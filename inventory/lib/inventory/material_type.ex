defmodule Bilimbi.Factory.Inventory.MaterialType do
  @moduledoc """
  Read model for one company-defined material type: a code, a name, and the
  property definitions every material of the type holds values for
  (`Bilimbi.Factory.Inventory.PropertyDefinition`).
  """

  @enforce_keys [:id, :company_id, :code, :name, :property_definitions]
  defstruct [:id, :company_id, :code, :name, :property_definitions, :retired_at]

  @type t :: %__MODULE__{
          id: pos_integer(),
          company_id: pos_integer(),
          code: String.t(),
          name: String.t(),
          property_definitions: [Bilimbi.Factory.Inventory.PropertyDefinition.definition()],
          retired_at: NaiveDateTime.t() | nil
        }

  @doc false
  @spec from_schema(Bilimbi.Factory.Inventory.Schemas.MaterialType.t()) :: t()
  def from_schema(type) do
    %__MODULE__{
      id: type.id,
      company_id: type.company_id,
      code: type.code,
      name: type.name,
      property_definitions: type.property_definitions,
      retired_at: type.retired_at
    }
  end
end
