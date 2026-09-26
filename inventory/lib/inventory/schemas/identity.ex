defmodule Bilimbi.Factory.Inventory.Schemas.Identity do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_inventory_identities" do
    field :company_id, :id
    field :material_id, :id
    field :source_transaction_id, :id
    field :kind, :string
    field :code, :string
  end

  def creation_changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, [:company_id, :material_id, :source_transaction_id, :kind, :code])
    |> validate_required([:company_id, :material_id, :source_transaction_id, :kind, :code])
    |> validate_inclusion(:kind, ["lot", "unit"])
    |> unique_constraint([:company_id, :material_id, :code])
  end
end
