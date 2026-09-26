defmodule Bilimbi.Factory.Inventory.Repo.Migrations.AddFactoryIdentityDimensions do
  use Ecto.Migration

  def change do
    alter table(:factory_inventory_identities) do
      add :dimensions, :map, null: false, default: %{}
    end

    create constraint(:factory_inventory_identities, :factory_inventory_identity_dimensions_shape,
             check:
               "jsonb_typeof(dimensions) = 'object' AND (kind = 'unit' OR dimensions = '{}'::jsonb) AND dimensions - 'width' - 'length' - 'thickness' = '{}'::jsonb"
           )
  end
end
