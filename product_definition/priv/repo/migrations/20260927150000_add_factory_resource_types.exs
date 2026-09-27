defmodule Bilimbi.Factory.ProductDefinition.Migrations.AddResourceTypes do
  @moduledoc """
  Company-defined resource types with property definitions, replacing the
  fixed resource `kind` vocabulary.

  Every `kind` a company's resources used becomes one of that company's
  resource types, with no property definitions, and each resource is moved
  to its type; the vocabulary is data from here on and nothing in code names
  it. The composite reference keeps a resource's type inside its own company.
  """

  use Ecto.Migration

  def up do
    create table(:factory_resource_types) do
      add :company_id, references(:companies, type: :bigint, on_delete: :restrict), null: false
      add :code, :string, size: 64, null: false
      add :name, :string, null: false
      add :property_definitions, {:array, :map}, null: false
      timestamps(type: :naive_datetime)
    end

    create unique_index(:factory_resource_types, [:company_id, :code],
             name: :factory_resource_types_company_code_unique
           )

    create unique_index(:factory_resource_types, [:id, :company_id],
             name: :factory_resource_types_id_company_unique
           )

    execute """
    INSERT INTO factory_resource_types
      (company_id, code, name, property_definitions, inserted_at, updated_at)
    SELECT DISTINCT company_id, upper(kind), initcap(replace(kind, '_', ' ')),
      ARRAY[]::jsonb[], now(), now()
    FROM factory_resources
    """

    alter table(:factory_resources) do
      add :resource_type_id,
          references(:factory_resource_types,
            type: :bigint,
            on_delete: :restrict,
            with: [company_id: :company_id],
            name: :factory_resources_resource_type_id_fkey
          )

      add :properties, :map, null: false, default: %{}
    end

    execute """
    UPDATE factory_resources AS resource
    SET resource_type_id = type.id
    FROM factory_resource_types AS type
    WHERE type.company_id = resource.company_id AND type.code = upper(resource.kind)
    """

    alter table(:factory_resources) do
      modify :resource_type_id, :bigint, null: false
    end

    drop constraint(:factory_resources, :factory_resources_kind_check)

    alter table(:factory_resources) do
      remove :kind
    end

    create index(:factory_resources, [:resource_type_id])

    create constraint(:factory_resources, :factory_resources_properties_shape,
             check: "jsonb_typeof(properties) = 'object'"
           )
  end

  def down do
    alter table(:factory_resources) do
      add :kind, :string
    end

    execute """
    UPDATE factory_resources AS resource
    SET kind = lower(type.code)
    FROM factory_resource_types AS type
    WHERE type.id = resource.resource_type_id
    """

    alter table(:factory_resources) do
      modify :kind, :string, null: false
      remove :properties
      remove :resource_type_id
    end

    create constraint(:factory_resources, :factory_resources_kind_check,
             check: "kind IN ('work_centre', 'machine', 'line', 'station')"
           )

    drop table(:factory_resource_types)
  end
end
