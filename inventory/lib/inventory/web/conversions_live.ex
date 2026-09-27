defmodule Bilimbi.Factory.Inventory.Web.ConversionsLive do
  @moduledoc "Versioned item conversion administration through Inventory."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.Inventory

  @view "factory.inventory.configuration.view"
  @manage "factory.inventory.configuration.manage"

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:page_title, "Conversions")
      |> assign(:active_nav, "admin.factory.materials")
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:selected, nil)
      |> assign(:conversions, [])
      |> assign(:form, conversion_form(%{}))
      |> assign(:error, nil)

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    if can?(socket, @view) do
      case Integer.parse(id) do
        {id, ""} ->
          case Enum.find(socket.assigns.materials, &(&1.item_id == id)) do
            nil -> {:noreply, assign(socket, :error, "Material not found.")}
            material -> {:noreply, select(socket, material)}
          end

        _ ->
          {:noreply, assign(socket, :error, "Material not found.")}
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to view conversions.")}
    end
  end

  def handle_event("save", _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, assign(socket, :error, "You do not have permission to manage conversions.")}

  def handle_event("save", %{"conversion" => params}, socket) do
    if can?(socket, @manage) do
      with %{item_id: item_id} = material <- socket.assigns.selected,
           {unit_id, ""} <- Integer.parse(params["unit_id"] || ""),
           {:ok, _conversion} <-
             Inventory.define_conversion(
               scope(socket),
               company_id(socket),
               item_id,
               unit_id,
               params["factor"]
             ) do
        {:noreply,
         socket
         |> select(material)
         |> assign(:form, conversion_form(%{}))
         |> put_flash(:success, "Conversion version saved.")}
      else
        {:error, reason} ->
          {:noreply,
           socket |> assign(:form, conversion_form(params)) |> assign(:error, error_text(reason))}

        _ ->
          {:noreply, assign(socket, :error, "Select a material and unit.")}
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to manage conversions.")}
    end
  end

  defp load(socket) do
    if can?(socket, @view) do
      with {:ok, materials} <-
             Inventory.list_materials(scope(socket), company_id(socket), limit: 500),
           {:ok, units} <- Inventory.list_units(scope(socket), company_id(socket), limit: 500) do
        socket |> assign(:materials, materials) |> assign(:units, units)
      else
        {:error, reason} ->
          socket
          |> assign(:materials, [])
          |> assign(:units, [])
          |> assign(:error, error_text(reason))
      end
    else
      socket
      |> assign(:materials, [])
      |> assign(:units, [])
      |> assign(:error, "You do not have permission to view conversions.")
    end
  end

  defp select(socket, material) do
    case Inventory.list_conversions(scope(socket), company_id(socket), material.item_id) do
      {:ok, conversions} ->
        socket
        |> assign(:selected, material)
        |> assign(:conversions, conversions)
        |> assign(:error, nil)

      {:error, reason} ->
        assign(socket, :error, error_text(reason))
    end
  end

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp conversion_form(params),
    do: to_form(Map.merge(%{"unit_id" => "", "factor" => ""}, params), as: :conversion)

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
          Conversions
          <:subtitle>Each change publishes a new factor version. Earlier versions remain available for posted transactions.</:subtitle>
        </.header>

        <p :if={@error} id="conversion-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card id="conversion-materials" inner_class="p-0" class="mt-5">
          <.table id="conversion-materials-table" rows={@materials} caption="Materials" framed={false}>
            <:col :let={material} label="Material">{material.sku}</:col>
            <:col :let={material} label="Native unit">{material.native_unit.code}</:col>
            <:action :let={material}>
              <.button type="button" phx-click="select" phx-value-id={material.item_id}>Versions</.button>
            </:action>
            <:empty :if={@materials == []} title="No materials" reason="Register a material before defining conversions." />
          </.table>
        </.card>

        <.card :if={@selected} id="conversion-versions" title={"#{@selected.sku} conversions"} class="mt-5">
          <.table id="conversion-versions-table" rows={@conversions} caption="Conversion versions" framed={false}>
            <:col :let={conversion} label="Unit">{conversion.unit.code}</:col>
            <:col :let={conversion} label="Version">{conversion.version}</:col>
            <:col :let={conversion} label="Factor">{conversion.factor}</:col>
            <:empty :if={@conversions == []} title="No conversions" reason="Publish the first factor for this material." />
          </.table>
          <.form :if={@can_manage?} for={@form} id="conversion-form" phx-submit="save" class="space-y-4 p-4">
            <.input field={@form[:unit_id]} type="select" label="Unit" prompt="Choose a unit" options={for unit <- @units, is_nil(unit.retired_at) and unit.id != @selected.native_unit.id, do: {"#{unit.name} (#{unit.code})", unit.id}} />
            <.input field={@form[:factor]} label="Native units per one selected unit" />
            <.button type="submit" variant="primary">Publish conversion</.button>
          </.form>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
