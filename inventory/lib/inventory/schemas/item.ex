defmodule Bilimbi.Factory.Inventory.Schemas.Item do
  @moduledoc false

  # Belimbing's item master (`commerce_inventory_items`). Column names and
  # types follow the adopted table; see the baseline migration. The status
  # vocabulary and the default currency are company settings
  # (`Bilimbi.Factory.Inventory.item_settings/2`), so this schema carries no
  # default for either: the adopted column defaults belong to the adopted
  # table, and Inventory always writes both values explicitly.

  use Ecto.Schema

  @type t :: %__MODULE__{}
  @type settings :: %{
          statuses: [String.t()] | nil,
          default_currency_code: String.t() | nil
        }

  import Ecto.Changeset

  schema "commerce_inventory_items" do
    field(:company_id, :id)
    field(:category_id, :id)
    field(:product_template_id, :id)
    field(:sku, :string)
    field(:status, :string)
    field(:title, :string)
    field(:description, :string)
    field(:quantity_on_hand, :integer, default: 1)
    field(:storage_location, :string)
    field(:notes, :string)
    field(:unit_cost_amount, :integer)
    field(:target_price_amount, :integer)
    field(:currency_code, :string)
    timestamps(type: :naive_datetime, inserted_at: :created_at)
  end

  @doc """
  Belimbing's create rules: SKU and currency are upper-cased, a blank storage
  location is stored as null, and the quantity defaults to one.

  With a configured status set, an omitted status is the set's first entry
  and any other status must be in the set; without one, any non-blank status
  is accepted and must be given. An omitted currency is the configured
  default, when there is one.
  """
  @spec creation_changeset(pos_integer(), map(), settings()) :: Ecto.Changeset.t()
  def creation_changeset(company_id, attributes, settings) do
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
    |> default_status(settings.statuses)
    |> default_currency(settings.default_currency_code)
    |> update_change(:sku, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:status, &String.trim/1)
    |> update_change(:currency_code, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:storage_location, &String.trim/1)
    |> validate_required([:sku, :status, :title, :quantity_on_hand, :currency_code])
    |> validate_length(:sku, max: 64)
    |> validate_length(:title, max: 255)
    |> validate_length(:notes, max: 5000)
    |> validate_length(:storage_location, max: 255)
    |> validate_length(:currency_code, is: 3)
    |> validate_status(settings.statuses)
    |> validate_number(:quantity_on_hand,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 999_999
    )
    |> validate_number(:unit_cost_amount, greater_than_or_equal_to: 0)
    |> validate_number(:target_price_amount, greater_than_or_equal_to: 0)
    |> unique_constraint(:sku, name: :commerce_inventory_items_company_id_sku_unique)
  end

  @doc "Updates item presentation and status while preserving its SKU and ledger identity."
  def update_changeset(item, attributes, settings) do
    item
    |> cast(attributes, [:title, :description, :status, :notes, :currency_code])
    |> update_change(:status, &String.trim/1)
    |> update_change(:currency_code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:title, :status, :currency_code])
    |> validate_length(:title, max: 255)
    |> validate_length(:notes, max: 5000)
    |> validate_length(:currency_code, is: 3)
    |> validate_status(settings.statuses)
  end

  defp default_status(changeset, [first | _rest]) do
    if is_nil(get_change(changeset, :status)),
      do: put_change(changeset, :status, first),
      else: changeset
  end

  defp default_status(changeset, _statuses), do: changeset

  defp default_currency(changeset, default) when is_binary(default) do
    if is_nil(get_change(changeset, :currency_code)),
      do: put_change(changeset, :currency_code, default),
      else: changeset
  end

  defp default_currency(changeset, _default), do: changeset

  defp validate_status(changeset, statuses) when is_list(statuses),
    do: validate_inclusion(changeset, :status, statuses)

  defp validate_status(changeset, nil), do: validate_length(changeset, :status, min: 1, max: 255)
end
