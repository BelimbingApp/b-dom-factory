defmodule Bilimbi.Factory.ProductionExecution.FoamPackScenario do
  @moduledoc """
  Representative configuration and seed data for a generic foam pack chain at
  a packaging manufacturer. Values are test assumptions, not plant-confirmed
  settings; see docs/foam-pack-scenario.md.
  All material writes use Factory's public facades.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}

  import Bilimbi.Factory.Inventory.TestFixtures, only: [request: 2]
  import Bilimbi.Factory.ProductionExecution.TestFixtures, only: [install_authz!: 0]

  @company 73
  @hold_hours 7 * 24

  def seed!(%{scope: scope, kg: kg, receiving: receiving}) do
    install_authz!()

    {:ok, :stored} =
      Authz.put_principal_capability(
        scope,
        @company,
        :user,
        9,
        "factory.production-execution.material-hold.override",
        true
      )

    items =
      for sku <- ~w(VIRGIN RECYCLED FILM FOAM-ROLL LAMINATE CUT-800 TRIM WASTE PACK), into: %{} do
        {:ok, item} = Inventory.create_item(scope, @company, %{sku: sku, title: sku})
        {:ok, _} = Inventory.register_material(scope, @company, item.id, kg.id)
        {sku, item}
      end

    locations =
      for {key, code} <- [
            cure: "CURE-A",
            line: "EXTRUDER-A",
            convert: "CONVERT-A",
            finished: "FINISHED"
          ],
          into: %{} do
        {:ok, location} = Inventory.create_location(scope, @company, %{code: code, name: code})
        {key, location}
      end

    times = timeline()

    {:ok, virgin_receipt} =
      Inventory.record_receipt(
        scope,
        @company,
        request("FP-LORRY-1",
          actor_id: 11,
          effective_at: times.receipt,
          evidence: "delivery note DN-1; supplier SUP-1; vehicle JQK-1234; weigh ticket WT-1",
          receipt_measurement: %{
            supplier_declared: 72,
            measured_gross: 812,
            tare: 742,
            net: 70,
            unit_id: kg.id,
            weighing_point_ref: "RCV"
          },
          lines: [
            line(items["VIRGIN"], receiving, 70, "measured", "VIRGIN-LOT-1", "lot")
            |> Map.put(:unit_id, kg.id)
          ]
        )
      )

    {:ok, recycle_receipt} =
      Inventory.record_receipt(
        scope,
        @company,
        request("FP-RECYCLE-1",
          effective_at: times.receipt,
          evidence: "delivery note DN-2; supplier SUP-2",
          lines: [line(items["RECYCLED"], receiving, 30, "measured", "RECYCLE-LOT-1", "lot")]
        )
      )

    {:ok, film_receipt} =
      Inventory.record_receipt(
        scope,
        @company,
        request("FP-FILM-1",
          effective_at: times.receipt,
          lines: [line(items["FILM"], receiving, 4, "measured", "FILM-LOT-1", "lot")]
        )
      )

    [virgin_id, recycle_id, film_id] =
      Enum.map([virgin_receipt, recycle_receipt, film_receipt], &stock_identity!/1)

    for {code, item, id, quantity} <- [
          {"VIRGIN", items["VIRGIN"], virgin_id, 70},
          {"RECYCLED", items["RECYCLED"], recycle_id, 30},
          {"FILM", items["FILM"], film_id, 4}
        ] do
      {:ok, _} =
        Inventory.record_transfer(
          scope,
          @company,
          request("FP-STAGE-#{code}",
            effective_at: times.stage,
            lines: [move(item, receiving, locations.line, quantity, id)]
          )
        )
    end

    operations = [
      {"EXTRUDE", ~w(VIRGIN RECYCLED), ~w(FOAM-ROLL)},
      {"LAMINATE", ~w(FOAM-ROLL FILM), ~w(LAMINATE)},
      {"CUT", ~w(LAMINATE), ~w(CUT-800 TRIM WASTE)},
      {"PACK", ~w(CUT-800), ~w(PACK WASTE)}
    ]

    {:ok, product} =
      ProductDefinition.create_product(scope, @company, items["PACK"].id, %{
        code: "FOAM-800",
        name: "Representative 800 mm foam pack"
      })

    formula_lines =
      for {role, skus} <- [
            {"input", ~w(VIRGIN RECYCLED FILM FOAM-ROLL LAMINATE CUT-800)},
            {"output", ~w(FOAM-ROLL LAMINATE CUT-800 TRIM WASTE PACK)}
          ],
          sku <- skus do
        %{item_id: items[sku].id, unit_id: kg.id, role: role, quantity: 1}
        |> then(fn line ->
          if role == "input" and sku == "FOAM-ROLL",
            do: Map.put(line, :material_hold_rule, %{"hours" => @hold_hours}),
            else: line
        end)
      end

    {:ok, formula} =
      ProductDefinition.publish_formula(scope, @company, product.id, %{
        lines: formula_lines,
        process_config: %{
          process_family: "LDPE foam",
          output_roles: %{"CUT-800" => "product", "TRIM" => "trim", "WASTE" => "waste"}
        }
      })

    {:ok, resource_type} =
      ProductDefinition.create_resource_type(scope, @company, %{code: "MACHINE", name: "Machine"})

    routed =
      for {{code, inputs, outputs}, sequence} <- Enum.with_index(operations, 1) do
        {:ok, resource} =
          ProductDefinition.create_resource(scope, @company, %{
            code: "FP-#{code}",
            name: code,
            resource_type_id: resource_type.id
          })

        %{
          code: code,
          sequence: sequence,
          inputs: Enum.map(inputs, &items[&1].id),
          outputs: Enum.map(outputs, &items[&1].id),
          allowed_resource_ids: [resource.id]
        }
      end

    {:ok, routing} =
      ProductDefinition.publish_routing(scope, @company, product.id, %{
        operations: routed,
        process_config: %{process_family: "LDPE foam"}
      })

    {:ok, order} =
      ProductionExecution.create_order(scope, @company, %{
        code: "FP-FORECAST-1",
        kind: "batch",
        product_id: product.id,
        formula_version: formula.version,
        routing_version: routing.version,
        demand_ref: "forecast:2026-09:sample"
      })

    resources = Map.new(routed, &{&1.code, hd(&1.allowed_resource_ids)})

    config = %{
      scope: Authentication.sign_in(scope, 9, @company),
      items: items,
      locations: locations,
      order: order,
      resources: resources,
      times: times
    }

    {extrude, extrude_tx} =
      run!(
        config,
        "EXTRUDE",
        "FP-EX-1",
        times.extrude,
        [
          draw(items["VIRGIN"], locations.line, 70, virgin_id),
          draw(items["RECYCLED"], locations.line, 30, recycle_id)
        ],
        [
          line(
            items["FOAM-ROLL"],
            locations.line,
            48,
            "measured",
            "ROLL-A",
            "unit",
            "width_mm=1200;thickness_mm=2;length_m=100;colour=blue"
          ),
          line(
            items["FOAM-ROLL"],
            locations.line,
            48,
            "measured",
            "ROLL-B",
            "unit",
            "width_mm=1200;thickness_mm=2;length_m=100;colour=blue"
          )
        ],
        %{
          evidence: "FP-EX-1 run sheet",
          reconciliation_basis: "4 kg representative extrusion loss"
        }
      )

    [roll_a, roll_b] = output_ids(extrude_tx)

    {:ok, roll_move} =
      Inventory.record_transfer(
        scope,
        @company,
        request("FP-ROLLS-TO-CURE",
          effective_at: times.cure_move,
          evidence: "Scanned roll labels into cure bay",
          lines: [
            move(items["FOAM-ROLL"], locations.line, locations.cure, 48, roll_a),
            move(items["FOAM-ROLL"], locations.line, locations.cure, 48, roll_b)
          ]
        )
      )

    {:ok, cure_stock_after_move} =
      Inventory.get_stock_position(scope, @company, items["FOAM-ROLL"].id, locations.cure.id)

    {:ok, roll_a_identity} = Inventory.get_identity(scope, @company, roll_a)

    {:ok, roll_source} =
      Inventory.get_transaction(scope, @company, roll_a_identity.source_transaction_id)

    {:error, :material_held} =
      run(
        config,
        "LAMINATE",
        "FP-LA-REFUSED",
        times.early_laminate,
        [
          draw(items["FOAM-ROLL"], locations.cure, 48, roll_a),
          draw(items["FILM"], locations.line, 2, film_id)
        ],
        [line(items["LAMINATE"], locations.convert, 49, "measured", "LAM-A", "unit")],
        %{evidence: "Lamination weigh", reconciliation_basis: "1 kg representative process loss"}
      )

    {lam_a, lam_a_tx} =
      run!(
        config,
        "LAMINATE",
        "FP-LA-1",
        times.early_laminate,
        [
          draw(items["FOAM-ROLL"], locations.cure, 48, roll_a),
          draw(items["FILM"], locations.line, 2, film_id)
        ],
        [line(items["LAMINATE"], locations.convert, 49, "measured", "LAM-A", "unit")],
        %{evidence: "Lamination weigh", reconciliation_basis: "1 kg representative process loss"},
        %{reason: "Representative supervised release"}
      )

    {lam_b, lam_b_tx} =
      run!(
        config,
        "LAMINATE",
        "FP-LA-2",
        times.mature_laminate,
        [
          draw(items["FOAM-ROLL"], locations.cure, 48, roll_b),
          draw(items["FILM"], locations.line, 2, film_id)
        ],
        [line(items["LAMINATE"], locations.convert, 49, "measured", "LAM-B", "unit")],
        %{evidence: "Lamination weigh", reconciliation_basis: "1 kg representative process loss"}
      )

    laminates = [stock_identity!(lam_a_tx), stock_identity!(lam_b_tx)]

    cuts =
      for {suffix, laminate_id, at} <- [
            {"A", hd(laminates), times.cut_a},
            {"B", List.last(laminates), times.cut_b}
          ] do
        {execution, tx} =
          run!(
            config,
            "CUT",
            "FP-CUT-#{suffix}",
            at,
            [draw(items["LAMINATE"], locations.convert, 49, laminate_id)],
            [
              line(
                items["CUT-800"],
                locations.convert,
                32,
                "measured",
                "CUT-#{suffix}",
                "unit",
                "target_width_mm=800;source_width_mm=1200",
                "product"
              ),
              line(
                items["TRIM"],
                locations.convert,
                14,
                "derived",
                "TRIM-#{suffix}",
                "lot",
                "width_mm=400;basis=width ratio",
                "trim"
              ),
              line(
                items["WASTE"],
                locations.convert,
                2,
                "measured",
                "WASTE-CUT-#{suffix}",
                "lot",
                "Scale ticket",
                "waste"
              )
            ],
            %{
              evidence: "Cut yield sheet #{suffix}",
              reconciliation_basis: "1 kg representative cut difference"
            }
          )

        {execution, tx}
      end

    cut_ids = Enum.map(cuts, fn {_run, tx} -> hd(output_ids(tx)) end)

    packs =
      for {suffix, cut_id, at} <- [
            {"A", hd(cut_ids), times.pack_a},
            {"B", List.last(cut_ids), times.pack_b}
          ] do
        {execution, tx} =
          run!(
            config,
            "PACK",
            "FP-PACK-#{suffix}",
            at,
            [draw(items["CUT-800"], locations.convert, 32, cut_id)],
            [
              line(
                items["PACK"],
                locations.finished,
                31,
                "counted",
                "PACK-#{suffix}",
                "unit",
                "Representative pack label",
                "finished"
              ),
              line(
                items["WASTE"],
                locations.convert,
                1,
                "measured",
                "WASTE-PACK-#{suffix}",
                "lot",
                "Packing loss",
                "waste"
              )
            ]
          )

        {execution, tx}
      end

    pack_a = packs |> hd() |> elem(1) |> output_ids() |> hd()

    {:ok, shipment} =
      Inventory.record_consumption(
        scope,
        @company,
        request("FP-DESPATCH-1",
          effective_at: times.despatch,
          context: %{shipment: "shipment:SHP-1", destination: "customer:DEST-1"},
          evidence: "Despatch note D-1",
          lines: [draw(items["PACK"], locations.finished, 31, pack_a)]
        )
      )

    %{
      config: config,
      receipts: [virgin_receipt, recycle_receipt, film_receipt],
      virgin_id: virgin_id,
      roll_ids: [roll_a, roll_b],
      roll_move: roll_move,
      cure_stock_after_move: cure_stock_after_move,
      roll_source: roll_source,
      extrude: {extrude, extrude_tx},
      laminations: [{lam_a, lam_a_tx}, {lam_b, lam_b_tx}],
      cuts: cuts,
      packs: packs,
      pack_a: pack_a,
      shipment: shipment
    }
  end

  defp timeline do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    days = fn n -> DateTime.add(now, -n * 86_400, :second) end

    %{
      receipt: days.(12),
      stage: days.(11),
      extrude: days.(9),
      cure_move: DateTime.add(days.(9), 60, :second),
      early_laminate: days.(8),
      cut_a: days.(7),
      pack_a: days.(6),
      despatch: days.(5),
      mature_laminate: days.(1),
      cut_b: DateTime.add(days.(1), 3600, :second),
      pack_b: DateTime.add(days.(1), 7200, :second)
    }
  end

  defp line(item, location, quantity, observation, code, kind, evidence \\ nil, role \\ nil) do
    %{
      item_id: item.id,
      location_id: location.id,
      quantity: quantity,
      observation: observation,
      identity:
        %{kind: kind, code: code}
        |> maybe_dimensions(code)
    }
    |> put_optional(:evidence, evidence)
    |> put_optional(:output_role, role)
  end

  defp maybe_dimensions(identity, "ROLL-" <> _) do
    Map.put(identity, :dimensions, %{
      width: %{value: 1200, unit: "mm", provenance: "measured"},
      length: %{value: 100, unit: "m", provenance: "measured"},
      thickness: %{value: 2, unit: "mm", provenance: "measured"}
    })
  end

  defp maybe_dimensions(identity, "CUT-" <> _) do
    Map.put(identity, :dimensions, %{width: %{value: 800, unit: "mm", provenance: "nominal"}})
  end

  defp maybe_dimensions(identity, _), do: identity

  defp draw(item, location, quantity, identity_id),
    do: %{
      item_id: item.id,
      location_id: location.id,
      quantity: quantity,
      observation: "measured",
      identity_id: identity_id
    }

  defp move(item, from, to, quantity, identity_id),
    do: %{
      item_id: item.id,
      from_location_id: from.id,
      to_location_id: to.id,
      quantity: quantity,
      observation: "counted",
      identity_id: identity_id
    }

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp stock_identity!(tx),
    do:
      tx.entries
      |> Enum.find(&(&1.role == :stock && Decimal.gt?(&1.native_quantity, 0)))
      |> Map.fetch!(:identity_id)

  defp output_ids(tx) do
    for entry <- tx.entries,
        entry.role == :stock and Decimal.gt?(entry.native_quantity, 0),
        do: entry.identity_id
  end

  defp run!(config, code, request_id, at, inputs, outputs, variance \\ nil, override \\ nil) do
    {:ok, execution} = run(config, code, request_id, at, inputs, outputs, variance, override)

    {:ok, tx} =
      Inventory.get_transaction(config.scope, @company, execution.inventory_transaction_id)

    {execution, tx}
  end

  defp run(config, code, request_id, at, inputs, outputs, variance, override \\ nil) do
    attrs =
      %{
        request_id: request_id,
        operation_code: code,
        resource_id: config.resources[code],
        operator_type: "user",
        operator_id: 9,
        started_at: DateTime.add(at, -600, :second),
        completed_at: at,
        evidence: "Run sheet #{request_id}",
        inputs: inputs,
        outputs: outputs,
        variance: variance
      }
      |> put_optional(:hold_override, override)

    ProductionExecution.complete_operation(config.scope, @company, config.order.id, :live, attrs)
  end
end
