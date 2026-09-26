defmodule Bilimbi.Factory.Inventory.Schemas.Location do
  @moduledoc false

  use Ecto.Schema

  @type t :: %__MODULE__{}

  import Ecto.Changeset

  schema "factory_inventory_locations" do
    field :company_id, :id
    field :code, :string
    field :name, :string
    timestamps(type: :naive_datetime, inserted_at: :created_at)
  end

  @spec creation_changeset(pos_integer(), map()) :: Ecto.Changeset.t()
  def creation_changeset(company_id, attributes) do
    %__MODULE__{}
    |> cast(attributes, [:code, :name])
    |> put_change(:company_id, company_id)
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:code, :name])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:code, name: :factory_inventory_locations_company_id_code_unique)
  end
end
