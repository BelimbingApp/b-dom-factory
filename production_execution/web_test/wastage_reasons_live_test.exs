defmodule BilimbiWeb.FactoryWastageReasonsLiveTest do
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
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    {:ok, scope} = Tenancy.scope(41)
    %{scope: scope}
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/wastage-reasons")
  end

  test "creates, relabels, and deactivates a company reason", %{conn: conn, scope: scope} do
    grant_capabilities!([
      "factory.production-execution.configuration.view",
      "factory.production-execution.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/wastage-reasons")
    render_click(element(view, "#new-wastage-reasons"))

    view
    |> form("#wastage-reasons-form", entry: %{code: "reason_a", label: "Reason A"})
    |> render_submit()

    assert has_element?(view, "#wastage-reasons-table td", "REASON_A")
    {:ok, [reason]} = ProductionExecution.list_wastage_reasons(scope, 73)

    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{reason.id}']"))
    view |> form("#wastage-reasons-form", entry: %{label: "Updated reason"}) |> render_submit()
    assert has_element?(view, "#wastage-reasons-table td", "Updated reason")

    render_click(element(view, "button[phx-click='toggle_active'][phx-value-id='#{reason.id}']"))
    assert has_element?(view, "#wastage-reasons-table td", "Inactive")

    assert {:ok, %{active: false, code: "REASON_A"}} =
             ProductionExecution.get_wastage_reason(scope, 73, reason.id)
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!(["factory.production-execution.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/wastage-reasons")
    refute has_element?(view, "#new-wastage-reasons")
    assert render_hook(view, "new", %{}) =~ "permission to manage wastage reasons"
  end
end
