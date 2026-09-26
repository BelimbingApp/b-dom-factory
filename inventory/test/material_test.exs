defmodule Bilimbi.Factory.Inventory.MaterialTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Conversion
  alias Bilimbi.Factory.Inventory.Material
  alias Bilimbi.Factory.Inventory.StockPosition

  import Bilimbi.Factory.Inventory.TestFixtures

  setup do
    create_inventory_tables!()
    insert_tenant!(%{id: 41, name: "Operator"})
    insert_tenant!(%{id: 42, name: "Customer", is_platform_operator: false})
    insert_company!(%{id: 73, tenant_id: 41, name: "Mill", code: "mill"})
    insert_company!(%{id: 74, tenant_id: 41, name: "Sister Mill", code: "sister"})

    {:ok, scope} = Tenancy.scope(41)
    {:ok, customer} = Tenancy.scope(42)
    {:ok, item} = Inventory.create_item(scope, 73, %{sku: "AL-COIL", title: "Aluminium coil"})
    {:ok, kg} = Inventory.create_unit(scope, 73, %{code: "kg", name: "Kilogram"})
    {:ok, coil} = Inventory.create_unit(scope, 73, %{code: "coil", name: "Coil"})
    {:ok, bay} = Inventory.create_location(scope, 73, %{code: "RM-01", name: "Raw material bay"})

    %{scope: scope, customer: customer, item: item, kg: kg, coil: coil, bay: bay}
  end

  describe "material identity" do
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
