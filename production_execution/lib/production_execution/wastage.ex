defmodule Bilimbi.Factory.ProductionExecution.Wastage do
  @moduledoc false

  # Wastage recorded against a run: material drawn from stock and scrapped for
  # one of the company's wastage reasons. The facade posts it through
  # Inventory as production consumption carrying the run's context; this
  # module validates the request and keeps the append-only evidence rows.
  #
  # The scrapped material must be a stock line of the run itself, by item and
  # identity, so the draw nets into that side of the run's yield (an input
  # line's material raises input, the run's own output lowers product) and
  # the same quantity is added to waste.

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.ProductionExecution.Capture
  alias Bilimbi.Factory.ProductionExecution.CaptureCodes
  alias Bilimbi.Factory.ProductionExecution.Schemas.WastageReason

  schema "factory_wastage_records" do
    field(:company_id, :integer)
    field(:request_id, :string)
    field(:request_fingerprint, :string)
    field(:order_id, :integer)
    field(:execution_id, :integer)
    field(:reason_id, :integer)
    field(:item_id, :integer)
    field(:location_id, :integer)
    field(:identity_id, :integer)
    field(:quantity, :decimal)
    field(:unit_id, :integer)
    field(:observation, :string)
    field(:note, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:recorded_by_type, :string)
    field(:recorded_by_id, :integer)
    field(:recorded_by_acting_for_user_id, :integer)
    field(:inventory_transaction_id, :integer)
    field(:corrects_id, :integer)
    field(:correction_reason, :string)
    timestamps(type: :naive_datetime, updated_at: false)
  end

  @fields [
    :company_id,
    :request_id,
    :request_fingerprint,
    :order_id,
    :execution_id,
    :reason_id,
    :item_id,
    :location_id,
    :identity_id,
    :quantity,
    :unit_id,
    :observation,
    :note,
    :occurred_at,
    :recorded_by_type,
    :recorded_by_id,
    :recorded_by_acting_for_user_id,
    :inventory_transaction_id,
    :corrects_id,
    :correction_reason
  ]

  @read_fields [:id, :inserted_at | @fields -- [:company_id, :request_fingerprint]]

  def insert!(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(
      @fields --
        [
          :identity_id,
          :note,
          :recorded_by_acting_for_user_id,
          :inventory_transaction_id,
          :corrects_id,
          :correction_reason
        ]
    )
    |> Repo.insert!()
    |> Repo.reload!()
  end

  def get(company_id, id) do
    case is_integer(id) && Repo.get_by(__MODULE__, id: id, company_id: company_id) do
      %__MODULE__{} = record -> {:ok, record}
      _ -> {:error, :wastage_not_found}
    end
  end

  def by_request(company_id, request_id),
    do: Repo.get_by(__MODULE__, company_id: company_id, request_id: request_id)

  def corrected?(record),
    do: Repo.exists?(from(w in __MODULE__, where: w.corrects_id == ^record.id))

  @doc "The chain's first record, whose Inventory transaction each correction adjusts."
  def root(%__MODULE__{corrects_id: nil} = record), do: record
  def root(%__MODULE__{corrects_id: id}), do: __MODULE__ |> Repo.get!(id) |> root()

  @doc "Every record of a run in ID order, each marked with the record correcting it."
  def list(company_id, execution_id) do
    records =
      Repo.all(
        from(w in __MODULE__,
          where: w.company_id == ^company_id and w.execution_id == ^execution_id,
          order_by: [asc: w.id]
        )
      )

    corrected_by = Map.new(records, &{&1.corrects_id, &1.id})
    Enum.map(records, &read(&1, Map.get(corrected_by, &1.id)))
  end

  @doc "The Inventory transactions a run's wastage posted, one per chain."
  def transaction_ids(company_id, execution_id) do
    Repo.all(
      from(w in __MODULE__,
        where:
          w.company_id == ^company_id and w.execution_id == ^execution_id and
            is_nil(w.corrects_id),
        order_by: [asc: w.id],
        select: w.inventory_transaction_id
      )
    )
  end

  def read(record, corrected_by_id \\ nil) do
    record
    |> Map.take(@read_fields)
    |> Map.put(:corrected_by_id, corrected_by_id)
  end

  @doc "Validates a new wastage record against the run's posted stock lines."
  def validate_record(scope, company_id, execution, transaction, attrs) do
    now = DateTime.utc_now()

    with {:ok, request_id} <- Capture.request_id(Capture.value(attrs, :request_id)),
         {:ok, reason} <- reason(company_id, Capture.value(attrs, :reason_id)),
         {:ok, entry} <-
           run_entry(
             transaction,
             Capture.value(attrs, :item_id),
             Capture.value(attrs, :identity_id)
           ),
         {:ok, location_id} <- location(scope, company_id, Capture.value(attrs, :location_id)),
         {:ok, quantity} <- quantity(Capture.value(attrs, :quantity), :positive),
         {:ok, observation} <- observation(Capture.value(attrs, :observation)),
         {:ok, note} <- field(Capture.optional_text(Capture.value(attrs, :note)), :invalid_note),
         {:ok, occurred_at} <-
           field(Capture.past_time(Capture.value(attrs, :occurred_at), now), :invalid_occurred_at),
         :ok <- not_before_run(occurred_at, execution) do
      request = %{
        request_id: request_id,
        order_id: execution.order_id,
        execution_id: execution.id,
        reason_id: reason.id,
        item_id: entry.item_id,
        location_id: location_id,
        identity_id: entry.identity_id,
        quantity: quantity,
        unit_id: entry.native_unit.id,
        observation: observation,
        note: note
      }

      # A defaulted time is left out, so a retry that omits it matches.
      fingerprint = Capture.fingerprint({:wastage, request, Capture.value(attrs, :occurred_at)})

      {:ok,
       request
       |> Map.put(:occurred_at, occurred_at)
       |> Map.put(:request_fingerprint, fingerprint)
       |> Map.put(:reason, reason)}
    end
  end

  @doc "Validates a correction: new quantity (zero voids), reason, note, and why."
  def validate_correction(company_id, record, attrs) do
    reason_id = Capture.value(attrs, :reason_id) || record.reason_id

    note =
      if Map.has_key?(attrs, :note) or Map.has_key?(attrs, "note"),
        do: Capture.value(attrs, :note),
        else: record.note

    with {:ok, request_id} <- Capture.request_id(Capture.value(attrs, :request_id)),
         {:ok, correction_reason} <-
           field(
             Capture.required_text(Capture.value(attrs, :correction_reason)),
             :correction_reason_required
           ),
         {:ok, reason} <- correction_reason_code(company_id, reason_id, record.reason_id),
         {:ok, quantity} <- quantity(Capture.value(attrs, :quantity), :non_negative),
         {:ok, note} <- field(Capture.optional_text(note), :invalid_note) do
      request =
        record
        |> Map.take([:order_id, :execution_id, :item_id, :location_id, :identity_id, :unit_id])
        |> Map.merge(%{
          request_id: request_id,
          corrects_id: record.id,
          reason_id: reason.id,
          quantity: quantity,
          observation: record.observation,
          note: note,
          occurred_at: record.occurred_at,
          correction_reason: correction_reason
        })

      {:ok,
       request
       |> Map.put(:request_fingerprint, Capture.fingerprint({:wastage_correction, request}))
       |> Map.put(:reason, reason)
       |> Map.put(:delta, Decimal.sub(quantity, record.quantity))}
    end
  end

  def evidence(reason, note) do
    Enum.join(["Wastage #{reason.code}: #{reason.label}" | List.wrap(note)], " — ")
  end

  defp reason(company_id, id),
    do:
      CaptureCodes.active(
        WastageReason,
        company_id,
        id,
        :wastage_reason_not_found,
        :wastage_reason_inactive
      )

  # Keeping a record's reason stays valid after the reason is deactivated.
  defp correction_reason_code(company_id, id, id),
    do: CaptureCodes.get(WastageReason, company_id, id, :wastage_reason_not_found)

  defp correction_reason_code(company_id, id, _original), do: reason(company_id, id)

  defp run_entry(transaction, item_id, identity_id) do
    case Enum.find(
           transaction.entries,
           &(&1.role == :stock and is_integer(item_id) and &1.item_id == item_id and
               &1.identity_id == identity_id)
         ) do
      nil -> {:error, :wastage_material_not_in_run}
      entry -> {:ok, entry}
    end
  end

  defp location(scope, company_id, location_id) when is_integer(location_id) do
    case Inventory.get_location(scope, company_id, location_id) do
      {:ok, location} -> {:ok, location.id}
      error -> error
    end
  end

  defp location(_scope, _company_id, _location_id), do: {:error, :location_not_found}

  defp quantity(value, sign) do
    case Capture.decimal(value) do
      {:ok, decimal} ->
        cond do
          sign == :positive and Decimal.gt?(decimal, 0) -> {:ok, decimal}
          sign == :non_negative and not Decimal.negative?(decimal) -> {:ok, decimal}
          true -> {:error, :invalid_quantity}
        end

      :error ->
        {:error, :invalid_quantity}
    end
  end

  defp observation(value) do
    if value in Inventory.observations(),
      do: {:ok, value},
      else: {:error, :invalid_observation}
  end

  defp not_before_run(occurred_at, execution) do
    if DateTime.compare(occurred_at, execution.started_at) == :lt,
      do: {:error, :invalid_occurred_at},
      else: :ok
  end

  defp field({:ok, value}, _error), do: {:ok, value}
  defp field(:error, error), do: {:error, error}
end
