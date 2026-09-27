defmodule Bilimbi.Factory.ProductDefinition.Repo.Migrations.RetireFactoryResources do
  use Ecto.Migration

  def change do
    alter table(:factory_resource_types) do
      add :retired_at, :naive_datetime
    end

    alter table(:factory_resources) do
      add :retired_at, :naive_datetime
    end
  end
end
