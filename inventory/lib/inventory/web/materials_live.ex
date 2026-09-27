defmodule Bilimbi.Factory.Inventory.Web.MaterialsLive do
  @moduledoc "Company material administration through the Inventory facade."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.Inventory

  @view "factory.inventory.configuration.view"
  @manage "factory.inventory.configuration.manage"

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:page_title, "Materials")
      |> assign(:active_nav, "admin.factory.materials")
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:editing, nil)
      |> assign(:form, material_form(%{}))
      |> assign(:error, nil)

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("new", _, socket) do
    with_manage(socket, fn socket ->
      {:noreply,
       socket
       |> assign(:editing, :new)
       |> assign(:form, material_form(%{}))
       |> assign(:error, nil)}
    end)
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      with {item_id, ""} <- Integer.parse(id),
           {:ok, material} <- Inventory.get_material(scope(socket), company_id(socket), item_id),
           {:ok, item} <- Inventory.get_item(scope(socket), company_id(socket), item_id) do
        {:noreply,
         socket
         |> assign(:editing, material)
         |> assign(
           :form,
           material_form(%{
             "sku" => item.sku,
             "title" => item.title,
             "status" => item.status,
             "currency_code" => item.currency_code,
             "description" => item.description || "",
             "native_unit_id" => to_string(material.native_unit.id),
             "material_type_id" =>
               if(material.material_type_id, do: to_string(material.material_type_id), else: ""),
             "properties" => Jason.encode!(material.properties, pretty: true)
           })
         )
         |> assign(:error, nil)}
      else
        {:error, reason} -> {:noreply, assign(socket, :error, error_text(reason))}
        _ -> {:noreply, assign(socket, :error, "Material not found.")}
      end
    end)
  end

  def handle_event("cancel", _, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> assign(:error, nil)}

  def handle_event("save", _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, assign(socket, :error, "You do not have permission to manage materials.")}

  def handle_event("save", %{"material" => params}, socket) do
    with_manage(socket, fn socket ->
      item_attrs =
        params
        |> Map.take(~w(sku title status currency_code description))
        |> Enum.reject(fn {_key, value} -> value == "" end)
        |> Map.new()

      properties = decode_properties(params["properties"])

      result =
        case socket.assigns.editing do
          :new ->
            with {unit_id, ""} <- Integer.parse(params["native_unit_id"] || ""),
                 {:ok, type_id} <- optional_id(params["material_type_id"]) do
              Inventory.create_material(scope(socket), company_id(socket), item_attrs, unit_id,
                material_type_id: type_id,
                properties: properties
              )
            else
              _ -> {:error, :invalid_material_reference}
            end

          %{item_id: item_id} ->
            Inventory.update_material(
              scope(socket),
              company_id(socket),
              item_id,
              item_attrs,
              properties
            )

          _ ->
            {:error, :material_not_found}
        end

      case result do
        {:ok, _material} ->
          {:noreply,
           socket
           |> assign(:editing, nil)
           |> assign(:error, nil)
           |> load()
           |> put_flash(:success, "Material saved.")}

        {:error, reason} ->
          {:noreply,
           socket |> assign(:form, material_form(params)) |> assign(:error, error_text(reason))}
      end
    end)
  end

  def handle_event("retire", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      result =
        case Integer.parse(id) do
          {item_id, ""} -> Inventory.retire_material(scope(socket), company_id(socket), item_id)
          _ -> {:error, :material_not_found}
        end

      case result do
        {:ok, _material} ->
          {:noreply, socket |> load() |> put_flash(:success, "Material retired.")}

        {:error, reason} ->
          {:noreply, assign(socket, :error, error_text(reason))}
      end
    end)
  end

  defp load(socket) do
    if can?(socket, @view) do
      with {:ok, materials} <-
             Inventory.list_materials(scope(socket), company_id(socket), limit: 500),
           {:ok, units} <- Inventory.list_units(scope(socket), company_id(socket), limit: 500),
           {:ok, types} <-
             Inventory.list_material_types(scope(socket), company_id(socket), limit: 500),
           {:ok, settings} <- Inventory.item_settings(scope(socket), company_id(socket)) do
        socket
        |> assign(:materials, materials)
        |> assign(:units, units)
        |> assign(:types, types)
        |> assign(:settings, settings)
      else
        {:error, reason} ->
          socket |> empty() |> assign(:error, error_text(reason))
      end
    else
      socket |> empty() |> assign(:error, "You do not have permission to view materials.")
    end
  end

  defp empty(socket) do
    socket
    |> assign(:materials, [])
    |> assign(:units, [])
    |> assign(:types, [])
    |> assign(:settings, %{statuses: nil, default_currency_code: nil})
  end

  defp with_manage(socket, callback) do
    if can?(socket, @manage),
      do: callback.(socket),
      else: {:noreply, assign(socket, :error, "You do not have permission to manage materials.")}
  end

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp material_form(params) do
    to_form(
      Map.merge(
        %{
          "sku" => "",
          "title" => "",
          "status" => "",
          "currency_code" => "",
          "description" => "",
          "native_unit_id" => "",
          "material_type_id" => "",
          "properties" => "{}"
        },
        params
      ),
      as: :material
    )
  end

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(""), do: {:ok, nil}

  defp optional_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_material_reference}
    end
  end

  defp decode_properties(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _} -> json
    end
  end

  defp decode_properties(_), do: nil

  defp error_text(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{Phoenix.Naming.humanize(field)} #{message}" end)
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
          Materials
          <:subtitle>Register an item with a native unit, material type, and typed values.</:subtitle>
          <:actions>
            <.button navigate={~p"/factory/material-types"}>Material types</.button>
            <.button navigate={~p"/factory/conversions"}>Conversions</.button>
            <.button :if={@can_manage?} id="new-material" phx-click="new" variant="primary">New material</.button>
          </:actions>
        </.header>

        <p :if={@error} id="material-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card :if={@editing} id="material-editor" title={if @editing == :new, do: "New material", else: "Material"} class="mt-5">
          <.form for={@form} id="material-form" phx-submit="save" class="space-y-4 p-4">
            <.input field={@form[:sku]} label="SKU" readonly={@editing != :new} />
            <.input field={@form[:title]} label="Title" />
            <.input field={@form[:description]} type="textarea" label="Description" />
            <.input field={@form[:status]} label="Status" hint={"Configured statuses: #{Enum.join(@settings.statuses || [], ", ")}"} />
            <.input field={@form[:currency_code]} label="Currency" hint={"Default: #{@settings.default_currency_code || "none"}"} />
            <.input field={@form[:native_unit_id]} type="select" label="Native unit" prompt="Choose a unit" disabled={@editing != :new} options={for unit <- @units, is_nil(unit.retired_at), do: {"#{unit.name} (#{unit.code})", unit.id}} />
            <.input field={@form[:material_type_id]} type="select" label="Material type" prompt="No type" disabled={@editing != :new} options={for type <- @types, is_nil(type.retired_at), do: {type.name, type.id}} />
            <.input field={@form[:properties]} type="textarea" label="Property values (JSON)" hint="Keys and value types are defined by the selected material type." />
            <div class="flex gap-2">
              <.button type="submit" variant="primary">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>

        <.card id="materials" inner_class="p-0" class="mt-5">
          <.table id="materials-table" rows={@materials} caption="Materials" framed={false}>
            <:col :let={material} label="SKU">{material.sku}</:col>
            <:col :let={material} label="Native unit">{material.native_unit.code}</:col>
            <:col :let={material} label="Type">{Enum.find_value(@types, "—", fn type -> if type.id == material.material_type_id, do: type.name end)}</:col>
            <:col :let={material} label="State">{if material.retired_at, do: "Retired", else: "Active"}</:col>
            <:action :let={material}>
              <div :if={@can_manage? and is_nil(material.retired_at)} class="flex gap-2">
                <.button type="button" phx-click="edit" phx-value-id={material.item_id}>Edit</.button>
                <.button type="button" phx-click="retire" phx-value-id={material.item_id} data-confirm="Retire this material?">Retire</.button>
              </div>
            </:action>
            <:empty :if={@materials == []} title="No materials" reason="Create a unit and a material to begin." />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
