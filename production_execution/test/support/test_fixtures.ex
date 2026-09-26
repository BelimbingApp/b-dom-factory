defmodule Bilimbi.Factory.ProductionExecution.TestFixtures do
  @moduledoc """
  Temporary Product Definition and Production Execution tables for
  public-API tests, beside Inventory's (`mill!/0` creates those). Mirror a
  migration's constraints here when persistence changes.
  """

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  def create_production_tables! do
    for sql <- [
          "CREATE TEMPORARY TABLE factory_products (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), code text NOT NULL, name text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code), UNIQUE(company_id, item_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_resources (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, kind text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_formula_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, lines jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_routing_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, operations jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_production_orders (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, kind text NOT NULL CHECK (kind IN ('order', 'batch')), product_id bigint NOT NULL REFERENCES factory_products(id), formula_version integer NOT NULL CHECK (formula_version > 0), routing_version integer NOT NULL CHECK (routing_version > 0), demand_ref text, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_operation_executions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), order_id bigint NOT NULL REFERENCES factory_production_orders(id), request_id text NOT NULL, request_fingerprint text NOT NULL, source text NOT NULL CHECK (source IN ('live', 'import')), operation_code text NOT NULL, resource_id bigint NOT NULL REFERENCES factory_resources(id), operator_type text NOT NULL, operator_id bigint NOT NULL, started_at timestamp(6) NOT NULL, completed_at timestamp(6) NOT NULL CHECK (started_at <= completed_at), inputs jsonb[] NOT NULL, outputs jsonb[] NOT NULL, variance jsonb, evidence text NOT NULL, inventory_transaction_id bigint NOT NULL, formula_version integer NOT NULL, routing_version integer NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(company_id, request_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_material_hold_overrides (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), execution_id bigint NOT NULL REFERENCES factory_operation_executions(id), inventory_transaction_id bigint NOT NULL REFERENCES factory_inventory_transactions(id), source_transaction_id bigint NOT NULL REFERENCES factory_inventory_transactions(id), identity_id bigint NOT NULL REFERENCES factory_inventory_identities(id), item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), source text NOT NULL, actor_type text NOT NULL, actor_id bigint NOT NULL, acting_for_user_id bigint, reason text NOT NULL CHECK (length(btrim(reason)) > 0), evidence text, occurred_at timestamp(6) NOT NULL, CHECK ((source = 'live' AND evidence IS NULL) OR (source = 'import' AND length(btrim(evidence)) > 0)), UNIQUE(execution_id, identity_id)) ON COMMIT PRESERVE ROWS"
        ],
        do: SQL.query!(Repo, sql, [])

    SQL.query!(
      Repo,
      "CREATE FUNCTION pg_temp.refuse_hold_override_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'material hold overrides are immutable'; END $$",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TRIGGER hold_overrides_append_only BEFORE UPDATE OR DELETE ON factory_material_hold_overrides FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_hold_override_change()",
      []
    )

    SQL.query!(
      Repo,
      "CREATE TRIGGER hold_overrides_no_truncate BEFORE TRUNCATE ON factory_material_hold_overrides FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.refuse_hold_override_change()",
      []
    )

    :ok
  end
end
