defmodule Bilimbi.Factory.Inventory.DescriptorTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Base.ModuleRegistry.MixDiscovery

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
    assert module.dependencies == ["base/module_registry"]
    assert module.migrations == nil
    assert Code.ensure_loaded?(Bilimbi.Factory.Inventory)
  end
end
