defmodule Bilimbi.Factory.Inventory.Transaction do
  @moduledoc """
  Read model for one Material Transaction and its entries.

  A transaction never changes after it is recorded. `effective_at` is when the
  material moved; `recorded_at` is when Inventory recorded it, so a late entry
  keeps both. `context` holds the optional opaque references the caller
  supplied, which Inventory stores without interpreting. `posting_authority`
  names the registered module that posted production or transform context, or
  is `nil`.

  A transform's `genealogy` links each input entry to each output entry it
  produced; every other kind has none.
  """

  alias Bilimbi.Factory.Inventory.Entry
  alias Bilimbi.Factory.Inventory.ReceiptMeasurement

  @kinds [:receipt, :transfer, :consumption, :output, :correction, :transform]
  @context_keys [:operation_execution, :order_or_batch, :work_centre, :shipment, :destination]

  @enforce_keys [
    :id,
    :company_id,
    :kind,
    :request_id,
    :actor_type,
    :actor_id,
    :evidence,
    :effective_at,
    :recorded_at,
    :entries
  ]
  defstruct [
    :id,
    :company_id,
    :kind,
    :request_id,
    :actor_type,
    :actor_id,
    :evidence,
    :receipt_measurement,
    :reason,
    :corrects_transaction_id,
    :posting_authority,
    :effective_at,
    :recorded_at,
    context: %{},
    entries: [],
    genealogy: []
  ]

  @type kind :: :receipt | :transfer | :consumption | :output | :correction | :transform
  @type context_key ::
          :operation_execution | :order_or_batch | :work_centre | :shipment | :destination

  @type t :: %__MODULE__{
          id: pos_integer(),
          company_id: pos_integer(),
          kind: kind(),
          request_id: String.t(),
          actor_type: String.t(),
          actor_id: non_neg_integer(),
          evidence: String.t(),
          receipt_measurement: ReceiptMeasurement.t() | nil,
          reason: String.t() | nil,
          corrects_transaction_id: pos_integer() | nil,
          posting_authority: String.t() | nil,
          context: %{optional(context_key()) => String.t()},
          effective_at: DateTime.t(),
          recorded_at: DateTime.t(),
          entries: [Entry.t()],
          genealogy: [%{input_entry_id: pos_integer(), output_entry_id: pos_integer()}]
        }

  @doc "The transaction kinds, in the order the ledger documents them."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The opaque context references a posting may carry."
  @spec context_keys() :: [context_key()]
  def context_keys, do: @context_keys
end
