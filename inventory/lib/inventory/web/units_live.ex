defmodule Bilimbi.Factory.Inventory.Web.UnitsLive do
  @moduledoc "Company unit administration through the Inventory facade."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.Inventory

  @view "factory.inventory.configuration.view"
  @manage "factory.inventory.configuration.manage"

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:page_title, "Units")
      |> assign(:active_nav, "admin.factory.units")
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:editing, nil)
      |> assign(:form, unit_form(%{}))
      |> assign(:error, nil)

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("new", _, socket) do
    with_manage(socket, fn socket ->
      {:noreply, socket |> assign(:editing, :new) |> assign(:form, unit_form(%{})) |> assign(:error, nil)}
    end)
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      case Integer.parse(id) do
        {id, ""} ->
          case Inventory.get_unit(scope(socket), company_id(socket), id) do
            {:ok, unit} ->
              {:noreply,
               socket
               |> assign(:editing, unit)
               |> assign(:form, unit_form(%{"code" => unit.code, "name" => unit.name}))
               |> assign(:error, nil)}

            {:error, reason} -> {:noreply, assign(socket, :error, error_text(reason))}
          end

        _ -> {:noreply, assign(socket, :error, "Unit not found.")}
      end
    end)
  end

  def handle_event("cancel", _, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> assign(:error, nil)}

  def handle_event("save", _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, assign(socket, :error, "You do not have permission to manage units.")}

  def handle_event("save", %{"unit" => params}, socket) do
    with_manage(socket, fn socket ->
      result =
        case socket.assigns.editing do
          :new -> Inventory.create_unit(scope(socket), company_id(socket), params)
          %{id: id} -> Inventory.rename_unit(scope(socket), company_id(socket), id, params)
          _ -> {:error, :unit_not_found}
        end

      case result do
        {:ok, _unit} ->
          {:noreply,
           socket
           |> assign(:editing, nil)
           |> assign(:error, nil)
           |> load()
           |> put_flash(:success, "Unit saved.")}

        {:error, reason} ->
          {:noreply, socket |> assign(:form, unit_form(params)) |> assign(:error, error_text(reason))}
      end
    end)
  end

  def handle_event("retire", %{"id" => id}, socket) do
    with_manage(socket, fn socket ->
      result =
        case Integer.parse(id) do
          {id, ""} -> Inventory.retire_unit(scope(socket), company_id(socket), id)
          _ -> {:error, :unit_not_found}
        end

      case result do
        {:ok, _unit} -> {:noreply, socket |> load() |> put_flash(:success, "Unit retired.")}
        {:error, reason} -> {:noreply, assign(socket, :error, error_text(reason))}
      end
    end)
  end

  defp load(socket) do
    if can?(socket, @view) do
      case Inventory.list_units(scope(socket), company_id(socket), limit: 500) do
        {:ok, units} -> assign(socket, :units, units)
        {:error, reason} -> socket |> assign(:units, []) |> assign(:error, error_text(reason))
      end
    else
      socket |> assign(:units, []) |> assign(:error, "You do not have permission to view units.")
    end
  end

  defp with_manage(socket, callback) do
    if can?(socket, @manage),
      do: callback.(socket),
      else: {:noreply, assign(socket, :error, "You do not have permission to manage units.")}
  end

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp unit_form(params),
    do: to_form(Map.merge(%{"code" => "", "name" => ""}, params), as: :unit)

  defp error_text(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _}} -> "#{Phoenix.Naming.humanize(field)} #{message}" end)
    |> Enum.join("; ")
  end

  defp error_text(reason), do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>
          Units
          <:subtitle>Company units used by materials and conversions. Codes stay stable after creation.</:subtitle>
          <:actions>
            <.button navigate={~p"/factory/item-settings"}>Item settings</.button>
            <.button :if={@can_manage?} id="new-unit" phx-click="new" variant="primary">New unit</.button>
          </:actions>
        </.header>

        <p :if={@error} id="unit-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card :if={@editing} id="unit-editor" title={if @editing == :new, do: "New unit", else: "Unit"} class="mt-5">
          <.form for={@form} id="unit-form" phx-submit="save" class="space-y-4 p-4">
            <.input field={@form[:code]} label="Code" readonly={@editing != :new} />
            <.input field={@form[:name]} label="Name" />
            <div class="flex gap-2">
              <.button type="submit" variant="primary">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>

        <.card id="units" inner_class="p-0" class="mt-5">
          <.table id="units-table" rows={@units} caption="Units" framed={false}>
            <:col :let={unit} label="Code">{unit.code}</:col>
            <:col :let={unit} label="Name">{unit.name}</:col>
            <:col :let={unit} label="State">{if unit.retired_at, do: "Retired", else: "Active"}</:col>
            <:action :let={unit}>
              <div :if={@can_manage? and is_nil(unit.retired_at)} class="flex gap-2">
                <.button type="button" phx-click="edit" phx-value-id={unit.id}>Edit</.button>
                <.button type="button" phx-click="retire" phx-value-id={unit.id} data-confirm="Retire this unit?">Retire</.button>
              </div>
            </:action>
            <:empty :if={@units == []} title="No units" reason="Create a unit to use it with a material." />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
