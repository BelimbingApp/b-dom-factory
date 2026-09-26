# Run from Bilimbi's root with MIX_ENV=test so the composed host loads Base Audit.
Code.require_file(Path.expand("../../../../base/tenancy/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/geonames/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../core/company/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../../../base/audit/test/support/test_fixtures.ex", __DIR__))
Code.require_file(Path.expand("../../inventory/test/support/test_fixtures.ex", __DIR__))

ExUnit.start(autorun: false, max_cases: 2)
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)

defmodule Bilimbi.Factory.AuditCaptureHostTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Bilimbi.Base.Audit.MutationSchema
  alias Bilimbi.Base.Audit.TestFixtures, as: AuditFixtures
  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory.Schemas.Item
  alias Bilimbi.Factory.Inventory.TestFixtures, as: InventoryFixtures

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    AuditFixtures.create_audit_tables!()
    InventoryFixtures.create_inventory_tables!()
    InventoryFixtures.insert_tenant!(%{id: 41})
    InventoryFixtures.insert_company!(%{id: 73, tenant_id: 41})
    :ok
  end

  test "a Factory Repo insert creates a canonical audit mutation in the composed host" do
    assert :bilimbi_base_audit in Enum.map(Application.started_applications(), &elem(&1, 0))

    item =
      Repo.insert!(%Item{
        company_id: 73,
        sku: "HOST-AUDIT-PROOF",
        title: "Host audit proof",
        status: "ready",
        quantity_on_hand: 1,
        currency_code: "MYR"
      })

    assert [mutation] =
             Repo.all(
               from(row in MutationSchema,
                 where:
                   row.auditable_type == "Bilimbi.Factory.Inventory.Schemas.Item" and
                     row.auditable_id == ^to_string(item.id)
               )
             )

    assert mutation.source == "listener"
    assert mutation.event == "created"
    assert mutation.actor_type == "guest"
    assert mutation.actor_id == 0
    assert mutation.old_values == %{}
    assert mutation.new_values["sku"] == "HOST-AUDIT-PROOF"
  end
end

case ExUnit.run() do
  %{failures: 0} -> :ok
  _result -> System.halt(1)
end
