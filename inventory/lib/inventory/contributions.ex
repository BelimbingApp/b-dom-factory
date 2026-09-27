defmodule Bilimbi.Factory.Inventory.Contributions do
  @moduledoc false

  # Belimbing's item master capabilities, kept under their durable keys so
  # grants in an adopted database still name a declared capability, and the
  # company settings the item master reads (`Inventory.item_settings/2`).

  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @capabilities [
    "commerce.inventory.item.create",
    "commerce.inventory.item.list",
    "commerce.inventory.item.update",
    "commerce.inventory.item.view",
    "commerce.inventory.manage"
  ]

  @item_statuses_key "factory.inventory.item_statuses"
  @default_currency_key "factory.inventory.default_currency_code"

  @doc "The setting naming a company's item status vocabulary."
  @spec item_statuses_key() :: String.t()
  def item_statuses_key, do: @item_statuses_key

  @doc "The setting naming a company's default item currency."
  @spec default_currency_key() :: String.t()
  def default_currency_key, do: @default_currency_key

  @impl true
  def contributions do
    %{
      settings: %{
        # Both default to nil on purpose: the vocabulary and the currency are
        # a company's configuration, never Inventory's. Unconfigured, any
        # non-blank status is accepted and a currency must be given per item.
        definitions: %{
          @item_statuses_key => %{
            type: :array,
            scopes: [:tenant, :company],
            default: nil,
            nullable: true,
            label: "Item statuses",
            help:
              "The statuses an item may hold, in order; the first is the default. " <>
                "Unset, any status is accepted."
          },
          @default_currency_key => %{
            type: :string,
            scopes: [:tenant, :company],
            default: nil,
            nullable: true,
            label: "Default item currency",
            help:
              "ISO 4217 code an item takes when none is given. Unset, each item names its own."
          }
        }
      },
      authz: %{
        domains: %{
          "commerce" => "Commerce, catalog, inventory, marketplace, and sales operations"
        },
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      }
    }
  end
end
