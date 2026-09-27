defmodule Bilimbi.Factory.Inventory.Balance do
  @moduledoc """
  Read model for the material balance of one transaction, net of its
  corrections.

  `per_unit` has one group per native unit among the stock entries, in the
  order the units first appear. `input` and `output` are the observed totals
  drawn from and put into stock in that unit, `difference` is input less
  output, and `variance` is what the transaction's variance entries in that
  unit record. Nothing is converted between groups: accounting balances per
  native unit, and the groups say nothing about each other.

  `cross_unit` is the measurement agreement across units, computed only when
  the stock entries span more than one native unit and only in a native unit
  `unit` that every line can be expressed in: a line native in that unit
  counts as recorded, and every other line converts through its item's
  current conversion to that unit. `conversions` names each conversion used
  (item, conversion ID, version, and factor), so the balance can be recomputed
  from the recorded quantities. A unit that any item has no conversion to has
  no cross-unit balance; nothing is assumed. `difference` is input less
  output in that unit. No entry records it.
  """

  alias Bilimbi.Factory.Inventory.Unit

  @enforce_keys [:transaction_id, :per_unit, :cross_unit, :correction_transaction_ids]
  defstruct [:transaction_id, :per_unit, :cross_unit, :correction_transaction_ids]

  @type group :: %{
          unit: Unit.t(),
          input: Decimal.t(),
          output: Decimal.t(),
          difference: Decimal.t(),
          variance: Decimal.t()
        }

  @type conversion :: %{
          item_id: pos_integer(),
          conversion_id: pos_integer(),
          version: pos_integer(),
          factor: Decimal.t()
        }

  @type cross_unit :: %{
          unit: Unit.t(),
          input: Decimal.t(),
          output: Decimal.t(),
          difference: Decimal.t(),
          conversions: [conversion()]
        }

  @type t :: %__MODULE__{
          transaction_id: pos_integer(),
          per_unit: [group()],
          cross_unit: [cross_unit()],
          correction_transaction_ids: [pos_integer()]
        }
end
