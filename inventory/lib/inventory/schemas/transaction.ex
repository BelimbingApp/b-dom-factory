defmodule Bilimbi.Factory.Inventory.Schemas.Transaction do
  @moduledoc false

  # Append-only: the database refuses UPDATE and DELETE. A correction is a new
  # row that names the one it corrects.

  use Ecto.Schema

  @type t :: %__MODULE__{}

  import Ecto.Changeset

  schema "factory_inventory_transactions" do
    field :company_id, :id
    field :kind, :string
    field :request_id, :string
    field :request_fingerprint, :string
    field :actor_type, :string
    field :actor_id, :integer
    field :evidence, :string
    field :reason, :string
    field :corrects_transaction_id, :id
    field :posting_authority, :string
    field :operation_execution_ref, :string
    field :order_or_batch_ref, :string
    field :work_centre_ref, :string
    field :shipment_ref, :string
    field :destination_ref, :string
    field :effective_at, :utc_datetime_usec
    field :recorded_at, :utc_datetime_usec
  end

  @spec creation_changeset(map()) :: Ecto.Changeset.t()
  def creation_changeset(attributes) do
    %__MODULE__{}
    |> change(attributes)
    |> unique_constraint(:request_id,
      name: :factory_inventory_transactions_company_id_request_id_unique
    )
  end
end
