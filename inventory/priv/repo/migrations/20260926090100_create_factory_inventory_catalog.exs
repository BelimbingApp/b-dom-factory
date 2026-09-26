defmodule Bilimbi.Factory.Inventory.Migrations.CreateCatalog do
  @moduledoc """
  Units of measure, stock locations, material identity, and versioned
  item-level unit conversions.

  These tables are Bilimbi-only: Belimbing's item master keeps one
  location-less `quantity_on_hand` and a free-text `storage_location`, and has
  no units. Every row belongs to one company. A material names the item master
  row it stocks and that item's native unit; a conversion row is immutable,
  and a changed factor is a new version.
  """

  use Ecto.Migration

  def up do
    create table(:factory_inventory_units, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, company_reference(:factory_inventory_units), null: false
      add :code, :string, size: 32, null: false
      add :name, :string, null: false
      timestamps(type: :naive_datetime, inserted_at: :created_at)
    end

    create unique_index(:factory_inventory_units, [:company_id, :code],
             name: :factory_inventory_units_company_id_code_unique
           )

    create table(:factory_inventory_locations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, company_reference(:factory_inventory_locations), null: false
      add :code, :string, size: 64, null: false
      add :name, :string, null: false
      timestamps(type: :naive_datetime, inserted_at: :created_at)
    end

    create unique_index(:factory_inventory_locations, [:company_id, :code],
             name: :factory_inventory_locations_company_id_code_unique
           )

    create table(:factory_inventory_materials, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, company_reference(:factory_inventory_materials), null: false

      add :item_id,
          references(:commerce_inventory_items,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_materials_item_id_foreign
          ),
          null: false

      add :native_unit_id,
          references(:factory_inventory_units,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_materials_native_unit_id_foreign
          ),
          null: false

      timestamps(type: :naive_datetime, inserted_at: :created_at)
    end

    create unique_index(:factory_inventory_materials, [:item_id],
             name: :factory_inventory_materials_item_id_unique
           )

    create index(:factory_inventory_materials, [:company_id])

    create table(:factory_inventory_unit_conversions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :company_id, company_reference(:factory_inventory_unit_conversions), null: false

      add :material_id,
          references(:factory_inventory_materials,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_unit_conversions_material_id_foreign
          ),
          null: false

      add :unit_id,
          references(:factory_inventory_units,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_unit_conversions_unit_id_foreign
          ),
          null: false

      add :version, :integer, null: false
      add :factor, :decimal, precision: 24, scale: 12, null: false
      add :created_at, :naive_datetime, null: false
    end

    create unique_index(
             :factory_inventory_unit_conversions,
             [:material_id, :unit_id, :version],
             name: :factory_inventory_unit_conversions_material_unit_version_unique
           )

    create constraint(
             :factory_inventory_unit_conversions,
             :factory_inventory_unit_conversions_factor_positive,
             check: "factor > 0"
           )

    create constraint(
             :factory_inventory_unit_conversions,
             :factory_inventory_unit_conversions_version_positive,
             check: "version > 0"
           )
  end

  def down do
    drop table(:factory_inventory_unit_conversions)
    drop table(:factory_inventory_materials)
    drop table(:factory_inventory_locations)
    drop table(:factory_inventory_units)
  end

  defp company_reference(table) do
    references(:companies,
      type: :bigint,
      on_delete: :restrict,
      name: :"#{table}_company_id_foreign"
    )
  end
end
