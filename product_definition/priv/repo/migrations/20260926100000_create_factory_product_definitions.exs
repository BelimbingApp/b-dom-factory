defmodule Bilimbi.Factory.ProductDefinition.Migrations.CreateDefinitions do
  use Ecto.Migration

  def change do
    create table(:factory_products) do
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false
      add :item_id, references(:commerce_inventory_items, type: :bigint, on_delete: :restrict), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      timestamps(type: :naive_datetime)
    end
    create unique_index(:factory_products, [:company_id, :code], name: :factory_products_company_code_unique)
    create unique_index(:factory_products, [:company_id, :item_id], name: :factory_products_company_item_unique)

    create table(:factory_resources) do
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      add :kind, :string, null: false
      timestamps(type: :naive_datetime)
    end
    create unique_index(:factory_resources, [:company_id, :code], name: :factory_resources_company_code_unique)
    create constraint(:factory_resources, :factory_resources_kind_check,
      check: "kind IN ('work_centre', 'machine', 'line', 'station')")

    create table(:factory_formula_revisions) do
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false
      add :product_id, references(:factory_products, on_delete: :restrict), null: false
      add :version, :integer, null: false
      add :lines, {:array, :map}, null: false
      add :process_config, :map, null: false
      timestamps(type: :naive_datetime, updated_at: false)
    end
    create unique_index(:factory_formula_revisions, [:product_id, :version], name: :factory_formula_revisions_product_version_unique)
    create constraint(:factory_formula_revisions, :factory_formula_revisions_version_positive, check: "version > 0")

    create table(:factory_routing_revisions) do
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false
      add :product_id, references(:factory_products, on_delete: :restrict), null: false
      add :version, :integer, null: false
      add :operations, {:array, :map}, null: false
      add :process_config, :map, null: false
      timestamps(type: :naive_datetime, updated_at: false)
    end
    create unique_index(:factory_routing_revisions, [:product_id, :version], name: :factory_routing_revisions_product_version_unique)
    create constraint(:factory_routing_revisions, :factory_routing_revisions_version_positive, check: "version > 0")
  end
end
