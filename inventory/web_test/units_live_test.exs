defmodule BilimbiWeb.FactoryUnitsLiveTest do
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
    :ok
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/units")
  end

  test "creates, renames, and retires a unit", %{conn: conn} do
    grant_capabilities!([
      "factory.inventory.configuration.view",
      "factory.inventory.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/units")
    assert has_element?(view, "a[href='/factory/item-settings']")
    render_click(element(view, "#new-unit"))
    view |> form("#unit-form", unit: %{code: "unit_a", name: "Unit A"}) |> render_submit()
    assert has_element?(view, "#units-table td", "unit_a")

    {:ok, scope} = Tenancy.scope(41)
    {:ok, [unit]} = Inventory.list_units(scope, 73)
    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{unit.id}']"))
    view |> form("#unit-form", unit: %{name: "Updated unit"}) |> render_submit()
    assert has_element?(view, "#units-table td", "Updated unit")

    render_click(element(view, "button[phx-click='retire'][phx-value-id='#{unit.id}']"))
    assert has_element?(view, "#units-table td", "Retired")
    assert {:ok, %{retired_at: retired_at}} = Inventory.get_unit(scope, 73, unit.id)
    assert retired_at
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!(["factory.inventory.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/units")
    refute has_element?(view, "#new-unit")
    assert render_hook(view, "new", %{}) =~ "permission to manage units"
  end
end
