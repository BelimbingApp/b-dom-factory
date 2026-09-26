defmodule Bilimbi.Factory.Inventory.GenealogyTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.TestPostingAuthority

  import Bilimbi.Factory.Inventory.TestFixtures

  test "an identified output traces to a receipt and the receipt traces to descendants" do
    %{scope: scope, coil: coil, sheet: sheet, trim: trim, kg: kg} = context = mill!()
    %{receiving: receiving, slitter: slitter} = context

    assert {:ok, receipt} =
             Inventory.record_receipt(
               scope,
               73,
               request("GEN-RECEIPT",
                 lines: [
                   %{
                     item_id: coil.id,
                     location_id: receiving.id,
                     quantity: 100,
                     observation: "measured",
                     identity: %{kind: "lot", code: "COIL-001"}
                   }
                 ]
               )
             )

    [receipt_entry, _boundary] = receipt.entries
    source_id = receipt_entry.identity_id
    assert {:ok, source} = Inventory.get_identity(scope, 73, source_id)
    assert source.code == "COIL-001"
    assert source.source_transaction_id == receipt.id

    assert {:error, %Ecto.Changeset{}} =
             Inventory.record_receipt(
               scope,
               73,
               request("GEN-DUPLICATE",
                 lines: [
                   %{
                     item_id: coil.id,
                     location_id: receiving.id,
                     quantity: 1,
                     observation: "measured",
                     identity: %{kind: "lot", code: "COIL-001"}
                   }
                 ]
               )
             )

    assert {:error, :insufficient_unidentified_stock} =
             Inventory.record_consumption(
               scope,
               73,
               request("GEN-UNTRACKED-DRAW",
                 lines: [
                   %{
                     item_id: coil.id,
                     location_id: receiving.id,
                     quantity: 1,
                     observation: "measured"
                   }
                 ]
               )
             )

    assert {:ok, _unidentified_receipt} =
             Inventory.record_receipt(
               scope,
               73,
               request("GEN-OTHER",
                 lines: [
                   %{
                     item_id: coil.id,
                     location_id: receiving.id,
                     quantity: 5,
                     observation: "measured"
                   }
                 ]
               )
             )

    assert {:ok, transform} =
             Inventory.record_transform(
               scope,
               73,
               request("GEN-TRANSFORM",
                 inputs: [
                   %{
                     item_id: coil.id,
                     location_id: receiving.id,
                     quantity: 100,
                     observation: "measured",
                     identity_id: source_id
                   }
                 ],
                 outputs: [
                   %{
                     item_id: sheet.id,
                     location_id: slitter.id,
                     quantity: 80,
                     observation: "measured",
                     identity: %{kind: "unit", code: "SHEET-001"}
                   },
                   %{
                     item_id: trim.id,
                     location_id: slitter.id,
                     quantity: 20,
                     observation: "measured",
                     identity: %{kind: "lot", code: "TRIM-001"}
                   }
                 ]
               ),
               TestPostingAuthority
             )

    [input, sheet_entry, trim_entry] = transform.entries
    assert input.identity_id == source_id
    assert sheet_entry.identity_id != nil
    assert trim_entry.identity_id != nil
    assert {:ok, backward} = Inventory.trace_backward(scope, 73, sheet_entry.identity_id)
    assert Enum.map(backward.identities, & &1.code) == ["COIL-001", "SHEET-001"]
    assert Enum.map(backward.receipts, & &1.id) == [receipt.id]
    assert {source_id, sheet_entry.identity_id, transform.id} in backward.links

    assert {:ok, second_transform} =
             Inventory.record_transform(
               scope,
               73,
               request("GEN-SECOND",
                 inputs: [
                   %{
                     item_id: sheet.id,
                     location_id: slitter.id,
                     quantity: 80,
                     observation: "measured",
                     identity_id: sheet_entry.identity_id
                   }
                 ],
                 outputs: [
                   %{
                     item_id: sheet.id,
                     location_id: receiving.id,
                     quantity: 80,
                     observation: "measured",
                     identity: %{kind: "unit", code: "SHEET-002"}
                   }
                 ]
               ),
               TestPostingAuthority
             )

    [_, descendant] = second_transform.entries
    assert {:ok, deep_backward} = Inventory.trace_backward(scope, 73, descendant.identity_id)

    assert Enum.map(deep_backward.identities, & &1.code) ==
             ["COIL-001", "SHEET-001", "SHEET-002"]

    assert Enum.map(deep_backward.receipts, & &1.id) == [receipt.id]

    assert {:ok, forward} = Inventory.trace_forward(scope, 73, source_id)

    assert Enum.map(forward.identities, & &1.code) ==
             ["COIL-001", "SHEET-001", "TRIM-001", "SHEET-002"]

    assert length(forward.links) == 3

    assert {:error, :insufficient_identity_stock} =
             Inventory.record_consumption(
               scope,
               73,
               request("GEN-OVERDRAW",
                 lines: [
                   %{
                     item_id: coil.id,
                     location_id: receiving.id,
                     quantity: 1,
                     unit_id: kg.id,
                     observation: "measured",
                     identity_id: source_id
                   }
                 ]
               )
             )

    assert {:error, :identity_not_found} = Inventory.get_identity(scope, 74, source_id)
    assert {:error, :identity_not_found} = Inventory.trace_forward(scope, 74, source_id)
  end
end
