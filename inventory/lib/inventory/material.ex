defmodule Bilimbi.Factory.Inventory.Material do
  @moduledoc """
  Read model for an item's material identity: the item master row it stocks,
  the native unit its quantities are held in, and, when the company gave it a
  material type, that type and the property values validated against it.
  """

  alias Bilimbi.Factory.Inventory.PropertyDefinition
  alias Bilimbi.Factory.Inventory.Unit

  @enforce_keys [:item_id, :company_id, :sku, :native_unit]
  defstruct [
    :item_id,
    :company_id,
    :sku,
    :native_unit,
    :material_type_id,
    :retired_at,
    properties: %{}
  ]

  @type t :: %__MODULE__{
          item_id: pos_integer(),
          company_id: pos_integer(),
          sku: String.t(),
          native_unit: Unit.t(),
          material_type_id: pos_integer() | nil,
          properties: PropertyDefinition.values(),
          retired_at: NaiveDateTime.t() | nil
        }
end
