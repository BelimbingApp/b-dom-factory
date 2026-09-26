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
    |> unique_constraint([:company_id, :code], name: :factory_products_company_code_unique)
    |> unique_constraint([:company_id, :item_id], name: :factory_products_company_item_unique)
  end
end

defmodule Bilimbi.Factory.ProductDefinition.Schemas.Resource do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_resources" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:kind, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:company_id, :code, :name, :kind])
    |> validate_required([:company_id, :code, :name, :kind])
    |> validate_inclusion(:kind, ["work_centre", "machine", "line", "station"])
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
