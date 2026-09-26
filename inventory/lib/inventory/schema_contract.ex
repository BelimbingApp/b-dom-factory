defmodule Bilimbi.Factory.Inventory.SchemaContract do
  @moduledoc """
  Pinned PostgreSQL contract for Belimbing's item master,
  `commerce_inventory_items`.

  Only the compatible baseline is described here. Units, locations,
  materials, and conversions are Bilimbi-only tables that an adopted
  Belimbing database does not yet have, so adoption does not verify them.
  """

  @behaviour Bilimbi.Base.Database.SchemaContract

  @impl true
  def tables, do: [items()]

  defp items do
    %{
      name: "commerce_inventory_items",
      columns: %{
        "id" => column(:bigint, false, {:sequence, "commerce_inventory_items_id_seq"}),
        "company_id" => column(:bigint, false),
        "category_id" => column(:bigint),
        "product_template_id" => column(:bigint),
        "sku" => column({:varchar, 255}, false),
        "status" => column({:varchar, 255}, false, {:string, "draft"}),
        "title" => column({:varchar, 255}, false),
        "description" => column(:text),
        "quantity_on_hand" => column(:integer, false, {:integer, 1}),
        "storage_location" => column({:varchar, 255}),
        "notes" => column(:text),
        "unit_cost_amount" => column(:bigint),
        "target_price_amount" => column(:bigint),
        "currency_code" => column({:char, 3}, false, {:string, "MYR"}),
        "created_at" => column({:timestamp, 0}),
        "updated_at" => column({:timestamp, 0})
      },
      indexes: %{
        "commerce_inventory_items_pkey" => index(["id"], true),
        "commerce_inventory_items_company_id_index" => index(["company_id"]),
        "commerce_inventory_items_status_index" => index(["status"]),
        "commerce_inventory_items_company_id_category_id_index" =>
          index(["company_id", "category_id"]),
        "commerce_inventory_items_company_id_product_template_id_index" =>
          index(["company_id", "product_template_id"]),
        "commerce_inventory_items_company_id_status_index" => index(["company_id", "status"]),
        "commerce_inventory_items_company_id_created_at_index" =>
          index(["company_id", "created_at"]),
        "commerce_inventory_items_company_id_sku_unique" => index(["company_id", "sku"], true)
      },
      foreign_keys: %{
        "commerce_inventory_items_company_id_foreign" =>
          foreign_key("company_id", "companies", "id", :nothing)
      }
    }
  end

  defp column(type, nullable \\ true, default \\ nil) do
    %{type: type, nullable: nullable, default: default}
  end

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}

  defp foreign_key(column, table, target_column, on_delete) do
    %{columns: [column], references: {table, [target_column]}, on_delete: on_delete}
  end
end
