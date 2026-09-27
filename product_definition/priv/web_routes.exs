[
  %{
    path: "/factory/resource-types",
    live: Bilimbi.Factory.ProductDefinition.Web.ResourceTypesLive,
    session: :auth,
    capability: "factory.product-definition.configuration.view"
  },
  %{
    path: "/factory/resources",
    live: Bilimbi.Factory.ProductDefinition.Web.ResourcesLive,
    session: :auth,
    capability: "factory.product-definition.configuration.view"
  },
  %{
    path: "/factory/definitions",
    live: Bilimbi.Factory.ProductDefinition.Web.DefinitionsLive,
    session: :auth,
    capability: "factory.product-definition.configuration.view"
  }
]
