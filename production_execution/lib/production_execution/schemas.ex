defmodule Bilimbi.Factory.ProductionExecution.Schemas.Order do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_production_orders" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:kind, :string)
    field(:product_id, :integer)
    field(:formula_version, :integer)
    field(:routing_version, :integer)
    field(:demand_ref, :string)
    timestamps(type: :naive_datetime)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :company_id,
      :code,
      :kind,
      :product_id,
      :formula_version,
      :routing_version,
      :demand_ref
    ])
    |> validate_required([
      :company_id,
      :code,
      :kind,
      :product_id,
      :formula_version,
      :routing_version
    ])
    |> validate_inclusion(:kind, ["order", "batch"])
    |> validate_number(:formula_version, greater_than: 0)
    |> validate_number(:routing_version, greater_than: 0)
    |> unique_constraint([:company_id, :code])
  end
end

defmodule Bilimbi.Factory.ProductionExecution.Schemas.Execution do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_operation_executions" do
    field(:company_id, :integer)
    field(:order_id, :integer)
    field(:request_id, :string)
    field(:request_fingerprint, :string)
    field(:source, :string)
    field(:operation_code, :string)
    field(:resource_id, :integer)
    field(:operator_type, :string)
    field(:operator_id, :integer)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:inputs, {:array, :map})
    field(:outputs, {:array, :map})
    field(:variance, :map)
    field(:evidence, :string)
    field(:inventory_transaction_id, :integer)
    field(:formula_version, :integer)
    field(:routing_version, :integer)
    timestamps(type: :naive_datetime, updated_at: false)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :company_id,
      :order_id,
      :request_id,
      :request_fingerprint,
      :source,
      :operation_code,
      :resource_id,
      :operator_type,
      :operator_id,
      :started_at,
      :completed_at,
      :inputs,
      :outputs,
      :variance,
      :evidence,
      :inventory_transaction_id,
      :formula_version,
      :routing_version
    ])
    |> validate_required([
      :company_id,
      :order_id,
      :request_id,
      :request_fingerprint,
      :source,
      :operation_code,
      :resource_id,
      :operator_type,
      :operator_id,
      :started_at,
      :completed_at,
      :inputs,
      :outputs,
      :evidence,
      :inventory_transaction_id,
      :formula_version,
      :routing_version
    ])
    |> unique_constraint([:company_id, :request_id])
    |> validate_inclusion(:source, ["live", "import"])
  end
end
