defmodule Bilimbi.Factory.Inventory.Repo.Migrations.RetireFactoryUnits do
  use Ecto.Migration

  def change do
    alter table(:factory_inventory_units) do
      add(:retired_at, :naive_datetime)
    end
  end
end
