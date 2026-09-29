defmodule Bilimbi.Factory.ProductionExecution.WastageTest do
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Factory.{Inventory, ProductionExecution}
  alias Ecto.Adapters.SQL
  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  @record "factory.production-execution.wastage.record"
  @correct "factory.production-execution.wastage.correct"

  setup do
    context = mill!()
    create_production_tables!()
    install_authz!()
    context = capture_run!(context)

    {:ok, start_up} =
      ProductionExecution.create_wastage_reason(context.scope, 73, %{
        code: "reason_a",
        label: "Reason A"
      })

    {:ok, defect} =
      ProductionExecution.create_wastage_reason(context.scope, 73, %{
        code: "REASON_B",
        label: "Reason B"
      })

    Map.merge(context, %{reason_a: start_up, reason_b: defect})
  end

  defp grant!(context, user_id, capability, company_id \\ 73) do
    assert {:ok, :stored} =
             Authz.put_principal_capability(
               context.scope,
               company_id,
               :user,
               user_id,
               capability,
               true
             )
  end

  defp as_user(context, user_id, company_id \\ 73, opts \\ []),
    do: Authentication.sign_in(context.scope, user_id, company_id, opts)

  defp scrap(context, request_id, overrides \\ %{}) do
    Map.merge(
      %{
        request_id: request_id,
        reason_id: context.reason_b.id,
        item_id: context.sheet.id,
        identity_id: context.sheet_unit,
        location_id: context.slitter.id,
        quantity: "10",
        observation: "measured",
        note: "Edge damage"
      },
      overrides
    )
  end

  defp start_up_scrap(context, request_id) do
    scrap(context, request_id, %{
      reason_id: context.reason_a.id,
      item_id: context.coil.id,
      identity_id: context.coil_lot,
      location_id: context.receiving.id,
      quantity: "4",
      note: nil
    })
  end

  defp balance(context) do
    {:ok, run_yield} = ProductionExecution.get_run_yield(context.scope, 73, context.run.id)
    [balance] = run_yield.balances

    {run_yield,
     Map.new(
       ~w(input product trim waste wastage variance)a,
       &{&1, balance |> Map.fetch!(&1) |> Decimal.normalize() |> Decimal.to_string(:normal)}
     )}
  end

  defp decisions(capability) do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM base_authz_decision_logs WHERE capability = $1",
        [capability]
      )

    count
  end

  describe "wastage reasons" do
    test "are company configuration with fixed, upper-cased codes", context do
      assert context.reason_a.code == "REASON_A" and context.reason_a.active

      assert {:error, %Ecto.Changeset{errors: [code: _]}} =
               ProductionExecution.create_wastage_reason(context.scope, 73, %{
                 code: "Reason_A",
                 label: "Duplicate"
               })

      assert {:ok, updated} =
               ProductionExecution.update_wastage_reason(
                 context.scope,
                 73,
                 context.reason_a.id,
                 %{
                   code: "RENAMED",
                   label: "Renamed reason",
                   active: false
                 }
               )

      assert updated.code == "REASON_A" and updated.label == "Renamed reason"
      refute updated.active

      assert {:ok, [%{code: "REASON_B"}]} =
               ProductionExecution.list_wastage_reasons(context.scope, 73, active: true)

      assert {:error, :wastage_reason_not_found} =
               ProductionExecution.get_wastage_reason(context.scope, 74, context.reason_a.id)

      assert {:ok, []} = ProductionExecution.list_wastage_reasons(context.scope, 74)
    end
  end

  describe "recording" do
    test "posts scrap through Inventory against the run, so its yield and positions reflect it",
         context do
      grant!(context, 9, @record)
      scope = as_user(context, 9)

      assert {:ok, defect} =
               ProductionExecution.record_wastage(
                 scope,
                 73,
                 context.run.id,
                 scrap(context, "W-1")
               )

      assert {:ok, start_up} =
               ProductionExecution.record_wastage(
                 scope,
                 73,
                 context.run.id,
                 start_up_scrap(context, "W-2")
               )

      assert defect.recorded_by_type == "user" and defect.recorded_by_id == 9
      assert defect.order_id == context.order.id and defect.execution_id == context.run.id
      assert Decimal.equal?(defect.quantity, 10) and defect.unit_id == context.kg.id

      {:ok, posting} =
        Inventory.get_transaction(context.scope, 73, defect.inventory_transaction_id)

      assert posting.kind == :consumption
      assert posting.actor_type == "user" and posting.actor_id == 9
      assert posting.evidence == "Wastage REASON_B: Reason B — Edge damage"

      assert posting.context == %{
               operation_execution: "RUN-1",
               order_or_batch: "ORDER-1",
               work_centre: Integer.to_string(context.resource.id)
             }

      # 100 kg in (plus 4 kg of start-up scrap from the same lot) = 70 kg
      # sheet left + 15 kg trim + 14 kg recorded wastage + 5 kg variance.
      {run_yield, totals} = balance(context)

      assert totals == %{
               input: "104",
               product: "70",
               trim: "15",
               waste: "14",
               wastage: "14",
               variance: "5"
             }

      assert run_yield.wastage_transaction_ids ==
               [defect.inventory_transaction_id, start_up.inventory_transaction_id]

      assert {:ok, [%{quantity: sheet_left}]} =
               Inventory.get_identity_positions(context.scope, 73, context.sheet_unit)

      assert Decimal.equal?(sheet_left, 70)

      assert {:ok, [first, second]} =
               ProductionExecution.list_wastage(context.scope, 73, context.run.id)

      assert first.id == defect.id and second.id == start_up.id
      assert is_nil(first.corrected_by_id)
    end

    test "an identical retry returns the record and a changed one is refused", context do
      grant!(context, 9, @record)
      scope = as_user(context, 9)
      attrs = scrap(context, "W-1")

      assert {:ok, record} = ProductionExecution.record_wastage(scope, 73, context.run.id, attrs)
      assert {:ok, ^record} = ProductionExecution.record_wastage(scope, 73, context.run.id, attrs)

      assert {:error, :request_id_conflict} =
               ProductionExecution.record_wastage(
                 scope,
                 73,
                 context.run.id,
                 %{attrs | quantity: "11"}
               )

      assert {:ok, [_one]} = ProductionExecution.list_wastage(context.scope, 73, context.run.id)
    end

    test "refuses a recorder without the capability, a system scope, and impersonation",
         context do
      attrs = scrap(context, "W-1")

      assert {:error, :capture_not_authorized} =
               ProductionExecution.record_wastage(as_user(context, 9), 73, context.run.id, attrs)

      assert decisions(@record) == 1

      assert {:error, :recorder_required} =
               ProductionExecution.record_wastage(context.scope, 73, context.run.id, attrs)

      grant!(context, 9, @record)

      assert {:error, :capture_refused_under_impersonation} =
               ProductionExecution.record_wastage(
                 as_user(context, 9, 73, impersonator_id: 2, impersonation_session_id: "support"),
                 73,
                 context.run.id,
                 attrs
               )

      grant!(context, 9, @record, 74)

      assert {:error, :recorder_company_mismatch} =
               ProductionExecution.record_wastage(
                 as_user(context, 9, 74),
                 73,
                 context.run.id,
                 attrs
               )

      assert {:error, :execution_not_found} =
               ProductionExecution.record_wastage(
                 as_user(context, 9, 74),
                 74,
                 context.run.id,
                 attrs
               )

      assert {:ok, []} = ProductionExecution.list_wastage(context.scope, 73, context.run.id)
      assert {:ok, [_receipt, _run]} = Inventory.list_transactions(context.scope, 73)
    end

    test "refuses material outside the run, inactive reasons, and invalid values", context do
      grant!(context, 9, @record)
      scope = as_user(context, 9)

      record =
        &ProductionExecution.record_wastage(scope, 73, context.run.id, scrap(context, "W", &1))

      assert {:error, :wastage_material_not_in_run} = record.(%{item_id: context.scrap.id})
      assert {:error, :wastage_material_not_in_run} = record.(%{identity_id: nil})
      assert {:error, :invalid_quantity} = record.(%{quantity: "0"})
      assert {:error, :invalid_quantity} = record.(%{quantity: "abc"})
      assert {:error, :invalid_observation} = record.(%{observation: "guessed"})
      assert {:error, :invalid_request_id} = record.(%{request_id: " "})
      assert {:error, :wastage_reason_not_found} = record.(%{reason_id: -1})

      assert {:error, :invalid_occurred_at} =
               record.(%{occurred_at: DateTime.add(DateTime.utc_now(), 3600)})

      assert {:error, :invalid_occurred_at} =
               record.(%{occurred_at: DateTime.add(context.run.started_at, -1)})

      assert {:error, :insufficient_stock} = record.(%{quantity: "81"})

      {:ok, _} =
        ProductionExecution.update_wastage_reason(context.scope, 73, context.reason_b.id, %{
          active: false
        })

      assert {:error, :wastage_reason_inactive} = record.(%{})
      assert {:ok, []} = ProductionExecution.list_wastage(context.scope, 73, context.run.id)
    end
  end

  describe "corrections" do
    setup context do
      grant!(context, 9, @record)
      grant!(context, 10, @correct)

      {:ok, defect} =
        ProductionExecution.record_wastage(
          as_user(context, 9),
          73,
          context.run.id,
          scrap(context, "W-1")
        )

      Map.put(context, :defect, defect)
    end

    test "need the correct capability and a reason, and are never silent edits", context do
      assert {:error, :capture_not_authorized} =
               ProductionExecution.correct_wastage(as_user(context, 9), 73, context.defect.id, %{
                 request_id: "C-1",
                 quantity: "6",
                 correction_reason: "Recount"
               })

      assert {:error, :correction_reason_required} =
               ProductionExecution.correct_wastage(as_user(context, 10), 73, context.defect.id, %{
                 request_id: "C-1",
                 quantity: "6",
                 correction_reason: " "
               })

      assert_raise Postgrex.Error, ~r/wastage records are immutable/, fn ->
        SQL.query!(Repo, "UPDATE factory_wastage_records SET quantity = 1", [])
      end

      assert_raise Postgrex.Error, ~r/wastage records are immutable/, fn ->
        SQL.query!(Repo, "DELETE FROM factory_wastage_records", [])
      end
    end

    test "a changed quantity posts an Inventory correction and the chain stays readable",
         context do
      scope = as_user(context, 10)

      assert {:ok, corrected} =
               ProductionExecution.correct_wastage(scope, 73, context.defect.id, %{
                 request_id: "C-1",
                 quantity: "6",
                 reason_id: context.reason_a.id,
                 correction_reason: "Recount"
               })

      assert corrected.corrects_id == context.defect.id and corrected.recorded_by_id == 10
      assert corrected.reason_id == context.reason_a.id and corrected.note == "Edge damage"
      assert corrected.correction_reason == "Recount"

      {:ok, adjustment} =
        Inventory.get_transaction(context.scope, 73, corrected.inventory_transaction_id)

      assert adjustment.kind == :correction
      assert adjustment.corrects_transaction_id == context.defect.inventory_transaction_id

      {_run_yield, totals} = balance(context)
      assert %{input: "100", product: "74", waste: "6", wastage: "6", variance: "5"} = totals

      assert {:ok, [%{quantity: sheet_left}]} =
               Inventory.get_identity_positions(context.scope, 73, context.sheet_unit)

      assert Decimal.equal?(sheet_left, 74)

      assert {:error, :wastage_already_corrected} =
               ProductionExecution.correct_wastage(scope, 73, context.defect.id, %{
                 request_id: "C-2",
                 quantity: "5",
                 correction_reason: "Again"
               })

      assert {:ok, [original, current]} =
               ProductionExecution.list_wastage(context.scope, 73, context.run.id)

      assert original.corrected_by_id == current.id and is_nil(current.corrected_by_id)

      assert {:ok, voided} =
               ProductionExecution.correct_wastage(scope, 73, current.id, %{
                 request_id: "C-3",
                 quantity: "0",
                 correction_reason: "Not scrapped"
               })

      assert Decimal.equal?(voided.quantity, 0)
      {_run_yield, totals} = balance(context)
      assert %{product: "80", waste: "0", wastage: "0"} = totals
    end

    test "an unchanged quantity records the correction without an Inventory posting", context do
      assert {:ok, corrected} =
               ProductionExecution.correct_wastage(as_user(context, 10), 73, context.defect.id, %{
                 request_id: "C-1",
                 quantity: "10",
                 reason_id: context.reason_a.id,
                 note: "",
                 correction_reason: "Wrong reason chosen"
               })

      assert is_nil(corrected.inventory_transaction_id) and is_nil(corrected.note)
      assert {:ok, [_receipt, _run, _wastage]} = Inventory.list_transactions(context.scope, 73)
    end
  end
end
