[
  %{
    path: "/factory/floor",
    live: Bilimbi.Factory.ProductionExecution.Web.FloorLive,
    session: :auth,
    capability: "factory.production-execution.floor.view"
  },
  %{
    path: "/factory/wastage-reasons",
    live: Bilimbi.Factory.ProductionExecution.Web.WastageReasonsLive,
    session: :auth,
    capability: "factory.production-execution.configuration.view"
  },
  %{
    path: "/factory/labour-roles",
    live: Bilimbi.Factory.ProductionExecution.Web.LabourRolesLive,
    session: :auth,
    capability: "factory.production-execution.configuration.view"
  }
]
