defmodule Bilimbi.Factory.ProductionExecution.HoldOverride do
  use Ecto.Schema
  import Ecto.Changeset

  schema "factory_material_hold_overrides" do
    field(:company_id, :integer)
    field(:execution_id, :integer)
    field(:inventory_transaction_id, :integer)
    field(:source_transaction_id, :integer)
    field(:identity_id, :integer)
    field(:item_id, :integer)
    field(:source, :string)
    field(:actor_type, :string)
    field(:actor_id, :integer)
    field(:acting_for_user_id, :integer)
    field(:reason, :string)
    field(:evidence, :string)
    field(:occurred_at, :utc_datetime_usec)
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :company_id,
      :execution_id,
      :inventory_transaction_id,
      :source_transaction_id,
      :identity_id,
      :item_id,
      :source,
      :actor_type,
      :actor_id,
      :acting_for_user_id,
      :reason,
      :evidence,
      :occurred_at
    ])
    |> validate_required([
      :company_id,
      :execution_id,
      :inventory_transaction_id,
      :source_transaction_id,
      :identity_id,
      :item_id,
      :source,
      :actor_type,
      :actor_id,
      :reason,
      :occurred_at
    ])
    |> validate_length(:reason, min: 1)
    |> validate_inclusion(:source, ["live", "import"])
  end
end
