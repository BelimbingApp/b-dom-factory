defmodule Bilimbi.Factory.Inventory.Unit do
  @moduledoc "Read model for one company's unit of measure."

  @enforce_keys [:id, :company_id, :code, :name]
  defstruct [:id, :company_id, :code, :name]

  @type t :: %__MODULE__{
          id: pos_integer(),
          company_id: pos_integer(),
          code: String.t(),
          name: String.t()
        }

  @doc false
  @spec from_schema(Bilimbi.Factory.Inventory.Schemas.Unit.t()) :: t()
  def from_schema(unit) do
    %__MODULE__{id: unit.id, company_id: unit.company_id, code: unit.code, name: unit.name}
  end
end
