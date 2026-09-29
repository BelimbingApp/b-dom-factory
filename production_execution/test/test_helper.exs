Code.require_file(Path.expand("../../../../base/database/test/support/data_case.ex", __DIR__))
Code.require_file(Path.expand("../../../../base/tenancy/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/geonames/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/company/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../base/settings/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/employee/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/user/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../inventory/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../product_definition/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("support/test_fixtures.ex", __DIR__))

# Module-local tests do not load Base Audit; composed-host tests cover capture.
Application.put_env(:bilimbi_base_database, :write_capture, nil)

# Inventory's item master reads company settings from the contribution snapshot.
Bilimbi.Factory.Inventory.TestFixtures.install_settings_snapshot!()

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
