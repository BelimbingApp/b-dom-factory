defmodule Bilimbi.Factory.ProductionExecution.LabourTest do
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Core.User.TestFixtures, as: UserFixtures
  alias Bilimbi.Factory.ProductionExecution
  alias Ecto.Adapters.SQL
  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  @record "factory.production-execution.labour.record"
  @manage "factory.production-execution.labour.manage"

  setup do
    UserFixtures.create_user_tables!()
    context = mill!(company_tables?: false)
    create_production_tables!()
    create_labour_tables!()
    install_authz!()

    for {id, company_id} <- [{9, 73}, {10, 73}, {11, 73}, {12, 74}] do
      UserFixtures.insert_user!(%{
        id: id,
        company_id: company_id,
        name: "User #{id}",
        email: "user#{id}@example.com"
      })
    end

    context = capture_run!(context)

    {:ok, role_a} =
      ProductionExecution.create_labour_role(context.scope, 73, %{code: "role_a", label: "Role A"})

    {:ok, role_b} =
      ProductionExecution.create_labour_role(context.scope, 73, %{code: "ROLE_B", label: "Role B"})

    Map.merge(context, %{role_a: role_a, role_b: role_b})
  end

  defp grant!(context, user_id, capability) do
    assert {:ok, :stored} =
             Authz.put_principal_capability(context.scope, 73, :user, user_id, capability, true)
  end

  defp as_user(context, user_id, company_id \\ 73),
    do: Authentication.sign_in(context.scope, user_id, company_id)

  defp clock_in(context, user_id, request_id, attrs \\ %{}) do
    ProductionExecution.clock_in(
      as_user(context, user_id),
      73,
      context.order.id,
      Map.merge(
        %{request_id: request_id, role_id: context.role_a.id, execution_id: context.run.id},
        attrs
      )
    )
  end

  defp ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  defp decisions(capability) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM base_authz_decision_logs WHERE capability = $1",
        [capability]
      )

    count
  end

  test "labour roles are company configuration with fixed codes", context do
    assert context.role_a.code == "ROLE_A"

    assert {:ok, %{active: false, code: "ROLE_A"}} =
             ProductionExecution.update_labour_role(context.scope, 73, context.role_a.id, %{
               active: false
             })

    grant!(context, 9, @record)
    assert {:error, :labour_role_inactive} = clock_in(context, 9, "L-1")
    assert {:ok, []} = ProductionExecution.list_labour_roles(context.scope, 74)
  end

  test "an operator clocks in on a run once, then out, and the run totals it", context do
    grant!(context, 9, @record)

    assert {:ok, entry} = clock_in(context, 9, "L-1")
    assert entry.worker_user_id == 9 and entry.recorded_by_id == 9
    assert entry.execution_id == context.run.id and is_nil(entry.stopped_at)
    assert {:ok, ^entry} = clock_in(context, 9, "L-1")
    assert {:error, :worker_already_clocked_in} = clock_in(context, 9, "L-2")

    assert {:ok, closed} = ProductionExecution.clock_out(as_user(context, 9), 73, entry.id)
    assert closed.stopped_by_id == 9 and closed.seconds >= 0

    assert {:error, :labour_entry_closed} =
             ProductionExecution.clock_out(as_user(context, 9), 73, entry.id)

    assert {:ok, _} =
             ProductionExecution.record_labour(as_user(context, 9), 73, context.order.id, %{
               request_id: "L-3",
               role_id: context.role_b.id,
               started_at: ago(180),
               stopped_at: ago(120)
             })

    assert {:ok, summary} =
             ProductionExecution.labour_summary(context.scope, 73, context.order.id)

    assert summary.total_seconds == 3600 + closed.seconds
    assert summary.open == []

    assert [%{execution_id: run_id, entries: 1}, %{execution_id: nil, seconds: 3600, entries: 1}] =
             summary.runs

    assert run_id == context.run.id
    assert [%{worker_user_id: 9, entries: 2}] = summary.workers
  end

  test "someone else's time needs the manage capability", context do
    grant!(context, 9, @record)

    assert {:error, :capture_not_authorized} =
             clock_in(context, 9, "L-1", %{worker_user_id: 10})

    assert decisions(@manage) == 1

    grant!(context, 10, @record)
    {:ok, own} = clock_in(context, 10, "L-2")

    assert {:error, :capture_not_authorized} =
             ProductionExecution.clock_out(as_user(context, 9), 73, own.id)

    grant!(context, 11, @manage)
    assert {:ok, other} = clock_in(context, 11, "L-3", %{worker_user_id: 9})
    assert other.worker_user_id == 9 and other.recorded_by_id == 11

    assert {:ok, %{stopped_by_id: 11}} =
             ProductionExecution.clock_out(as_user(context, 11), 73, own.id)

    assert {:error, :worker_not_found} = clock_in(context, 11, "L-4", %{worker_user_id: 12})

    assert {:error, :recorder_required} =
             ProductionExecution.clock_in(context.scope, 73, context.order.id, %{
               request_id: "L-5",
               role_id: context.role_a.id
             })
  end

  test "recorded entries need past, ordered times that do not overlap", context do
    grant!(context, 9, @record)
    record = &ProductionExecution.record_labour(as_user(context, 9), 73, context.order.id, &1)

    base = %{
      request_id: "L-1",
      role_id: context.role_a.id,
      started_at: ago(120),
      stopped_at: ago(60)
    }

    assert {:ok, _entry} = record.(base)

    assert {:error, :labour_overlap} =
             record.(%{base | request_id: "L-2", started_at: ago(90), stopped_at: ago(30)})

    assert {:error, :invalid_labour_times} =
             record.(%{base | request_id: "L-3", started_at: ago(30), stopped_at: ago(40)})

    assert {:error, :invalid_labour_times} =
             record.(%{base | request_id: "L-3", started_at: ago(30), stopped_at: ago(-10)})

    assert {:error, :invalid_labour_times} = record.(Map.delete(base, :stopped_at))

    assert {:error, :execution_not_found} =
             record.(
               %{base | request_id: "L-4", started_at: ago(20), stopped_at: ago(10)}
               |> Map.put(:execution_id, -1)
             )

    assert {:ok, _entry} =
             record.(%{base | request_id: "L-5", started_at: ago(60), stopped_at: ago(30)})

    assert {:error, :invalid_labour_times} =
             clock_in(context, 9, "L-6", %{started_at: ago(5)})
  end

  test "a supervisor corrects an entry with a reason; entries never change silently", context do
    grant!(context, 9, @record)
    grant!(context, 10, @manage)
    {:ok, entry} = clock_in(context, 9, "L-1")

    correction = %{
      request_id: "C-1",
      started_at: ago(90),
      stopped_at: ago(30),
      correction_reason: "Forgot to clock out"
    }

    assert {:error, :capture_not_authorized} =
             ProductionExecution.correct_labour(as_user(context, 9), 73, entry.id, correction)

    assert {:error, :correction_reason_required} =
             ProductionExecution.correct_labour(as_user(context, 10), 73, entry.id, %{
               correction
               | correction_reason: ""
             })

    assert_raise Postgrex.Error, ~r/labour entries are immutable/, fn ->
      SQL.query!(Repo, "UPDATE factory_labour_entries SET note = 'changed'", [])
    end

    assert {:ok, corrected} =
             ProductionExecution.correct_labour(as_user(context, 10), 73, entry.id, correction)

    assert corrected.corrects_id == entry.id and corrected.recorded_by_id == 10
    assert corrected.seconds == 3600 and corrected.stopped_by_id == 10
    assert corrected.execution_id == context.run.id and corrected.role_id == context.role_a.id

    assert {:error, :labour_entry_corrected} =
             ProductionExecution.clock_out(as_user(context, 9), 73, entry.id)

    assert {:error, :labour_entry_corrected} =
             ProductionExecution.correct_labour(as_user(context, 10), 73, entry.id, %{
               correction
               | request_id: "C-2"
             })

    # The corrected open entry no longer counts, so the worker can clock in.
    assert {:ok, _} = clock_in(context, 9, "L-2")

    assert_raise Postgrex.Error, ~r/labour entries are immutable/, fn ->
      SQL.query!(Repo, "UPDATE factory_labour_entries SET stopped_at = now() WHERE id = $1", [
        corrected.id
      ])
    end

    assert_raise Postgrex.Error, ~r/labour entries are immutable/, fn ->
      SQL.query!(Repo, "DELETE FROM factory_labour_entries", [])
    end

    assert {:ok, entries} = ProductionExecution.list_labour(context.scope, 73, context.order.id)
    assert Enum.find(entries, &(&1.id == entry.id)).corrected_by_id == corrected.id

    assert {:ok, %{total_seconds: 3600}} =
             ProductionExecution.labour_summary(context.scope, 73, context.order.id)
  end
end
