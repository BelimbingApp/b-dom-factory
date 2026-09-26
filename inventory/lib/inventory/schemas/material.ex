defmodule Bilimbi.Factory.Inventory.Schemas.Material do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  import Ecto.Changeset

  schema "factory_inventory_materials" do
    field :company_id, :id
    field :item_id, :id
    field :native_unit_id, :id
    timestamps(type: :naive_datetime, inserted_at: :created_at)
  end

  @spec creation_changeset(pos_integer(), pos_integer(), pos_integer()) :: Ecto.Changeset.t()
  def creation_changeset(company_id, item_id, native_unit_id) do
    %__MODULE__{}
    |> change(company_id: company_id, item_id: item_id, native_unit_id: native_unit_id)
    |> unique_constraint(:item_id, name: :factory_inventory_materials_item_id_unique)
  end
end
