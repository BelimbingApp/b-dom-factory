Code.require_file("support/sbg_scenario.ex", __DIR__)

defmodule Bilimbi.Factory.ProductionExecution.SbgScenarioTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}
  alias Bilimbi.Factory.ProductionExecution.SbgScenario

  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  setup do
    context = mill!()
    create_production_tables!()
    context
  end

  test "synthetic SBG glue, coating and slitting reconcile through Factory",
       %{scope: scope, kg: kg} = context do
    scenario = SbgScenario.seed!(context)
    %{items: items, receipts: receipts, orders: orders, runs: runs} = scenario
    {wet, wet_tx} = runs.wet
    {dry, dry_tx} = runs.dry
    {coat, coat_tx} = runs.coat
    {slit, slit_tx} = runs.slit

    assert Enum.map([wet, dry], & &1.source) == ["import", "import"]
    assert Enum.map([coat, slit], & &1.source) == ["live", "live"]
    assert wet.order_id == orders.glue.order.id
    assert coat.order_id == orders.coating.order.id
    assert slit.order_id == orders.slitting.order.id
    assert Enum.all?([wet, dry, coat, slit], &(&1.inventory_transaction_id != nil))

    assert {:ok, selected} =
             ProductDefinition.select_revisions(
               scope,
               73,
               orders.glue.order.product_id,
               orders.glue.order.formula_version,
               orders.glue.order.routing_version
             )

    assert selected.formula.process_config == %{"process_family" => "adhesive glue"}
    assert selected.routing.process_config == %{"process_family" => "adhesive glue"}

    assert {:error, :invalid_process_config} =
             ProductDefinition.publish_formula(scope, 73, orders.glue.order.product_id, %{
               lines: [
                 %{item_id: items["GLUE-DRY"].id, unit_id: kg.id, role: "output", quantity: 1}
               ],
               process_config: %{process_family: "adhesive glue", reactor_capacity_kg: 120}
             })

    assert Enum.map(selected.routing.operations, & &1["code"]) == ~w(MIX-WET DRY)

    assert Decimal.eq?(quantity(wet_tx, items["BA"].id, :input), 70)
    assert Decimal.eq?(quantity(wet_tx, items["ADDITIVE"].id, :input), 30)
    assert Decimal.eq?(quantity(wet_tx, items["GLUE-WET"].id, :output), 98)
    assert Decimal.eq?(quantity(dry_tx, items["GLUE-WET"].id, :input), 98)
    assert Decimal.eq?(quantity(dry_tx, items["GLUE-DRY"].id, :output), 80)
    assert wet_tx.effective_at == wet.completed_at
    assert wet_tx.context.order_or_batch == "SBG-GLUE-BATCH-1"
    assert wet_tx.evidence =~ "synthetic fixture"

    # Historical retries use the same import contract and retain one material effect.
    assert {:ok, retried} =
             ProductionExecution.complete_operation(
               scope,
               73,
               orders.glue.order.id,
               :import,
               scenario.import_request
             )

    assert retried.id == wet.id
    assert retried.inventory_transaction_id == wet_tx.id

    assert Decimal.eq?(quantity(coat_tx, items["BOPP"].id, :input), 50)
    assert Decimal.eq?(quantity(coat_tx, items["GLUE-DRY"].id, :input), 80)
    assert Decimal.eq?(quantity(coat_tx, items["COATED"].id, :output), 125)
    assert coat_tx.context.order_or_batch == "SBG-PO-COAT-1"
    assert coat_tx.context.work_centre == Integer.to_string(coat.resource_id)
    assert Decimal.eq?(quantity(slit_tx, items["COATED"].id, :input), 125)
    assert Decimal.eq?(quantity(slit_tx, items["SLIT-600"].id, :output), 60)
    assert Decimal.eq?(quantity(slit_tx, items["SLIT-300"].id, :output), 30)
    assert Decimal.eq?(quantity(slit_tx, items["TRIM"].id, :output), 30)
    assert Decimal.eq?(quantity(slit_tx, items["WASTE"].id, :output), 3)
    assert Enum.any?(slit_tx.entries, &(&1.output_role == "trim" and &1.observation == :derived))

    assert Enum.any?(
             slit_tx.entries,
             &(&1.output_role == "waste" and &1.observation == :measured)
           )

    assert Enum.any?(
             slit_tx.entries,
             &(&1.role == :variance and Decimal.eq?(&1.native_quantity, 2))
           )

    assert {:ok, slit_yield} = ProductionExecution.get_run_yield(scope, 73, slit.id)

    assert Enum.all?(
             [{:input, 125}, {:product, 90}, {:trim, 30}, {:waste, 3}, {:variance, 2}],
             fn {field, expected} -> Decimal.eq?(Map.fetch!(slit_yield, field), expected) end
           ),
           inspect(slit_yield)

    coated_roll = output_identity(coat_tx, items["COATED"].id)

    assert {:ok, %{runs: unit_runs}} =
             ProductionExecution.get_unit_yield(scope, 73, coated_roll)

    assert Enum.map(unit_runs, & &1.execution_id) == [coat.id, slit.id]
    unit_yield = List.last(unit_runs)
    assert unit_yield.execution_id == slit.id
    assert Decimal.eq?(unit_yield.unit_input, 125)
    assert Decimal.eq?(hd(unit_runs).unit_output, 125)

    receipt_identities = MapSet.new(receipts, fn {_sku, {_tx, identity_id}} -> identity_id end)
    receipt_transactions = MapSet.new(receipts, fn {_sku, {tx, _}} -> tx.id end)

    for {sku, code} <- [{"SLIT-600", "SLIT-600-1"}, {"SLIT-300", "SLIT-300-1"}] do
      roll = output_identity(slit_tx, items[sku].id)
      assert {:ok, %{code: ^code}} = Inventory.get_identity(scope, 73, roll)
      assert {:ok, identity} = Inventory.get_identity(scope, 73, roll)
      assert identity.dimensions.width.unit == :mm
      assert identity.dimensions.width.provenance == :measured

      assert Decimal.eq?(
               identity.dimensions.width.value,
               if(sku == "SLIT-600", do: 600, else: 300)
             )

      assert {:ok, [%{location: location, quantity: quantity}]} =
               Inventory.get_identity_positions(scope, 73, roll)

      assert location.code == "SLITTER-A"
      assert Decimal.eq?(quantity, if(sku == "SLIT-600", do: 60, else: 30))

      assert {:ok, %{runs: [%{execution_id: execution_id, unit_output: unit_output}]}} =
               ProductionExecution.get_unit_yield(scope, 73, roll)

      assert execution_id == slit.id
      assert Decimal.eq?(unit_output, if(sku == "SLIT-600", do: 60, else: 30))

      assert {:ok, backward} = ProductionExecution.trace_backward(scope, 73, roll)
      assert Enum.map(backward.runs, & &1.operation_code) == ~w(MIX-WET DRY COAT SLIT)

      assert MapSet.subset?(
               receipt_identities,
               MapSet.new(backward.material.identities, & &1.id)
             )

      assert receipt_transactions == MapSet.new(backward.material.receipts, & &1.id)

      assert {:ok, forward} =
               ProductionExecution.trace_forward(scope, 73, elem(receipts["BA"], 1))

      assert roll in Enum.map(forward.material.identities, & &1.id)
    end
  end

  defp output_identity(tx, item_id) do
    [identity_id] =
      for entry <- tx.entries,
          entry.role == :stock and entry.item_id == item_id and
            Decimal.gt?(entry.native_quantity, 0),
          do: entry.identity_id

    identity_id
  end

  defp quantity(tx, item_id, direction) do
    tx.entries
    |> Enum.filter(fn entry ->
      entry.role == :stock and entry.item_id == item_id and
        case direction do
          :input -> Decimal.lt?(entry.native_quantity, 0)
          :output -> Decimal.gt?(entry.native_quantity, 0)
        end
    end)
    |> Enum.reduce(Decimal.new(0), fn entry, total ->
      Decimal.add(total, Decimal.abs(entry.native_quantity))
    end)
  end
end
