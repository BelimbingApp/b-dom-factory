defmodule Bilimbi.Factory.ProductDefinition.Web.ResourcesLive do
  @moduledoc "Company resource administration through Product Definition."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.ProductDefinition, as: Definitions

  @view "factory.product-definition.configuration.view"
  @manage "factory.product-definition.configuration.manage"

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:page_title, "Resources")
      |> assign(:active_nav, "admin.factory.resources")
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:editing, nil)
      |> assign(:form, resource_form(%{}))
      |> assign(:error, nil)

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("new", _, socket) do
    with_manage(socket, fn socket ->
      {:noreply,
       socket
       |> assign(:editing, :new)
       |> assign(:form, resource_form(%{}))
       |> assign(:error, nil)}
    end)
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      with {resource_id, ""} <- Integer.parse(id),
           {:ok, resource} <-
             Definitions.get_resource(scope(socket), company_id(socket), resource_id) do
        {:noreply,
         socket
         |> assign(:editing, resource)
         |> assign(
           :form,
           resource_form(%{
             "code" => resource.code,
             "name" => resource.name,
             "resource_type_id" => to_string(resource.resource_type_id),
             "properties" => Jason.encode!(resource.properties, pretty: true)
           })
         )
         |> assign(:error, nil)}
      else
        {:error, reason} -> {:noreply, assign(socket, :error, error_text(reason))}
        _ -> {:noreply, assign(socket, :error, "Resource not found.")}
      end
    end)
  end

  def handle_event("cancel", _, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> assign(:error, nil)}

  def handle_event("save", _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, assign(socket, :error, "You do not have permission to manage resources.")}

  def handle_event("save", %{"resource" => params}, socket) do
    with_manage(socket, fn socket ->
      attrs = %{
        "code" => params["code"],
        "name" => params["name"],
        "properties" => decode_properties(params["properties"])
      }

      result =
        case socket.assigns.editing do
          :new ->
            case Integer.parse(params["resource_type_id"] || "") do
              {type_id, ""} ->
                Definitions.create_resource(
                  scope(socket),
                  company_id(socket),
                  Map.put(attrs, "resource_type_id", type_id)
                )

              _ ->
                {:error, :resource_type_not_found}
            end

          %{id: id} ->
            Definitions.update_resource(scope(socket), company_id(socket), id, attrs)

          _ ->
            {:error, :resource_not_found}
        end

      case result do
        {:ok, _resource} ->
          {:noreply,
           socket
           |> assign(:editing, nil)
           |> assign(:error, nil)
           |> load()
           |> put_flash(:success, "Resource saved.")}

        {:error, reason} ->
          {:noreply,
           socket |> assign(:form, resource_form(params)) |> assign(:error, error_text(reason))}
      end
    end)
  end

  def handle_event("retire", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      result =
        case Integer.parse(id) do
          {resource_id, ""} ->
            Definitions.retire_resource(scope(socket), company_id(socket), resource_id)

          _ ->
            {:error, :resource_not_found}
        end

      case result do
        {:ok, _resource} ->
          {:noreply, socket |> load() |> put_flash(:success, "Resource retired.")}

        {:error, reason} ->
          {:noreply, assign(socket, :error, error_text(reason))}
      end
    end)
  end

  defp load(socket) do
    if can?(socket, @view) do
      with {:ok, resources} <- Definitions.list_resources(scope(socket), company_id(socket)),
           {:ok, types} <- Definitions.list_resource_types(scope(socket), company_id(socket)) do
        socket |> assign(:resources, resources) |> assign(:types, types)
      else
        {:error, reason} ->
          socket
          |> assign(:resources, [])
          |> assign(:types, [])
          |> assign(:error, error_text(reason))
      end
    else
      socket
      |> assign(:resources, [])
      |> assign(:types, [])
      |> assign(:error, "You do not have permission to view resources.")
    end
  end

  defp with_manage(socket, callback) do
    if can?(socket, @manage),
      do: callback.(socket),
      else: {:noreply, assign(socket, :error, "You do not have permission to manage resources.")}
  end

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp resource_form(params),
    do:
      to_form(
        Map.merge(
          %{"code" => "", "name" => "", "resource_type_id" => "", "properties" => "{}"},
          params
        ), as: :resource)

  defp decode_properties(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _} -> json
    end
  end

  defp decode_properties(_), do: nil

  defp error_text(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, options}} ->
      message =
        Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
          options |> Keyword.get(String.to_existing_atom(key)) |> to_string()
        end)

      "#{Phoenix.Naming.humanize(field)} #{message}"
    end)
    |> Enum.join("; ")
  end

  defp error_text(reason),
    do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>
          Resources
          <:subtitle>Register a resource against a company type and its property definitions.</:subtitle>
          <:actions>
            <.button navigate={~p"/factory/resource-types"}>Resource types</.button>
            <.button :if={@can_manage?} id="new-resource" phx-click="new" variant="primary">New resource</.button>
          </:actions>
        </.header>

        <p :if={@error} id="resource-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card :if={@editing} id="resource-editor" title={if @editing == :new, do: "New resource", else: "Resource"} class="mt-5">
          <.form for={@form} id="resource-form" phx-submit="save" class="space-y-4 p-4">
            <.input field={@form[:code]} label="Code" />
            <.input field={@form[:name]} label="Name" />
            <.input field={@form[:resource_type_id]} type="select" label="Resource type" prompt="Choose a type" disabled={@editing != :new} options={for type <- @types, is_nil(type.retired_at), do: {type.name, type.id}} />
            <.input field={@form[:properties]} type="textarea" label="Property values (JSON)" hint="Keys and value types are defined by the selected resource type." />
            <div class="flex gap-2">
              <.button type="submit" variant="primary">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>

        <.card id="resources" inner_class="p-0" class="mt-5">
          <.table id="resources-table" rows={@resources} caption="Resources" framed={false}>
            <:col :let={resource} label="Code">{resource.code}</:col>
            <:col :let={resource} label="Name">{resource.name}</:col>
            <:col :let={resource} label="Type">{Enum.find_value(@types, "—", fn type -> if type.id == resource.resource_type_id, do: type.name end)}</:col>
            <:col :let={resource} label="State">{if resource.retired_at, do: "Retired", else: "Active"}</:col>
            <:action :let={resource}>
              <div :if={@can_manage? and is_nil(resource.retired_at)} class="flex gap-2">
                <.button type="button" phx-click="edit" phx-value-id={resource.id}>Edit</.button>
                <.button type="button" phx-click="retire" phx-value-id={resource.id} data-confirm="Retire this resource?">Retire</.button>
              </div>
            </:action>
            <:empty :if={@resources == []} title="No resources" reason="Create a resource type, then register a resource." />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
