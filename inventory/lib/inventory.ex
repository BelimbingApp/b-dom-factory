defmodule Bilimbi.Factory.Inventory do
  @moduledoc """
  Factory Inventory's public API: the item master and its company settings,
  units of measure, stock locations, material types, material identity,
  item-level unit conversions, the Material Transaction ledger, the
  production posting-authority registry, stock positions, and lot or unit
  genealogy.

  Every operation takes a `Bilimbi.Base.Tenancy.Scope` and a company ID. The
  company must be live and inside the scope's tenant; a missing, deleted, or
  cross-tenant company is `{:error, :company_not_found}`, and a record that
  belongs to another company is reported as not found. Results are read models,
  never Ecto schemas.

  Stock positions are views over the Material Transaction ledger, which is
  append-only: a mistake is corrected by a new transaction that names it.
  Identity ancestry is read from the ledger's transform links.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Factory.Inventory.Balance
  alias Bilimbi.Factory.Inventory.Contributions
  alias Bilimbi.Factory.Inventory.Conversion
  alias Bilimbi.Factory.Inventory.Genealogy
  alias Bilimbi.Factory.Inventory.Identity
  alias Bilimbi.Factory.Inventory.Item
  alias Bilimbi.Factory.Inventory.Ledger
  alias Bilimbi.Factory.Inventory.Location
  alias Bilimbi.Factory.Inventory.Material
  alias Bilimbi.Factory.Inventory.MaterialType
  alias Bilimbi.Factory.Inventory.PostingAuthority
  alias Bilimbi.Factory.Inventory.PropertyDefinition
  alias Bilimbi.Factory.Inventory.Schemas
  alias Bilimbi.Factory.Inventory.StockPosition
  alias Bilimbi.Factory.Inventory.Transaction
  alias Bilimbi.Factory.Inventory.Unit

  @default_limit 100
  @maximum_limit 500

  @type not_found ::
          :company_not_found
          | :item_not_found
          | :unit_not_found
          | :location_not_found
          | :material_not_found
          | :material_type_not_found
          | :conversion_not_found
          | :identity_not_found

  @type posting_result ::
          {:ok, Transaction.t()} | {:error, :company_not_found | Ledger.error()}

  # ============================================================================
  # Item master
  # ============================================================================

  @doc """
  The company's item master settings, resolved through Base Settings for the
  company, then its tenant.

    * `statuses` — the status vocabulary
      (`#{Contributions.item_statuses_key()}`), an ordered list whose first
      entry is the default status, or `nil` when the company has not
      configured one and any non-blank status is accepted.
    * `default_currency_code` — the currency an item takes when none is
      given (`#{Contributions.default_currency_key()}`), or `nil`.

  Inventory holds no vocabulary or currency of its own; both are the
  company's configuration.
  """
  @spec item_settings(Scope.t(), pos_integer()) ::
          {:ok, Schemas.Item.settings()} | {:error, :company_not_found}
  def item_settings(%Scope{} = scope, company_id) do
    with {:ok, company} <- live_company_summary(scope, company_id) do
      {:ok, item_settings_of(company)}
    end
  end

  @doc "Configures the company's item statuses and default currency as one write. Nil removes an override."
  def configure_item_settings(%Scope{} = scope, company_id, %{
        statuses: statuses,
        default_currency_code: currency
      }) do
    with {:ok, company} <- live_company_summary(scope, company_id),
         :ok <- validate_item_settings(statuses, currency) do
      setting_scope = Settings.Scope.company(company.id, company.tenant_id)

      Repo.transaction(fn ->
        with {:ok, _} <-
               put_item_setting(Contributions.item_statuses_key(), statuses, setting_scope),
             {:ok, _} <-
               put_item_setting(Contributions.default_currency_key(), currency, setting_scope) do
          item_settings_of(company)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  The company's own item settings overrides: each field is the company's
  value, or `nil` where the company inherits its tenant's setting.
  """
  @spec item_setting_overrides(Scope.t(), pos_integer()) ::
          {:ok, Schemas.Item.settings()} | {:error, :company_not_found}
  def item_setting_overrides(%Scope{} = scope, company_id) do
    with {:ok, company} <- live_company_summary(scope, company_id) do
      setting_scope = Settings.Scope.company(company.id, company.tenant_id)
      settings = item_settings_of(company)

      {:ok,
       %{
         statuses:
           if(Settings.overridden?(Contributions.item_statuses_key(), setting_scope),
             do: settings.statuses
           ),
         default_currency_code:
           if(Settings.overridden?(Contributions.default_currency_key(), setting_scope),
             do: settings.default_currency_code
           )
       }}
    end
  end

  defp validate_item_settings(statuses, currency) do
    cond do
      not (is_nil(statuses) or
               (is_list(statuses) and statuses != [] and
                  Enum.all?(
                    statuses,
                    &(is_binary(&1) and &1 != "" and &1 == String.trim(&1) and
                          String.length(&1) <= 255)
                  ) and
                  statuses == Enum.uniq(statuses))) ->
        {:error, :invalid_item_statuses}

      not (is_nil(currency) or
               (is_binary(currency) and Regex.match?(~r/^[A-Z]{3}$/, currency))) ->
        {:error, :invalid_default_currency}

      true ->
        :ok
    end
  end

  defp put_item_setting(key, nil, setting_scope) do
    :ok = Settings.delete(key, setting_scope)
    {:ok, nil}
  end

  defp put_item_setting(key, value, setting_scope), do: Settings.put(key, value, setting_scope)

  @doc """
  Lists a company's items ordered by SKU.

  Options: `:status` filters to one status; `:limit` caps the result (default
  #{@default_limit}, at most #{@maximum_limit}).
  """
  @spec list_items(Scope.t(), pos_integer(), keyword()) ::
          {:ok, [Item.t()]} | {:error, :company_not_found}
  def list_items(%Scope{} = scope, company_id, opts \\ []) do
    opts = Keyword.validate!(opts, status: nil, limit: @default_limit)

    with :ok <- live_company(scope, company_id) do
      items =
        from(item in Schemas.Item,
          where: item.company_id == ^company_id,
          order_by: [asc: item.sku],
          limit: ^limit!(opts[:limit])
        )
        |> filter_status(opts[:status])
        |> Repo.all()
        |> Enum.map(&Item.from_schema/1)

      {:ok, items}
    end
  end

  @spec get_item(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Item.t()} | {:error, :company_not_found | :item_not_found}
  def get_item(%Scope{} = scope, company_id, item_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item} <- fetch(Schemas.Item, company_id, item_id, :item_not_found) do
      {:ok, Item.from_schema(item)}
    end
  end

  @doc "Reads an item by SKU. SKUs are stored upper-case, so the lookup is too."
  @spec get_item_by_sku(Scope.t(), pos_integer(), String.t()) ::
          {:ok, Item.t()} | {:error, :company_not_found | :item_not_found}
  def get_item_by_sku(%Scope{} = scope, company_id, sku) when is_binary(sku) do
    with :ok <- live_company(scope, company_id) do
      sku = sku |> String.trim() |> String.upcase()

      case Repo.get_by(Schemas.Item, company_id: company_id, sku: sku) do
        nil -> {:error, :item_not_found}
        item -> {:ok, Item.from_schema(item)}
      end
    end
  end

  @doc """
  Creates an item master row with Belimbing's create rules and the company's
  item settings (`item_settings/2`).

  Accepts `sku`, `title`, `status`, `description`, `quantity_on_hand`,
  `storage_location`, `notes`, `unit_cost_amount`, `target_price_amount` (minor
  units), and `currency_code`. An omitted `status` is the configured
  vocabulary's first entry; an omitted `currency_code` is the configured
  default. Without the setting, the value is required. Catalog references
  are not accepted: Inventory cannot validate a catalog it does not own.
  """
  @spec create_item(Scope.t(), pos_integer(), map()) ::
          {:ok, Item.t()} | {:error, :company_not_found | Ecto.Changeset.t()}
  def create_item(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    with {:ok, company} <- live_company_summary(scope, company_id),
         {:ok, item} <-
           company_id
           |> Schemas.Item.creation_changeset(attributes, item_settings_of(company))
           |> Repo.insert() do
      {:ok, Item.from_schema(item)}
    end
  end

  # ============================================================================
  # Units of measure
  # ============================================================================

  @doc "Lists a company's units of measure ordered by code, capped by `:limit`."
  @spec list_units(Scope.t(), pos_integer(), keyword()) ::
          {:ok, [Unit.t()]} | {:error, :company_not_found}
  def list_units(%Scope{} = scope, company_id, opts \\ []) do
    opts = Keyword.validate!(opts, limit: @default_limit)

    with :ok <- live_company(scope, company_id) do
      units =
        from(unit in Schemas.Unit,
          where: unit.company_id == ^company_id,
          order_by: [asc: unit.code],
          limit: ^limit!(opts[:limit])
        )
        |> Repo.all()
        |> Enum.map(&Unit.from_schema/1)

      {:ok, units}
    end
  end

  @spec get_unit(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Unit.t()} | {:error, :company_not_found | :unit_not_found}
  def get_unit(%Scope{} = scope, company_id, unit_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, unit} <- fetch(Schemas.Unit, company_id, unit_id, :unit_not_found) do
      {:ok, Unit.from_schema(unit)}
    end
  end

  @doc "Creates a unit of measure from `code` (unique in the company) and `name`."
  @spec create_unit(Scope.t(), pos_integer(), map()) ::
          {:ok, Unit.t()} | {:error, :company_not_found | Ecto.Changeset.t()}
  def create_unit(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    with :ok <- live_company(scope, company_id),
         {:ok, unit} <- company_id |> Schemas.Unit.creation_changeset(attributes) |> Repo.insert() do
      {:ok, Unit.from_schema(unit)}
    end
  end

  @doc "Renames a company's unit. Its code remains stable in conversion and posting history."
  def rename_unit(%Scope{} = scope, company_id, unit_id, attributes) when is_map(attributes) do
    with :ok <- live_company(scope, company_id),
         {:ok, unit} <- fetch(Schemas.Unit, company_id, unit_id, :unit_not_found),
         :ok <- active_unit(unit),
         {:ok, updated} <- unit |> Schemas.Unit.rename_changeset(attributes) |> Repo.update() do
      {:ok, Unit.from_schema(updated)}
    end
  end

  @doc """
  Retires a unit while preserving the IDs in existing conversions and postings.
  A unit that is an active material's native unit is refused as `:unit_in_use`.
  """
  def retire_unit(%Scope{} = scope, company_id, unit_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, unit} <- fetch(Schemas.Unit, company_id, unit_id, :unit_not_found),
         :ok <- active_unit(unit),
         :ok <- no_active_native_materials(unit),
         {:ok, retired} <-
           unit
           |> Ecto.Changeset.change(
             retired_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
           )
           |> Repo.update() do
      {:ok, Unit.from_schema(retired)}
    end
  end

  defp active_unit(%{retired_at: nil}), do: :ok
  defp active_unit(_), do: {:error, :unit_retired}

  defp no_active_native_materials(unit) do
    if Repo.exists?(
         from(m in Schemas.Material,
           where:
             m.company_id == ^unit.company_id and m.native_unit_id == ^unit.id and
               is_nil(m.retired_at)
         )
       ),
       do: {:error, :unit_in_use},
       else: :ok
  end

  # ============================================================================
  # Stock locations
  # ============================================================================

  @doc "Lists a company's stock locations ordered by code, capped by `:limit`."
  @spec list_locations(Scope.t(), pos_integer(), keyword()) ::
          {:ok, [Location.t()]} | {:error, :company_not_found}
  def list_locations(%Scope{} = scope, company_id, opts \\ []) do
    opts = Keyword.validate!(opts, limit: @default_limit)

    with :ok <- live_company(scope, company_id) do
      locations =
        from(location in Schemas.Location,
          where: location.company_id == ^company_id,
          order_by: [asc: location.code],
          limit: ^limit!(opts[:limit])
        )
        |> Repo.all()
        |> Enum.map(&Location.from_schema/1)

      {:ok, locations}
    end
  end

  @spec get_location(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Location.t()} | {:error, :company_not_found | :location_not_found}
  def get_location(%Scope{} = scope, company_id, location_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, location} <- fetch(Schemas.Location, company_id, location_id, :location_not_found) do
      {:ok, Location.from_schema(location)}
    end
  end

  @doc "Creates a stock location from `code` (upper-cased, unique in the company) and `name`."
  @spec create_location(Scope.t(), pos_integer(), map()) ::
          {:ok, Location.t()} | {:error, :company_not_found | Ecto.Changeset.t()}
  def create_location(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    with :ok <- live_company(scope, company_id),
         {:ok, location} <-
           company_id |> Schemas.Location.creation_changeset(attributes) |> Repo.insert() do
      {:ok, Location.from_schema(location)}
    end
  end

  # ============================================================================
  # Material types
  # ============================================================================

  @doc """
  Defines a company material type from `code` (upper-cased, unique in the
  company), `name`, and `property_definitions`, a list validated by
  `Bilimbi.Factory.Inventory.PropertyDefinition.normalize_definitions/1`
  (empty for a type with no properties). Definitions stop changing once a
  material uses the type, so recorded values retain their meaning.
  """
  @spec create_material_type(Scope.t(), pos_integer(), map()) ::
          {:ok, MaterialType.t()}
          | {:error, :company_not_found | :invalid_property_definitions | Ecto.Changeset.t()}
  def create_material_type(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    with :ok <- live_company(scope, company_id),
         {:ok, definitions} <-
           PropertyDefinition.normalize_definitions(
             attribute(attributes, :property_definitions, [])
           ),
         {:ok, type} <-
           company_id
           |> Schemas.MaterialType.creation_changeset(attributes, definitions)
           |> Repo.insert() do
      {:ok, MaterialType.from_schema(type)}
    end
  end

  @spec get_material_type(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, MaterialType.t()} | {:error, :company_not_found | :material_type_not_found}
  def get_material_type(%Scope{} = scope, company_id, material_type_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, type} <-
           fetch(Schemas.MaterialType, company_id, material_type_id, :material_type_not_found) do
      {:ok, MaterialType.from_schema(type)}
    end
  end

  @doc "Updates a company's material type. Property definitions cannot change after a material uses the type."
  def update_material_type(%Scope{} = scope, company_id, material_type_id, attributes)
      when is_map(attributes) do
    with :ok <- live_company(scope, company_id),
         {:ok, type} <-
           fetch(Schemas.MaterialType, company_id, material_type_id, :material_type_not_found),
         :ok <- editable_type(type),
         {:ok, definitions} <-
           PropertyDefinition.normalize_definitions(
             attribute(attributes, :property_definitions, type.property_definitions)
           ),
         :ok <- definitions_editable(type, definitions),
         {:ok, updated} <-
           type |> Schemas.MaterialType.update_changeset(attributes, definitions) |> Repo.update() do
      {:ok, MaterialType.from_schema(updated)}
    end
  end

  @doc "Retires a material type without removing historical references."
  def retire_material_type(%Scope{} = scope, company_id, material_type_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, type} <-
           fetch(Schemas.MaterialType, company_id, material_type_id, :material_type_not_found),
         :ok <- editable_type(type),
         {:ok, retired} <-
           type
           |> Ecto.Changeset.change(
             retired_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
           )
           |> Repo.update() do
      {:ok, MaterialType.from_schema(retired)}
    end
  end

  defp editable_type(%{retired_at: nil}), do: :ok
  defp editable_type(_type), do: {:error, :material_type_retired}

  defp definitions_editable(type, definitions) do
    if definitions == type.property_definitions or
         not Repo.exists?(
           from(m in Schemas.Material,
             where: m.company_id == ^type.company_id and m.material_type_id == ^type.id
           )
         ) do
      :ok
    else
      {:error, :material_type_in_use}
    end
  end

  @doc "Lists a company's material types ordered by code, capped by `:limit`."
  @spec list_material_types(Scope.t(), pos_integer(), keyword()) ::
          {:ok, [MaterialType.t()]} | {:error, :company_not_found}
  def list_material_types(%Scope{} = scope, company_id, opts \\ []) do
    opts = Keyword.validate!(opts, limit: @default_limit)

    with :ok <- live_company(scope, company_id) do
      types =
        from(type in Schemas.MaterialType,
          where: type.company_id == ^company_id,
          order_by: [asc: type.code],
          limit: ^limit!(opts[:limit])
        )
        |> Repo.all()
        |> Enum.map(&MaterialType.from_schema/1)

      {:ok, types}
    end
  end

  # ============================================================================
  # Material identity and conversions
  # ============================================================================

  @doc """
  Makes an item a stocked material held in `native_unit_id`.

  An item is registered once. Its native unit never changes, because every
  quantity recorded for it is in that unit.

  Options: `:material_type_id` gives the material one of the company's types,
  and `:properties` its values for that type's definitions, validated by
  `Bilimbi.Factory.Inventory.PropertyDefinition.validate_values/2`; a
  material without a type holds none. A type of another company is
  `{:error, :material_type_not_found}`; values the type does not define, a
  missing required value, or a value of the wrong type are
  `{:error, :invalid_properties}`.
  """
  @spec register_material(Scope.t(), pos_integer(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, Material.t()}
          | {:error,
             :company_not_found
             | :item_not_found
             | :unit_not_found
             | :material_type_not_found
             | :invalid_properties
             | Ecto.Changeset.t()}
  def register_material(%Scope{} = scope, company_id, item_id, native_unit_id, opts \\ []) do
    opts = Keyword.validate!(opts, material_type_id: nil, properties: nil)

    with :ok <- live_company(scope, company_id),
         {:ok, item} <- fetch(Schemas.Item, company_id, item_id, :item_not_found),
         {:ok, unit} <- fetch(Schemas.Unit, company_id, native_unit_id, :unit_not_found),
         :ok <- active_unit(unit),
         {:ok, type_id, properties} <-
           typed_properties(company_id, opts[:material_type_id], opts[:properties]),
         {:ok, material} <-
           company_id
           |> Schemas.Material.creation_changeset(item.id, unit.id, type_id, properties)
           |> Repo.insert() do
      {:ok, material(company_id, item, material, unit)}
    end
  end

  @doc "Creates an item and registers it as a material atomically."
  def create_material(%Scope{} = scope, company_id, item_attributes, native_unit_id, opts \\ [])
      when is_map(item_attributes) do
    Repo.transaction(fn ->
      with {:ok, item} <- create_item(scope, company_id, item_attributes),
           {:ok, material} <- register_material(scope, company_id, item.id, native_unit_id, opts) do
        material
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec get_material(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Material.t()}
          | {:error, :company_not_found | :item_not_found | :material_not_found}
  def get_material(%Scope{} = scope, company_id, item_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item, material, unit} <- fetch_material(company_id, item_id) do
      {:ok, material(company_id, item, material, unit)}
    end
  end

  @doc "Updates an item's editable details and the material's typed values, preserving its native unit and type."
  def update_material(%Scope{} = scope, company_id, item_id, item_attributes, properties)
      when is_map(item_attributes) do
    with {:ok, company} <- live_company_summary(scope, company_id),
         {:ok, item, material_row, native_unit} <- fetch_material(company_id, item_id),
         :ok <- active_material(material_row),
         {:ok, normalized} <-
           existing_typed_properties(company_id, material_row.material_type_id, properties) do
      Repo.transaction(fn ->
        with {:ok, updated_item} <-
               item
               |> Schemas.Item.update_changeset(item_attributes, item_settings_of(company))
               |> Repo.update(),
             {:ok, updated_material} <-
               material_row |> Ecto.Changeset.change(properties: normalized) |> Repo.update() do
          material(company_id, updated_item, updated_material, native_unit)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Retires a material with no stock balance, preserving its posting history."
  def retire_material(%Scope{} = scope, company_id, item_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item, material_row, native_unit} <- fetch_material(company_id, item_id) do
      Repo.transaction(fn ->
        locked =
          Repo.one!(
            from(m in Schemas.Material, where: m.id == ^material_row.id, lock: "FOR UPDATE")
          )

        with :ok <- active_material(locked),
             :ok <- no_material_stock(locked),
             {:ok, retired} <-
               locked
               |> Ecto.Changeset.change(
                 retired_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
               )
               |> Repo.update() do
          material(company_id, item, retired, native_unit)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp active_material(%{retired_at: nil}), do: :ok
  defp active_material(_), do: {:error, :material_retired}

  defp no_material_stock(material_row) do
    balance =
      Repo.one(
        from(e in Schemas.Entry,
          where: e.material_id == ^material_row.id,
          select: sum(e.native_quantity)
        )
      )

    if is_nil(balance) or Decimal.equal?(balance, Decimal.new(0)),
      do: :ok,
      else: {:error, :material_has_stock}
  end

  defp existing_typed_properties(_company_id, nil, properties),
    do: PropertyDefinition.validate_values([], properties)

  defp existing_typed_properties(company_id, type_id, properties) do
    with {:ok, type} <- fetch(Schemas.MaterialType, company_id, type_id, :material_type_not_found) do
      PropertyDefinition.validate_values(type.property_definitions, properties)
    end
  end

  @doc "Lists a company's registered materials by item SKU, capped by `:limit`."
  def list_materials(%Scope{} = scope, company_id, opts \\ []) do
    opts = Keyword.validate!(opts, limit: @default_limit)

    with :ok <- live_company(scope, company_id) do
      materials =
        from(m in Schemas.Material,
          join: item in Schemas.Item,
          on: item.id == m.item_id and item.company_id == ^company_id,
          join: unit in Schemas.Unit,
          on: unit.id == m.native_unit_id and unit.company_id == ^company_id,
          where: m.company_id == ^company_id,
          order_by: [asc: item.sku],
          limit: ^limit!(opts[:limit]),
          select: {item, m, unit}
        )
        |> Repo.all()
        |> Enum.map(fn {item, material_row, unit} ->
          material(company_id, item, material_row, unit)
        end)

      {:ok, materials}
    end
  end

  @doc """
  Defines the next version of an item's conversion from `unit_id` to its
  native unit: one `unit_id` equals `factor` native units.

  Earlier versions stay readable; the new version becomes current. `factor`
  is a positive decimal (a `Decimal`, integer, or decimal string) with at most
  12 decimal places.
  """
  @spec define_conversion(
          Scope.t(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          Decimal.t() | integer() | String.t()
        ) ::
          {:ok, Conversion.t()}
          | {:error,
             :company_not_found
             | :item_not_found
             | :material_not_found
             | :unit_not_found
             | :native_unit
             | Ecto.Changeset.t()}
  def define_conversion(%Scope{} = scope, company_id, item_id, unit_id, factor) do
    with :ok <- live_company(scope, company_id) do
      Repo.transaction(fn ->
        case insert_conversion(company_id, item_id, unit_id, factor) do
          {:ok, conversion} -> conversion
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Lists every version of an item's conversions, by unit code then version."
  @spec list_conversions(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, [Conversion.t()]}
          | {:error, :company_not_found | :item_not_found | :material_not_found}
  def list_conversions(%Scope{} = scope, company_id, item_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item, _material, native_unit} <- fetch_material(company_id, item_id) do
      conversions =
        from([conversion, unit] in conversion_query(company_id, item.id),
          order_by: [asc: unit.code, asc: conversion.version]
        )
        |> Repo.all()
        |> Enum.map(&conversion(&1, item.id, native_unit))

      {:ok, conversions}
    end
  end

  @doc """
  Reads an item's conversion from `unit_id`: the current version, or the one
  named by the `:version` option.
  """
  @spec get_conversion(Scope.t(), pos_integer(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, Conversion.t()}
          | {:error,
             :company_not_found | :item_not_found | :material_not_found | :conversion_not_found}
  def get_conversion(%Scope{} = scope, company_id, item_id, unit_id, opts \\ []) do
    opts = Keyword.validate!(opts, version: :current)

    with :ok <- live_company(scope, company_id),
         {:ok, item, _material, native_unit} <- fetch_material(company_id, item_id),
         {:ok, row} <- fetch_conversion(company_id, item.id, unit_id, opts[:version]) do
      {:ok, conversion(row, item.id, native_unit)}
    end
  end

  # ============================================================================
  # Posting authority
  # ============================================================================

  @doc """
  Whether `module` is a production posting authority, as its OTP application
  declares in the composition metadata:

      env:
        Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__) ++
          [posting_authority: Bilimbi.Factory.ProductionExecution]

  Only a Domain module of Inventory's own container may declare one, naming
  one of its own modules; any other declaration fails Inventory's boot. The
  registry is built once at boot, and nothing registers at runtime.
  """
  @spec posting_authority_registered?(module()) :: boolean()
  def posting_authority_registered?(module) when is_atom(module),
    do: PostingAuthority.registered?(module)

  # ============================================================================
  # Material Transaction ledger
  # ============================================================================

  @doc "The ways a posted quantity may have been obtained, as a line's `observation` names them."
  @spec observations() :: [String.t()]
  def observations, do: Ledger.Request.observations()

  @doc """
  Records material received into stock from outside it.

  Every posting takes a request map with:

    * `request_id` (required) — the caller's idempotency key, unique in the
      company. Repeating a recorded request returns the recorded transaction;
      a different request under the same ID is `{:error, :request_id_conflict}`.
    * `actor_type` and `actor_id` (required) — who recorded it.
    * `evidence` (required) — the source evidence, such as a delivery note.
    * `receipt_measurement` — optional typed weigh-ticket fields: positive
      `supplier_declared`, `measured_gross`, and `net`; non-negative `tare`;
      shared `unit_id`; and `weighing_point_ref`. Gross less tare must equal
      net, and a weighed receipt must have one measured stock line whose
      quantity and unit match net and the ticket. The returned
      `Transaction.receipt_measurement.supplier_variance` is declared net
      minus measured net.
    * `effective_at` — when the material moved, if earlier than now. Inventory
      records its own `recorded_at` beside it, so a late entry keeps both.
    * `context` — optional opaque references, keyed by
      `Bilimbi.Factory.Inventory.Transaction.context_keys/0`, stored without
      interpretation.
    * `lines` — one or more lines, each with `item_id`, `location_id`,
      `quantity` (positive), `observation` (`measured`, `declared`, `counted`,
      or `derived`), and optionally `unit_id`, `conversion_version`, and
      `evidence`. A quantity in another unit is kept as recorded; its native
      quantity is derived through the item's current conversion, or the named
      version, and the entry names that basis.

  A posting that carries `operation_execution`, `order_or_batch`, or
  `work_centre` context is production context. Only the production postings
  (`record_output/4`, `record_transform/4`,
  `record_production_consumption/4`, and `record_production_correction/4`)
  accept it; each names its `authority`, a declared posting authority (see
  `posting_authority_registered?/1`). Anything else is
  `{:error, :unregistered_posting_authority}`.
  """
  @spec record_receipt(Scope.t(), pos_integer(), map()) :: posting_result()
  def record_receipt(%Scope{} = scope, company_id, request),
    do: post(scope, company_id, :receipt, request, [])

  @doc """
  Moves material between locations. Each line has `from_location_id` and
  `to_location_id` instead of `location_id`; the source must hold the quantity.
  """
  @spec record_transfer(Scope.t(), pos_integer(), map()) :: posting_result()
  def record_transfer(%Scope{} = scope, company_id, request),
    do: post(scope, company_id, :transfer, request, [])

  @doc """
  Records material used from stock. The location must hold the quantity, so
  two callers cannot consume the same material. Consumption against a
  production order is production context; see
  `record_production_consumption/4`.
  """
  @spec record_consumption(Scope.t(), pos_integer(), map()) :: posting_result()
  def record_consumption(%Scope{} = scope, company_id, request),
    do: post(scope, company_id, :consumption, request, [])

  @doc """
  Records consumption that may carry production context, posted by
  `authority`, a declared posting authority.
  """
  @spec record_production_consumption(Scope.t(), pos_integer(), map(), module()) ::
          posting_result()
  def record_production_consumption(%Scope{} = scope, company_id, request, authority),
    do: post(scope, company_id, :consumption, request, authority: authority)

  @doc "Records production output into stock, posted by `authority`."
  @spec record_output(Scope.t(), pos_integer(), map(), module()) :: posting_result()
  def record_output(%Scope{} = scope, company_id, request, authority),
    do: post(scope, company_id, :output, request, authority: authority)

  @doc """
  Corrects a recorded transaction with a new one; the original is never
  changed.

  Needs `corrects_transaction_id` and a `reason`. Each line's `quantity` is a
  signed adjustment at its location: negative removes stock, positive adds it.
  A transaction that needed a posting authority is corrected through
  `record_production_correction/4`.
  """
  @spec record_correction(Scope.t(), pos_integer(), map()) :: posting_result()
  def record_correction(%Scope{} = scope, company_id, request),
    do: post(scope, company_id, :correction, request, [])

  @doc """
  Corrects any recorded transaction, including one that needed a posting
  authority, posted by `authority`.
  """
  @spec record_production_correction(Scope.t(), pos_integer(), map(), module()) ::
          posting_result()
  def record_production_correction(%Scope{} = scope, company_id, request, authority),
    do: post(scope, company_id, :correction, request, authority: authority)

  @doc """
  Records a material transform: `inputs` drawn from stock and `outputs` put
  into stock, committed with their genealogy as one transaction, posted by
  `authority`.

  Input and output lines take the receipt line fields; an output may add an
  opaque `output_role`, such as finished, trim, or waste. Lines may be in
  several native units; the transform balances each native unit on its own,
  and nothing is converted between units.

  Observed quantities are kept as recorded and never adjusted to agree. Each
  native unit whose inputs and outputs differ records the difference as a
  variance entry in that unit, and needs `variance` evidence: `evidence` and
  `reconciliation_basis` shared by every differing unit, or `units`, a list
  of `unit_id`, `evidence`, and `reconciliation_basis` naming each differing
  unit's own, but not both. A differing unit without evidence is
  `{:error, :variance_required}`; evidence that no difference uses, shared or
  named, is `{:error, :no_variance}`. `get_transaction_balance/3` reads the
  result per unit and, in a unit every line was posted in, across units.
  """
  @spec record_transform(Scope.t(), pos_integer(), map(), module()) :: posting_result()
  def record_transform(%Scope{} = scope, company_id, request, authority),
    do: post(scope, company_id, :transform, request, authority: authority)

  @doc "Reads one lot or unit identity inside the company."
  @spec get_identity(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Identity.t()} | {:error, :company_not_found | :identity_not_found}
  def get_identity(%Scope{} = scope, company_id, identity_id) do
    with :ok <- live_company(scope, company_id), do: Genealogy.get(company_id, identity_id)
  end

  @doc "Reads the current positive stock positions of an identified lot or unit. Empty means none remains in stock."
  @spec get_identity_positions(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, :company_not_found | :identity_not_found}
  def get_identity_positions(%Scope{} = scope, company_id, identity_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, identity} <- Genealogy.get(company_id, identity_id) do
      {:ok, Ledger.identity_positions(company_id, identity.id)}
    end
  end

  @doc "Follows transform links from an output toward its source receipts."
  @spec trace_backward(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Genealogy.trace()} | {:error, :company_not_found | :identity_not_found}
  def trace_backward(%Scope{} = scope, company_id, identity_id) do
    with :ok <- live_company(scope, company_id),
         do: Genealogy.trace(company_id, identity_id, :backward)
  end

  @doc "Follows transform links from a receipt toward descendant outputs."
  @spec trace_forward(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Genealogy.trace()} | {:error, :company_not_found | :identity_not_found}
  def trace_forward(%Scope{} = scope, company_id, identity_id) do
    with :ok <- live_company(scope, company_id),
         do: Genealogy.trace(company_id, identity_id, :forward)
  end

  @doc "Lists the consumptions and transforms that drew the identity, in ID order."
  @spec list_identity_draws(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, [Transaction.t()]} | {:error, :company_not_found | :identity_not_found}
  def list_identity_draws(%Scope{} = scope, company_id, identity_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, identity} <- Genealogy.get(company_id, identity_id),
         do: {:ok, Ledger.draws(company_id, identity.id)}
  end

  @doc "Lists the corrections of a transaction, following corrections of corrections, in ID order."
  @spec list_corrections(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, [Transaction.t()]} | {:error, :company_not_found | :transaction_not_found}
  def list_corrections(%Scope{} = scope, company_id, transaction_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, transaction} <- Ledger.get(company_id, transaction_id),
         do: {:ok, Ledger.corrections(company_id, transaction.id)}
  end

  @doc """
  Reads a transaction's material balance, net of its corrections.

  `per_unit` balances each native unit on its own: observed input, output,
  their difference, and the variance the transaction recorded in that unit.
  `cross_unit` compares inputs and outputs across units only in a native unit
  that every line was posted in, natively or as its recorded unit, naming the
  conversion version each recorded line was posted through; see
  `Bilimbi.Factory.Inventory.Balance`.
  """
  @spec get_transaction_balance(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Balance.t()} | {:error, :company_not_found | :transaction_not_found}
  def get_transaction_balance(%Scope{} = scope, company_id, transaction_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, transaction} <- Ledger.get(company_id, transaction_id),
         do: {:ok, Ledger.balance(company_id, transaction)}
  end

  @spec get_transaction(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Transaction.t()} | {:error, :company_not_found | :transaction_not_found}
  def get_transaction(%Scope{} = scope, company_id, transaction_id) do
    with :ok <- live_company(scope, company_id) do
      Ledger.get(company_id, transaction_id)
    end
  end

  @doc """
  Lists a company's transactions, most recently recorded first.

  Options: `:item_id` keeps transactions with an entry for that item;
  `:limit` caps the result (default #{@default_limit}, at most
  #{@maximum_limit}).
  """
  @spec list_transactions(Scope.t(), pos_integer(), keyword()) ::
          {:ok, [Transaction.t()]} | {:error, :company_not_found}
  def list_transactions(%Scope{} = scope, company_id, opts \\ []) do
    opts = Keyword.validate!(opts, item_id: nil, limit: @default_limit)

    with :ok <- live_company(scope, company_id) do
      {:ok, Ledger.list(company_id, item_id: opts[:item_id], limit: limit!(opts[:limit]))}
    end
  end

  # ============================================================================
  # Stock positions
  # ============================================================================

  @doc """
  Reads the stock position of one material at one location: the sum of the
  ledger's stock entries there, in the item's native unit.
  """
  @spec get_stock_position(Scope.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, StockPosition.t()}
          | {:error,
             :company_not_found | :item_not_found | :material_not_found | :location_not_found}
  def get_stock_position(%Scope{} = scope, company_id, item_id, location_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item, material, native_unit} <- fetch_material(company_id, item_id),
         {:ok, location} <- fetch(Schemas.Location, company_id, location_id, :location_not_found) do
      {:ok,
       %StockPosition{
         item_id: item.id,
         location_id: location.id,
         quantity: Ledger.position(company_id, material.id, location.id),
         unit: Unit.from_schema(native_unit)
       }}
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp post(scope, company_id, kind, request, opts) when is_map(request) do
    with :ok <- live_company(scope, company_id) do
      Ledger.post(company_id, kind, request, opts)
    end
  end

  defp live_company(scope, company_id) do
    with {:ok, _company} <- live_company_summary(scope, company_id), do: :ok
  end

  defp live_company_summary(scope, company_id) do
    case Company.get_company(scope, company_id) do
      {:ok, company} -> {:ok, company}
      {:error, :not_found} -> {:error, :company_not_found}
    end
  end

  # A malformed override is an administration error, reported where it is
  # read rather than turned into a refused item.
  defp item_settings_of(company) do
    scope = Settings.Scope.company(company.id, company.tenant_id)
    statuses = Settings.get(Contributions.item_statuses_key(), scope)
    currency = Settings.get(Contributions.default_currency_key(), scope)

    unless is_nil(statuses) or
             (is_list(statuses) and statuses != [] and
                Enum.all?(statuses, &(is_binary(&1) and &1 != "" and &1 == String.trim(&1))) and
                statuses == Enum.uniq(statuses)) do
      raise ArgumentError,
            "#{Contributions.item_statuses_key()} for company #{company.id} must be a " <>
              "non-empty list of distinct, non-blank, unpadded statuses, got: #{inspect(statuses)}"
    end

    unless is_nil(currency) or (is_binary(currency) and String.length(String.trim(currency)) == 3) do
      raise ArgumentError,
            "#{Contributions.default_currency_key()} for company #{company.id} must be a " <>
              "three-letter code, got: #{inspect(currency)}"
    end

    %{statuses: statuses, default_currency_code: currency}
  end

  defp typed_properties(_company_id, nil, properties) do
    case PropertyDefinition.validate_values([], properties) do
      {:ok, none} -> {:ok, nil, none}
      error -> error
    end
  end

  defp typed_properties(company_id, material_type_id, properties) do
    with {:ok, type} <-
           fetch(Schemas.MaterialType, company_id, material_type_id, :material_type_not_found),
         :ok <- editable_type(type),
         {:ok, values} <-
           PropertyDefinition.validate_values(type.property_definitions, properties) do
      {:ok, type.id, values}
    end
  end

  defp attribute(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch(schema, company_id, id, error) when is_integer(id) and id > 0 do
    case Repo.get_by(schema, id: id, company_id: company_id) do
      nil -> {:error, error}
      record -> {:ok, record}
    end
  end

  defp fetch(_schema, _company_id, _id, error), do: {:error, error}

  defp fetch_material(company_id, item_id) do
    with {:ok, item} <- fetch(Schemas.Item, company_id, item_id, :item_not_found) do
      from(material in Schemas.Material,
        join: unit in Schemas.Unit,
        on: unit.id == material.native_unit_id,
        where: material.item_id == ^item.id and material.company_id == ^company_id,
        select: {material, unit}
      )
      |> Repo.one()
      |> case do
        nil -> {:error, :material_not_found}
        {material, unit} -> {:ok, item, material, unit}
      end
    end
  end

  # Locking the material row serialises the versions of its conversions; the
  # unique version index is the backstop.
  defp insert_conversion(company_id, item_id, unit_id, factor) do
    with {:ok, item, material, native_unit} <- fetch_material(company_id, item_id),
         {:ok, unit} <- fetch(Schemas.Unit, company_id, unit_id, :unit_not_found),
         :ok <- active_unit(unit),
         :ok <- not_native(unit, native_unit) do
      Repo.one!(
        from(material in Schemas.Material,
          where: material.id == ^material.id,
          lock: "FOR UPDATE",
          select: material.id
        )
      )

      version =
        from(conversion in Schemas.Conversion,
          where: conversion.material_id == ^material.id and conversion.unit_id == ^unit.id,
          select: coalesce(max(conversion.version), 0) + 1
        )
        |> Repo.one()

      identity = %{
        company_id: company_id,
        material_id: material.id,
        unit_id: unit.id,
        version: version,
        created_at: NaiveDateTime.utc_now(:second)
      }

      # `returning` reads the factor back at the column's scale, so the result
      # equals what a later read returns.
      with {:ok, row} <-
             identity
             |> Schemas.Conversion.creation_changeset(%{factor: factor})
             |> Repo.insert(returning: [:factor]) do
        {:ok, conversion({row, unit}, item.id, native_unit)}
      end
    end
  end

  defp not_native(%Schemas.Unit{id: id}, %Schemas.Unit{id: id}), do: {:error, :native_unit}
  defp not_native(_unit, _native_unit), do: :ok

  defp conversion_query(company_id, item_id) do
    from(conversion in Schemas.Conversion,
      join: unit in Schemas.Unit,
      on: unit.id == conversion.unit_id,
      join: material in Schemas.Material,
      on: material.id == conversion.material_id,
      where: material.item_id == ^item_id and conversion.company_id == ^company_id,
      select: {conversion, unit}
    )
  end

  defp fetch_conversion(company_id, item_id, unit_id, version) when is_integer(unit_id) do
    query =
      from([conversion] in conversion_query(company_id, item_id),
        where: conversion.unit_id == ^unit_id
      )

    query =
      case version do
        :current ->
          from([conversion] in query, order_by: [desc: conversion.version], limit: 1)

        version when is_integer(version) and version > 0 ->
          from([conversion] in query, where: conversion.version == ^version)

        other ->
          raise ArgumentError,
                "version must be :current or a positive integer, got: #{inspect(other)}"
      end

    case Repo.one(query) do
      nil -> {:error, :conversion_not_found}
      row -> {:ok, row}
    end
  end

  defp fetch_conversion(_company_id, _item_id, _unit_id, _version),
    do: {:error, :conversion_not_found}

  defp material(company_id, item, material, native_unit) do
    %Material{
      item_id: item.id,
      company_id: company_id,
      sku: item.sku,
      native_unit: Unit.from_schema(native_unit),
      material_type_id: material.material_type_id,
      properties: material.properties,
      retired_at: material.retired_at
    }
  end

  defp conversion({row, unit}, item_id, native_unit) do
    %Conversion{
      id: row.id,
      item_id: item_id,
      unit: Unit.from_schema(unit),
      native_unit: Unit.from_schema(native_unit),
      version: row.version,
      factor: row.factor,
      created_at: row.created_at
    }
  end

  defp filter_status(query, nil), do: query

  defp filter_status(query, status) when is_binary(status),
    do: from(item in query, where: item.status == ^status)

  defp limit!(limit) when is_integer(limit) and limit > 0 and limit <= @maximum_limit, do: limit

  defp limit!(limit) do
    raise ArgumentError,
          "limit must be an integer from 1 to #{@maximum_limit}, got: #{inspect(limit)}"
  end
end
