defmodule Bilimbi.Factory.Inventory.ReceiptMeasurement do
  @moduledoc """
  Typed weigh-ticket values attached to a receipt. All values use `unit_id`;
  `supplier_variance` is declared net minus measured net.
  """

  @enforce_keys [
    :supplier_declared,
    :measured_gross,
    :tare,
    :net,
    :unit_id,
    :weighing_point_ref,
    :supplier_variance
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          supplier_declared: Decimal.t(),
          measured_gross: Decimal.t(),
          tare: Decimal.t(),
          net: Decimal.t(),
          unit_id: pos_integer(),
          weighing_point_ref: String.t(),
          supplier_variance: Decimal.t()
        }
end
