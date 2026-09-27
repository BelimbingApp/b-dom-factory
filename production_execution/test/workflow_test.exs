defmodule Bilimbi.Factory.ProductionExecution.WorkflowTest do
  # Three distinct factory workflows run through Production Execution's one
  # contract and reconcile from Inventory's transactions alone. Their process
  # shapes (a foam extrude-cure-laminate-cut chain, a coil-slitting chain, and
  # a coating-and-slitting chain that mixes area, mass, and counted rolls)
  # live only in these fixtures: Inventory carries no process rule or source
  # mapping for any of them.
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}
  alias Bilimbi.Factory.Inventory.Transaction

  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  @authority inspect(ProductionExecution)

  setup do
    context = mill!()
    create_production_tables!()
    context
  end

  test "Production Execution is the registered authority Inventory accepts" do
    assert Inventory.posting_authority_registered?(ProductionExecution)
  end

  test "foam, coil-slitting, and mixed-unit coating chains reconcile from Inventory transactions without changing earlier history",
       context do
    %{scope: scope, kg: kg} = context

    foam = foam_chain!(context)
    {:ok, after_foam} = Inventory.list_transactions(scope, 73, limit: 500)

    slitting = slitting_chain!(context)
    coating = coating_chain!(context)
    {:ok, ledger} = Inventory.list_transactions(scope, 73, limit: 500)

    # The second workflow only appended: every earlier transaction reads back
    # exactly as it was recorded, in the same order.
    assert Enum.take(ledger, -length(after_foam)) == after_foam

    for transaction <- after_foam,
        do: assert({:ok, ^transaction} = Inventory.get_transaction(scope, 73, transaction.id))

    # Every transaction balances in its native unit, and every stock position
    # equals the sum of the ledger's stock entries there.
    for %Transaction{entries: entries} <- ledger do
      entries
      |> Enum.group_by(& &1.native_unit.id, & &1.native_quantity)
      |> Enum.each(fn {_unit, quantities} ->
        assert Decimal.eq?(Enum.reduce(quantities, &Decimal.add/2), 0)
      end)
    end

    positions =
      for %Transaction{entries: entries} <- ledger,
          %{role: :stock} = entry <- entries,
          reduce: %{} do
        acc ->
          Map.update(
            acc,
            {entry.item_id, entry.location_id},
            entry.native_quantity,
            &Decimal.add(&1, entry.native_quantity)
          )
      end

    for {{item_id, location_id}, quantity} <- positions do
      assert {:ok, position} = Inventory.get_stock_position(scope, 73, item_id, location_id)
      assert Decimal.eq?(position.quantity, quantity)
    end

    for {workflow, expected} <- [
          {foam, %{panel: 88, offcut: 12, film: 1, polyol: 0, iso: 0, raw: 0, cured: 0}},
          {slitting, %{coil: 0, narrow: 320, trim: 15}},
          {coating, %{film: 0, glue: 0, coated: 0, rolls: 3, edge: 4}}
        ],
        {name, quantity} <- expected do
      {item, location} = workflow.stock[name]
      assert Decimal.eq?(positions[{item.id, location.id}], quantity)
    end

    # Each execution's material effect is one Inventory transaction that the
    # authority posted with the execution's opaque context, holding the
    # actual inputs and outputs rather than the formula's quantities.
    for workflow <- [foam, slitting, coating], {run, request} <- workflow.runs do
      assert {:ok, transaction} =
               Inventory.get_transaction(scope, 73, run.inventory_transaction_id)

      assert %Transaction{kind: :transform, posting_authority: @authority} = transaction
      assert transaction.evidence == run.evidence
      assert transaction.effective_at == run.completed_at

      assert transaction.context == %{
               operation_execution: run.request_id,
               order_or_batch: workflow.order.code,
               work_centre: Integer.to_string(run.resource_id)
             }

      assert stock_lines(transaction) ==
               Enum.sort(
                 for(line <- request.inputs, do: line_key(line, -1)) ++
                   for(line <- request.outputs, do: line_key(line, 1))
               )
    end

    # Material ancestry runs from each workflow's finished identity back to
    # every source receipt through Inventory's links, and the production trace
    # adds each run's order, operation, and resource.
    assert {:ok, panel_trace} = ProductionExecution.trace_backward(scope, 73, foam.finished)

    assert Enum.sort(Enum.map(panel_trace.material.receipts, & &1.id)) ==
             Enum.sort(foam.receipts)

    assert Enum.map(panel_trace.runs, & &1.operation_code) ==
             ["EXTRUDE", "CURE", "LAMINATE", "CUT"]

    assert {:ok, coil_trace} = Inventory.trace_forward(scope, 73, slitting.source)
    assert length(coil_trace.links) == 4

    assert MapSet.subset?(
             MapSet.new(slitting.outputs),
             MapSet.new(coil_trace.identities, & &1.id)
           )

    # The mixed-unit chain balances each native unit on its own, with a
    # variance per unit, and its genealogy still runs from every slit roll
    # back to both receipts.
    for {run, _request} <- coating.runs do
      {:ok, transaction} = Inventory.get_transaction(scope, 73, run.inventory_transaction_id)

      variances =
        for %{role: :variance} = entry <- transaction.entries,
            do: {entry.native_unit.code, Decimal.to_integer(entry.native_quantity)}

      assert variances == Map.fetch!(coating.variances, run.operation_code)
    end

    {:ok, roll_trace} = ProductionExecution.trace_backward(scope, 73, hd(coating.outputs))

    assert Enum.sort(Enum.map(roll_trace.material.receipts, & &1.id)) ==
             Enum.sort(coating.receipts)

    assert Enum.map(roll_trace.runs, & &1.operation_code) == ["COAT", "SLIT"]

    # The coating run was weighed in kilograms on both sides, so its yield
    # carries a mass balance across units that names the conversion version
    # each line was posted through: 20 kg of film and 30 kg of glue in, 48 kg
    # out. A later conversion version restates nothing already posted.
    {coat, _request} = coating.coat

    assert {:ok, %{cross_unit: [mass]} = run_yield} =
             ProductionExecution.get_run_yield(scope, 73, coat.id)

    assert mass.unit.code == "kg"
    assert Decimal.eq?(mass.input, 50) and Decimal.eq?(mass.output, 48)
    assert Decimal.eq?(mass.difference, 2)

    assert Enum.sort_by(mass.conversions, & &1.item_id) ==
             Enum.sort_by(
               [
                 %{
                   item_id: coating.conversions.film.item_id,
                   conversion_id: coating.conversions.film.id,
                   version: 1,
                   factor: coating.conversions.film.factor
                 },
                 %{
                   item_id: coating.conversions.coated.item_id,
                   conversion_id: coating.conversions.coated.id,
                   version: 1,
                   factor: coating.conversions.coated.factor
                 }
               ],
               & &1.item_id
             )

    {:ok, unit_yield} = ProductionExecution.get_unit_yield(scope, 73, coating.coated_lot)
    {:ok, balance} = Inventory.get_transaction_balance(scope, 73, coat.inventory_transaction_id)

    for {item, factor} <- [{coating.conversions.film, "5"}, {coating.conversions.coated, "8"}] do
      {:ok, %{version: 2}} = Inventory.define_conversion(scope, 73, item.item_id, kg.id, factor)
    end

    assert {:ok, ^run_yield} = ProductionExecution.get_run_yield(scope, 73, coat.id)
    assert {:ok, ^unit_yield} = ProductionExecution.get_unit_yield(scope, 73, coating.coated_lot)

    assert {:ok, ^balance} =
             Inventory.get_transaction_balance(scope, 73, coat.inventory_transaction_id)
  end

  # Foam: polyol and isocyanate extrude to a raw bun that loses blowing gas,
  # cures with a moisture loss, laminates with film, and cuts to panels and
  # offcut. Every observation stays as measured; each loss is a variance.
  defp foam_chain!(context) do
    %{scope: scope, kg: kg, receiving: receiving, slitter: line, yard: yard} = context

    [polyol, iso, raw, cured, film, laminate, panel, offcut] =
      items!(scope, kg, ~w(POLYOL ISO FOAM-RAW FOAM-CURED FILM LAMINATE PANEL OFFCUT))

    receipts =
      for {item, quantity, lot} <- [
            {polyol, 60, "POL-1"},
            {iso, 40, "ISO-1"},
            {film, 6, "FILM-1"}
          ] do
        {:ok, receipt} =
          Inventory.record_receipt(
            scope,
            73,
            request("FOAM-GRN-#{lot}",
              lines: [
                %{
                  item_id: item.id,
                  location_id: receiving.id,
                  quantity: quantity,
                  observation: "measured",
                  identity: %{kind: "lot", code: lot}
                }
              ]
            )
          )

        receipt
      end

    [polyol_lot, iso_lot, film_lot] = Enum.map(receipts, &hd(&1.entries).identity_id)

    order =
      order!(scope, kg, panel, "FOAM-BATCH-1", [
        {"EXTRUDE", [polyol, iso], [raw]},
        {"CURE", [raw], [cured]},
        {"LAMINATE", [cured, film], [laminate]},
        {"CUT", [laminate], [panel, offcut]}
      ])

    {extrude, [raw_lot]} =
      run!(
        scope,
        order,
        "FOAM-EX-1",
        [draw(polyol, receiving, 60, polyol_lot), draw(iso, receiving, 40, iso_lot)],
        [make(raw, line, 97, "RAW-1")],
        %{evidence: "Bun scale less mix weight", reconciliation_basis: "Blowing gas loss"}
      )

    {cure, [cured_lot]} =
      run!(
        scope,
        order,
        "FOAM-CU-1",
        [draw(raw, line, 97, raw_lot)],
        [make(cured, line, 95, "CURED-1")],
        %{evidence: "Post-cure weigh", reconciliation_basis: "Moisture loss in cure"}
      )

    {laminating, [laminate_lot]} =
      run!(
        scope,
        order,
        "FOAM-LA-1",
        [draw(cured, line, 95, cured_lot), draw(film, receiving, 5, film_lot)],
        [make(laminate, line, 100, "LAM-1")]
      )

    {cut, [panel_lot, _offcut_lot]} =
      run!(
        scope,
        order,
        "FOAM-CT-1",
        [draw(laminate, line, 100, laminate_lot)],
        [
          make(panel, line, 88, "PANEL-1", "derived", "finished"),
          make(offcut, yard, 12, "OFFCUT-1", "measured", "waste")
        ]
      )

    %{
      order: order,
      runs: [extrude, cure, laminating, cut],
      receipts: Enum.map(receipts, & &1.id),
      finished: panel_lot,
      stock: %{
        polyol: {polyol, receiving},
        iso: {iso, receiving},
        film: {film, receiving},
        raw: {raw, line},
        cured: {cured, line},
        panel: {panel, line},
        offcut: {offcut, yard}
      }
    }
  end

  # Coil slitting: two coils received by the coil unit, moved to the line,
  # and slit into two identified narrow coils and derived edge trim, with the
  # unweighed edge loss as a variance.
  defp slitting_chain!(context) do
    %{scope: scope, kg: kg, coil: coil, sheet: narrow, trim: trim} = context
    %{coil_unit: coil_unit, receiving: receiving, slitter: line, yard: yard} = context

    {:ok, receipt} =
      Inventory.record_receipt(
        scope,
        73,
        request("COIL-GRN-1",
          lines: [
            %{
              item_id: coil.id,
              location_id: receiving.id,
              quantity: 2,
              unit_id: coil_unit.id,
              observation: "counted",
              identity: %{kind: "lot", code: "HEAT-7"}
            }
          ]
        )
      )

    coil_lot = hd(receipt.entries).identity_id

    {:ok, _transfer} =
      Inventory.record_transfer(
        scope,
        73,
        request("COIL-MOVE-1",
          lines: [
            %{
              item_id: coil.id,
              identity_id: coil_lot,
              from_location_id: receiving.id,
              to_location_id: line.id,
              quantity: 500,
              observation: "declared"
            }
          ]
        )
      )

    order = order!(scope, kg, narrow, "SLIT-ORDER-1", [{"SLIT", [coil], [narrow, trim]}])

    {slit, outputs} =
      run!(
        scope,
        order,
        "SLIT-1",
        [draw(coil, line, 500, coil_lot)],
        [
          make(narrow, line, 160, "NARROW-A", "measured", "finished", "unit"),
          make(narrow, line, 160, "NARROW-B", "measured", "finished", "unit"),
          make(trim, yard, 15, "TRIM-7", "derived", "trim"),
          make(narrow, line, 160, "NARROW-C", "measured", "finished", "unit")
        ],
        %{evidence: "Slitter log", reconciliation_basis: "Coil weight less outputs"}
      )

    # A shipment is warehouse work, open to any caller.
    {:ok, _shipment} =
      Inventory.record_consumption(
        scope,
        73,
        request("SHIP-1",
          context: %{shipment: "SHP-1", destination: "Customer dock"},
          lines: [
            %{
              item_id: narrow.id,
              identity_id: List.last(outputs),
              location_id: line.id,
              quantity: 160,
              observation: "counted"
            }
          ]
        )
      )

    %{
      order: order,
      runs: [slit],
      source: coil_lot,
      outputs: outputs,
      stock: %{coil: {coil, line}, narrow: {narrow, line}, trim: {trim, yard}}
    }
  end

  # Coating and slitting: film stocked by area and glue by mass coat to a
  # roll stocked by area, then slit into counted rolls and weighed edge trim.
  # Every unit balances on its own, and each unit's difference is its own
  # variance: the glue's mass and the trim's mass have no counterpart in the
  # other unit, and rolls are counted, not conserved.
  defp coating_chain!(context) do
    %{scope: scope, kg: kg, receiving: receiving, slitter: line, yard: yard} = context
    {:ok, m2} = Inventory.create_unit(scope, 73, %{code: "m2", name: "Square metre"})
    {:ok, roll} = Inventory.create_unit(scope, 73, %{code: "roll", name: "Roll"})
    [film] = items!(scope, m2, ~w(WEB-FILM))
    [glue] = items!(scope, kg, ~w(WEB-GLUE))
    [coated] = items!(scope, m2, ~w(WEB-COATED))
    [rolls] = items!(scope, roll, ~w(WEB-ROLL))
    [edge] = items!(scope, kg, ~w(WEB-EDGE))

    receipts =
      for {item, quantity, lot} <- [{film, 200, "WEB-1"}, {glue, 30, "GLUE-1"}] do
        {:ok, receipt} =
          Inventory.record_receipt(
            scope,
            73,
            request("WEB-GRN-#{lot}",
              lines: [
                %{
                  item_id: item.id,
                  location_id: receiving.id,
                  quantity: quantity,
                  observation: "measured",
                  identity: %{kind: "lot", code: lot}
                }
              ]
            )
          )

        receipt
      end

    [film_lot, glue_lot] = Enum.map(receipts, &hd(&1.entries).identity_id)

    # The film and the coated roll are weighed on the coater: 1 kg of film is
    # 10 m2 and 1 kg of coated film is 4 m2.
    {:ok, film_kg} = Inventory.define_conversion(scope, 73, film.id, kg.id, "10")
    {:ok, coated_kg} = Inventory.define_conversion(scope, 73, coated.id, kg.id, "4")

    order =
      order!(scope, kg, rolls, "WEB-BATCH-1", [
        {"COAT", [film, glue], [coated]},
        {"SLIT", [coated], [rolls, edge]}
      ])

    {coat, [coated_lot]} =
      run!(
        scope,
        order,
        "WEB-CO-1",
        [
          Map.put(draw(film, receiving, 20, film_lot), :unit_id, kg.id),
          draw(glue, receiving, 30, glue_lot)
        ],
        [Map.put(make(coated, line, 48, "COATED-1"), :unit_id, kg.id)],
        %{
          units: [
            %{
              unit_id: m2.id,
              evidence: "Coater length counter",
              reconciliation_basis: "Film area in less coated area out"
            },
            %{
              unit_id: kg.id,
              evidence: "Glue pump totaliser",
              reconciliation_basis: "Glue applied to the film has no mass output in kilograms"
            }
          ]
        }
      )

    {slit, outputs} =
      run!(
        scope,
        order,
        "WEB-SL-1",
        [draw(coated, line, 192, coated_lot)],
        [
          make(rolls, line, 3, "ROLLS-1", "counted", "finished"),
          make(edge, yard, 4, "EDGE-1", "measured", "trim")
        ],
        %{
          units: [
            %{
              unit_id: m2.id,
              evidence: "Slitter log",
              reconciliation_basis: "Area in is not measured out"
            },
            %{
              unit_id: roll.id,
              evidence: "Slitter log: three rolls cut",
              reconciliation_basis: "Rolls are counted, not conserved"
            },
            %{
              unit_id: kg.id,
              evidence: "Edge trim scale ticket",
              reconciliation_basis: "Only the trim is weighed"
            }
          ]
        }
      )

    %{
      order: order,
      runs: [coat, slit],
      receipts: Enum.map(receipts, & &1.id),
      outputs: outputs,
      coat: coat,
      coated_lot: coated_lot,
      conversions: %{film: film_kg, coated: coated_kg},
      variances: %{
        "COAT" => [{"m2", 8}, {"kg", 30}],
        "SLIT" => [{"m2", 192}, {"roll", -3}, {"kg", -4}]
      },
      stock: %{
        film: {film, receiving},
        glue: {glue, receiving},
        coated: {coated, line},
        rolls: {rolls, line},
        edge: {edge, yard}
      }
    }
  end

  defp items!(scope, kg, skus) do
    for sku <- skus do
      {:ok, item} = Inventory.create_item(scope, 73, %{sku: sku, title: sku})
      {:ok, _material} = Inventory.register_material(scope, 73, item.id, kg.id)
      item
    end
  end

  # A product, one resource per operation, and an order on the first published
  # Formula/BOM and routing revisions. Each operation's items become formula
  # lines, so intermediates are both an input and an output.
  defp order!(scope, kg, product_item, code, operations) do
    {:ok, product} =
      ProductDefinition.create_product(scope, 73, product_item.id, %{code: code, name: code})

    lines =
      for {_code, inputs, outputs} <- operations,
          {role, items} <- [{"input", inputs}, {"output", outputs}],
          item <- items,
          uniq: true,
          do: %{item_id: item.id, unit_id: kg.id, role: role, quantity: 1}

    {:ok, formula} = ProductDefinition.publish_formula(scope, 73, product.id, %{lines: lines})

    {:ok, resource_type} =
      ProductDefinition.create_resource_type(scope, 73, %{
        code: "#{code}-MACHINE",
        name: "Machine"
      })

    routed =
      for {{operation, inputs, outputs}, sequence} <- Enum.with_index(operations, 1) do
        {:ok, resource} =
          ProductDefinition.create_resource(scope, 73, %{
            code: "#{code}-#{operation}",
            name: operation,
            resource_type_id: resource_type.id
          })

        %{
          code: operation,
          sequence: sequence,
          inputs: Enum.map(inputs, & &1.id),
          outputs: Enum.map(outputs, & &1.id),
          allowed_resource_ids: [resource.id]
        }
      end

    {:ok, routing} =
      ProductDefinition.publish_routing(scope, 73, product.id, %{operations: routed})

    {:ok, order} =
      ProductionExecution.create_order(scope, 73, %{
        code: code,
        kind: "batch",
        product_id: product.id,
        formula_version: formula.version,
        routing_version: routing.version
      })

    Map.put(order, :operations, Map.new(routed, &{&1.code, hd(&1.allowed_resource_ids)}))
  end

  # Completes the next routed operation whose items match the lines, and
  # returns the execution with the identities its outputs created, in order.
  defp run!(scope, order, request_id, inputs, outputs, variance \\ nil) do
    {:ok, %{routing: routing}} =
      ProductDefinition.select_revisions(
        scope,
        73,
        order.product_id,
        order.formula_version,
        order.routing_version
      )

    output_items = MapSet.new(outputs, & &1.item_id)

    operation =
      Enum.find(routing.operations, &MapSet.subset?(output_items, MapSet.new(&1["outputs"])))

    at = DateTime.add(DateTime.utc_now(), -3600, :second)

    request = %{
      request_id: request_id,
      operation_code: operation["code"],
      resource_id: order.operations[operation["code"]],
      operator_type: "user",
      operator_id: 9,
      evidence: "Run sheet #{request_id}",
      started_at: DateTime.add(at, -600, :second),
      completed_at: at,
      inputs: inputs,
      outputs: outputs,
      variance: variance
    }

    assert {:ok, run} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, request)

    {:ok, transaction} = Inventory.get_transaction(scope, 73, run.inventory_transaction_id)

    created =
      for %{role: :stock, native_quantity: quantity, identity_id: id} <- transaction.entries,
          Decimal.gt?(quantity, 0),
          do: id

    {{run, request}, created}
  end

  defp draw(item, location, quantity, identity_id),
    do: %{
      item_id: item.id,
      location_id: location.id,
      quantity: quantity,
      observation: "measured",
      identity_id: identity_id
    }

  defp make(item, location, quantity, code, observation \\ "measured", role \\ nil, kind \\ "lot") do
    %{
      item_id: item.id,
      location_id: location.id,
      quantity: quantity,
      observation: observation,
      identity: %{kind: kind, code: code}
    }
    |> then(&if(role, do: Map.put(&1, :output_role, role), else: &1))
  end

  defp line_key(line, sign),
    do:
      {line.item_id, line.location_id,
       Decimal.normalize(Decimal.mult(Decimal.new(line.quantity), sign))}

  # A line is kept as recorded, so a line posted in another unit compares by
  # its recorded quantity, signed as its stock effect.
  defp stock_lines(transaction) do
    for %{role: :stock} = entry <- transaction.entries do
      sign = if Decimal.negative?(entry.native_quantity), do: -1, else: 1

      {entry.item_id, entry.location_id,
       Decimal.normalize(Decimal.mult(entry.recorded_quantity, sign))}
    end
    |> Enum.sort()
  end
end
