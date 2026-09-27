defmodule Bilimbi.Factory.ProductDefinition.Web.ResourceTypesLive do
  @moduledoc "Company resource type administration through Product Definition."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.ProductDefinition, as: Definitions

  @view "factory.product-definition.configuration.view"
  @manage "factory.product-definition.configuration.manage"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Resource types")
      |> assign(:active_nav, "admin.factory.resources")
      |> assign(:editing, nil)
      |> assign(:form, type_form(%{}))
      |> assign(:error, nil)
      |> assign(:can_manage?, can?(socket, @manage))

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("new", _, socket) do
    with_manage(socket, fn socket ->
      {:noreply,
       socket |> assign(:editing, :new) |> assign(:form, type_form(%{})) |> assign(:error, nil)}
    end)
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      case Integer.parse(id) do
        {id, ""} ->
          case Definitions.get_resource_type(scope(socket), company_id(socket), id) do
            {:ok, type} ->
              {:noreply,
               socket
               |> assign(:editing, type)
               |> assign(
                 :form,
                 type_form(%{
                   "code" => type.code,
                   "name" => type.name,
                   "property_definitions" =>
                     Jason.encode!(type.property_definitions, pretty: true)
                 })
               )
               |> assign(:error, nil)}

            {:error, reason} ->
              {:noreply, assign(socket, :error, error_text(reason))}
          end

        _ ->
          {:noreply, assign(socket, :error, "Resource type not found.")}
      end
    end)
  end

  def handle_event("cancel", _, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> assign(:error, nil)}

  def handle_event("save", _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, assign(socket, :error, "You do not have permission to manage resource types.")}

  def handle_event("save", %{"type" => params}, socket) do
    with_manage(socket, fn socket ->
      attrs = %{
        "code" => params["code"],
        "name" => params["name"],
        "property_definitions" => definitions(params["property_definitions"])
      }

      result =
        case socket.assigns.editing do
          :new ->
            Definitions.create_resource_type(scope(socket), company_id(socket), attrs)

          %{id: id} ->
            Definitions.update_resource_type(scope(socket), company_id(socket), id, attrs)

          _ ->
            {:error, :resource_type_not_found}
        end

      case result do
        {:ok, _type} ->
          {:noreply,
           socket
           |> assign(:editing, nil)
           |> assign(:error, nil)
           |> load()
           |> put_flash(:success, "Resource type saved.")}

        {:error, reason} ->
          {:noreply,
           socket |> assign(:form, type_form(params)) |> assign(:error, error_text(reason))}
      end
    end)
  end

  def handle_event("retire", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      result =
        case Integer.parse(id) do
          {id, ""} -> Definitions.retire_resource_type(scope(socket), company_id(socket), id)
          _ -> {:error, :resource_type_not_found}
        end

      case result do
        {:ok, _type} ->
          {:noreply, socket |> load() |> put_flash(:success, "Resource type retired.")}

        {:error, reason} ->
          {:noreply, assign(socket, :error, error_text(reason))}
      end
    end)
  end

  defp load(socket) do
    if can?(socket, @view) do
      case Definitions.list_resource_types(scope(socket), company_id(socket)) do
        {:ok, types} -> assign(socket, :types, types)
        {:error, reason} -> socket |> assign(:types, []) |> assign(:error, error_text(reason))
      end
    else
      socket
      |> assign(:types, [])
      |> assign(:error, "You do not have permission to view resource types.")
    end
  end

  defp with_manage(socket, callback) do
    if can?(socket, @manage),
      do: callback.(socket),
      else:
        {:noreply, assign(socket, :error, "You do not have permission to manage resource types.")}
  end

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp type_form(params) do
    to_form(Map.merge(%{"code" => "", "name" => "", "property_definitions" => "[]"}, params),
      as: :type
    )
  end

  defp definitions(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _} -> json
    end
  end

  defp definitions(_), do: nil

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
          Resource types
          <:subtitle>Define the properties that a company's resources record.</:subtitle>
          <:actions>
            <.button :if={@can_manage?} id="new-resource-type" phx-click="new" variant="primary">New type</.button>
          </:actions>
        </.header>

        <p :if={@error} id="resource-type-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card :if={@editing} id="resource-type-editor" title={if @editing == :new, do: "New resource type", else: "Resource type"} class="mt-5">
          <.form for={@form} id="resource-type-form" phx-submit="save" class="space-y-4 p-4">
            <.input field={@form[:code]} label="Code" />
            <.input field={@form[:name]} label="Name" />
            <.input field={@form[:property_definitions]} type="textarea" label="Property definitions (JSON)" hint="Each definition has key, label, value_type, required, and optional unit." />
            <div class="flex gap-2">
              <.button type="submit" variant="primary">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>

        <.card id="resource-types" inner_class="p-0" class="mt-5">
          <.table id="resource-types-table" rows={@types} caption="Resource types" framed={false}>
            <:col :let={type} label="Code">{type.code}</:col>
            <:col :let={type} label="Name">{type.name}</:col>
            <:col :let={type} label="Properties">{length(type.property_definitions)}</:col>
            <:col :let={type} label="State">{if type.retired_at, do: "Retired", else: "Active"}</:col>
            <:action :let={type}>
              <div :if={@can_manage? and is_nil(type.retired_at)} class="flex gap-2">
                <.button type="button" phx-click="edit" phx-value-id={type.id}>Edit</.button>
                <.button type="button" phx-click="retire" phx-value-id={type.id} data-confirm="Retire this resource type?">Retire</.button>
              </div>
            </:action>
            <:empty :if={@types == []} title="No resource types" reason="Create a type to define its properties." />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
