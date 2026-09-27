defmodule Bilimbi.Factory.Inventory.Schemas.MaterialType do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  import Ecto.Changeset

  schema "factory_inventory_material_types" do
    field(:company_id, :id)
    field(:code, :string)
    field(:name, :string)
    field(:property_definitions, {:array, :map}, default: [])
    field(:retired_at, :naive_datetime)
    timestamps(type: :naive_datetime, inserted_at: :created_at)
  end

  @doc "Takes already normalized property definitions; the facade validates them."
  @spec creation_changeset(pos_integer(), map(), [map()]) :: Ecto.Changeset.t()
  def creation_changeset(company_id, attributes, property_definitions) do
    %__MODULE__{}
    |> cast(attributes, [:code, :name])
    |> put_change(:company_id, company_id)
    |> put_change(:property_definitions, property_definitions)
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:code, :name])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:code, name: :factory_inventory_material_types_company_id_code_unique)
  end

  def update_changeset(type, attributes, property_definitions) do
    type
    |> cast(attributes, [:code, :name])
    |> put_change(:property_definitions, property_definitions)
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:code, :name])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:code, name: :factory_inventory_material_types_company_id_code_unique)
  end
end
