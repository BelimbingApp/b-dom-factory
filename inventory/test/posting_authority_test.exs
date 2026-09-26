defmodule Bilimbi.Factory.Inventory.PostingAuthorityTest do
  # Declarations are application environment, which one test changes.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.PostingAuthority
  alias Bilimbi.Factory.Inventory.TestPostingAuthority
  alias Bilimbi.Factory.Inventory.Transaction

  import Bilimbi.Factory.Inventory.TestFixtures

  # Inventory's own descriptor and modules stand in for a Factory module's.
  defp declare(descriptor, module) do
    own = Application.fetch_env!(:bilimbi_factory_inventory, :bilimbi_module)

    PostingAuthority.declared!(
      :declaring_app,
      [bilimbi_module: Map.merge(own, descriptor), posting_authority: module],
      Application.spec(:bilimbi_factory_inventory, :modules)
    )
  end

  describe "declaration" do
    test "accepts a Domain module of Inventory's container naming its own module" do
      assert declare(%{}, TestPostingAuthority) == TestPostingAuthority
      assert Inventory.posting_authority_registered?(TestPostingAuthority)
    end

    test "refuses a declaration from another container or layer, off the graph, or naming another's module" do
      company = Application.fetch_env!(:bilimbi_core_company, :bilimbi_module)

      for {descriptor, module} <- [
            {company, Bilimbi.Core.Company},
            {%{id: "sales/orders"}, TestPostingAuthority},
            {%{id: "factory/inventory", layer: :extension}, TestPostingAuthority},
            {%{id: "factory/unmounted"}, TestPostingAuthority},
            {%{}, Bilimbi.Core.Company},
            {%{}, nil}
          ] do
        assert_raise ArgumentError, ~r/posting authority/, fn -> declare(descriptor, module) end
      end
    end

    test "a refused declaration fails the registry rather than being ignored" do
      Application.put_env(:bilimbi_core_company, :posting_authority, Bilimbi.Core.Company)
      on_exit(fn -> Application.delete_env(:bilimbi_core_company, :posting_authority) end)

      assert_raise ArgumentError, ~r/bilimbi_core_company declares/, fn ->
        Inventory.posting_authority_registered?(TestPostingAuthority)
      end
    end

    test "names no module that its application does not declare" do
      for module <- [
            Bilimbi.Core.Company,
            Bilimbi.Factory.Inventory.Ledger,
            Bilimbi.Factory.ProductionExecution,
            __MODULE__,
            nil
          ] do
        refute Inventory.posting_authority_registered?(module)
      end
    end
  end

  describe "production and transform context" do
    setup do
      context = mill!()
      %{scope: scope, coil: coil, receiving: receiving} = context

      {:ok, _receipt} =
        Inventory.record_receipt(
          scope,
          73,
          request("R-1",
            lines: [
              %{
                item_id: coil.id,
                location_id: receiving.id,
                quantity: 50,
                observation: "measured"
              }
            ]
          )
        )

      context
    end

    test "is refused from an unregistered caller and accepted from a registered one", context do
      %{scope: scope, coil: coil, sheet: sheet, receiving: receiving, slitter: line} = context

      consumption =
        request("C-1",
          context: %{order_or_batch: "PO-7"},
          lines: [
            %{item_id: coil.id, location_id: receiving.id, quantity: 5, observation: "measured"}
          ]
        )

      output =
        request("O-1",
          lines: [%{item_id: sheet.id, location_id: line.id, quantity: 5, observation: "counted"}]
        )

      for authority <- [
            [],
            [authority: Bilimbi.Factory.ProductionExecution],
            [authority: Bilimbi.Factory.Inventory.Ledger],
            [authority: inspect(TestPostingAuthority)]
          ] do
        assert {:error, :unregistered_posting_authority} =
                 Inventory.record_consumption(scope, 73, consumption, authority)

        assert {:error, :unregistered_posting_authority} =
                 Inventory.record_output(scope, 73, output, authority)
      end

      authority = [authority: TestPostingAuthority]

      assert {:ok, %Transaction{kind: :consumption, posting_authority: posted_by}} =
               Inventory.record_consumption(scope, 73, consumption, authority)

      assert posted_by == inspect(TestPostingAuthority)

      assert {:ok, %Transaction{kind: :output}} =
               Inventory.record_output(scope, 73, output, authority)
    end

    test "leaves warehouse postings open to any caller", context do
      %{scope: scope, coil: coil, receiving: receiving, slitter: line} = context

      assert {:ok, %Transaction{kind: :consumption, posting_authority: nil}} =
               Inventory.record_consumption(
                 scope,
                 73,
                 request("C-1",
                   context: %{shipment: "SHP-1", destination: "Customer dock"},
                   lines: [
                     %{
                       item_id: coil.id,
                       location_id: receiving.id,
                       quantity: 5,
                       observation: "counted"
                     }
                   ]
                 )
               )

      assert {:ok, %Transaction{kind: :transfer}} =
               Inventory.record_transfer(
                 scope,
                 73,
                 request("T-1",
                   lines: [
                     %{
                       item_id: coil.id,
                       from_location_id: receiving.id,
                       to_location_id: line.id,
                       quantity: 5,
                       observation: "declared"
                     }
                   ]
                 )
               )
    end

    test "correcting a production posting needs the authority too", context do
      %{scope: scope, sheet: sheet, slitter: line} = context
      authority = [authority: TestPostingAuthority]

      {:ok, output} =
        Inventory.record_output(
          scope,
          73,
          request("O-1",
            lines: [
              %{item_id: sheet.id, location_id: line.id, quantity: 5, observation: "counted"}
            ]
          ),
          authority
        )

      correction =
        request("X-1",
          corrects_transaction_id: output.id,
          reason: "Counted twice",
          lines: [
            %{item_id: sheet.id, location_id: line.id, quantity: -1, observation: "counted"}
          ]
        )

      assert {:error, :unregistered_posting_authority} =
               Inventory.record_correction(scope, 73, correction)

      assert {:ok, %Transaction{kind: :correction}} =
               Inventory.record_correction(scope, 73, correction, authority)
    end
  end
end
