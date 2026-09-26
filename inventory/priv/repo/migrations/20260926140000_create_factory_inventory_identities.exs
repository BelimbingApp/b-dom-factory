defmodule Bilimbi.Factory.Inventory.Migrations.CreateIdentities do
  use Ecto.Migration

  def up do
    create table(:factory_inventory_identities, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false

      add :material_id,
          references(:factory_inventory_materials, type: :bigint, on_delete: :restrict),
          null: false

      add :source_transaction_id,
          references(:factory_inventory_transactions, type: :bigint, on_delete: :restrict),
          null: false

      add :kind, :string, size: 8, null: false
      add :code, :string, size: 255, null: false
    end

    create unique_index(:factory_inventory_identities, [:company_id, :material_id, :code])

    create constraint(:factory_inventory_identities, :factory_inventory_identities_kind,
             check: "kind IN ('lot', 'unit')"
           )

    alter table(:factory_inventory_transaction_entries) do
      add :identity_id,
          references(:factory_inventory_identities, type: :bigint, on_delete: :restrict)
    end

    create index(:factory_inventory_transaction_entries, [:company_id, :identity_id],
             where: "identity_id IS NOT NULL"
           )

    create constraint(
             :factory_inventory_transaction_entries,
             :factory_inventory_transaction_entries_identity_stock,
             check: "identity_id IS NULL OR role = 'stock'"
           )

    execute("""
    CREATE FUNCTION factory_inventory_check_identity_entry() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.identity_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM factory_inventory_identities identity
        WHERE identity.id = NEW.identity_id
          AND identity.company_id = NEW.company_id
          AND identity.material_id = NEW.material_id
      ) THEN
        RAISE EXCEPTION 'identity does not belong to the stock entry material and company'
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER factory_inventory_transaction_entries_identity
      BEFORE INSERT ON factory_inventory_transaction_entries
      FOR EACH ROW EXECUTE FUNCTION factory_inventory_check_identity_entry()
    """)

    execute("""
    CREATE TRIGGER factory_inventory_identities_append_only
      BEFORE UPDATE OR DELETE ON factory_inventory_identities
      FOR EACH ROW EXECUTE FUNCTION factory_inventory_ledger_refuse_change()
    """)

    execute("""
    CREATE TRIGGER factory_inventory_identities_no_truncate
      BEFORE TRUNCATE ON factory_inventory_identities
      FOR EACH STATEMENT EXECUTE FUNCTION factory_inventory_ledger_refuse_change()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER factory_inventory_transaction_entries_identity ON factory_inventory_transaction_entries"
    )

    execute("DROP FUNCTION factory_inventory_check_identity_entry()")
    alter table(:factory_inventory_transaction_entries), do: remove(:identity_id)
    drop table(:factory_inventory_identities)
  end
end
