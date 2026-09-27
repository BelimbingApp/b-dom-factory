defmodule BilimbiWeb.FactoryResourceTypesLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Factory.Inventory.TestFixtures, as: InventoryFixtures
  alias Bilimbi.Factory.ProductDefinition, as: Definitions
  alias Bilimbi.Factory.ProductDefinition.TestFixtures, as: DefinitionFixtures
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures

  setup do
    UserFixtures.create_user_tables!()
    InventoryFixtures.create_inventory_tables!(company_tables?: false)
    DefinitionFixtures.create_definition_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/resource-types")
  end

  test "creates, edits, and retires a company type", %{conn: conn} do
    grant_capabilities!([
      "factory.product-definition.configuration.view",
      "factory.product-definition.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/resource-types")
    assert has_element?(view, "#new-resource-type")
    render_click(element(view, "#new-resource-type"))

    view
    |> form("#resource-type-form",
      type: %{
        code: "type_a",
        name: "Type A",
        property_definitions: ~s([{"key":"measure","label":"Measure","value_type":"integer"}])
      }
    )
    |> render_submit()

    assert has_element?(view, "#resource-types-table td", "TYPE_A")
    refute render(view) =~ "No resource types"
    {:ok, scope} = Tenancy.scope(41)
    {:ok, [type]} = Definitions.list_resource_types(scope, 73)
    assert length(type.property_definitions) == 1

    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{type.id}']"))
    view |> form("#resource-type-form", type: %{name: "Updated type"}) |> render_submit()
    assert has_element?(view, "#resource-types-table td", "Updated type")

    render_click(element(view, "button[phx-click='retire'][phx-value-id='#{type.id}']"))
    assert has_element?(view, "#resource-types-table td", "Retired")
    assert {:ok, %{retired_at: retired_at}} = Definitions.get_resource_type(scope, 73, type.id)
    assert retired_at
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!(["factory.product-definition.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/resource-types")
    refute has_element?(view, "#new-resource-type")
    assert render_hook(view, "new", %{}) =~ "permission to manage resource types"
  end
end
