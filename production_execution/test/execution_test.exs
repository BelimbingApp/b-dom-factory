defmodule Bilimbi.Factory.ProductionExecution.ExecutionTest do
  use Bilimbi.Base.Database.DataCase, async: true
  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}
  alias Ecto.Adapters.SQL
  import Bilimbi.Factory.Inventory.TestFixtures

  setup do
    context = mill!()

    for sql <- [
          "CREATE TEMPORARY TABLE factory_products (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), code text NOT NULL, name text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code), UNIQUE(company_id, item_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_resources (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, kind text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_formula_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, lines jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_routing_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, operations jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_production_orders (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, kind text NOT NULL CHECK (kind IN ('order', 'batch')), product_id bigint NOT NULL REFERENCES factory_products(id), formula_version integer NOT NULL CHECK (formula_version > 0), routing_version integer NOT NULL CHECK (routing_version > 0), demand_ref text, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_operation_executions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), order_id bigint NOT NULL REFERENCES factory_production_orders(id), request_id text NOT NULL, request_fingerprint text NOT NULL, source text NOT NULL CHECK (source IN ('live', 'import')), operation_code text NOT NULL, resource_id bigint NOT NULL REFERENCES factory_resources(id), operator_type text NOT NULL, operator_id bigint NOT NULL, started_at timestamp(6) NOT NULL, completed_at timestamp(6) NOT NULL CHECK (started_at <= completed_at), inputs jsonb[] NOT NULL, outputs jsonb[] NOT NULL, variance jsonb, evidence text NOT NULL, inventory_transaction_id bigint NOT NULL, formula_version integer NOT NULL, routing_version integer NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(company_id, request_id)) ON COMMIT PRESERVE ROWS"
        ],
        do: SQL.query!(Repo, sql, [])

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

    Map.merge(context, %{order: order, resource: resource})
  end

  defp execution(context, request_id, quantity \\ 100) do
    %{coil: coil, sheet: sheet, receiving: location, resource: resource} = context
    at = DateTime.add(DateTime.utc_now(), -3600, :second)

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
        %{item_id: coil.id, location_id: location.id, quantity: quantity, observation: "measured"}
      ],
      outputs: [
        %{
          item_id: sheet.id,
          location_id: location.id,
          quantity: quantity,
          observation: "measured"
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

    assert replay.id == completed.id

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
