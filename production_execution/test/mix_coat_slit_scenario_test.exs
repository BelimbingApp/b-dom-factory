Code.require_file("support/mix_coat_slit_scenario.ex", __DIR__)

defmodule Bilimbi.Factory.ProductionExecution.MixCoatSlitScenarioTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}
  alias Bilimbi.Factory.ProductionExecution.MixCoatSlitScenario

  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  setup do
    context = mill!()
    create_production_tables!()
    context
  end

  test "a synthetic mix, coat and slit chain reconciles through Factory",
       %{scope: scope, kg: kg} = context do
    scenario = MixCoatSlitScenario.seed!(context)
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

    assert Decimal.eq?(quantity(wet_tx, items["RESIN"].id, :input), 70)
    assert Decimal.eq?(quantity(wet_tx, items["ADDITIVE"].id, :input), 30)
    assert Decimal.eq?(quantity(wet_tx, items["GLUE-WET"].id, :output), 98)
    assert Decimal.eq?(quantity(dry_tx, items["GLUE-WET"].id, :input), 98)
    assert Decimal.eq?(quantity(dry_tx, items["GLUE-DRY"].id, :output), 80)
    assert wet_tx.effective_at == wet.completed_at
    assert wet_tx.context.order_or_batch == "GLUE-BATCH-1"
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

    # Coating mixes film by area with glue by mass. Each native unit balances
    # on its own: the area is exact, and the glue's mass is a variance in
    # kilograms with its own evidence, because the coated roll is not weighed.
    assert Decimal.eq?(quantity(coat_tx, items["FILM"].id, :input), 500)
    assert Decimal.eq?(quantity(coat_tx, items["GLUE-DRY"].id, :input), 80)
    assert Decimal.eq?(quantity(coat_tx, items["COATED"].id, :output), 500)
    assert coat_tx.context.order_or_batch == "PO-COAT-1"
    assert coat_tx.context.work_centre == Integer.to_string(coat.resource_id)

    assert [%{native_unit: ^kg} = glue_variance] =
             Enum.filter(coat_tx.entries, &(&1.role == :variance))

    assert Decimal.eq?(glue_variance.native_quantity, 80)
    assert glue_variance.evidence =~ "glue pump totaliser"

    # Across units, the film and the coated roll have explicit conversions to
    # kilograms, so a mass balance is read: 50 kg film and 80 kg glue in,
    # 125 kg coated out, 5 kg apart. Nothing records that 5 kg as an entry.
    assert {:ok, %Inventory.Balance{cross_unit: [coat_mass]}} =
             Inventory.get_transaction_balance(scope, 73, coat_tx.id)

    assert coat_mass.unit.id == kg.id
    assert Decimal.eq?(coat_mass.input, 130)
    assert Decimal.eq?(coat_mass.output, 125)
    assert Decimal.eq?(coat_mass.difference, 5)

    assert Enum.map(coat_mass.conversions, & &1.item_id) |> Enum.sort() ==
             Enum.sort([items["FILM"].id, items["COATED"].id])

    assert Decimal.eq?(quantity(slit_tx, items["COATED"].id, :input), 500)
    assert Decimal.eq?(quantity(slit_tx, items["SLIT-600"].id, :output), 250)
    assert Decimal.eq?(quantity(slit_tx, items["SLIT-300"].id, :output), 125)
    assert Decimal.eq?(quantity(slit_tx, items["TRIM"].id, :output), 120)
    assert Decimal.eq?(quantity(slit_tx, items["WASTE"].id, :output), 3)
    assert Enum.any?(slit_tx.entries, &(&1.output_role == "trim" and &1.observation == :derived))

    assert Enum.any?(
             slit_tx.entries,
             &(&1.output_role == "waste" and &1.observation == :measured)
           )

    # Slitting has a variance per native unit: 5 m2 of area, and the 3 kg
    # of weighed waste that no mass input balances.
    assert [%{native_unit: %{code: "m2"}} = area_variance, %{native_unit: ^kg} = mass_variance] =
             Enum.filter(slit_tx.entries, &(&1.role == :variance))

    assert Decimal.eq?(area_variance.native_quantity, 5)
    assert Decimal.eq?(mass_variance.native_quantity, -3)
    assert mass_variance.evidence == "synthetic waste scale ticket"

    # Yields sort balances by unit ID; the mill's kilogram unit came first.
    assert {:ok, %{balances: [slit_mass, slit_area], cross_unit: []}} =
             ProductionExecution.get_run_yield(scope, 73, slit.id)

    assert slit_area.unit.code == "m2" and slit_mass.unit.id == kg.id

    assert Enum.all?(
             [{:input, 500}, {:product, 375}, {:trim, 120}, {:waste, 0}, {:variance, 5}],
             fn {field, expected} -> Decimal.eq?(Map.fetch!(slit_area, field), expected) end
           ),
           inspect(slit_area)

    assert Enum.all?(
             [{:input, 0}, {:product, 0}, {:trim, 0}, {:waste, 3}, {:variance, -3}],
             fn {field, expected} -> Decimal.eq?(Map.fetch!(slit_mass, field), expected) end
           ),
           inspect(slit_mass)

    # The coating run's yield carries the cross-unit mass balance; the slit
    # rolls and trim have no conversion, so slitting has none.
    assert {:ok, %{balances: [_coat_mass, _coat_area], cross_unit: [^coat_mass]}} =
             ProductionExecution.get_run_yield(scope, 73, coat.id)

    coated_roll = output_identity(coat_tx, items["COATED"].id)

    assert {:ok, %{runs: unit_runs}} =
             ProductionExecution.get_unit_yield(scope, 73, coated_roll)

    assert Enum.map(unit_runs, & &1.execution_id) == [coat.id, slit.id]
    unit_yield = List.last(unit_runs)
    assert unit_yield.execution_id == slit.id
    assert [_mass, %{unit: %{code: "m2"}, unit_input: unit_input}] = unit_yield.balances
    assert Decimal.eq?(unit_input, 500)
    assert [_mass, %{unit: %{code: "m2"}, unit_output: unit_output}] = hd(unit_runs).balances
    assert Decimal.eq?(unit_output, 500)

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
      assert Decimal.eq?(quantity, if(sku == "SLIT-600", do: 250, else: 125))

      assert {:ok,
              %{
                runs: [
                  %{execution_id: execution_id, balances: [_mass, %{unit_output: unit_output}]}
                ]
              }} =
               ProductionExecution.get_unit_yield(scope, 73, roll)

      assert execution_id == slit.id
      assert Decimal.eq?(unit_output, if(sku == "SLIT-600", do: 250, else: 125))

      assert {:ok, backward} = ProductionExecution.trace_backward(scope, 73, roll)
      assert Enum.map(backward.runs, & &1.operation_code) == ~w(MIX-WET DRY COAT SLIT)

      assert MapSet.subset?(
               receipt_identities,
               MapSet.new(backward.material.identities, & &1.id)
             )

      assert receipt_transactions == MapSet.new(backward.material.receipts, & &1.id)

      assert {:ok, forward} =
               ProductionExecution.trace_forward(scope, 73, elem(receipts["RESIN"], 1))

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
