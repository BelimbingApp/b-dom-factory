defmodule Bilimbi.Factory.Inventory.Schemas.Entry do
  @moduledoc false

  # One effect of a Material Transaction. Append-only, like its transaction.

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "factory_inventory_transaction_entries" do
    field :company_id, :id
    field :transaction_id, :id
    field :role, :string
    field :material_id, :id
    field :identity_id, :id
    field :location_id, :id
    field :native_quantity, :decimal
    field :native_unit_id, :id
    field :recorded_quantity, :decimal
    field :recorded_unit_id, :id
    field :conversion_id, :id
    field :observation, :string
    field :output_role, :string
    field :evidence, :string
    field :reconciliation_basis, :string
  end
end
