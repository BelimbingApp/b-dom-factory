defmodule Bilimbi.Factory.ProductionExecution do
  @moduledoc """
  Production orders and completed operation executions.

  Live commands and historical imports use `complete_operation/5`. Execution
  and its Inventory material effects commit in one database transaction.

  A material hold override is authorized against the authenticated user sealed
  on the Scope, who is recorded as its recorder; an impersonated session is
  refused. Historical imports keep their source approver as separate evidence.
  """
  import Ecto.Query
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductDefinition
  alias Bilimbi.Factory.ProductionExecution.HoldOverride
  alias Bilimbi.Factory.ProductionExecution.Trace
  alias Bilimbi.Factory.ProductionExecution.Yield
  alias Bilimbi.Factory.ProductionExecution.Schemas.{Execution, Order}

  @order_fields [
    :id,
    :company_id,
    :code,
    :kind,
    :product_id,
    :formula_version,
    :routing_version,
    :demand_ref
  ]
  @execution_fields [
    :id,
    :company_id,
    :order_id,
    :request_id,
    :source,
    :operation_code,
    :resource_id,
    :operator_type,
    :operator_id,
    :started_at,
    :completed_at,
    :inputs,
    :outputs,
    :variance,
    :evidence,
    :inventory_transaction_id,
    :formula_version,
    :routing_version
  ]

  @doc "Creates an order or batch with exact published definition revisions."
  def create_order(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    product_id = value(attrs, :product_id)
    formula_version = value(attrs, :formula_version)
    routing_version = value(attrs, :routing_version)

    with {:ok, _selected} <-
           ProductDefinition.select_revisions(
             scope,
             company_id,
             product_id,
             formula_version,
             routing_version
           ) do
      %{
        company_id: company_id,
        code: value(attrs, :code),
        kind: value(attrs, :kind),
        product_id: product_id,
        formula_version: formula_version,
        routing_version: routing_version,
        demand_ref: value(attrs, :demand_ref)
      }
      |> Order.changeset()
      |> Repo.insert()
      |> case do
        {:ok, order} -> {:ok, Map.take(order, @order_fields)}
        error -> error
      end
    end
  end

  def get_order(%Scope{} = scope, company_id, order_id) do
    with {:ok, _company} <- company(scope, company_id) do
      case Repo.get_by(Order, id: order_id, company_id: company_id) do
        nil -> {:error, :order_not_found}
        order -> {:ok, Map.take(order, @order_fields)}
      end
    end
  end

  @doc """
  Completes one routed operation. `source` is `:live` or `:import`; both use
  identical validation and posting. The request contains a company-unique
  `request_id`, operation code, resource ID, operator type and ID, start and
  completion times, evidence, actual input and output lines, and optional
  Inventory variance evidence. An identical retry returns the original result.
  """
  def complete_operation(%Scope{} = scope, company_id, order_id, source, attrs)
      when source in [:live, :import] and is_map(attrs) do
    with {:ok, order} <- get_order(scope, company_id, order_id),
         {:ok, selected} <- selected_revisions(scope, company_id, order),
         {:ok, request} <- validate(scope, company_id, order, selected, source, attrs),
         {:ok, overrides} <- check_holds(scope, company_id, request) do
      Repo.transaction(fn ->
        Repo.one!(
          from(o in Order,
            where: o.id == ^order_id and o.company_id == ^company_id,
            lock: "FOR UPDATE"
          )
        )

        case Repo.get_by(Execution, company_id: company_id, request_id: request.request_id) do
          nil ->
            commit(scope, company_id, order, request, overrides)

          existing when existing.request_fingerprint == request.request_fingerprint ->
            Map.take(existing, @execution_fields)

          _existing ->
            Repo.rollback(:request_id_conflict)
        end
      end)
    end
  end

  def complete_operation(%Scope{}, _company_id, _order_id, _source, _attrs),
    do: {:error, :invalid_execution}

  def get_execution(%Scope{} = scope, company_id, execution_id) do
    with {:ok, _company} <- company(scope, company_id) do
      case Repo.get_by(Execution, id: execution_id, company_id: company_id) do
        nil -> {:error, :execution_not_found}
        execution -> {:ok, Map.take(execution, @execution_fields)}
      end
    end
  end

  @doc "Reads one run's Inventory balances per native unit, net of its corrections: input, product, trim, waste, and signed variance; `cross_unit` carries Inventory's balance across units where every line was posted in the unit."
  def get_run_yield(%Scope{} = scope, company_id, execution_id) do
    with {:ok, _company} <- company(scope, company_id),
         do: Yield.for_run(scope, company_id, execution_id)
  end

  @doc "Reads whole-run balances per native unit, net of corrections, for the production creation and draws of a unit, with its own input or output quantities."
  def get_unit_yield(%Scope{} = scope, company_id, identity_id) do
    with {:ok, _company} <- company(scope, company_id),
         do: Yield.for_unit(scope, company_id, identity_id)
  end

  @doc "Adds production order, operation, and resource context to Inventory's backward genealogy."
  def trace_backward(%Scope{} = scope, company_id, identity_id),
    do: Trace.read(scope, company_id, identity_id, :backward)

  @doc "Adds production order, operation, and resource context to Inventory's forward genealogy."
  def trace_forward(%Scope{} = scope, company_id, identity_id),
    do: Trace.read(scope, company_id, identity_id, :forward)

  @doc "Returns immutable material hold override evidence for one execution."
  def list_hold_overrides(%Scope{} = scope, company_id, execution_id) do
    with {:ok, _execution} <- get_execution(scope, company_id, execution_id) do
      rows =
        Repo.all(
          from(o in HoldOverride,
            where: o.company_id == ^company_id and o.execution_id == ^execution_id,
            order_by: [asc: o.id]
          )
        )

      {:ok,
       Enum.map(
         rows,
         &Map.take(&1, [
           :id,
           :execution_id,
           :inventory_transaction_id,
           :source_transaction_id,
           :identity_id,
           :item_id,
           :source,
           :actor_type,
           :actor_id,
           :acting_for_user_id,
           :recorded_by_type,
           :recorded_by_id,
           :recorded_by_acting_for_user_id,
           :reason,
           :evidence,
           :occurred_at
         ])
       )}
    end
  end

  defp commit(scope, company_id, order, request, overrides) do
    context = %{
      operation_execution: request.request_id,
      order_or_batch: order.code,
      work_centre: Integer.to_string(request.resource_id)
    }

    posting = %{
      request_id: "pe:" <> request.request_id,
      actor_type: request.operator_type,
      actor_id: request.operator_id,
      evidence: request.evidence,
      effective_at: request.completed_at,
      context: context,
      inputs: request.inputs,
      outputs: request.outputs,
      variance: request.variance
    }

    result =
      cond do
        request.inputs != [] and request.outputs != [] ->
          Inventory.record_transform(scope, company_id, posting, __MODULE__)

        request.outputs != [] ->
          Inventory.record_output(
            scope,
            company_id,
            posting
            |> Map.take([:request_id, :actor_type, :actor_id, :evidence, :effective_at, :context])
            |> Map.put(:lines, request.outputs),
            __MODULE__
          )

        true ->
          Inventory.record_production_consumption(
            scope,
            company_id,
            posting
            |> Map.take([:request_id, :actor_type, :actor_id, :evidence, :effective_at, :context])
            |> Map.put(:lines, request.inputs),
            __MODULE__
          )
      end

    case result do
      {:ok, transaction} ->
        request
        |> Map.put(:company_id, company_id)
        |> Map.put(:order_id, order.id)
        |> Map.put(:formula_version, order.formula_version)
        |> Map.put(:routing_version, order.routing_version)
        |> Map.put(:inventory_transaction_id, transaction.id)
        |> Execution.changeset()
        |> Repo.insert()
        |> case do
          {:ok, execution} ->
            Enum.each(overrides, fn override ->
              override
              |> Map.merge(%{
                company_id: company_id,
                execution_id: execution.id,
                inventory_transaction_id: transaction.id
              })
              |> HoldOverride.changeset()
              |> Repo.insert!()
            end)

            execution |> Repo.reload!() |> Map.take(@execution_fields)

          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp validate(scope, company_id, order, selected, source, attrs) do
    code = value(attrs, :operation_code)
    resource_id = value(attrs, :resource_id)
    operation = Enum.find(selected.routing.operations, &(&1["code"] == code))
    started_at = value(attrs, :started_at)
    completed_at = value(attrs, :completed_at)
    inputs = value(attrs, :inputs)
    outputs = value(attrs, :outputs)
    request_id = value(attrs, :request_id)
    evidence = value(attrs, :evidence)
    operator_type = value(attrs, :operator_type)
    operator_id = value(attrs, :operator_id)
    variance = value(attrs, :variance)
    hold_override = value(attrs, :hold_override)

    with true <- is_binary(request_id) and request_id != "" and byte_size(request_id) <= 240,
         true <- is_binary(evidence) and evidence != "",
         true <- is_binary(operator_type) and operator_type != "",
         true <- is_integer(operator_id) and operator_id >= 0,
         true <- is_struct(started_at, DateTime) and is_struct(completed_at, DateTime),
         true <- DateTime.compare(started_at, completed_at) != :gt,
         true <- DateTime.compare(completed_at, DateTime.utc_now()) != :gt,
         true <- operation != nil and resource_id in operation["allowed_resource_ids"],
         {:ok, _resource} <- ProductDefinition.get_resource(scope, company_id, resource_id),
         {:ok, inputs} <- lines(inputs, operation["inputs"]),
         {:ok, outputs} <- lines(outputs, operation["outputs"]),
         {:ok, holds} <- hold_rules(selected, inputs),
         {:ok, hold_override} <-
           validate_override(scope, company_id, source, completed_at, hold_override),
         true <- inputs != [] or outputs != [],
         true <- is_nil(variance) or (is_map(variance) and inputs != [] and outputs != []) do
      request = %{
        request_id: request_id,
        source: Atom.to_string(source),
        operation_code: code,
        resource_id: resource_id,
        operator_type: operator_type,
        operator_id: operator_id,
        started_at: started_at,
        completed_at: completed_at,
        inputs: inputs,
        outputs: outputs,
        variance: variance,
        holds: holds,
        hold_override: hold_override,
        evidence: evidence
      }

      fingerprint =
        :crypto.hash(:sha256, :erlang.term_to_binary({order.id, request}, [:deterministic]))
        |> Base.encode16(case: :lower)

      {:ok, Map.put(request, :request_fingerprint, fingerprint)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_execution}
    end
  end

  @line_keys ~w(item_id location_id quantity unit_id conversion_version observation evidence output_role identity identity_id)a
  defp lines(lines, allowed) when is_list(lines) do
    if Enum.all?(lines, fn line ->
         is_map(line) and value(line, :item_id) in allowed and
           is_integer(value(line, :location_id)) and value(line, :location_id) > 0 and
           valid_quantity?(value(line, :quantity))
       end) do
      {:ok,
       Enum.map(lines, fn line ->
         Map.new(@line_keys, fn key -> {key, value(line, key)} end)
         |> Map.reject(fn {_key, value} -> is_nil(value) end)
         |> Map.update!(:quantity, &(Decimal.new(to_string(&1)) |> Decimal.to_string()))
       end)}
    else
      {:error, :invalid_lines}
    end
  end

  defp lines(_, _), do: {:error, :invalid_lines}

  defp valid_quantity?(quantity) do
    try do
      Decimal.gt?(Decimal.new(to_string(quantity)), 0)
    rescue
      _ -> false
    end
  end

  defp hold_rules(selected, inputs) do
    formula_rules = selected.formula.process_config["material_hold_rules"] || %{}
    routing_rules = selected.routing.process_config["material_hold_rules"] || %{}

    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, acc} ->
      rules =
        for line <- selected.formula.lines,
            line["role"] == "input" and line["item_id"] == input.item_id,
            not is_nil(line["material_hold_rule"]),
            do: line["material_hold_rule"]

      key = Integer.to_string(input.item_id)
      rules = rules ++ List.wrap(formula_rules[key]) ++ List.wrap(routing_rules[key])

      cond do
        rules == [] ->
          {:cont, {:ok, acc}}

        Enum.all?(rules, &(is_map(&1) and is_integer(&1["hours"]) and &1["hours"] > 0)) ->
          {:cont, {:ok, [{input, Enum.max_by(rules, & &1["hours"])["hours"]} | acc]}}

        true ->
          {:halt, {:error, :invalid_material_hold_rule}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  @live_override_keys [:reason, :evidence, :occurred_at] ++
                        ~w(reason evidence occurred_at)
  @import_override_keys [:reason, :evidence, :occurred_at, :approver] ++
                          ~w(reason evidence occurred_at approver)

  defp validate_override(_scope, _company_id, _source, _completed_at, nil), do: {:ok, nil}

  defp validate_override(scope, company_id, source, completed_at, override)
       when is_map(override) do
    reason = value(override, :reason)
    evidence = value(override, :evidence)
    occurred_at = value(override, :occurred_at)

    keys = if source == :live, do: @live_override_keys, else: @import_override_keys

    with true <- Enum.all?(Map.keys(override), &(&1 in keys)),
         true <- nonblank?(reason),
         {:ok, actor} <- override_actor(scope, company_id),
         {:ok, approver} <- override_approver(source, actor, override),
         true <-
           (source == :live and is_nil(evidence) and is_nil(occurred_at)) or
             (source == :import and nonblank?(evidence) and is_struct(occurred_at, DateTime) and
                DateTime.compare(occurred_at, completed_at) != :gt) do
      {:ok,
       %{
         actor_type: approver && approver.type,
         actor_id: approver && approver.id,
         acting_for_user_id: approver && approver.acting_for_user_id,
         recorded_by_type: Authz.Actor.principal_type(actor),
         recorded_by_id: actor.id,
         recorded_by_acting_for_user_id: actor.acting_for_user_id,
         reason: String.trim(reason),
         evidence: evidence && String.trim(evidence),
         occurred_at: occurred_at
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_hold_override}
    end
  end

  defp validate_override(_scope, _company_id, _source, _completed_at, _override),
    do: {:error, :invalid_hold_override}

  defp override_actor(scope, company_id) do
    case {Scope.actor(scope), Authz.scope_actor(scope)} do
      {%{impersonator_id: nil}, {:ok, %Authz.Actor{company_id: ^company_id} = actor}} ->
        {:ok, actor}

      {%{impersonator_id: nil}, {:ok, _actor}} ->
        {:error, :hold_override_actor_mismatch}

      {%{impersonator_id: nil}, {:error, :no_authenticated_actor}} ->
        {:error, :hold_override_denied}

      _impersonated ->
        {:error, :override_refused_under_impersonation}
    end
  end

  defp override_approver(:live, actor, _override) do
    {:ok,
     %{
       type: Authz.Actor.principal_type(actor),
       id: actor.id,
       acting_for_user_id: actor.acting_for_user_id
     }}
  end

  defp override_approver(:import, _actor, override) do
    case value(override, :approver) do
      nil ->
        {:ok, nil}

      approver when is_map(approver) ->
        type = value(approver, :type)
        id = value(approver, :id)
        acting_for = value(approver, :acting_for_user_id)

        if is_integer(id) and id > 0 and
             ((type == "user" and is_nil(acting_for)) or
                (type == "agent" and is_integer(acting_for) and acting_for > 0)) do
          {:ok, %{type: type, id: id, acting_for_user_id: acting_for}}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp nonblank?(text), do: is_binary(text) and String.trim(text) != ""

  defp check_holds(scope, company_id, request) do
    recorded? =
      Repo.exists?(
        from(e in Execution,
          where: e.company_id == ^company_id and e.request_id == ^request.request_id
        )
      )

    if recorded? do
      {:ok, []}
    else
      request.holds
      |> Enum.uniq_by(fn {line, _hours} -> {Map.get(line, :identity_id), line.item_id} end)
      |> Enum.reduce_while({:ok, []}, fn {line, hours}, {:ok, acc} ->
        case check_hold(scope, company_id, request, line, hours) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, override} -> {:cont, {:ok, [override | acc]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp check_hold(scope, company_id, request, line, hours) do
    identity_id = Map.get(line, :identity_id)

    with true <- is_integer(identity_id) and identity_id > 0,
         {:ok, identity} <- Inventory.get_identity(scope, company_id, identity_id),
         true <- identity.item_id == line.item_id,
         {:ok, source} <-
           Inventory.get_transaction(scope, company_id, identity.source_transaction_id),
         true <- source.kind in [:receipt, :output, :transform],
         true <-
           Enum.any?(source.entries, fn entry ->
             entry.identity_id == identity_id and entry.role == :stock and
               entry.item_id == line.item_id and Decimal.gt?(entry.native_quantity, 0)
           end),
         true <- DateTime.compare(source.effective_at, request.completed_at) != :gt do
      if DateTime.diff(request.completed_at, source.effective_at, :second) >= hours * 3600 do
        {:ok, nil}
      else
        authorize_hold_override(
          scope,
          request,
          line,
          identity.source_transaction_id,
          identity_id
        )
      end
    else
      _ -> {:error, :invalid_hold_source}
    end
  end

  defp authorize_hold_override(_scope, %{hold_override: nil}, _line, _source_id, _identity_id),
    do: {:error, :material_held}

  defp authorize_hold_override(scope, request, line, source_id, identity_id) do
    resource = Authz.resource("factory.material_unit", identity_id)
    capability = "factory.production-execution.material-hold.override"

    if Authz.can(scope, capability, resource).allowed do
      {:ok,
       Map.merge(request.hold_override, %{
         source: request.source,
         source_transaction_id: source_id,
         identity_id: identity_id,
         item_id: line.item_id,
         occurred_at: request.hold_override.occurred_at || DateTime.utc_now()
       })}
    else
      {:error, :hold_override_denied}
    end
  end

  defp selected_revisions(scope, company_id, order),
    do:
      ProductDefinition.select_revisions(
        scope,
        company_id,
        order.product_id,
        order.formula_version,
        order.routing_version
      )

  defp company(scope, company_id), do: Company.get_company(scope, company_id)
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
