defmodule Bilimbi.Factory.ProductionExecution.MixCoatSlitScenario do
  @moduledoc """
  Synthetic configuration and production facts for a generic mix, coat, and
  slit chain at a tape manufacturer ("Company A"). The stand-in values are
  listed in docs/mix-coat-slit-scenario.md; no source-system connection or
  customer Extension is used.
  """

  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}

  import Bilimbi.Factory.Inventory.TestFixtures, only: [request: 2]

  @company 73

  # Glue, additives, and waste are stocked by mass; film, coated film, slit
  # rolls, and trim by area. Coating and slitting therefore mix native units.
  def seed!(%{scope: scope, kg: kg, receiving: receiving}) do
    {:ok, m2} = Inventory.create_unit(scope, @company, %{code: "m2", name: "Square metre"})

    units = %{
      "RESIN" => kg,
      "ADDITIVE" => kg,
      "GLUE-WET" => kg,
      "GLUE-DRY" => kg,
      "WASTE" => kg,
      "FILM" => m2,
      "COATED" => m2,
      "SLIT-600" => m2,
      "SLIT-300" => m2,
      "TRIM" => m2
    }

    items =
      for {sku, unit} <- units, into: %{} do
        {:ok, item} = Inventory.create_item(scope, @company, %{sku: sku, title: sku})
        {:ok, _} = Inventory.register_material(scope, @company, item.id, unit.id)
        {sku, item}
      end

    # Representative area-to-mass conversions for the film and the coated
    # roll only: 1 kg of film is 10 m2 and 1 kg of coated film is 4 m2. Slit
    # rolls and trim have none, so their slitting run has no cross-unit
    # balance.
    {:ok, _} = Inventory.define_conversion(scope, @company, items["FILM"].id, kg.id, "10")
    {:ok, _} = Inventory.define_conversion(scope, @company, items["COATED"].id, kg.id, "4")

    locations =
      for code <- ~w(REACTOR-A COATER-A SLITTER-A), into: %{} do
        {:ok, location} = Inventory.create_location(scope, @company, %{code: code, name: code})
        {code, location}
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    at = fn days -> DateTime.add(now, -days * 86_400, :second) end

    receipts =
      for {sku, quantity, code} <- [
            {"RESIN", 70, "RESIN-LOT-1"},
            {"ADDITIVE", 30, "ADDITIVE-LOT-1"},
            {"FILM", 500, "FILM-LOT-1"}
          ],
          into: %{} do
        {:ok, tx} =
          Inventory.record_receipt(
            scope,
            @company,
            request("RCV-#{sku}",
              effective_at: at.(32),
              evidence: "synthetic receiving ticket; source=representative fixture",
              lines: [make(items[sku], receiving, quantity, code, "lot")]
            )
          )

        {sku, {tx, output_id(tx)}}
      end

    glue =
      order!(
        scope,
        units,
        items["GLUE-DRY"],
        "GLUE-BATCH-1",
        "batch",
        [
          {"MIX-WET", ~w(RESIN ADDITIVE), ~w(GLUE-WET), "REACTOR-A"},
          {"DRY", ~w(GLUE-WET), ~w(GLUE-DRY), "REACTOR-A"}
        ],
        "adhesive glue"
      )

    coating =
      order!(
        scope,
        units,
        items["COATED"],
        "PO-COAT-1",
        "order",
        [
          {"COAT", ~w(FILM GLUE-DRY), ~w(COATED), "COATER-A"}
        ],
        "adhesive coating"
      )

    slitting =
      order!(
        scope,
        units,
        items["SLIT-600"],
        "PO-SLIT-1",
        "order",
        [
          {"SLIT", ~w(COATED), ~w(SLIT-600 SLIT-300 TRIM WASTE), "SLITTER-A"}
        ],
        "tape slitting"
      )

    {wet, wet_tx, wet_attrs} =
      run!(
        scope,
        glue,
        :import,
        "IMPORT-GLUE-WET-1",
        "MIX-WET",
        at.(30),
        [
          draw(items["RESIN"], receiving, 70, receipt_id(receipts, "RESIN")),
          draw(items["ADDITIVE"], receiving, 30, receipt_id(receipts, "ADDITIVE"))
        ],
        [make(items["GLUE-WET"], locations["REACTOR-A"], 98, "GLUE-WET-1", "lot")],
        %{
          evidence: "synthetic source-system extract SNAPSHOT-1; wet scale",
          reconciliation_basis: "2 kg representative mixing loss"
        }
      )

    {dry, dry_tx, _dry_attrs} =
      run!(
        scope,
        glue,
        :import,
        "IMPORT-GLUE-DRY-1",
        "DRY",
        at.(29),
        [draw(items["GLUE-WET"], locations["REACTOR-A"], 98, output_id(wet_tx))],
        [make(items["GLUE-DRY"], locations["REACTOR-A"], 80, "GLUE-DRY-1", "lot")],
        %{
          evidence: "synthetic source-system extract SNAPSHOT-1; dry scale",
          reconciliation_basis: "18 kg representative drying loss"
        }
      )

    {coat, coat_tx, _coat_attrs} =
      run!(
        scope,
        coating,
        :live,
        "COAT-1",
        "COAT",
        at.(2),
        [
          draw(items["FILM"], receiving, 500, receipt_id(receipts, "FILM")),
          draw(items["GLUE-DRY"], locations["REACTOR-A"], 80, output_id(dry_tx))
        ],
        [
          make(
            items["COATED"],
            locations["COATER-A"],
            500,
            "COATED-ROLL-1",
            "unit",
            "measured",
            "good"
          )
        ],
        # Area balances exactly. The glue's 80 kg has no mass output to
        # balance against, because the coated roll is measured by area, so
        # it is a variance in kilograms with its own evidence.
        %{
          units: [
            %{
              unit_id: kg.id,
              evidence: "synthetic glue pump totaliser; PO PO-COAT-1; line COATER-A",
              reconciliation_basis:
                "80 kg dry glue applied to the film; the coated roll is measured by area, not weighed"
            }
          ]
        }
      )

    {slit, slit_tx, _slit_attrs} =
      run!(
        scope,
        slitting,
        :live,
        "SLIT-1",
        "SLIT",
        at.(1),
        [draw(items["COATED"], locations["COATER-A"], 500, output_id(coat_tx))],
        [
          make(
            items["SLIT-600"],
            locations["SLITTER-A"],
            250,
            "SLIT-600-1",
            "unit",
            "measured",
            "good",
            "source_width_mm=1200;target_width_mm=600"
          ),
          make(
            items["SLIT-300"],
            locations["SLITTER-A"],
            125,
            "SLIT-300-1",
            "unit",
            "measured",
            "good",
            "source_width_mm=1200;target_width_mm=300"
          ),
          make(
            items["TRIM"],
            locations["SLITTER-A"],
            120,
            "TRIM-1",
            "lot",
            "derived",
            "trim",
            "remaining_width_mm=300;basis=representative width ratio"
          ),
          make(
            items["WASTE"],
            locations["SLITTER-A"],
            3,
            "WASTE-1",
            "lot",
            "measured",
            "waste",
            "synthetic scale ticket"
          )
        ],
        # Area differs by 5 m2 under the shared evidence; the 3 kg of waste
        # is the only mass observed, so kilograms carry their own.
        %{
          evidence: "synthetic slitting sheet; 1200 to 600+300+300 mm",
          reconciliation_basis: "5 m2 representative slit difference",
          units: [
            %{
              unit_id: kg.id,
              evidence: "synthetic waste scale ticket",
              reconciliation_basis:
                "waste is weighed; the coated roll and slit rolls are measured by area"
            }
          ]
        }
      )

    %{
      items: items,
      locations: locations,
      receipts: receipts,
      orders: %{glue: glue, coating: coating, slitting: slitting},
      runs: %{
        wet: {wet, wet_tx},
        dry: {dry, dry_tx},
        coat: {coat, coat_tx},
        slit: {slit, slit_tx}
      },
      import_request: wet_attrs
    }
  end

  defp order!(scope, units, item, code, kind, operations, process_family) do
    {:ok, product} =
      ProductDefinition.create_product(scope, @company, item.id, %{code: code, name: code})

    lines =
      for {_operation, inputs, outputs, _resource} <- operations,
          {role, skus} <- [{"input", inputs}, {"output", outputs}],
          sku <- skus,
          uniq: true,
          do: %{
            item_id: get_item!(scope, sku).id,
            unit_id: units[sku].id,
            role: role,
            quantity: 1
          }

    {:ok, formula} =
      ProductDefinition.publish_formula(scope, @company, product.id, %{
        lines: lines,
        process_config: %{process_family: process_family}
      })

    resources =
      for resource_code <- operations |> Enum.map(&elem(&1, 3)) |> Enum.uniq(), into: %{} do
        {:ok, resource} =
          ProductDefinition.create_resource(scope, @company, %{
            code: resource_code,
            name: resource_code,
            kind: "machine"
          })

        {resource_code, resource.id}
      end

    routed =
      for {{operation, inputs, outputs, resource_code}, sequence} <-
            Enum.with_index(operations, 1) do
        %{
          code: operation,
          sequence: sequence,
          inputs: Enum.map(inputs, &get_item!(scope, &1).id),
          outputs: Enum.map(outputs, &get_item!(scope, &1).id),
          allowed_resource_ids: [resources[resource_code]]
        }
      end

    {:ok, routing} =
      ProductDefinition.publish_routing(scope, @company, product.id, %{
        operations: routed,
        process_config: %{process_family: process_family}
      })

    {:ok, order} =
      ProductionExecution.create_order(scope, @company, %{
        code: code,
        kind: kind,
        product_id: product.id,
        formula_version: formula.version,
        routing_version: routing.version
      })

    %{order: order, resources: Map.new(routed, &{&1.code, hd(&1.allowed_resource_ids)})}
  end

  defp get_item!(scope, sku) do
    {:ok, item} = Inventory.get_item_by_sku(scope, @company, sku)
    item
  end

  defp run!(scope, config, source, request_id, code, at, inputs, outputs, variance) do
    attrs = %{
      request_id: request_id,
      operation_code: code,
      resource_id: config.resources[code],
      operator_type: "user",
      operator_id: 9,
      started_at: DateTime.add(at, -600, :second),
      completed_at: at,
      evidence: "#{request_id}; source=#{source}; synthetic fixture; operator=9; helper=12",
      inputs: inputs,
      outputs: outputs,
      variance: variance
    }

    {:ok, run} =
      ProductionExecution.complete_operation(scope, @company, config.order.id, source, attrs)

    {:ok, tx} = Inventory.get_transaction(scope, @company, run.inventory_transaction_id)
    {run, tx, attrs}
  end

  defp make(
         item,
         location,
         quantity,
         code,
         kind,
         observation \\ "measured",
         role \\ nil,
         evidence \\ nil
       ) do
    %{
      item_id: item.id,
      location_id: location.id,
      quantity: quantity,
      observation: observation,
      identity:
        %{kind: kind, code: code}
        |> maybe_dimensions(code)
    }
    |> optional(:output_role, role)
    |> optional(:evidence, evidence)
  end

  defp maybe_dimensions(identity, "COATED-ROLL-" <> _) do
    Map.put(identity, :dimensions, %{width: %{value: 1200, unit: "mm", provenance: "nominal"}})
  end

  defp maybe_dimensions(identity, "SLIT-600-" <> _) do
    Map.put(identity, :dimensions, %{width: %{value: 600, unit: "mm", provenance: "measured"}})
  end

  defp maybe_dimensions(identity, "SLIT-300-" <> _) do
    Map.put(identity, :dimensions, %{width: %{value: 300, unit: "mm", provenance: "measured"}})
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

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp receipt_id(receipts, sku), do: receipts |> Map.fetch!(sku) |> elem(1)

  defp output_id(tx),
    do:
      Enum.find_value(
        tx.entries,
        &(&1.role == :stock and Decimal.gt?(&1.native_quantity, 0) and &1.identity_id)
      )
end
