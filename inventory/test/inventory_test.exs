defmodule Bilimbi.Factory.Inventory.DescriptorTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Base.ModuleRegistry.MixDiscovery
  alias Bilimbi.Factory.Inventory.Contributions

  @workspace_root Path.expand("../../../../..", __DIR__)

  test "is an optional Factory Domain module discovered from its mounted repository" do
    module =
      @workspace_root
      |> MixDiscovery.discover_workspace!()
      |> Enum.find(&(&1.id == "factory/inventory"))

    assert module.container_id == "factory"
    assert module.layer == :domain
    refute module.required
    assert module.namespace == Bilimbi.Factory.Inventory
    assert module.migrations == "priv/repo/migrations"
    assert module.schema_contract == Bilimbi.Factory.Inventory.SchemaContract
    assert Code.ensure_loaded?(Bilimbi.Factory.Inventory)
  end

  test "depends on no other Factory module, so Production Execution is never required" do
    applications = Application.spec(:bilimbi_factory_inventory, :applications)

    assert :bilimbi_core_company in applications
    assert :bilimbi_base_settings in applications
    refute :bilimbi_factory_production_execution in applications
    refute :bilimbi_factory_product_definition in applications
  end

  test "declares the item settings as company configuration with no default of its own" do
    %{settings: %{definitions: definitions}} = Contributions.contributions()

    assert %{type: :array, scopes: [:tenant, :company], default: nil, nullable: true} =
             Map.new(definitions[Contributions.item_statuses_key()])

    assert %{type: :string, scopes: [:tenant, :company], default: nil, nullable: true} =
             Map.new(definitions[Contributions.default_currency_key()])
  end

  test "declares Belimbing's item master capabilities under their durable keys" do
    %{authz: authz} = Contributions.contributions()

    assert "commerce.inventory.item.view" in authz.capabilities
    assert "commerce.inventory.item.list" in authz.capabilities
    assert authz.roles["tenant_owner"].capabilities == authz.capabilities
  end
end
