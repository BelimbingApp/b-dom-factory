defmodule Bilimbi.Factory.Inventory.PostingAuthority do
  @moduledoc false

  # The production posting-authority registry, as declared by the composition
  # metadata (see `inventory/docs/README.md`). Inventory builds it once at
  # application start from the loaded applications and caches it; nothing
  # registers at runtime, and Inventory names no authority.

  @registry {__MODULE__, :registry}

  @spec registered?(term()) :: boolean()
  def registered?(module) when is_atom(module) and module != nil,
    do: module in :persistent_term.get(@registry)

  def registered?(_other), do: false

  @spec install!() :: :ok
  def install!, do: :persistent_term.put(@registry, build!())

  # Accepts a declaration only from a Domain module of Inventory's own
  # container in the validated composition graph, naming one of that
  # application's own modules, and raises on any other.
  @spec build!() :: [module()]
  def build! do
    for {app, _description, _version} <- Application.loaded_applications(),
        env = Application.get_all_env(app),
        Keyword.has_key?(env, :posting_authority),
        do: declared!(app, env, Application.spec(app, :modules) || [])
  end

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
