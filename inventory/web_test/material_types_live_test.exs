defmodule BilimbiWeb.FactoryMaterialTypesLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.TestFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures

  setup do
    UserFixtures.create_user_tables!()
    TestFixtures.create_inventory_tables!(company_tables?: false)
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/material-types")
  end

  test "creates, edits, and retires a company type", %{conn: conn} do
    grant_capabilities!([
      "factory.inventory.configuration.view",
      "factory.inventory.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/material-types")
    assert has_element?(view, "#new-material-type")
    render_click(element(view, "#new-material-type"))

    view
    |> form("#material-type-form",
      type: %{
        code: "type_a",
        name: "Type A",
        property_definitions: ~s([{"key":"measure","label":"Measure","value_type":"integer"}])
      }
    )
    |> render_submit()

    assert has_element?(view, "#material-types-table td", "TYPE_A")
    refute render(view) =~ "No material types"
    {:ok, scope} = Tenancy.scope(41)
    {:ok, [type]} = Inventory.list_material_types(scope, 73)
    assert length(type.property_definitions) == 1

    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{type.id}']"))
    view |> form("#material-type-form", type: %{name: "Updated type"}) |> render_submit()
    assert has_element?(view, "#material-types-table td", "Updated type")

    render_click(element(view, "button[phx-click='retire'][phx-value-id='#{type.id}']"))
    assert has_element?(view, "#material-types-table td", "Retired")
    assert {:ok, %{retired_at: retired_at}} = Inventory.get_material_type(scope, 73, type.id)
    assert retired_at
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!(["factory.inventory.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/material-types")
    refute has_element?(view, "#new-material-type")
    assert render_hook(view, "new", %{}) =~ "permission to manage material types"
  end
end
