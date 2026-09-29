defmodule Bilimbi.Factory.ProductionExecution.Web.FloorLive do
  @moduledoc """
  The tablet shop-floor page: pick an order, then one of its runs, then
  record against that run with large controls: scrapped material, who
  worked on it, and what its output measured. Every write goes through the
  Production Execution facade, which checks the capability on the run's
  order and records the signed-in user as the recorder; the flags here only
  decide which controls to show.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.UI.DateTimeDisplay
  alias Bilimbi.Core.User
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductionExecution
  alias Bilimbi.Factory.ProductionExecution.Web.CodeList

  @record_wastage "factory.production-execution.wastage.record"
  @correct_wastage "factory.production-execution.wastage.correct"
  @record_labour "factory.production-execution.labour.record"
  @manage_labour "factory.production-execution.labour.manage"
  @record_measurement "factory.production-execution.measurement.record"
  @correct_measurement "factory.production-execution.measurement.correct"

  @touch "min-h-14 px-6 text-base"
  # `<.input class=...>` replaces the input's own styling, so floor forms
  # enlarge their fields from the form instead.
  @fields "[&_input]:min-h-14 [&_select]:min-h-14 [&_input]:text-lg [&_select]:text-lg"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Shop floor")
      |> assign(:active_nav, "production.factory.floor")
      |> assign(:touch, @touch)
      |> assign(:fields, @fields)
      |> assign(:error, nil)
      |> assign(:order, nil)
      |> assign(:runs, [])
      |> assign(:run, nil)
      |> assign(:can_record_wastage?, can?(socket, @record_wastage))
      |> assign(:can_correct_wastage?, can?(socket, @correct_wastage))
      |> assign(:can_record_labour?, can?(socket, @record_labour))
      |> assign(:can_manage_labour?, can?(socket, @manage_labour))
      |> assign(:can_record_measurement?, can?(socket, @record_measurement))
      |> assign(:can_correct_measurement?, can?(socket, @correct_measurement))
      |> assign(:measurement_correcting, nil)
      |> assign(:user_id, socket.assigns.current_scope.user["user_id"])
      |> assign(:labour_correcting, nil)
      |> assign(:labour_form, labour_form(%{}))
      |> assign(:labour_entry_form, labour_entry_form(%{}))

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

  def handle_event("pick_measurement_type", %{"id" => id}, socket),
    do:
      {:noreply,
       update_form(socket, :measurement_form, %{"measurement_type_id" => id, "value" => ""})}

  def handle_event("change_measurement", %{"measurement" => params}, socket),
    do: {:noreply, update_form(socket, :measurement_form, params)}

  def handle_event("save_measurement", %{"measurement" => params}, socket) do
    if socket.assigns.can_record_measurement? do
      params = Map.merge(socket.assigns.measurement_form.params, params)

      case measurement_type(socket, params["measurement_type_id"]) do
        nil ->
          {:noreply, assign(socket, :error, "Choose what was measured.")}

        type ->
          attrs = %{
            request_id: params["request_id"],
            measurement_type_id: type.id,
            identity_id: integer(params["identity_id"]),
            value: typed_value(type, params["value"]),
            note: params["note"]
          }

          result(
            socket,
            ProductionExecution.record_measurement(
              scope(socket),
              company_id(socket),
              run_id(socket),
              attrs
            ),
            "Measurement recorded."
          )
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to record measurements.")}
    end
  end

  def handle_event("start_measurement_correction", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.measurements, &(Integer.to_string(&1.id) == id)) do
      nil ->
        {:noreply, assign(socket, :error, "Measurement not found.")}

      measurement ->
        {:noreply,
         socket
         |> assign(:measurement_correcting, measurement)
         |> assign(
           :measurement_correction_form,
           to_form(
             %{
               "request_id" => request_id(),
               "value" => measurement.value,
               "note" => measurement.note || "",
               "correction_reason" => ""
             },
             as: :measurement_correction
           )
         )}
    end
  end

  def handle_event("cancel_measurement_correction", _params, socket),
    do: {:noreply, assign(socket, :measurement_correcting, nil)}

  def handle_event("save_measurement_correction", %{"measurement_correction" => params}, socket) do
    if socket.assigns.can_correct_measurement? do
      measurement = socket.assigns.measurement_correcting
      type = measurement_type(socket, measurement.measurement_type_id)

      attrs = %{
        request_id: params["request_id"],
        value: typed_value(type, params["value"]),
        note: params["note"],
        correction_reason: params["correction_reason"]
      }

      result(
        socket,
        ProductionExecution.correct_measurement(
          scope(socket),
          company_id(socket),
          measurement.id,
          attrs
        ),
        "Measurement corrected."
      )
    else
      {:noreply, assign(socket, :error, "You do not have permission to correct measurements.")}
    end
  end

  def handle_event("pick_role", %{"id" => id}, socket),
    do: {:noreply, update_form(socket, :labour_form, %{"role_id" => id})}

  def handle_event("change_labour", %{"labour" => params}, socket),
    do: {:noreply, update_form(socket, :labour_form, params)}

  def handle_event("clock_in", _params, socket) do
    if can_clock?(socket) do
      params = socket.assigns.labour_form.params

      attrs = %{
        request_id: params["request_id"],
        role_id: integer(params["role_id"]),
        worker_user_id: integer(params["worker_user_id"]) || socket.assigns.user_id,
        execution_id: socket.assigns.run && socket.assigns.run.id
      }

      if is_nil(attrs.role_id),
        do: {:noreply, assign(socket, :error, "Choose a labour role.")},
        else:
          result(
            socket,
            ProductionExecution.clock_in(
              scope(socket),
              company_id(socket),
              order_id(socket),
              attrs
            ),
            "Clocked in."
          )
    else
      {:noreply, assign(socket, :error, "You do not have permission to record labour.")}
    end
  end

  def handle_event("clock_out", %{"id" => id}, socket) do
    if can_clock?(socket) do
      result(
        socket,
        ProductionExecution.clock_out(scope(socket), company_id(socket), integer(id)),
        "Clocked out."
      )
    else
      {:noreply, assign(socket, :error, "You do not have permission to record labour.")}
    end
  end

  def handle_event("save_labour_entry", %{"entry" => params}, socket) do
    if socket.assigns.can_manage_labour? do
      with {:ok, started_at} <- local_time(params["started_at"]),
           {:ok, stopped_at} <- local_time(params["stopped_at"]) do
        attrs = %{
          request_id: params["request_id"],
          role_id: integer(params["role_id"]),
          worker_user_id: integer(params["worker_user_id"]),
          execution_id: socket.assigns.run && socket.assigns.run.id,
          started_at: started_at,
          stopped_at: stopped_at,
          note: params["note"]
        }

        result(
          socket,
          ProductionExecution.record_labour(
            scope(socket),
            company_id(socket),
            order_id(socket),
            attrs
          ),
          "Labour recorded."
        )
      else
        :error -> {:noreply, assign(socket, :error, "Enter a start and stop time.")}
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to manage labour.")}
    end
  end

  def handle_event("start_labour_correction", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.labour, &(Integer.to_string(&1.id) == id)) do
      nil ->
        {:noreply, assign(socket, :error, "Labour entry not found.")}

      entry ->
        {:noreply,
         socket
         |> assign(:labour_correcting, entry)
         |> assign(
           :labour_correction_form,
           to_form(
             %{
               "request_id" => request_id(),
               "role_id" => Integer.to_string(entry.role_id),
               "started_at" => local_input(entry.started_at),
               "stopped_at" => local_input(entry.stopped_at),
               "correction_reason" => ""
             },
             as: :labour_correction
           )
         )}
    end
  end

  def handle_event("cancel_labour_correction", _params, socket),
    do: {:noreply, assign(socket, :labour_correcting, nil)}

  def handle_event("save_labour_correction", %{"labour_correction" => params}, socket) do
    if socket.assigns.can_manage_labour? do
      stopped_at =
        if params["stopped_at"] in [nil, ""],
          do: {:ok, nil},
          else: local_time(params["stopped_at"])

      with {:ok, started_at} <- local_time(params["started_at"]),
           {:ok, stopped_at} <- stopped_at do
        attrs = %{
          request_id: params["request_id"],
          role_id: integer(params["role_id"]),
          started_at: started_at,
          stopped_at: stopped_at,
          correction_reason: params["correction_reason"]
        }

        result(
          socket,
          ProductionExecution.correct_labour(
            scope(socket),
            company_id(socket),
            socket.assigns.labour_correcting.id,
            attrs
          ),
          "Labour corrected."
        )
      else
        :error -> {:noreply, assign(socket, :error, "Enter a valid start and stop time.")}
      end
    else
      {:noreply, assign(socket, :error, "You do not have permission to manage labour.")}
    end
  end

  defp result(socket, {:ok, _record}, message) do
    {:noreply,
     socket
     |> assign(:correcting, nil)
     |> assign(:labour_correcting, nil)
     |> assign(:measurement_correcting, nil)
     |> assign(:labour_form, labour_form(%{}))
     |> assign(:labour_entry_form, labour_entry_form(%{}))
     |> load_order()
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
      socket
      |> assign(order: order, runs: runs, labour_correcting: nil)
      |> assign(:labour_form, labour_form(%{}))
      |> assign(:labour_entry_form, labour_entry_form(%{}))
      |> load_order()
    else
      {:error, reason} ->
        assign(socket, order: nil, runs: [], error: CodeList.error_text(reason))
    end
  end

  # What the order's labour panel reads: its roles, entries, and totals, and
  # for a supervisor the company's users to record for.
  defp load_order(%{assigns: %{order: nil}} = socket), do: socket

  defp load_order(socket) do
    scope = scope(socket)
    company_id = company_id(socket)
    order_id = order_id(socket)

    users =
      with true <- socket.assigns.can_manage_labour?,
           {:ok, users} <- User.list_company_users(scope, company_id) do
        users
      else
        _ -> []
      end

    with {:ok, roles} <- ProductionExecution.list_labour_roles(scope, company_id),
         {:ok, labour} <- ProductionExecution.list_labour(scope, company_id, order_id),
         {:ok, summary} <- ProductionExecution.labour_summary(scope, company_id, order_id) do
      assign(socket, roles: roles, labour: labour, labour_summary: summary, users: users)
    else
      {:error, reason} -> assign(socket, :error, CodeList.error_text(reason))
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
        |> assign(:measurement_correcting, nil)
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
         {:ok, run_yield} <- ProductionExecution.get_run_yield(scope, company_id, run.id),
         {:ok, types} <- ProductionExecution.list_measurement_types(scope, company_id),
         {:ok, measurements} <- ProductionExecution.list_measurements(scope, company_id, run.id) do
      socket
      |> assign(:lines, lines(scope, company_id, transaction))
      |> assign(:locations, locations)
      |> assign(:reasons, reasons)
      |> assign(:wastage, wastage)
      |> assign(:run_yield, run_yield)
      |> assign(:wastage_form, wastage_form(%{}))
      |> assign(:measurement_types, types)
      |> assign(:measurements, measurements)
      |> assign(:measurement_form, measurement_form(%{}))
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

  defp measurement_form(params) do
    to_form(
      Map.merge(
        %{
          "request_id" => request_id(),
          "measurement_type_id" => "",
          "identity_id" => "",
          "value" => "",
          "note" => ""
        },
        params
      ),
      as: :measurement
    )
  end

  defp measurement_type(socket, id), do: find_type(socket.assigns.measurement_types, id)

  defp find_type(types, id) do
    id = if is_integer(id), do: id, else: integer(id)
    Enum.find(types, &(&1.id == id))
  end

  # A form value is text; the facade validates it as the type's value type.
  defp typed_value(%{value_type: "integer"}, value) do
    case Integer.parse(String.trim(value || "")) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp typed_value(%{value_type: "boolean"}, value) when value in ["true", "false"],
    do: value == "true"

  defp typed_value(_type, value), do: value

  defp outputs(lines), do: Enum.filter(lines, &(&1.side == "Output" and &1.identity_id))

  defp measured(_lines, nil), do: "Run output"

  defp measured(lines, identity_id),
    do:
      Enum.find_value(lines, "Unit #{identity_id}", &(&1.identity_id == identity_id && &1.label))

  defp limits(measurement) do
    [{"min", measurement.minimum}, {"target", measurement.target}, {"max", measurement.maximum}]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map_join(" · ", fn {label, value} -> "#{label} #{quantity(value)}" end)
  end

  defp order_id(socket), do: socket.assigns.order.id

  defp can_clock?(socket),
    do: socket.assigns.can_record_labour? or socket.assigns.can_manage_labour?

  defp labour_form(params) do
    to_form(
      Map.merge(%{"request_id" => request_id(), "role_id" => "", "worker_user_id" => ""}, params),
      as: :labour
    )
  end

  defp labour_entry_form(params) do
    to_form(
      Map.merge(
        %{
          "request_id" => request_id(),
          "worker_user_id" => "",
          "role_id" => "",
          "started_at" => "",
          "stopped_at" => "",
          "note" => ""
        },
        params
      ),
      as: :entry
    )
  end

  # Entered times are read in the zone the reader's timestamps display in:
  # the company's, or UTC for a reader who displays UTC.
  defp zone do
    case DateTimeDisplay.get() do
      %{mode: :utc} -> {"Etc/UTC", Calendar.get_time_zone_database()}
      %{timezone: zone, tz_db: db} when is_binary(zone) and not is_nil(db) -> {zone, db}
      _ -> {"Etc/UTC", Calendar.get_time_zone_database()}
    end
  end

  defp zone_name, do: elem(zone(), 0)

  defp local_time(value) when is_binary(value) do
    {zone, db} = zone()

    with {:ok, naive} <- NaiveDateTime.from_iso8601(seconds(value)),
         {:ok, local} <- from_naive(naive, zone, db),
         {:ok, utc} <- DateTime.shift_zone(local, "Etc/UTC", db) do
      {:ok, utc}
    else
      _ -> :error
    end
  end

  defp local_time(_value), do: :error

  defp from_naive(naive, zone, db) do
    case DateTime.from_naive(naive, zone, db) do
      {:ok, local} -> {:ok, local}
      {:ambiguous, first, _second} -> {:ok, first}
      _gap_or_error -> :error
    end
  end

  defp seconds(<<_date::binary-size(10), "T", _time::binary-size(5)>> = value), do: value <> ":00"
  defp seconds(value), do: value

  defp local_input(nil), do: ""

  defp local_input(%DateTime{} = at) do
    {zone, db} = zone()

    case DateTime.shift_zone(at, zone, db) do
      {:ok, local} ->
        local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> binary_part(0, 16)

      _ ->
        ""
    end
  end

  defp duration(nil), do: "open"

  defp duration(seconds) do
    minutes = div(seconds, 60)
    "#{div(minutes, 60)}h #{String.pad_leading(Integer.to_string(rem(minutes, 60)), 2, "0")}m"
  end

  defp worker_name(users, user_id, own_id) do
    cond do
      user_id == own_id -> "You"
      user = Enum.find(users, &(&1.id == user_id)) -> user.name
      true -> "User #{user_id}"
    end
  end

  defp role_label(roles, id), do: Enum.find_value(roles, "—", &(&1.id == id && &1.label))

  defp run_label(_runs, nil), do: "Order"

  defp run_label(runs, execution_id),
    do:
      Enum.find_value(runs, "Run #{execution_id}", &(&1.id == execution_id && &1.operation_code))

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
          <:subtitle>Record what happened on a run: scrapped material, who worked on it, and what its output measured.</:subtitle>
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
          <div class="mt-5">{labour_panel(assigns)}</div>
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
            <.form for={@wastage_form} id="wastage-form" phx-change="change_wastage" phx-submit="save_wastage" class={["space-y-4 p-4", @fields]}>
              <input type="hidden" name="wastage[request_id]" value={@wastage_form.params["request_id"]} />
              <input type="hidden" name="wastage[reason_id]" value={@wastage_form.params["reason_id"]} />
              <.input field={@wastage_form[:line]} type="select" label="Material" prompt="Choose material" options={for line <- @lines, do: {"#{line.side}: #{line.label} (#{quantity(line.quantity)} #{line.unit})", line.key}} />
              <.input field={@wastage_form[:location_id]} type="select" label="Drawn from" prompt="The run's location" options={for location <- @locations, do: {"#{location.code} · #{location.name}", location.id}} />
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input field={@wastage_form[:quantity]} label="Quantity (native unit)" inputmode="decimal" autocomplete="off" />
                <.input field={@wastage_form[:observation]} type="select" label="Quantity was" options={Inventory.observations()} />
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
            <.form for={@correction_form} id="wastage-correction-form" phx-submit="save_wastage_correction" class={["space-y-4 p-4", @fields]}>
              <input type="hidden" name="correction[request_id]" value={@correction_form.params["request_id"]} />
              <.input field={@correction_form[:quantity]} label="Corrected quantity (0 voids it)" inputmode="decimal" />
              <.input field={@correction_form[:reason_id]} type="select" label="Reason" options={for reason <- @reasons, reason.active or reason.id == @correcting.reason_id, do: {reason.label, reason.id}} />
              <.input field={@correction_form[:note]} label="Note" />
              <.input field={@correction_form[:correction_reason]} label="Why is this corrected?" />
              <div class="flex gap-3">
                <.button type="submit" variant="primary" class={@touch}>Save correction</.button>
                <.button type="button" phx-click="cancel_correction" class={@touch}>Cancel</.button>
              </div>
            </.form>
          </.card>

          {measurement_panel(assigns)}

          {labour_panel(assigns)}
        </section>
      </.page>
    </Layouts.app>
    """
  end

  # Values measured on the run's output, flagged outside their limits.
  defp measurement_panel(assigns) do
    ~H"""
    <div class="space-y-5">
      <.card :if={@can_record_measurement?} id="floor-measurement-entry" title="Measure output">
        <.form for={@measurement_form} id="measurement-form" phx-change="change_measurement" phx-submit="save_measurement" class={["space-y-4 p-4", @fields]}>
          <input type="hidden" name="measurement[request_id]" value={@measurement_form.params["request_id"]} />
          <input type="hidden" name="measurement[measurement_type_id]" value={@measurement_form.params["measurement_type_id"]} />
          <fieldset>
            <legend class="mb-2 text-sm font-semibold">What was measured</legend>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
              <.button :for={type <- @measurement_types} :if={type.active} type="button" phx-click="pick_measurement_type" phx-value-id={type.id} aria-pressed={to_string(@measurement_form.params["measurement_type_id"] == Integer.to_string(type.id))} variant={if @measurement_form.params["measurement_type_id"] == Integer.to_string(type.id), do: "primary"} class={@touch}>
                {type.label}{if type.unit, do: " (#{type.unit})"}
              </.button>
            </div>
            <p :if={Enum.all?(@measurement_types, &(not &1.active))} class="text-sm text-ink-muted">No active measurement types. An administrator defines them under Measurement types.</p>
          </fieldset>
          <.input field={@measurement_form[:identity_id]} type="select" label="Output" prompt="Run output as a whole" options={for line <- outputs(@lines), do: {line.label, line.identity_id}} />
          <%= case find_type(@measurement_types, @measurement_form.params["measurement_type_id"]) do %>
            <% %{value_type: "boolean"} = type -> %>
              <.input field={@measurement_form[:value]} type="select" label={type.label} prompt="Choose" options={[{"Yes", "true"}, {"No", "false"}]} />
            <% %{value_type: value_type} = type when value_type in ["integer", "decimal"] -> %>
              <.input field={@measurement_form[:value]} label={"#{type.label}#{if type.unit, do: " (#{type.unit})"}"} inputmode={if value_type == "integer", do: "numeric", else: "decimal"} autocomplete="off" hint={limits(type)} />
            <% %{} = type -> %>
              <.input field={@measurement_form[:value]} label={type.label} />
            <% nil -> %>
              <p class="text-sm text-ink-muted">Choose what was measured to enter its value.</p>
          <% end %>
          <.input field={@measurement_form[:note]} label="Note (optional)" />
          <.button type="submit" variant="primary" class={[@touch, "w-full"]} phx-disable-with="Recording…">Record measurement</.button>
        </.form>
      </.card>

      <.card id="floor-measurements" inner_class="p-0" title="Output measurements">
        <.table id="measurements-table" rows={Enum.filter(@measurements, &is_nil(&1.corrected_by_id))} caption="Current measurements" framed={false}>
          <:col :let={measurement} label="Measured">{Enum.find_value(@measurement_types, "—", &(&1.id == measurement.measurement_type_id && &1.label))}</:col>
          <:col :let={measurement} label="Output">{measured(@lines, measurement.identity_id)}</:col>
          <:col :let={measurement} label="Value">{measurement.value}{if measurement.unit, do: " #{measurement.unit}"}</:col>
          <:col :let={measurement} label="Limits">{limits(measurement)}</:col>
          <:col :let={measurement} label="Check">
            <.badge :if={measurement.out_of_range == true} kind={:danger}>Out of range</.badge>
            <.badge :if={measurement.out_of_range == false} kind={:success}>In range</.badge>
          </:col>
          <:col :let={measurement} label="When"><.datetime id={"measurement-#{measurement.id}-at"} value={measurement.measured_at} /></:col>
          <:col :let={measurement} label="Corrected">{if measurement.corrects_id, do: measurement.correction_reason, else: ""}</:col>
          <:action :let={measurement}>
            <.button :if={@can_correct_measurement?} type="button" phx-click="start_measurement_correction" phx-value-id={measurement.id} class={@touch}>Correct</.button>
          </:action>
          <:empty :if={Enum.all?(@measurements, & &1.corrected_by_id)} title="No measurements" reason="Nothing has been measured on this run's output yet." />
        </.table>
      </.card>

      <.card :if={@measurement_correcting} id="measurement-correction" title="Correct measurement">
        <.form for={@measurement_correction_form} id="measurement-correction-form" phx-submit="save_measurement_correction" class={["space-y-4 p-4", @fields]}>
          <input type="hidden" name="measurement_correction[request_id]" value={@measurement_correction_form.params["request_id"]} />
          <.input field={@measurement_correction_form[:value]} label="Corrected value" />
          <.input field={@measurement_correction_form[:note]} label="Note" />
          <.input field={@measurement_correction_form[:correction_reason]} label="Why is this corrected?" />
          <div class="flex gap-3">
            <.button type="submit" variant="primary" class={@touch}>Save correction</.button>
            <.button type="button" phx-click="cancel_measurement_correction" class={@touch}>Cancel</.button>
          </div>
        </.form>
      </.card>
    </div>
    """
  end

  # Labour on the order, or on the selected run: clock in and out, totals per
  # run, and a supervisor's entries and corrections for others.
  defp labour_panel(assigns) do
    ~H"""
    <div class="space-y-5">
      <.card :if={@can_record_labour? or @can_manage_labour?} id="floor-clock" title={if @run, do: "Clock in on this run", else: "Clock in on #{@order.code}"}>
        <.form for={@labour_form} id="labour-form" phx-change="change_labour" phx-submit="clock_in" class={["space-y-4 p-4", @fields]}>
          <input type="hidden" name="labour[request_id]" value={@labour_form.params["request_id"]} />
          <input type="hidden" name="labour[role_id]" value={@labour_form.params["role_id"]} />
          <.input :if={@can_manage_labour?} field={@labour_form[:worker_user_id]} type="select" label="Worker" prompt="Me" options={for user <- @users, user.id != @user_id, do: {user.name, user.id}} />
          <fieldset>
            <legend class="mb-2 text-sm font-semibold">Role</legend>
            <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
              <.button :for={role <- @roles} :if={role.active} type="button" phx-click="pick_role" phx-value-id={role.id} aria-pressed={to_string(@labour_form.params["role_id"] == Integer.to_string(role.id))} variant={if @labour_form.params["role_id"] == Integer.to_string(role.id), do: "primary"} class={@touch}>
                {role.label}
              </.button>
            </div>
            <p :if={Enum.all?(@roles, &(not &1.active))} class="text-sm text-ink-muted">No active labour roles. An administrator defines them under Labour roles.</p>
          </fieldset>
          <.button type="submit" variant="primary" class={[@touch, "w-full"]} phx-disable-with="Clocking in…">Clock in</.button>
        </.form>
      </.card>

      <.card id="floor-labour" inner_class="p-0" title="Labour">
        <div class="grid grid-cols-2 gap-3 p-4 sm:grid-cols-4">
          <div class="rounded-xl border border-line p-3">
            <div class="text-sm text-ink-muted">Order total</div>
            <div id="labour-total" class="text-xl tabular-nums">{duration(@labour_summary.total_seconds)}</div>
          </div>
          <div :for={run <- @labour_summary.runs} class="rounded-xl border border-line p-3">
            <div class="text-sm text-ink-muted">{run_label(@runs, run.execution_id)}</div>
            <div class="text-xl tabular-nums">{duration(run.seconds)}</div>
          </div>
        </div>
        <.table id="labour-table" rows={Enum.filter(@labour, &is_nil(&1.corrected_by_id))} caption="Current labour" framed={false}>
          <:col :let={entry} label="Worker">{worker_name(@users, entry.worker_user_id, @user_id)}</:col>
          <:col :let={entry} label="Role">{role_label(@roles, entry.role_id)}</:col>
          <:col :let={entry} label="Run">{run_label(@runs, entry.execution_id)}</:col>
          <:col :let={entry} label="Start"><.datetime id={"labour-#{entry.id}-start"} value={entry.started_at} /></:col>
          <:col :let={entry} label="Stop"><.datetime :if={entry.stopped_at} id={"labour-#{entry.id}-stop"} value={entry.stopped_at} /></:col>
          <:col :let={entry} label="Time">{duration(entry.seconds)}</:col>
          <:col :let={entry} label="Corrected">{if entry.corrects_id, do: entry.correction_reason, else: ""}</:col>
          <:action :let={entry}>
            <div class="flex gap-2">
              <.button :if={is_nil(entry.stopped_at) and ((@can_record_labour? and entry.worker_user_id == @user_id) or @can_manage_labour?)} type="button" phx-click="clock_out" phx-value-id={entry.id} variant="primary" class={@touch}>Clock out</.button>
              <.button :if={@can_manage_labour?} type="button" phx-click="start_labour_correction" phx-value-id={entry.id} class={@touch}>Correct</.button>
            </div>
          </:action>
          <:empty :if={Enum.all?(@labour, & &1.corrected_by_id)} title="No labour" reason="Nobody has clocked in on this order yet." />
        </.table>
      </.card>

      <.card :if={@labour_correcting} id="labour-correction" title="Correct labour">
        <.form for={@labour_correction_form} id="labour-correction-form" phx-submit="save_labour_correction" class={["space-y-4 p-4", @fields]}>
          <input type="hidden" name="labour_correction[request_id]" value={@labour_correction_form.params["request_id"]} />
          <.input field={@labour_correction_form[:role_id]} type="select" label="Role" options={for role <- @roles, role.active or role.id == @labour_correcting.role_id, do: {role.label, role.id}} />
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.input field={@labour_correction_form[:started_at]} type="datetime-local" label={"Start (#{zone_name()})"} />
            <.input field={@labour_correction_form[:stopped_at]} type="datetime-local" label={"Stop (#{zone_name()}); empty keeps it open"} />
          </div>
          <.input field={@labour_correction_form[:correction_reason]} label="Why is this corrected?" />
          <div class="flex gap-3">
            <.button type="submit" variant="primary" class={@touch}>Save correction</.button>
            <.button type="button" phx-click="cancel_labour_correction" class={@touch}>Cancel</.button>
          </div>
        </.form>
      </.card>

      <.card :if={@can_manage_labour?} id="labour-entry" title="Add a finished entry">
        <.form for={@labour_entry_form} id="labour-entry-form" phx-submit="save_labour_entry" class={["space-y-4 p-4", @fields]}>
          <input type="hidden" name="entry[request_id]" value={@labour_entry_form.params["request_id"]} />
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.input field={@labour_entry_form[:worker_user_id]} type="select" label="Worker" prompt="Choose a worker" options={for user <- @users, do: {user.name, user.id}} />
            <.input field={@labour_entry_form[:role_id]} type="select" label="Role" prompt="Choose a role" options={for role <- @roles, role.active, do: {role.label, role.id}} />
            <.input field={@labour_entry_form[:started_at]} type="datetime-local" label={"Start (#{zone_name()})"} />
            <.input field={@labour_entry_form[:stopped_at]} type="datetime-local" label={"Stop (#{zone_name()})"} />
          </div>
          <.input field={@labour_entry_form[:note]} label="Note (optional)" />
          <.button type="submit" class={@touch}>Add entry</.button>
        </.form>
      </.card>
    </div>
    """
  end
end
