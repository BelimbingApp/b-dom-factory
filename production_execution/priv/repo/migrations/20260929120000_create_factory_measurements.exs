defmodule Bilimbi.Factory.ProductionExecution.Migrations.CreateMeasurements do
  @moduledoc """
  A company's measurement types and the values measured on a run's output.

  Which measurement types exist, with their units and limits, is the
  company's configuration: nothing here names one. A measurement keeps the
  limits it was judged against and whether it fell outside them, so a later
  change to a type's limits never restates a recorded flag. Measurements are
  append-only; a correction is a new measurement that names the one it
  corrects, corrected at most once.
  """

  use Ecto.Migration

  def up do
    create table(:factory_measurement_types) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)
      add(:code, :string, size: 64, null: false)
      add(:label, :string, null: false)
      add(:value_type, :string, null: false)
      add(:unit, :string, size: 32)
      add(:minimum, :decimal, precision: 24, scale: 12)
      add(:maximum, :decimal, precision: 24, scale: 12)
      add(:target, :decimal, precision: 24, scale: 12)
      add(:active, :boolean, null: false, default: true)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:factory_measurement_types, [:company_id, :code],
        name: :factory_measurement_types_company_id_code_unique
      )
    )

    create(
      unique_index(:factory_measurement_types, [:id, :company_id],
        name: :factory_measurement_types_id_company_id_unique
      )
    )

    create(
      constraint(:factory_measurement_types, :factory_measurement_types_limits,
        check: "minimum IS NULL OR maximum IS NULL OR minimum <= maximum"
      )
    )

    create table(:factory_measurements) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)
      add(:request_id, :string, null: false)
      add(:request_fingerprint, :string, null: false)
      add(:order_id, references(:factory_production_orders, on_delete: :restrict), null: false)

      add(:execution_id, references(:factory_operation_executions, on_delete: :restrict),
        null: false
      )

      add(:identity_id, references(:factory_inventory_identities, on_delete: :restrict))

      add(
        :measurement_type_id,
        references(:factory_measurement_types,
          on_delete: :restrict,
          with: [company_id: :company_id],
          name: :factory_measurements_measurement_type_id_fkey
        ),
        null: false
      )

      add(:value, :text, null: false)
      add(:unit, :string, size: 32)
      add(:minimum, :decimal, precision: 24, scale: 12)
      add(:maximum, :decimal, precision: 24, scale: 12)
      add(:target, :decimal, precision: 24, scale: 12)
      add(:out_of_range, :boolean)
      add(:note, :text)
      add(:measured_at, :utc_datetime_usec, null: false)
      add(:recorded_by_type, :string, null: false)
      add(:recorded_by_id, :bigint, null: false)
      add(:recorded_by_acting_for_user_id, :bigint)
      add(:corrects_id, references(:factory_measurements, on_delete: :restrict))
      add(:correction_reason, :text)
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create(unique_index(:factory_measurements, [:company_id, :request_id]))
    create(unique_index(:factory_measurements, [:corrects_id]))
    create(index(:factory_measurements, [:execution_id]))
    create(index(:factory_measurements, [:identity_id]))

    create(
      constraint(:factory_measurements, :factory_measurements_correction,
        check:
          "(corrects_id IS NULL AND correction_reason IS NULL) OR " <>
            "(corrects_id IS NOT NULL AND length(btrim(correction_reason)) > 0)"
      )
    )

    execute("""
    CREATE FUNCTION factory_measurements_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN
      RAISE EXCEPTION 'measurements are immutable; record a correction';
    END $$
    """)

    execute("""
    CREATE TRIGGER factory_measurements_append_only
    BEFORE UPDATE OR DELETE ON factory_measurements
    FOR EACH ROW EXECUTE FUNCTION factory_measurements_refuse_change()
    """)

    execute("""
    CREATE TRIGGER factory_measurements_no_truncate
    BEFORE TRUNCATE ON factory_measurements
    FOR EACH STATEMENT EXECUTE FUNCTION factory_measurements_refuse_change()
    """)
  end

  def down do
    drop(table(:factory_measurements))
    execute("DROP FUNCTION factory_measurements_refuse_change()")
    drop(table(:factory_measurement_types))
  end
end
