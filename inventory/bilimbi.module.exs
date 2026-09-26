[
  id: "factory/inventory",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_factory_inventory,
  namespace: Bilimbi.Factory.Inventory,
  dependencies: [
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "core/company"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_926_090_000 => :compatible_baseline,
    20_260_926_090_100 => :bilimbi_only,
    20_260_926_120_000 => :bilimbi_only,
    20_260_926_140_000 => :bilimbi_only
  },
  web: nil,
  schema_contract: Bilimbi.Factory.Inventory.SchemaContract,
  contribution_provider: Bilimbi.Factory.Inventory.Contributions,
  dev_seed: nil
]
