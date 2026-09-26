Code.require_file(Path.expand("../../../../base/database/test/support/data_case.ex", __DIR__))
Code.require_file(Path.expand("../../../../base/tenancy/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/geonames/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/company/test/support/test_fixtures.ex", __DIR__))

# The posting boundary reads every compiled module of the graph, which only a
# build of the whole mounted workspace has; CI runs it with `--only`.
ExUnit.start(exclude: [:compiled_graph])
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
