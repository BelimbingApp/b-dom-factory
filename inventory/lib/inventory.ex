defmodule Bilimbi.Factory.Inventory do
  @moduledoc """
  Factory Inventory's public API: the item master, units of measure, stock
  locations, material identity, item-level unit conversions, and stock
  positions.

  Every operation takes a `Bilimbi.Base.Tenancy.Scope` and a company ID. The
  company must be live and inside the scope's tenant; a missing, deleted, or
  cross-tenant company is `{:error, :company_not_found}`, and a record that
  belongs to another company is reported as not found. Results are read models,
  never Ecto schemas.

  Stock positions are views over the Material Transaction ledger. The ledger is
  not built yet, so every position currently reads zero.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Factory.Inventory.Conversion
  alias Bilimbi.Factory.Inventory.Item
  alias Bilimbi.Factory.Inventory.Location
  alias Bilimbi.Factory.Inventory.Material
  alias Bilimbi.Factory.Inventory.Schemas
  alias Bilimbi.Factory.Inventory.StockPosition
  alias Bilimbi.Factory.Inventory.Unit

  @default_limit 100
  @maximum_limit 500

  @type not_found ::
          :company_not_found
          | :item_not_found
          | :unit_not_found
          | :location_not_found
          | :material_not_found
          | :conversion_not_found

  # ============================================================================
  # Item master
  # ============================================================================

  @doc "Statuses an item master row may hold, as Belimbing defines them."
  @spec item_statuses() :: [String.t()]
  def item_statuses, do: Schemas.Item.statuses()

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
  Creates an item master row with Belimbing's create rules.

  Accepts `sku`, `title`, `status`, `description`, `quantity_on_hand`,
  `storage_location`, `notes`, `unit_cost_amount`, `target_price_amount` (minor
  units), and `currency_code`. Catalog references are not accepted: Inventory
  cannot validate a catalog it does not own.
  """
  @spec create_item(Scope.t(), pos_integer(), map()) ::
          {:ok, Item.t()} | {:error, :company_not_found | Ecto.Changeset.t()}
  def create_item(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    with :ok <- live_company(scope, company_id),
         {:ok, item} <- company_id |> Schemas.Item.creation_changeset(attributes) |> Repo.insert() do
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
  # Material identity and conversions
  # ============================================================================

  @doc """
  Makes an item a stocked material held in `native_unit_id`.

  An item is registered once. Its native unit never changes, because every
  quantity recorded for it is in that unit.
  """
  @spec register_material(Scope.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, Material.t()}
          | {:error, :company_not_found | :item_not_found | :unit_not_found | Ecto.Changeset.t()}
  def register_material(%Scope{} = scope, company_id, item_id, native_unit_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item} <- fetch(Schemas.Item, company_id, item_id, :item_not_found),
         {:ok, unit} <- fetch(Schemas.Unit, company_id, native_unit_id, :unit_not_found),
         {:ok, _material} <-
           company_id |> Schemas.Material.creation_changeset(item.id, unit.id) |> Repo.insert() do
      {:ok, material(company_id, item, unit)}
    end
  end

  @spec get_material(Scope.t(), pos_integer(), pos_integer()) ::
          {:ok, Material.t()}
          | {:error, :company_not_found | :item_not_found | :material_not_found}
  def get_material(%Scope{} = scope, company_id, item_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item, _material, unit} <- fetch_material(company_id, item_id) do
      {:ok, material(company_id, item, unit)}
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
  # Stock positions
  # ============================================================================

  @doc """
  Reads the stock position of one material at one location.

  The quantity is in the item's native unit. Positions are derived from the
  Material Transaction ledger; until that ledger lands every position is zero.
  """
  @spec get_stock_position(Scope.t(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, StockPosition.t()}
          | {:error,
             :company_not_found | :item_not_found | :material_not_found | :location_not_found}
  def get_stock_position(%Scope{} = scope, company_id, item_id, location_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, item, _material, native_unit} <- fetch_material(company_id, item_id),
         {:ok, location} <- fetch(Schemas.Location, company_id, location_id, :location_not_found) do
      {:ok,
       %StockPosition{
         item_id: item.id,
         location_id: location.id,
         # No ledger rows exist to sum yet.
         quantity: Decimal.new(0),
         unit: Unit.from_schema(native_unit)
       }}
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp live_company(scope, company_id) do
    case Company.get_company(scope, company_id) do
      {:ok, _company} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
    end
  end

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

  defp material(company_id, item, native_unit) do
    %Material{
      item_id: item.id,
      company_id: company_id,
      sku: item.sku,
      native_unit: Unit.from_schema(native_unit)
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
