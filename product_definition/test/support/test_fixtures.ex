defmodule Bilimbi.Factory.ProductDefinition.TestFixtures do
  @moduledoc "Temporary Product Definition tables for module and web tests."

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_definition_tables! do
    Enum.each(
      [
        "CREATE TEMPORARY TABLE factory_products (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), code text NOT NULL, name text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, CONSTRAINT factory_products_company_code_unique UNIQUE(company_id, code), CONSTRAINT factory_products_company_item_unique UNIQUE(company_id, item_id)) ON COMMIT PRESERVE ROWS",
        "CREATE TEMPORARY TABLE factory_resource_types (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code varchar(64) NOT NULL, name varchar(255) NOT NULL, property_definitions jsonb[] NOT NULL, retired_at timestamp(0), inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, CONSTRAINT factory_resource_types_company_code_unique UNIQUE(company_id, code), CONSTRAINT factory_resource_types_id_company_unique UNIQUE(id, company_id)) ON COMMIT PRESERVE ROWS",
        "CREATE TEMPORARY TABLE factory_resources (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, resource_type_id bigint NOT NULL, properties jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(properties) = 'object'), retired_at timestamp(0), inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, CONSTRAINT factory_resources_company_code_unique UNIQUE(company_id, code), CONSTRAINT factory_resources_resource_type_id_fkey FOREIGN KEY (resource_type_id, company_id) REFERENCES factory_resource_types (id, company_id)) ON COMMIT PRESERVE ROWS",
        "CREATE TEMPORARY TABLE factory_formula_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, lines jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, CONSTRAINT factory_formula_revisions_product_version_unique UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
        "CREATE TEMPORARY TABLE factory_routing_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, operations jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, CONSTRAINT factory_routing_revisions_product_version_unique UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS"
      ],
      &SQL.query!(Repo, &1, [])
    )
  end
end
