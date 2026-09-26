defmodule Bilimbi.Factory.ProductDefinition do
  @moduledoc """
  Scoped product, immutable Formula/BOM and routing revision contracts.

  Definitions are owned by a company. Revision numbers are assigned under a
  product lock, and a selection names exact formula and routing versions.
  Returned values are maps, not persistence schemas. Execution remains the
  responsibility of Production Execution.
  """
  import Ecto.Query
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductDefinition.Schemas.{Formula, Product, Resource, Routing}

  @product_fields [:id, :company_id, :item_id, :code, :name]
  @resource_fields [:id, :company_id, :code, :name, :kind]
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

  @doc "Defines a physical resource that a logical operation may allow."
  def create_resource(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    with :ok <- live_company(scope, company_id) do
      attrs = %{
        company_id: company_id,
        code: value(attrs, :code),
        name: value(attrs, :name),
        kind: value(attrs, :kind)
      }

      insert(Resource.changeset(attrs), @resource_fields)
    end
  end

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
  `sequence`, `inputs` and `outputs` (item IDs defined in the Formula/BOM),
  and nonempty `allowed_resource_ids`. Config is versioned with the revision.
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
      case Inventory.get_item(scope, company_id, id) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp each_unit(scope, company_id, ids) do
    Enum.reduce_while(Enum.uniq(ids), :ok, fn id, _ ->
      case Inventory.get_unit(scope, company_id, id) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp each_resource(scope, company_id, ids) do
    Enum.reduce_while(Enum.uniq(ids), :ok, fn id, _ ->
      case get_resource(scope, company_id, id) do
        {:ok, _} -> {:cont, :ok}
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
end
