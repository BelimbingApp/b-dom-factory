defmodule Bilimbi.Factory.Inventory.Schemas.Conversion do
  @moduledoc false

  # Append-only: a row is never updated. A changed factor is a new version.

  use Ecto.Schema

  @type t :: %__MODULE__{}

  import Ecto.Changeset

  schema "factory_inventory_unit_conversions" do
    field :company_id, :id
    field :material_id, :id
    field :unit_id, :id
    field :version, :integer
    field :factor, :decimal
    field :created_at, :naive_datetime
  end

  @spec creation_changeset(map(), map()) :: Ecto.Changeset.t()
  def creation_changeset(identity, attributes) do
    %__MODULE__{}
    |> cast(attributes, [:factor])
    |> change(identity)
    |> validate_required([:factor])
    |> validate_number(:factor, greater_than: 0)
    |> validate_change(:factor, &factor_fits/2)
    |> unique_constraint(:version,
      name: :factory_inventory_unit_conversions_material_unit_version_unique
    )
    |> check_constraint(:factor, name: :factory_inventory_unit_conversions_factor_positive)
  end

  # numeric(24, 12): at most 12 digits either side of the point.
  defp factor_fits(:factor, %Decimal{} = factor) do
    rounded = Decimal.round(factor, 12)

    cond do
      not Decimal.eq?(rounded, factor) -> [factor: "has more than 12 decimal places"]
      Decimal.compare(Decimal.abs(factor), Decimal.new("1E12")) != :lt -> [factor: "is too large"]
      true -> []
    end
  end
end
