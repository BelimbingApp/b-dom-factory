defmodule Bilimbi.Factory.Inventory.Ledger.Request do
  @moduledoc false

  # Validates a posting request's shape before the ledger touches the
  # database, and fingerprints it so a retry can be told from a reused
  # request ID. A failed field is a changeset error on the request; a failed
  # line names its position in the list.

  import Ecto.Changeset

  alias Bilimbi.Factory.Inventory.Transaction

  @header_types %{
    request_id: :string,
    actor_type: :string,
    actor_id: :integer,
    evidence: :string,
    effective_at: :utc_datetime_usec,
    reason: :string,
    corrects_transaction_id: :integer,
    context: :map,
    variance: :map
  }

  @line_types %{
    item_id: :integer,
    location_id: :integer,
    from_location_id: :integer,
    to_location_id: :integer,
    quantity: :decimal,
    unit_id: :integer,
    conversion_version: :integer,
    observation: :string,
    evidence: :string,
    output_role: :string
  }

  @observations ~w(measured declared counted derived)
  @text_limit 10_000
  @reference_limit 255

  @spec observations() :: [String.t()]
  def observations, do: @observations

  @spec validate(Transaction.kind(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def validate(kind, request, now) when is_map(request) do
    changeset =
      {%{}, @header_types}
      |> cast(request, Map.keys(@header_types))
      |> validate_required([:request_id, :actor_type, :actor_id, :evidence])
      |> validate_length(:request_id, max: @reference_limit)
      |> validate_length(:actor_type, max: 64)
      |> validate_number(:actor_id, greater_than_or_equal_to: 0)
      |> validate_length(:evidence, max: @text_limit)
      |> validate_change(:effective_at, &not_after(&1, &2, now))
      |> validate_change(:context, &context/2)
      |> validate_kind(kind)

    {changeset, lists} =
      Enum.reduce(list_fields(kind), {changeset, %{}}, fn {field, line_kind},
                                                          {changeset, lists} ->
        case lines(request, field, line_kind) do
          {:ok, lines} -> {changeset, Map.put(lists, field, lines)}
          {:error, errors} -> {Enum.reduce(errors, changeset, &add_error(&2, field, &1)), lists}
        end
      end)

    with {:ok, header} <- apply_action(changeset, :validate) do
      fingerprint = fingerprint(kind, changeset.changes, lists)

      {:ok,
       header
       |> Map.put_new(:effective_at, now)
       |> Map.update(:context, %{}, &normalize_context/1)
       |> Map.merge(lists)
       |> Map.put(:fingerprint, fingerprint)}
    end
  end

  defp list_fields(:transfer), do: [lines: :transfer]
  defp list_fields(:correction), do: [lines: :adjustment]
  defp list_fields(:transform), do: [inputs: :stock, outputs: :output]
  defp list_fields(_kind), do: [lines: :stock]

  defp validate_kind(changeset, :correction) do
    changeset
    |> validate_required([:reason, :corrects_transaction_id])
    |> validate_length(:reason, max: @text_limit)
    |> absent(:variance)
  end

  defp validate_kind(changeset, :transform) do
    changeset
    |> absent(:reason)
    |> absent(:corrects_transaction_id)
    |> validate_change(:variance, &variance/2)
  end

  defp validate_kind(changeset, _kind) do
    changeset
    |> absent(:reason)
    |> absent(:corrects_transaction_id)
    |> absent(:variance)
  end

  defp absent(changeset, field) do
    if get_change(changeset, field) == nil,
      do: changeset,
      else: add_error(changeset, field, "is not accepted for this transaction")
  end

  defp not_after(field, at, now) do
    if DateTime.after?(at, now),
      do: [{field, "cannot be later than the time it is recorded"}],
      else: []
  end

  defp context(:context, context) do
    known = Transaction.context_keys() |> Enum.flat_map(&[&1, Atom.to_string(&1)])

    Enum.flat_map(context, fn
      {key, value} when is_binary(value) and value != "" ->
        cond do
          key not in known -> [context: "has an unknown reference #{inspect(key)}"]
          String.length(value) > @reference_limit -> [context: "#{key} is too long"]
          true -> []
        end

      {key, _value} ->
        [context: "#{key} must be a non-empty string"]
    end)
  end

  defp normalize_context(context) do
    Map.new(Transaction.context_keys(), &{&1, context[&1] || context[Atom.to_string(&1)]})
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp variance(:variance, variance) do
    Enum.flat_map([:evidence, :reconciliation_basis], fn key ->
      case variance[key] || variance[Atom.to_string(key)] do
        value when is_binary(value) and value != "" and byte_size(value) <= @text_limit -> []
        _other -> [variance: "needs #{key}"]
      end
    end)
  end

  @doc false
  @spec variance(map()) :: %{evidence: String.t(), reconciliation_basis: String.t()} | nil
  def variance(%{variance: variance}) when is_map(variance) do
    %{
      evidence: variance[:evidence] || variance["evidence"],
      reconciliation_basis: variance[:reconciliation_basis] || variance["reconciliation_basis"]
    }
  end

  def variance(_header), do: nil

  # ============================================================================
  # Lines
  # ============================================================================

  defp lines(request, field, line_kind) do
    case Map.get(request, field, Map.get(request, Atom.to_string(field))) do
      [_ | _] = lines ->
        results =
          lines
          |> Enum.with_index(1)
          |> Enum.map(fn {line, position} -> {position, line(line, line_kind)} end)

        case for {position, {:error, messages}} <- results,
                 message <- messages,
                 do: "line #{position}: #{message}" do
          [] -> {:ok, for({_position, {:ok, line}} <- results, do: line)}
          errors -> {:error, errors}
        end

      _missing ->
        {:error, ["needs at least one line"]}
    end
  end

  defp line(line, line_kind) when is_map(line) do
    changeset =
      {%{}, @line_types}
      |> cast(line, line_fields(line_kind))
      |> validate_required(required_line_fields(line_kind))
      |> validate_inclusion(:observation, @observations)
      |> validate_length(:evidence, max: @text_limit)
      |> validate_length(:output_role, max: 64)
      |> validate_number(:conversion_version, greater_than: 0)
      |> validate_change(:quantity, &quantity(&1, &2, line_kind))
      |> distinct_locations(line_kind)

    case apply_action(changeset, :validate) do
      {:ok, line} ->
        {:ok, line}

      {:error, changeset} ->
        {:error,
         changeset
         |> traverse_errors(fn {message, options} ->
           Enum.reduce(options, message, fn {key, value}, message ->
             String.replace(message, "%{#{key}}", to_string(value))
           end)
         end)
         |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)}
    end
  end

  defp line(_line, _line_kind), do: {:error, ["must be a map"]}

  @common [:item_id, :quantity, :unit_id, :conversion_version, :observation, :evidence]

  defp line_fields(:transfer), do: [:from_location_id, :to_location_id | @common]
  defp line_fields(:output), do: [:location_id, :output_role | @common]
  defp line_fields(_line_kind), do: [:location_id | @common]

  defp required_line_fields(:transfer),
    do: [:item_id, :from_location_id, :to_location_id, :quantity, :observation]

  defp required_line_fields(_line_kind), do: [:item_id, :location_id, :quantity, :observation]

  defp distinct_locations(changeset, :transfer) do
    from = get_field(changeset, :from_location_id)

    if from != nil and from == get_field(changeset, :to_location_id),
      do: add_error(changeset, :to_location_id, "must differ from from_location_id"),
      else: changeset
  end

  defp distinct_locations(changeset, _line_kind), do: changeset

  # numeric(24, 12): at most 12 digits either side of the point. Only a
  # correction adjusts downward, with a negative quantity.
  defp quantity(:quantity, quantity, line_kind) do
    cond do
      line_kind == :adjustment and Decimal.eq?(quantity, 0) ->
        [quantity: "must not be zero"]

      line_kind != :adjustment and not Decimal.gt?(quantity, 0) ->
        [quantity: "must be greater than 0"]

      not Decimal.eq?(Decimal.round(quantity, 12), quantity) ->
        [quantity: "has more than 12 decimal places"]

      Decimal.compare(Decimal.abs(quantity), Decimal.new("1E12")) != :lt ->
        [quantity: "is too large"]

      true ->
        []
    end
  end

  # ============================================================================
  # Fingerprint
  # ============================================================================

  # A defaulted effective time is left out, so a retry that omits it matches.
  defp fingerprint(kind, changes, lists) do
    term = {kind, normalize(changes), normalize(lists)}

    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp normalize(%Decimal{} = decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string()
  defp normalize(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), normalize(v)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value
end
