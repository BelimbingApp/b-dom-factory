defmodule Bilimbi.Factory.ProductionExecution.Trace do
  @moduledoc false

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductDefinition
  alias Bilimbi.Factory.ProductionExecution.Schemas.{Execution, Order}

  def read(scope, company_id, identity_id, direction) do
    trace =
      case direction do
        :backward -> Inventory.trace_backward(scope, company_id, identity_id)
        :forward -> Inventory.trace_forward(scope, company_id, identity_id)
      end

    with {:ok, genealogy} <- trace,
         {:ok, draws} <- draws(scope, company_id, genealogy.identities, direction) do
      transaction_ids =
        (Enum.map(genealogy.identities, & &1.source_transaction_id) ++
           Enum.map(genealogy.links, fn {_, _, transaction_id} -> transaction_id end) ++
           Enum.map(draws, & &1.id))
        |> Enum.uniq()

      executions =
        from(execution in Execution,
          join: order in Order,
          on: order.id == execution.order_id and order.company_id == execution.company_id,
          where:
            execution.company_id == ^company_id and
              execution.inventory_transaction_id in ^transaction_ids,
          order_by: [asc: execution.completed_at, asc: execution.id],
          select: {execution, order}
        )
        |> Repo.all()

      resources =
        executions
        |> Enum.map(fn {execution, _order} -> execution.resource_id end)
        |> Enum.uniq()
        |> Map.new(fn resource_id ->
          {:ok, resource} = ProductDefinition.get_resource(scope, company_id, resource_id)
          {resource_id, resource}
        end)

      runs =
        Enum.map(executions, fn {execution, order} ->
          %{
            id: execution.id,
            order:
              Map.take(order, [:id, :code, :kind, :product_id, :formula_version, :routing_version]),
            operation_code: execution.operation_code,
            resource: Map.fetch!(resources, execution.resource_id),
            started_at: execution.started_at,
            completed_at: execution.completed_at,
            source: execution.source,
            inventory_transaction_id: execution.inventory_transaction_id
          }
        end)

      {:ok, %{material: genealogy, runs: runs}}
    end
  end

  defp draws(_scope, _company_id, _identities, :backward), do: {:ok, []}

  defp draws(scope, company_id, identities, :forward) do
    Enum.reduce_while(identities, {:ok, []}, fn identity, {:ok, acc} ->
      case Inventory.list_identity_draws(scope, company_id, identity.id) do
        {:ok, transactions} -> {:cont, {:ok, transactions ++ acc}}
        error -> {:halt, error}
      end
    end)
  end
end
