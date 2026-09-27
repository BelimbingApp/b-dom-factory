[
  id: "factory/product_definition",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_factory_product_definition,
  namespace: Bilimbi.Factory.ProductDefinition,
  dependencies: [
    "base/database",
    "base/authz",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "factory/inventory"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_260_926_100_000 => :bilimbi_only,
    20_260_927_150_000 => :bilimbi_only,
    20_260_927_163_000 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.Factory.ProductDefinition.Contributions,
  dev_seed: nil
]
