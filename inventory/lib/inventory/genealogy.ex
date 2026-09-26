defmodule Bilimbi.Factory.Inventory.Genealogy do
  @moduledoc false
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory.Identity
  alias Bilimbi.Factory.Inventory.Ledger
  alias Bilimbi.Factory.Inventory.Schemas
  alias Bilimbi.Factory.Inventory.Transaction

  @type trace :: %{
          root: Identity.t(),
          identities: [Identity.t()],
          links: [{pos_integer(), pos_integer(), pos_integer()}],
          receipts: [Transaction.t()]
        }

  @spec get(pos_integer(), pos_integer()) :: {:ok, Identity.t()} | {:error, :identity_not_found}
  def get(company_id, identity_id) when is_integer(identity_id) and identity_id > 0 do
    case identities(company_id, [identity_id]) do
      [identity] -> {:ok, identity}
      [] -> {:error, :identity_not_found}
    end
  end

  def get(_company_id, _identity_id), do: {:error, :identity_not_found}

  @spec trace(pos_integer(), pos_integer(), :backward | :forward) ::
          {:ok, trace()} | {:error, :identity_not_found}
  def trace(company_id, identity_id, direction) when direction in [:backward, :forward] do
    with {:ok, root} <- get(company_id, identity_id) do
      {visited, links} = walk(company_id, direction, MapSet.new([identity_id]), [identity_id], [])
      identities = identities(company_id, MapSet.to_list(visited))

      receipts = Ledger.receipts(company_id, Enum.map(identities, & &1.source_transaction_id))

      {:ok,
       %{
         root: root,
         identities: identities,
         links: links |> Enum.uniq() |> Enum.sort(),
         receipts: receipts
       }}
    end
  end

  defp identities(company_id, ids) do
    from(identity in Schemas.Identity,
      join: material in Schemas.Material,
      on: material.id == identity.material_id,
      where: identity.company_id == ^company_id and identity.id in ^ids,
      order_by: [asc: identity.id],
      select: {identity, material.item_id}
    )
    |> Repo.all()
    |> Enum.map(&model/1)
  end

  defp walk(_company_id, _direction, visited, [], links), do: {visited, links}

  defp walk(company_id, direction, visited, frontier, links) do
    query =
      from(link in Schemas.GenealogyLink,
        join: input in Schemas.Entry,
        on: input.id == link.input_entry_id,
        join: output in Schemas.Entry,
        on: output.id == link.output_entry_id,
        where: link.company_id == ^company_id,
        select: {input.identity_id, output.identity_id, link.transaction_id}
      )

    query =
      case direction do
        :backward -> from([link, input, output] in query, where: output.identity_id in ^frontier)
        :forward -> from([link, input, output] in query, where: input.identity_id in ^frontier)
      end

    edges =
      query
      |> Repo.all()
      |> Enum.reject(fn {input, output, _transaction} -> is_nil(input) or is_nil(output) end)

    next =
      edges
      |> Enum.map(fn {input, output, _transaction} ->
        if direction == :backward, do: input, else: output
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(visited, &1))

    walk(
      company_id,
      direction,
      Enum.reduce(next, visited, &MapSet.put(&2, &1)),
      next,
      edges ++ links
    )
  end

  defp model({row, item_id}) do
    %Identity{
      id: row.id,
      item_id: item_id,
      kind: if(row.kind == "lot", do: :lot, else: :unit),
      code: row.code,
      source_transaction_id: row.source_transaction_id
    }
  end
end
