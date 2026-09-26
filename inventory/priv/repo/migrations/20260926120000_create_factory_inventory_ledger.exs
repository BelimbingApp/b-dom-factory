defmodule Bilimbi.Factory.Inventory.Migrations.CreateLedger do
  @moduledoc """
  The Material Transaction ledger: transactions, their entries, and the
  input-to-output links each transform records for Lot/Unit Genealogy.

  Bilimbi-only. Every row belongs to one company and is append-only: a
  trigger refuses UPDATE, DELETE, and TRUNCATE, so a correction is always a
  new transaction. A deferred constraint trigger refuses a commit in which a
  transaction's entries do not sum to zero per native unit, or a transaction
  has no entries.
  """

  use Ecto.Migration

  def up do
    create table(:factory_inventory_transactions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, company_reference(:factory_inventory_transactions), null: false
      add :kind, :string, size: 32, null: false
      add :request_id, :string, null: false
      add :request_fingerprint, :string, size: 64, null: false
      add :actor_type, :string, size: 64, null: false
      add :actor_id, :bigint, null: false
      add :evidence, :text, null: false
      add :reason, :text

      add :corrects_transaction_id,
          references(:factory_inventory_transactions,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_transactions_corrects_transaction_id_foreign
          )

      add :posting_authority, :string
      add :operation_execution_ref, :string
      add :order_or_batch_ref, :string
      add :work_centre_ref, :string
      add :shipment_ref, :string
      add :destination_ref, :string
      add :effective_at, :utc_datetime_usec, null: false
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create unique_index(:factory_inventory_transactions, [:company_id, :request_id],
             name: :factory_inventory_transactions_company_id_request_id_unique
           )

    create index(:factory_inventory_transactions, [:company_id, :recorded_at])
    create index(:factory_inventory_transactions, [:corrects_transaction_id])

    create constraint(:factory_inventory_transactions, :factory_inventory_transactions_kind,
             check:
               "kind IN ('receipt', 'transfer', 'consumption', 'output', 'correction', 'transform')"
           )

    create constraint(
             :factory_inventory_transactions,
             :factory_inventory_transactions_correction_reference,
             check:
               "(kind = 'correction') = (corrects_transaction_id IS NOT NULL AND reason IS NOT NULL)"
           )

    create constraint(
             :factory_inventory_transactions,
             :factory_inventory_transactions_late_entry,
             check: "effective_at <= recorded_at"
           )

    create table(:factory_inventory_transaction_entries, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, company_reference(:factory_inventory_transaction_entries), null: false

      add :transaction_id,
          references(:factory_inventory_transactions,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_transaction_entries_transaction_id_foreign
          ),
          null: false

      add :role, :string, size: 16, null: false

      add :material_id,
          references(:factory_inventory_materials,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_transaction_entries_material_id_foreign
          )

      add :location_id,
          references(:factory_inventory_locations,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_transaction_entries_location_id_foreign
          )

      add :native_quantity, :decimal, precision: 36, scale: 12, null: false

      add :native_unit_id,
          references(:factory_inventory_units,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_transaction_entries_native_unit_id_foreign
          ),
          null: false

      add :recorded_quantity, :decimal, precision: 24, scale: 12

      add :recorded_unit_id,
          references(:factory_inventory_units,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_transaction_entries_recorded_unit_id_foreign
          )

      add :conversion_id,
          references(:factory_inventory_unit_conversions,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_transaction_entries_conversion_id_foreign
          )

      add :observation, :string, size: 16
      add :output_role, :string, size: 64
      add :evidence, :text
      add :reconciliation_basis, :text
    end

    create index(:factory_inventory_transaction_entries, [:transaction_id])

    create index(:factory_inventory_transaction_entries, [:material_id, :location_id],
             where: "location_id IS NOT NULL",
             name: :factory_inventory_transaction_entries_stock_index
           )

    create constraint(
             :factory_inventory_transaction_entries,
             :factory_inventory_transaction_entries_role,
             check: "role IN ('stock', 'boundary', 'variance')"
           )

    # A stock entry is an observation at a location; a boundary entry is its
    # counterpart outside stock; a variance is the provenance-backed
    # difference a transform could not account for.
    create constraint(
             :factory_inventory_transaction_entries,
             :factory_inventory_transaction_entries_role_shape,
             check: """
             CASE role
               WHEN 'stock' THEN material_id IS NOT NULL AND location_id IS NOT NULL
                 AND recorded_quantity IS NOT NULL AND recorded_unit_id IS NOT NULL
                 AND observation IS NOT NULL AND reconciliation_basis IS NULL
               WHEN 'boundary' THEN material_id IS NOT NULL AND location_id IS NULL
                 AND recorded_quantity IS NULL AND observation IS NULL
                 AND reconciliation_basis IS NULL
               WHEN 'variance' THEN material_id IS NULL AND location_id IS NULL
                 AND recorded_quantity IS NULL AND observation IS NULL
                 AND evidence IS NOT NULL AND reconciliation_basis IS NOT NULL
             END
             """
           )

    create constraint(
             :factory_inventory_transaction_entries,
             :factory_inventory_transaction_entries_observation,
             check: "observation IN ('measured', 'declared', 'counted', 'derived')"
           )

    create constraint(
             :factory_inventory_transaction_entries,
             :factory_inventory_transaction_entries_quantities,
             check:
               "native_quantity <> 0 AND (recorded_quantity IS NULL OR recorded_quantity > 0)"
           )

    create table(:factory_inventory_genealogy_links, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, company_reference(:factory_inventory_genealogy_links), null: false

      add :transaction_id,
          references(:factory_inventory_transactions,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_genealogy_links_transaction_id_foreign
          ),
          null: false

      add :input_entry_id,
          references(:factory_inventory_transaction_entries,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_genealogy_links_input_entry_id_foreign
          ),
          null: false

      add :output_entry_id,
          references(:factory_inventory_transaction_entries,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_genealogy_links_output_entry_id_foreign
          ),
          null: false
    end

    create unique_index(
             :factory_inventory_genealogy_links,
             [:input_entry_id, :output_entry_id],
             name: :factory_inventory_genealogy_links_input_output_unique
           )

    create index(:factory_inventory_genealogy_links, [:output_entry_id])
    create index(:factory_inventory_genealogy_links, [:transaction_id])

    execute("""
    CREATE FUNCTION factory_inventory_ledger_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'the Material Transaction ledger is append-only: % on % is refused',
        TG_OP, TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
    END
    $$
    """)

    for table <- [
          :factory_inventory_transactions,
          :factory_inventory_transaction_entries,
          :factory_inventory_genealogy_links
        ] do
      execute("""
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION factory_inventory_ledger_refuse_change()
      """)

      execute("""
      CREATE TRIGGER #{table}_no_truncate
        BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION factory_inventory_ledger_refuse_change()
      """)
    end

    execute("""
    CREATE FUNCTION factory_inventory_ledger_check_balance() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      checked_id bigint;
    BEGIN
      IF TG_TABLE_NAME = 'factory_inventory_transactions' THEN
        checked_id := NEW.id;
      ELSE
        checked_id := NEW.transaction_id;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM factory_inventory_transaction_entries WHERE transaction_id = checked_id
      ) THEN
        RAISE EXCEPTION 'material transaction % has no entries', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1 FROM factory_inventory_transaction_entries
        WHERE transaction_id = checked_id
        GROUP BY native_unit_id
        HAVING sum(native_quantity) <> 0
      ) THEN
        RAISE EXCEPTION 'material transaction % does not balance', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NULL;
    END
    $$
    """)

    for table <- [:factory_inventory_transactions, :factory_inventory_transaction_entries] do
      execute("""
      CREATE CONSTRAINT TRIGGER #{table}_balanced
        AFTER INSERT ON #{table}
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION factory_inventory_ledger_check_balance()
      """)
    end
  end

  def down do
    drop table(:factory_inventory_genealogy_links)
    drop table(:factory_inventory_transaction_entries)
    drop table(:factory_inventory_transactions)
    execute("DROP FUNCTION factory_inventory_ledger_check_balance()")
    execute("DROP FUNCTION factory_inventory_ledger_refuse_change()")
  end

  defp company_reference(table) do
    references(:companies,
      type: :bigint,
      on_delete: :restrict,
      name: :"#{table}_company_id_foreign"
    )
  end
end
