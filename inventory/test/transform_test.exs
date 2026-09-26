defmodule Bilimbi.Factory.Inventory.TransformTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Entry
  alias Bilimbi.Factory.Inventory.TestPostingAuthority
  alias Bilimbi.Factory.Inventory.Transaction

  import Bilimbi.Factory.Inventory.TestFixtures

  setup do
    context = mill!()
    %{scope: scope, coil: coil, receiving: receiving} = context

    {:ok, _receipt} =
      Inventory.record_receipt(
        scope,
        73,
        request("R-1",
          lines: [
            %{item_id: coil.id, location_id: receiving.id, quantity: 100, observation: "measured"}
          ]
        )
      )

    context
  end

  defp slitting(context, fields \\ []) do
    %{coil: coil, sheet: sheet, trim: trim, scrap: scrap, receiving: receiving} = context
    %{slitter: line, yard: yard} = context

    request("T-1",
      evidence: "Slitting run 14 scale tickets",
      context: %{order_or_batch: "PO-7", operation_execution: "EX-3", work_centre: "SLIT-1"},
      inputs: [
        %{item_id: coil.id, location_id: receiving.id, quantity: 100, observation: "measured"}
      ],
      outputs: [
        %{
          item_id: sheet.id,
          location_id: line.id,
          quantity: 78,
          observation: "measured",
          output_role: "finished",
          evidence: "Scale ticket 88"
        },
        %{
          item_id: trim.id,
          location_id: yard.id,
          quantity: 17,
          observation: "derived",
          output_role: "trim"
        },
        %{
          item_id: scrap.id,
          location_id: yard.id,
          quantity: 2,
          observation: "measured",
          output_role: "waste"
        }
      ],
      variance: %{
        evidence: "Operator log: edge loss not weighed",
        reconciliation_basis: "Input scale weight less measured and derived outputs"
      }
    )
    |> Map.merge(Map.new(fields))
  end

  defp quantity(scope, item, location) do
    {:ok, position} = Inventory.get_stock_position(scope, 73, item.id, location.id)
    position.quantity
  end

  test "100 kg in, 78 measured finished, 17 derived trim, 2 measured waste, 3 kg variance",
       context do
    %{scope: scope, coil: coil, sheet: sheet, trim: trim, scrap: scrap, kg: kg} = context
    %{receiving: receiving, slitter: line, yard: yard} = context

    assert {:ok, %Transaction{kind: :transform} = transform} =
             Inventory.record_transform(scope, 73, slitting(context),
               authority: TestPostingAuthority
             )

    assert transform.posting_authority == inspect(TestPostingAuthority)

    assert transform.context == %{
             order_or_batch: "PO-7",
             operation_execution: "EX-3",
             work_centre: "SLIT-1"
           }

    [input, finished, trimmed, waste, variance] = transform.entries

    # Every observation is kept exactly as recorded, with how it was obtained.
    for {entry, item, location, amount, observation, role} <- [
          {input, coil, receiving, "-100", :measured, nil},
          {finished, sheet, line, "78", :measured, "finished"},
          {trimmed, trim, yard, "17", :derived, "trim"},
          {waste, scrap, yard, "2", :measured, "waste"}
        ] do
      assert %Entry{role: :stock, observation: ^observation, output_role: ^role} = entry
      assert entry.item_id == item.id
      assert entry.location_id == location.id
      assert Decimal.eq?(entry.native_quantity, amount)
      assert Decimal.eq?(entry.recorded_quantity, Decimal.abs(Decimal.new(amount)))
      assert entry.native_unit == kg and entry.recorded_unit == kg
    end

    assert finished.evidence == "Scale ticket 88"

    # The unaccounted 3 kg is a variance with its evidence and basis; it is
    # not spread over any observation.
    assert %Entry{role: :variance, item_id: nil, location_id: nil, native_unit: ^kg} = variance
    assert Decimal.eq?(variance.native_quantity, 3)
    assert variance.evidence == "Operator log: edge loss not weighed"

    assert variance.reconciliation_basis ==
             "Input scale weight less measured and derived outputs"

    # The accounting balances.
    total = Enum.reduce(transform.entries, Decimal.new(0), &Decimal.add(&1.native_quantity, &2))
    assert Decimal.eq?(total, 0)

    # The genealogy links the input to each output, committed with them.
    assert transform.genealogy == [
             %{input_entry_id: input.id, output_entry_id: finished.id},
             %{input_entry_id: input.id, output_entry_id: trimmed.id},
             %{input_entry_id: input.id, output_entry_id: waste.id}
           ]

    assert Decimal.eq?(quantity(scope, coil, receiving), 0)
    assert Decimal.eq?(quantity(scope, sheet, line), 78)
    assert Decimal.eq?(quantity(scope, trim, yard), 17)
    assert Decimal.eq?(quantity(scope, scrap, yard), 2)

    assert {:ok, ^transform} = Inventory.get_transaction(scope, 73, transform.id)
  end

  test "is refused without a registered posting authority", context do
    %{scope: scope, coil: coil, receiving: receiving} = context

    assert {:error, :unregistered_posting_authority} =
             Inventory.record_transform(scope, 73, slitting(context))

    assert Decimal.eq?(quantity(scope, coil, receiving), 100)
    assert {:ok, [%Transaction{kind: :receipt}]} = Inventory.list_transactions(scope, 73)
  end

  test "a difference needs a variance, and a variance needs a difference", context do
    %{scope: scope, sheet: sheet, slitter: line} = context
    authority = [authority: TestPostingAuthority]

    assert {:error, :variance_required} =
             Inventory.record_transform(scope, 73, slitting(context, variance: nil), authority)

    [finished | rest] = slitting(context).outputs
    exact = [%{finished | quantity: 81} | rest]

    assert {:error, :no_variance} =
             Inventory.record_transform(scope, 73, slitting(context, outputs: exact), authority)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Inventory.record_transform(
               scope,
               73,
               slitting(context, variance: %{evidence: "log"}),
               authority
             )

    assert %{variance: ["needs reconciliation_basis"]} = errors_on(changeset)
    assert Decimal.eq?(quantity(scope, sheet, line), 0)

    assert {:ok, %Transaction{entries: entries}} =
             Inventory.record_transform(
               scope,
               73,
               slitting(context, outputs: exact, variance: nil),
               authority
             )

    refute Enum.any?(entries, &(&1.role == :variance))
  end

  test "commits nothing when an input is short", context do
    %{scope: scope, sheet: sheet, slitter: line, coil: coil, receiving: receiving} = context
    [input] = slitting(context).inputs

    assert {:error, :insufficient_stock} =
             Inventory.record_transform(
               scope,
               73,
               slitting(context, inputs: [%{input | quantity: 101}]),
               authority: TestPostingAuthority
             )

    assert Decimal.eq?(quantity(scope, coil, receiving), 100)
    assert Decimal.eq?(quantity(scope, sheet, line), 0)
  end

  test "an output at a drawn position never covers the draw", context do
    %{scope: scope, coil: coil, receiving: receiving} = context
    [input] = slitting(context).inputs

    assert {:error, :insufficient_stock} =
             Inventory.record_transform(
               scope,
               73,
               slitting(context,
                 inputs: [%{input | quantity: 150}],
                 outputs: [
                   %{
                     item_id: coil.id,
                     location_id: receiving.id,
                     quantity: 60,
                     observation: "measured"
                   }
                 ]
               ),
               authority: TestPostingAuthority
             )

    assert Decimal.eq?(quantity(scope, coil, receiving), 100)
  end

  test "refuses inputs and outputs that do not share a native unit", context do
    %{scope: scope, slitter: line} = context
    {:ok, pieces} = Inventory.create_unit(scope, 73, %{code: "pc", name: "Piece"})
    {:ok, blank} = Inventory.create_item(scope, 73, %{sku: "BLANK", title: "Blank"})
    {:ok, _material} = Inventory.register_material(scope, 73, blank.id, pieces.id)

    outputs = [
      %{item_id: blank.id, location_id: line.id, quantity: 400, observation: "counted"}
    ]

    assert {:error, :mixed_native_units} =
             Inventory.record_transform(scope, 73, slitting(context, outputs: outputs),
               authority: TestPostingAuthority
             )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))
  end
end
