defmodule Bilimbi.Factory.Inventory.Schemas.Item do
  @moduledoc false

  # Belimbing's item master (`commerce_inventory_items`). Column names, types,
  # and defaults follow the adopted table; see the baseline migration.

  use Ecto.Schema

  @type t :: %__MODULE__{}

  import Ecto.Changeset

  @statuses ~w(draft ready listed sold archived)

  schema "commerce_inventory_items" do
    field :company_id, :id
    field :category_id, :id
    field :product_template_id, :id
    field :sku, :string
    field :status, :string, default: "draft"
    field :title, :string
    field :description, :string
    field :quantity_on_hand, :integer, default: 1
    field :storage_location, :string
    field :notes, :string
    field :unit_cost_amount, :integer
    field :target_price_amount, :integer
    field :currency_code, :string, default: "MYR"
    timestamps(type: :naive_datetime, inserted_at: :created_at)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Belimbing's create rules: SKU and currency are upper-cased, a blank storage
  location is stored as null, and the quantity defaults to one.
  """
  @spec creation_changeset(pos_integer(), map()) :: Ecto.Changeset.t()
  def creation_changeset(company_id, attributes) do
    %__MODULE__{}
    |> cast(attributes, [
      :sku,
      :status,
      :title,
      :description,
      :quantity_on_hand,
      :storage_location,
      :notes,
      :unit_cost_amount,
      :target_price_amount,
      :currency_code
    ])
    |> put_change(:company_id, company_id)
    |> update_change(:sku, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:currency_code, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:storage_location, &String.trim/1)
    |> validate_required([:sku, :status, :title, :quantity_on_hand, :currency_code])
    |> validate_length(:sku, max: 64)
    |> validate_length(:title, max: 255)
    |> validate_length(:notes, max: 5000)
    |> validate_length(:storage_location, max: 255)
    |> validate_length(:currency_code, is: 3)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:quantity_on_hand,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 999_999
    )
    |> validate_number(:unit_cost_amount, greater_than_or_equal_to: 0)
    |> validate_number(:target_price_amount, greater_than_or_equal_to: 0)
    |> unique_constraint(:sku, name: :commerce_inventory_items_company_id_sku_unique)
  end
end
