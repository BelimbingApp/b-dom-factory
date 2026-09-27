defmodule BilimbiWeb.FactoryDefinitionsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Factory.Inventory
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
    InventoryFixtures.configure_item_settings!(73, 41, statuses: ["draft"], currency: "USD")
    {:ok, scope} = Tenancy.scope(41)
    {:ok, input} = Inventory.create_item(scope, 73, %{sku: "INPUT_A", title: "Input A"})
    {:ok, output} = Inventory.create_item(scope, 73, %{sku: "OUTPUT_A", title: "Output A"})
    {:ok, unit} = Inventory.create_unit(scope, 73, %{code: "u1", name: "Unit one"})
    {:ok, type} = Definitions.create_resource_type(scope, 73, %{code: "TYPE_A", name: "Type A"})
    {:ok, resource} = Definitions.create_resource(scope, 73, %{code: "RESOURCE_A", name: "Resource A", resource_type_id: type.id})
    %{scope: scope, input: input, output: output, unit: unit, resource: resource}
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/definitions")
  end

  test "creates a product and publishes immutable formula and routing versions", context do
    %{conn: conn, scope: scope, input: input, output: output, unit: unit, resource: resource} = context
    grant_capabilities!([
      "factory.product-definition.configuration.view",
      "factory.product-definition.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/definitions")
    view
    |> form("#product-form", product: %{item_id: output.id, code: "PRODUCT_A", name: "Product A"})
    |> render_submit()

    assert has_element?(view, "#product-definitions-table td", "PRODUCT_A")
    {:ok, [product]} = Definitions.list_products(scope, 73)

    lines = [
      %{item_id: input.id, unit_id: unit.id, role: "input", quantity: "2"},
      %{item_id: output.id, unit_id: unit.id, role: "output", quantity: "1"}
    ]

    view
    |> form("#formula-form", formula: %{lines: Jason.encode!(lines), process_config: "{}"})
    |> render_submit()

    operation = %{code: "OP_A", sequence: 1, inputs: [input.id], outputs: [output.id], allowed_resource_ids: [resource.id]}

    view
    |> form("#routing-form", routing: %{operations: Jason.encode!([operation]), process_config: "{}"})
    |> render_submit()

    assert has_element?(view, "#formula-revisions-table td", "1")
    assert has_element?(view, "#routing-revisions-table td", "1")
    assert {:ok, [%{version: 1}]} = Definitions.list_formula_revisions(scope, 73, product.id)
    assert {:ok, [%{version: 1}]} = Definitions.list_routing_revisions(scope, 73, product.id)
  end

  test "a viewer cannot submit a forged publish event", %{conn: conn} do
    grant_capabilities!(["factory.product-definition.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/definitions")
    refute has_element?(view, "#product-form")
    assert render_hook(view, "create_product", %{"product" => %{}}) =~ "permission to manage definitions"
  end
end
