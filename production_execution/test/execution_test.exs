defmodule Bilimbi.Factory.ProductionExecution.ExecutionTest do
  use Bilimbi.Base.Database.DataCase, async: false
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}
  alias Ecto.Adapters.SQL
  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  setup do
    context = mill!()

    create_production_tables!()

    %{scope: scope, coil: coil, sheet: sheet, kg: kg, receiving: receiving} = context

    {:ok, product} =
      ProductDefinition.create_product(scope, 73, sheet.id, %{code: "SHEET", name: "Sheet"})

    {:ok, resource} =
      ProductDefinition.create_resource(scope, 73, %{
        code: "SLIT",
        name: "Slitter",
        kind: "machine"
      })

    formula_attrs = %{
      lines: [
        %{item_id: coil.id, unit_id: kg.id, role: "input", quantity: 100},
        %{item_id: sheet.id, unit_id: kg.id, role: "output", quantity: 100}
      ]
    }

    {:ok, formula1} = ProductDefinition.publish_formula(scope, 73, product.id, formula_attrs)
    {:ok, _formula2} = ProductDefinition.publish_formula(scope, 73, product.id, formula_attrs)

    routing_attrs = %{
      operations: [
        %{
          code: "SLIT",
          sequence: 1,
          inputs: [coil.id],
          outputs: [sheet.id],
          allowed_resource_ids: [resource.id]
        }
      ]
    }

    {:ok, routing1} = ProductDefinition.publish_routing(scope, 73, product.id, routing_attrs)
    {:ok, _routing2} = ProductDefinition.publish_routing(scope, 73, product.id, routing_attrs)

    {:ok, order} =
      ProductionExecution.create_order(scope, 73, %{
        code: "PO-7",
        kind: "batch",
        product_id: product.id,
        formula_version: formula1.version,
        routing_version: routing1.version
      })

    {:ok, receipt} =
      Inventory.record_receipt(
        scope,
        73,
        request("R-1",
          lines: [
            %{
              item_id: coil.id,
              location_id: receiving.id,
              quantity: 100,
              observation: "measured",
              identity: %{kind: "unit", code: "COIL-UNIT-1"}
            }
          ]
        )
      )

    Map.merge(context, %{order: order, resource: resource, receipt: receipt, product: product})
  end

  defp held_order(context) do
    %{scope: scope, product: product, coil: coil, sheet: sheet, kg: kg} = context

    {:ok, formula} =
      ProductDefinition.publish_formula(scope, 73, product.id, %{
        lines: [
          %{
            item_id: coil.id,
            unit_id: kg.id,
            role: "input",
            quantity: 100,
            material_hold_rule: %{"hours" => 24}
          },
          %{item_id: sheet.id, unit_id: kg.id, role: "output", quantity: 100}
        ]
      })

    {:ok, order} =
      ProductionExecution.create_order(scope, 73, %{
        code: "PO-HOLD",
        kind: "batch",
        product_id: product.id,
        formula_version: formula.version,
        routing_version: 1
      })

    attrs = execution(context, "EX-HOLD")
    completed_at = DateTime.utc_now()
    attrs = %{attrs | started_at: DateTime.add(completed_at, -300), completed_at: completed_at}

    {order, attrs}
  end

  defp authz_tables! do
    for sql <- [
          "CREATE TEMPORARY TABLE base_authz_roles (id bigserial PRIMARY KEY, company_id bigint, name text NOT NULL, code text NOT NULL, description text, is_system boolean NOT NULL DEFAULT false, grant_all boolean NOT NULL DEFAULT false, created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_role_capabilities (id bigserial PRIMARY KEY, role_id bigint NOT NULL REFERENCES base_authz_roles(id), capability_key text NOT NULL, created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_principal_roles (id bigserial PRIMARY KEY, company_id bigint, principal_type text NOT NULL, principal_id bigint NOT NULL, role_id bigint NOT NULL REFERENCES base_authz_roles(id), created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_principal_capabilities (id bigserial PRIMARY KEY, company_id bigint, principal_type text NOT NULL, principal_id bigint NOT NULL, capability_key text NOT NULL, is_allowed boolean NOT NULL, created_at timestamp(0), updated_at timestamp(0), UNIQUE(company_id, principal_type, principal_id, capability_key)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_decision_logs (id bigserial PRIMARY KEY, company_id bigint, actor_type text NOT NULL, actor_id bigint NOT NULL, acting_for_user_id bigint, capability text NOT NULL, resource_type text, resource_id text, allowed boolean NOT NULL, reason_code text NOT NULL, applied_policies json, context json, trace_id text, occurred_at timestamp(0) NOT NULL, created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS"
        ],
        do: SQL.query!(Repo, sql, [])

    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"factory/production_execution", :bilimbi_factory_production_execution,
             Bilimbi.Factory.ProductionExecution.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    authz = ContributionValidator.validate_contributions!(entries)
    snapshot = ContributionRegistry.build!([])

    ContributionRegistry.put_snapshot_for_test!(%{
      snapshot
      | consumers: Map.put(snapshot.consumers, :authz, authz)
    })

    on_exit(&ContributionRegistry.clear_for_test!/0)
  end

  test "a held material unit is refused without an override", context do
    {order, attrs} = held_order(context)

    assert {:error, :material_held} =
             ProductionExecution.complete_operation(context.scope, 73, order.id, :live, attrs)

    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.HoldOverride)
  end

  test "material that has met its hold is consumed without an override", context do
    %{scope: scope, coil: coil, receiving: location} = context
    {order, attrs} = held_order(context)

    receive_unit = fn code, hours_before ->
      {:ok, receipt} =
        Inventory.record_receipt(
          scope,
          73,
          request("R-" <> code,
            effective_at: DateTime.add(attrs.completed_at, -hours_before * 3600),
            lines: [
              %{
                item_id: coil.id,
                location_id: location.id,
                quantity: 100,
                observation: "measured",
                identity: %{kind: "unit", code: code}
              }
            ]
          )
        )

      hd(receipt.entries).identity_id
    end

    uncured = receive_unit.("COIL-23H", 23)
    cured = receive_unit.("COIL-25H", 25)
    draw = fn identity_id -> [Map.put(hd(attrs.inputs), :identity_id, identity_id)] end

    assert {:error, :material_held} =
             complete(context, order, %{attrs | request_id: "EX-23H", inputs: draw.(uncured)})

    assert {:ok, completed} =
             complete(context, order, %{attrs | request_id: "EX-25H", inputs: draw.(cured)})

    assert {:ok, []} = ProductionExecution.list_hold_overrides(scope, 73, completed.id)
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.HoldOverride)
  end

  test "routing process configuration also enforces the hold", context do
    %{scope: scope, product: product, coil: coil, sheet: sheet, resource: resource} = context

    {:ok, routing} =
      ProductDefinition.publish_routing(scope, 73, product.id, %{
        operations: [
          %{
            code: "SLIT",
            sequence: 1,
            inputs: [coil.id],
            outputs: [sheet.id],
            allowed_resource_ids: [resource.id]
          }
        ],
        process_config: %{material_hold_rules: %{Integer.to_string(coil.id) => %{"hours" => 24}}}
      })

    {:ok, order} =
      ProductionExecution.create_order(scope, 73, %{
        code: "PO-ROUTE-HOLD",
        kind: "batch",
        product_id: product.id,
        formula_version: 1,
        routing_version: routing.version
      })

    attrs = execution(context, "EX-ROUTE-HOLD")
    completed_at = DateTime.utc_now()
    attrs = %{attrs | started_at: DateTime.add(completed_at, -300), completed_at: completed_at}

    assert {:error, :material_held} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, attrs)
  end

  defp grant_override!(context, user_id) do
    assert {:ok, :stored} =
             Authz.put_principal_capability(
               context.scope,
               73,
               :user,
               user_id,
               "factory.production-execution.material-hold.override",
               true
             )
  end

  defp complete(context, order, attrs, source \\ :live),
    do: ProductionExecution.complete_operation(context.scope, 73, order.id, source, attrs)

  defp override_decisions do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM base_authz_decision_logs WHERE capability = $1",
        ["factory.production-execution.material-hold.override"]
      )

    count
  end

  test "hold override requires a reason and the declared capability", context do
    authz_tables!()
    {order, attrs} = held_order(context)
    actor = Authz.actor(:user, 10, context.scope, 73)

    assert {:error, :invalid_hold_override} =
             complete(
               context,
               order,
               Map.put(attrs, :hold_override, %{actor: actor, reason: " "})
             )

    assert {:error, :hold_override_denied} =
             complete(
               context,
               order,
               Map.put(attrs, :hold_override, %{actor: actor, reason: "urgent"})
             )

    assert override_decisions() == 1
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.HoldOverride)
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
    assert {:ok, [_receipt]} = Inventory.list_transactions(context.scope, 73)
  end

  test "an override requires an Authz actor in the execution's company", context do
    authz_tables!()
    grant_override!(context, 9)
    {order, attrs} = held_order(context)

    assert {:error, :invalid_hold_override} =
             complete(
               context,
               order,
               Map.put(attrs, :hold_override, %{actor_type: "user", actor_id: 9, reason: "urgent"})
             )

    actor = Authz.actor(:user, 10, context.scope, 73)

    assert {:error, :invalid_hold_override} =
             complete(
               context,
               order,
               Map.put(attrs, :hold_override, %{actor: actor, actor_id: 9, reason: "urgent"})
             )

    other_company = Authz.actor(:user, 9, context.scope, 74)

    assert {:error, :hold_override_actor_mismatch} =
             complete(
               context,
               order,
               Map.put(attrs, :hold_override, %{actor: other_company, reason: "urgent"})
             )

    assert override_decisions() == 0
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.HoldOverride)
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
  end

  test "authorized override records the affected source atomically with consumption", context do
    authz_tables!()
    grant_override!(context, 9)
    {order, attrs} = held_order(context)
    actor = Authz.actor(:user, 9, context.scope, 73)
    attrs = Map.put(attrs, :hold_override, %{actor: actor, reason: "Batch release"})

    assert {:ok, completed} = complete(context, order, attrs)

    assert {:ok, [override]} =
             ProductionExecution.list_hold_overrides(context.scope, 73, completed.id)

    assert override.actor_type == "user" and override.actor_id == 9
    assert override.recorded_by_type == "user" and override.recorded_by_id == 9
    assert override.source == "live" and is_nil(override.evidence)
    assert override.reason == "Batch release"
    assert override.identity_id == hd(attrs.inputs).identity_id
    assert override.source_transaction_id == context.receipt.id
    assert override.inventory_transaction_id == completed.inventory_transaction_id

    assert {:ok, transaction} =
             Inventory.get_transaction(context.scope, 73, completed.inventory_transaction_id)

    assert transaction.kind == :transform
    assert {:ok, ^completed} = complete(context, order, attrs)
    assert override_decisions() == 1

    assert_raise Postgrex.Error, fn ->
      SQL.query!(
        Repo,
        "UPDATE factory_material_hold_overrides SET reason = 'changed' WHERE id = $1",
        [override.id]
      )
    end
  end

  test "an imported override records its historical approver and time, not the importer",
       context do
    authz_tables!()
    grant_override!(context, 9)
    {order, attrs} = held_order(context)
    importer = Authz.actor(:user, 9, context.scope, 73)
    historical_at = DateTime.add(attrs.completed_at, -60)

    assert {:error, :invalid_hold_override} =
             complete(
               context,
               order,
               Map.put(attrs, :hold_override, %{
                 actor: importer,
                 reason: "Batch release",
                 evidence: "Legacy MES override 4411"
               }),
               :import
             )

    attrs =
      Map.put(attrs, :hold_override, %{
        actor: importer,
        reason: "Batch release",
        evidence: "Legacy MES override 4411 by QA lead",
        occurred_at: historical_at,
        approver: %{type: "user", id: 12}
      })

    assert {:error, :invalid_hold_override} = complete(context, order, attrs, :live)
    assert {:ok, completed} = complete(context, order, attrs, :import)

    assert {:ok, [override]} =
             ProductionExecution.list_hold_overrides(context.scope, 73, completed.id)

    assert override.source == "import"
    assert override.evidence == "Legacy MES override 4411 by QA lead"
    assert override.actor_type == "user" and override.actor_id == 12
    assert override.recorded_by_type == "user" and override.recorded_by_id == 9
    assert DateTime.compare(override.occurred_at, historical_at) == :eq
  end

  test "an imported override without a named approver records none", context do
    authz_tables!()
    grant_override!(context, 9)
    {order, attrs} = held_order(context)

    attrs =
      Map.put(attrs, :hold_override, %{
        actor: Authz.actor(:user, 9, context.scope, 73),
        reason: "Batch release",
        evidence: "Legacy MES override 4412",
        occurred_at: DateTime.add(attrs.completed_at, -60)
      })

    assert {:ok, completed} = complete(context, order, attrs, :import)

    assert {:ok, [override]} =
             ProductionExecution.list_hold_overrides(context.scope, 73, completed.id)

    assert is_nil(override.actor_type) and is_nil(override.actor_id)
    assert override.recorded_by_id == 9
  end

  test "one override decision is logged per affected unit", context do
    authz_tables!()
    grant_override!(context, 9)
    {order, attrs} = held_order(context)
    [input] = attrs.inputs
    half = %{input | quantity: 50}

    attrs =
      attrs
      |> Map.put(:inputs, [half, half])
      |> Map.put(:hold_override, %{
        actor: Authz.actor(:user, 9, context.scope, 73),
        reason: "Batch release"
      })

    assert {:ok, completed} = complete(context, order, attrs)

    assert {:ok, [_override]} =
             ProductionExecution.list_hold_overrides(context.scope, 73, completed.id)

    assert override_decisions() == 1
  end

  test "failed posting leaves neither override nor consumption", context do
    authz_tables!()
    {order, attrs} = held_order(context)

    grant_override!(context, 9)

    attrs =
      Map.put(attrs, :hold_override, %{
        actor: Authz.actor(:user, 9, context.scope, 73),
        reason: "Batch release"
      })

    attrs = put_in(attrs.inputs, [%{hd(attrs.inputs) | quantity: 101}])

    attrs =
      Map.put(attrs, :variance, %{evidence: "scale discrepancy", reconciliation_basis: "weigh"})

    assert {:error, :insufficient_stock} =
             ProductionExecution.complete_operation(context.scope, 73, order.id, :live, attrs)

    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.HoldOverride)
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
    assert {:ok, transactions} = Inventory.list_transactions(context.scope, 73)
    assert length(transactions) == 1
  end

  test "override evidence failure rolls back the Inventory effect", context do
    authz_tables!()
    {order, attrs} = held_order(context)

    grant_override!(context, 9)

    attrs =
      Map.put(attrs, :hold_override, %{
        actor: Authz.actor(:user, 9, context.scope, 73),
        reason: "Batch release"
      })

    SQL.query!(
      Repo,
      "CREATE FUNCTION pg_temp.reject_override_insert() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'override insert refused'; END $$",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TRIGGER reject_override_insert BEFORE INSERT ON factory_material_hold_overrides FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_override_insert()",
      []
    )

    assert_raise Postgrex.Error, fn ->
      ProductionExecution.complete_operation(context.scope, 73, order.id, :live, attrs)
    end

    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.HoldOverride)
    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
    assert {:ok, transactions} = Inventory.list_transactions(context.scope, 73)
    assert length(transactions) == 1
  end

  defp execution(context, request_id, quantity \\ 100) do
    %{coil: coil, sheet: sheet, receiving: location, resource: resource} = context
    at = DateTime.add(DateTime.utc_now(), -3600, :second)

    source_entry =
      Enum.find(context.receipt.entries, &(&1.role == :stock and &1.item_id == coil.id))

    %{
      request_id: request_id,
      operation_code: "SLIT",
      resource_id: resource.id,
      operator_type: "user",
      operator_id: 9,
      evidence: "Batch log",
      started_at: DateTime.add(at, -600, :second),
      completed_at: at,
      inputs: [
        %{
          item_id: coil.id,
          location_id: location.id,
          quantity: quantity,
          observation: "measured",
          identity_id: source_entry.identity_id
        }
      ],
      outputs: [
        %{
          item_id: sheet.id,
          location_id: location.id,
          quantity: quantity,
          observation: "measured",
          identity: %{kind: "unit", code: "SHEET-" <> request_id}
        }
      ]
    }
  end

  test "live completion posts once and retains exact selected revisions", context do
    %{scope: scope, order: order, sheet: sheet, receiving: location} = context
    attrs = execution(context, "EX-1")

    assert {:ok, completed} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, attrs)

    assert completed.formula_version == 1 and completed.routing_version == 1
    assert completed.source == "live"

    assert {:ok, transaction} =
             Inventory.get_transaction(scope, 73, completed.inventory_transaction_id)

    assert transaction.kind == :transform
    assert transaction.posting_authority == inspect(ProductionExecution)

    assert transaction.context == %{
             operation_execution: "EX-1",
             order_or_batch: "PO-7",
             work_centre: Integer.to_string(context.resource.id)
           }

    assert {:ok, position} = Inventory.get_stock_position(scope, 73, sheet.id, location.id)
    assert Decimal.eq?(position.quantity, 100)

    assert {:ok, replay} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, attrs)

    assert replay == completed
    assert {:ok, ^completed} = ProductionExecution.get_execution(scope, 73, completed.id)

    assert {:error, :request_id_conflict} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, %{
               attrs
               | evidence: "Other"
             })
  end

  test "historical import uses the same contract and keeps its effective time", context do
    %{scope: scope, order: order} = context
    attrs = execution(context, "EX-HIST")

    assert {:ok, completed} =
             ProductionExecution.complete_operation(scope, 73, order.id, :import, attrs)

    assert completed.source == "import"

    assert {:ok, transaction} =
             Inventory.get_transaction(scope, 73, completed.inventory_transaction_id)

    assert transaction.effective_at == attrs.completed_at
    assert DateTime.compare(transaction.recorded_at, attrs.completed_at) == :gt
  end

  test "production trace follows Inventory ancestry backward and forward with run context",
       context do
    %{scope: scope, order: order, coil: coil, receiving: location, resource: resource} = context

    assert {:ok, receipt} =
             Inventory.record_receipt(
               scope,
               73,
               request("TRACE-RECEIPT",
                 lines: [
                   %{
                     item_id: coil.id,
                     location_id: location.id,
                     quantity: 100,
                     observation: "measured",
                     identity: %{kind: "lot", code: "COIL-TRACE"}
                   }
                 ]
               )
             )

    source_id = hd(receipt.entries).identity_id

    outputs =
      for {request_id, output_code} <- [{"TRACE-1", "SHEET-1"}, {"TRACE-2", "SHEET-2"}] do
        attrs = execution(context, request_id, 50)

        attrs = %{
          attrs
          | inputs: [Map.put(hd(attrs.inputs), :identity_id, source_id)],
            outputs: [Map.put(hd(attrs.outputs), :identity, %{kind: "lot", code: output_code})]
        }

        assert {:ok, run} =
                 ProductionExecution.complete_operation(scope, 73, order.id, :live, attrs)

        assert {:ok, transaction} =
                 Inventory.get_transaction(scope, 73, run.inventory_transaction_id)

        {run, List.last(transaction.entries).identity_id}
      end

    [{first_run, first_output_id}, {second_run, second_output_id}] = outputs
    assert first_output_id != second_output_id

    assert {:ok, backward} = ProductionExecution.trace_backward(scope, 73, first_output_id)
    assert Enum.map(backward.material.receipts, & &1.id) == [receipt.id]
    assert Enum.map(backward.material.identities, & &1.id) == [source_id, first_output_id]

    assert backward.material.links == [
             {source_id, first_output_id, first_run.inventory_transaction_id}
           ]

    assert [run] = backward.runs
    assert run.id == first_run.id
    assert run.order.code == order.code
    assert run.operation_code == "SLIT"
    assert run.resource == resource

    assert {:ok, forward} = ProductionExecution.trace_forward(scope, 73, source_id)

    assert Enum.map(forward.material.identities, & &1.id) ==
             Enum.sort([source_id, first_output_id, second_output_id])

    assert Enum.sort(forward.material.links) ==
             Enum.sort([
               {source_id, first_output_id, first_run.inventory_transaction_id},
               {source_id, second_output_id, second_run.inventory_transaction_id}
             ])

    assert Enum.map(forward.runs, & &1.id) == [first_run.id, second_run.id]
    assert Enum.all?(forward.runs, &(&1.resource == resource))

    assert {:error, :identity_not_found} =
             ProductionExecution.trace_backward(scope, 74, first_output_id)
  end

  test "forward trace includes runs that drew a lot without an identified output", context do
    %{scope: scope, order: order, coil: coil, receiving: location} = context

    assert {:ok, receipt} =
             Inventory.record_receipt(
               scope,
               73,
               request("COIL-A-RECEIPT",
                 lines: [
                   %{
                     item_id: coil.id,
                     location_id: location.id,
                     quantity: 100,
                     observation: "measured",
                     identity: %{kind: "lot", code: "COIL-A"}
                   }
                 ]
               )
             )

    coil_a = hd(receipt.entries).identity_id
    attrs = execution(context, "COIL-A-SLIT", 40)

    attrs = %{
      attrs
      | inputs: [Map.put(hd(attrs.inputs), :identity_id, coil_a)],
        outputs: [Map.delete(hd(attrs.outputs), :identity)]
    }

    assert {:error, :identity_required} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, attrs)

    assert {:ok, slit} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, %{
               attrs
               | outputs: []
             })

    consume = execution(context, "COIL-A-CONSUME", 30)

    assert {:ok, consumption} =
             ProductionExecution.complete_operation(scope, 73, order.id, :import, %{
               consume
               | inputs: [Map.put(hd(consume.inputs), :identity_id, coil_a)],
                 outputs: []
             })

    assert {:ok, forward} = ProductionExecution.trace_forward(scope, 73, coil_a)
    assert forward.material.links == []

    assert Enum.sort(Enum.map(forward.runs, & &1.id)) == Enum.sort([slit.id, consumption.id])
    assert {:ok, backward} = ProductionExecution.trace_backward(scope, 73, coil_a)
    assert backward.runs == []
  end

  test "variance without both inputs and outputs is refused", context do
    %{scope: scope, order: order} = context

    attrs =
      context
      |> execution("EX-VAR")
      |> Map.merge(%{
        inputs: [],
        variance: %{evidence: "scale drift", reconciliation_basis: "weigh"}
      })

    assert {:error, :invalid_execution} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, attrs)

    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
  end

  test "posting failure leaves no execution or material effect", context do
    %{scope: scope, order: order, sheet: sheet, receiving: location} = context
    attrs = execution(context, "EX-FAIL", 101)

    assert {:error, :insufficient_stock} =
             ProductionExecution.complete_operation(scope, 73, order.id, :live, attrs)

    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
    assert {:ok, position} = Inventory.get_stock_position(scope, 73, sheet.id, location.id)
    assert Decimal.eq?(position.quantity, 0)
    assert Inventory.list_transactions(scope, 73) |> elem(1) |> length() == 1
  end

  test "a failed execution insert rolls back a completed Inventory posting", context do
    %{scope: scope, order: order, coil: coil, sheet: sheet, receiving: location} = context

    SQL.query!(
      Repo,
      """
      CREATE FUNCTION pg_temp.reject_execution() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'execution insert refused';
      END
      $$
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TRIGGER reject_execution BEFORE INSERT ON factory_operation_executions
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_execution()
      """,
      []
    )

    assert_raise Postgrex.Error, fn ->
      ProductionExecution.complete_operation(
        scope,
        73,
        order.id,
        :live,
        execution(context, "EX-ROLLBACK")
      )
    end

    assert [] = Repo.all(Bilimbi.Factory.ProductionExecution.Schemas.Execution)
    assert {:ok, transactions} = Inventory.list_transactions(scope, 73)
    assert length(transactions) == 1

    for {item, expected} <- [{coil, 100}, {sheet, 0}] do
      assert {:ok, position} = Inventory.get_stock_position(scope, 73, item.id, location.id)
      assert Decimal.eq?(position.quantity, expected)
    end
  end
end
