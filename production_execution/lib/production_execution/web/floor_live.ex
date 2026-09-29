defmodule Bilimbi.Factory.ProductionExecution.Web.FloorLive do
  @moduledoc """
  The tablet shop-floor page: pick an order, then one of its runs, then
  record against that run with large controls. Every write goes through the
  Production Execution facade, which checks the capability on the run's
  order and records the signed-in user as the recorder; the flags here only
  decide which controls to show.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductionExecution
  alias Bilimbi.Factory.ProductionExecution.Web.CodeList

  @record_wastage "factory.production-execution.wastage.record"
  @correct_wastage "factory.production-execution.wastage.correct"

  @touch "min-h-14 px-6 text-base"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Shop floor")
      |> assign(:active_nav, "production.factory.floor")
      |> assign(:touch, @touch)
      |> assign(:error, nil)
      |> assign(:order, nil)
      |> assign(:runs, [])
      |> assign(:run, nil)
      |> assign(:can_record_wastage?, can?(socket, @record_wastage))
      |> assign(:can_correct_wastage?, can?(socket, @correct_wastage))

    socket =
      case ProductionExecution.list_orders(scope(socket), company_id(socket)) do
        {:ok, orders} ->
          assign(socket, :orders, orders)

        {:error, reason} ->
          socket |> assign(:orders, []) |> assign(:error, CodeList.error_text(reason))
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:error, nil)
      |> select_order(integer(params["order"]))
      |> select_run(integer(params["run"]))

    {:noreply, socket}
  end

  @impl true
  def handle_event("pick_order", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/factory/floor?#{[order: id]}")}

  def handle_event("pick_run", %{"id" => id}, socket),
    do:
      {:noreply,
       push_patch(socket, to: ~p"/factory/floor?#{[order: socket.assigns.order.id, run: id]}")}

  def handle_event("back_to_orders", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/factory/floor")}

  def handle_event("back_to_runs", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/factory/floor?#{[order: socket.assigns.order.id]}")}

  def handle_event("pick_reason", %{"id" => id}, socket),
    do: {:noreply, update_form(socket, :wastage_form, %{"reason_id" => id})}

  def handle_event("change_wastage", %{"wastage" => params}, socket),
    do: {:noreply, update_form(socket, :wastage_form, params)}

  def handle_event("save_wastage", %{"wastage" => params}, socket) do
    if socket.assigns.can_record_wastage? do
      params = Map.merge(socket.assigns.wastage_form.params, params)

      with {:ok, line} <- line(socket, params["line"]),
           {:ok, attrs} <- wastage_attrs(params, line) do
        socket
        |> result(
          ProductionExecution.record_wastage(
            scope(socket),
            company_id(socket),
            run_id(socket),
            attrs
          ),
          "Wastage recorded."
        )
      else
        {:error, message} -> {:noreply, assign(socket, :error, message)}
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to record wastage.")}
    end
  end

  def handle_event("start_correction", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.wastage, &(Integer.to_string(&1.id) == id)) do
      nil ->
        {:noreply, assign(socket, :error, "Wastage record not found.")}

      record ->
        {:noreply,
         socket
         |> assign(:correcting, record)
         |> assign(
           :correction_form,
           to_form(
             %{
               "request_id" => request_id(),
               "quantity" => Decimal.to_string(record.quantity, :normal),
               "reason_id" => Integer.to_string(record.reason_id),
               "note" => record.note || "",
               "correction_reason" => ""
             },
             as: :correction
           )
         )}
    end
  end

  def handle_event("cancel_correction", _params, socket),
    do: {:noreply, assign(socket, :correcting, nil)}

  def handle_event("save_wastage_correction", %{"correction" => params}, socket) do
    if socket.assigns.can_correct_wastage? do
      attrs = %{
        request_id: params["request_id"],
        quantity: params["quantity"],
        reason_id: integer(params["reason_id"]),
        note: params["note"],
        correction_reason: params["correction_reason"]
      }

      result(
        socket,
        ProductionExecution.correct_wastage(
          scope(socket),
          company_id(socket),
          socket.assigns.correcting.id,
          attrs
        ),
        "Wastage corrected."
      )
    else
      {:noreply, assign(socket, :error, "You do not have permission to correct wastage.")}
    end
  end

  defp result(socket, {:ok, _record}, message) do
    {:noreply,
     socket
     |> assign(:correcting, nil)
     |> load_run()
     |> put_flash(:success, message)}
  end

  defp result(socket, {:error, reason}, _message),
    do: {:noreply, assign(socket, :error, CodeList.error_text(reason))}

  # ============================================================================
  # Selection
  # ============================================================================

  defp select_order(socket, nil), do: assign(socket, order: nil, runs: [])

  defp select_order(socket, order_id) do
    with {:ok, order} <-
           ProductionExecution.get_order(scope(socket), company_id(socket), order_id),
         {:ok, runs} <-
           ProductionExecution.list_executions(scope(socket), company_id(socket), order.id) do
      assign(socket, order: order, runs: runs)
    else
      {:error, reason} ->
        assign(socket, order: nil, runs: [], error: CodeList.error_text(reason))
    end
  end

  defp select_run(socket, run_id) do
    case Enum.find(socket.assigns.runs, &(&1.id == run_id)) do
      nil ->
        assign(socket, :run, nil)

      run ->
        socket
        |> assign(:run, run)
        |> assign(:correcting, nil)
        |> assign(:wastage_form, wastage_form(%{}))
        |> load_run()
    end
  end

  defp load_run(%{assigns: %{run: nil}} = socket), do: socket

  defp load_run(socket) do
    scope = scope(socket)
    company_id = company_id(socket)
    run = socket.assigns.run

    with {:ok, transaction} <-
           Inventory.get_transaction(scope, company_id, run.inventory_transaction_id),
         {:ok, locations} <- Inventory.list_locations(scope, company_id, limit: 500),
         {:ok, reasons} <- ProductionExecution.list_wastage_reasons(scope, company_id),
         {:ok, wastage} <- ProductionExecution.list_wastage(scope, company_id, run.id),
         {:ok, run_yield} <- ProductionExecution.get_run_yield(scope, company_id, run.id) do
      socket
      |> assign(:lines, lines(scope, company_id, transaction))
      |> assign(:locations, locations)
      |> assign(:reasons, reasons)
      |> assign(:wastage, wastage)
      |> assign(:run_yield, run_yield)
      |> assign(:wastage_form, wastage_form(%{}))
    else
      {:error, reason} -> assign(socket, :error, CodeList.error_text(reason))
    end
  end

  # The run's posted stock lines: what wastage may be drawn from.
  defp lines(scope, company_id, transaction) do
    for entry <- transaction.entries, entry.role == :stock do
      item =
        case Inventory.get_item(scope, company_id, entry.item_id) do
          {:ok, item} -> "#{item.sku} · #{item.title}"
          _ -> "Item #{entry.item_id}"
        end

      identity =
        case entry.identity_id && Inventory.get_identity(scope, company_id, entry.identity_id) do
          {:ok, identity} -> identity.code
          _ -> nil
        end

      %{
        key: "#{entry.item_id}:#{entry.identity_id}",
        item_id: entry.item_id,
        identity_id: entry.identity_id,
        location_id: entry.location_id,
        label: Enum.join(Enum.reject([item, identity], &is_nil/1), " · "),
        side: if(Decimal.negative?(entry.native_quantity), do: "Input", else: "Output"),
        quantity: Decimal.abs(entry.native_quantity),
        unit: entry.native_unit.code
      }
    end
    |> Enum.uniq_by(& &1.key)
  end

  defp line(socket, key) do
    case Enum.find(socket.assigns.lines, &(&1.key == key)) do
      nil -> {:error, "Choose the material that was scrapped."}
      line -> {:ok, line}
    end
  end

  defp wastage_attrs(params, line) do
    case integer(params["reason_id"]) do
      nil ->
        {:error, "Choose a wastage reason."}

      reason_id ->
        {:ok,
         %{
           request_id: params["request_id"],
           reason_id: reason_id,
           item_id: line.item_id,
           identity_id: line.identity_id,
           location_id: integer(params["location_id"]) || line.location_id,
           quantity: params["quantity"],
           observation: params["observation"],
           note: params["note"]
         }}
    end
  end

  defp wastage_form(params) do
    to_form(
      Map.merge(
        %{
          "request_id" => request_id(),
          "line" => "",
          "location_id" => "",
          "quantity" => "",
          "observation" => "measured",
          "reason_id" => "",
          "note" => ""
        },
        params
      ),
      as: :wastage
    )
  end

  defp update_form(socket, key, params) do
    form = socket.assigns[key]
    assign(socket, key, to_form(Map.merge(form.params, params), as: form.name))
  end

  # A fresh key per form, so a double-tapped submit is one record.
  defp request_id,
    do: "floor:" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp run_id(socket), do: socket.assigns.run.id

  defp can?(socket, capability),
    do: Authz.can(socket.assigns.current_scope.actor, capability).allowed

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  defp integer(nil), do: nil
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp reason_label(reasons, id),
    do: Enum.find_value(reasons, "—", &(&1.id == id && "#{&1.code} · #{&1.label}"))

  defp line_label(lines, record),
    do:
      Enum.find_value(lines, "Item #{record.item_id}", fn line ->
        line.item_id == record.item_id and line.identity_id == record.identity_id and line.label
      end)

  defp unit_code(lines, record),
    do:
      Enum.find_value(lines, "", fn line ->
        line.item_id == record.item_id and line.identity_id == record.identity_id and line.unit
      end)

  defp quantity(decimal), do: Decimal.to_string(Decimal.normalize(decimal), :normal)

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:list}>
        <.header>
          Shop floor
          <:subtitle>Record what happened on a run: scrapped material and its reason.</:subtitle>
        </.header>

        <p :if={@error} id="floor-error" role="alert" class="mt-4 text-base text-danger-ink">{@error}</p>

        <section :if={is_nil(@order)} id="floor-orders" class="mt-5">
          <h2 class="mb-3 text-lg font-semibold">Choose an order</h2>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.button :for={order <- @orders} type="button" phx-click="pick_order" phx-value-id={order.id} class={[@touch, "justify-start"]}>
              <span class="font-semibold">{order.code}</span>
              <span class="text-ink-muted">{order.kind}</span>
            </.button>
          </div>
          <.empty_state :if={@orders == []} title="No orders" reason="Orders appear here once they are created." />
        </section>

        <section :if={@order && is_nil(@run)} id="floor-runs" class="mt-5">
          <div class="mb-3 flex items-center gap-3">
            <.button type="button" phx-click="back_to_orders" class={@touch}>Orders</.button>
            <h2 class="text-lg font-semibold">Runs of {@order.code}</h2>
          </div>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <.button :for={run <- @runs} type="button" phx-click="pick_run" phx-value-id={run.id} class={[@touch, "justify-start"]}>
              <span class="font-semibold">{run.operation_code}</span>
              <.datetime id={"run-#{run.id}-completed"} value={run.completed_at} class="text-ink-muted" />
            </.button>
          </div>
          <.empty_state :if={@runs == []} title="No runs" reason="A run appears here once an operation of this order is completed." />
        </section>

        <section :if={@run} id="floor-run" class="mt-5 space-y-5">
          <div class="flex flex-wrap items-center gap-3">
            <.button type="button" phx-click="back_to_runs" class={@touch}>Runs</.button>
            <h2 class="text-lg font-semibold">{@order.code} · {@run.operation_code} · <.datetime id="run-completed" value={@run.completed_at} /></h2>
          </div>

          <.card id="floor-yield" title="Run yield">
            <div class="grid grid-cols-2 gap-3 p-4 sm:grid-cols-3 lg:grid-cols-6">
              <%= for balance <- @run_yield.balances do %>
                <div :for={{label, value} <- [{"Input", balance.input}, {"Product", balance.product}, {"Trim", balance.trim}, {"Waste", balance.waste}, {"Recorded wastage", balance.wastage}, {"Variance", balance.variance}]} class="rounded-xl border border-line p-3">
                  <div class="text-sm text-ink-muted">{label}</div>
                  <div class="text-xl tabular-nums">{quantity(value)} {balance.unit.code}</div>
                </div>
              <% end %>
            </div>
          </.card>

          <.card :if={@can_record_wastage?} id="floor-wastage-entry" title="Record wastage">
            <.form for={@wastage_form} id="wastage-form" phx-change="change_wastage" phx-submit="save_wastage" class="space-y-4 p-4">
              <input type="hidden" name="wastage[request_id]" value={@wastage_form.params["request_id"]} />
              <input type="hidden" name="wastage[reason_id]" value={@wastage_form.params["reason_id"]} />
              <.input field={@wastage_form[:line]} type="select" label="Material" prompt="Choose material" options={for line <- @lines, do: {"#{line.side}: #{line.label} (#{quantity(line.quantity)} #{line.unit})", line.key}} class="min-h-14 text-base" />
              <.input field={@wastage_form[:location_id]} type="select" label="Drawn from" prompt="The run's location" options={for location <- @locations, do: {"#{location.code} · #{location.name}", location.id}} class="min-h-14 text-base" />
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input field={@wastage_form[:quantity]} label="Quantity (native unit)" inputmode="decimal" autocomplete="off" class="min-h-14 text-xl" />
                <.input field={@wastage_form[:observation]} type="select" label="Quantity was" options={Inventory.observations()} class="min-h-14 text-base" />
              </div>
              <fieldset>
                <legend class="mb-2 text-sm font-semibold">Reason</legend>
                <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
                  <.button :for={reason <- @reasons} :if={reason.active} type="button" phx-click="pick_reason" phx-value-id={reason.id} aria-pressed={to_string(@wastage_form.params["reason_id"] == Integer.to_string(reason.id))} variant={if @wastage_form.params["reason_id"] == Integer.to_string(reason.id), do: "primary"} class={@touch}>
                    {reason.label}
                  </.button>
                </div>
                <p :if={Enum.all?(@reasons, &(not &1.active))} class="text-sm text-ink-muted">No active wastage reasons. An administrator defines them under Wastage reasons.</p>
              </fieldset>
              <.input field={@wastage_form[:note]} label="Note (optional)" />
              <.button type="submit" variant="primary" class={[@touch, "w-full"]} phx-disable-with="Recording…">Record wastage</.button>
            </.form>
          </.card>

          <.card id="floor-wastage" inner_class="p-0" title="Wastage on this run">
            <.table id="wastage-table" rows={Enum.filter(@wastage, &is_nil(&1.corrected_by_id))} caption="Current wastage" framed={false}>
              <:col :let={record} label="Material">{line_label(@lines, record)}</:col>
              <:col :let={record} label="Quantity">{quantity(record.quantity)} {unit_code(@lines, record)}</:col>
              <:col :let={record} label="Reason">{reason_label(@reasons, record.reason_id)}</:col>
              <:col :let={record} label="When"><.datetime id={"wastage-#{record.id}-at"} value={record.occurred_at} /></:col>
              <:col :let={record} label="Note">{record.note}</:col>
              <:col :let={record} label="Corrected">{if record.corrects_id, do: record.correction_reason, else: ""}</:col>
              <:action :let={record}>
                <.button :if={@can_correct_wastage?} type="button" phx-click="start_correction" phx-value-id={record.id} class={@touch}>Correct</.button>
              </:action>
              <:empty :if={Enum.all?(@wastage, & &1.corrected_by_id)} title="No wastage" reason="Nothing has been scrapped on this run yet." />
            </.table>
          </.card>

          <.card :if={@correcting} id="wastage-correction" title="Correct wastage">
            <.form for={@correction_form} id="wastage-correction-form" phx-submit="save_wastage_correction" class="space-y-4 p-4">
              <input type="hidden" name="correction[request_id]" value={@correction_form.params["request_id"]} />
              <.input field={@correction_form[:quantity]} label="Corrected quantity (0 voids it)" inputmode="decimal" class="min-h-14 text-xl" />
              <.input field={@correction_form[:reason_id]} type="select" label="Reason" options={for reason <- @reasons, reason.active or reason.id == @correcting.reason_id, do: {reason.label, reason.id}} class="min-h-14 text-base" />
              <.input field={@correction_form[:note]} label="Note" />
              <.input field={@correction_form[:correction_reason]} label="Why is this corrected?" />
              <div class="flex gap-3">
                <.button type="submit" variant="primary" class={@touch}>Save correction</.button>
                <.button type="button" phx-click="cancel_correction" class={@touch}>Cancel</.button>
              </div>
            </.form>
          </.card>
        </section>
      </.page>
    </Layouts.app>
    """
  end
end
