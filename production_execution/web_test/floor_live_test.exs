defmodule BilimbiWeb.FactoryFloorLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Factory.Inventory.TestFixtures, as: InventoryFixtures
  alias Bilimbi.Factory.ProductionExecution
  alias Bilimbi.Factory.ProductionExecution.TestFixtures, as: ProductionFixtures

  @floor "factory.production-execution.floor.view"
  @record_wastage "factory.production-execution.wastage.record"
  @correct_wastage "factory.production-execution.wastage.correct"
  @record_labour "factory.production-execution.labour.record"
  @manage_labour "factory.production-execution.labour.manage"

  setup do
    UserFixtures.create_user_tables!()
    context = InventoryFixtures.mill!(company_tables?: false)
    ProductionFixtures.create_production_tables!()
    ProductionFixtures.create_labour_tables!()
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    context = ProductionFixtures.capture_run!(context)

    {:ok, reason} =
      ProductionExecution.create_wastage_reason(context.scope, 73, %{
        code: "REASON_A",
        label: "Reason A"
      })

    {:ok, role} =
      ProductionExecution.create_labour_role(context.scope, 73, %{code: "ROLE_A", label: "Role A"})

    Map.merge(context, %{reason: reason, role: role})
  end

  defp run_path(context),
    do: ~p"/factory/floor?#{[order: context.order.id, run: context.run.id]}"

  test "refuses the floor without its capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/factory/floor")
  end

  test "an operator picks an order and run, then records wastage with large controls",
       %{conn: conn} = context do
    grant_capabilities!([@floor, @record_wastage])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/factory/floor")

    render_click(element(view, "#floor-orders button", "ORDER-1"))
    assert_patch(view, ~p"/factory/floor?#{[order: context.order.id]}")
    render_click(element(view, "#floor-runs button", "SLIT"))
    assert_patch(view, run_path(context))

    render_click(element(view, "button[phx-click='pick_reason']", "Reason A"))

    view
    |> form("#wastage-form",
      wastage: %{
        line: "#{context.sheet.id}:#{context.sheet_unit}",
        quantity: "10",
        observation: "counted",
        note: "Edge damage"
      }
    )
    |> render_submit()

    assert has_element?(view, "#wastage-table td", "Reason A")
    assert has_element?(view, "#floor-yield", "Recorded wastage")
    refute has_element?(view, "button[phx-click='start_correction']")

    assert {:ok, [record]} = ProductionExecution.list_wastage(context.scope, 73, context.run.id)
    assert record.recorded_by_id == 91 and record.observation == "counted"
    assert Decimal.equal?(record.quantity, 10)
  end

  test "a viewer sees the run but cannot record by a forged event", %{conn: conn} = context do
    grant_capabilities!([@floor])
    {:ok, view, _html} = conn |> log_in_as() |> live(run_path(context))

    assert has_element?(view, "#floor-yield")
    refute has_element?(view, "#wastage-form")

    assert render_hook(view, "save_wastage", %{"wastage" => %{"quantity" => "1"}}) =~
             "permission to record wastage"

    assert {:ok, []} = ProductionExecution.list_wastage(context.scope, 73, context.run.id)
  end

  test "a supervisor corrects wastage with a reason", %{conn: conn} = context do
    grant_capabilities!([@floor, @record_wastage, @correct_wastage])

    {:ok, record} =
      ProductionExecution.record_wastage(
        Bilimbi.Base.Tenancy.Authentication.sign_in(context.scope, 91, 73),
        73,
        context.run.id,
        %{
          request_id: "W-1",
          reason_id: context.reason.id,
          item_id: context.sheet.id,
          identity_id: context.sheet_unit,
          location_id: context.slitter.id,
          quantity: "10",
          observation: "measured"
        }
      )

    {:ok, view, _html} = conn |> log_in_as() |> live(run_path(context))

    render_click(
      element(view, "button[phx-click='start_correction'][phx-value-id='#{record.id}']")
    )

    view
    |> form("#wastage-correction-form",
      correction: %{quantity: "6", correction_reason: "Recounted"}
    )
    |> render_submit()

    assert has_element?(view, "#wastage-table td", "Recounted")

    assert {:ok, [_original, corrected]} =
             ProductionExecution.list_wastage(context.scope, 73, context.run.id)

    assert corrected.corrects_id == record.id and Decimal.equal?(corrected.quantity, 6)
  end

  test "an operator clocks in on a run and out again", %{conn: conn} = context do
    grant_capabilities!([@floor, @record_labour])
    {:ok, view, _html} = conn |> log_in_as() |> live(run_path(context))

    refute has_element?(view, "#labour-entry-form")
    render_click(element(view, "button[phx-click='pick_role']", "Role A"))
    view |> form("#labour-form") |> render_submit()

    assert has_element?(view, "#labour-table td", "You")
    assert {:ok, [entry]} = ProductionExecution.list_labour(context.scope, 73, context.order.id)
    assert entry.worker_user_id == 91 and entry.execution_id == context.run.id

    render_click(element(view, "button[phx-click='clock_out'][phx-value-id='#{entry.id}']"))

    assert {:ok, [%{stopped_at: %DateTime{}}]} =
             ProductionExecution.list_labour(context.scope, 73, context.order.id)

    refute has_element?(view, "button[phx-click='clock_out']")

    assert render_hook(view, "save_labour_entry", %{"entry" => %{}}) =~
             "permission to manage labour"
  end

  test "a supervisor adds a finished entry for someone else and corrects it",
       %{conn: conn} = context do
    UserFixtures.insert_user!(%{
      id: 92,
      company_id: 73,
      name: "Helper",
      email: "helper@example.com"
    })

    grant_capabilities!([@floor, @manage_labour])

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/factory/floor?#{[order: context.order.id]}")

    view
    |> form("#labour-entry-form",
      entry: %{
        worker_user_id: 92,
        role_id: context.role.id,
        started_at: "2026-01-05T08:00",
        stopped_at: "2026-01-05T10:30"
      }
    )
    |> render_submit()

    assert has_element?(view, "#labour-table td", "Helper")
    assert has_element?(view, "#labour-total", "2h 30m")
    assert {:ok, [entry]} = ProductionExecution.list_labour(context.scope, 73, context.order.id)

    assert entry.worker_user_id == 92 and entry.recorded_by_id == 91 and
             is_nil(entry.execution_id)

    assert entry.started_at == ~U[2026-01-05 08:00:00.000000Z]

    render_click(
      element(view, "button[phx-click='start_labour_correction'][phx-value-id='#{entry.id}']")
    )

    view
    |> form("#labour-correction-form",
      labour_correction: %{stopped_at: "2026-01-05T09:00", correction_reason: "Left early"}
    )
    |> render_submit()

    assert has_element?(view, "#labour-table td", "Left early")
    assert has_element?(view, "#labour-total", "1h 00m")
  end
end
