defmodule Bilimbi.Factory.Inventory.Entry do
  @moduledoc """
  Read model for one effect of a Material Transaction.

  `native_quantity` is signed and in `native_unit`: a transaction's entries
  sum to zero per native unit. Its `role` is one of:

    * `:stock` — material at `location_id`. It keeps the quantity and unit as
      recorded, how that quantity was obtained (`observation`), and, when the
      recorded unit is not the native unit, the conversion basis and version
      used to derive the native quantity.
    * `:boundary` — the counterpart outside stock: where a receipt came from,
      where consumption went, or what production produced.
    * `:variance` — the difference a transform's observations do not account
      for, with its evidence and reconciliation basis. It changes no observed
      quantity.

  `output_role` is the caller's opaque label for a transform output, such as
  finished, trim, or waste.
  """

  alias Bilimbi.Factory.Inventory.Unit

  @enforce_keys [:id, :role, :native_quantity, :native_unit]
  defstruct [
    :id,
    :role,
    :item_id,
    :location_id,
    :native_quantity,
    :native_unit,
    :recorded_quantity,
    :recorded_unit,
    :conversion_id,
    :conversion_version,
    :observation,
    :output_role,
    :evidence,
    :reconciliation_basis
  ]

  @type observation :: :measured | :declared | :counted | :derived

  @type t :: %__MODULE__{
          id: pos_integer(),
          role: :stock | :boundary | :variance,
          item_id: pos_integer() | nil,
          location_id: pos_integer() | nil,
          native_quantity: Decimal.t(),
          native_unit: Unit.t(),
          recorded_quantity: Decimal.t() | nil,
          recorded_unit: Unit.t() | nil,
          conversion_id: pos_integer() | nil,
          conversion_version: pos_integer() | nil,
          observation: observation() | nil,
          output_role: String.t() | nil,
          evidence: String.t() | nil,
          reconciliation_basis: String.t() | nil
        }
end
