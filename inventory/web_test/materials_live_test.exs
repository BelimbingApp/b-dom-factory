defmodule BilimbiWeb.FactoryMaterialsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.TestFixtures

  setup do
    UserFixtures.create_user_tables!()
    TestFixtures.create_inventory_tables!(company_tables?: false)
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    TestFixtures.configure_item_settings!(73, 41, statuses: ["draft", "ready"], currency: "USD")
    {:ok, scope} = Tenancy.scope(41)
    {:ok, unit} = Inventory.create_unit(scope, 73, %{code: "u1", name: "Unit one"})
    {:ok, type} = Inventory.create_material_type(scope, 73, %{code: "TYPE_A", name: "Type A"})
    %{scope: scope, unit: unit, type: type}
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/materials")
  end

  test "creates, edits, and retires a material", %{
    conn: conn,
    scope: scope,
    unit: unit,
    type: type
  } do
    grant_capabilities!([
      "factory.inventory.configuration.view",
      "factory.inventory.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/materials")
    assert has_element?(view, "a[href='/factory/material-types']")
    assert has_element?(view, "a[href='/factory/conversions']")
    render_click(element(view, "#new-material"))

    view
    |> form("#material-form",
      material: %{
        sku: "ITEM_A",
        title: "Item A",
        native_unit_id: unit.id,
        material_type_id: type.id,
        properties: "{}"
      }
    )
    |> render_submit()

    assert has_element?(view, "#materials-table td", "ITEM_A")
    {:ok, [material]} = Inventory.list_materials(scope, 73)
    assert material.native_unit.id == unit.id
    assert material.material_type_id == type.id

    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{material.item_id}']"))
    view |> form("#material-form", material: %{title: "Updated item"}) |> render_submit()
    assert {:ok, %{title: "Updated item"}} = Inventory.get_item(scope, 73, material.item_id)

    render_click(element(view, "button[phx-click='retire'][phx-value-id='#{material.item_id}']"))
    assert has_element?(view, "#materials-table td", "Retired")
    assert {:ok, %{retired_at: retired_at}} = Inventory.get_material(scope, 73, material.item_id)
    assert retired_at
  end

  test "a viewer cannot submit a forged create", %{conn: conn} do
    grant_capabilities!(["factory.inventory.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/materials")
    refute has_element?(view, "#new-material")
    assert render_hook(view, "new", %{}) =~ "permission to manage materials"
  end
end
