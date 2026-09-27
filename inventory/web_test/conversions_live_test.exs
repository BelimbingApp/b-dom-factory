defmodule BilimbiWeb.FactoryConversionsLiveTest do
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
    TestFixtures.configure_item_settings!(73, 41, statuses: ["draft"], currency: "USD")
    {:ok, scope} = Tenancy.scope(41)
    {:ok, item} = Inventory.create_item(scope, 73, %{sku: "ITEM_A", title: "Item A"})
    {:ok, native} = Inventory.create_unit(scope, 73, %{code: "u1", name: "Unit one"})
    {:ok, other} = Inventory.create_unit(scope, 73, %{code: "u2", name: "Unit two"})
    {:ok, _material} = Inventory.register_material(scope, 73, item.id, native.id)
    %{scope: scope, item: item, other: other}
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/conversions")
  end

  test "publishes two versions without changing the first", %{
    conn: conn,
    item: item,
    other: other,
    scope: scope
  } do
    grant_capabilities!([
      "factory.inventory.configuration.view",
      "factory.inventory.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/conversions")
    render_click(element(view, "button[phx-click='select'][phx-value-id='#{item.id}']"))

    view
    |> form("#conversion-form", conversion: %{unit_id: other.id, factor: "2"})
    |> render_submit()

    view
    |> form("#conversion-form", conversion: %{unit_id: other.id, factor: "3"})
    |> render_submit()

    assert has_element?(view, "#conversion-versions-table td", "2")
    assert has_element?(view, "#conversion-versions-table td", "3")
    assert {:ok, conversions} = Inventory.list_conversions(scope, 73, item.id)
    assert Enum.map(conversions, & &1.version) == [1, 2]

    assert Enum.zip_with(conversions, ["2", "3"], fn conversion, expected ->
             Decimal.equal?(conversion.factor, Decimal.new(expected))
           end)
           |> Enum.all?()
  end

  test "a viewer cannot publish a conversion", %{conn: conn, item: item, other: other} do
    grant_capabilities!(["factory.inventory.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/conversions")
    render_click(element(view, "button[phx-click='select'][phx-value-id='#{item.id}']"))
    refute has_element?(view, "#conversion-form")

    assert render_hook(view, "save", %{
             "conversion" => %{"unit_id" => to_string(other.id), "factor" => "2"}
           }) =~
             "permission to manage conversions"
  end
end
