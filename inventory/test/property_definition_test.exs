defmodule Bilimbi.Factory.Inventory.PropertyDefinitionTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Factory.Inventory.PropertyDefinition

  @definitions [
    %{
      "key" => "width",
      "label" => "Width",
      "value_type" => "decimal",
      "unit" => "mm",
      "required" => true
    },
    %{
      "key" => "count",
      "label" => "Count",
      "value_type" => "integer",
      "unit" => nil,
      "required" => false
    },
    %{
      "key" => "note",
      "label" => "Note",
      "value_type" => "string",
      "unit" => nil,
      "required" => false
    },
    %{
      "key" => "flag",
      "label" => "Flag",
      "value_type" => "boolean",
      "unit" => nil,
      "required" => false
    }
  ]

  test "normalizes atom- or string-keyed definitions to the stored shape" do
    assert {:ok, @definitions} =
             PropertyDefinition.normalize_definitions([
               %{
                 key: "width",
                 label: " Width ",
                 value_type: "decimal",
                 unit: "mm",
                 required: true
               },
               %{"key" => "count", "label" => "Count", "value_type" => "integer"},
               %{key: "note", label: "Note", value_type: "string", unit: nil},
               %{key: "flag", label: "Flag", value_type: "boolean", required: false}
             ])

    assert {:ok, []} = PropertyDefinition.normalize_definitions([])
    assert PropertyDefinition.value_types() == ["string", "integer", "decimal", "boolean"]
  end

  test "refuses a bad key, type, unit, required flag, or duplicate" do
    valid = %{key: "width", label: "Width", value_type: "decimal"}

    for bad <- [
          %{valid | key: "1width"},
          %{valid | key: "Width"},
          %{valid | key: String.duplicate("w", 65)},
          Map.delete(valid, :label),
          %{valid | value_type: "number"},
          Map.put(%{valid | value_type: "boolean"}, :unit, "mm"),
          Map.put(valid, :unit, ""),
          Map.put(valid, :required, nil),
          nil
        ] do
      assert {:error, :invalid_property_definitions} =
               PropertyDefinition.normalize_definitions([bad])
    end

    assert {:error, :invalid_property_definitions} =
             PropertyDefinition.normalize_definitions([valid, %{valid | label: "Other"}])

    assert {:error, :invalid_property_definitions} = PropertyDefinition.normalize_definitions(%{})
  end

  test "validates values by type and keeps decimals as normal strings" do
    assert {:ok, %{"width" => "12.50", "count" => 3, "note" => "x", "flag" => false}} =
             PropertyDefinition.validate_values(@definitions, %{
               "count" => 3,
               width: Decimal.new("12.50"),
               note: " x ",
               flag: false
             })

    assert {:ok, %{"width" => "7"}} =
             PropertyDefinition.validate_values(@definitions, %{width: 7})

    assert {:ok, %{}} = PropertyDefinition.validate_values([], nil)
    assert {:ok, %{}} = PropertyDefinition.validate_values([], %{})

    for bad <- [
          %{},
          nil,
          %{width: "1", other: 1},
          %{width: 1.5},
          %{width: "NaN"},
          %{width: "1", count: 2.0},
          %{width: "1", note: 1},
          %{width: "1", flag: "true"},
          [width: "1"]
        ] do
      assert {:error, :invalid_properties} = PropertyDefinition.validate_values(@definitions, bad)
    end

    assert {:error, :invalid_properties} = PropertyDefinition.validate_values([], %{a: 1})
  end
end
