defmodule Bilimbi.Factory.Inventory.Location do
  @moduledoc "Read model for one company's stock location."

  @enforce_keys [:id, :company_id, :code, :name]
  defstruct [:id, :company_id, :code, :name]

  @type t :: %__MODULE__{
          id: pos_integer(),
          company_id: pos_integer(),
          code: String.t(),
          name: String.t()
        }

  @doc false
  @spec from_schema(Bilimbi.Factory.Inventory.Schemas.Location.t()) :: t()
  def from_schema(location) do
    %__MODULE__{
      id: location.id,
      company_id: location.company_id,
      code: location.code,
      name: location.name
    }
  end
end
