defmodule Bilimbi.Factory.Inventory.MaterialTest do
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Conversion
  alias Bilimbi.Factory.Inventory.Material
  alias Bilimbi.Factory.Inventory.MaterialType
  alias Bilimbi.Factory.Inventory.StockPosition

  import Bilimbi.Factory.Inventory.TestFixtures

  setup do
    create_inventory_tables!()
    insert_tenant!(%{id: 41, name: "Operator"})
    insert_tenant!(%{id: 42, name: "Customer", is_platform_operator: false})
    insert_company!(%{id: 73, tenant_id: 41, name: "Mill", code: "mill"})
    insert_company!(%{id: 74, tenant_id: 41, name: "Sister Mill", code: "sister"})
    configure_item_settings!(73, 41)
    configure_item_settings!(74, 41)

    {:ok, scope} = Tenancy.scope(41)
    {:ok, customer} = Tenancy.scope(42)
    {:ok, item} = Inventory.create_item(scope, 73, %{sku: "AL-COIL", title: "Aluminium coil"})
    {:ok, kg} = Inventory.create_unit(scope, 73, %{code: "kg", name: "Kilogram"})
    {:ok, coil} = Inventory.create_unit(scope, 73, %{code: "coil", name: "Coil"})
    {:ok, bay} = Inventory.create_location(scope, 73, %{code: "RM-01", name: "Raw material bay"})

    %{scope: scope, customer: customer, item: item, kg: kg, coil: coil, bay: bay}
  end

  describe "material identity" do
    test "a retired unit stays readable but cannot take new material or conversion", %{
      scope: scope,
      item: item
    } do
      {:ok, native} = Inventory.create_unit(scope, 73, %{code: "u1", name: "Unit one"})
      {:ok, alternate} = Inventory.create_unit(scope, 73, %{code: "u2", name: "Unit two"})

      assert {:ok, retired} = Inventory.retire_unit(scope, 73, alternate.id)
      assert retired.retired_at

      assert {:error, :unit_retired} =
               Inventory.register_material(scope, 73, item.id, alternate.id)

      assert {:ok, _} = Inventory.register_material(scope, 73, item.id, native.id)

      assert {:error, :unit_retired} =
               Inventory.define_conversion(scope, 73, item.id, alternate.id, "2")

      assert {:error, :unit_retired} =
               Inventory.rename_unit(scope, 73, alternate.id, %{name: "Other"})

      assert {:ok, ^retired} = Inventory.get_unit(scope, 73, alternate.id)
    end

    test "a unit is not retired while an active material is native to it", %{
      scope: scope,
      item: item
    } do
      {:ok, native} = Inventory.create_unit(scope, 73, %{code: "u1", name: "Unit one"})
      {:ok, _} = Inventory.register_material(scope, 73, item.id, native.id)

      assert {:error, :unit_in_use} = Inventory.retire_unit(scope, 73, native.id)

      {:ok, _} = Inventory.retire_material(scope, 73, item.id)
      assert {:ok, %{retired_at: retired_at}} = Inventory.retire_unit(scope, 73, native.id)
      assert retired_at
    end

    test "registers an item once, in its native unit", %{
      scope: scope,
      item: item,
      kg: kg,
      coil: coil
    } do
      assert {:error, :material_not_found} = Inventory.get_material(scope, 73, item.id)

      assert {:ok, %Material{item_id: item_id, sku: "AL-COIL", native_unit: ^kg} = material} =
               Inventory.register_material(scope, 73, item.id, kg.id)

      assert item_id == item.id
      assert {:ok, ^material} = Inventory.get_material(scope, 73, item.id)

      assert {:error, changeset} = Inventory.register_material(scope, 73, item.id, coil.id)
      assert %{item_id: [_]} = Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))
      assert {:ok, %Material{native_unit: ^kg}} = Inventory.get_material(scope, 73, item.id)
    end

    test "refuses an item or unit from another company", %{scope: scope, item: item, kg: kg} do
      {:ok, sister_unit} = Inventory.create_unit(scope, 74, %{code: "kg", name: "Kilogram"})
      {:ok, sister_item} = Inventory.create_item(scope, 74, %{sku: "S", title: "S"})

      assert {:error, :unit_not_found} =
               Inventory.register_material(scope, 73, item.id, sister_unit.id)

      assert {:error, :item_not_found} =
               Inventory.register_material(scope, 73, sister_item.id, kg.id)

      assert {:error, :item_not_found} = Inventory.get_material(scope, 74, item.id)
    end
  end

  describe "material types" do
    test "edits an unused type and retires it without deleting history", %{
      scope: scope,
      item: item
    } do
      {:ok, unit} = Inventory.create_unit(scope, 73, %{code: "u1", name: "Unit one"})
      {:ok, type} = Inventory.create_material_type(scope, 73, %{code: "TYPE_A", name: "Type A"})

      {:ok, updated} =
        Inventory.update_material_type(scope, 73, type.id, %{
          name: "Revised type",
          property_definitions: [%{key: "measure", label: "Measure", value_type: "integer"}]
        })

      assert updated.name == "Revised type"
      assert length(updated.property_definitions) == 1

      {:ok, _material} =
        Inventory.register_material(scope, 73, item.id, unit.id,
          material_type_id: type.id,
          properties: %{}
        )

      assert {:error, :material_type_in_use} =
               Inventory.update_material_type(scope, 73, type.id, %{
                 property_definitions: []
               })

      assert {:ok, retired} = Inventory.retire_material_type(scope, 73, type.id)
      assert retired.retired_at

      assert {:error, :material_type_retired} =
               Inventory.update_material_type(scope, 73, type.id, %{name: "Other"})

      assert {:error, :material_type_retired} = Inventory.retire_material_type(scope, 73, type.id)
      assert {:ok, ^retired} = Inventory.get_material_type(scope, 73, type.id)
    end

    @definitions [
      %{key: "thickness", label: "Thickness", value_type: "decimal", unit: "mm", required: true},
      %{key: "grade", label: "Grade", value_type: "string"},
      %{key: "layers", label: "Layers", value_type: "integer", required: false},
      %{key: "coated", label: "Coated", value_type: "boolean"}
    ]

    test "defines a company type and registers a material with validated values", context do
      %{scope: scope, item: item, kg: kg} = context

      assert {:ok, %MaterialType{code: "SHEET", property_definitions: definitions} = type} =
               Inventory.create_material_type(scope, 73, %{
                 code: " sheet ",
                 name: "Sheet stock",
                 property_definitions: @definitions
               })

      assert Enum.map(definitions, &{&1["key"], &1["value_type"], &1["unit"], &1["required"]}) ==
               [
                 {"thickness", "decimal", "mm", true},
                 {"grade", "string", nil, false},
                 {"layers", "integer", nil, false},
                 {"coated", "boolean", nil, false}
               ]

      assert {:ok, ^type} = Inventory.get_material_type(scope, 73, type.id)

      {:ok, plain} =
        Inventory.create_material_type(scope, 73, %{code: "BULK", name: "Bulk stock"})

      assert plain.property_definitions == []
      assert {:ok, [^plain, ^type]} = Inventory.list_material_types(scope, 73)

      assert {:ok, %Material{material_type_id: type_id, properties: properties} = material} =
               Inventory.register_material(scope, 73, item.id, kg.id,
                 material_type_id: type.id,
                 properties: %{"thickness" => "0.50", "grade" => " A1 ", "coated" => true}
               )

      assert type_id == type.id
      assert properties == %{"thickness" => "0.50", "grade" => "A1", "coated" => true}
      assert {:ok, ^material} = Inventory.get_material(scope, 73, item.id)
    end

    test "refuses values the type does not define, missing required, and wrong types", context do
      %{scope: scope, item: item, kg: kg} = context

      {:ok, type} =
        Inventory.create_material_type(scope, 73, %{
          code: "SHEET",
          name: "Sheet stock",
          property_definitions: @definitions
        })

      for properties <- [
            %{},
            %{"thickness" => "0.5", "colour" => "blue"},
            %{"thickness" => "thin"},
            %{"thickness" => 0.5},
            %{"thickness" => "1", "layers" => "3"},
            %{"thickness" => "1", "coated" => "yes"},
            %{"thickness" => "1", "grade" => ""},
            "not a map"
          ] do
        assert {:error, :invalid_properties} =
                 Inventory.register_material(scope, 73, item.id, kg.id,
                   material_type_id: type.id,
                   properties: properties
                 )
      end

      assert {:error, :invalid_properties} =
               Inventory.register_material(scope, 73, item.id, kg.id,
                 properties: %{"thickness" => "1"}
               )

      assert {:error, :material_not_found} = Inventory.get_material(scope, 73, item.id)

      assert {:ok, %Material{material_type_id: nil, properties: %{}}} =
               Inventory.register_material(scope, 73, item.id, kg.id)
    end

    test "refuses malformed definitions and a duplicate code", %{scope: scope} do
      for definitions <- [
            [%{key: "Thickness", label: "T", value_type: "decimal"}],
            [%{key: "thickness", label: "", value_type: "decimal"}],
            [%{key: "thickness", label: "T", value_type: "float"}],
            [%{key: "grade", label: "G", value_type: "string", unit: "mm"}],
            [%{key: "grade", label: "G", value_type: "string", required: "yes"}],
            [
              %{key: "a", label: "A", value_type: "string"},
              %{key: "a", label: "B", value_type: "string"}
            ],
            ["thickness"],
            %{key: "thickness"}
          ] do
        assert {:error, :invalid_property_definitions} =
                 Inventory.create_material_type(scope, 73, %{
                   code: "T",
                   name: "T",
                   property_definitions: definitions
                 })
      end

      assert {:ok, _} = Inventory.create_material_type(scope, 73, %{code: "T", name: "T"})

      assert {:error, changeset} =
               Inventory.create_material_type(scope, 73, %{code: "t", name: "T"})

      assert %{code: [_]} = Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))
      assert {:ok, _} = Inventory.create_material_type(scope, 74, %{code: "T", name: "T"})
    end

    test "keeps types inside their company and tenant", context do
      %{scope: scope, customer: customer, item: item, kg: kg} = context
      {:ok, type} = Inventory.create_material_type(scope, 74, %{code: "T", name: "T"})

      assert {:error, :material_type_not_found} = Inventory.get_material_type(scope, 73, type.id)
      assert {:ok, []} = Inventory.list_material_types(scope, 73)
      assert {:error, :company_not_found} = Inventory.get_material_type(customer, 74, type.id)
      assert {:error, :company_not_found} = Inventory.list_material_types(customer, 74)

      assert {:error, :company_not_found} =
               Inventory.create_material_type(customer, 73, %{code: "X", name: "X"})

      assert {:error, :material_type_not_found} =
               Inventory.register_material(scope, 73, item.id, kg.id, material_type_id: type.id)

      # The composite reference refuses what the API never writes.
      assert_raise Postgrex.Error, ~r/material_type_id_fkey/, fn ->
        Repo.query!(
          "INSERT INTO factory_inventory_materials (company_id, item_id, native_unit_id, material_type_id, properties, created_at, updated_at) VALUES ($1, $2, $3, $4, '{}', now(), now())",
          [73, item.id, kg.id, type.id]
        )
      end

      assert_raise Postgrex.Error, ~r/properties_shape/, fn ->
        Repo.query!(
          "INSERT INTO factory_inventory_materials (company_id, item_id, native_unit_id, properties, created_at, updated_at) VALUES ($1, $2, $3, '{\"a\": 1}', now(), now())",
          [73, item.id, kg.id]
        )
      end
    end
  end

  describe "item-level conversions" do
    setup %{scope: scope, item: item, kg: kg} do
      {:ok, _material} = Inventory.register_material(scope, 73, item.id, kg.id)
      :ok
    end

    test "each definition is a new version and earlier versions stay readable", context do
      %{scope: scope, item: item, kg: kg, coil: coil} = context

      assert {:ok, %Conversion{version: 1, unit: ^coil, native_unit: ^kg} = first} =
               Inventory.define_conversion(scope, 73, item.id, coil.id, "250.5")

      assert Decimal.eq?(first.factor, "250.5")

      assert {:ok, %Conversion{version: 2} = second} =
               Inventory.define_conversion(scope, 73, item.id, coil.id, Decimal.new("248"))

      assert {:ok, ^second} = Inventory.get_conversion(scope, 73, item.id, coil.id)
      assert {:ok, ^first} = Inventory.get_conversion(scope, 73, item.id, coil.id, version: 1)

      assert {:error, :conversion_not_found} =
               Inventory.get_conversion(scope, 73, item.id, coil.id, version: 3)

      assert {:ok, [^first, ^second]} = Inventory.list_conversions(scope, 73, item.id)
    end

    test "refuses a non-positive factor, the native unit, and a foreign unit", context do
      %{scope: scope, item: item, kg: kg, coil: coil} = context
      {:ok, sister_unit} = Inventory.create_unit(scope, 74, %{code: "coil", name: "Coil"})

      assert {:error, %Ecto.Changeset{}} =
               Inventory.define_conversion(scope, 73, item.id, coil.id, 0)

      assert {:error, %Ecto.Changeset{}} =
               Inventory.define_conversion(scope, 73, item.id, coil.id, "-1")

      assert {:error, %Ecto.Changeset{}} =
               Inventory.define_conversion(scope, 73, item.id, coil.id, "0.0000000000001")

      assert {:error, :native_unit} = Inventory.define_conversion(scope, 73, item.id, kg.id, 1)

      assert {:error, :unit_not_found} =
               Inventory.define_conversion(scope, 73, item.id, sister_unit.id, 1)

      assert {:ok, []} = Inventory.list_conversions(scope, 73, item.id)
    end

    test "requires a registered material", %{scope: scope, coil: coil} do
      {:ok, loose} = Inventory.create_item(scope, 73, %{sku: "LOOSE", title: "Loose"})

      assert {:error, :material_not_found} =
               Inventory.define_conversion(scope, 73, loose.id, coil.id, 1)

      assert {:error, :material_not_found} = Inventory.list_conversions(scope, 73, loose.id)
    end
  end

  describe "stock positions" do
    test "reads a position by item and location in the native unit", context do
      %{scope: scope, item: item, kg: kg, bay: bay} = context
      {:ok, _material} = Inventory.register_material(scope, 73, item.id, kg.id)

      assert {:ok,
              %StockPosition{item_id: item_id, location_id: location_id, unit: ^kg} = position} =
               Inventory.get_stock_position(scope, 73, item.id, bay.id)

      assert item_id == item.id
      assert location_id == bay.id
      assert Decimal.eq?(position.quantity, 0)
    end

    test "refuses an unregistered item, another company's location, and another tenant",
         context do
      %{scope: scope, customer: customer, item: item, kg: kg, bay: bay} = context

      assert {:error, :material_not_found} =
               Inventory.get_stock_position(scope, 73, item.id, bay.id)

      {:ok, _material} = Inventory.register_material(scope, 73, item.id, kg.id)
      {:ok, sister_bay} = Inventory.create_location(scope, 74, %{code: "RM-01", name: "Bay"})

      assert {:error, :location_not_found} =
               Inventory.get_stock_position(scope, 73, item.id, sister_bay.id)

      assert {:error, :item_not_found} =
               Inventory.get_stock_position(scope, 74, item.id, sister_bay.id)

      assert {:error, :company_not_found} =
               Inventory.get_stock_position(customer, 73, item.id, bay.id)
    end
  end
end
