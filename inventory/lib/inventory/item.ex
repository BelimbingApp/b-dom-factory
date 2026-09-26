defmodule Bilimbi.Factory.Inventory.Item do
  @moduledoc """
  Read model for one item master row.

  The fields are Belimbing's item master contract. `category_id` and
  `product_template_id` are opaque references to a catalog Inventory does not
  own. `quantity_on_hand` and `storage_location` are the item master's own
  location-less values; per-location stock is read through
  `Bilimbi.Factory.Inventory.get_stock_position/4`. Money amounts are minor
  units of `currency_code`.
  """

  @enforce_keys [:id, :company_id, :sku, :status, :title, :quantity_on_hand, :currency_code]
  defstruct [
    :id,
    :company_id,
    :category_id,
    :product_template_id,
    :sku,
    :status,
    :title,
    :description,
    :quantity_on_hand,
    :storage_location,
    :notes,
    :unit_cost_amount,
    :target_price_amount,
    :currency_code,
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          company_id: pos_integer(),
          category_id: pos_integer() | nil,
          product_template_id: pos_integer() | nil,
          sku: String.t(),
          status: String.t(),
          title: String.t(),
          description: String.t() | nil,
          quantity_on_hand: non_neg_integer(),
          storage_location: String.t() | nil,
          notes: String.t() | nil,
          unit_cost_amount: non_neg_integer() | nil,
          target_price_amount: non_neg_integer() | nil,
          currency_code: String.t(),
          created_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc false
  @spec from_schema(Bilimbi.Factory.Inventory.Schemas.Item.t()) :: t()
  def from_schema(item) do
    %__MODULE__{
      id: item.id,
      company_id: item.company_id,
      category_id: item.category_id,
      product_template_id: item.product_template_id,
      sku: item.sku,
      status: item.status,
      title: item.title,
      description: item.description,
      quantity_on_hand: item.quantity_on_hand,
      storage_location: item.storage_location,
      notes: item.notes,
      unit_cost_amount: item.unit_cost_amount,
      target_price_amount: item.target_price_amount,
      currency_code: item.currency_code,
      created_at: item.created_at,
      updated_at: item.updated_at
    }
  end
end
