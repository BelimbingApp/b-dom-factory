defmodule Bilimbi.Factory.Inventory.Material do
  @moduledoc """
  Read model for an item's material identity: the item master row it stocks
  and the native unit its quantities are held in.
  """

  alias Bilimbi.Factory.Inventory.Unit

  @enforce_keys [:item_id, :company_id, :sku, :native_unit]
  defstruct [:item_id, :company_id, :sku, :native_unit]

  @type t :: %__MODULE__{
          item_id: pos_integer(),
          company_id: pos_integer(),
          sku: String.t(),
          native_unit: Unit.t()
        }
end
