defmodule Bilimbi.Factory.Inventory.Migrations.CreateItemMasterBaseline do
  @moduledoc """
  Belimbing's item master, `commerce_inventory_items`, as the pinned Belimbing
  schema holds it. Adoption verifies an existing table and records this version
  without running it.

  The unique `(company_id, sku)` pair is a constraint in Belimbing; the
  verifier compares it as the index that backs it, as Core Company's baseline
  does.
  """

  use Ecto.Migration

  def up do
    create table(:commerce_inventory_items, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :company_id,
          references(:companies,
            type: :bigint,
            on_delete: :nothing,
            name: :commerce_inventory_items_company_id_foreign
          ),
          null: false

      add :category_id, :bigint
      add :product_template_id, :bigint
      add :sku, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :title, :string, null: false
      add :description, :text
      add :quantity_on_hand, :integer, null: false, default: 1
      add :storage_location, :string
      add :notes, :text
      add :unit_cost_amount, :bigint
      add :target_price_amount, :bigint
      add :currency_code, :char, size: 3, null: false, default: "MYR"
      timestamps(type: :naive_datetime, null: true, inserted_at: :created_at)
    end

    create index(:commerce_inventory_items, [:company_id])
    create index(:commerce_inventory_items, [:status])
    create index(:commerce_inventory_items, [:company_id, :category_id])
    create index(:commerce_inventory_items, [:company_id, :product_template_id])
    create index(:commerce_inventory_items, [:company_id, :status])
    create index(:commerce_inventory_items, [:company_id, :created_at])

    create unique_index(:commerce_inventory_items, [:company_id, :sku],
             name: :commerce_inventory_items_company_id_sku_unique
           )
  end

  def down do
    drop table(:commerce_inventory_items)
  end
end
