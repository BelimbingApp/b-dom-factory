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
      ] ++ ledger_tables(),
      &SQL.query!(Repo, &1, [])
    )
  end

  # The ledger's append-only and balance triggers, as the migration creates
  # them, so tests can prove the database refuses what the API never does.
  defp ledger_tables do
    [
      """
      CREATE TEMPORARY TABLE factory_inventory_transactions (
        id bigserial PRIMARY KEY,
        company_id bigint NOT NULL REFERENCES companies (id),
        kind varchar(32) NOT NULL,
        request_id varchar(255) NOT NULL,
        request_fingerprint bytea NOT NULL,
        actor_type varchar(64) NOT NULL,
        actor_id bigint NOT NULL,
        evidence text NOT NULL,
        reason text,
        corrects_transaction_id bigint REFERENCES factory_inventory_transactions (id),
        posting_authority varchar(255),
        operation_execution_ref varchar(255),
        order_or_batch_ref varchar(255),
        work_centre_ref varchar(255),
        shipment_ref varchar(255),
        destination_ref varchar(255),
        effective_at timestamp(6) without time zone NOT NULL,
        recorded_at timestamp(6) without time zone NOT NULL,
        CONSTRAINT factory_inventory_transactions_company_id_request_id_unique
          UNIQUE (company_id, request_id),
        CONSTRAINT factory_inventory_transactions_kind CHECK (
          kind IN ('receipt', 'transfer', 'consumption', 'output', 'correction', 'transform')
        ),
        CONSTRAINT factory_inventory_transactions_correction_reference CHECK (
          (kind = 'correction') = (corrects_transaction_id IS NOT NULL AND reason IS NOT NULL)
        ),
        CONSTRAINT factory_inventory_transactions_late_entry CHECK (effective_at <= recorded_at)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE factory_inventory_transaction_entries (
        id bigserial PRIMARY KEY,
        company_id bigint NOT NULL REFERENCES companies (id),
        transaction_id bigint NOT NULL REFERENCES factory_inventory_transactions (id),
        role varchar(16) NOT NULL,
        material_id bigint REFERENCES factory_inventory_materials (id),
        location_id bigint REFERENCES factory_inventory_locations (id),
        native_quantity numeric(36, 12) NOT NULL,
        native_unit_id bigint NOT NULL REFERENCES factory_inventory_units (id),
        recorded_quantity numeric(24, 12),
        recorded_unit_id bigint REFERENCES factory_inventory_units (id),
        conversion_id bigint REFERENCES factory_inventory_unit_conversions (id),
        observation varchar(16),
        output_role varchar(64),
        evidence text,
        reconciliation_basis text,
        CONSTRAINT factory_inventory_transaction_entries_role
          CHECK (role IN ('stock', 'boundary', 'variance')),
        CONSTRAINT factory_inventory_transaction_entries_role_shape CHECK (
          CASE role
            WHEN 'stock' THEN material_id IS NOT NULL AND location_id IS NOT NULL
              AND recorded_quantity IS NOT NULL AND recorded_unit_id IS NOT NULL
              AND observation IS NOT NULL AND reconciliation_basis IS NULL
            WHEN 'boundary' THEN material_id IS NOT NULL AND location_id IS NULL
              AND recorded_quantity IS NULL AND observation IS NULL
              AND reconciliation_basis IS NULL
            WHEN 'variance' THEN material_id IS NULL AND location_id IS NULL
              AND recorded_quantity IS NULL AND observation IS NULL
              AND evidence IS NOT NULL AND reconciliation_basis IS NOT NULL
          END
        ),
        CONSTRAINT factory_inventory_transaction_entries_observation
          CHECK (observation IN ('measured', 'declared', 'counted', 'derived')),
        CONSTRAINT factory_inventory_transaction_entries_quantities CHECK (
          native_quantity <> 0 AND (recorded_quantity IS NULL OR recorded_quantity > 0)
        )
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE factory_inventory_genealogy_links (
        id bigserial PRIMARY KEY,
        company_id bigint NOT NULL REFERENCES companies (id),
        transaction_id bigint NOT NULL REFERENCES factory_inventory_transactions (id),
        input_entry_id bigint NOT NULL REFERENCES factory_inventory_transaction_entries (id),
        output_entry_id bigint NOT NULL REFERENCES factory_inventory_transaction_entries (id),
        CONSTRAINT factory_inventory_genealogy_links_input_output_unique
          UNIQUE (input_entry_id, output_entry_id)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE FUNCTION pg_temp.factory_inventory_ledger_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'the Material Transaction ledger is append-only: % on % is refused',
          TG_OP, TG_TABLE_NAME
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.factory_inventory_ledger_check_balance() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        checked_id bigint;
      BEGIN
        IF TG_TABLE_NAME = 'factory_inventory_transactions' THEN
          checked_id := NEW.id;
        ELSE
          checked_id := NEW.transaction_id;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM factory_inventory_transaction_entries WHERE transaction_id = checked_id
        ) THEN
          RAISE EXCEPTION 'material transaction % has no entries', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM factory_inventory_transaction_entries
          WHERE transaction_id = checked_id
          GROUP BY native_unit_id
          HAVING sum(native_quantity) <> 0
        ) THEN
          RAISE EXCEPTION 'material transaction % does not balance', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """
    ] ++
      (for table <- [
            "factory_inventory_transactions",
            "factory_inventory_transaction_entries",
            "factory_inventory_genealogy_links"
          ],
          statement <- [
            "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
              "FOR EACH ROW EXECUTE FUNCTION pg_temp.factory_inventory_ledger_refuse_change()",
            "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
              "FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.factory_inventory_ledger_refuse_change()"
          ],
          do: statement
      ) ++
      for table <- ["factory_inventory_transactions", "factory_inventory_transaction_entries"] do
        "CREATE CONSTRAINT TRIGGER #{table}_balanced AFTER INSERT ON #{table} " <>
          "DEFERRABLE INITIALLY DEFERRED " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.factory_inventory_ledger_check_balance()"
      end
  end

  @doc "Makes PostgreSQL run the ledger's deferred balance check now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  @doc """
  A mill in tenant 41 (company 73, with a sister company 74), and a customer
  tenant 42, with kilogram-native coil, finished, trim, and scrap materials,
  a coil unit converting to kilograms, and three locations.
  """
  def mill! do
    alias Bilimbi.Base.Tenancy
    alias Bilimbi.Factory.Inventory

    create_inventory_tables!()
    insert_tenant!(%{id: 41, name: "Operator"})
    insert_tenant!(%{id: 42, name: "Customer", is_platform_operator: false})
    insert_company!(%{id: 73, tenant_id: 41, name: "Mill", code: "mill"})
    insert_company!(%{id: 74, tenant_id: 41, name: "Sister Mill", code: "sister"})

    {:ok, scope} = Tenancy.scope(41)
    {:ok, customer} = Tenancy.scope(42)
    {:ok, kg} = Inventory.create_unit(scope, 73, %{code: "kg", name: "Kilogram"})
    {:ok, coil_unit} = Inventory.create_unit(scope, 73, %{code: "coil", name: "Coil"})

    [coil, sheet, trim, scrap] =
      for {sku, title} <- [
            {"AL-COIL", "Aluminium coil"},
            {"AL-SHEET", "Aluminium sheet"},
            {"AL-TRIM", "Aluminium trim"},
            {"AL-SCRAP", "Aluminium scrap"}
          ] do
        {:ok, item} = Inventory.create_item(scope, 73, %{sku: sku, title: title})
        {:ok, _material} = Inventory.register_material(scope, 73, item.id, kg.id)
        item
      end

    {:ok, _conversion} = Inventory.define_conversion(scope, 73, coil.id, coil_unit.id, "250")

    [receiving, slitter, yard] =
      for {code, name} <- [{"RCV", "Receiving"}, {"LINE-1", "Slitting line"}, {"YARD", "Scrap yard"}] do
        {:ok, location} = Inventory.create_location(scope, 73, %{code: code, name: name})
        location
      end

    %{
      scope: scope,
      customer: customer,
      kg: kg,
      coil_unit: coil_unit,
      coil: coil,
      sheet: sheet,
      trim: trim,
      scrap: scrap,
      receiving: receiving,
      slitter: slitter,
      yard: yard
    }
  end

  @doc "A request with the header every posting needs."
  def request(request_id, fields) do
    Map.merge(
      %{request_id: request_id, actor_type: "user", actor_id: 9, evidence: "GRN-#{request_id}"},
      Map.new(fields)
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
