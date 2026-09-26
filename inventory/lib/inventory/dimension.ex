defmodule Bilimbi.Factory.Inventory.Dimension do
  @moduledoc "A positive length measurement attached to an identified unit at creation."

  @enforce_keys [:value, :unit, :provenance]
  defstruct [:value, :unit, :provenance]

  @type t :: %__MODULE__{
          value: Decimal.t(),
          unit: :um | :mm | :cm | :m,
          provenance: :measured | :nominal
        }

  @units %{"um" => :um, "mm" => :mm, "cm" => :cm, "m" => :m}
  @provenances %{"measured" => :measured, "nominal" => :nominal}
  @names %{"width" => :width, "length" => :length, "thickness" => :thickness}

  @spec parse(map()) :: {:ok, t()} | :error
  def parse(value) when is_map(value) do
    measurement = Map.get(value, :value, Map.get(value, "value"))
    unit = Map.get(value, :unit, Map.get(value, "unit"))
    provenance = Map.get(value, :provenance, Map.get(value, "provenance"))

    with true <- map_size(value) == 3,
         {:ok, decimal} <- decimal(measurement),
         false <- Decimal.inf?(decimal) or Decimal.nan?(decimal),
         true <- Decimal.gt?(decimal, 0) and Decimal.eq?(Decimal.round(decimal, 12), decimal),
         {:ok, unit} <- Map.fetch(@units, name(unit)),
         {:ok, provenance} <- Map.fetch(@provenances, name(provenance)) do
      {:ok, %__MODULE__{value: decimal, unit: unit, provenance: provenance}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "Maps a stored dimension name to its atom."
  @spec name!(String.t()) :: :width | :length | :thickness
  def name!(name), do: Map.fetch!(@names, name)

  defp name(value) when is_binary(value), do: value
  defp name(value) when is_atom(value), do: Atom.to_string(value)
  defp name(_), do: nil

  defp decimal(%Decimal{} = value), do: {:ok, value}
  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal(_), do: :error

  @spec stored(t()) :: map()
  def stored(%__MODULE__{} = dimension),
    do: %{
      "value" => Decimal.to_string(dimension.value),
      "unit" => Atom.to_string(dimension.unit),
      "provenance" => Atom.to_string(dimension.provenance)
    }
end
