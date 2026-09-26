Code.require_file(Path.expand("../../../../base/database/test/support/data_case.ex", __DIR__))
Code.require_file(Path.expand("../../../../base/tenancy/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/geonames/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/company/test/support/test_fixtures.ex", __DIR__))

Application.put_env(
  :bilimbi_factory_inventory,
  :posting_authority,
  Bilimbi.Factory.Inventory.TestPostingAuthority
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
