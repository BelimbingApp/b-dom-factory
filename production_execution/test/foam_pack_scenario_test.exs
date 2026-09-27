Code.require_file("support/foam_pack_scenario.ex", __DIR__)

defmodule Bilimbi.Factory.ProductionExecution.FoamPackScenarioTest do
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}
  alias Bilimbi.Factory.Inventory.ReceiptMeasurement
  alias Bilimbi.Factory.ProductionExecution.FoamPackScenario

  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  setup do
    context = mill!()
    create_production_tables!()
    context
  end

  test "representative lorry receipt reaches identified packs and despatch through Factory",
       context do
    %{scope: scope} = context
    scenario = FoamPackScenario.seed!(context)
    %{items: items, locations: locations, order: order, times: times} = scenario.config
    [receipt | _] = scenario.receipts
    [roll_a, roll_b] = scenario.roll_ids

    # The ticket distinguishes a supplier claim from gross/tare/net readings.
    # Only the measured net enters stock; the declared 72 kg is not counted twice.
    assert receipt.kind == :receipt and receipt.actor_id == 11
    assert DateTime.compare(receipt.effective_at, times.receipt) == :eq
    assert receipt.evidence =~ "supplier SUP-1; vehicle JQK-1234; weigh ticket WT-1"
    assert %ReceiptMeasurement{} = measurement = receipt.receipt_measurement
    assert Decimal.eq?(measurement.supplier_declared, 72)
    assert Decimal.eq?(measurement.measured_gross, 812)
    assert Decimal.eq?(measurement.tare, 742)
    assert Decimal.eq?(measurement.net, 70)

    assert measurement.unit_id ==
             receipt.entries |> hd() |> Map.fetch!(:recorded_unit) |> Map.fetch!(:id)

    assert measurement.weighing_point_ref == "RCV"
    assert Decimal.eq?(measurement.supplier_variance, 2)

    assert Decimal.eq?(stock_quantity(receipt, items["VIRGIN"].id), 70)

    assert {:ok, virgin_stock} =
             Inventory.get_stock_position(scope, 73, items["VIRGIN"].id, locations.line.id)

    assert Decimal.eq?(virgin_stock.quantity, 0)

    assert order.demand_ref == "forecast:2026-09:sample"

    assert {:ok, selected} =
             ProductDefinition.select_revisions(
               scope,
               73,
               order.product_id,
               order.formula_version,
               order.routing_version
             )

    assert selected.formula.process_config["process_family"] == "LDPE foam"

    assert Enum.any?(
             selected.formula.lines,
             &(&1["item_id"] == items["FOAM-ROLL"].id and
                 &1["material_hold_rule"] == %{"hours" => 168})
           )

    # Both labels retain their source, dimensions and physical cure-bay move.
    assert scenario.roll_move.kind == :transfer
    assert Decimal.eq?(scenario.cure_stock_after_move.quantity, 96)

    assert MapSet.new([roll_a, roll_b]) ==
             MapSet.new(
               for entry <- scenario.roll_move.entries,
                   entry.role == :stock and Decimal.gt?(entry.native_quantity, 0),
                   do: entry.identity_id
             )

    assert {:ok, roll_identity} = Inventory.get_identity(scope, 73, roll_a)
    assert roll_identity.code == "ROLL-A" and roll_identity.kind == :unit
    assert roll_identity.source_transaction_id == elem(scenario.extrude, 1).id
    assert roll_identity.dimensions.width.unit == :mm
    assert roll_identity.dimensions.width.provenance == :measured
    assert Decimal.eq?(roll_identity.dimensions.width.value, 1200)
    assert Decimal.eq?(roll_identity.dimensions.length.value, 100)
    assert Decimal.eq?(roll_identity.dimensions.thickness.value, 2)
    assert {:ok, []} = Inventory.get_identity_positions(scope, 73, roll_a)

    pack_b =
      scenario.packs
      |> List.last()
      |> elem(1)
      |> then(fn tx ->
        Enum.find_value(
          tx.entries,
          &((&1.role == :stock and &1.item_id == items["PACK"].id and
               Decimal.positive?(&1.native_quantity)) && &1.identity_id)
        )
      end)

    assert {:ok, [%{location: finished, quantity: pack_quantity}]} =
             Inventory.get_identity_positions(scope, 73, pack_b)

    assert finished.id == locations.finished.id
    assert Decimal.eq?(pack_quantity, 31)
    assert DateTime.compare(scenario.roll_source.effective_at, times.extrude) == :eq
    assert DateTime.diff(times.early_laminate, scenario.roll_source.effective_at, :hour) == 24
    assert DateTime.diff(times.mature_laminate, scenario.roll_source.effective_at, :hour) == 192

    assert Enum.any?(
             elem(scenario.extrude, 1).entries,
             &(&1.identity_id == roll_a and
                 &1.evidence == "width_mm=1200;thickness_mm=2;length_m=100;colour=blue")
           )

    # The refused attempt made no execution or material transaction; the
    # granted capability allows one early draw with immutable override data.
    assert {:ok, ledger} = Inventory.list_transactions(scope, 73, limit: 100)
    refute Enum.any?(ledger, &(&1.request_id == "FP-LA-REFUSED"))
    [{early_lamination, _}, {mature_lamination, _}] = scenario.laminations

    assert {:ok, [override]} =
             ProductionExecution.list_hold_overrides(scope, 73, early_lamination.id)

    assert override.identity_id == roll_a
    assert override.source_transaction_id == elem(scenario.extrude, 1).id
    assert override.actor_type == "user" and override.actor_id == 9
    assert override.reason == "Representative supervised release"
    assert override.inventory_transaction_id == early_lamination.inventory_transaction_id
    assert {:ok, []} = ProductionExecution.list_hold_overrides(scope, 73, mature_lamination.id)

    # Separate cut executions preserve attributable 800 mm yield for each
    # 1200 mm roll. Measured product and waste differ from derived trim.
    for {cut, transaction} <- scenario.cuts do
      assert cut.operation_code == "CUT"
      assert Decimal.eq?(input_quantity(transaction, items["LAMINATE"].id), 49)
      assert Decimal.eq?(stock_quantity(transaction, items["CUT-800"].id), 32)
      assert Decimal.eq?(stock_quantity(transaction, items["TRIM"].id), 14)
      assert Decimal.eq?(stock_quantity(transaction, items["WASTE"].id), 2)

      assert Enum.any?(
               transaction.entries,
               &(&1.role == :variance and Decimal.eq?(&1.native_quantity, 1) and
                   &1.reconciliation_basis == "1 kg representative cut difference")
             )

      assert Enum.any?(
               transaction.entries,
               &(&1.output_role == "trim" and &1.observation == :derived)
             )

      assert Enum.any?(
               transaction.entries,
               &(&1.output_role == "waste" and &1.observation == :measured)
             )

      assert {:ok, %{balances: [yield]}} = ProductionExecution.get_run_yield(scope, 73, cut.id)

      assert Enum.all?(
               [{:input, 49}, {:product, 32}, {:trim, 14}, {:waste, 2}, {:variance, 1}],
               fn {field, expected} -> Decimal.eq?(Map.fetch!(yield, field), expected) end
             ),
             inspect(yield)

      laminate_id =
        Enum.find_value(
          transaction.entries,
          &((&1.role == :stock and Decimal.negative?(&1.native_quantity)) && &1.identity_id)
        )

      assert {:ok, %{runs: unit_runs}} =
               ProductionExecution.get_unit_yield(scope, 73, laminate_id)

      unit_yield = Enum.find(unit_runs, &(&1.execution_id == cut.id))
      assert unit_yield.execution_id == cut.id
      assert [%{unit_input: unit_input}] = unit_yield.balances
      assert Decimal.eq?(unit_input, 49)
    end

    assert Enum.all?(scenario.cuts, fn {_run, tx} ->
             Decimal.eq?(
               Decimal.mult(stock_quantity(tx, items["CUT-800"].id), 49),
               Decimal.mult(input_quantity(tx, items["LAMINATE"].id), 32)
             )
           end)

    assert Decimal.eq?(
             Enum.reduce(scenario.cuts, Decimal.new(0), fn {_run, tx}, total ->
               Decimal.add(total, stock_quantity(tx, items["CUT-800"].id))
             end),
             64
           )

    assert Decimal.eq?(
             Enum.reduce(scenario.cuts, Decimal.new(0), fn {_run, tx}, total ->
               Decimal.add(total, input_quantity(tx, items["LAMINATE"].id))
             end),
             98
           )

    assert scenario.shipment.kind == :consumption

    assert scenario.shipment.context == %{
             shipment: "shipment:SHP-1",
             destination: "customer:DEST-1"
           }

    assert Decimal.eq?(input_quantity(scenario.shipment, items["PACK"].id), 31)
    assert {:ok, pack_identity} = Inventory.get_identity(scope, 73, scenario.pack_a)
    assert pack_identity.code == "PACK-A" and pack_identity.kind == :unit

    assert {:ok, backward} = ProductionExecution.trace_backward(scope, 73, scenario.pack_a)

    assert MapSet.subset?(
             MapSet.new([roll_a, scenario.virgin_id]),
             MapSet.new(backward.material.identities, & &1.id)
           )

    assert receipt.id in Enum.map(backward.material.receipts, & &1.id)
    assert Enum.map(backward.runs, & &1.operation_code) == ~w(EXTRUDE LAMINATE CUT PACK)

    assert {:ok, forward} = ProductionExecution.trace_forward(scope, 73, scenario.virgin_id)
    assert scenario.pack_a in Enum.map(forward.material.identities, & &1.id)

    assert scenario.shipment.id in Enum.map(
             Inventory.list_identity_draws(scope, 73, scenario.pack_a) |> elem(1),
             & &1.id
           )
  end

  defp stock_quantity(transaction, item_id) do
    transaction.entries
    |> Enum.filter(
      &(&1.role == :stock and &1.item_id == item_id and Decimal.gt?(&1.native_quantity, 0))
    )
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.native_quantity, &2))
  end

  defp input_quantity(transaction, item_id) do
    transaction.entries
    |> Enum.filter(
      &(&1.role == :stock and &1.item_id == item_id and Decimal.lt?(&1.native_quantity, 0))
    )
    |> Enum.reduce(Decimal.new(0), &Decimal.sub(&2, &1.native_quantity))
  end
end
