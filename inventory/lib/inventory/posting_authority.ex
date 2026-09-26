defmodule Bilimbi.Factory.Inventory.PostingAuthority do
  @moduledoc """
  The production posting-authority registry, as declared by the composition
  metadata.

  A module is a posting authority when its OTP application declares it beside
  the descriptor metadata composition writes into the application resource.
  Module discovery accepts no key beyond the descriptor's own, so the
  declaration sits in the application's `mix.exs`:

      def application do
        [
          extra_applications: [:logger],
          env:
            Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__) ++
              [posting_authority: Bilimbi.Factory.ProductionExecution]
        ]
      end

  Inventory reads the registry from the loaded applications. It accepts a
  declaration only from a Domain module of its own container in the validated
  composition graph, naming one of that application's own modules, and raises
  on any other. Nothing registers at runtime, and Inventory names no
  authority.

  The BEAM cannot prove which module calls, so a production posting names its
  authority, and Inventory's `posting_boundary_test.exs` fails when a compiled
  module other than a declared authority calls `record_output` or
  `record_transform`.
  """

  @doc false
  @spec registered?(term()) :: boolean()
  def registered?(module) when is_atom(module) and module != nil, do: module in registry()
  def registered?(_other), do: false

  @doc false
  @spec registry() :: [module()]
  def registry do
    for {app, _description, _version} <- Application.loaded_applications(),
        env = Application.get_all_env(app),
        Keyword.has_key?(env, :posting_authority),
        do: declared!(app, env, Application.spec(app, :modules) || [])
  end

  @doc false
  @spec declared!(atom(), keyword(), [module()]) :: module()
  def declared!(app, env, modules) do
    # The descriptor is read directly rather than through
    # `ModuleRegistry.installed_modules!/0`, which refuses the partial graph a
    # package-local runtime loads.
    own = Application.fetch_env!(:bilimbi_factory_inventory, :bilimbi_module)
    module = Keyword.fetch!(env, :posting_authority)

    case Keyword.get(env, :bilimbi_module) do
      %{id: id, layer: :domain} when is_atom(module) and module != nil ->
        if id in own.graph_module_ids and container(id) == container(own.id) and module in modules,
          do: module,
          else: refuse!(app, module)

      _descriptor ->
        refuse!(app, module)
    end
  end

  defp refuse!(app, module) do
    raise ArgumentError,
          "#{app} declares #{inspect(module)} as a posting authority; only a Domain module " <>
            "of Inventory's own container may declare one of its own modules"
  end

  defp container(module_id), do: module_id |> String.split("/", parts: 2) |> hd()
end
