defmodule Bilimbi.Factory.ProductDefinitionTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductDefinition, as: Definitions
  alias Ecto.Adapters.SQL
  import Bilimbi.Factory.Inventory.TestFixtures

  setup do
    create_inventory_tables!()

    SQL.query!(
      Repo,
      "CREATE TEMPORARY TABLE factory_products (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), code text NOT NULL, name text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code), UNIQUE(company_id, item_id)) ON COMMIT PRESERVE ROWS",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TEMPORARY TABLE factory_resources (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, kind text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code)) ON COMMIT PRESERVE ROWS",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TEMPORARY TABLE factory_formula_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, lines jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TEMPORARY TABLE factory_routing_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, operations jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
      []
    )

    insert_tenant!(%{id: 41, name: "Operator"})
    insert_tenant!(%{id: 42, name: "Other"})
    insert_company!(%{id: 73, tenant_id: 41, name: "Mill", code: "mill"})
    insert_company!(%{id: 74, tenant_id: 42, name: "Other", code: "other"})
    insert_company!(%{id: 75, tenant_id: 41, name: "Sister", code: "sister"})
    {:ok, scope} = Tenancy.scope(41)
    {:ok, other} = Tenancy.scope(42)
    %{scope: scope, other: other}
  end

  test "an order can select exact product, formula and routing revisions", %{scope: scope} do
    {:ok, input} = Inventory.create_item(scope, 73, %{sku: "COIL", title: "Coil"})
    {:ok, output} = Inventory.create_item(scope, 73, %{sku: "PANEL", title: "Panel"})
    {:ok, unit} = Inventory.create_unit(scope, 73, %{code: "pcs", name: "Pieces"})

    {:ok, product} =
      Definitions.create_product(scope, 73, output.id, %{code: "PANEL", name: "Panel"})

    {:ok, resource} =
      Definitions.create_resource(scope, 73, %{code: "PRESS", name: "Press", kind: "machine"})

    lines = [
      %{
        item_id: input.id,
        unit_id: unit.id,
        role: "input",
        quantity: "2",
        material_hold_rule: %{"hours" => 24}
      },
      %{
        item_id: output.id,
        unit_id: unit.id,
        role: "output",
        quantity: "1",
        output_role: "primary"
      }
    ]

    {:ok, first} =
      Definitions.publish_formula(scope, 73, product.id, %{
        lines: lines,
        process_config: %{process_family: "pressing", tolerances: %{"length_mm" => 1}}
      })

    {:ok, second} =
      Definitions.publish_formula(scope, 73, product.id, %{
        lines: lines,
        process_config: %{process_family: "pressing", tolerances: %{"length_mm" => 2}}
      })

    operation = %{
      code: "PRESS",
      sequence: 1,
      inputs: [input.id],
      outputs: [output.id],
      allowed_resource_ids: [resource.id]
    }

    {:ok, route1} = Definitions.publish_routing(scope, 73, product.id, %{operations: [operation]})

    {:ok, route2} =
      Definitions.publish_routing(scope, 73, product.id, %{
        operations: [operation],
        process_config: %{process_family: "pressing"}
      })

    assert {:ok, selected} =
             Definitions.select_revisions(scope, 73, product.id, first.version, route2.version)

    assert selected.product.item_id == output.id
    assert selected.formula.id == first.id
    assert selected.routing.id == route2.id
    assert selected.formula.process_config["tolerances"] == %{"length_mm" => 1}
    assert second.version == 2 and route1.version == 1

    assert {:error, :routing_not_found} =
             Definitions.select_revisions(scope, 73, product.id, first.version, 99)

    for version <- [nil, "1", 0] do
      assert {:error, :routing_not_found} =
               Definitions.select_revisions(scope, 73, product.id, first.version, version)

      assert {:error, :formula_not_found} =
               Definitions.get_formula_revision(scope, 73, product.id, version)
    end

    {:ok, wrong_output} =
      Definitions.publish_routing(scope, 73, product.id, %{
        operations: [%{operation | outputs: [input.id]}]
      })

    assert {:error, :routing_formula_mismatch} =
             Definitions.select_revisions(
               scope,
               73,
               product.id,
               first.version,
               wrong_output.version
             )
  end

  test "definitions refuse foreign items and resources across company boundaries", %{
    scope: scope,
    other: other
  } do
    {:ok, item} = Inventory.create_item(scope, 73, %{sku: "X", title: "X"})

    assert {:error, :company_not_found} =
             Definitions.create_product(other, 73, item.id, %{code: "X", name: "X"})

    assert {:error, :item_not_found} =
             Definitions.create_product(scope, 75, item.id, %{code: "X", name: "X"})

    {:ok, product} = Definitions.create_product(scope, 73, item.id, %{code: "X", name: "X"})
    assert {:error, :company_not_found} = Definitions.get_product(other, 73, product.id)

    {:ok, unit} = Inventory.create_unit(scope, 73, %{code: "pcs", name: "Pieces"})
    {:ok, other_item} = Inventory.create_item(scope, 73, %{sku: "Y", title: "Y"})

    assert {:error, :product_output_missing} =
             Definitions.publish_formula(scope, 73, product.id, %{
               lines: [%{item_id: other_item.id, unit_id: unit.id, role: "output", quantity: 1}]
             })

    assert {:error, :invalid_operations} =
             Definitions.publish_routing(scope, 73, product.id, %{
               operations: [
                 %{
                   code: "X",
                   sequence: 1,
                   inputs: [],
                   outputs: [item.id],
                   allowed_resource_ids: []
                 }
               ]
             })
  end
end
