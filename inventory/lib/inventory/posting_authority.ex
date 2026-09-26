defmodule Bilimbi.Factory.Inventory.PostingAuthority do
  @moduledoc """
  The credential a registered production posting authority presents.

  Inventory refuses production or transform context unless the posting
  carries one. Only a module whose OTP application is installed in
  Inventory's own Domain container, as its descriptor declares, may
  register, and each module registers once: the first registration receives
  the credential, and a later one naming the same module is refused, so a
  caller cannot obtain another module's credential by registering in its
  name. Production Execution registers at boot and keeps the credential to
  itself.

  The registry lives in memory, so registration repeats at every boot.
  Inventory names no registrant and depends on none.
  """

  @enforce_keys [:module, :secret]
  defstruct [:module, :secret]

  @opaque t :: %__MODULE__{module: module(), secret: binary()}

  @registry {__MODULE__, :registry}

  @doc false
  @spec register(module()) ::
          {:ok, t()} | {:error, :outside_domain_container | :already_registered}
  def register(module) when is_atom(module) do
    with :ok <- inside_container(module) do
      # Serialises concurrent registrations so exactly one receives the secret.
      :global.trans({@registry, self()}, fn -> put_new(module) end, [node()])
    end
  end

  @doc false
  @spec registered?(module()) :: boolean()
  def registered?(module) when is_atom(module), do: Map.has_key?(registry(), module)

  @doc false
  @spec verify(t() | term()) :: {:ok, module()} | :error
  def verify(%__MODULE__{module: module, secret: secret}) when is_binary(secret) do
    case registry() do
      %{^module => expected} when byte_size(expected) == byte_size(secret) ->
        if :crypto.hash_equals(expected, secret), do: {:ok, module}, else: :error

      _registry ->
        :error
    end
  end

  def verify(_other), do: :error

  defp put_new(module) do
    registry = registry()

    if Map.has_key?(registry, module) do
      {:error, :already_registered}
    else
      secret = :crypto.strong_rand_bytes(32)
      :persistent_term.put(@registry, Map.put(registry, module, secret))
      {:ok, %__MODULE__{module: module, secret: secret}}
    end
  end

  defp registry, do: :persistent_term.get(@registry, %{})

  # A module belongs to the OTP application whose resource lists it, and that
  # application's descriptor, recorded by composition, names its container in
  # the stable module ID. The descriptor is read directly rather than through
  # `ModuleRegistry.installed_modules!/0`, which refuses the partial graph a
  # package-local runtime loads.
  defp inside_container(module) do
    with {:ok, app} <- :application.get_application(module),
         %{id: id, layer: :domain} <- Application.get_env(app, :bilimbi_module),
         true <- container(id) == container(own_id()) do
      :ok
    else
      _outside -> {:error, :outside_domain_container}
    end
  end

  defp own_id do
    %{id: id} = Application.fetch_env!(:bilimbi_factory_inventory, :bilimbi_module)
    id
  end

  defp container(module_id), do: module_id |> String.split("/", parts: 2) |> hd()
end
