defmodule Bilimbi.Factory.Inventory.CatalogTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Item
  alias Bilimbi.Factory.Inventory.Location
  alias Bilimbi.Factory.Inventory.Unit

  import Bilimbi.Factory.Inventory.TestFixtures

  setup do
    create_inventory_tables!()
    insert_tenant!(%{id: 41, name: "Operator"})
    insert_tenant!(%{id: 42, name: "Customer", is_platform_operator: false})
    insert_company!(%{id: 73, tenant_id: 41, name: "Mill", code: "mill"})
    insert_company!(%{id: 74, tenant_id: 41, name: "Sister Mill", code: "sister"})
    insert_company!(%{id: 75, tenant_id: 42, name: "Other", code: "other"})

    {:ok, operator} = Tenancy.scope(41)
    {:ok, customer} = Tenancy.scope(42)

    %{operator: operator, customer: customer}
  end

  describe "item master" do
    test "creates an item with Belimbing's create rules", %{operator: scope} do
      assert {:ok, %Item{} = item} =
               Inventory.create_item(scope, 73, %{
                 sku: " al-coil-01 ",
                 title: "Aluminium coil",
                 status: "ready",
                 storage_location: "  ",
                 currency_code: "usd",
                 unit_cost_amount: 125_00
               })

      assert item.company_id == 73
      assert item.sku == "AL-COIL-01"
      assert item.currency_code == "USD"
      assert item.quantity_on_hand == 1
      assert item.storage_location == nil
      assert item.unit_cost_amount == 12_500

      assert {:ok, ^item} = Inventory.get_item(scope, 73, item.id)
      assert {:ok, ^item} = Inventory.get_item_by_sku(scope, 73, "al-coil-01")
    end

    test "refuses an unknown status and a duplicate SKU in the same company", %{operator: scope} do
      assert {:error, changeset} =
               Inventory.create_item(scope, 73, %{sku: "X", title: "X", status: "on_hold"})

      assert %{status: [_]} = errors_on(changeset)

      assert {:ok, _item} = Inventory.create_item(scope, 73, %{sku: "X", title: "X"})
      assert {:error, changeset} = Inventory.create_item(scope, 73, %{sku: "x", title: "Again"})
      assert %{sku: [_]} = errors_on(changeset)

      assert {:ok, _item} = Inventory.create_item(scope, 74, %{sku: "X", title: "Sister's X"})
    end

    test "lists a company's items by SKU, optionally by status", %{operator: scope} do
      {:ok, _} = Inventory.create_item(scope, 73, %{sku: "B", title: "B", status: "ready"})
      {:ok, _} = Inventory.create_item(scope, 73, %{sku: "A", title: "A"})
      {:ok, _} = Inventory.create_item(scope, 74, %{sku: "C", title: "C"})

      assert {:ok, items} = Inventory.list_items(scope, 73)
      assert Enum.map(items, & &1.sku) == ["A", "B"]

      assert {:ok, [%Item{sku: "B"}]} = Inventory.list_items(scope, 73, status: "ready")
      assert {:ok, [%Item{sku: "A"}]} = Inventory.list_items(scope, 73, limit: 1)
      assert_raise ArgumentError, fn -> Inventory.list_items(scope, 73, limit: 501) end
    end

    test "keeps items inside their company and tenant", context do
      {:ok, item} = Inventory.create_item(context.operator, 73, %{sku: "A", title: "A"})

      assert {:error, :item_not_found} = Inventory.get_item(context.operator, 74, item.id)
      assert {:error, :company_not_found} = Inventory.get_item(context.customer, 73, item.id)
      assert {:error, :company_not_found} = Inventory.list_items(context.customer, 73)

      assert {:error, :company_not_found} =
               Inventory.create_item(context.customer, 73, %{sku: "Z", title: "Z"})

      soft_delete_company!(73)
      assert {:error, :company_not_found} = Inventory.get_item(context.operator, 73, item.id)
    end
  end

  describe "units of measure" do
    test "creates, reads, and lists a company's units", %{operator: scope} do
      assert {:ok, %Unit{code: "kg", name: "Kilogram"} = kg} =
               Inventory.create_unit(scope, 73, %{code: "kg", name: "Kilogram"})

      assert {:ok, %Unit{code: "pcs"}} =
               Inventory.create_unit(scope, 73, %{code: "pcs", name: "Pieces"})

      assert {:ok, _} = Inventory.create_unit(scope, 74, %{code: "kg", name: "Kilogram"})

      assert {:ok, ^kg} = Inventory.get_unit(scope, 73, kg.id)
      assert {:ok, units} = Inventory.list_units(scope, 73)
      assert Enum.map(units, & &1.code) == ["kg", "pcs"]

      assert {:error, changeset} = Inventory.create_unit(scope, 73, %{code: "kg", name: "Again"})
      assert %{code: [_]} = errors_on(changeset)
      assert {:error, :unit_not_found} = Inventory.get_unit(scope, 74, kg.id)
    end
  end

  describe "stock locations" do
    test "creates, reads, and lists a company's locations", context do
      assert {:ok, %Location{code: "RM-01"} = location} =
               Inventory.create_location(context.operator, 73, %{
                 code: "rm-01",
                 name: "Raw material bay"
               })

      assert {:ok, ^location} = Inventory.get_location(context.operator, 73, location.id)
      assert {:ok, [^location]} = Inventory.list_locations(context.operator, 73)

      assert {:error, changeset} =
               Inventory.create_location(context.operator, 73, %{code: "RM-01", name: "Again"})

      assert %{code: [_]} = errors_on(changeset)

      assert {:error, :location_not_found} =
               Inventory.get_location(context.operator, 74, location.id)

      assert {:error, :company_not_found} =
               Inventory.get_location(context.customer, 73, location.id)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
