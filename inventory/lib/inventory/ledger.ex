defmodule Bilimbi.Factory.Inventory.Ledger do
  @moduledoc false

  # Posts and reads Material Transactions. The facade has already proven the
  # company; everything here is scoped to that company ID.
  #
  # A posting locks the material rows it touches, in ID order, before it
  # reads a request ID or a stock position. That one lock serialises retries
  # of the same request and competing consumption of the same material, so
  # two callers cannot both take the last of it. The unique request index and
  # the database's balance and append-only triggers are the backstops.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory.Balance
  alias Bilimbi.Factory.Inventory.Entry
  alias Bilimbi.Factory.Inventory.Dimension
  alias Bilimbi.Factory.Inventory.Ledger.Request
  alias Bilimbi.Factory.Inventory.PostingAuthority
  alias Bilimbi.Factory.Inventory.ReceiptMeasurement
  alias Bilimbi.Factory.Inventory.Schemas
  alias Bilimbi.Factory.Inventory.Transaction
  alias Bilimbi.Factory.Inventory.Unit
  alias Bilimbi.Factory.Inventory.Location

  @production_context [:operation_execution, :order_or_batch, :work_centre]
  @always_production [:output, :transform]

  @type error ::
          :unregistered_posting_authority
          | :request_id_conflict
          | :item_not_found
          | :material_not_found
          | :material_retired
          | :location_not_found
          | :conversion_not_found
          | :transaction_not_found
          | :insufficient_stock
          | :variance_required
          | :no_variance
          | :identity_not_found
          | :identity_required
          | :invalid_identity
          | :insufficient_identity_stock
          | :insufficient_unidentified_stock
          | Ecto.Changeset.t()

  @spec post(pos_integer(), Transaction.kind(), map(), keyword()) ::
          {:ok, Transaction.t()} | {:error, error()}
  def post(company_id, kind, request, opts) do
    opts = Keyword.validate!(opts, [:authority])
    now = DateTime.utc_now(:microsecond)

    with {:ok, request} <- Request.validate(kind, request, now),
         {:ok, authority} <- authority(Keyword.fetch(opts, :authority)) do
      Repo.transaction(fn ->
        case record(company_id, kind, request, authority) do
          {:ok, transaction_id} -> read!(company_id, transaction_id)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @spec get(pos_integer(), pos_integer()) ::
          {:ok, Transaction.t()} | {:error, :transaction_not_found}
  def get(company_id, transaction_id) when is_integer(transaction_id) and transaction_id > 0 do
    case Repo.get_by(Schemas.Transaction, id: transaction_id, company_id: company_id) do
      nil -> {:error, :transaction_not_found}
      row -> {:ok, hd(read_models(company_id, [row]))}
    end
  end

  def get(_company_id, _transaction_id), do: {:error, :transaction_not_found}

  @doc "Reads the receipts among the given transaction IDs, in ID order."
  @spec receipts(pos_integer(), [pos_integer()]) :: [Transaction.t()]
  def receipts(company_id, transaction_ids) do
    from(transaction in Schemas.Transaction,
      where:
        transaction.company_id == ^company_id and transaction.kind == "receipt" and
          transaction.id in ^transaction_ids,
      order_by: [asc: transaction.id]
    )
    |> Repo.all()
    |> then(&read_models(company_id, &1))
  end

  @doc "Reads the consumptions and transforms that drew the identity, in ID order."
  @spec draws(pos_integer(), pos_integer()) :: [Transaction.t()]
  def draws(company_id, identity_id) do
    from(transaction in Schemas.Transaction,
      where:
        transaction.company_id == ^company_id and
          transaction.kind in ["consumption", "transform"] and
          transaction.id in subquery(
            from(entry in Schemas.Entry,
              where:
                entry.company_id == ^company_id and entry.role == "stock" and
                  entry.identity_id == ^identity_id and entry.native_quantity < 0,
              select: entry.transaction_id
            )
          ),
      order_by: [asc: transaction.id]
    )
    |> Repo.all()
    |> then(&read_models(company_id, &1))
  end

  @doc "Reads the corrections of a transaction, including corrections of those corrections, in ID order."
  @spec corrections(pos_integer(), pos_integer()) :: [Transaction.t()]
  def corrections(company_id, transaction_id), do: corrections(company_id, [transaction_id], [])

  defp corrections(company_id, [], found),
    do: read_models(company_id, Enum.sort_by(found, & &1.id))

  defp corrections(company_id, ids, found) do
    rows =
      from(transaction in Schemas.Transaction,
        where:
          transaction.company_id == ^company_id and transaction.kind == "correction" and
            transaction.corrects_transaction_id in ^ids
      )
      |> Repo.all()

    corrections(company_id, Enum.map(rows, & &1.id), found ++ rows)
  end

  @spec list(pos_integer(), keyword()) :: [Transaction.t()]
  def list(company_id, opts) do
    query =
      from(transaction in Schemas.Transaction,
        where: transaction.company_id == ^company_id,
        order_by: [desc: transaction.id],
        limit: ^opts[:limit]
      )

    query =
      case opts[:item_id] do
        nil ->
          query

        item_id ->
          from(transaction in query,
            where:
              transaction.id in subquery(
                from(entry in Schemas.Entry,
                  join: material in Schemas.Material,
                  on: material.id == entry.material_id,
                  where: material.item_id == ^item_id and entry.company_id == ^company_id,
                  select: entry.transaction_id
                )
              )
          )
      end

    read_models(company_id, Repo.all(query))
  end

  @doc "Sums the stock entries of one material at one location."
  @spec position(pos_integer(), pos_integer(), pos_integer()) :: Decimal.t()
  def position(company_id, material_id, location_id) do
    from(entry in Schemas.Entry,
      where:
        entry.company_id == ^company_id and entry.role == "stock" and
          entry.material_id == ^material_id and entry.location_id == ^location_id,
      select: coalesce(sum(entry.native_quantity), 0)
    )
    |> Repo.one()
    |> Decimal.new()
  end

  @doc "Current positive positions for one identity, grouped by location."
  def identity_positions(company_id, identity_id) do
    from(entry in Schemas.Entry,
      join: location in Schemas.Location,
      on: location.id == entry.location_id,
      join: unit in Schemas.Unit,
      on: unit.id == entry.native_unit_id,
      where:
        entry.company_id == ^company_id and entry.identity_id == ^identity_id and
          entry.role == "stock",
      group_by: [location.id, unit.id],
      order_by: [asc: location.id],
      select: {location, unit, sum(entry.native_quantity)}
    )
    |> Repo.all()
    |> Enum.reject(fn {_location, _unit, quantity} -> not Decimal.gt?(quantity, 0) end)
    |> Enum.map(fn {location, unit, quantity} ->
      %{
        location: Location.from_schema(location),
        quantity: quantity,
        unit: Unit.from_schema(unit)
      }
    end)
  end

  # ============================================================================
  # Balance
  # ============================================================================

  @doc "The transaction's balance net of its corrections: per native unit, and across units in a unit every line was posted in."
  @spec balance(pos_integer(), Transaction.t()) :: Balance.t()
  def balance(company_id, %Transaction{} = transaction) do
    corrections = corrections(company_id, transaction.id)
    stock = Enum.filter(transaction.entries, &(&1.role == :stock))
    variances = Enum.filter(transaction.entries, &(&1.role == :variance))

    # A correction entry nets into the side of the entry it adjusts: the one
    # for the same item and identity.
    sided =
      Enum.map(stock, &{side(&1), &1}) ++
        for correction <- corrections, entry <- correction.entries, entry.role == :stock do
          case Enum.find(
                 stock,
                 &(&1.item_id == entry.item_id and &1.identity_id == entry.identity_id)
               ) do
            nil -> {side(entry), entry}
            adjusted -> {side(adjusted), entry}
          end
        end

    units = sided |> Enum.map(fn {_side, entry} -> entry.native_unit end) |> Enum.uniq_by(& &1.id)

    per_unit =
      for unit <- units do
        own = Enum.filter(sided, fn {_side, entry} -> entry.native_unit.id == unit.id end)
        input = Decimal.negate(sum(own, :input, & &1.native_quantity))
        output = sum(own, :output, & &1.native_quantity)

        %{
          unit: unit,
          input: input,
          output: output,
          difference: Decimal.sub(input, output),
          variance:
            variances
            |> Enum.filter(&(&1.native_unit.id == unit.id))
            |> Enum.map(& &1.native_quantity)
            |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        }
      end

    %Balance{
      transaction_id: transaction.id,
      per_unit: per_unit,
      cross_unit: if(length(units) > 1, do: cross_unit(company_id, sided, units), else: []),
      correction_transaction_ids: Enum.map(corrections, & &1.id)
    }
  end

  defp side(entry), do: if(Decimal.negative?(entry.native_quantity), do: :input, else: :output)

  defp sum(sided, side, convert) do
    for {^side, entry} <- sided, reduce: Decimal.new(0) do
      total -> Decimal.add(total, convert.(entry))
    end
  end

  # A line counts in a unit only as it was posted: its native quantity when
  # native in that unit, or its recorded quantity when recorded in it, with
  # the conversion version it was posted through named. Nothing is converted
  # at read time, so a later conversion version never restates the balance.
  defp cross_unit(company_id, sided, units) do
    conversion_ids =
      for {_side, entry} <- sided, entry.conversion_id, uniq: true, do: entry.conversion_id

    factors =
      from(conversion in Schemas.Conversion,
        where: conversion.company_id == ^company_id and conversion.id in ^conversion_ids,
        select: {conversion.id, conversion.factor}
      )
      |> Repo.all()
      |> Map.new()

    Enum.flat_map(units, fn unit ->
      if Enum.all?(sided, fn {_side, entry} -> in_unit?(entry, unit) end),
        do: [converted(unit, sided, factors)],
        else: []
    end)
  end

  defp in_unit?(entry, unit),
    do:
      entry.native_unit.id == unit.id or
        (entry.recorded_unit && entry.recorded_unit.id == unit.id)

  defp converted(unit, sided, factors) do
    convert = fn entry ->
      cond do
        entry.native_unit.id == unit.id -> entry.native_quantity
        Decimal.negative?(entry.native_quantity) -> Decimal.negate(entry.recorded_quantity)
        true -> entry.recorded_quantity
      end
    end

    input = Decimal.negate(sum(sided, :input, convert))
    output = sum(sided, :output, convert)

    %{
      unit: unit,
      input: input,
      output: output,
      difference: Decimal.sub(input, output),
      conversions:
        for {_side, entry} <- sided,
            entry.native_unit.id != unit.id,
            uniq: true do
          %{
            item_id: entry.item_id,
            conversion_id: entry.conversion_id,
            version: entry.conversion_version,
            factor: Map.fetch!(factors, entry.conversion_id)
          }
        end
        |> Enum.sort_by(&{&1.item_id, &1.version})
    }
  end

  # ============================================================================
  # Posting
  # ============================================================================

  # A production posting names its authority, which must be declared; any
  # other posting names none and may not carry production context.
  defp authority(:error), do: {:ok, nil}

  defp authority({:ok, module}) do
    if PostingAuthority.registered?(module),
      do: {:ok, module},
      else: {:error, :unregistered_posting_authority}
  end

  defp record(company_id, kind, request, authority) do
    with {:ok, original} <- corrected(company_id, kind, request),
         :ok <- authorised(kind, request, original, authority),
         {:ok, materials} <- lock_materials(company_id, request),
         :ok <- fresh(company_id, request),
         :ok <- active_materials(kind, materials),
         {:ok, locations} <- locations(company_id, request),
         {:ok, plan} <- plan(company_id, kind, request, materials, locations),
         :ok <- validate_identities(company_id, kind, plan.entries),
         :ok <- stock_suffices(company_id, plan.entries),
         :ok <- identity_stock_suffices(company_id, plan.entries),
         :ok <- unidentified_stock_suffices(company_id, plan.entries) do
      insert(company_id, kind, request, authority, plan)
    else
      {:replay, transaction_id} -> {:ok, transaction_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_materials(:correction, _materials), do: :ok

  defp active_materials(_kind, materials) do
    if Enum.any?(materials, fn {_item_id, {material, _unit}} -> material.retired_at != nil end),
      do: {:error, :material_retired},
      else: :ok
  end

  defp corrected(company_id, :correction, request) do
    case Repo.get_by(Schemas.Transaction,
           id: request.corrects_transaction_id,
           company_id: company_id
         ) do
      nil -> {:error, :transaction_not_found}
      original -> {:ok, original}
    end
  end

  defp corrected(_company_id, _kind, _request), do: {:ok, nil}

  # Production or transform context needs a registered authority. Correcting
  # a posting that needed one needs one too.
  defp authorised(kind, request, original, authority) do
    production? =
      kind in @always_production or
        Enum.any?(@production_context, &Map.has_key?(request.context, &1)) or
        (original != nil and original.posting_authority != nil)

    if production? and authority == nil,
      do: {:error, :unregistered_posting_authority},
      else: :ok
  end

  defp lock_materials(company_id, request) do
    item_ids = request |> lines() |> Enum.map(& &1.item_id) |> Enum.uniq()

    locked =
      from(material in Schemas.Material,
        where: material.company_id == ^company_id and material.item_id in ^item_ids,
        order_by: [asc: material.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    unit_ids = Enum.map(locked, & &1.native_unit_id)

    units =
      from(unit in Schemas.Unit, where: unit.id in ^unit_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    materials =
      Map.new(locked, &{&1.item_id, {&1, Map.fetch!(units, &1.native_unit_id)}})

    case Enum.reject(item_ids, &Map.has_key?(materials, &1)) do
      [] ->
        {:ok, materials}

      missing ->
        known =
          from(item in Schemas.Item,
            where: item.company_id == ^company_id and item.id in ^missing,
            select: count()
          )
          |> Repo.one()

        if known == length(missing),
          do: {:error, :material_not_found},
          else: {:error, :item_not_found}
    end
  end

  # A retry of a recorded request returns what it recorded; a different
  # request under the same ID is refused.
  defp fresh(company_id, request) do
    from(transaction in Schemas.Transaction,
      where:
        transaction.company_id == ^company_id and transaction.request_id == ^request.request_id,
      select: {transaction.id, transaction.request_fingerprint}
    )
    |> Repo.one()
    |> case do
      nil ->
        :ok

      {id, fingerprint} ->
        if fingerprint == request.fingerprint,
          do: {:replay, id},
          else: {:error, :request_id_conflict}
    end
  end

  defp locations(company_id, request) do
    ids =
      request
      |> lines()
      |> Enum.flat_map(&[&1[:location_id], &1[:from_location_id], &1[:to_location_id]])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    found =
      from(location in Schemas.Location,
        where: location.company_id == ^company_id and location.id in ^ids,
        select: location.id
      )
      |> Repo.all()
      |> MapSet.new()

    if Enum.all?(ids, &MapSet.member?(found, &1)),
      do: {:ok, found},
      else: {:error, :location_not_found}
  end

  defp lines(%{inputs: inputs, outputs: outputs}), do: inputs ++ outputs
  defp lines(%{lines: lines}), do: lines

  # ============================================================================
  # Entry plans
  # ============================================================================

  # A plan is the entries to insert, in order, and the genealogy links between
  # them as {input position, output position}.

  defp plan(company_id, :transfer, request, materials, _locations) do
    request.lines
    |> map_ok(fn line ->
      with {:ok, stock} <- stock(company_id, line, materials) do
        {:ok,
         [
           signed(%{stock | location_id: line.from_location_id}, -1),
           %{stock | location_id: line.to_location_id}
         ]}
      end
    end)
    |> entries_plan()
  end

  defp plan(company_id, :transform, request, materials, _locations) do
    with {:ok, inputs} <- map_ok(request.inputs, &stock(company_id, &1, materials)),
         {:ok, outputs} <- map_ok(request.outputs, &stock(company_id, &1, materials)),
         {:ok, variance} <- variance(inputs, outputs, Request.variance(request)) do
      inputs = Enum.map(inputs, &signed(&1, -1))
      entries = inputs ++ outputs ++ variance
      input_positions = Enum.to_list(0..(length(inputs) - 1)//1)
      output_positions = Enum.to_list(length(inputs)..(length(inputs) + length(outputs) - 1)//1)

      {:ok,
       %{
         entries: entries,
         links: for(input <- input_positions, output <- output_positions, do: {input, output})
       }}
    end
  end

  defp plan(company_id, kind, request, materials, _locations) do
    sign = if kind == :consumption, do: -1, else: 1

    request.lines
    |> map_ok(fn line ->
      with {:ok, stock} <- stock(company_id, line, materials) do
        stock =
          signed(stock, if(Decimal.negative?(line.quantity), do: -sign, else: sign))

        {:ok, [stock, boundary(stock)]}
      end
    end)
    |> entries_plan()
  end

  defp entries_plan({:ok, groups}), do: {:ok, %{entries: List.flatten(groups), links: []}}
  defp entries_plan(error), do: error

  defp stock(company_id, line, materials) do
    {material, native_unit} = Map.fetch!(materials, line.item_id)
    quantity = Decimal.abs(line.quantity)

    with {:ok, native_quantity, recorded_unit_id, conversion_id} <-
           native(company_id, material, native_unit, line, quantity) do
      {:ok,
       %{
         role: "stock",
         material_id: material.id,
         location_id: line[:location_id],
         native_quantity: native_quantity,
         native_unit_id: native_unit.id,
         recorded_quantity: quantity,
         recorded_unit_id: recorded_unit_id,
         conversion_id: conversion_id,
         observation: line.observation,
         identity_id: line[:identity_id],
         new_identity: line[:identity],
         output_role: line[:output_role],
         evidence: line[:evidence],
         reconciliation_basis: nil
       }}
    end
  end

  # The recorded quantity is kept as observed; the native quantity is derived
  # from it through the named conversion version and never replaces it.
  defp native(company_id, material, native_unit, line, quantity) do
    case line[:unit_id] do
      unit_id when unit_id in [nil, native_unit.id] ->
        {:ok, quantity, native_unit.id, nil}

      unit_id ->
        query =
          from(conversion in Schemas.Conversion,
            where:
              conversion.company_id == ^company_id and conversion.material_id == ^material.id and
                conversion.unit_id == ^unit_id,
            order_by: [desc: conversion.version],
            limit: 1
          )

        query =
          case line[:conversion_version] do
            nil -> query
            version -> from(conversion in query, where: conversion.version == ^version)
          end

        case Repo.one(query) do
          nil ->
            {:error, :conversion_not_found}

          conversion ->
            native_quantity = quantity |> Decimal.mult(conversion.factor) |> Decimal.round(12)
            {:ok, native_quantity, unit_id, conversion.id}
        end
    end
  end

  defp signed(entry, sign) when sign in [-1, 1] do
    %{entry | native_quantity: Decimal.mult(entry.native_quantity, sign)}
  end

  defp boundary(stock) do
    %{
      stock
      | role: "boundary",
        location_id: nil,
        native_quantity: Decimal.negate(stock.native_quantity),
        recorded_quantity: nil,
        recorded_unit_id: nil,
        conversion_id: nil,
        observation: nil,
        identity_id: nil,
        new_identity: nil,
        output_role: nil,
        evidence: nil
    }
  end

  # A transform balances per native unit; its observations are compared,
  # never adjusted, and nothing is converted between units. Each unit whose
  # inputs and outputs differ records the difference as a variance entry in
  # that unit, carrying the shared evidence or the evidence named for that
  # unit. Evidence that no difference uses is refused.
  defp variance(inputs, outputs, evidence) do
    differences =
      for unit_id <- (inputs ++ outputs) |> Enum.map(& &1.native_unit_id) |> Enum.uniq(),
          difference = Decimal.sub(total(inputs, unit_id), total(outputs, unit_id)),
          not Decimal.eq?(difference, 0),
          do: {unit_id, difference}

    differing = Enum.map(differences, &elem(&1, 0))

    by_unit =
      case evidence do
        nil -> %{}
        {:shared, shared} -> Map.new(differing, &{&1, shared})
        {:units, named} -> named
      end

    cond do
      Enum.any?(differing, &(not Map.has_key?(by_unit, &1))) ->
        {:error, :variance_required}

      evidence != nil and (differing == [] or map_size(by_unit) > length(differing)) ->
        {:error, :no_variance}

      true ->
        {:ok,
         for {unit_id, difference} <- differences do
           %{evidence: evidence, reconciliation_basis: basis} = Map.fetch!(by_unit, unit_id)

           %{
             role: "variance",
             material_id: nil,
             location_id: nil,
             native_quantity: difference,
             native_unit_id: unit_id,
             recorded_quantity: nil,
             recorded_unit_id: nil,
             conversion_id: nil,
             observation: nil,
             identity_id: nil,
             new_identity: nil,
             output_role: nil,
             evidence: evidence,
             reconciliation_basis: basis
           }
         end}
    end
  end

  defp total(entries, unit_id) do
    for entry <- entries, entry.native_unit_id == unit_id, reduce: Decimal.new(0) do
      sum -> Decimal.add(sum, entry.native_quantity)
    end
  end

  defp map_ok(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # ============================================================================
  # Insert
  # ============================================================================

  defp insert(company_id, kind, request, authority, plan) do
    attributes = %{
      company_id: company_id,
      kind: Atom.to_string(kind),
      request_id: request.request_id,
      request_fingerprint: request.fingerprint,
      actor_type: request.actor_type,
      actor_id: request.actor_id,
      evidence: request.evidence,
      receipt_measurement: request[:receipt_measurement],
      reason: request[:reason],
      corrects_transaction_id: request[:corrects_transaction_id],
      posting_authority: authority && inspect(authority),
      operation_execution_ref: request.context[:operation_execution],
      order_or_batch_ref: request.context[:order_or_batch],
      work_centre_ref: request.context[:work_centre],
      shipment_ref: request.context[:shipment],
      destination_ref: request.context[:destination],
      effective_at: request.effective_at,
      # Taken after the material locks, so it never precedes the effective
      # time validated against an earlier clock reading.
      recorded_at: DateTime.utc_now(:microsecond)
    }

    with {:ok, transaction} <-
           attributes |> Schemas.Transaction.creation_changeset() |> Repo.insert(),
         {:ok, entry_ids} <- insert_entries(company_id, transaction.id, plan.entries) do
      entry_ids = List.to_tuple(entry_ids)

      Enum.each(plan.links, fn {input, output} ->
        Repo.insert!(%Schemas.GenealogyLink{
          company_id: company_id,
          transaction_id: transaction.id,
          input_entry_id: elem(entry_ids, input),
          output_entry_id: elem(entry_ids, output)
        })
      end)

      {:ok, transaction.id}
    else
      # A concurrent request under the same ID committed first with other
      # materials, so the material locks did not order the two.
      {:error, changeset} ->
        case changeset.errors[:request_id] do
          {_message, [{:constraint, :unique} | _details]} -> {:error, :request_id_conflict}
          _other -> {:error, changeset}
        end
    end
  end

  defp insert_entries(company_id, transaction_id, entries) do
    map_ok(entries, fn entry ->
      with {:ok, identity_id} <- insert_identity(company_id, transaction_id, entry) do
        entry =
          entry
          |> Map.drop([:new_identity])
          |> Map.put(:identity_id, identity_id)
          |> Map.merge(%{company_id: company_id, transaction_id: transaction_id})

        %Schemas.Entry{}
        |> Ecto.Changeset.change(entry)
        |> Repo.insert()
        |> case do
          {:ok, row} -> {:ok, row.id}
          error -> error
        end
      end
    end)
  end

  defp insert_identity(_company_id, _transaction_id, %{new_identity: nil, identity_id: id}),
    do: {:ok, id}

  defp insert_identity(company_id, transaction_id, entry) do
    identity = entry.new_identity

    %{
      company_id: company_id,
      material_id: entry.material_id,
      source_transaction_id: transaction_id,
      kind: identity[:kind] || identity["kind"],
      code: identity[:code] || identity["code"],
      dimensions:
        case identity[:dimensions] || identity["dimensions"] do
          nil ->
            %{}

          dimensions ->
            Map.new(dimensions, fn {name, value} ->
              {:ok, dimension} = Dimension.parse(value)
              {to_string(name), Dimension.stored(dimension)}
            end)
        end
    }
    |> Schemas.Identity.creation_changeset()
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, row.id}
      error -> error
    end
  end

  defp validate_identities(company_id, kind, entries) do
    stock = Enum.filter(entries, &(&1.role == "stock"))

    cond do
      Enum.any?(stock, &(&1.identity_id && &1.new_identity)) ->
        {:error, :invalid_identity}

      Enum.any?(stock, fn entry ->
        entry.new_identity &&
            not (Decimal.positive?(entry.native_quantity) and
                     kind in [:receipt, :output, :transform])
      end) ->
        {:error, :invalid_identity}

      kind in [:receipt, :output] and Enum.any?(stock, & &1.identity_id) ->
        {:error, :invalid_identity}

      kind == :transform and
          Enum.any?(stock, &(Decimal.positive?(&1.native_quantity) and &1.identity_id)) ->
        {:error, :invalid_identity}

      kind == :transform and Enum.any?(stock, &(&1.identity_id || &1.new_identity)) and
          Enum.any?(stock, &(is_nil(&1.identity_id) and is_nil(&1.new_identity))) ->
        {:error, :identity_required}

      true ->
        ids = stock |> Enum.map(& &1.identity_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

        found =
          from(identity in Schemas.Identity,
            where: identity.company_id == ^company_id and identity.id in ^ids
          )
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        if Enum.all?(stock, fn entry ->
             entry.identity_id == nil or
               (found[entry.identity_id] &&
                  found[entry.identity_id].material_id == entry.material_id)
           end),
           do: :ok,
           else: {:error, :identity_not_found}
    end
  end

  defp identity_stock_suffices(company_id, entries) do
    entries
    |> Enum.filter(
      &((&1.role == "stock" and &1.identity_id) && Decimal.negative?(&1.native_quantity))
    )
    |> Enum.group_by(&{&1.identity_id, &1.location_id}, &Decimal.abs(&1.native_quantity))
    |> Enum.all?(fn {{identity_id, location_id}, drawn} ->
      available =
        from(entry in Schemas.Entry,
          where:
            entry.company_id == ^company_id and entry.role == "stock" and
              entry.identity_id == ^identity_id and entry.location_id == ^location_id,
          select: coalesce(sum(entry.native_quantity), 0)
        )
        |> Repo.one()
        |> Decimal.new()

      Decimal.compare(available, Enum.reduce(drawn, &Decimal.add/2)) != :lt
    end)
    |> if(do: :ok, else: {:error, :insufficient_identity_stock})
  end

  defp unidentified_stock_suffices(company_id, entries) do
    entries
    |> Enum.filter(
      &(&1.role == "stock" and is_nil(&1.identity_id) and
          Decimal.negative?(&1.native_quantity))
    )
    |> Enum.group_by(&{&1.material_id, &1.location_id}, &Decimal.abs(&1.native_quantity))
    |> Enum.all?(fn {{material_id, location_id}, drawn} ->
      available =
        from(entry in Schemas.Entry,
          where:
            entry.company_id == ^company_id and entry.role == "stock" and
              is_nil(entry.identity_id) and entry.material_id == ^material_id and
              entry.location_id == ^location_id,
          select: coalesce(sum(entry.native_quantity), 0)
        )
        |> Repo.one()
        |> Decimal.new()

      Decimal.compare(available, Enum.reduce(drawn, &Decimal.add/2)) != :lt
    end)
    |> if(do: :ok, else: {:error, :insufficient_unidentified_stock})
  end

  # Every position a posting draws down must hold, before the posting, all it
  # draws there; the posting's own additions never cover its draws. The
  # material locks taken at the start make this read current.
  defp stock_suffices(company_id, entries) do
    entries
    |> Enum.filter(&(&1.role == "stock" and Decimal.negative?(&1.native_quantity)))
    |> Enum.group_by(&{&1.material_id, &1.location_id}, &Decimal.abs(&1.native_quantity))
    |> Enum.all?(fn {{material_id, location_id}, drawn} ->
      Decimal.compare(
        position(company_id, material_id, location_id),
        Enum.reduce(drawn, &Decimal.add/2)
      ) != :lt
    end)
    |> if(do: :ok, else: {:error, :insufficient_stock})
  end

  # ============================================================================
  # Read models
  # ============================================================================

  defp read!(company_id, transaction_id) do
    {:ok, transaction} = get(company_id, transaction_id)
    transaction
  end

  defp read_models(_company_id, []), do: []

  defp read_models(company_id, rows) do
    ids = Enum.map(rows, & &1.id)

    entries =
      from(entry in Schemas.Entry,
        left_join: material in Schemas.Material,
        on: material.id == entry.material_id,
        left_join: conversion in Schemas.Conversion,
        on: conversion.id == entry.conversion_id,
        where: entry.company_id == ^company_id and entry.transaction_id in ^ids,
        order_by: [asc: entry.id],
        select: {entry, material.item_id, conversion.version}
      )
      |> Repo.all()

    unit_ids =
      entries
      |> Enum.flat_map(fn {entry, _item_id, _version} ->
        [entry.native_unit_id, entry.recorded_unit_id]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    units =
      from(unit in Schemas.Unit, where: unit.id in ^unit_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, Unit.from_schema(&1)})

    entries_by_transaction =
      Enum.group_by(
        entries,
        fn {entry, _item_id, _version} -> entry.transaction_id end,
        fn {entry, item_id, version} ->
          entry(entry, item_id, version, units)
        end
      )

    links =
      from(link in Schemas.GenealogyLink,
        where: link.company_id == ^company_id and link.transaction_id in ^ids,
        order_by: [asc: link.id]
      )
      |> Repo.all()
      |> Enum.group_by(
        & &1.transaction_id,
        &%{input_entry_id: &1.input_entry_id, output_entry_id: &1.output_entry_id}
      )

    Enum.map(rows, fn row ->
      transaction(row, Map.get(entries_by_transaction, row.id, []), Map.get(links, row.id, []))
    end)
  end

  @kinds Map.new(Transaction.kinds(), &{Atom.to_string(&1), &1})
  @roles %{"stock" => :stock, "boundary" => :boundary, "variance" => :variance}
  @observations %{
    "measured" => :measured,
    "declared" => :declared,
    "counted" => :counted,
    "derived" => :derived
  }

  defp transaction(row, entries, genealogy) do
    %Transaction{
      id: row.id,
      company_id: row.company_id,
      kind: Map.fetch!(@kinds, row.kind),
      request_id: row.request_id,
      actor_type: row.actor_type,
      actor_id: row.actor_id,
      evidence: row.evidence,
      receipt_measurement: receipt_measurement(row.receipt_measurement),
      reason: row.reason,
      corrects_transaction_id: row.corrects_transaction_id,
      posting_authority: row.posting_authority,
      context:
        %{
          operation_execution: row.operation_execution_ref,
          order_or_batch: row.order_or_batch_ref,
          work_centre: row.work_centre_ref,
          shipment: row.shipment_ref,
          destination: row.destination_ref
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end),
      effective_at: row.effective_at,
      recorded_at: row.recorded_at,
      entries: entries,
      genealogy: genealogy
    }
  end

  defp receipt_measurement(nil), do: nil

  defp receipt_measurement(values) do
    values = Map.new(values, fn {key, value} -> {to_string(key), value} end)
    declared = Decimal.new(values["supplier_declared"])
    net = Decimal.new(values["net"])

    %ReceiptMeasurement{
      supplier_declared: declared,
      measured_gross: Decimal.new(values["measured_gross"]),
      tare: Decimal.new(values["tare"]),
      net: net,
      unit_id: values["unit_id"],
      weighing_point_ref: values["weighing_point_ref"],
      supplier_variance: Decimal.sub(declared, net)
    }
  end

  defp entry(entry, item_id, conversion_version, units) do
    %Entry{
      id: entry.id,
      role: Map.fetch!(@roles, entry.role),
      item_id: item_id,
      identity_id: entry.identity_id,
      location_id: entry.location_id,
      native_quantity: entry.native_quantity,
      native_unit: Map.fetch!(units, entry.native_unit_id),
      recorded_quantity: entry.recorded_quantity,
      recorded_unit: entry.recorded_unit_id && Map.fetch!(units, entry.recorded_unit_id),
      conversion_id: entry.conversion_id,
      conversion_version: conversion_version,
      observation: entry.observation && Map.fetch!(@observations, entry.observation),
      output_role: entry.output_role,
      evidence: entry.evidence,
      reconciliation_basis: entry.reconciliation_basis
    }
  end
end
