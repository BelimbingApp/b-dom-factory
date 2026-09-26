[
  id: "factory/production_execution",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_factory_production_execution,
  namespace: Bilimbi.Factory.ProductionExecution,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "core/company",
    "factory/inventory",
    "factory/product_definition"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_926_130_000 => :bilimbi_only,
    20_260_926_150_000 => :bilimbi_only
  },
  web: nil,
  schema_contract: nil,
  contribution_provider: Bilimbi.Factory.ProductionExecution.Contributions,
  dev_seed: nil
]
