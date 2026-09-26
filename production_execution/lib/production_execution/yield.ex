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
             {:ok, summary} <- summarize(execution, transaction) do
          {:ok, summary}
        end
    end
  end

  # A unit can be created by one run and drawn in several later operations.
  # Each balance is the whole run, with the unit's own input or output shown
  # separately; shared effects cannot be apportioned without an allocation rule.
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
        |> Enum.reduce_while({:ok, []}, fn execution, {:ok, acc} ->
          transaction =
            case Map.fetch(txs, execution.inventory_transaction_id) do
              {:ok, transaction} ->
                transaction

              :error ->
                {:ok, transaction} =
                  Inventory.get_transaction(scope, company_id, execution.inventory_transaction_id)

                transaction
            end

          unit_input =
            transaction.entries
            |> Enum.filter(
              &(&1.role == :stock and &1.identity_id == identity_id and
                  Decimal.negative?(&1.native_quantity))
            )
            |> sum_abs()

          unit_output =
            transaction.entries
            |> Enum.filter(
              &(&1.role == :stock and &1.identity_id == identity_id and
                  Decimal.positive?(&1.native_quantity))
            )
            |> sum_abs()

          case summarize(execution, transaction) do
            {:ok, summary} ->
              summary = Map.merge(summary, %{unit_input: unit_input, unit_output: unit_output})
              {:cont, {:ok, [summary | acc]}}

            error ->
              {:halt, error}
          end
        end)

      case runs do
        {:ok, summaries} -> {:ok, %{identity: identity, runs: Enum.reverse(summaries)}}
        error -> error
      end
    end
  end

  defp summarize(execution, transaction) do
    units = transaction.entries |> Enum.map(& &1.native_unit.id) |> Enum.uniq()

    if length(units) == 1 do
      {:ok, balance(execution, transaction)}
    else
      {:error, :mixed_native_units}
    end
  end

  defp balance(execution, transaction) do
    stock = Enum.filter(transaction.entries, &(&1.role == :stock))
    outputs = Enum.filter(stock, &Decimal.positive?(&1.native_quantity))
    inputs = Enum.filter(stock, &Decimal.negative?(&1.native_quantity))
    trim = Enum.filter(outputs, &(&1.output_role == "trim"))
    waste = Enum.filter(outputs, &(&1.output_role == "waste"))
    product = Enum.reject(outputs, &(&1.output_role in ["trim", "waste"]))

    variance =
      transaction.entries
      |> Enum.filter(&(&1.role == :variance))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.native_quantity, &2))

    %{
      execution_id: execution.id,
      transaction_id: transaction.id,
      operation_code: execution.operation_code,
      resource_id: execution.resource_id,
      input: sum_abs(inputs),
      product: sum_abs(product),
      trim: sum_abs(trim),
      waste: sum_abs(waste),
      variance: variance,
      unit: transaction.entries |> hd() |> Map.fetch!(:native_unit)
    }
  end

  defp sum_abs(entries),
    do:
      Enum.reduce(entries, Decimal.new(0), fn entry, total ->
        Decimal.add(total, Decimal.abs(entry.native_quantity))
      end)
end
