defmodule Bilimbi.Factory.Inventory.Unit do
  @moduledoc "Read model for one company's unit of measure."

  @enforce_keys [:id, :company_id, :code, :name]
  defstruct [:id, :company_id, :code, :name, :retired_at]

  @type t :: %__MODULE__{
          id: pos_integer(),
          company_id: pos_integer(),
          code: String.t(),
          name: String.t(),
          retired_at: NaiveDateTime.t() | nil
        }

  @doc false
  @spec from_schema(Bilimbi.Factory.Inventory.Schemas.Unit.t()) :: t()
  def from_schema(unit) do
    %__MODULE__{
      id: unit.id,
      company_id: unit.company_id,
      code: unit.code,
      name: unit.name,
      retired_at: unit.retired_at
    }
  end
end
