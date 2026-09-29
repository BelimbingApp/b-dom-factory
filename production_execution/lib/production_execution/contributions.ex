defmodule Bilimbi.Factory.ProductionExecution.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @floor "factory.production-execution.floor.view"
  @view "factory.production-execution.configuration.view"
  @manage "factory.production-execution.configuration.manage"

  # Recording and correcting shop-floor capture are separate grants, so a
  # company can let operators record and only supervisors correct.
  @capture [
    "factory.production-execution.wastage.record",
    "factory.production-execution.wastage.correct",
    "factory.production-execution.labour.record",
    "factory.production-execution.labour.manage",
    "factory.production-execution.measurement.record",
    "factory.production-execution.measurement.correct"
  ]

  @impl true
  def contributions do
    %{
      menu: [
        %{
          id: "production.factory.floor",
          label: "Shop floor",
          parent: "production",
          route: "/factory/floor",
          capability: @floor,
          order: 10
        },
        %{
          id: "admin.factory.wastage-reasons",
          label: "Wastage reasons",
          parent: "admin.factory",
          route: "/factory/wastage-reasons",
          capability: @view,
          order: 80
        },
        %{
          id: "admin.factory.labour-roles",
          label: "Labour roles",
          parent: "admin.factory",
          route: "/factory/labour-roles",
          capability: @view,
          order: 85
        },
        %{
          id: "admin.factory.measurement-types",
          label: "Measurement types",
          parent: "admin.factory",
          route: "/factory/measurement-types",
          capability: @view,
          order: 90
        }
      ],
      authz: %{
        domains: %{"factory" => "Factory operations"},
        verbs: ["import", "override", "record", "correct"],
        capabilities:
          [
            "factory.production-execution.import",
            "factory.production-execution.material-hold.override",
            @floor,
            @view,
            @manage
          ] ++ @capture,
        roles: %{"tenant_owner" => %{capabilities: [@floor, @view, @manage]}}
      }
    }
  end
end
