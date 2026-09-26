defmodule Bilimbi.Factory.ProductionExecution.DescriptorTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Base.ModuleRegistry.MixDiscovery

  @workspace_root Path.expand("../../../../..", __DIR__)

  test "is an optional Factory Domain module discovered from its mounted repository" do
    module =
      @workspace_root
      |> MixDiscovery.discover_workspace!()
      |> Enum.find(&(&1.id == "factory/production_execution"))

    assert module.container_id == "factory"
    assert module.layer == :domain
    refute module.required
    assert module.namespace == Bilimbi.Factory.ProductionExecution

    assert module.dependencies == [
             "base/database",
             "base/module_registry",
             "base/tenancy",
             "core/company",
             "factory/inventory",
             "factory/product_definition"
           ]

    assert module.migrations == "priv/repo/migrations"
    assert Code.ensure_loaded?(Bilimbi.Factory.ProductionExecution)
  end
end
