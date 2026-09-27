defmodule Bilimbi.Factory.Inventory.PropertyDefinition do
  @moduledoc """
  Company-defined property definitions and the values held against them.

  A material type or a resource type carries a list of definitions; each
  material or resource of that type holds one value per definition. This is
  the one mechanism for both, so a property behaves the same wherever a
  company configures it. Nothing here names a particular property: what a
  type measures is that company's configuration.

  A definition has a `key` (lower-case identifier, unique in the type), a
  `label`, a `value_type` (`string`, `integer`, `decimal`, or `boolean`), an
  optional `unit` label for a numeric value, and `required`.

  Definitions are normalized to string-keyed maps, the shape they are stored
  and read back in. Values are validated against the definitions that own
  them: no unknown key, every required key present, and each value of its
  declared type. A decimal is stored as a plain decimal string at the
  precision it was given, so a value reads back as it was recorded.
  """

  @value_types ~w(string integer decimal boolean)
  @numeric_types ~w(integer decimal)
  @key_format ~r/^[a-z][a-z0-9_]{0,63}$/
  @label_limit 255
  @unit_limit 32
  @string_limit 1000

  @type definition :: %{required(String.t()) => String.t() | boolean() | nil}
  @type values :: %{required(String.t()) => String.t() | integer() | boolean()}

  @doc "The value types a definition may declare."
  @spec value_types() :: [String.t()]
  def value_types, do: @value_types

  @doc """
  Normalizes a list of definitions, refusing a malformed one, a duplicate
  key, or a unit on a non-numeric value type. An empty list is a type with
  no properties.
  """
  @spec normalize_definitions(term()) ::
          {:ok, [definition()]} | {:error, :invalid_property_definitions}
  def normalize_definitions(definitions) when is_list(definitions) do
    definitions
    |> Enum.reduce_while({:ok, []}, fn definition, {:ok, acc} ->
      case definition(definition) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)
        keys = Enum.map(normalized, & &1["key"])

        if length(Enum.uniq(keys)) == length(keys),
          do: {:ok, normalized},
          else: {:error, :invalid_property_definitions}

      :error ->
        {:error, :invalid_property_definitions}
    end
  end

  def normalize_definitions(_definitions), do: {:error, :invalid_property_definitions}

  @doc """
  Validates property values against their definitions. `nil` stands for no
  values. Keys may be atoms or strings; the result is string-keyed.
  """
  @spec validate_values([definition()], term()) ::
          {:ok, values()} | {:error, :invalid_properties}
  def validate_values(definitions, nil) when is_list(definitions),
    do: validate_values(definitions, %{})

  def validate_values(definitions, values) when is_list(definitions) and is_map(values) do
    values = for {key, value} <- values, into: %{}, do: {to_string(key), value}
    known = MapSet.new(definitions, & &1["key"])

    if Enum.all?(Map.keys(values), &MapSet.member?(known, &1)) do
      Enum.reduce_while(definitions, {:ok, %{}}, fn definition, {:ok, acc} ->
        key = definition["key"]

        case {Map.fetch(values, key), definition["required"]} do
          {:error, false} -> {:cont, {:ok, acc}}
          {:error, true} -> {:halt, :error}
          {{:ok, value}, _} -> with_value(acc, key, value(definition["value_type"], value))
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, normalized}
        :error -> {:error, :invalid_properties}
      end
    else
      {:error, :invalid_properties}
    end
  end

  def validate_values(_definitions, _values), do: {:error, :invalid_properties}

  defp with_value(acc, key, {:ok, value}), do: {:cont, {:ok, Map.put(acc, key, value)}}
  defp with_value(_acc, _key, :error), do: {:halt, :error}

  defp definition(definition) when is_map(definition) do
    key = fetch(definition, :key)
    label = fetch(definition, :label)
    value_type = fetch(definition, :value_type)
    unit = fetch(definition, :unit)
    required = fetch(definition, :required, false)

    with true <- is_binary(key) and Regex.match?(@key_format, key),
         true <- text?(label, @label_limit),
         true <- value_type in @value_types,
         true <- is_boolean(required),
         true <- is_nil(unit) or (value_type in @numeric_types and text?(unit, @unit_limit)) do
      {:ok,
       %{
         "key" => key,
         "label" => String.trim(label),
         "value_type" => value_type,
         "unit" => unit && String.trim(unit),
         "required" => required
       }}
    else
      _ -> :error
    end
  end

  defp definition(_definition), do: :error

  defp text?(value, limit),
    do: is_binary(value) and String.trim(value) != "" and String.length(value) <= limit

  defp value("string", value) do
    if text?(value, @string_limit), do: {:ok, String.trim(value)}, else: :error
  end

  defp value("integer", value) when is_integer(value), do: {:ok, value}
  defp value("boolean", value) when is_boolean(value), do: {:ok, value}

  defp value("decimal", value)
       when is_binary(value) or is_integer(value) or is_struct(value, Decimal) do
    case Decimal.cast(value) do
      {:ok, decimal} ->
        if Decimal.nan?(decimal) or Decimal.inf?(decimal),
          do: :error,
          else: {:ok, Decimal.to_string(decimal, :normal)}

      :error ->
        :error
    end
  end

  defp value(_value_type, _value), do: :error

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
