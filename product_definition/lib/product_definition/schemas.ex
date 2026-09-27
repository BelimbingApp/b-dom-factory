defmodule Bilimbi.Factory.ProductDefinition.Schemas.Product do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_products" do
    field(:company_id, :integer)
    field(:item_id, :integer)
    field(:code, :string)
    field(:name, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:company_id, :item_id, :code, :name])
    |> validate_required([:company_id, :item_id, :code, :name])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint([:company_id, :code], name: :factory_products_company_code_unique)
    |> unique_constraint([:company_id, :item_id], name: :factory_products_company_item_unique)
  end
end

defmodule Bilimbi.Factory.ProductDefinition.Schemas.ResourceType do
  @moduledoc false

  # A company's own kind of resource. What kinds exist, and what each one
  # measures, is that company's configuration; nothing here names one.

  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_resource_types" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:property_definitions, {:array, :map}, default: [])
    field(:retired_at, :naive_datetime)
    timestamps(type: :naive_datetime)
  end

  @doc "Takes already normalized property definitions; the facade validates them."
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:company_id, :code, :name, :property_definitions])
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:company_id, :code, :name, :property_definitions])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint([:company_id, :code], name: :factory_resource_types_company_code_unique)
  end

  def update_changeset(type, attrs) do
    type
    |> cast(attrs, [:code, :name, :property_definitions])
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:code, :name, :property_definitions])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint([:company_id, :code], name: :factory_resource_types_company_code_unique)
  end
end

defmodule Bilimbi.Factory.ProductDefinition.Schemas.Resource do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_resources" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:resource_type_id, :integer)
    field(:properties, :map, default: %{})
    field(:retired_at, :naive_datetime)
    timestamps(type: :naive_datetime)
  end

  @doc "Takes property values already validated against the type's definitions."
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:company_id, :code, :name, :resource_type_id, :properties])
    |> validate_required([:company_id, :code, :name, :resource_type_id, :properties])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint([:company_id, :code], name: :factory_resources_company_code_unique)
    |> foreign_key_constraint(:resource_type_id, name: :factory_resources_resource_type_id_fkey)
  end

  def update_changeset(resource, attrs) do
    resource
    |> cast(attrs, [:code, :name, :properties])
    |> validate_required([:code, :name, :properties])
    |> validate_length(:code, max: 64)
    |> validate_length(:name, max: 255)
    |> unique_constraint([:company_id, :code], name: :factory_resources_company_code_unique)
  end
end

defmodule Bilimbi.Factory.ProductDefinition.Schemas.Formula do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_formula_revisions" do
    field(:company_id, :integer)
    field(:product_id, :integer)
    field(:version, :integer)
    field(:lines, {:array, :map})
    field(:process_config, :map)
    timestamps(type: :naive_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:company_id, :product_id, :version, :lines, :process_config])
    |> validate_required([:company_id, :product_id, :version, :lines, :process_config])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:product_id, :version],
      name: :factory_formula_revisions_product_version_unique
    )
  end
end

defmodule Bilimbi.Factory.ProductDefinition.Schemas.Routing do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_routing_revisions" do
    field(:company_id, :integer)
    field(:product_id, :integer)
    field(:version, :integer)
    field(:operations, {:array, :map})
    field(:process_config, :map)
    timestamps(type: :naive_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:company_id, :product_id, :version, :operations, :process_config])
    |> validate_required([:company_id, :product_id, :version, :operations, :process_config])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint([:product_id, :version],
      name: :factory_routing_revisions_product_version_unique
    )
  end
end
