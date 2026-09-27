defmodule Bilimbi.Factory.Inventory.Schemas.Material do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  import Ecto.Changeset

  schema "factory_inventory_materials" do
    field :company_id, :id
    field :item_id, :id
    field :native_unit_id, :id
    field :material_type_id, :id
    field :properties, :map, default: %{}
    timestamps(type: :naive_datetime, inserted_at: :created_at)
  end

  @doc """
  Takes property values already validated against the material type's
  definitions; the facade does that. A material without a type holds none.
  """
  @spec creation_changeset(
          pos_integer(),
          pos_integer(),
          pos_integer(),
          pos_integer() | nil,
          map()
        ) ::
          Ecto.Changeset.t()
  def creation_changeset(company_id, item_id, native_unit_id, material_type_id, properties) do
    %__MODULE__{}
    |> change(
      company_id: company_id,
      item_id: item_id,
      native_unit_id: native_unit_id,
      material_type_id: material_type_id,
      properties: properties
    )
    |> unique_constraint(:item_id, name: :factory_inventory_materials_item_id_unique)
    |> foreign_key_constraint(:material_type_id,
      name: :factory_inventory_materials_material_type_id_fkey
    )
    |> check_constraint(:properties, name: :factory_inventory_materials_properties_shape)
  end
end
