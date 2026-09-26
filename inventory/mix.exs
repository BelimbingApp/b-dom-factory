Code.require_file(Path.expand("../../../../mix/composition_lock.exs", __DIR__))

[discovery_file] =
  Path.wildcard(Path.expand("../../../../apps/base/*/mix/module_discovery.exs", __DIR__))

Code.require_file(discovery_file)

defmodule Bilimbi.Factory.Inventory.MixProject do
  use Mix.Project

  @workspace_root Path.expand("../../../..", __DIR__)

  def project do
    [
      app: :bilimbi_factory_inventory,
      version: "0.1.0",
      build_path: Path.join(@workspace_root, "_build"),
      config_path: Path.join(@workspace_root, "config/config.exs"),
      deps_path: Path.join(@workspace_root, "deps"),
      lockfile: Bilimbi.CompositionLock.lockfile!(@workspace_root),
      elixir: "~> 1.20",
      compilers: [:bilimbi_graph] ++ Mix.compilers(),
      bilimbi_module_root: __DIR__,
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Bilimbi.Factory.Inventory.Application, []},
      extra_applications: [:logger],
      env:
        Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__) ++
          posting_authority(Mix.env())
    ]
  end

  # Production Execution declares no posting authority yet, so the tests
  # declare one the way it will.
  defp posting_authority(:test),
    do: [posting_authority: Bilimbi.Factory.Inventory.TestPostingAuthority]

  defp posting_authority(_env), do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [{:ecto_sql, "~> 3.14"}] ++
      Bilimbi.Base.ModuleRegistry.MixDiscovery.module_dependencies(__DIR__)
  end

  defp aliases do
    [test: ["ecto.create --quiet -r Bilimbi.Base.Repo", "test"]]
  end
end
