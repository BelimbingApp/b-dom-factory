defmodule Bilimbi.Factory.ProductionExecution do
  @moduledoc """
  Production orders and completed operation executions.

  Live commands and historical imports use `complete_operation/5`. Execution
  and its Inventory material effects commit in one database transaction.
  """
  import Ecto.Query
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductDefinition
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
         {:ok, request} <- validate(scope, company_id, order, selected, source, attrs) do
      Repo.transaction(fn ->
        Repo.one!(
          from(o in Order,
            where: o.id == ^order_id and o.company_id == ^company_id,
            lock: "FOR UPDATE"
          )
        )

        case Repo.get_by(Execution, company_id: company_id, request_id: request.request_id) do
          nil ->
            commit(scope, company_id, order, request)

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

  defp commit(scope, company_id, order, request) do
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
          {:ok, execution} -> execution |> Repo.reload!() |> Map.take(@execution_fields)
          {:error, reason} -> Repo.rollback(reason)
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

  @line_keys ~w(item_id location_id quantity unit_id conversion_version observation evidence output_role)a
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
