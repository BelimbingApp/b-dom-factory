defmodule Bilimbi.Factory.ProductionExecution.Schemas.MeasurementType do
  @moduledoc false
  use Ecto.Schema

  schema "factory_measurement_types" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:label, :string)
    field(:value_type, :string)
    field(:unit, :string)
    field(:minimum, :decimal)
    field(:maximum, :decimal)
    field(:target, :decimal)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end
end

defmodule Bilimbi.Factory.ProductionExecution.Measurement do
  @moduledoc false

  # A value measured on a run's output, against one of the company's
  # measurement types. A type is one property definition in Inventory's
  # shape (`Inventory.PropertyDefinition`: label, value type, and a unit for
  # a numeric value), so a measured value is validated exactly as a material
  # property is, plus optional minimum, maximum, and target for a numeric
  # type. A measurement keeps the limits it was judged against and whether it
  # fell outside them (inclusive limits); nil means it had none to judge.

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory.PropertyDefinition
  alias Bilimbi.Factory.ProductionExecution.Capture
  alias Bilimbi.Factory.ProductionExecution.Schemas.MeasurementType

  schema "factory_measurements" do
    field(:company_id, :integer)
    field(:request_id, :string)
    field(:request_fingerprint, :string)
    field(:order_id, :integer)
    field(:execution_id, :integer)
    field(:identity_id, :integer)
    field(:measurement_type_id, :integer)
    field(:value, :string)
    field(:unit, :string)
    field(:minimum, :decimal)
    field(:maximum, :decimal)
    field(:target, :decimal)
    field(:out_of_range, :boolean)
    field(:note, :string)
    field(:measured_at, :utc_datetime_usec)
    field(:recorded_by_type, :string)
    field(:recorded_by_id, :integer)
    field(:recorded_by_acting_for_user_id, :integer)
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
    :identity_id,
    :measurement_type_id,
    :value,
    :unit,
    :minimum,
    :maximum,
    :target,
    :out_of_range,
    :note,
    :measured_at,
    :recorded_by_type,
    :recorded_by_id,
    :recorded_by_acting_for_user_id,
    :corrects_id,
    :correction_reason
  ]

  @required [
    :company_id,
    :request_id,
    :request_fingerprint,
    :order_id,
    :execution_id,
    :measurement_type_id,
    :value,
    :measured_at,
    :recorded_by_type,
    :recorded_by_id
  ]

  @read_fields [:id, :inserted_at | @fields -- [:company_id, :request_fingerprint]]
  @type_fields [:id, :code, :label, :value_type, :unit, :minimum, :maximum, :target, :active]
  @numeric ~w(integer decimal)

  # ============================================================================
  # Measurement types
  # ============================================================================

  def list_types(company_id, opts) do
    opts = Keyword.validate!(opts, active: nil)

    MeasurementType
    |> where([t], t.company_id == ^company_id)
    |> then(fn query ->
      if is_nil(opts[:active]), do: query, else: where(query, [t], t.active == ^opts[:active])
    end)
    |> order_by([t], asc: t.code)
    |> Repo.all()
    |> Enum.map(&read_type/1)
  end

  def get_type(company_id, id) do
    case is_integer(id) && Repo.get_by(MeasurementType, id: id, company_id: company_id) do
      %MeasurementType{} = type -> {:ok, read_type(type)}
      _ -> {:error, :measurement_type_not_found}
    end
  end

  @doc "Creates a type: its code, value type, and unit are fixed once created."
  def create_type(company_id, attrs) do
    with {:ok, fields} <-
           type_fields(attrs, [:code, :label, :value_type, :unit, :minimum, :maximum, :target]),
         {:ok, _definition} <- definition(fields) do
      %MeasurementType{company_id: company_id}
      |> type_changeset(fields, [
        :code,
        :label,
        :value_type,
        :unit,
        :minimum,
        :maximum,
        :target,
        :active
      ])
      |> Repo.insert()
      |> type_result()
    end
  end

  @doc "Changes a type's label, limits, or active; recorded measurements keep the limits they were judged against."
  def update_type(company_id, id, attrs) do
    case is_integer(id) && Repo.get_by(MeasurementType, id: id, company_id: company_id) do
      %MeasurementType{} = type ->
        with {:ok, fields} <- type_fields(attrs, [:label, :minimum, :maximum, :target]),
             merged =
               Map.merge(
                 Map.take(type, [:code, :label, :value_type, :unit, :minimum, :maximum, :target]),
                 fields
               ),
             {:ok, _definition} <- definition(merged) do
          type
          |> type_changeset(fields, [:label, :minimum, :maximum, :target, :active])
          |> Repo.update()
          |> type_result()
        end

      _ ->
        {:error, :measurement_type_not_found}
    end
  end

  def read_type(type), do: Map.take(type, @type_fields)

  # Limits are decimals; blank means none.
  defp type_fields(attrs, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      given? = Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
      value = Capture.value(attrs, key)

      cond do
        not given? ->
          {:cont, {:ok, acc}}

        key in [:minimum, :maximum, :target] ->
          case limit(value) do
            {:ok, decimal} -> {:cont, {:ok, Map.put(acc, key, decimal)}}
            :error -> {:halt, {:error, :invalid_measurement_limits}}
          end

        key == :unit ->
          {:cont, {:ok, Map.put(acc, key, blank_nil(value))}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
    |> case do
      {:ok, fields} ->
        fields =
          if Map.has_key?(attrs, :active) or Map.has_key?(attrs, "active"),
            do: Map.put(fields, :active, Capture.value(attrs, :active)),
            else: fields

        {:ok, fields}

      error ->
        error
    end
  end

  defp limit(value) when value in [nil, ""], do: {:ok, nil}
  defp limit(value), do: Capture.decimal(value)

  defp blank_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_nil(value), do: value

  # A type is one property definition in Inventory's shape, and its limits
  # belong to a numeric type, in order.
  defp definition(fields) do
    limits = Enum.reject([fields[:minimum], fields[:maximum], fields[:target]], &is_nil/1)

    with {:ok, [definition]} <-
           PropertyDefinition.normalize_definitions([
             %{
               "key" => "value",
               "label" => fields[:label],
               "value_type" => fields[:value_type],
               "unit" => fields[:unit],
               "required" => true
             }
           ]),
         true <- limits == [] or definition["value_type"] in @numeric,
         true <-
           is_nil(fields[:minimum]) or is_nil(fields[:maximum]) or
             not Decimal.gt?(fields[:minimum], fields[:maximum]) do
      {:ok, definition}
    else
      {:error, _} -> {:error, :invalid_measurement_type}
      false -> {:error, :invalid_measurement_limits}
    end
  end

  defp type_changeset(type, fields, permitted) do
    type
    |> cast(fields, permitted)
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:label, &String.trim/1)
    |> validate_required([:code, :label, :value_type, :active])
    |> validate_format(:code, ~r/^[A-Z0-9][A-Z0-9_.-]*$/,
      message: "must be letters, digits, dot, dash, or underscore"
    )
    |> validate_length(:code, max: 64)
    |> validate_length(:label, max: 255)
    |> unique_constraint(:code, name: :factory_measurement_types_company_id_code_unique)
  end

  defp type_result({:ok, type}), do: {:ok, read_type(type)}
  defp type_result(error), do: error

  # ============================================================================
  # Measurements
  # ============================================================================

  def insert!(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> Repo.insert!()
    |> Repo.reload!()
  end

  def get(company_id, id) do
    case is_integer(id) && Repo.get_by(__MODULE__, id: id, company_id: company_id) do
      %__MODULE__{} = measurement -> {:ok, measurement}
      _ -> {:error, :measurement_not_found}
    end
  end

  def by_request(company_id, request_id),
    do: Repo.get_by(__MODULE__, company_id: company_id, request_id: request_id)

  def corrected?(measurement),
    do: Repo.exists?(from(m in __MODULE__, where: m.corrects_id == ^measurement.id))

  def list(company_id, execution_id) do
    measurements =
      Repo.all(
        from(m in __MODULE__,
          where: m.company_id == ^company_id and m.execution_id == ^execution_id,
          order_by: [asc: m.id]
        )
      )

    corrected_by = Map.new(measurements, &{&1.corrects_id, &1.id})
    Enum.map(measurements, &read(&1, Map.get(corrected_by, &1.id)))
  end

  def read(measurement, corrected_by_id \\ nil) do
    measurement
    |> Map.take(@read_fields)
    |> Map.put(:corrected_by_id, corrected_by_id)
  end

  @doc "Validates a measurement of one of the run's output identities, or of the run's output as a whole when `identity_id` is nil."
  def validate_record(company_id, execution, transaction, attrs) do
    now = DateTime.utc_now()
    identity_id = Capture.value(attrs, :identity_id)

    with {:ok, request_id} <- Capture.request_id(Capture.value(attrs, :request_id)),
         {:ok, type} <- active_type(company_id, Capture.value(attrs, :measurement_type_id)),
         :ok <- output_identity(transaction, identity_id),
         {:ok, value} <- value(type, Capture.value(attrs, :value)),
         {:ok, note} <- field(Capture.optional_text(Capture.value(attrs, :note)), :invalid_note),
         {:ok, measured_at} <-
           field(Capture.past_time(Capture.value(attrs, :measured_at), now), :invalid_measured_at),
         :ok <- not_before_run(measured_at, execution) do
      request = %{
        request_id: request_id,
        order_id: execution.order_id,
        execution_id: execution.id,
        identity_id: identity_id,
        measurement_type_id: type.id,
        value: value,
        note: note
      }

      limits = Map.take(type, [:unit, :minimum, :maximum, :target])

      {:ok,
       request
       |> Map.merge(limits)
       |> Map.merge(%{
         measured_at: measured_at,
         out_of_range: out_of_range(type.value_type, value, limits),
         request_fingerprint:
           Capture.fingerprint({:measurement, request, Capture.value(attrs, :measured_at)})
       })}
    end
  end

  @doc "Validates a correction: a new value or note, judged against the corrected measurement's limits."
  def validate_correction(company_id, measurement, attrs) do
    note =
      if Map.has_key?(attrs, :note) or Map.has_key?(attrs, "note"),
        do: Capture.value(attrs, :note),
        else: measurement.note

    with {:ok, request_id} <- Capture.request_id(Capture.value(attrs, :request_id)),
         {:ok, correction_reason} <-
           field(
             Capture.required_text(Capture.value(attrs, :correction_reason)),
             :correction_reason_required
           ),
         {:ok, type} <- get_type(company_id, measurement.measurement_type_id),
         {:ok, value} <- value(%{type | unit: measurement.unit}, Capture.value(attrs, :value)),
         {:ok, note} <- field(Capture.optional_text(note), :invalid_note) do
      limits = Map.take(measurement, [:unit, :minimum, :maximum, :target])

      request =
        measurement
        |> Map.take([:order_id, :execution_id, :identity_id, :measurement_type_id, :measured_at])
        |> Map.merge(limits)
        |> Map.merge(%{
          request_id: request_id,
          value: value,
          note: note,
          out_of_range: out_of_range(type.value_type, value, limits),
          corrects_id: measurement.id,
          correction_reason: correction_reason
        })

      {:ok,
       Map.put(
         request,
         :request_fingerprint,
         Capture.fingerprint({:measurement_correction, request})
       )}
    end
  end

  defp active_type(company_id, id) do
    case get_type(company_id, id) do
      {:ok, %{active: true} = type} -> {:ok, type}
      {:ok, _inactive} -> {:error, :measurement_type_inactive}
      error -> error
    end
  end

  defp output_identity(_transaction, nil), do: :ok

  defp output_identity(transaction, identity_id) do
    if Enum.any?(
         transaction.entries,
         &(&1.role == :stock and &1.identity_id == identity_id and
             Decimal.gt?(&1.native_quantity, 0))
       ),
       do: :ok,
       else: {:error, :identity_not_run_output}
  end

  # Validated as the one property of a definition in Inventory's shape; the
  # stored text reads back as it was recorded.
  defp value(type, value) do
    definition = %{
      "key" => "value",
      "label" => type.label,
      "value_type" => type.value_type,
      "unit" => type.unit,
      "required" => true
    }

    case PropertyDefinition.validate_values([definition], %{"value" => value}) do
      {:ok, %{"value" => valid}} -> {:ok, to_string(valid)}
      {:error, _} -> {:error, :invalid_measurement_value}
    end
  end

  defp out_of_range(value_type, value, %{minimum: minimum, maximum: maximum})
       when value_type in @numeric and not (is_nil(minimum) and is_nil(maximum)) do
    decimal = Decimal.new(value)

    (not is_nil(minimum) and Decimal.lt?(decimal, minimum)) or
      (not is_nil(maximum) and Decimal.gt?(decimal, maximum))
  end

  defp out_of_range(_value_type, _value, _limits), do: nil

  defp not_before_run(measured_at, execution) do
    if DateTime.compare(measured_at, execution.started_at) == :lt,
      do: {:error, :invalid_measured_at},
      else: :ok
  end

  defp field({:ok, value}, _error), do: {:ok, value}
  defp field(:error, error), do: {:error, error}
end
