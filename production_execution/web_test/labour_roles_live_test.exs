defmodule BilimbiWeb.FactoryLabourRolesLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Factory.Inventory.TestFixtures, as: InventoryFixtures
  alias Bilimbi.Factory.ProductionExecution
  alias Bilimbi.Factory.ProductionExecution.TestFixtures, as: ProductionFixtures

  setup do
    UserFixtures.create_user_tables!()
    InventoryFixtures.create_inventory_tables!(company_tables?: false)
    ProductionFixtures.create_production_tables!()
    ProductionFixtures.create_labour_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    {:ok, scope} = Tenancy.scope(41)
    %{scope: scope}
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/labour-roles")
  end

  test "creates, relabels, and deactivates a company role", %{conn: conn, scope: scope} do
    grant_capabilities!([
      "factory.production-execution.configuration.view",
      "factory.production-execution.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/labour-roles")
    render_click(element(view, "#new-labour-roles"))

    view
    |> form("#labour-roles-form", entry: %{code: "role_a", label: "Role A"})
    |> render_submit()

    assert has_element?(view, "#labour-roles-table td", "ROLE_A")
    {:ok, [role]} = ProductionExecution.list_labour_roles(scope, 73)

    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{role.id}']"))
    view |> form("#labour-roles-form", entry: %{label: "Updated role"}) |> render_submit()
    assert has_element?(view, "#labour-roles-table td", "Updated role")

    render_click(element(view, "button[phx-click='toggle_active'][phx-value-id='#{role.id}']"))
    assert has_element?(view, "#labour-roles-table td", "Inactive")

    assert {:ok, %{active: false, code: "ROLE_A"}} =
             ProductionExecution.get_labour_role(scope, 73, role.id)
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!(["factory.production-execution.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/labour-roles")
    refute has_element?(view, "#new-labour-roles")
    assert render_hook(view, "new", %{}) =~ "permission to manage labour roles"
  end
end
