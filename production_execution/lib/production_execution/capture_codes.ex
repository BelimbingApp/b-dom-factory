defmodule Bilimbi.Factory.ProductionExecution.CaptureCodes do
  @moduledoc false

  # A company's code lists for shop-floor capture, such as its wastage
  # reasons: each entry is a code (upper-cased, unique in the company and
  # fixed once created, so recorded history keeps its meaning), a label, and
  # whether it is offered for new records. Which entries exist is the
  # company's configuration; nothing in code names one.

  import Ecto.Query
  import Ecto.Changeset
  alias Bilimbi.Base.Repo

  @fields [:id, :code, :label, :active]

  def list(schema, company_id, opts) do
    opts = Keyword.validate!(opts, active: nil)

    schema
    |> where([row], row.company_id == ^company_id)
    |> then(fn query ->
      case opts[:active] do
        nil -> query
        active -> where(query, [row], row.active == ^active)
      end
    end)
    |> order_by([row], asc: row.code)
    |> Repo.all()
    |> Enum.map(&read/1)
  end

  def get(schema, company_id, id, not_found) do
    case is_integer(id) && Repo.get_by(schema, id: id, company_id: company_id) do
      row when is_struct(row, schema) -> {:ok, read(row)}
      _ -> {:error, not_found}
    end
  end

  @doc "An entry that may be used for a new record."
  def active(schema, company_id, id, not_found, inactive) do
    case get(schema, company_id, id, not_found) do
      {:ok, %{active: true} = row} -> {:ok, row}
      {:ok, _inactive} -> {:error, inactive}
      error -> error
    end
  end

  def create(schema, company_id, attrs) when is_map(attrs) do
    schema
    |> struct(company_id: company_id)
    |> cast(attrs, [:code, :label, :active])
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:label, &String.trim/1)
    |> validations(schema)
    |> Repo.insert()
    |> result()
  end

  def update(schema, company_id, id, attrs, not_found) when is_map(attrs) do
    case is_integer(id) && Repo.get_by(schema, id: id, company_id: company_id) do
      row when is_struct(row, schema) ->
        row
        |> cast(attrs, [:label, :active])
        |> update_change(:label, &String.trim/1)
        |> validations(schema)
        |> Repo.update()
        |> result()

      _ ->
        {:error, not_found}
    end
  end

  def read(row), do: Map.take(row, @fields)

  defp validations(changeset, schema) do
    changeset
    |> validate_required([:code, :label, :active])
    |> validate_format(:code, ~r/^[A-Z0-9][A-Z0-9_.-]*$/,
      message: "must be letters, digits, dot, dash, or underscore"
    )
    |> validate_length(:code, max: 64)
    |> validate_length(:label, max: 255)
    |> unique_constraint(:code, name: schema.unique_code_index())
  end

  defp result({:ok, row}), do: {:ok, read(row)}
  defp result(error), do: error
end

defmodule Bilimbi.Factory.ProductionExecution.Schemas.WastageReason do
  @moduledoc false
  use Ecto.Schema

  schema "factory_wastage_reasons" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:label, :string)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def unique_code_index, do: :factory_wastage_reasons_company_id_code_unique
end

defmodule Bilimbi.Factory.ProductionExecution.Schemas.LabourRole do
  @moduledoc false
  use Ecto.Schema

  schema "factory_labour_roles" do
    field(:company_id, :integer)
    field(:code, :string)
    field(:label, :string)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def unique_code_index, do: :factory_labour_roles_company_id_code_unique
end
