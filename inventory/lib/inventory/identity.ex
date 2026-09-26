defmodule Bilimbi.Factory.Inventory.Identity do
  @moduledoc "An identified lot or individual unit. Its source transaction never changes."
  @enforce_keys [:id, :item_id, :kind, :code, :source_transaction_id]
  defstruct [:id, :item_id, :kind, :code, :source_transaction_id, dimensions: %{}]

  @type t :: %__MODULE__{
          id: pos_integer(),
          item_id: pos_integer(),
          kind: :lot | :unit,
          code: String.t(),
          source_transaction_id: pos_integer(),
          dimensions: %{
            optional(:width | :length | :thickness) => Bilimbi.Factory.Inventory.Dimension.t()
          }
        }
end
