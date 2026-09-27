defmodule Bilimbi.Factory.Inventory.Migrations.AddMaterialTypes do
  @moduledoc """
  Company-defined material types with property definitions, and the type and
  validated property values a material may hold.

  A material type is that company's configuration: nothing here names one.
  The composite reference keeps a material's type inside its own company. A
  material without a type holds no properties.
  """

  use Ecto.Migration

  def up do
    create table(:factory_inventory_material_types, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :company_id,
          references(:companies,
            type: :bigint,
            on_delete: :restrict,
            name: :factory_inventory_material_types_company_id_foreign
          ),
          null: false

      add :code, :string, size: 64, null: false
      add :name, :string, null: false
      add :property_definitions, {:array, :map}, null: false
      timestamps(type: :naive_datetime, inserted_at: :created_at)
    end

    create unique_index(:factory_inventory_material_types, [:company_id, :code],
             name: :factory_inventory_material_types_company_id_code_unique
           )

    create unique_index(:factory_inventory_material_types, [:id, :company_id],
             name: :factory_inventory_material_types_id_company_id_unique
           )

    alter table(:factory_inventory_materials) do
      add :material_type_id,
          references(:factory_inventory_material_types,
            type: :bigint,
            on_delete: :restrict,
            with: [company_id: :company_id],
            name: :factory_inventory_materials_material_type_id_fkey
          )

      add :properties, :map, null: false, default: %{}
    end

    create index(:factory_inventory_materials, [:material_type_id])

    create constraint(:factory_inventory_materials, :factory_inventory_materials_properties_shape,
             check:
               "jsonb_typeof(properties) = 'object' AND (material_type_id IS NOT NULL OR properties = '{}'::jsonb)"
           )
  end

  def down do
    drop constraint(:factory_inventory_materials, :factory_inventory_materials_properties_shape)

    alter table(:factory_inventory_materials) do
      remove :properties
      remove :material_type_id
    end

    drop table(:factory_inventory_material_types)
  end
end
