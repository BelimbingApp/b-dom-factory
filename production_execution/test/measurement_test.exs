defmodule Bilimbi.Factory.ProductionExecution.MeasurementTest do
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Factory.ProductionExecution
  alias Ecto.Adapters.SQL
  import Bilimbi.Factory.Inventory.TestFixtures
  import Bilimbi.Factory.ProductionExecution.TestFixtures

  @record "factory.production-execution.measurement.record"
  @correct "factory.production-execution.measurement.correct"

  setup do
    context = mill!()
    create_production_tables!()
    install_authz!()
    context = capture_run!(context)

    # Example configuration: a mass-per-area measure with limits, and a
    # count without any.
    {:ok, measure} =
      ProductionExecution.create_measurement_type(context.scope, 73, %{
        code: "measure_a",
        label: "Measure A",
        value_type: "decimal",
        unit: "g/m2",
        minimum: "95",
        maximum: "105",
        target: "100"
      })

    {:ok, count} =
      ProductionExecution.create_measurement_type(context.scope, 73, %{
        code: "MEASURE_B",
        label: "Measure B",
        value_type: "integer"
      })

    Map.merge(context, %{measure: measure, count: count})
  end

  defp grant!(context, user_id, capability) do
    assert {:ok, :stored} =
             Authz.put_principal_capability(context.scope, 73, :user, user_id, capability, true)
  end

  defp as_user(context, user_id), do: Authentication.sign_in(context.scope, user_id, 73)

  defp measure(context, request_id, attrs) do
    ProductionExecution.record_measurement(
      as_user(context, 9),
      73,
      context.run.id,
      Map.merge(
        %{
          request_id: request_id,
          measurement_type_id: context.measure.id,
          identity_id: context.sheet_unit
        },
        attrs
      )
    )
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

  describe "measurement types" do
    test "are company configuration validated as one property definition", context do
      assert %{code: "MEASURE_A", value_type: "decimal", unit: "g/m2", active: true} =
               context.measure

      assert Decimal.equal?(context.measure.target, 100)

      create = &ProductionExecution.create_measurement_type(context.scope, 73, &1)

      assert {:error, :invalid_measurement_type} =
               create.(%{code: "C", label: "C", value_type: "string", unit: "mm"})

      assert {:error, :invalid_measurement_type} =
               create.(%{code: "C", label: "C", value_type: "colour"})

      assert {:error, :invalid_measurement_limits} =
               create.(%{code: "C", label: "C", value_type: "boolean", minimum: "1"})

      assert {:error, :invalid_measurement_limits} =
               create.(%{
                 code: "C",
                 label: "C",
                 value_type: "decimal",
                 minimum: "5",
                 maximum: "4"
               })

      assert {:error, %Ecto.Changeset{errors: [code: _]}} =
               create.(%{code: "Measure_A", label: "Again", value_type: "integer"})

      assert {:ok, updated} =
               ProductionExecution.update_measurement_type(
                 context.scope,
                 73,
                 context.measure.id,
                 %{
                   code: "RENAMED",
                   value_type: "integer",
                   unit: "kg",
                   label: "Measure A2",
                   maximum: "",
                   active: false
                 }
               )

      assert %{code: "MEASURE_A", value_type: "decimal", unit: "g/m2", label: "Measure A2"} =
               updated

      assert is_nil(updated.maximum) and not updated.active

      assert {:ok, [%{code: "MEASURE_B"}]} =
               ProductionExecution.list_measurement_types(context.scope, 73, active: true)

      assert {:error, :measurement_type_not_found} =
               ProductionExecution.get_measurement_type(context.scope, 74, context.measure.id)
    end
  end

  describe "recording" do
    setup context do
      grant!(context, 9, @record)
      context
    end

    test "flags a numeric value outside its limits and keeps the limits it was judged against",
         context do
      assert {:ok, inside} = measure(context, "M-1", %{value: "101.5"})
      assert inside.out_of_range == false and inside.value == "101.5" and inside.unit == "g/m2"
      assert inside.recorded_by_id == 9 and inside.identity_id == context.sheet_unit
      assert Decimal.equal?(inside.minimum, 95) and Decimal.equal?(inside.target, 100)

      assert {:ok, low} = measure(context, "M-2", %{value: "94.99"})
      assert low.out_of_range == true
      assert {:ok, edge} = measure(context, "M-3", %{value: Decimal.new("105")})
      assert edge.out_of_range == false

      assert {:ok, high} = measure(context, "M-4", %{value: "110"})
      assert high.out_of_range == true

      {:ok, _} =
        ProductionExecution.update_measurement_type(context.scope, 73, context.measure.id, %{
          maximum: "120"
        })

      assert {:ok, later} = measure(context, "M-5", %{value: "110"})
      assert later.out_of_range == false

      assert {:ok, measurements} =
               ProductionExecution.list_measurements(context.scope, 73, context.run.id)

      assert Enum.find(measurements, &(&1.id == high.id)).out_of_range == true

      assert {:ok, counted} =
               measure(context, "M-6", %{
                 measurement_type_id: context.count.id,
                 identity_id: nil,
                 value: 12
               })

      assert is_nil(counted.out_of_range) and is_nil(counted.identity_id) and
               counted.value == "12"
    end

    test "an identical retry returns the measurement and a changed one is refused", context do
      assert {:ok, first} = measure(context, "M-1", %{value: "100"})
      assert {:ok, ^first} = measure(context, "M-1", %{value: "100"})
      assert {:error, :request_id_conflict} = measure(context, "M-1", %{value: "99"})
    end

    test "refuses values of the wrong type, inputs, inactive types, and future times", context do
      assert {:error, :invalid_measurement_value} = measure(context, "M", %{value: "abc"})

      assert {:error, :invalid_measurement_value} =
               measure(context, "M", %{measurement_type_id: context.count.id, value: "12"})

      assert {:error, :identity_not_run_output} =
               measure(context, "M", %{identity_id: context.coil_lot, value: "100"})

      assert {:error, :invalid_measured_at} =
               measure(context, "M", %{
                 value: "100",
                 measured_at: DateTime.add(DateTime.utc_now(), 60)
               })

      {:ok, _} =
        ProductionExecution.update_measurement_type(context.scope, 73, context.measure.id, %{
          active: false
        })

      assert {:error, :measurement_type_inactive} = measure(context, "M", %{value: "100"})
      assert {:ok, []} = ProductionExecution.list_measurements(context.scope, 73, context.run.id)
    end
  end

  test "refuses a recorder without the capability or a signed-in user", context do
    assert {:error, :capture_not_authorized} = measure(context, "M-1", %{value: "100"})
    assert decisions(@record) == 1

    assert {:error, :recorder_required} =
             ProductionExecution.record_measurement(context.scope, 73, context.run.id, %{
               request_id: "M-1",
               measurement_type_id: context.measure.id,
               value: "100"
             })

    assert {:ok, []} = ProductionExecution.list_measurements(context.scope, 73, context.run.id)
  end

  test "a correction needs its capability and a reason, and is judged on the original limits",
       context do
    grant!(context, 9, @record)
    grant!(context, 10, @correct)
    {:ok, measured} = measure(context, "M-1", %{value: "110"})

    {:ok, _} =
      ProductionExecution.update_measurement_type(context.scope, 73, context.measure.id, %{
        maximum: "200"
      })

    correction = %{request_id: "C-1", value: "106", correction_reason: "Misread gauge"}

    assert {:error, :capture_not_authorized} =
             ProductionExecution.correct_measurement(
               as_user(context, 9),
               73,
               measured.id,
               correction
             )

    assert {:error, :correction_reason_required} =
             ProductionExecution.correct_measurement(as_user(context, 10), 73, measured.id, %{
               correction
               | correction_reason: " "
             })

    assert {:ok, corrected} =
             ProductionExecution.correct_measurement(
               as_user(context, 10),
               73,
               measured.id,
               correction
             )

    assert corrected.corrects_id == measured.id and corrected.value == "106"
    assert corrected.out_of_range == true and Decimal.equal?(corrected.maximum, 105)
    assert corrected.recorded_by_id == 10 and corrected.measured_at == measured.measured_at

    assert {:error, :measurement_already_corrected} =
             ProductionExecution.correct_measurement(as_user(context, 10), 73, measured.id, %{
               correction
               | request_id: "C-2"
             })

    assert_raise Postgrex.Error, ~r/measurements are immutable/, fn ->
      SQL.query!(Repo, "UPDATE factory_measurements SET value = '1'", [])
    end

    assert {:ok, [original, current]} =
             ProductionExecution.list_measurements(context.scope, 73, context.run.id)

    assert original.corrected_by_id == current.id and is_nil(current.corrected_by_id)
  end
end
