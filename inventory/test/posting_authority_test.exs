defmodule Bilimbi.Factory.Inventory.PostingAuthorityTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.TestPostingAuthority
  alias Bilimbi.Factory.Inventory.Transaction

  import Bilimbi.Factory.Inventory.TestFixtures

  describe "registration" do
    test "refuses a module outside Inventory's Domain container" do
      # A Core module, a Base module, and a module no installed application
      # owns, such as this test.
      for module <- [Bilimbi.Core.Company, Bilimbi.Base.Repo, __MODULE__, :"Elixir.Nowhere"] do
        assert {:error, :outside_domain_container} =
                 Inventory.register_posting_authority(module)

        refute Inventory.posting_authority_registered?(module)
      end
    end

    test "gives each module its credential once, so no caller can register in its name" do
      assert Inventory.posting_authority_registered?(TestPostingAuthority)

      assert {:error, :already_registered} =
               Inventory.register_posting_authority(TestPostingAuthority)
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
              %{item_id: coil.id, location_id: receiving.id, quantity: 50, observation: "measured"}
            ]
          )
        )

      context
    end

    test "is refused from an unregistered caller and accepted from a registered one", context do
      %{scope: scope, coil: coil, sheet: sheet, receiving: receiving, slitter: line} = context

      forged = %{TestPostingAuthority.credential() | secret: :crypto.strong_rand_bytes(32)}

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

      for authority <- [[], [authority: forged], [authority: %{module: TestPostingAuthority}]] do
        assert {:error, :unregistered_posting_authority} =
                 Inventory.record_consumption(scope, 73, consumption, authority)

        assert {:error, :unregistered_posting_authority} =
                 Inventory.record_output(scope, 73, output, authority)
      end

      authority = [authority: TestPostingAuthority.credential()]

      assert {:ok, %Transaction{kind: :consumption, posting_authority: posted_by}} =
               Inventory.record_consumption(scope, 73, consumption, authority)

      assert posted_by == inspect(TestPostingAuthority)
      assert {:ok, %Transaction{kind: :output}} = Inventory.record_output(scope, 73, output, authority)
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
                     %{item_id: coil.id, location_id: receiving.id, quantity: 5, observation: "counted"}
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
      authority = [authority: TestPostingAuthority.credential()]

      {:ok, output} =
        Inventory.record_output(
          scope,
          73,
          request("O-1",
            lines: [%{item_id: sheet.id, location_id: line.id, quantity: 5, observation: "counted"}]
          ),
          authority
        )

      correction =
        request("X-1",
          corrects_transaction_id: output.id,
          reason: "Counted twice",
          lines: [%{item_id: sheet.id, location_id: line.id, quantity: -1, observation: "counted"}]
        )

      assert {:error, :unregistered_posting_authority} =
               Inventory.record_correction(scope, 73, correction)

      assert {:ok, %Transaction{kind: :correction}} =
               Inventory.record_correction(scope, 73, correction, authority)
    end
  end
end
