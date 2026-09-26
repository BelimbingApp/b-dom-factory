defmodule Bilimbi.Factory.Inventory.StandaloneTest do
  # Inventory's catalog, ledger, stock positions, and genealogy serve
  # receiving and warehouse work in a runtime that never loads Production
  # Execution, and no posting here names an authority.
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Transaction

  import Bilimbi.Factory.Inventory.TestFixtures

  test "Production Execution is neither loaded nor loadable here" do
    assert Application.spec(:bilimbi_factory_production_execution) == nil
    refute Code.ensure_loaded?(Bilimbi.Factory.ProductionExecution)
  end

  test "receive, store, move, ship, and correct material, then trace it, with no posting authority" do
    %{scope: scope, kg: kg, receiving: receiving, yard: yard} = mill!()

    # Catalog: a new item becomes a kilogram material with a drum conversion.
    {:ok, drum_unit} = Inventory.create_unit(scope, 73, %{code: "drum", name: "Drum"})
    {:ok, resin} = Inventory.create_item(scope, 73, %{sku: "RESIN", title: "Resin"})
    {:ok, _material} = Inventory.register_material(scope, 73, resin.id, kg.id)
    {:ok, conversion} = Inventory.define_conversion(scope, 73, resin.id, drum_unit.id, "200")
    {:ok, store} = Inventory.create_location(scope, 73, %{code: "STORE", name: "Store"})

    # Ledger: receive four drums of one lot, put three away, ship one.
    assert {:ok, %Transaction{kind: :receipt} = receipt} =
             Inventory.record_receipt(
               scope,
               73,
               request("RESIN-GRN",
                 lines: [
                   %{
                     item_id: resin.id,
                     location_id: receiving.id,
                     quantity: 4,
                     unit_id: drum_unit.id,
                     observation: "counted",
                     identity: %{kind: "lot", code: "RESIN-LOT-1"}
                   }
                 ]
               )
             )

    [stock_entry, _boundary] = receipt.entries
    lot = stock_entry.identity_id
    assert stock_entry.conversion_id == conversion.id
    assert Decimal.eq?(stock_entry.native_quantity, 800)

    assert {:ok, %Transaction{kind: :transfer}} =
             Inventory.record_transfer(
               scope,
               73,
               request("RESIN-PUTAWAY",
                 lines: [
                   %{
                     item_id: resin.id,
                     identity_id: lot,
                     from_location_id: receiving.id,
                     to_location_id: store.id,
                     quantity: 600,
                     observation: "declared"
                   }
                 ]
               )
             )

    assert {:ok, %Transaction{kind: :consumption} = shipment} =
             Inventory.record_consumption(
               scope,
               73,
               request("RESIN-SHIP",
                 context: %{shipment: "SHP-9", destination: "Sister plant"},
                 lines: [
                   %{
                     item_id: resin.id,
                     identity_id: lot,
                     location_id: store.id,
                     quantity: 200,
                     observation: "counted"
                   }
                 ]
               )
             )

    # A count finds 5 kg spilled at receiving: a correction is a new
    # transaction, and the receipt it names reads back unchanged.
    assert {:ok, %Transaction{kind: :correction}} =
             Inventory.record_correction(
               scope,
               73,
               request("RESIN-COUNT",
                 corrects_transaction_id: receipt.id,
                 reason: "Spill found at cycle count",
                 lines: [
                   %{
                     item_id: resin.id,
                     identity_id: lot,
                     location_id: receiving.id,
                     quantity: -5,
                     observation: "counted"
                   }
                 ]
               )
             )

    assert {:ok, ^receipt} = Inventory.get_transaction(scope, 73, receipt.id)

    # Stock positions are the ledger's sums.
    for {location, quantity} <- [{receiving, 195}, {store, 400}, {yard, 0}] do
      assert {:ok, position} = Inventory.get_stock_position(scope, 73, resin.id, location.id)
      assert Decimal.eq?(position.quantity, quantity)
    end

    {:ok, ledger} = Inventory.list_transactions(scope, 73, item_id: resin.id)
    assert length(ledger) == 4
    assert Enum.all?(ledger, &(&1.posting_authority == nil))

    # Genealogy: the lot traces to its receipt, has no descendants, and its
    # shipment is one of its draws.
    assert {:ok, backward} = Inventory.trace_backward(scope, 73, lot)
    assert Enum.map(backward.receipts, & &1.id) == [receipt.id]
    assert {:ok, forward} = Inventory.trace_forward(scope, 73, lot)
    assert forward.links == []
    assert {:ok, draws} = Inventory.list_identity_draws(scope, 73, lot)
    assert Enum.map(draws, & &1.id) == [shipment.id]
  end
end
