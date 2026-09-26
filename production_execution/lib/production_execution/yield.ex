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
             {:ok, corrections} <-
               Inventory.list_corrections(scope, company_id, transaction.id),
             do: {:ok, summarize(execution, transaction, corrections, nil)}
    end
  end

  # A unit can be created by one run and drawn in several later operations.
  # Each balance is the whole run in one native unit, with the unit's own input
  # or output shown separately; shared effects cannot be apportioned without an
  # allocation rule.
  def for_unit(scope, company_id, identity_id) do
    with {:ok, identity} <- Inventory.get_identity(scope, company_id, identity_id),
         {:ok, draws} <- Inventory.list_identity_draws(scope, company_id, identity_id) do
      ids = [identity.source_transaction_id | Enum.map(draws, & &1.id)] |> Enum.uniq()

      runs =
        from(execution in Execution,
          where:
            execution.company_id == ^company_id and execution.inventory_transaction_id in ^ids,
          order_by: [asc: execution.completed_at, asc: execution.id]
        )
        |> Repo.all()
        |> Enum.map(fn execution ->
          {:ok, transaction} =
            Inventory.get_transaction(scope, company_id, execution.inventory_transaction_id)

          {:ok, corrections} = Inventory.list_corrections(scope, company_id, transaction.id)
          summarize(execution, transaction, corrections, identity_id)
        end)

      {:ok, %{identity: identity, runs: runs}}
    end
  end

  # Balances are grouped by native unit and never converted between units.
  # A correction entry nets into the side of the run entry it adjusts.
  defp summarize(execution, transaction, corrections, identity_id) do
    original = Enum.filter(transaction.entries, &(&1.role in [:stock, :variance]))

    adjustments =
      corrections
      |> Enum.flat_map(& &1.entries)
      |> Enum.filter(&(&1.role == :stock))
      |> Enum.map(fn entry ->
        case Enum.find(
               original,
               &(&1.role == :stock and &1.item_id == entry.item_id and
                   &1.identity_id == entry.identity_id)
             ) do
          nil -> {side(entry), entry}
          adjusted -> {side(adjusted), entry}
        end
      end)

    balances =
      original
      |> Enum.map(&{side(&1), &1})
      |> Kernel.++(adjustments)
      |> Enum.group_by(fn {_side, entry} -> entry.native_unit.id end)
      |> Enum.map(fn {_unit_id, sided} -> balance(sided, identity_id) end)
      |> Enum.sort_by(& &1.unit.id)

    %{
      execution_id: execution.id,
      transaction_id: transaction.id,
      operation_code: execution.operation_code,
      resource_id: execution.resource_id,
      corrected: corrections != [],
      correction_transaction_ids: Enum.map(corrections, & &1.id),
      balances: balances
    }
  end

  defp side(%{role: :variance}), do: :variance

  defp side(entry) do
    cond do
      Decimal.negative?(entry.native_quantity) -> :input
      entry.output_role == "trim" -> :trim
      entry.output_role == "waste" -> :waste
      true -> :product
    end
  end

  defp balance(sided, identity_id) do
    balance = %{
      unit: sided |> hd() |> elem(1) |> Map.fetch!(:native_unit),
      input: Decimal.negate(total(sided, [:input])),
      product: total(sided, [:product]),
      trim: total(sided, [:trim]),
      waste: total(sided, [:waste]),
      variance: total(sided, [:variance])
    }

    if identity_id do
      own = Enum.filter(sided, fn {_side, entry} -> entry.identity_id == identity_id end)

      Map.merge(balance, %{
        unit_input: Decimal.negate(total(own, [:input])),
        unit_output: total(own, [:product, :trim, :waste])
      })
    else
      balance
    end
  end

  defp total(sided, sides) do
    for {side, entry} <- sided, side in sides, reduce: Decimal.new(0) do
      sum -> Decimal.add(sum, entry.native_quantity)
    end
  end
end
