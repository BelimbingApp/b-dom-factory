defmodule Bilimbi.Factory.ProductDefinition do
  @moduledoc """
  Scoped product, resource type, resource, and immutable Formula/BOM and
  routing revision contracts.

  Definitions are owned by a company. Resource types and their properties are
  the company's configuration, validated through
  `Bilimbi.Factory.Inventory.PropertyDefinition`. Revision numbers are
  assigned under a product lock, and a selection names exact formula and
  routing versions. Returned values are maps, not persistence schemas.
  Execution remains the responsibility of Production Execution.
  """
  import Ecto.Query
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.PropertyDefinition

  alias Bilimbi.Factory.ProductDefinition.Schemas.{
    Formula,
    Product,
    Resource,
    ResourceType,
    Routing
  }

  @product_fields [:id, :company_id, :item_id, :code, :name]
  @resource_type_fields [:id, :company_id, :code, :name, :property_definitions, :retired_at]
  @resource_fields [:id, :company_id, :code, :name, :resource_type_id, :properties, :retired_at]
  @formula_fields [:id, :company_id, :product_id, :version, :lines, :process_config]
  @routing_fields [:id, :company_id, :product_id, :version, :operations, :process_config]

  @doc "Links exactly one product definition to a company Inventory item."
  def create_product(%Scope{} = scope, company_id, item_id, attrs) when is_map(attrs) do
    with {:ok, _item} <- Inventory.get_item(scope, company_id, item_id) do
      attrs = %{
        company_id: company_id,
        item_id: item_id,
        code: value(attrs, :code),
        name: value(attrs, :name)
      }

      insert(Product.changeset(attrs), @product_fields)
    end
  end

  def get_product(%Scope{} = scope, company_id, product_id) do
    fetch(scope, company_id, Product, product_id, :product_not_found, @product_fields)
  end

  @doc "Lists a company's product definitions ordered by code."
  def list_products(%Scope{} = scope, company_id) do
    with :ok <- live_company(scope, company_id) do
      {:ok,
       Product
       |> where([p], p.company_id == ^company_id)
       |> order_by([p], asc: p.code)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, @product_fields))}
    end
  end

  @doc """
  Defines a company resource type from `code` (upper-cased, unique in the
  company), `name`, and `property_definitions`, validated by
  `Bilimbi.Factory.Inventory.PropertyDefinition.normalize_definitions/1`
  (empty for a type with no properties). Definitions stop changing once a
  resource uses the type, so recorded values retain their meaning.
  """
  def create_resource_type(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with :ok <- live_company(scope, company_id),
         {:ok, definitions} <-
           PropertyDefinition.normalize_definitions(value(attrs, :property_definitions, [])) do
      attrs = %{
        company_id: company_id,
        code: value(attrs, :code),
        name: value(attrs, :name),
        property_definitions: definitions
      }

      insert(ResourceType.changeset(attrs), @resource_type_fields)
    end
  end

  @doc "Updates a resource type; property definitions are fixed once resources use it."
  def update_resource_type(%Scope{} = scope, company_id, type_id, attrs) when is_map(attrs) do
    with :ok <- live_company(scope, company_id),
         {:ok, type} <- resource_type_row(company_id, type_id),
         :ok <- active_type(type),
         {:ok, definitions} <-
           PropertyDefinition.normalize_definitions(
             value(attrs, :property_definitions, type.property_definitions)
           ),
         :ok <- editable_definitions(type, definitions),
         {:ok, updated} <-
           type
           |> ResourceType.update_changeset(
             attrs
             |> string_keys()
             |> Map.put("property_definitions", definitions)
           )
           |> Repo.update() do
      {:ok, Map.take(updated, @resource_type_fields)}
    end
  end

  @doc "Retires a resource type after all its resources are retired."
  def retire_resource_type(%Scope{} = scope, company_id, type_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, type} <- resource_type_row(company_id, type_id),
         :ok <- active_type(type),
         :ok <- no_active_resources(type),
         {:ok, retired} <-
           type
           |> Ecto.Changeset.change(
             retired_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
           )
           |> Repo.update() do
      {:ok, Map.take(retired, @resource_type_fields)}
    end
  end

  defp resource_type_row(company_id, id) when is_integer(id) and id > 0 do
    case Repo.get_by(ResourceType, id: id, company_id: company_id) do
      nil -> {:error, :resource_type_not_found}
      type -> {:ok, type}
    end
  end

  defp resource_type_row(_, _), do: {:error, :resource_type_not_found}
  defp active_type(%{retired_at: nil}), do: :ok
  defp active_type(_), do: {:error, :resource_type_retired}

  defp editable_definitions(type, definitions) do
    if definitions == type.property_definitions or
         not Repo.exists?(
           from(r in Resource,
             where: r.company_id == ^type.company_id and r.resource_type_id == ^type.id
           )
         ),
       do: :ok,
       else: {:error, :resource_type_in_use}
  end

  defp no_active_resources(type) do
    if Repo.exists?(
         from(r in Resource,
           where:
             r.company_id == ^type.company_id and r.resource_type_id == ^type.id and
               is_nil(r.retired_at)
         )
       ),
       do: {:error, :resource_type_in_use},
       else: :ok
  end

  def get_resource_type(%Scope{} = scope, company_id, resource_type_id) do
    fetch(
      scope,
      company_id,
      ResourceType,
      resource_type_id,
      :resource_type_not_found,
      @resource_type_fields
    )
  end

  @doc "Lists a company's resource types ordered by code."
  def list_resource_types(%Scope{} = scope, company_id) do
    with :ok <- live_company(scope, company_id) do
      types =
        from(t in ResourceType, where: t.company_id == ^company_id, order_by: [asc: t.code])
        |> Repo.all()
        |> Enum.map(&Map.take(&1, @resource_type_fields))

      {:ok, types}
    end
  end

  @doc """
  Defines a physical resource that a logical operation may allow: `code`,
  `name`, the company's `resource_type_id`, and `properties`, its values for
  that type's definitions
  (`Bilimbi.Factory.Inventory.PropertyDefinition.validate_values/2`). A type
  of another company is `{:error, :resource_type_not_found}`; values the type
  does not define, a missing required value, or a value of the wrong type are
  `{:error, :invalid_properties}`.
  """
  def create_resource(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with {:ok, type} <- get_resource_type(scope, company_id, value(attrs, :resource_type_id)),
         :ok <- active_type(type),
         {:ok, properties} <-
           PropertyDefinition.validate_values(
             type.property_definitions,
             value(attrs, :properties, %{})
           ) do
      attrs = %{
        company_id: company_id,
        code: value(attrs, :code),
        name: value(attrs, :name),
        resource_type_id: type.id,
        properties: properties
      }

      insert(Resource.changeset(attrs), @resource_fields)
    end
  end

  @doc "Lists a company's resources ordered by code."
  def list_resources(%Scope{} = scope, company_id) do
    with :ok <- live_company(scope, company_id) do
      {:ok,
       Resource
       |> where([r], r.company_id == ^company_id)
       |> order_by([r], asc: r.code)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, @resource_fields))}
    end
  end

  @doc "Updates a resource's code, name and typed values without changing its type."
  def update_resource(%Scope{} = scope, company_id, resource_id, attrs) when is_map(attrs) do
    with :ok <- live_company(scope, company_id),
         {:ok, resource} <- resource_row(company_id, resource_id),
         :ok <- active_resource(resource),
         {:ok, type} <- get_resource_type(scope, company_id, resource.resource_type_id),
         {:ok, properties} <-
           PropertyDefinition.validate_values(
             type.property_definitions,
             value(attrs, :properties, resource.properties)
           ),
         {:ok, updated} <-
           resource
           |> Resource.update_changeset(
             attrs
             |> string_keys()
             |> Map.put("properties", properties)
           )
           |> Repo.update() do
      {:ok, Map.take(updated, @resource_fields)}
    end
  end

  @doc "Retires a resource without changing existing routing revisions."
  def retire_resource(%Scope{} = scope, company_id, resource_id) do
    with :ok <- live_company(scope, company_id),
         {:ok, resource} <- resource_row(company_id, resource_id),
         :ok <- active_resource(resource),
         {:ok, retired} <-
           resource
           |> Ecto.Changeset.change(
             retired_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
           )
           |> Repo.update() do
      {:ok, Map.take(retired, @resource_fields)}
    end
  end

  defp resource_row(company_id, id) when is_integer(id) and id > 0 do
    case Repo.get_by(Resource, id: id, company_id: company_id) do
      nil -> {:error, :resource_not_found}
      resource -> {:ok, resource}
    end
  end

  defp resource_row(_, _), do: {:error, :resource_not_found}
  defp active_resource(%{retired_at: nil}), do: :ok
  defp active_resource(_), do: {:error, :resource_retired}

  def get_resource(%Scope{} = scope, company_id, resource_id) do
    fetch(scope, company_id, Resource, resource_id, :resource_not_found, @resource_fields)
  end

  @doc """
  Publishes the next Formula/BOM revision. Each line has `item_id`, `role`
  (`input` or `output`), positive `quantity`, and `unit_id`. Output lines may
  have a configured `output_role`. Inputs may have `material_hold_rule`.
  `process_config` is a JSON map carrying process family and tolerance data.
  """
  def publish_formula(%Scope{} = scope, company_id, product_id, attrs) when is_map(attrs) do
    with {:ok, product} <- get_product(scope, company_id, product_id),
         {:ok, lines} <- validate_lines(scope, company_id, value(attrs, :lines)),
         :ok <- product_output(product, lines),
         {:ok, config} <- config(value(attrs, :process_config, %{})) do
      publish(
        Formula,
        company_id,
        product_id,
        %{lines: lines, process_config: config},
        @formula_fields
      )
    end
  end

  @doc """
  Publishes the next routing revision. Operations have a unique `code`, positive
  `sequence`, `inputs` and `outputs` (Inventory item IDs), and nonempty
  `allowed_resource_ids`. Config is versioned with the revision. Items are
  matched against a Formula/BOM revision only by `select_revisions/5`.
  """
  def publish_routing(%Scope{} = scope, company_id, product_id, attrs) when is_map(attrs) do
    with {:ok, _product} <- get_product(scope, company_id, product_id),
         {:ok, operations} <- validate_operations(scope, company_id, value(attrs, :operations)),
         {:ok, config} <- config(value(attrs, :process_config, %{})) do
      publish(
        Routing,
        company_id,
        product_id,
        %{operations: operations, process_config: config},
        @routing_fields
      )
    end
  end

  def get_formula_revision(%Scope{} = scope, company_id, product_id, version) do
    revision(scope, company_id, Formula, product_id, version, :formula_not_found, @formula_fields)
  end

  def get_routing_revision(%Scope{} = scope, company_id, product_id, version) do
    revision(scope, company_id, Routing, product_id, version, :routing_not_found, @routing_fields)
  end

  @doc "Lists every immutable formula revision for one company product."
  def list_formula_revisions(%Scope{} = scope, company_id, product_id) do
    list_revisions(scope, company_id, product_id, Formula, @formula_fields)
  end

  @doc "Lists every immutable routing revision for one company product."
  def list_routing_revisions(%Scope{} = scope, company_id, product_id) do
    list_revisions(scope, company_id, product_id, Routing, @routing_fields)
  end

  defp list_revisions(scope, company_id, product_id, schema, fields) do
    with {:ok, _product} <- get_product(scope, company_id, product_id) do
      {:ok,
       schema
       |> where([r], r.company_id == ^company_id and r.product_id == ^product_id)
       |> order_by([r], asc: r.version)
       |> Repo.all()
       |> Enum.map(&Map.take(&1, fields))}
    end
  end

  @doc "Resolves the exact immutable definitions selected by a future order."
  def select_revisions(%Scope{} = scope, company_id, product_id, formula_version, routing_version) do
    with {:ok, product} <- get_product(scope, company_id, product_id),
         {:ok, formula} <- get_formula_revision(scope, company_id, product_id, formula_version),
         {:ok, routing} <- get_routing_revision(scope, company_id, product_id, routing_version),
         :ok <- compatible(product, formula, routing) do
      {:ok, %{product: product, formula: formula, routing: routing}}
    end
  end

  defp compatible(product, formula, routing) do
    inputs = role_items(formula, "input")
    outputs = role_items(formula, "output")
    operations = routing.operations

    if Enum.all?(operations, fn operation ->
         Enum.all?(operation["inputs"], &MapSet.member?(inputs, &1)) and
           Enum.all?(operation["outputs"], &MapSet.member?(outputs, &1))
       end) and Enum.any?(operations, &(product.item_id in &1["outputs"])),
       do: :ok,
       else: {:error, :routing_formula_mismatch}
  end

  defp role_items(formula, role),
    do: for(line <- formula.lines, line["role"] == role, into: MapSet.new(), do: line["item_id"])

  defp product_output(product, lines) do
    if Enum.any?(lines, &(&1["role"] == "output" and &1["item_id"] == product.item_id)),
      do: :ok,
      else: {:error, :product_output_missing}
  end

  defp publish(schema, company_id, product_id, attrs, fields) do
    Repo.transaction(fn ->
      Repo.one!(
        from(p in Product,
          where: p.id == ^product_id and p.company_id == ^company_id,
          lock: "FOR UPDATE"
        )
      )

      version =
        Repo.one(
          from(r in schema,
            where: r.product_id == ^product_id,
            select: coalesce(max(r.version), 0)
          )
        ) + 1

      changeset =
        schema.changeset(
          Map.merge(attrs, %{company_id: company_id, product_id: product_id, version: version})
        )

      case Repo.insert(changeset) do
        {:ok, row} -> Map.take(row, fields)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp revision(scope, company_id, schema, product_id, version, error, fields) do
    with {:ok, _product} <- get_product(scope, company_id, product_id) do
      case (is_integer(version) and version > 0) &&
             Repo.get_by(schema, company_id: company_id, product_id: product_id, version: version) do
        nil -> {:error, error}
        false -> {:error, error}
        row -> {:ok, Map.take(row, fields)}
      end
    end
  end

  defp fetch(scope, company_id, schema, id, error, fields) do
    with :ok <- live_company(scope, company_id) do
      case (is_integer(id) and id > 0) && Repo.get_by(schema, company_id: company_id, id: id) do
        nil -> {:error, error}
        false -> {:error, error}
        row -> {:ok, Map.take(row, fields)}
      end
    end
  end

  defp insert(changeset, fields) do
    case Repo.insert(changeset) do
      {:ok, row} -> {:ok, Map.take(row, fields)}
      error -> error
    end
  end

  defp live_company(scope, company_id) do
    case Company.get_company(scope, company_id) do
      {:ok, _} -> :ok
      _ -> {:error, :company_not_found}
    end
  end

  defp validate_lines(scope, company_id, lines) when is_list(lines) and lines != [] do
    with {:ok, normalized} <- collect(lines, &line/1),
         true <- Enum.any?(normalized, &(&1["role"] == "output")),
         :ok <- each_item(scope, company_id, Enum.map(normalized, & &1["item_id"])),
         :ok <- each_unit(scope, company_id, Enum.map(normalized, & &1["unit_id"])) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_lines}
      other -> other
    end
  end

  defp validate_lines(_, _, _), do: {:error, :invalid_lines}

  defp line(line) when is_map(line) do
    item_id = value(line, :item_id)
    unit_id = value(line, :unit_id)
    role = value(line, :role)
    quantity = value(line, :quantity)
    output_role = value(line, :output_role)
    hold = value(line, :material_hold_rule)

    with true <- is_integer(item_id) and item_id > 0 and is_integer(unit_id) and unit_id > 0,
         true <- role in ["input", "output"],
         {:ok, quantity} <- decimal(quantity),
         true <-
           is_nil(output_role) or
             (role == "output" and is_binary(output_role) and output_role != ""),
         true <- is_nil(hold) or (role == "input" and is_map(hold)) do
      {:ok,
       %{
         "item_id" => item_id,
         "unit_id" => unit_id,
         "role" => role,
         "quantity" => quantity,
         "output_role" => output_role,
         "material_hold_rule" => hold
       }}
    else
      _ -> {:error, :invalid_lines}
    end
  end

  defp line(_), do: {:error, :invalid_lines}

  defp validate_operations(scope, company_id, operations)
       when is_list(operations) and operations != [] do
    with {:ok, normalized} <- collect(operations, &operation/1),
         true <- unique?(normalized, "code") and unique?(normalized, "sequence"),
         :ok <-
           each_item(
             scope,
             company_id,
             Enum.flat_map(normalized, &(&1["inputs"] ++ &1["outputs"]))
           ),
         :ok <-
           each_resource(
             scope,
             company_id,
             Enum.flat_map(normalized, & &1["allowed_resource_ids"])
           ) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_operations}
      other -> other
    end
  end

  defp validate_operations(_, _, _), do: {:error, :invalid_operations}

  defp operation(op) when is_map(op) do
    code = value(op, :code)
    sequence = value(op, :sequence)
    inputs = value(op, :inputs)
    outputs = value(op, :outputs)
    resources = value(op, :allowed_resource_ids)

    with true <- is_binary(code) and code != "" and is_integer(sequence) and sequence > 0,
         true <-
           ids?(inputs) and ids?(outputs) and outputs != [] and ids?(resources) and
             resources != [] do
      {:ok,
       %{
         "code" => code,
         "sequence" => sequence,
         "inputs" => inputs,
         "outputs" => outputs,
         "allowed_resource_ids" => resources
       }}
    else
      _ -> {:error, :invalid_operations}
    end
  end

  defp operation(_), do: {:error, :invalid_operations}

  defp ids?(ids), do: is_list(ids) and Enum.all?(ids, &(is_integer(&1) and &1 > 0))
  defp unique?(maps, key), do: length(Enum.uniq_by(maps, & &1[key])) == length(maps)

  defp each_item(scope, company_id, ids) do
    Enum.reduce_while(Enum.uniq(ids), :ok, fn id, _ ->
      case Inventory.get_material(scope, company_id, id) do
        {:ok, %{retired_at: nil}} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :material_retired}}
        {:error, :material_not_found} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp each_unit(scope, company_id, ids) do
    Enum.reduce_while(Enum.uniq(ids), :ok, fn id, _ ->
      case Inventory.get_unit(scope, company_id, id) do
        {:ok, %{retired_at: nil}} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :unit_retired}}
        error -> {:halt, error}
      end
    end)
  end

  defp each_resource(scope, company_id, ids) do
    Enum.reduce_while(Enum.uniq(ids), :ok, fn id, _ ->
      case get_resource(scope, company_id, id) do
        {:ok, %{retired_at: nil}} -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :resource_retired}}
        error -> {:halt, error}
      end
    end)
  end

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp decimal(value) do
    case Decimal.cast(value) do
      {:ok, number} ->
        if Decimal.compare(number, 0) == :gt,
          do: {:ok, Decimal.to_string(number, :normal)},
          else: {:error, :invalid_lines}

      _ ->
        {:error, :invalid_lines}
    end
  end

  defp config(config) when is_map(config) do
    config = for {key, value} <- config, into: %{}, do: {to_string(key), value}

    if Enum.all?(
         Map.keys(config),
         &(&1 in ["process_family", "tolerances", "output_roles", "material_hold_rules"])
       ) and
         (is_nil(config["process_family"]) or is_binary(config["process_family"])) and
         Enum.all?(
           ["tolerances", "output_roles", "material_hold_rules"],
           &(is_nil(config[&1]) or is_map(config[&1]))
         ) do
      {:ok, config}
    else
      {:error, :invalid_process_config}
    end
  end

  defp config(_), do: {:error, :invalid_process_config}

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
