defmodule Bilimbi.Factory.Inventory.Repo.Migrations.RetireFactoryMaterialTypes do
  use Ecto.Migration

  def change do
    alter table(:factory_inventory_material_types) do
      add(:retired_at, :naive_datetime)
    end
  end
end
