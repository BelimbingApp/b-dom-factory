defmodule Bilimbi.Factory.ProductionExecution.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"factory" => "Factory operations"},
        verbs: ["import", "override"],
        capabilities: [
          "factory.production-execution.import",
          "factory.production-execution.material-hold.override"
        ],
        roles: %{}
      }
    }
  end
end
