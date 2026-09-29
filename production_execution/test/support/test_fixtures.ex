defmodule Bilimbi.Factory.ProductionExecution.TestFixtures do
  @moduledoc """
  Temporary Product Definition and Production Execution tables for
  public-API tests, beside Inventory's (`mill!/0` creates those). Mirror a
  migration's constraints here when persistence changes.
  """

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Tenancy.SystemPrincipals.ContributionValidator, as: PrincipalValidator
  alias Ecto.Adapters.SQL

  def create_production_tables! do
    for sql <- [
          "CREATE TEMPORARY TABLE factory_products (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), code text NOT NULL, name text NOT NULL, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code), UNIQUE(company_id, item_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_resource_types (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, property_definitions jsonb[] NOT NULL, retired_at timestamp(0), inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, CONSTRAINT factory_resource_types_company_code_unique UNIQUE (company_id, code), UNIQUE(id, company_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_resources (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, name text NOT NULL, resource_type_id bigint NOT NULL, properties jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(properties) = 'object'), retired_at timestamp(0), inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code), CONSTRAINT factory_resources_resource_type_id_fkey FOREIGN KEY (resource_type_id, company_id) REFERENCES factory_resource_types (id, company_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_formula_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, lines jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_routing_revisions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), product_id bigint NOT NULL REFERENCES factory_products(id), version integer NOT NULL, operations jsonb[] NOT NULL, process_config jsonb NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(product_id, version)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_production_orders (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code text NOT NULL, kind text NOT NULL CHECK (kind IN ('order', 'batch')), product_id bigint NOT NULL REFERENCES factory_products(id), formula_version integer NOT NULL CHECK (formula_version > 0), routing_version integer NOT NULL CHECK (routing_version > 0), demand_ref text, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, UNIQUE(company_id, code)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_operation_executions (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), order_id bigint NOT NULL REFERENCES factory_production_orders(id), request_id text NOT NULL, request_fingerprint text NOT NULL, source text NOT NULL CHECK (source IN ('live', 'import')), operation_code text NOT NULL, resource_id bigint NOT NULL REFERENCES factory_resources(id), operator_type text NOT NULL, operator_id bigint NOT NULL, started_at timestamp(6) NOT NULL, completed_at timestamp(6) NOT NULL CHECK (started_at <= completed_at), inputs jsonb[] NOT NULL, outputs jsonb[] NOT NULL, variance jsonb, evidence text NOT NULL, inventory_transaction_id bigint NOT NULL, formula_version integer NOT NULL, routing_version integer NOT NULL, inserted_at timestamp(0) NOT NULL, UNIQUE(company_id, request_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_material_hold_overrides (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), execution_id bigint NOT NULL REFERENCES factory_operation_executions(id), inventory_transaction_id bigint NOT NULL REFERENCES factory_inventory_transactions(id), source_transaction_id bigint NOT NULL REFERENCES factory_inventory_transactions(id), identity_id bigint NOT NULL REFERENCES factory_inventory_identities(id), item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), source text NOT NULL, actor_type text, actor_id bigint, acting_for_user_id bigint, recorded_by_type text NOT NULL, recorded_by_id bigint NOT NULL, recorded_by_acting_for_user_id bigint, reason text NOT NULL CHECK (length(btrim(reason)) > 0), evidence text, occurred_at timestamp(6) NOT NULL, CHECK ((source = 'live' AND evidence IS NULL AND actor_type = recorded_by_type AND actor_id = recorded_by_id AND acting_for_user_id IS NOT DISTINCT FROM recorded_by_acting_for_user_id) OR (source = 'import' AND length(btrim(evidence)) > 0)), UNIQUE(execution_id, identity_id)) ON COMMIT PRESERVE ROWS"
        ],
        do: SQL.query!(Repo, sql, [])

    create_wastage_tables!()

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

  defp create_wastage_tables! do
    for sql <- [
          "CREATE TEMPORARY TABLE factory_wastage_reasons (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code varchar(64) NOT NULL, label text NOT NULL, active boolean NOT NULL DEFAULT true, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, CONSTRAINT factory_wastage_reasons_company_id_code_unique UNIQUE (company_id, code), CONSTRAINT factory_wastage_reasons_id_company_id_unique UNIQUE (id, company_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_wastage_records (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), request_id text NOT NULL, request_fingerprint text NOT NULL, order_id bigint NOT NULL REFERENCES factory_production_orders(id), execution_id bigint NOT NULL REFERENCES factory_operation_executions(id), reason_id bigint NOT NULL, item_id bigint NOT NULL REFERENCES commerce_inventory_items(id), location_id bigint NOT NULL REFERENCES factory_inventory_locations(id), identity_id bigint REFERENCES factory_inventory_identities(id), quantity numeric(24, 12) NOT NULL, unit_id bigint NOT NULL REFERENCES factory_inventory_units(id), observation text NOT NULL, note text, occurred_at timestamp(6) NOT NULL, recorded_by_type text NOT NULL, recorded_by_id bigint NOT NULL, recorded_by_acting_for_user_id bigint, inventory_transaction_id bigint REFERENCES factory_inventory_transactions(id), corrects_id bigint UNIQUE REFERENCES factory_wastage_records(id), correction_reason text, inserted_at timestamp(0) NOT NULL, UNIQUE(company_id, request_id), CONSTRAINT factory_wastage_records_reason_id_fkey FOREIGN KEY (reason_id, company_id) REFERENCES factory_wastage_reasons (id, company_id), CONSTRAINT factory_wastage_records_correction CHECK ((corrects_id IS NULL AND quantity > 0 AND inventory_transaction_id IS NOT NULL AND correction_reason IS NULL) OR (corrects_id IS NOT NULL AND quantity >= 0 AND length(btrim(correction_reason)) > 0))) ON COMMIT PRESERVE ROWS",
          "CREATE FUNCTION pg_temp.refuse_wastage_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'wastage records are immutable; record a correction'; END $$",
          "CREATE TRIGGER wastage_records_append_only BEFORE UPDATE OR DELETE ON factory_wastage_records FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_wastage_change()",
          "CREATE TRIGGER wastage_records_no_truncate BEFORE TRUNCATE ON factory_wastage_records FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.refuse_wastage_change()"
        ],
        do: SQL.query!(Repo, sql, [])
  end

  @doc """
  Labour tables, which reference Core User's `users`: call after
  `Bilimbi.Core.User.TestFixtures.create_user_tables!/0` and
  `create_production_tables!/0`.
  """
  def create_labour_tables! do
    for sql <- [
          "CREATE TEMPORARY TABLE factory_labour_roles (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), code varchar(64) NOT NULL, label text NOT NULL, active boolean NOT NULL DEFAULT true, inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL, CONSTRAINT factory_labour_roles_company_id_code_unique UNIQUE (company_id, code), CONSTRAINT factory_labour_roles_id_company_id_unique UNIQUE (id, company_id)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE factory_labour_entries (id bigserial PRIMARY KEY, company_id bigint NOT NULL REFERENCES companies(id), request_id text NOT NULL, request_fingerprint text NOT NULL, order_id bigint NOT NULL REFERENCES factory_production_orders(id), execution_id bigint REFERENCES factory_operation_executions(id), worker_user_id bigint NOT NULL REFERENCES users(id), role_id bigint NOT NULL, started_at timestamp(6) NOT NULL, stopped_at timestamp(6), note text, recorded_by_type text NOT NULL, recorded_by_id bigint NOT NULL, recorded_by_acting_for_user_id bigint, stopped_by_type text, stopped_by_id bigint, stopped_by_acting_for_user_id bigint, corrects_id bigint UNIQUE REFERENCES factory_labour_entries(id), correction_reason text, inserted_at timestamp(0) NOT NULL, UNIQUE(company_id, request_id), CONSTRAINT factory_labour_entries_role_id_fkey FOREIGN KEY (role_id, company_id) REFERENCES factory_labour_roles (id, company_id), CONSTRAINT factory_labour_entries_times CHECK ((stopped_at IS NULL AND stopped_by_type IS NULL AND stopped_by_id IS NULL) OR (stopped_at >= started_at AND stopped_by_type IS NOT NULL AND stopped_by_id IS NOT NULL)), CONSTRAINT factory_labour_entries_correction CHECK ((corrects_id IS NULL AND correction_reason IS NULL) OR (corrects_id IS NOT NULL AND length(btrim(correction_reason)) > 0))) ON COMMIT PRESERVE ROWS",
          """
          CREATE FUNCTION pg_temp.refuse_labour_change() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
            IF TG_OP = 'UPDATE' THEN
              IF OLD.stopped_at IS NULL AND NEW.stopped_at IS NOT NULL
                AND (to_jsonb(NEW) - 'stopped_at' - 'stopped_by_type' - 'stopped_by_id' - 'stopped_by_acting_for_user_id')
                  = (to_jsonb(OLD) - 'stopped_at' - 'stopped_by_type' - 'stopped_by_id' - 'stopped_by_acting_for_user_id') THEN
                RETURN NEW;
              END IF;
            END IF;
            RAISE EXCEPTION 'labour entries are immutable once closed; record a correction';
          END $$
          """,
          "CREATE TRIGGER labour_entries_append_only BEFORE UPDATE OR DELETE ON factory_labour_entries FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_labour_change()",
          "CREATE TRIGGER labour_entries_no_truncate BEFORE TRUNCATE ON factory_labour_entries FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.refuse_labour_change()"
        ],
        do: SQL.query!(Repo, sql, [])

    :ok
  end

  @doc """
  A completed slitting run for shop-floor capture tests, over `mill!/0`'s
  context: 120 kg of coil received as one lot, then 100 kg of it slit into an
  80 kg sheet unit and a 15 kg trim lot with a 5 kg variance. The resource
  type, codes, and quantities are fixture data.
  """
  def capture_run!(context) do
    alias Bilimbi.Factory.{Inventory, ProductDefinition, ProductionExecution}

    %{scope: scope, coil: coil, sheet: sheet, trim: trim, kg: kg} = context
    %{receiving: receiving, slitter: slitter, yard: yard} = context

    {:ok, product} =
      ProductDefinition.create_product(scope, 73, sheet.id, %{code: "SHEET", name: "Sheet"})

    {:ok, resource_type} =
      ProductDefinition.create_resource_type(scope, 73, %{code: "TYPE_A", name: "Type A"})

    {:ok, resource} =
      ProductDefinition.create_resource(scope, 73, %{
        code: "RESOURCE_A",
        name: "Resource A",
        resource_type_id: resource_type.id
      })

    {:ok, formula} =
      ProductDefinition.publish_formula(scope, 73, product.id, %{
        lines: [
          %{item_id: coil.id, unit_id: kg.id, role: "input", quantity: 100},
          %{item_id: sheet.id, unit_id: kg.id, role: "output", quantity: 80},
          %{item_id: trim.id, unit_id: kg.id, role: "output", quantity: 15}
        ]
      })

    {:ok, routing} =
      ProductDefinition.publish_routing(scope, 73, product.id, %{
        operations: [
          %{
            code: "SLIT",
            sequence: 1,
            inputs: [coil.id],
            outputs: [sheet.id, trim.id],
            allowed_resource_ids: [resource.id]
          }
        ]
      })

    {:ok, order} =
      ProductionExecution.create_order(scope, 73, %{
        code: "ORDER-1",
        kind: "order",
        product_id: product.id,
        formula_version: formula.version,
        routing_version: routing.version
      })

    {:ok, receipt} =
      Inventory.record_receipt(scope, 73, %{
        request_id: "RECEIPT-1",
        actor_type: "user",
        actor_id: 9,
        evidence: "Delivery note",
        lines: [
          %{
            item_id: coil.id,
            location_id: receiving.id,
            quantity: 120,
            observation: "measured",
            identity: %{kind: "lot", code: "COIL-LOT-1"}
          }
        ]
      })

    coil_lot = Enum.find_value(receipt.entries, &(&1.role == :stock && &1.identity_id))
    completed_at = DateTime.add(DateTime.utc_now(), -3600, :second)

    {:ok, run} =
      ProductionExecution.complete_operation(scope, 73, order.id, :live, %{
        request_id: "RUN-1",
        operation_code: "SLIT",
        resource_id: resource.id,
        operator_type: "user",
        operator_id: 9,
        evidence: "Run sheet",
        started_at: DateTime.add(completed_at, -1800, :second),
        completed_at: completed_at,
        inputs: [
          %{
            item_id: coil.id,
            location_id: receiving.id,
            quantity: 100,
            observation: "measured",
            identity_id: coil_lot
          }
        ],
        outputs: [
          %{
            item_id: sheet.id,
            location_id: slitter.id,
            quantity: 80,
            observation: "measured",
            identity: %{kind: "unit", code: "SHEET-UNIT-1"}
          },
          %{
            item_id: trim.id,
            location_id: yard.id,
            quantity: 15,
            observation: "measured",
            output_role: "trim",
            identity: %{kind: "lot", code: "TRIM-LOT-1"}
          }
        ],
        variance: %{evidence: "Run sheet", reconciliation_basis: "Unweighed loss"}
      })

    {:ok, transaction} = Inventory.get_transaction(scope, 73, run.inventory_transaction_id)

    identity = fn item ->
      Enum.find_value(
        transaction.entries,
        &((&1.role == :stock and &1.item_id == item.id) && &1.identity_id)
      )
    end

    Map.merge(context, %{
      order: order,
      resource: resource,
      run: run,
      coil_lot: coil_lot,
      sheet_unit: identity.(sheet),
      trim_lot: identity.(trim)
    })
  end

  def install_authz!(principal_declarations \\ []) do
    for sql <- [
          "CREATE TEMPORARY TABLE base_authz_roles (id bigserial PRIMARY KEY, company_id bigint, name text NOT NULL, code text NOT NULL, description text, is_system boolean NOT NULL DEFAULT false, grant_all boolean NOT NULL DEFAULT false, created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_role_capabilities (id bigserial PRIMARY KEY, role_id bigint NOT NULL REFERENCES base_authz_roles(id), capability_key text NOT NULL, created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_principal_roles (id bigserial PRIMARY KEY, company_id bigint, principal_type text NOT NULL, principal_id bigint NOT NULL, role_id bigint NOT NULL REFERENCES base_authz_roles(id), created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_principal_capabilities (id bigserial PRIMARY KEY, company_id bigint, principal_type text NOT NULL, principal_id bigint NOT NULL, capability_key text NOT NULL, is_allowed boolean NOT NULL, created_at timestamp(0), updated_at timestamp(0), UNIQUE(company_id, principal_type, principal_id, capability_key)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_system_principal_capabilities (id bigserial PRIMARY KEY, company_id bigint NOT NULL, principal varchar(100) NOT NULL, capability_key varchar(255) NOT NULL, created_at timestamp(0), updated_at timestamp(0), UNIQUE(company_id, principal, capability_key)) ON COMMIT PRESERVE ROWS",
          "CREATE TEMPORARY TABLE base_authz_decision_logs (id bigserial PRIMARY KEY, company_id bigint, actor_type text NOT NULL, actor_id bigint NOT NULL, acting_for_user_id bigint, capability text NOT NULL, resource_type text, resource_id text, allowed boolean NOT NULL, reason_code text NOT NULL, applied_policies json, context json, trace_id text, occurred_at timestamp(0) NOT NULL, created_at timestamp(0), updated_at timestamp(0)) ON COMMIT PRESERVE ROWS"
        ],
        do: SQL.query!(Repo, sql, [])

    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"factory/production_execution", :bilimbi_factory_production_execution,
             Bilimbi.Factory.ProductionExecution.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    authz = ContributionValidator.validate_contributions!(entries)

    system_principals =
      PrincipalValidator.validate_contributions!([
        %{
          descriptor: %{id: "test/import_extension", otp_app: :bilimbi_test_import_extension},
          payload: principal_declarations
        }
      ])

    snapshot = Bilimbi.Factory.Inventory.TestFixtures.install_settings_snapshot!()

    ContributionRegistry.put_snapshot_for_test!(%{
      snapshot
      | consumers:
          Map.merge(snapshot.consumers, %{
            authz: authz,
            system_principals: system_principals
          })
    })

    ExUnit.Callbacks.on_exit(fn ->
      Bilimbi.Factory.Inventory.TestFixtures.install_settings_snapshot!()
    end)
  end
end
