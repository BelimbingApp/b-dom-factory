[
  id: "factory/product_definition",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_factory_product_definition,
  namespace: Bilimbi.Factory.ProductDefinition,
  dependencies: [
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "core/company",
    "factory/inventory"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_260_926_100_000 => :bilimbi_only},
  web: nil,
  schema_contract: nil,
  contribution_provider: nil,
  dev_seed: nil
]
