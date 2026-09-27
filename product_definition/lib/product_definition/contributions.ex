defmodule Bilimbi.Factory.ProductDefinition.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @view "factory.product-definition.configuration.view"
  @manage "factory.product-definition.configuration.manage"

  @impl true
  def contributions do
    %{
      menu: [
        %{
          id: "admin.factory.resources",
          label: "Resources",
          parent: "admin.factory",
          route: "/factory/resources",
          capability: @view,
          order: 60
        },
        %{
          id: "admin.factory.definitions",
          label: "BOM formulas & routings",
          parent: "admin.factory",
          route: "/factory/definitions",
          capability: @view,
          order: 70
        }
      ],
      authz: %{
        domains: %{"factory" => "Factory operations"},
        capabilities: [@view, @manage],
        roles: %{"tenant_owner" => %{capabilities: [@view, @manage]}}
      }
    }
  end
end
