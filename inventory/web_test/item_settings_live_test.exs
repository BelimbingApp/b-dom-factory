defmodule BilimbiWeb.FactoryItemSettingsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Base.Settings
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Contributions

  setup do
    UserFixtures.create_user_tables!()
    CompanyFixtures.insert_tenant!(%{id: 41})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41})
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    :ok
  end

  test "refuses the screen without view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/item-settings")
  end

  test "saves and validates company settings", %{conn: conn} do
    grant_capabilities!([
      "factory.inventory.configuration.view",
      "factory.inventory.configuration.manage"
    ])

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/item-settings")
    view
    |> form("#item-settings-form", settings: %{statuses: "draft\nreleased", currency: "usd"})
    |> render_submit()

    {:ok, scope} = Tenancy.scope(41)
    assert {:ok, %{statuses: ["draft", "released"], default_currency_code: "USD"}} =
             Inventory.item_settings(scope, 73)

    view
    |> form("#item-settings-form", settings: %{statuses: "draft\ndraft", currency: "USD"})
    |> render_submit()

    assert has_element?(view, "#item-settings-error", "Invalid item statuses")
    assert {:ok, %{statuses: ["draft", "released"]}} = Inventory.item_settings(scope, 73)
  end

  test "an inherited tenant setting is not saved as a company override", %{conn: conn} do
    grant_capabilities!([
      "factory.inventory.configuration.view",
      "factory.inventory.configuration.manage"
    ])

    tenant = Settings.Scope.tenant(41)
    {:ok, _} = Settings.put(Contributions.item_statuses_key(), ["draft"], tenant)
    {:ok, _} = Settings.put(Contributions.default_currency_key(), "USD", tenant)

    on_exit(fn ->
      Settings.delete(Contributions.item_statuses_key(), tenant)
      Settings.delete(Contributions.default_currency_key(), tenant)
    end)

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/item-settings")
    assert has_element?(view, "#item-settings-facts", "USD")
    view |> form("#item-settings-form") |> render_submit()

    {:ok, _} = Settings.put(Contributions.default_currency_key(), "EUR", tenant)
    {:ok, scope} = Tenancy.scope(41)

    assert {:ok, %{statuses: nil, default_currency_code: nil}} =
             Inventory.item_setting_overrides(scope, 73)

    assert {:ok, %{default_currency_code: "EUR"}} = Inventory.item_settings(scope, 73)
  end

  test "a viewer cannot submit a forged save", %{conn: conn} do
    grant_capabilities!(["factory.inventory.configuration.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/item-settings")
    refute has_element?(view, "#item-settings-form")
    assert render_hook(view, "save", %{"settings" => %{"statuses" => "draft"}}) =~
             "permission to manage item settings"
  end
end
