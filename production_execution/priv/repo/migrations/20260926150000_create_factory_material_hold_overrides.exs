defmodule Bilimbi.Factory.ProductionExecution.Migrations.CreateMaterialHoldOverrides do
  use Ecto.Migration

  def up do
    create table(:factory_material_hold_overrides) do
      add(:company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false)

      add(:execution_id, references(:factory_operation_executions, on_delete: :restrict),
        null: false
      )

      add(
        :inventory_transaction_id,
        references(:factory_inventory_transactions, on_delete: :restrict),
        null: false
      )

      add(
        :source_transaction_id,
        references(:factory_inventory_transactions, on_delete: :restrict),
        null: false
      )

      add(
        :identity_id,
        references(:factory_inventory_identities, on_delete: :restrict),
        null: false
      )

      add(:item_id, references(:commerce_inventory_items, on_delete: :restrict), null: false)
      add(:actor_type, :string, null: false)
      add(:actor_id, :bigint, null: false)
      add(:acting_for_user_id, :bigint)
      add(:reason, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:factory_material_hold_overrides, [:execution_id, :identity_id]))

    create(
      constraint(:factory_material_hold_overrides, :factory_material_hold_overrides_reason,
        check: "length(btrim(reason)) > 0"
      )
    )

    execute("""
    CREATE FUNCTION factory_material_hold_overrides_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN
      RAISE EXCEPTION 'material hold overrides are immutable';
    END $$
    """)

    execute("""
    CREATE TRIGGER factory_material_hold_overrides_append_only
    BEFORE UPDATE OR DELETE ON factory_material_hold_overrides
    FOR EACH ROW EXECUTE FUNCTION factory_material_hold_overrides_refuse_change()
    """)

    execute("""
    CREATE TRIGGER factory_material_hold_overrides_no_truncate
    BEFORE TRUNCATE ON factory_material_hold_overrides
    FOR EACH STATEMENT EXECUTE FUNCTION factory_material_hold_overrides_refuse_change()
    """)
  end

  def down do
    drop(table(:factory_material_hold_overrides))
    execute("DROP FUNCTION factory_material_hold_overrides_refuse_change()")
  end
end
