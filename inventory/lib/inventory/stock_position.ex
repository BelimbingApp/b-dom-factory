defmodule Bilimbi.Factory.Inventory.StockPosition do
  @moduledoc """
  The current quantity of one item at one location, in the item's native unit.
  """

  alias Bilimbi.Factory.Inventory.Unit

  @enforce_keys [:item_id, :location_id, :quantity, :unit]
  defstruct [:item_id, :location_id, :quantity, :unit]

  @type t :: %__MODULE__{
          item_id: pos_integer(),
          location_id: pos_integer(),
          quantity: Decimal.t(),
          unit: Unit.t()
        }
end
