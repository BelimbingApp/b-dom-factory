defmodule Bilimbi.Factory.ProductionExecution.Migrations.CreateWastage do
  @moduledoc """
  A company's wastage reasons and the wastage recorded against a run.

  Which reasons exist is the company's configuration: nothing here names one.
  A wastage record is append-only evidence. A correction is a new record that
  names the one it corrects, with its own reason; a record is corrected at
  most once, so its corrections form one chain.
  """

  use Ecto.Migration

  def up do
    create table(:factory_wastage_reasons) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)
      add(:code, :string, size: 64, null: false)
      add(:label, :string, null: false)
      add(:active, :boolean, null: false, default: true)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:factory_wastage_reasons, [:company_id, :code],
        name: :factory_wastage_reasons_company_id_code_unique
      )
    )

    create(
      unique_index(:factory_wastage_reasons, [:id, :company_id],
        name: :factory_wastage_reasons_id_company_id_unique
      )
    )

    create table(:factory_wastage_records) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)
      add(:request_id, :string, null: false)
      add(:request_fingerprint, :string, null: false)
      add(:order_id, references(:factory_production_orders, on_delete: :restrict), null: false)

      add(:execution_id, references(:factory_operation_executions, on_delete: :restrict),
        null: false
      )

      add(
        :reason_id,
        references(:factory_wastage_reasons,
          on_delete: :restrict,
          with: [company_id: :company_id],
          name: :factory_wastage_records_reason_id_fkey
        ),
        null: false
      )

      add(:item_id, references(:commerce_inventory_items, on_delete: :restrict), null: false)

      add(:location_id, references(:factory_inventory_locations, on_delete: :restrict),
        null: false
      )

      add(:identity_id, references(:factory_inventory_identities, on_delete: :restrict))
      add(:quantity, :decimal, precision: 24, scale: 12, null: false)
      add(:unit_id, references(:factory_inventory_units, on_delete: :restrict), null: false)
      add(:observation, :string, null: false)
      add(:note, :text)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:recorded_by_type, :string, null: false)
      add(:recorded_by_id, :bigint, null: false)
      add(:recorded_by_acting_for_user_id, :bigint)

      add(
        :inventory_transaction_id,
        references(:factory_inventory_transactions, on_delete: :restrict)
      )

      add(:corrects_id, references(:factory_wastage_records, on_delete: :restrict))
      add(:correction_reason, :text)
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create(unique_index(:factory_wastage_records, [:company_id, :request_id]))
    create(unique_index(:factory_wastage_records, [:corrects_id]))
    create(index(:factory_wastage_records, [:execution_id]))

    create(
      constraint(:factory_wastage_records, :factory_wastage_records_correction,
        check:
          "(corrects_id IS NULL AND quantity > 0 AND inventory_transaction_id IS NOT NULL " <>
            "AND correction_reason IS NULL) OR " <>
            "(corrects_id IS NOT NULL AND quantity >= 0 AND length(btrim(correction_reason)) > 0)"
      )
    )

    execute("""
    CREATE FUNCTION factory_wastage_records_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN
      RAISE EXCEPTION 'wastage records are immutable; record a correction';
    END $$
    """)

    execute("""
    CREATE TRIGGER factory_wastage_records_append_only
    BEFORE UPDATE OR DELETE ON factory_wastage_records
    FOR EACH ROW EXECUTE FUNCTION factory_wastage_records_refuse_change()
    """)

    execute("""
    CREATE TRIGGER factory_wastage_records_no_truncate
    BEFORE TRUNCATE ON factory_wastage_records
    FOR EACH STATEMENT EXECUTE FUNCTION factory_wastage_records_refuse_change()
    """)
  end

  def down do
    drop(table(:factory_wastage_records))
    execute("DROP FUNCTION factory_wastage_records_refuse_change()")
    drop(table(:factory_wastage_reasons))
  end
end
