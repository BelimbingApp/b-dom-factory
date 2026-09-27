defmodule Bilimbi.Factory.Inventory.Repo.Migrations.RetireFactoryMaterials do
  use Ecto.Migration

  def change do
    alter table(:factory_inventory_materials) do
      add(:retired_at, :naive_datetime)
    end
  end
end
