defmodule Bilimbi.Factory.Inventory.Genealogy do
  @moduledoc false
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory.Identity
  alias Bilimbi.Factory.Inventory.Ledger
  alias Bilimbi.Factory.Inventory.Schemas

  def get(company_id, identity_id) do
    case Repo.get_by(Schemas.Identity, id: identity_id, company_id: company_id) do
      nil -> {:error, :identity_not_found}
      row -> {:ok, model(row)}
    end
  end

  def trace(company_id, identity_id, direction) when direction in [:backward, :forward] do
    with {:ok, root} <- get(company_id, identity_id) do
      {visited, links} = walk(company_id, direction, MapSet.new([identity_id]), [identity_id], [])

      identities =
        from(identity in Schemas.Identity,
          where: identity.company_id == ^company_id and identity.id in ^MapSet.to_list(visited),
          order_by: [asc: identity.id]
        )
        |> Repo.all()
        |> Enum.map(&model/1)

      receipts =
        identities
        |> Enum.map(& &1.source_transaction_id)
        |> Enum.uniq()
        |> Enum.flat_map(fn id ->
          case Ledger.get(company_id, id) do
            {:ok, %{kind: :receipt} = receipt} -> [receipt]
            _ -> []
          end
        end)

      {:ok, %{root: root, identities: identities, links: Enum.sort(links), receipts: receipts}}
    end
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

  defp model(row) do
    item_id = Repo.get!(Schemas.Material, row.material_id).item_id

    %Identity{
      id: row.id,
      item_id: item_id,
      kind: if(row.kind == "lot", do: :lot, else: :unit),
      code: row.code,
      source_transaction_id: row.source_transaction_id
    }
  end
end
