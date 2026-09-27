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
      "CREATE TEMPORARY TABLE factory_resource_types (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, property_definitions jsonb[] NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, CONSTRAINT factory_resource_types_company_code_unique UNIQUE (company_id, code), UNIQUE(id, company_id)) ON COMMIT PRESERVE ROWS",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TEMPORARY TABLE factory_resources (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, resource_type_id bigint NOT NULL, properties jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(properties) = 'object'), inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code), CONSTRAINT factory_resources_resource_type_id_fkey FOREIGN KEY (resource_type_id, company_id) REFERENCES factory_resource_types (id, company_id)) ON COMMIT PRESERVE ROWS",
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
    configure_item_settings!(73, 41)
    configure_item_settings!(75, 41)
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

    {:ok, type} = Definitions.create_resource_type(scope, 73, %{code: "MACHINE", name: "Machine"})

    {:ok, resource} =
      Definitions.create_resource(scope, 73, %{
        code: "PRESS",
        name: "Press",
        resource_type_id: type.id
      })

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

  test "resource types are company configuration and validate their resources' properties", %{
    scope: scope,
    other: other
  } do
    definitions = [
      %{key: "capacity", label: "Capacity", value_type: "decimal", unit: "t/h", required: true},
      %{key: "lanes", label: "Lanes", value_type: "integer"},
      %{key: "certified", label: "Certified", value_type: "boolean"}
    ]

    assert {:ok, %{code: "LINE", property_definitions: [capacity | _]} = type} =
             Definitions.create_resource_type(scope, 73, %{
               code: " line ",
               name: "Line",
               property_definitions: definitions
             })

    assert capacity == %{
             "key" => "capacity",
             "label" => "Capacity",
             "value_type" => "decimal",
             "unit" => "t/h",
             "required" => true
           }

    assert {:ok, ^type} = Definitions.get_resource_type(scope, 73, type.id)
    {:ok, plain} = Definitions.create_resource_type(scope, 73, %{code: "CELL", name: "Cell"})
    assert plain.property_definitions == []
    assert {:ok, [^plain, ^type]} = Definitions.list_resource_types(scope, 73)

    assert {:error, %Ecto.Changeset{}} =
             Definitions.create_resource_type(scope, 73, %{code: "line", name: "Again"})

    assert {:error, :invalid_property_definitions} =
             Definitions.create_resource_type(scope, 73, %{
               code: "BAD",
               name: "Bad",
               property_definitions: [%{key: "x", label: "X", value_type: "text"}]
             })

    assert {:ok, %{resource_type_id: type_id, properties: properties} = resource} =
             Definitions.create_resource(scope, 73, %{
               code: "L1",
               name: "Line one",
               resource_type_id: type.id,
               properties: %{"lanes" => 4, capacity: "2.5"}
             })

    assert type_id == type.id
    assert properties == %{"capacity" => "2.5", "lanes" => 4}
    assert {:ok, ^resource} = Definitions.get_resource(scope, 73, resource.id)

    for properties <- [
          %{},
          %{capacity: "fast"},
          %{capacity: "1", lanes: "4"},
          %{capacity: "1", width: 1}
        ] do
      assert {:error, :invalid_properties} =
               Definitions.create_resource(scope, 73, %{
                 code: "L2",
                 name: "Line two",
                 resource_type_id: type.id,
                 properties: properties
               })
    end

    assert {:error, :invalid_properties} =
             Definitions.create_resource(scope, 73, %{
               code: "C1",
               name: "Cell one",
               resource_type_id: plain.id,
               properties: %{capacity: "1"}
             })

    assert {:ok, %{properties: %{}}} =
             Definitions.create_resource(scope, 73, %{
               code: "C1",
               name: "Cell one",
               resource_type_id: plain.id
             })

    # Types stay inside their company and tenant.
    assert {:error, :resource_type_not_found} = Definitions.get_resource_type(scope, 75, type.id)
    assert {:ok, []} = Definitions.list_resource_types(scope, 75)
    assert {:error, :company_not_found} = Definitions.get_resource_type(other, 73, type.id)
    assert {:error, :company_not_found} = Definitions.list_resource_types(other, 73)

    assert {:error, :company_not_found} =
             Definitions.create_resource_type(other, 73, %{code: "X", name: "X"})

    assert {:error, :resource_type_not_found} =
             Definitions.create_resource(scope, 75, %{
               code: "L9",
               name: "Foreign",
               resource_type_id: type.id
             })

    for missing <- [nil, 0, "1"] do
      assert {:error, :resource_type_not_found} =
               Definitions.create_resource(scope, 73, %{
                 code: "L9",
                 name: "Untyped",
                 resource_type_id: missing
               })
    end

    # The composite reference refuses what the API never writes.
    assert_raise Postgrex.Error, ~r/resource_type_id_fkey/, fn ->
      Repo.query!(
        "INSERT INTO factory_resources (company_id, code, name, resource_type_id, properties, inserted_at, updated_at) VALUES ($1, 'X', 'X', $2, '{}', now(), now())",
        [75, type.id]
      )
    end
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
