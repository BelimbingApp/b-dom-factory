defmodule Bilimbi.Factory.ProductionExecution.Web.MeasurementTypesLive do
  @moduledoc "Company measurement type administration through the Production Execution facade."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.Inventory.PropertyDefinition
  alias Bilimbi.Factory.ProductionExecution
  alias Bilimbi.Factory.ProductionExecution.Web.CodeList

  @view "factory.production-execution.configuration.view"
  @manage "factory.production-execution.configuration.manage"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Measurement types")
      |> assign(:active_nav, "admin.factory.measurement-types")
      |> assign(:editing, nil)
      |> assign(:form, type_form(%{}))
      |> assign(:error, nil)
      |> assign(:can_manage?, can?(socket, @manage))

    {:ok, load(socket)}
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{can_manage?: false}} = socket),
    do: {:noreply, forbidden(socket)}

  def handle_event("new", _params, socket) do
    if can_manage?(socket),
      do: {:noreply, assign(socket, editing: :new, form: type_form(%{}), error: nil)},
      else: {:noreply, forbidden(socket)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    if can_manage?(socket) do
      case Enum.find(socket.assigns.types, &(Integer.to_string(&1.id) == id)) do
        nil ->
          {:noreply, assign(socket, :error, "Measurement type not found.")}

        type ->
          {:noreply,
           assign(socket,
             editing: type,
             form:
               type_form(%{
                 "code" => type.code,
                 "label" => type.label,
                 "value_type" => type.value_type,
                 "unit" => type.unit || "",
                 "minimum" => limit(type.minimum),
                 "maximum" => limit(type.maximum),
                 "target" => limit(type.target)
               }),
             error: nil
           )}
      end
    else
      {:noreply, forbidden(socket)}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, editing: nil, error: nil)}

  def handle_event("save", %{"type" => params}, socket) do
    if can_manage?(socket) do
      limits = Map.take(params, ["label", "minimum", "maximum", "target"])

      result =
        case socket.assigns.editing do
          :new ->
            ProductionExecution.create_measurement_type(
              scope(socket),
              company_id(socket),
              Map.merge(limits, Map.take(params, ["code", "value_type", "unit"]))
            )

          %{id: id} ->
            ProductionExecution.update_measurement_type(
              scope(socket),
              company_id(socket),
              id,
              limits
            )

          _ ->
            {:error, :measurement_type_not_found}
        end

      case result do
        {:ok, _type} ->
          {:noreply,
           socket
           |> assign(editing: nil, error: nil)
           |> load()
           |> put_flash(:success, "Measurement type saved.")}

        {:error, reason} ->
          {:noreply, assign(socket, form: type_form(params), error: CodeList.error_text(reason))}
      end
    else
      {:noreply, forbidden(socket)}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    if can_manage?(socket) do
      with %{} = type <- Enum.find(socket.assigns.types, &(Integer.to_string(&1.id) == id)),
           {:ok, _type} <-
             ProductionExecution.update_measurement_type(
               scope(socket),
               company_id(socket),
               type.id,
               %{active: not type.active}
             ) do
        {:noreply, load(socket)}
      else
        {:error, reason} -> {:noreply, assign(socket, :error, CodeList.error_text(reason))}
        _ -> {:noreply, assign(socket, :error, "Measurement type not found.")}
      end
    else
      {:noreply, forbidden(socket)}
    end
  end

  defp load(socket) do
    if can?(socket, @view) do
      case ProductionExecution.list_measurement_types(scope(socket), company_id(socket)) do
        {:ok, types} -> assign(socket, :types, types)
        {:error, reason} -> assign(socket, types: [], error: CodeList.error_text(reason))
      end
    else
      assign(socket,
        types: [],
        error: "You do not have permission to view measurement types."
      )
    end
  end

  defp can_manage?(socket), do: can?(socket, @manage)

  defp forbidden(socket),
    do: assign(socket, :error, "You do not have permission to manage measurement types.")

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp limit(nil), do: ""
  defp limit(decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp type_form(params) do
    to_form(
      Map.merge(
        %{
          "code" => "",
          "label" => "",
          "value_type" => "decimal",
          "unit" => "",
          "minimum" => "",
          "maximum" => "",
          "target" => ""
        },
        params
      ),
      as: :type
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>
          Measurement types
          <:subtitle>What operators measure on a run's output, with its unit and the limits a value is flagged outside.</:subtitle>
          <:actions>
            <.button :if={@can_manage?} id="new-measurement-type" phx-click="new" variant="primary">New type</.button>
          </:actions>
        </.header>

        <p :if={@error} id="measurement-type-error" role="alert" class="mt-4 text-sm text-danger-ink">{@error}</p>

        <.card :if={@editing} id="measurement-type-editor" title={if @editing == :new, do: "New measurement type", else: "Measurement type"} class="mt-5">
          <.form for={@form} id="measurement-type-form" phx-submit="save" class="space-y-4 p-4">
            <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <.input field={@form[:code]} label="Code" disabled={@editing != :new} />
              <.input field={@form[:label]} label="Label" />
              <.input field={@form[:value_type]} type="select" label="Value type" disabled={@editing != :new} options={PropertyDefinition.value_types()} />
              <.input field={@form[:unit]} label="Unit (numeric types)" disabled={@editing != :new} />
              <.input field={@form[:minimum]} label="Minimum" inputmode="decimal" />
              <.input field={@form[:maximum]} label="Maximum" inputmode="decimal" />
              <.input field={@form[:target]} label="Target" inputmode="decimal" />
            </div>
            <p class="text-sm text-ink-muted">Code, value type, and unit are fixed once created. Changed limits apply to new measurements only.</p>
            <div class="flex gap-2">
              <.button type="submit" variant="primary">Save</.button>
              <.button type="button" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>

        <.card id="measurement-types" inner_class="p-0" class="mt-5">
          <.table id="measurement-types-table" rows={@types} caption="Measurement types" framed={false}>
            <:col :let={type} label="Code">{type.code}</:col>
            <:col :let={type} label="Label">{type.label}</:col>
            <:col :let={type} label="Value">{type.value_type}{if type.unit, do: " (#{type.unit})"}</:col>
            <:col :let={type} label="Minimum">{limit(type.minimum)}</:col>
            <:col :let={type} label="Target">{limit(type.target)}</:col>
            <:col :let={type} label="Maximum">{limit(type.maximum)}</:col>
            <:col :let={type} label="State">{if type.active, do: "Active", else: "Inactive"}</:col>
            <:action :let={type}>
              <div :if={@can_manage?} class="flex gap-2">
                <.button type="button" phx-click="edit" phx-value-id={type.id}>Edit</.button>
                <.button type="button" phx-click="toggle_active" phx-value-id={type.id}>{if type.active, do: "Deactivate", else: "Activate"}</.button>
              </div>
            </:action>
            <:empty :if={@types == []} title="No measurement types" reason="Add what operators measure on a run's output." />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
