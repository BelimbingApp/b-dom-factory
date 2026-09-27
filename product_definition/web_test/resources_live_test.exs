defmodule BilimbiWeb.FactoryResourcesLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Factory.Inventory.TestFixtures, as: InventoryFixtures
  alias Bilimbi.Factory.ProductDefinition, as: Definitions
  alias Bilimbi.Factory.ProductDefinition.TestFixtures, as: DefinitionFixtures

  setup do
    UserFixtures.create_user_tables!()
    InventoryFixtures.create_inventory_tables!(company_tables?: false)
    DefinitionFixtures.create_definition_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    {:ok, scope} = Tenancy.scope(41)
    {:ok, type} = Definitions.create_resource_type(scope, 73, %{code: "TYPE_A", name: "Type A"})
    %{scope: scope, type: type}
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/resources")
  end

  test "creates, edits, and retires a resource", %{conn: conn, scope: scope, type: type} do
    grant_capabilities!([
      "factory.product-definition.configuration.view",
      "factory.product-definition.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/resources")
    assert has_element?(view, "a[href='/factory/resource-types']")
    render_click(element(view, "#new-resource"))
    view
    |> form("#resource-form", resource: %{
      code: "RESOURCE_A",
      name: "Resource A",
      resource_type_id: type.id,
      properties: "{}"
    })
    |> render_submit()

    assert has_element?(view, "#resources-table td", "RESOURCE_A")
    {:ok, [resource]} = Definitions.list_resources(scope, 73)
    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{resource.id}']"))
    view |> form("#resource-form", resource: %{name: "Updated resource"}) |> render_submit()
    assert has_element?(view, "#resources-table td", "Updated resource")

    render_click(element(view, "button[phx-click='retire'][phx-value-id='#{resource.id}']"))
    assert has_element?(view, "#resources-table td", "Retired")
    assert {:ok, %{retired_at: retired_at}} = Definitions.get_resource(scope, 73, resource.id)
    assert retired_at
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!(["factory.product-definition.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/resources")
    refute has_element?(view, "#new-resource")
    assert render_hook(view, "new", %{}) =~ "permission to manage resources"
  end
end
