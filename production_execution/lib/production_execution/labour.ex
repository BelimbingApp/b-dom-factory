defmodule Bilimbi.Factory.ProductionExecution.Labour do
  @moduledoc false

  # Time a company user works on an order, optionally on one of its runs, in
  # one of the company's labour roles. An entry is opened by clocking in and
  # closed once by clocking out, or recorded with both times; any other change
  # is a correction that names the entry it replaces. A worker has at most one
  # open entry, and a worker's current entries never overlap.

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Core.User
  alias Bilimbi.Factory.ProductionExecution.Capture
  alias Bilimbi.Factory.ProductionExecution.CaptureCodes
  alias Bilimbi.Factory.ProductionExecution.Schemas.{Execution, LabourRole}

  schema "factory_labour_entries" do
    field(:company_id, :integer)
    field(:request_id, :string)
    field(:request_fingerprint, :string)
    field(:order_id, :integer)
    field(:execution_id, :integer)
    field(:worker_user_id, :integer)
    field(:role_id, :integer)
    field(:started_at, :utc_datetime_usec)
    field(:stopped_at, :utc_datetime_usec)
    field(:note, :string)
    field(:recorded_by_type, :string)
    field(:recorded_by_id, :integer)
    field(:recorded_by_acting_for_user_id, :integer)
    field(:stopped_by_type, :string)
    field(:stopped_by_id, :integer)
    field(:stopped_by_acting_for_user_id, :integer)
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
    :worker_user_id,
    :role_id,
    :started_at,
    :stopped_at,
    :note,
    :recorded_by_type,
    :recorded_by_id,
    :recorded_by_acting_for_user_id,
    :stopped_by_type,
    :stopped_by_id,
    :stopped_by_acting_for_user_id,
    :corrects_id,
    :correction_reason
  ]

  @required [
    :company_id,
    :request_id,
    :request_fingerprint,
    :order_id,
    :worker_user_id,
    :role_id,
    :started_at,
    :recorded_by_type,
    :recorded_by_id
  ]

  @read_fields [:id, :inserted_at | @fields -- [:company_id, :request_fingerprint]]

  def insert!(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> Repo.insert!()
    |> Repo.reload!()
  end

  @doc "Closes an open entry, the one update an entry allows."
  def close!(entry, stopper, stopped_at) do
    entry
    |> change(%{
      stopped_at: stopped_at,
      stopped_by_type: stopper.recorded_by_type,
      stopped_by_id: stopper.recorded_by_id,
      stopped_by_acting_for_user_id: stopper.recorded_by_acting_for_user_id
    })
    |> Repo.update!()
  end

  def get(company_id, id) do
    case is_integer(id) && Repo.get_by(__MODULE__, id: id, company_id: company_id) do
      %__MODULE__{} = entry -> {:ok, entry}
      _ -> {:error, :labour_entry_not_found}
    end
  end

  def by_request(company_id, request_id),
    do: Repo.get_by(__MODULE__, company_id: company_id, request_id: request_id)

  def corrected?(entry),
    do: Repo.exists?(from(l in __MODULE__, where: l.corrects_id == ^entry.id))

  @doc "Serializes a worker's clocking, so two open entries cannot race in."
  def lock_worker!(company_id, worker_user_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      :erlang.phash2({:factory_labour, company_id}),
      worker_user_id
    ])
  end

  @doc "The worker's current entries (not corrected), except `except_id`."
  def current_for_worker(company_id, worker_user_id, except_id \\ nil) do
    from(l in __MODULE__,
      as: :entry,
      where: l.company_id == ^company_id and l.worker_user_id == ^worker_user_id,
      where:
        not exists(from(c in __MODULE__, where: c.corrects_id == parent_as(:entry).id, select: 1))
    )
    |> then(fn query ->
      if except_id, do: where(query, [l], l.id != ^except_id), else: query
    end)
    |> Repo.all()
  end

  @doc "A worker's time on one entry must not overlap another current entry; an open entry runs to now."
  def overlapping?(entries, started_at, stopped_at, now) do
    stop = stopped_at || now

    Enum.any?(entries, fn entry ->
      DateTime.compare(entry.started_at, stop) == :lt and
        DateTime.compare(entry.stopped_at || now, started_at) == :gt
    end)
  end

  def list(company_id, order_id) do
    entries =
      Repo.all(
        from(l in __MODULE__,
          where: l.company_id == ^company_id and l.order_id == ^order_id,
          order_by: [asc: l.started_at, asc: l.id]
        )
      )

    corrected_by = Map.new(entries, &{&1.corrects_id, &1.id})
    Enum.map(entries, &read(&1, Map.get(corrected_by, &1.id)))
  end

  def read(entry, corrected_by_id \\ nil) do
    entry
    |> Map.take(@read_fields)
    |> Map.put(:corrected_by_id, corrected_by_id)
    |> Map.put(:seconds, seconds(entry))
  end

  @doc "Totals of the current entries: closed time per run and per worker, and those still open."
  def summary(entries) do
    current = Enum.filter(entries, &is_nil(&1.corrected_by_id))
    closed = Enum.filter(current, & &1.stopped_at)

    %{
      total_seconds: closed |> Enum.map(& &1.seconds) |> Enum.sum(),
      open: Enum.filter(current, &is_nil(&1.stopped_at)),
      runs: totals(closed, :execution_id),
      workers: totals(closed, :worker_user_id)
    }
  end

  defp totals(entries, key) do
    entries
    |> Enum.group_by(&Map.fetch!(&1, key))
    |> Enum.map(fn {value, grouped} ->
      %{
        key => value,
        seconds: grouped |> Enum.map(& &1.seconds) |> Enum.sum(),
        entries: length(grouped)
      }
    end)
    |> Enum.sort_by(&{is_nil(Map.fetch!(&1, key)), Map.fetch!(&1, key)})
  end

  defp seconds(%{stopped_at: nil}), do: nil
  defp seconds(entry), do: DateTime.diff(entry.stopped_at, entry.started_at, :second)

  # ============================================================================
  # Validation
  # ============================================================================

  @doc """
  Validates a new entry for `worker_user_id` on `order`. `times` is `:now`
  for a clock-in, or `:given` for an entry recorded with a past start and
  stop time.
  """
  def validate_entry(scope, company_id, order, worker_user_id, attrs, times) do
    now = DateTime.utc_now()

    with {:ok, request_id} <- Capture.request_id(Capture.value(attrs, :request_id)),
         {:ok, _worker} <- worker(scope, company_id, worker_user_id),
         {:ok, role} <- role(company_id, Capture.value(attrs, :role_id)),
         {:ok, execution_id} <- run(company_id, order.id, Capture.value(attrs, :execution_id)),
         {:ok, note} <- field(Capture.optional_text(Capture.value(attrs, :note)), :invalid_note),
         {:ok, started_at, stopped_at} <- entry_times(times, attrs, now) do
      request = %{
        request_id: request_id,
        order_id: order.id,
        execution_id: execution_id,
        worker_user_id: worker_user_id,
        role_id: role.id,
        note: note
      }

      # A clock-in's time is the server's, so a retry that repeats it matches.
      timing = if times == :now, do: :now, else: {started_at, stopped_at}

      {:ok,
       request
       |> Map.merge(%{
         started_at: started_at,
         stopped_at: stopped_at,
         request_fingerprint: Capture.fingerprint({:labour, request, timing})
       })}
    end
  end

  @doc "Validates a correction of `entry`; anything not given keeps the entry's value."
  def validate_correction(company_id, entry, attrs) do
    now = DateTime.utc_now()
    given? = &(Map.has_key?(attrs, &1) or Map.has_key?(attrs, Atom.to_string(&1)))
    pick = &if(given?.(&1), do: Capture.value(attrs, &1), else: Map.fetch!(entry, &1))
    role_id = pick.(:role_id)

    with {:ok, request_id} <- Capture.request_id(Capture.value(attrs, :request_id)),
         {:ok, correction_reason} <-
           field(
             Capture.required_text(Capture.value(attrs, :correction_reason)),
             :correction_reason_required
           ),
         {:ok, role} <-
           if(role_id == entry.role_id,
             do: CaptureCodes.get(LabourRole, company_id, role_id, :labour_role_not_found),
             else: role(company_id, role_id)
           ),
         {:ok, execution_id} <- run(company_id, entry.order_id, pick.(:execution_id)),
         {:ok, note} <- field(Capture.optional_text(pick.(:note)), :invalid_note),
         {:ok, started_at, stopped_at} <-
           times(pick.(:started_at), pick.(:stopped_at), now, true) do
      request = %{
        request_id: request_id,
        order_id: entry.order_id,
        execution_id: execution_id,
        worker_user_id: entry.worker_user_id,
        role_id: role.id,
        started_at: started_at,
        stopped_at: stopped_at,
        note: note,
        corrects_id: entry.id,
        correction_reason: correction_reason
      }

      {:ok,
       Map.put(request, :request_fingerprint, Capture.fingerprint({:labour_correction, request}))}
    end
  end

  defp entry_times(:now, attrs, now) do
    if is_nil(Capture.value(attrs, :started_at)) and is_nil(Capture.value(attrs, :stopped_at)),
      do: {:ok, now, nil},
      else: {:error, :invalid_labour_times}
  end

  defp entry_times(:given, attrs, now),
    do: times(Capture.value(attrs, :started_at), Capture.value(attrs, :stopped_at), now, false)

  defp times(%DateTime{} = started_at, stopped_at, now, open_allowed?) do
    cond do
      DateTime.compare(started_at, now) == :gt -> {:error, :invalid_labour_times}
      is_nil(stopped_at) and open_allowed? -> {:ok, started_at, nil}
      not is_struct(stopped_at, DateTime) -> {:error, :invalid_labour_times}
      DateTime.compare(stopped_at, now) == :gt -> {:error, :invalid_labour_times}
      DateTime.compare(stopped_at, started_at) != :gt -> {:error, :invalid_labour_times}
      true -> {:ok, started_at, stopped_at}
    end
  end

  defp times(_started_at, _stopped_at, _now, _open_allowed?), do: {:error, :invalid_labour_times}

  defp worker(scope, company_id, user_id) when is_integer(user_id) do
    case User.get_user(scope, company_id, user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :company_not_found} = error -> error
      {:error, _} -> {:error, :worker_not_found}
    end
  end

  defp worker(_scope, _company_id, _user_id), do: {:error, :worker_not_found}

  defp role(company_id, id),
    do:
      CaptureCodes.active(
        LabourRole,
        company_id,
        id,
        :labour_role_not_found,
        :labour_role_inactive
      )

  defp run(_company_id, _order_id, nil), do: {:ok, nil}

  defp run(company_id, order_id, execution_id) when is_integer(execution_id) do
    if Repo.exists?(
         from(e in Execution,
           where:
             e.id == ^execution_id and e.company_id == ^company_id and e.order_id == ^order_id
         )
       ),
       do: {:ok, execution_id},
       else: {:error, :execution_not_found}
  end

  defp run(_company_id, _order_id, _execution_id), do: {:error, :execution_not_found}

  defp field({:ok, value}, _error), do: {:ok, value}
  defp field(:error, error), do: {:error, error}
end
