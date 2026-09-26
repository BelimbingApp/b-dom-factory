defmodule Bilimbi.Factory.ProductionExecution.Migrations.CreateExecution do
  use Ecto.Migration

  def change do
    create table(:factory_production_orders) do
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false
      add :code, :string, null: false
      add :kind, :string, null: false
      add :product_id, references(:factory_products, on_delete: :restrict), null: false
      add :formula_version, :integer, null: false
      add :routing_version, :integer, null: false
      add :demand_ref, :string
      timestamps(type: :naive_datetime)
    end

    create unique_index(:factory_production_orders, [:company_id, :code])
    create constraint(:factory_production_orders, :factory_production_orders_kind,
             check: "kind IN ('order', 'batch')"
           )
    create constraint(:factory_production_orders, :factory_production_orders_versions,
             check: "formula_version > 0 AND routing_version > 0"
           )

    create table(:factory_operation_executions) do
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false
      add :order_id, references(:factory_production_orders, on_delete: :restrict), null: false
      add :request_id, :string, null: false
      add :request_fingerprint, :string, null: false
      add :source, :string, null: false
      add :operation_code, :string, null: false
      add :resource_id, references(:factory_resources, on_delete: :restrict), null: false
      add :operator_type, :string, null: false
      add :operator_id, :bigint, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec, null: false
      add :inputs, {:array, :map}, null: false
      add :outputs, {:array, :map}, null: false
      add :variance, :map
      add :evidence, :text, null: false
      add :inventory_transaction_id, :bigint, null: false
      add :formula_version, :integer, null: false
      add :routing_version, :integer, null: false
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create unique_index(:factory_operation_executions, [:company_id, :request_id])
    create constraint(:factory_operation_executions, :factory_operation_executions_time,
             check: "started_at <= completed_at"
           )
    create constraint(:factory_operation_executions, :factory_operation_executions_source,
             check: "source IN ('live', 'import')"
           )
  end
end
