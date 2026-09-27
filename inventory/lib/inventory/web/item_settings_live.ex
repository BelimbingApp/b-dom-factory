defmodule Bilimbi.Factory.Inventory.Web.ItemSettingsLive do
  @moduledoc "Company item status and currency administration through Inventory."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.Inventory

  @view "factory.inventory.configuration.view"
  @manage "factory.inventory.configuration.manage"

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(:page_title, "Item settings")
      |> assign(:active_nav, "admin.factory.units")
      |> assign(:can_manage?, can?(socket, @manage))
      |> assign(:error, nil)

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("save", _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, assign(socket, :error, "You do not have permission to manage item settings.")}

  def handle_event("save", %{"settings" => params}, socket) do
    if can?(socket, @manage) do
      statuses =
        params
        |> Map.get("statuses", "")
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> nil
          values -> values
        end

      currency =
        params
        |> Map.get("currency", "")
        |> String.trim()
        |> String.upcase()
        |> case do
          "" -> nil
          value -> value
        end

      case Inventory.configure_item_settings(scope(socket), company_id(socket), %{
             statuses: statuses,
             default_currency_code: currency
           }) do
        {:ok, _settings} ->
          {:noreply, socket |> load() |> put_flash(:success, "Item settings saved.")}

        {:error, reason} ->
          {:noreply, socket |> assign(:form, settings_form(params)) |> assign(:error, error_text(reason))}
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to manage item settings.")}
    end
  end

  defp load(socket) do
    if can?(socket, @view) do
      with {:ok, settings} <- Inventory.item_settings(scope(socket), company_id(socket)),
           {:ok, overrides} <- Inventory.item_setting_overrides(scope(socket), company_id(socket)) do
        socket
        |> assign(:settings, settings)
        |> assign(:form, settings_form(%{
          "statuses" => Enum.join(overrides.statuses || [], "\n"),
          "currency" => overrides.default_currency_code || ""
        }))
        |> assign(:error, nil)
      else
        {:error, reason} ->
          socket |> assign(:settings, nil) |> assign(:form, settings_form(%{})) |> assign(:error, error_text(reason))
      end
    else
      socket |> assign(:settings, nil) |> assign(:form, settings_form(%{})) |> assign(:error, "You do not have permission to view item settings.")
    end
  end

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp settings_form(params),
    do: to_form(Map.merge(%{"statuses" => "", "currency" => ""}, params), as: :settings)

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
      <.page variant={:form}>
        <.header>
          Item settings
          <:subtitle>Set the company's item statuses and default currency.</:subtitle>
        </.header>

        <p :if={@error} id="item-settings-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card id="item-settings-card" title="Company overrides" class="mt-5">
          <.form :if={@can_manage?} for={@form} id="item-settings-form" phx-submit="save" class="space-y-4 p-4">
            <.input field={@form[:statuses]} type="textarea" label="Item statuses" hint="One status per line. The first is the default. Leave empty to inherit the tenant setting or allow any status." />
            <.input field={@form[:currency]} label="Default currency" hint="Three-letter currency code. Leave empty to inherit or require a currency on each item." />
            <.button type="submit" variant="primary">Save settings</.button>
          </.form>
          <.list :if={@settings} id="item-settings-facts">
            <:item title="Effective item statuses">{Enum.join(@settings.statuses || [], ", ")}</:item>
            <:item title="Effective default currency">{@settings.default_currency_code || "Not set"}</:item>
          </.list>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
