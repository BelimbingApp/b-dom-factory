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

  setup do
    UserFixtures.create_user_tables!()
    context = InventoryFixtures.mill!(company_tables?: false)
    ProductionFixtures.create_production_tables!()
    UserFixtures.insert_user!(%{id: 91, company_id: 73, name: "Operator"})
    context = ProductionFixtures.capture_run!(context)

    {:ok, reason} =
      ProductionExecution.create_wastage_reason(context.scope, 73, %{
        code: "REASON_A",
        label: "Reason A"
      })

    Map.put(context, :reason, reason)
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
end
