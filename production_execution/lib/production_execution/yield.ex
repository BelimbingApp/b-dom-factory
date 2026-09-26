defmodule Bilimbi.Factory.ProductionExecution.Yield do
  @moduledoc false

  import Ecto.Query
  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductionExecution.Schemas.Execution

  def for_run(scope, company_id, execution_id) do
    case Repo.get_by(Execution, id: execution_id, company_id: company_id) do
      nil ->
        {:error, :execution_not_found}

      execution ->
        with {:ok, transaction} <-
               Inventory.get_transaction(scope, company_id, execution.inventory_transaction_id),
             do: {:ok, summarize(execution, transaction)}
    end
  end

  # A unit can be created by one run and drawn in several later operations.
  # Each balance is the whole run in one native unit, with the unit's own input
  # or output shown separately; shared effects cannot be apportioned without an
  # allocation rule.
  def for_unit(scope, company_id, identity_id) do
    with {:ok, identity} <- Inventory.get_identity(scope, company_id, identity_id),
         {:ok, draws} <- Inventory.list_identity_draws(scope, company_id, identity_id) do
      txs = Map.new(draws, &{&1.id, &1})
      ids = [identity.source_transaction_id | Map.keys(txs)] |> Enum.uniq()

      runs =
        from(execution in Execution,
          where:
            execution.company_id == ^company_id and execution.inventory_transaction_id in ^ids,
          order_by: [asc: execution.completed_at, asc: execution.id]
        )
        |> Repo.all()
        |> Enum.map(fn execution ->
          transaction =
            case Map.fetch(txs, execution.inventory_transaction_id) do
              {:ok, transaction} ->
                transaction

              :error ->
                {:ok, transaction} =
                  Inventory.get_transaction(scope, company_id, execution.inventory_transaction_id)

                transaction
            end

          summary = summarize(execution, transaction)

          balances =
            Enum.map(summary.balances, fn balance ->
              unit_entries =
                Enum.filter(
                  transaction.entries,
                  &(&1.role == :stock and &1.identity_id == identity_id and
                      &1.native_unit.id == balance.unit.id)
                )

              Map.merge(balance, %{
                unit_input:
                  unit_entries |> Enum.filter(&Decimal.negative?(&1.native_quantity)) |> sum_abs(),
                unit_output:
                  unit_entries |> Enum.filter(&Decimal.positive?(&1.native_quantity)) |> sum_abs()
              })
            end)

          %{summary | balances: balances}
        end)

      {:ok, %{identity: identity, runs: runs}}
    end
  end

  # Balances are grouped by native unit and never converted between units.
  defp summarize(execution, transaction) do
    balances =
      transaction.entries
      |> Enum.filter(&(&1.role in [:stock, :variance]))
      |> Enum.group_by(& &1.native_unit.id)
      |> Enum.map(fn {_unit_id, entries} -> balance(entries) end)
      |> Enum.sort_by(& &1.unit.id)

    %{
      execution_id: execution.id,
      transaction_id: transaction.id,
      operation_code: execution.operation_code,
      resource_id: execution.resource_id,
      balances: balances
    }
  end

  defp balance(entries) do
    stock = Enum.filter(entries, &(&1.role == :stock))
    outputs = Enum.filter(stock, &Decimal.positive?(&1.native_quantity))
    inputs = Enum.filter(stock, &Decimal.negative?(&1.native_quantity))
    trim = Enum.filter(outputs, &(&1.output_role == "trim"))
    waste = Enum.filter(outputs, &(&1.output_role == "waste"))
    product = Enum.reject(outputs, &(&1.output_role in ["trim", "waste"]))

    variance =
      entries
      |> Enum.filter(&(&1.role == :variance))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.native_quantity, &2))

    %{
      unit: hd(entries).native_unit,
      input: sum_abs(inputs),
      product: sum_abs(product),
      trim: sum_abs(trim),
      waste: sum_abs(waste),
      variance: variance
    }
  end

  defp sum_abs(entries),
    do:
      Enum.reduce(entries, Decimal.new(0), fn entry, total ->
        Decimal.add(total, Decimal.abs(entry.native_quantity))
      end)
end
