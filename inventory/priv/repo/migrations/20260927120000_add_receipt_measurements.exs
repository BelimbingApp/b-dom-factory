defmodule Bilimbi.Factory.Inventory.Migrations.AddReceiptMeasurements do
  @moduledoc "Adds optional typed weigh-ticket evidence to receipts."

  use Ecto.Migration

  def change do
    alter table(:factory_inventory_transactions) do
      add(:receipt_measurement, :map)
    end
  end
end
