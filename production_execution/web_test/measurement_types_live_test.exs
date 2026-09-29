defmodule BilimbiWeb.FactoryMeasurementTypesLiveTest do
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
             conn |> log_in_as() |> live(~p"/factory/measurement-types")
  end

  test "creates a type with limits, changes its limits, and deactivates it",
       %{conn: conn, scope: scope} do
    grant_capabilities!([
      "factory.production-execution.configuration.view",
      "factory.production-execution.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/measurement-types")
    render_click(element(view, "#new-measurement-type"))

    view
    |> form("#measurement-type-form",
      type: %{
        code: "measure_a",
        label: "Measure A",
        value_type: "decimal",
        unit: "g/m2",
        minimum: "95",
        maximum: "105",
        target: "100"
      }
    )
    |> render_submit()

    assert has_element?(view, "#measurement-types-table td", "MEASURE_A")
    {:ok, [type]} = ProductionExecution.list_measurement_types(scope, 73)
    assert type.unit == "g/m2" and Decimal.equal?(type.maximum, 105)

    render_click(element(view, "button[phx-click='edit'][phx-value-id='#{type.id}']"))

    view
    |> form("#measurement-type-form", type: %{label: "Measure A2", maximum: "110"})
    |> render_submit()

    assert has_element?(view, "#measurement-types-table td", "Measure A2")

    render_click(element(view, "button[phx-click='toggle_active'][phx-value-id='#{type.id}']"))
    assert has_element?(view, "#measurement-types-table td", "Inactive")

    assert {:ok, %{active: false, label: "Measure A2", maximum: maximum}} =
             ProductionExecution.get_measurement_type(scope, 73, type.id)

    assert Decimal.equal?(maximum, 110)
  end

  test "a viewer cannot submit a forged write event", %{conn: conn} do
    grant_capabilities!(["factory.production-execution.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/measurement-types")
    refute has_element?(view, "#new-measurement-type")
    assert render_hook(view, "new", %{}) =~ "permission to manage measurement types"
  end
end
