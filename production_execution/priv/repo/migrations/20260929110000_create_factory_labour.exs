defmodule Bilimbi.Factory.ProductionExecution.Migrations.CreateLabour do
  @moduledoc """
  A company's labour roles and the time its users work on an order's runs.

  Which roles exist is the company's configuration: nothing here names one.
  A labour entry is append-only evidence with one exception: an open entry
  (clocked in, not yet out) may be closed once, by setting its stop time and
  who stopped it. Any other change is a correction: a new entry that names
  the one it corrects, corrected at most once.
  """

  use Ecto.Migration

  def up do
    create table(:factory_labour_roles) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)
      add(:code, :string, size: 64, null: false)
      add(:label, :string, null: false)
      add(:active, :boolean, null: false, default: true)
      timestamps(type: :naive_datetime)
    end

    create(
      unique_index(:factory_labour_roles, [:company_id, :code],
        name: :factory_labour_roles_company_id_code_unique
      )
    )

    create(
      unique_index(:factory_labour_roles, [:id, :company_id],
        name: :factory_labour_roles_id_company_id_unique
      )
    )

    create table(:factory_labour_entries) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)
      add(:request_id, :string, null: false)
      add(:request_fingerprint, :string, null: false)
      add(:order_id, references(:factory_production_orders, on_delete: :restrict), null: false)
      add(:execution_id, references(:factory_operation_executions, on_delete: :restrict))
      add(:worker_user_id, references(:users, type: :bigint, on_delete: :restrict), null: false)

      add(
        :role_id,
        references(:factory_labour_roles,
          on_delete: :restrict,
          with: [company_id: :company_id],
          name: :factory_labour_entries_role_id_fkey
        ),
        null: false
      )

      add(:started_at, :utc_datetime_usec, null: false)
      add(:stopped_at, :utc_datetime_usec)
      add(:note, :text)
      add(:recorded_by_type, :string, null: false)
      add(:recorded_by_id, :bigint, null: false)
      add(:recorded_by_acting_for_user_id, :bigint)
      add(:stopped_by_type, :string)
      add(:stopped_by_id, :bigint)
      add(:stopped_by_acting_for_user_id, :bigint)
      add(:corrects_id, references(:factory_labour_entries, on_delete: :restrict))
      add(:correction_reason, :text)
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create(unique_index(:factory_labour_entries, [:company_id, :request_id]))
    create(unique_index(:factory_labour_entries, [:corrects_id]))
    create(index(:factory_labour_entries, [:order_id]))
    create(index(:factory_labour_entries, [:company_id, :worker_user_id]))

    create(
      constraint(:factory_labour_entries, :factory_labour_entries_times,
        check:
          "(stopped_at IS NULL AND stopped_by_type IS NULL AND stopped_by_id IS NULL) OR " <>
            "(stopped_at >= started_at AND stopped_by_type IS NOT NULL AND stopped_by_id IS NOT NULL)"
      )
    )

    create(
      constraint(:factory_labour_entries, :factory_labour_entries_correction,
        check:
          "(corrects_id IS NULL AND correction_reason IS NULL) OR " <>
            "(corrects_id IS NOT NULL AND length(btrim(correction_reason)) > 0)"
      )
    )

    # Only closing an open entry is an update: its stop time and stopper are
    # set once and nothing else changes.
    execute("""
    CREATE FUNCTION factory_labour_entries_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN
      IF TG_OP = 'UPDATE' THEN
        IF OLD.stopped_at IS NULL AND NEW.stopped_at IS NOT NULL
          AND (to_jsonb(NEW) - 'stopped_at' - 'stopped_by_type' - 'stopped_by_id'
               - 'stopped_by_acting_for_user_id')
            = (to_jsonb(OLD) - 'stopped_at' - 'stopped_by_type' - 'stopped_by_id'
               - 'stopped_by_acting_for_user_id') THEN
          RETURN NEW;
        END IF;
      END IF;
      RAISE EXCEPTION 'labour entries are immutable once closed; record a correction';
    END $$
    """)

    execute("""
    CREATE TRIGGER factory_labour_entries_append_only
    BEFORE UPDATE OR DELETE ON factory_labour_entries
    FOR EACH ROW EXECUTE FUNCTION factory_labour_entries_refuse_change()
    """)

    execute("""
    CREATE TRIGGER factory_labour_entries_no_truncate
    BEFORE TRUNCATE ON factory_labour_entries
    FOR EACH STATEMENT EXECUTE FUNCTION factory_labour_entries_refuse_change()
    """)
  end

  def down do
    drop(table(:factory_labour_entries))
    execute("DROP FUNCTION factory_labour_entries_refuse_change()")
    drop(table(:factory_labour_roles))
  end
end
