defmodule Bilimbi.Factory.Inventory.Schemas.GenealogyLink do
  @moduledoc false

  # A transform's input entry linked to one of its output entries.
  # Append-only, like the transaction that records it.

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "factory_inventory_genealogy_links" do
    field :company_id, :id
    field :transaction_id, :id
    field :input_entry_id, :id
    field :output_entry_id, :id
  end
end
