Code.require_file("support/sbg_scenario.ex", __DIR__)

defmodule Bilimbi.Factory.ProductionExecution.SbgScenarioTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.{ProductDefinition, ProductionExecution}
  alias Bilimbi.Factory.ProductionExecution.SbgScenario

  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  setup do
    context = mill!()
    create_production_tables!()
    context
  end

  test "synthetic SBG glue, coating and slitting reconcile through Factory",
       %{scope: scope} = context do
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

    assert selected.formula.process_config["process_family"] == "adhesive glue"
    assert scenario.glue_config.reactor_capacity_kg == 120
    assert scenario.glue_config.previous_batch == "SBG-GLUE-BATCH-0"
    assert scenario.glue_config.cleaning_sequence == "CLEAN-1"
    assert scenario.glue_config.quality_result_ref == "quality:pending"
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

    [wide_roll | _] = scenario.slit_ids
    assert {:ok, backward} = ProductionExecution.trace_backward(scope, 73, wide_roll)
    assert Enum.map(backward.runs, & &1.operation_code) == ~w(MIX-WET DRY COAT SLIT)

    assert MapSet.subset?(
             MapSet.new([
               elem(receipts["BA"], 1),
               elem(receipts["ADDITIVE"], 1),
               elem(receipts["BOPP"], 1)
             ]),
             MapSet.new(backward.material.identities, & &1.id)
           )

    assert MapSet.new(Enum.map(receipts, fn {_sku, {tx, _}} -> tx.id end)) ==
             MapSet.new(backward.material.receipts, & &1.id)

    assert {:ok, forward} = ProductionExecution.trace_forward(scope, 73, elem(receipts["BA"], 1))
    assert wide_roll in Enum.map(forward.material.identities, & &1.id)
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
