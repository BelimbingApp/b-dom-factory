defmodule Bilimbi.Factory.Inventory.Contributions do
  @moduledoc false

  # Belimbing's item master capabilities, kept under their durable keys so
  # grants in an adopted database still name a declared capability.

  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @capabilities [
    "commerce.inventory.item.create",
    "commerce.inventory.item.list",
    "commerce.inventory.item.update",
    "commerce.inventory.item.view",
    "commerce.inventory.manage"
  ]

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{
          "commerce" => "Commerce, catalog, inventory, marketplace, and sales operations"
        },
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      }
    }
  end
end
