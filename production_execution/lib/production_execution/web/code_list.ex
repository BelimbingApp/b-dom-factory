defmodule Bilimbi.Factory.ProductionExecution.Web.CodeList do
  @moduledoc """
  The administration screen shared by a company's shop-floor code lists, such
  as its wastage reasons: code, label, and whether the entry is offered for
  new records. A LiveView passes its list's `config/0` and delegates.

  A code is fixed once created, so recorded history keeps its meaning; an
  entry that should no longer be used is deactivated, not deleted.
  """
  use Bilimbi.Base.UI, :html

  alias Bilimbi.Base.Authz

  @view "factory.production-execution.configuration.view"
  @manage "factory.production-execution.configuration.manage"

  @doc false
  def mount(socket, config) do
    socket
    |> Phoenix.Component.assign(:config, config)
    |> Phoenix.Component.assign(:page_title, config.title)
    |> Phoenix.Component.assign(:active_nav, config.nav)
    |> Phoenix.Component.assign(:editing, nil)
    |> Phoenix.Component.assign(:form, entry_form(%{}))
    |> Phoenix.Component.assign(:error, nil)
    |> Phoenix.Component.assign(:can_manage?, can?(socket, @manage))
    |> load()
  end

  @doc false
  def handle_event(_event, _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, forbidden(socket)}

  def handle_event("new", _params, socket) do
    if can_manage?(socket) do
      {:noreply,
       Phoenix.Component.assign(socket, editing: :new, form: entry_form(%{}), error: nil)}
    else
      {:noreply, forbidden(socket)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    if can_manage?(socket) do
      case Enum.find(socket.assigns.entries, &(Integer.to_string(&1.id) == id)) do
        nil ->
          {:noreply,
           Phoenix.Component.assign(socket, :error, "#{socket.assigns.config.noun} not found.")}

        entry ->
          {:noreply,
           Phoenix.Component.assign(socket,
             editing: entry,
             form: entry_form(%{"code" => entry.code, "label" => entry.label}),
             error: nil
           )}
      end
    else
      {:noreply, forbidden(socket)}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, Phoenix.Component.assign(socket, editing: nil, error: nil)}

  def handle_event("save", %{"entry" => params}, socket) do
    if can_manage?(socket) do
      config = socket.assigns.config

      result =
        case socket.assigns.editing do
          :new ->
            config.create.(scope(socket), company_id(socket), %{
              code: params["code"],
              label: params["label"]
            })

          %{id: id} ->
            config.update.(scope(socket), company_id(socket), id, %{label: params["label"]})

          _ ->
            {:error, :not_found}
        end

      case result do
        {:ok, _entry} ->
          {:noreply,
           socket
           |> Phoenix.Component.assign(editing: nil, error: nil)
           |> load()
           |> Phoenix.LiveView.put_flash(:success, "#{config.noun} saved.")}

        {:error, reason} ->
          {:noreply,
           Phoenix.Component.assign(socket, form: entry_form(params), error: error_text(reason))}
      end
    else
      {:noreply, forbidden(socket)}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    if can_manage?(socket) do
      config = socket.assigns.config

      with {id, ""} <- Integer.parse(id),
           %{} = entry <- Enum.find(socket.assigns.entries, &(&1.id == id)),
           {:ok, _entry} <-
             config.update.(scope(socket), company_id(socket), id, %{active: not entry.active}) do
        {:noreply, load(socket)}
      else
        {:error, reason} ->
          {:noreply, Phoenix.Component.assign(socket, :error, error_text(reason))}

        _ ->
          {:noreply, Phoenix.Component.assign(socket, :error, "#{config.noun} not found.")}
      end
    else
      {:noreply, forbidden(socket)}
    end
  end

  defp load(socket) do
    if can?(socket, @view) do
      case socket.assigns.config.list.(scope(socket), company_id(socket), []) do
        {:ok, entries} ->
          Phoenix.Component.assign(socket, :entries, entries)

        {:error, reason} ->
          Phoenix.Component.assign(socket, entries: [], error: error_text(reason))
      end
    else
      Phoenix.Component.assign(socket,
        entries: [],
        error: "You do not have permission to view #{socket.assigns.config.plural}."
      )
    end
  end

  defp can_manage?(socket), do: can?(socket, @manage)

  defp forbidden(socket),
    do:
      Phoenix.Component.assign(
        socket,
        :error,
        "You do not have permission to manage #{socket.assigns.config.plural}."
      )

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp entry_form(params),
    do: to_form(Map.merge(%{"code" => "", "label" => ""}, params), as: :entry)

  @doc false
  def error_text(%Ecto.Changeset{} = changeset) do
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

  def error_text(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  def error_text(reason), do: inspect(reason)

  @doc false
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>
          {@config.title}
          <:subtitle>{@config.subtitle}</:subtitle>
          <:actions>
            <.button :if={@can_manage?} id={"new-#{@config.id}"} phx-click="new" variant="primary">New</.button>
          </:actions>
        </.header>

        <p :if={@error} id={"#{@config.id}-error"} role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card :if={@editing} id={"#{@config.id}-editor"} title={if @editing == :new, do: "New #{String.downcase(@config.noun)}", else: @config.noun} class="mt-5">
          <.form for={@form} id={"#{@config.id}-form"} phx-submit="save" class="space-y-4 p-4">
            <.input field={@form[:code]} label="Code" disabled={@editing != :new} hint="Fixed once created, so recorded history keeps its meaning." />
            <.input field={@form[:label]} label="Label" />
            <div class="flex gap-2">
              <.button type="submit" variant="primary">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>

        <.card id={@config.id} inner_class="p-0" class="mt-5">
          <.table id={"#{@config.id}-table"} rows={@entries} caption={@config.title} framed={false}>
            <:col :let={entry} label="Code">{entry.code}</:col>
            <:col :let={entry} label="Label">{entry.label}</:col>
            <:col :let={entry} label="State">{if entry.active, do: "Active", else: "Inactive"}</:col>
            <:action :let={entry}>
              <div :if={@can_manage?} class="flex gap-2">
                <.button type="button" phx-click="edit" phx-value-id={entry.id}>Edit</.button>
                <.button type="button" phx-click="toggle_active" phx-value-id={entry.id}>{if entry.active, do: "Deactivate", else: "Activate"}</.button>
              </div>
            </:action>
            <:empty :if={@entries == []} title={"No #{@config.plural}"} reason={@config.empty} />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
