[
  %{
    path: "/factory/material-types",
    live: Bilimbi.Factory.Inventory.Web.MaterialTypesLive,
    session: :auth,
    capability: "factory.inventory.configuration.view"
  },
  %{
    path: "/factory/units",
    live: Bilimbi.Factory.Inventory.Web.UnitsLive,
    session: :auth,
    capability: "factory.inventory.configuration.view"
  },
  %{
    path: "/factory/item-settings",
    live: Bilimbi.Factory.Inventory.Web.ItemSettingsLive,
    session: :auth,
    capability: "factory.inventory.configuration.view"
  },
  %{
    path: "/factory/conversions",
    live: Bilimbi.Factory.Inventory.Web.ConversionsLive,
    session: :auth,
    capability: "factory.inventory.configuration.view"
  },
  %{
    path: "/factory/materials",
    live: Bilimbi.Factory.Inventory.Web.MaterialsLive,
    session: :auth,
    capability: "factory.inventory.configuration.view"
  }
]
