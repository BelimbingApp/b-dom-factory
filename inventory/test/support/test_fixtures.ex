defmodule Bilimbi.Factory.Inventory.TestFixtures do
  @moduledoc """
  Temporary Inventory tables for public-API tests.

  They exercise query behaviour and the constraints the API relies on. Exact
  PostgreSQL compatibility of the migrations is covered by Core
  Compatibility's migration and verification tests, which run every mounted
  module's migrations and schema contract.
  """

  alias Bilimbi.Base.Repo
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyTestFixtures
  alias Ecto.Adapters.SQL

  def create_inventory_tables! do
    apply(CompanyTestFixtures, :create_company_identity_tables!, [])

    Enum.each(
      [
        """
        CREATE TEMPORARY TABLE commerce_inventory_items (
          id bigserial PRIMARY KEY,
          company_id bigint NOT NULL REFERENCES companies (id),
          category_id bigint,
          product_template_id bigint,
          sku varchar(255) NOT NULL,
          status varchar(255) NOT NULL DEFAULT 'draft',
          title varchar(255) NOT NULL,
          description text,
          quantity_on_hand integer NOT NULL DEFAULT 1,
          storage_location varchar(255),
          notes text,
          unit_cost_amount bigint,
          target_price_amount bigint,
          currency_code char(3) NOT NULL DEFAULT 'MYR',
          created_at timestamp(0) without time zone,
          updated_at timestamp(0) without time zone,
          CONSTRAINT commerce_inventory_items_company_id_sku_unique UNIQUE (company_id, sku)
        ) ON COMMIT PRESERVE ROWS
        """,
        """
        CREATE TEMPORARY TABLE factory_inventory_units (
          id bigserial PRIMARY KEY,
          company_id bigint NOT NULL REFERENCES companies (id),
          code varchar(32) NOT NULL,
          name varchar(255) NOT NULL,
          created_at timestamp(0) without time zone NOT NULL,
          updated_at timestamp(0) without time zone NOT NULL,
          CONSTRAINT factory_inventory_units_company_id_code_unique UNIQUE (company_id, code)
        ) ON COMMIT PRESERVE ROWS
        """,
        """
        CREATE TEMPORARY TABLE factory_inventory_locations (
          id bigserial PRIMARY KEY,
          company_id bigint NOT NULL REFERENCES companies (id),
          code varchar(64) NOT NULL,
          name varchar(255) NOT NULL,
          created_at timestamp(0) without time zone NOT NULL,
          updated_at timestamp(0) without time zone NOT NULL,
          CONSTRAINT factory_inventory_locations_company_id_code_unique UNIQUE (company_id, code)
        ) ON COMMIT PRESERVE ROWS
        """,
        """
        CREATE TEMPORARY TABLE factory_inventory_materials (
          id bigserial PRIMARY KEY,
          company_id bigint NOT NULL REFERENCES companies (id),
          item_id bigint NOT NULL REFERENCES commerce_inventory_items (id),
          native_unit_id bigint NOT NULL REFERENCES factory_inventory_units (id),
          created_at timestamp(0) without time zone NOT NULL,
          updated_at timestamp(0) without time zone NOT NULL,
          CONSTRAINT factory_inventory_materials_item_id_unique UNIQUE (item_id)
        ) ON COMMIT PRESERVE ROWS
        """,
        """
        CREATE TEMPORARY TABLE factory_inventory_unit_conversions (
          id bigserial PRIMARY KEY,
          company_id bigint NOT NULL REFERENCES companies (id),
          material_id bigint NOT NULL REFERENCES factory_inventory_materials (id),
          unit_id bigint NOT NULL REFERENCES factory_inventory_units (id),
          version integer NOT NULL,
          factor numeric(24, 12) NOT NULL,
          created_at timestamp(0) without time zone NOT NULL,
          CONSTRAINT factory_inventory_unit_conversions_material_unit_version_unique
            UNIQUE (material_id, unit_id, version),
          CONSTRAINT factory_inventory_unit_conversions_factor_positive CHECK (factor > 0),
          CONSTRAINT factory_inventory_unit_conversions_version_positive CHECK (version > 0)
        ) ON COMMIT PRESERVE ROWS
        """
      ],
      &SQL.query!(Repo, &1, [])
    )
  end

  def insert_tenant!(attributes) do
    apply(CompanyTestFixtures, :insert_tenant!, [attributes])
  end

  def insert_company!(attributes) do
    apply(CompanyTestFixtures, :insert_company!, [attributes])
  end

  def soft_delete_company!(company_id) do
    SQL.query!(
      Repo,
      "UPDATE companies SET deleted_at = '2026-09-26 12:00:00' WHERE id = $1",
      [company_id]
    )
  end
end
