defmodule Bilimbi.Factory.Inventory.TransformTest do
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Balance
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
             Inventory.record_transform(scope, 73, slitting(context), TestPostingAuthority)

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

    for authority <- [nil, Bilimbi.Factory.ProductionExecution, Bilimbi.Factory.Inventory.Ledger] do
      assert {:error, :unregistered_posting_authority} =
               Inventory.record_transform(scope, 73, slitting(context), authority)
    end

    assert Decimal.eq?(quantity(scope, coil, receiving), 100)
    assert {:ok, [%Transaction{kind: :receipt}]} = Inventory.list_transactions(scope, 73)
  end

  test "a difference needs a variance, and a variance needs a difference", context do
    %{scope: scope, sheet: sheet, slitter: line} = context
    authority = TestPostingAuthority

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
               TestPostingAuthority
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
               TestPostingAuthority
             )

    assert Decimal.eq?(quantity(scope, coil, receiving), 100)
  end

  describe "mixed native units" do
    # Film is stocked by area and glue by mass; coated film is stocked by
    # area. Each native unit balances on its own.
    setup %{scope: scope, kg: kg, receiving: receiving, slitter: line} do
      {:ok, m2} = Inventory.create_unit(scope, 73, %{code: "m2", name: "Square metre"})
      {:ok, roll} = Inventory.create_unit(scope, 73, %{code: "roll", name: "Roll"})

      items =
        for {sku, unit} <- [
              {"FILM", m2},
              {"GLUE", kg},
              {"COATED", m2},
              {"JUMBO", roll},
              {"SLIT", roll},
              {"EDGE", kg}
            ],
            into: %{} do
          {:ok, item} = Inventory.create_item(scope, 73, %{sku: sku, title: sku})
          {:ok, _material} = Inventory.register_material(scope, 73, item.id, unit.id)
          {sku, item}
        end

      for {sku, quantity, observation} <- [
            {"FILM", 100, "measured"},
            {"GLUE", 20, "measured"},
            {"JUMBO", 1, "counted"}
          ] do
        {:ok, _receipt} =
          Inventory.record_receipt(
            scope,
            73,
            request("R-#{sku}",
              lines: [
                %{
                  item_id: items[sku].id,
                  location_id: receiving.id,
                  quantity: quantity,
                  observation: observation
                }
              ]
            )
          )
      end

      coating =
        request("COAT-1",
          evidence: "Coating run sheet",
          context: %{order_or_batch: "PO-9", operation_execution: "EX-9", work_centre: "COATER"},
          inputs: [
            %{
              item_id: items["FILM"].id,
              location_id: receiving.id,
              quantity: 100,
              observation: "measured"
            },
            %{
              item_id: items["GLUE"].id,
              location_id: receiving.id,
              quantity: 20,
              observation: "measured"
            }
          ],
          outputs: [
            %{
              item_id: items["COATED"].id,
              location_id: line.id,
              quantity: 98,
              observation: "measured",
              output_role: "finished"
            }
          ],
          variance: %{
            units: [
              %{
                unit_id: m2.id,
                evidence: "Length counter at the rewind",
                reconciliation_basis: "Film area in less coated area out"
              },
              %{
                unit_id: kg.id,
                evidence: "Glue pump totaliser",
                reconciliation_basis: "Glue applied to the film is not weighed on the coated roll"
              }
            ]
          }
        )

      slitting =
        request("SLIT-1",
          evidence: "Slitter log",
          context: %{order_or_batch: "PO-10", operation_execution: "EX-10", work_centre: "SLIT"},
          inputs: [
            %{
              item_id: items["JUMBO"].id,
              location_id: receiving.id,
              quantity: 1,
              observation: "counted"
            }
          ],
          outputs: [
            %{
              item_id: items["SLIT"].id,
              location_id: line.id,
              quantity: 3,
              observation: "counted",
              output_role: "finished"
            },
            %{
              item_id: items["EDGE"].id,
              location_id: line.id,
              quantity: 2,
              observation: "measured",
              output_role: "trim"
            }
          ],
          variance: %{
            units: [
              %{
                unit_id: roll.id,
                evidence: "Slitter log: one jumbo cut into three",
                reconciliation_basis: "Rolls are counted, not conserved"
              },
              %{
                unit_id: kg.id,
                evidence: "Edge trim scale ticket",
                reconciliation_basis: "The jumbo was not weighed; trim is the only mass observed"
              }
            ]
          }
        )

      %{m2: m2, roll: roll, items: items, coating: coating, slitting: slitting}
    end

    test "coating balances film area and glue mass separately, each with its own variance",
         %{scope: scope, kg: kg, m2: m2, items: items, coating: coating} = context do
      %{receiving: receiving, slitter: line} = context

      assert {:ok, %Transaction{kind: :transform} = transform} =
               Inventory.record_transform(scope, 73, coating, TestPostingAuthority)

      [film, glue, coated, area, mass] = transform.entries

      for {entry, item, unit, amount} <- [
            {film, items["FILM"], m2, "-100"},
            {glue, items["GLUE"], kg, "-20"},
            {coated, items["COATED"], m2, "98"}
          ] do
        assert %Entry{role: :stock, native_unit: ^unit, recorded_unit: ^unit} = entry
        assert entry.item_id == item.id
        assert Decimal.eq?(entry.native_quantity, amount)
        assert Decimal.eq?(entry.recorded_quantity, Decimal.abs(Decimal.new(amount)))
      end

      # The 2 m2 the rewind did not account for and the 20 kg of glue now on
      # the film are each a variance in their own unit, with their own
      # evidence. Neither adjusts an observation or converts between units.
      assert %Entry{role: :variance, native_unit: ^m2} = area
      assert Decimal.eq?(area.native_quantity, 2)
      assert area.evidence == "Length counter at the rewind"
      assert area.reconciliation_basis == "Film area in less coated area out"

      assert %Entry{role: :variance, native_unit: ^kg} = mass
      assert Decimal.eq?(mass.native_quantity, 20)
      assert mass.evidence == "Glue pump totaliser"

      assert mass.reconciliation_basis ==
               "Glue applied to the film is not weighed on the coated roll"

      # Each unit balances on its own.
      for unit <- [m2, kg] do
        total =
          for entry <- transform.entries, entry.native_unit == unit, reduce: Decimal.new(0) do
            sum -> Decimal.add(sum, entry.native_quantity)
          end

        assert Decimal.eq?(total, 0)
      end

      # Genealogy is unaffected: every input links to every output.
      assert transform.genealogy == [
               %{input_entry_id: film.id, output_entry_id: coated.id},
               %{input_entry_id: glue.id, output_entry_id: coated.id}
             ]

      assert Decimal.eq?(quantity(scope, items["FILM"], receiving), 0)
      assert Decimal.eq?(quantity(scope, items["GLUE"], receiving), 0)
      assert Decimal.eq?(quantity(scope, items["COATED"], line), 98)

      # A retry with the same per-unit evidence is the same request.
      assert {:ok, ^transform} =
               Inventory.record_transform(scope, 73, coating, TestPostingAuthority)
    end

    test "a cross-unit balance exists only in a unit every line was posted in",
         %{scope: scope, kg: kg, m2: m2, items: items, coating: coating} do
      assert {:ok, transform} =
               Inventory.record_transform(scope, 73, coating, TestPostingAuthority)

      assert {:ok, %Balance{transaction_id: id} = balance} =
               Inventory.get_transaction_balance(scope, 73, transform.id)

      assert id == transform.id
      assert balance.correction_transaction_ids == []
      assert [%{unit: ^m2} = area, %{unit: ^kg} = mass] = balance.per_unit

      for {group, input, output, difference} <- [{area, 100, 98, 2}, {mass, 20, 0, 20}] do
        assert Decimal.eq?(group.input, input)
        assert Decimal.eq?(group.output, output)
        assert Decimal.eq?(group.difference, difference)
        assert Decimal.eq?(group.variance, difference)
      end

      assert balance.cross_unit == []

      # Film and the coated roll were recorded by area, so conversions
      # defined afterwards convert nothing already posted.
      {:ok, _} = Inventory.define_conversion(scope, 73, items["FILM"].id, kg.id, "10")
      {:ok, _} = Inventory.define_conversion(scope, 73, items["COATED"].id, kg.id, "3.5")

      assert {:ok, %Balance{cross_unit: []}} =
               Inventory.get_transaction_balance(scope, 73, transform.id)
    end

    test "a weighed coating reads a mass balance that a later conversion version does not restate",
         %{scope: scope, kg: kg, m2: m2, items: items, coating: coating} do
      {:ok, film_kg} = Inventory.define_conversion(scope, 73, items["FILM"].id, kg.id, "10")
      {:ok, coated_kg} = Inventory.define_conversion(scope, 73, items["COATED"].id, kg.id, "3.5")

      [film, glue] = coating.inputs
      [coated] = coating.outputs

      weighed = %{
        coating
        | inputs: [%{film | quantity: 10} |> Map.put(:unit_id, kg.id), glue],
          outputs: [%{coated | quantity: 28} |> Map.put(:unit_id, kg.id)]
      }

      assert {:ok, transform} =
               Inventory.record_transform(scope, 73, weighed, TestPostingAuthority)

      # 10 kg of film is 100 m2 and 28 kg of coated film is 98 m2, so area
      # balances per unit as before. In mass, 10 kg of film and 20 kg of glue
      # went in and 28 kg came out, as weighed: 2 kg of measurement
      # disagreement. Glue was not recorded by area, so there is no m2 one.
      assert {:ok, %Balance{per_unit: [area, _mass], cross_unit: [mass_balance]} = balance} =
               Inventory.get_transaction_balance(scope, 73, transform.id)

      assert area.unit == m2 and Decimal.eq?(area.difference, 2)
      assert mass_balance.unit == kg
      assert Decimal.eq?(mass_balance.input, 30)
      assert Decimal.eq?(mass_balance.output, 28)
      assert Decimal.eq?(mass_balance.difference, 2)

      assert mass_balance.conversions ==
               [
                 %{
                   item_id: items["COATED"].id,
                   conversion_id: coated_kg.id,
                   version: 1,
                   factor: coated_kg.factor
                 },
                 %{
                   item_id: items["FILM"].id,
                   conversion_id: film_kg.id,
                   version: 1,
                   factor: film_kg.factor
                 }
               ]
               |> Enum.sort_by(& &1.item_id)

      # A newer version applies to later postings only.
      {:ok, _} = Inventory.define_conversion(scope, 73, items["FILM"].id, kg.id, "5")
      {:ok, _} = Inventory.define_conversion(scope, 73, items["COATED"].id, kg.id, "4")

      assert {:ok, ^balance} = Inventory.get_transaction_balance(scope, 73, transform.id)
    end

    test "slitting one counted jumbo into counted rolls and weighed trim has a variance per unit",
         %{scope: scope, kg: kg, roll: roll, items: items, slitting: slitting} = context do
      %{slitter: line} = context

      assert {:ok, transform} =
               Inventory.record_transform(scope, 73, slitting, TestPostingAuthority)

      [jumbo, rolls, trim, count, mass] = transform.entries
      assert Decimal.eq?(jumbo.native_quantity, -1) and jumbo.native_unit == roll
      assert Decimal.eq?(rolls.native_quantity, 3) and rolls.native_unit == roll
      assert Decimal.eq?(trim.native_quantity, 2) and trim.native_unit == kg

      # One roll in and three out is a counted difference of -2 rolls; the
      # trim is 2 kg of mass with no mass input. Both are recorded as they
      # are, with the evidence given for that unit.
      assert %Entry{role: :variance, native_unit: ^roll} = count
      assert Decimal.eq?(count.native_quantity, -2)
      assert count.evidence == "Slitter log: one jumbo cut into three"
      assert %Entry{role: :variance, native_unit: ^kg} = mass
      assert Decimal.eq?(mass.native_quantity, -2)

      assert mass.reconciliation_basis ==
               "The jumbo was not weighed; trim is the only mass observed"

      assert transform.genealogy == [
               %{input_entry_id: jumbo.id, output_entry_id: rolls.id},
               %{input_entry_id: jumbo.id, output_entry_id: trim.id}
             ]

      assert {:ok, %Balance{per_unit: [counted, weighed], cross_unit: []}} =
               Inventory.get_transaction_balance(scope, 73, transform.id)

      assert counted.unit == roll and Decimal.eq?(counted.difference, -2)
      assert weighed.unit == kg and Decimal.eq?(weighed.difference, -2)
      assert Decimal.eq?(quantity(scope, items["SLIT"], line), 3)
    end

    test "each differing unit needs evidence, and evidence needs a difference",
         %{scope: scope, kg: kg, m2: m2, roll: roll, coating: coating, slitting: slitting} do
      authority = TestPostingAuthority
      [film, glue] = coating.inputs
      [coated] = coating.outputs

      # Only the area difference is covered.
      shared_only = %{
        coating
        | variance: %{evidence: "Coating run sheet", reconciliation_basis: "area and glue"}
      }

      area_only = %{
        coating
        | variance: %{
            units: [%{unit_id: m2.id, evidence: "counter", reconciliation_basis: "area"}]
          }
      }

      # Shared evidence covers every differing unit, so this is accepted...
      assert {:ok, _} = Inventory.record_transform(scope, 73, shared_only, authority)
      # ...while naming only one of two differing units is not.
      assert {:error, :variance_required} =
               Inventory.record_transform(
                 scope,
                 73,
                 %{area_only | request_id: "COAT-2"},
                 authority
               )

      # Kilograms and rolls do not differ in slitting when the trim is left
      # out, so evidence for them has no difference to explain.
      assert {:error, :no_variance} =
               Inventory.record_transform(
                 scope,
                 73,
                 %{slitting | outputs: [%{hd(slitting.outputs) | quantity: 1}]},
                 authority
               )

      # Evidence named for a unit that balances has no difference to explain.
      exact = %{coated | quantity: 100}

      assert {:error, :no_variance} =
               Inventory.record_transform(
                 scope,
                 73,
                 %{coating | request_id: "COAT-3", inputs: [film, glue], outputs: [exact]},
                 authority
               )

      # Evidence for a unit no line is in has no difference either.
      assert {:error, :no_variance} =
               Inventory.record_transform(
                 scope,
                 73,
                 %{
                   coating
                   | request_id: "COAT-4",
                     variance: %{
                       units: [
                         %{unit_id: roll.id, evidence: "x", reconciliation_basis: "y"}
                         | coating.variance.units
                       ]
                     }
                 },
                 authority
               )

      # Shared and per-unit evidence are exclusive.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_transform(
                 scope,
                 73,
                 %{coating | variance: Map.merge(coating.variance, shared_only.variance)},
                 authority
               )

      assert %{variance: ["takes evidence and reconciliation_basis, or units, not both"]} =
               errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_transform(
                 scope,
                 73,
                 %{
                   coating
                   | variance: %{
                       units: [
                         %{unit_id: kg.id, evidence: "pump"},
                         %{unit_id: kg.id, evidence: "pump", reconciliation_basis: "applied"},
                         "log"
                       ]
                     }
                 },
                 authority
               )

      assert %{variance: messages} = errors_on(changeset)

      assert Enum.sort(messages) ==
               Enum.sort([
                 "unit 1 needs reconciliation_basis",
                 "unit 3 must be a map",
                 "units must name each unit once"
               ])

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_transform(
                 scope,
                 73,
                 %{coating | variance: %{units: []}},
                 authority
               )

      assert %{variance: ["needs evidence and reconciliation_basis, or units"]} =
               errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))
  end
end
