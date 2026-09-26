defmodule Bilimbi.Factory.ProductionExecution.SbgScenario do
  @moduledoc """
  Synthetic SBG configuration and production facts. The assumptions are listed
  in docs/sbg-scenario.md; no AX connection or customer Extension is used.
  """

  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}

  import Bilimbi.Factory.Inventory.TestFixtures, only: [request: 2]

  @company 73

  def seed!(%{scope: scope, kg: kg, receiving: receiving}) do
    items =
      for sku <- ~w(BA BOPP ADDITIVE GLUE-WET GLUE-DRY COATED SLIT-600 SLIT-300 TRIM WASTE),
          into: %{} do
        {:ok, item} = Inventory.create_item(scope, @company, %{sku: sku, title: sku})
        {:ok, _} = Inventory.register_material(scope, @company, item.id, kg.id)
        {sku, item}
      end

    locations =
      for code <- ~w(REACTOR-A COATER-A SLITTER-A), into: %{} do
        {:ok, location} = Inventory.create_location(scope, @company, %{code: code, name: code})
        {code, location}
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    at = fn days -> DateTime.add(now, -days * 86_400, :second) end

    receipts =
      for {sku, quantity, code} <- [
            {"BA", 70, "BA-LOT-1"},
            {"ADDITIVE", 30, "ADDITIVE-LOT-1"},
            {"BOPP", 50, "BOPP-LOT-1"}
          ],
          into: %{} do
        {:ok, tx} =
          Inventory.record_receipt(
            scope,
            @company,
            request("SBG-RCV-#{sku}",
              effective_at: at.(32),
              evidence: "synthetic receiving ticket; source=representative fixture",
              lines: [make(items[sku], receiving, quantity, code, "lot")]
            )
          )

        {sku, {tx, output_id(tx)}}
      end

    glue_config = %{
      process_family: "adhesive glue",
      reactor_capacity_kg: 120,
      glue_type: "representative type A",
      recipe_revision: "R1",
      previous_batch: "SBG-GLUE-BATCH-0",
      cleaning_sequence: "CLEAN-1",
      quality_result_ref: "quality:pending"
    }

    glue =
      order!(
        scope,
        kg,
        items["GLUE-DRY"],
        "SBG-GLUE-BATCH-1",
        "batch",
        [
          {"MIX-WET", ~w(BA ADDITIVE), ~w(GLUE-WET), "REACTOR-A"},
          {"DRY", ~w(GLUE-WET), ~w(GLUE-DRY), "REACTOR-A"}
        ],
        glue_config
      )

    coating =
      order!(
        scope,
        kg,
        items["COATED"],
        "SBG-PO-COAT-1",
        "order",
        [
          {"COAT", ~w(BOPP GLUE-DRY), ~w(COATED), "COATER-A"}
        ],
        %{process_family: "adhesive coating", coating_line: "COATER-A"}
      )

    slitting =
      order!(
        scope,
        kg,
        items["SLIT-600"],
        "SBG-PO-SLIT-1",
        "order",
        [
          {"SLIT", ~w(COATED), ~w(SLIT-600 SLIT-300 TRIM WASTE), "SLITTER-A"}
        ],
        %{process_family: "tape slitting", source_width_mm: 1200}
      )

    {wet, wet_tx, wet_attrs} =
      run!(
        scope,
        glue,
        :import,
        "SBG-AX-GLUE-WET-1",
        at.(30),
        [
          draw(items["BA"], receiving, 70, receipt_id(receipts, "BA")),
          draw(items["ADDITIVE"], receiving, 30, receipt_id(receipts, "ADDITIVE"))
        ],
        [make(items["GLUE-WET"], locations["REACTOR-A"], 98, "GLUE-WET-1", "lot")],
        %{
          evidence: "synthetic AX extract batch AX-SNAPSHOT-1; wet scale",
          reconciliation_basis: "2 kg representative mixing loss"
        }
      )

    {dry, dry_tx, _dry_attrs} =
      run!(
        scope,
        glue,
        :import,
        "SBG-AX-GLUE-DRY-1",
        at.(29),
        [draw(items["GLUE-WET"], locations["REACTOR-A"], 98, output_id(wet_tx))],
        [make(items["GLUE-DRY"], locations["REACTOR-A"], 80, "GLUE-DRY-1", "lot")],
        %{
          evidence: "synthetic AX extract batch AX-SNAPSHOT-1; dry scale",
          reconciliation_basis: "18 kg representative drying loss"
        }
      )

    {coat, coat_tx, _coat_attrs} =
      run!(
        scope,
        coating,
        :live,
        "SBG-COAT-1",
        at.(2),
        [
          draw(items["BOPP"], receiving, 50, receipt_id(receipts, "BOPP")),
          draw(items["GLUE-DRY"], locations["REACTOR-A"], 80, output_id(dry_tx))
        ],
        [
          make(
            items["COATED"],
            locations["COATER-A"],
            125,
            "COATED-ROLL-1",
            "unit",
            "measured",
            "good"
          )
        ],
        %{
          evidence: "synthetic coating scale; PO SBG-PO-COAT-1; line COATER-A",
          reconciliation_basis: "5 kg representative coating loss"
        }
      )

    {slit, slit_tx, _slit_attrs} =
      run!(
        scope,
        slitting,
        :live,
        "SBG-SLIT-1",
        at.(1),
        [draw(items["COATED"], locations["COATER-A"], 125, output_id(coat_tx))],
        [
          make(
            items["SLIT-600"],
            locations["SLITTER-A"],
            60,
            "SLIT-600-1",
            "unit",
            "measured",
            "good",
            "source_width_mm=1200;target_width_mm=600"
          ),
          make(
            items["SLIT-300"],
            locations["SLITTER-A"],
            30,
            "SLIT-300-1",
            "unit",
            "measured",
            "good",
            "source_width_mm=1200;target_width_mm=300"
          ),
          make(
            items["TRIM"],
            locations["SLITTER-A"],
            30,
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
        %{
          evidence: "synthetic slitting sheet; 1200 to 600+300+300 mm",
          reconciliation_basis: "2 kg representative slit difference"
        }
      )

    %{
      items: items,
      locations: locations,
      receipts: receipts,
      glue_config: glue_config,
      orders: %{glue: glue, coating: coating, slitting: slitting},
      runs: %{
        wet: {wet, wet_tx},
        dry: {dry, dry_tx},
        coat: {coat, coat_tx},
        slit: {slit, slit_tx}
      },
      slit_ids: output_ids(slit_tx),
      import_request: wet_attrs
    }
  end

  defp order!(scope, kg, item, code, kind, operations, config) do
    {:ok, product} =
      ProductDefinition.create_product(scope, @company, item.id, %{code: code, name: code})

    lines =
      for {_operation, inputs, outputs, _resource} <- operations,
          {role, skus} <- [{"input", inputs}, {"output", outputs}],
          sku <- skus,
          uniq: true,
          do: %{item_id: get_item!(scope, sku).id, unit_id: kg.id, role: role, quantity: 1}

    {:ok, formula} =
      ProductDefinition.publish_formula(scope, @company, product.id, %{
        lines: lines,
        process_config: %{process_family: config.process_family}
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
        process_config: %{process_family: config.process_family}
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

  defp run!(scope, config, source, request_id, at, inputs, outputs, variance) do
    code =
      case request_id do
        "SBG-AX-GLUE-WET-1" -> "MIX-WET"
        "SBG-AX-GLUE-DRY-1" -> "DRY"
        "SBG-COAT-1" -> "COAT"
        "SBG-SLIT-1" -> "SLIT"
      end

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
      identity: %{kind: kind, code: code}
    }
    |> optional(:output_role, role)
    |> optional(:evidence, evidence)
  end

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
  defp output_id(tx), do: tx |> output_ids() |> hd()

  defp output_ids(tx),
    do:
      for(
        entry <- tx.entries,
        entry.role == :stock and Decimal.gt?(entry.native_quantity, 0),
        do: entry.identity_id
      )
end
