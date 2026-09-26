defmodule Bilimbi.Factory.Inventory.Conversion do
  @moduledoc """
  Read model for one version of an item-level unit conversion.

  One `unit` equals `factor` of the item's `native_unit`. A version never
  changes after it is defined, so a converted quantity that names its version
  can always be recomputed from the original.
  """

  alias Bilimbi.Factory.Inventory.Unit

  @enforce_keys [:id, :item_id, :unit, :native_unit, :version, :factor, :created_at]
  defstruct [:id, :item_id, :unit, :native_unit, :version, :factor, :created_at]

  @type t :: %__MODULE__{
          id: pos_integer(),
          item_id: pos_integer(),
          unit: Unit.t(),
          native_unit: Unit.t(),
          version: pos_integer(),
          factor: Decimal.t(),
          created_at: NaiveDateTime.t()
        }
end
