defmodule Bilimbi.Factory.ProductionExecution.Yield do
  @moduledoc false

  import Ecto.Query
  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductionExecution.Schemas.Execution
  alias Bilimbi.Factory.ProductionExecution.Wastage

  def for_run(scope, company_id, execution_id) do
    case Repo.get_by(Execution, id: execution_id, company_id: company_id) do
      nil ->
        {:error, :execution_not_found}

      execution ->
        with {:ok, transaction} <-
               Inventory.get_transaction(scope, company_id, execution.inventory_transaction_id),
             {:ok, corrections} <-
               Inventory.list_corrections(scope, company_id, transaction.id),
             {:ok, balance} <-
               Inventory.get_transaction_balance(scope, company_id, transaction.id),
             {:ok, wastage} <- wastage(scope, company_id, execution),
             do: {:ok, summarize(execution, transaction, corrections, balance, wastage, nil)}
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
          {:ok, balance} = Inventory.get_transaction_balance(scope, company_id, transaction.id)
          {:ok, wastage} = wastage(scope, company_id, execution)
          summarize(execution, transaction, corrections, balance, wastage, identity_id)
        end)

      {:ok, %{identity: identity, runs: runs}}
    end
  end

  # The Inventory transactions of a run's wastage, each with its corrections.
  defp wastage(scope, company_id, execution) do
    company_id
    |> Wastage.transaction_ids(execution.id)
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      with {:ok, transaction} <- Inventory.get_transaction(scope, company_id, id),
           {:ok, corrections} <- Inventory.list_corrections(scope, company_id, id) do
        {:cont, {:ok, acc ++ [transaction | corrections]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # Balances are grouped by native unit and never converted between units;
  # Inventory's cross-unit balance is carried as read, so a run only has one
  # in a unit every line was posted in. A correction entry nets
  # into the side of the run entry it adjusts. Recorded wastage draws one of
  # the run's own stock lines: the draw nets into that line's side and the
  # same quantity counts as waste, so input still equals product, trim,
  # waste, and variance. Its corrections net the same way.
  defp summarize(execution, transaction, corrections, balance, wastage, identity_id) do
    original = Enum.filter(transaction.entries, &(&1.role in [:stock, :variance]))

    adjustments =
      corrections
      |> Enum.flat_map(& &1.entries)
      |> Enum.filter(&(&1.role == :stock))
      |> Enum.map(&{adjusted_side(original, &1), &1})

    scrapped =
      for posting <- wastage,
          entry <- posting.entries,
          entry.role == :stock,
          sided <- [
            {adjusted_side(original, entry), entry},
            {:wastage, %{entry | native_quantity: Decimal.negate(entry.native_quantity)}}
          ],
          do: sided

    balances =
      original
      |> Enum.map(&{side(&1), &1})
      |> Kernel.++(adjustments)
      |> Kernel.++(scrapped)
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
      wastage_transaction_ids: Enum.map(wastage, & &1.id),
      balances: balances,
      cross_unit: balance.cross_unit
    }
  end

  defp adjusted_side(original, entry) do
    case Enum.find(
           original,
           &(&1.role == :stock and &1.item_id == entry.item_id and
               &1.identity_id == entry.identity_id)
         ) do
      nil -> side(entry)
      adjusted -> side(adjusted)
    end
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
      waste: total(sided, [:waste, :wastage]),
      wastage: total(sided, [:wastage]),
      variance: total(sided, [:variance])
    }

    if identity_id do
      own = Enum.filter(sided, fn {_side, entry} -> entry.identity_id == identity_id end)

      Map.merge(balance, %{
        unit_input: Decimal.negate(total(own, [:input])),
        unit_output: total(own, [:product, :trim, :waste, :wastage])
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
