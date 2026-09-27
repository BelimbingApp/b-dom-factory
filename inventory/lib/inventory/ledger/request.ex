defmodule Bilimbi.Factory.Inventory.Ledger.Request do
  @moduledoc false

  # Validates a posting request's shape before the ledger touches the
  # database, and fingerprints it so a retry can be told from a reused
  # request ID. A failed field is a changeset error on the request; a failed
  # line names its position in the list.

  import Ecto.Changeset

  alias Bilimbi.Factory.Inventory.Transaction
  alias Bilimbi.Factory.Inventory.Dimension

  @header_types %{
    request_id: :string,
    actor_type: :string,
    actor_id: :integer,
    evidence: :string,
    effective_at: :utc_datetime_usec,
    reason: :string,
    corrects_transaction_id: :integer,
    context: :map,
    variance: :map,
    receipt_measurement: :map
  }

  @line_types %{
    item_id: :integer,
    location_id: :integer,
    from_location_id: :integer,
    to_location_id: :integer,
    quantity: :decimal,
    unit_id: :integer,
    conversion_version: :integer,
    observation: :string,
    evidence: :string,
    output_role: :string,
    identity_id: :integer,
    identity: :map
  }

  @observations ~w(measured declared counted derived)
  @text_limit 10_000
  @reference_limit 255
  @receipt_measurement_types %{
    supplier_declared: :decimal,
    measured_gross: :decimal,
    tare: :decimal,
    net: :decimal,
    unit_id: :integer,
    weighing_point_ref: :string
  }

  @spec observations() :: [String.t()]
  def observations, do: @observations

  @spec validate(Transaction.kind(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def validate(kind, request, now) when is_map(request) do
    changeset =
      {%{}, @header_types}
      |> cast(request, Map.keys(@header_types))
      |> validate_required([:request_id, :actor_type, :actor_id, :evidence])
      |> validate_length(:request_id, max: @reference_limit)
      |> validate_length(:actor_type, max: 64)
      |> validate_number(:actor_id, greater_than_or_equal_to: 0)
      |> validate_length(:evidence, max: @text_limit)
      |> validate_change(:effective_at, &not_after(&1, &2, now))
      |> validate_change(:context, &context/2)
      |> validate_kind(kind)

    {changeset, lists} =
      Enum.reduce(list_fields(kind), {changeset, %{}}, fn {field, line_kind},
                                                          {changeset, lists} ->
        case lines(request, field, line_kind) do
          {:ok, lines} -> {changeset, Map.put(lists, field, lines)}
          {:error, errors} -> {Enum.reduce(errors, changeset, &add_error(&2, field, &1)), lists}
        end
      end)

    changeset =
      case receipt_measurement_line_errors(
             kind,
             cast_receipt_measurement(changeset.changes[:receipt_measurement]),
             lists
           ) do
        [] -> changeset
        errors -> Enum.reduce(errors, changeset, &add_error(&2, :receipt_measurement, &1))
      end

    with {:ok, header} <- apply_action(changeset, :validate) do
      fingerprint = fingerprint(kind, changeset.changes, lists)

      {:ok,
       header
       |> Map.put_new(:effective_at, now)
       |> Map.update(:context, %{}, &normalize_context/1)
       |> Map.update(:receipt_measurement, nil, &normalize_receipt_measurement/1)
       |> Map.merge(lists)
       |> Map.put(:fingerprint, fingerprint)}
    end
  end

  defp list_fields(:transfer), do: [lines: :transfer]
  defp list_fields(:correction), do: [lines: :adjustment]
  defp list_fields(:transform), do: [inputs: :stock, outputs: :output]
  defp list_fields(_kind), do: [lines: :stock]

  defp validate_kind(changeset, :correction) do
    changeset
    |> validate_required([:reason, :corrects_transaction_id])
    |> validate_length(:reason, max: @text_limit)
    |> absent(:variance)
    |> absent(:receipt_measurement)
  end

  defp validate_kind(changeset, :transform) do
    changeset
    |> absent(:reason)
    |> absent(:corrects_transaction_id)
    |> validate_change(:variance, &variance/2)
    |> absent(:receipt_measurement)
  end

  defp validate_kind(changeset, :receipt) do
    changeset
    |> absent(:reason)
    |> absent(:corrects_transaction_id)
    |> absent(:variance)
    |> validate_change(:receipt_measurement, &receipt_measurement/2)
  end

  defp validate_kind(changeset, _kind) do
    changeset
    |> absent(:reason)
    |> absent(:corrects_transaction_id)
    |> absent(:variance)
    |> absent(:receipt_measurement)
  end

  defp receipt_measurement_line_errors(_kind, nil, _lists), do: []
  defp receipt_measurement_line_errors(_kind, {:error, _changeset}, _lists), do: []

  defp receipt_measurement_line_errors(:receipt, {:ok, measurement}, %{lines: [line]}) do
    if line.observation == "measured" and line.unit_id == measurement.unit_id and
         Decimal.eq?(line.quantity, measurement.net),
       do: [],
       else: ["net and unit must match the measured stock line"]
  end

  defp receipt_measurement_line_errors(:receipt, _measurement, _lists),
    do: ["requires exactly one measured stock line"]

  defp receipt_measurement_line_errors(_kind, _measurement, _lists), do: []

  defp receipt_measurement(:receipt_measurement, measurement) do
    changeset = cast_receipt_measurement(measurement)

    case changeset do
      {:error, changeset} ->
        traverse_errors(changeset, fn {message, options} ->
          Enum.reduce(options, message, fn {key, value}, message ->
            String.replace(message, "%{#{key}}", to_string(value))
          end)
        end)
        |> Enum.flat_map(fn {_field, messages} ->
          Enum.map(messages, &{:receipt_measurement, &1})
        end)

      {:ok, fields} ->
        expected_net = Decimal.sub(fields.measured_gross, fields.tare)

        if Decimal.eq?(expected_net, fields.net),
          do: [],
          else: [receipt_measurement: "measured_gross minus tare must equal net"]
    end
  end

  defp receipt_measurement(_field, _measurement), do: [receipt_measurement: "must be a map"]

  defp cast_receipt_measurement(nil), do: nil

  defp cast_receipt_measurement(measurement) when is_map(measurement) do
    changeset =
      {%{}, @receipt_measurement_types}
      |> cast(measurement, Map.keys(@receipt_measurement_types))
      |> validate_required(Map.keys(@receipt_measurement_types))
      |> validate_number(:supplier_declared, greater_than: 0)
      |> validate_number(:measured_gross, greater_than: 0)
      |> validate_number(:tare, greater_than_or_equal_to: 0)
      |> validate_number(:net, greater_than: 0)
      |> validate_number(:unit_id, greater_than: 0)
      |> validate_length(:weighing_point_ref, max: @reference_limit)

    apply_action(changeset, :validate)
  end

  defp cast_receipt_measurement(_measurement),
    do: {:error, change({%{}, @receipt_measurement_types})}

  defp normalize_receipt_measurement(nil), do: nil

  defp normalize_receipt_measurement(measurement) do
    {:ok, fields} = cast_receipt_measurement(measurement)

    Map.new(fields, fn {key, value} ->
      {key, if(match?(%Decimal{}, value), do: Decimal.to_string(value), else: value)}
    end)
  end

  defp absent(changeset, field) do
    if get_change(changeset, field) == nil,
      do: changeset,
      else: add_error(changeset, field, "is not accepted for this transaction")
  end

  defp not_after(field, at, now) do
    if DateTime.after?(at, now),
      do: [{field, "cannot be later than the time it is recorded"}],
      else: []
  end

  defp context(:context, context) do
    known = Transaction.context_keys() |> Enum.flat_map(&[&1, Atom.to_string(&1)])

    Enum.flat_map(context, fn
      {key, value} when is_binary(value) and value != "" ->
        cond do
          key not in known -> [context: "has an unknown reference #{inspect(key)}"]
          String.length(value) > @reference_limit -> [context: "#{key} is too long"]
          true -> []
        end

      {key, _value} ->
        [context: "#{key} must be a non-empty string"]
    end)
  end

  defp normalize_context(context) do
    Map.new(Transaction.context_keys(), &{&1, context[&1] || context[Atom.to_string(&1)]})
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Variance evidence is either shared by every native unit whose inputs and
  # outputs differ, or named per unit under `units`; never both.
  defp variance(:variance, variance) do
    shared? = field(variance, :evidence) != nil or field(variance, :reconciliation_basis) != nil

    errors =
      case {shared?, field(variance, :units)} do
        {true, nil} ->
          text_errors(field(variance, :evidence), field(variance, :reconciliation_basis), "needs")

        {true, _units} ->
          ["takes evidence and reconciliation_basis, or units, not both"]

        {false, [_ | _] = units} ->
          unit_variance_errors(units)

        {false, units} when units in [nil, []] ->
          ["needs evidence and reconciliation_basis, or units"]

        {false, _other} ->
          ["units must be a list"]
      end

    Enum.map(errors, &{:variance, &1})
  end

  defp unit_variance_errors(units) do
    errors =
      units
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {unit, position} when is_map(unit) ->
          unit_id = field(unit, :unit_id)

          id_errors =
            if is_integer(unit_id) and unit_id > 0,
              do: [],
              else: ["unit #{position} needs unit_id"]

          id_errors ++
            text_errors(
              field(unit, :evidence),
              field(unit, :reconciliation_basis),
              "unit #{position} needs"
            )

        {_unit, position} ->
          ["unit #{position} must be a map"]
      end)

    ids = for unit <- units, is_map(unit), do: field(unit, :unit_id)

    if length(Enum.uniq(ids)) == length(ids),
      do: errors,
      else: errors ++ ["units must name each unit once"]
  end

  defp text_errors(evidence, basis, prefix) do
    for {key, value} <- [evidence: evidence, reconciliation_basis: basis],
        not (is_binary(value) and value != "" and byte_size(value) <= @text_limit),
        do: "#{prefix} #{key}"
  end

  defp field(map, key) when is_map(map), do: map[key] || map[Atom.to_string(key)]
  defp field(_other, _key), do: nil

  @doc false
  @spec variance(map()) ::
          {:shared, %{evidence: String.t(), reconciliation_basis: String.t()}}
          | {:units,
             %{pos_integer() => %{evidence: String.t(), reconciliation_basis: String.t()}}}
          | nil
  def variance(%{variance: variance}) when is_map(variance) do
    case field(variance, :units) do
      nil ->
        {:shared,
         %{
           evidence: field(variance, :evidence),
           reconciliation_basis: field(variance, :reconciliation_basis)
         }}

      units ->
        {:units,
         Map.new(units, fn unit ->
           {field(unit, :unit_id),
            %{
              evidence: field(unit, :evidence),
              reconciliation_basis: field(unit, :reconciliation_basis)
            }}
         end)}
    end
  end

  def variance(_header), do: nil

  # ============================================================================
  # Lines
  # ============================================================================

  defp lines(request, field, line_kind) do
    case Map.get(request, field, Map.get(request, Atom.to_string(field))) do
      [_ | _] = lines ->
        results =
          lines
          |> Enum.with_index(1)
          |> Enum.map(fn {line, position} -> {position, line(line, line_kind)} end)

        case for {position, {:error, messages}} <- results,
                 message <- messages,
                 do: "line #{position}: #{message}" do
          [] -> {:ok, for({_position, {:ok, line}} <- results, do: line)}
          errors -> {:error, errors}
        end

      _missing ->
        {:error, ["needs at least one line"]}
    end
  end

  defp line(line, line_kind) when is_map(line) do
    changeset =
      {%{}, @line_types}
      |> cast(line, line_fields(line_kind))
      |> validate_required(required_line_fields(line_kind))
      |> validate_inclusion(:observation, @observations)
      |> validate_length(:evidence, max: @text_limit)
      |> validate_length(:output_role, max: 64)
      |> validate_number(:conversion_version, greater_than: 0)
      |> validate_number(:identity_id, greater_than: 0)
      |> validate_change(:identity, &identity/2)
      |> validate_change(:quantity, &quantity(&1, &2, line_kind))
      |> distinct_locations(line_kind)

    case apply_action(changeset, :validate) do
      {:ok, line} ->
        {:ok, line}

      {:error, changeset} ->
        {:error,
         changeset
         |> traverse_errors(fn {message, options} ->
           Enum.reduce(options, message, fn {key, value}, message ->
             String.replace(message, "%{#{key}}", to_string(value))
           end)
         end)
         |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)}
    end
  end

  defp line(_line, _line_kind), do: {:error, ["must be a map"]}

  @common [
    :item_id,
    :quantity,
    :unit_id,
    :conversion_version,
    :observation,
    :evidence,
    :identity_id,
    :identity
  ]

  defp identity(:identity, value) do
    kind = value[:kind] || value["kind"]
    code = value[:code] || value["code"]
    dimensions = value[:dimensions] || value["dimensions"]

    valid_dimensions =
      dimensions == nil or
        (kind == "unit" and is_map(dimensions) and map_size(dimensions) in 1..3 and
           Enum.all?(dimensions, fn {name, measurement} ->
             name in [:width, :length, :thickness, "width", "length", "thickness"] and
               match?({:ok, _}, Dimension.parse(measurement))
           end) and
           dimensions |> Map.keys() |> Enum.map(&to_string/1) |> Enum.uniq() |> length() ==
             map_size(dimensions))

    if kind in ["lot", "unit"] and is_binary(code) and String.trim(code) != "" and
         byte_size(code) <= 255 and map_size(value) == if(dimensions == nil, do: 2, else: 3) and
         valid_dimensions,
       do: [],
       else: [
         identity:
           "needs kind (lot or unit), a non-empty code of at most 255 bytes, and valid unit dimensions"
       ]
  end

  defp line_fields(:transfer), do: [:from_location_id, :to_location_id | @common]
  defp line_fields(:output), do: [:location_id, :output_role | @common]
  defp line_fields(_line_kind), do: [:location_id | @common]

  defp required_line_fields(:transfer),
    do: [:item_id, :from_location_id, :to_location_id, :quantity, :observation]

  defp required_line_fields(_line_kind), do: [:item_id, :location_id, :quantity, :observation]

  defp distinct_locations(changeset, :transfer) do
    from = get_field(changeset, :from_location_id)

    if from != nil and from == get_field(changeset, :to_location_id),
      do: add_error(changeset, :to_location_id, "must differ from from_location_id"),
      else: changeset
  end

  defp distinct_locations(changeset, _line_kind), do: changeset

  # numeric(24, 12): at most 12 digits either side of the point. Only a
  # correction adjusts downward, with a negative quantity.
  defp quantity(:quantity, quantity, line_kind) do
    cond do
      line_kind == :adjustment and Decimal.eq?(quantity, 0) ->
        [quantity: "must not be zero"]

      line_kind != :adjustment and not Decimal.gt?(quantity, 0) ->
        [quantity: "must be greater than 0"]

      not Decimal.eq?(Decimal.round(quantity, 12), quantity) ->
        [quantity: "has more than 12 decimal places"]

      Decimal.compare(Decimal.abs(quantity), Decimal.new("1E12")) != :lt ->
        [quantity: "is too large"]

      true ->
        []
    end
  end

  # ============================================================================
  # Fingerprint
  # ============================================================================

  # A defaulted effective time is left out, so a retry that omits it matches.
  defp fingerprint(kind, changes, lists) do
    changes =
      case Map.fetch(changes, :receipt_measurement) do
        {:ok, measurement} ->
          {:ok, fields} = cast_receipt_measurement(measurement)
          Map.put(changes, :receipt_measurement, fields)

        :error ->
          changes
      end

    term = {kind, normalize(changes), normalize(lists)}

    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp normalize(%Decimal{} = decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string()
  defp normalize(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), normalize(v)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value
end
