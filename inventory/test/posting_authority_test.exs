defmodule Bilimbi.Factory.Inventory.PostingAuthorityTest do
  # Declarations are application environment and loaded applications, which
  # several tests change and restart Inventory over.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.PostingAuthority
  alias Bilimbi.Factory.Inventory.TestPostingAuthority
  alias Bilimbi.Factory.Inventory.Transaction

  import Bilimbi.Factory.Inventory.TestFixtures

  # The throwaway Extension's module, compiled once and kept out of every
  # application until a test loads its declaring application.
  setup_all do
    [{poster, _beam}] =
      Code.compile_string("""
      defmodule Bilimbi.Throwaway.Poster do
        alias Bilimbi.Factory.Inventory

        def consume(scope, request),
          do: Inventory.record_production_consumption(scope, 73, request, __MODULE__)

        def output(scope, request), do: Inventory.record_output(scope, 73, request, __MODULE__)

        def transform(scope, request),
          do: Inventory.record_transform(scope, 73, request, __MODULE__)

        def consume_as_warehouse(scope, request),
          do: Inventory.record_consumption(scope, 73, request)
      end
      """)

    %{poster: poster}
  end

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

    test "a refused declaration fails Inventory's boot, not its postings" do
      Application.put_env(:bilimbi_core_company, :posting_authority, Bilimbi.Core.Company)

      on_exit(fn ->
        Application.delete_env(:bilimbi_core_company, :posting_authority)
        {:ok, _started} = Application.ensure_all_started(:bilimbi_factory_inventory)
      end)

      :ok = Application.stop(:bilimbi_factory_inventory)

      assert {:error, reason} = Application.start(:bilimbi_factory_inventory)
      assert inspect(reason) =~ "bilimbi_core_company declares"
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

      assert {:error, :unregistered_posting_authority} =
               Inventory.record_consumption(scope, 73, consumption)

      for authority <- [
            nil,
            Bilimbi.Factory.ProductionExecution,
            Bilimbi.Factory.Inventory.Ledger,
            inspect(TestPostingAuthority)
          ] do
        assert {:error, :unregistered_posting_authority} =
                 Inventory.record_production_consumption(scope, 73, consumption, authority)

        assert {:error, :unregistered_posting_authority} =
                 Inventory.record_output(scope, 73, output, authority)
      end

      authority = TestPostingAuthority

      assert {:ok, %Transaction{kind: :consumption, posting_authority: posted_by}} =
               Inventory.record_production_consumption(scope, 73, consumption, authority)

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
      authority = TestPostingAuthority

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

      assert {:error, :unregistered_posting_authority} =
               Inventory.record_production_correction(
                 scope,
                 73,
                 correction,
                 Bilimbi.Factory.ProductionExecution
               )

      assert {:ok, %Transaction{kind: :correction}} =
               Inventory.record_production_correction(scope, 73, correction, authority)
    end
  end

  describe "with no authority registered" do
    setup do
      context = mill!()

      on_exit(fn ->
        Application.put_env(
          :bilimbi_factory_inventory,
          :posting_authority,
          TestPostingAuthority
        )

        restart_inventory!()
      end)

      Application.delete_env(:bilimbi_factory_inventory, :posting_authority)
      restart_inventory!()
      context
    end

    test "every production and transform posting is refused while warehouse use continues",
         context do
      %{scope: scope, coil: coil, sheet: sheet, receiving: receiving, slitter: line} = context
      refute Inventory.posting_authority_registered?(TestPostingAuthority)

      assert {:ok, %Transaction{kind: :receipt} = receipt} =
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

      draw = %{item_id: coil.id, location_id: receiving.id, quantity: 5, observation: "measured"}
      make = %{item_id: sheet.id, location_id: line.id, quantity: 5, observation: "counted"}
      production = %{order_or_batch: "PO-7"}

      correction =
        request("X-1",
          corrects_transaction_id: receipt.id,
          reason: "Recount",
          lines: [%{draw | quantity: -1}]
        )

      for {post, request} <- [
            {&Inventory.record_production_consumption/4,
             request("C-1", context: production, lines: [draw])},
            {&Inventory.record_output/4, request("O-1", lines: [make])},
            {&Inventory.record_transform/4, request("T-1", inputs: [draw], outputs: [make])},
            {&Inventory.record_production_correction/4, correction}
          ],
          authority <- [TestPostingAuthority, Bilimbi.Factory.ProductionExecution, nil] do
        assert {:error, :unregistered_posting_authority} = post.(scope, 73, request, authority)
      end

      assert {:error, :unregistered_posting_authority} =
               Inventory.record_consumption(
                 scope,
                 73,
                 request("C-2", context: production, lines: [draw])
               )

      assert {:ok, %Transaction{kind: :consumption}} =
               Inventory.record_consumption(scope, 73, request("C-3", lines: [draw]))

      assert {:ok, %Transaction{kind: :correction}} =
               Inventory.record_correction(scope, 73, correction)

      assert {:ok, [_correction, _consumption, ^receipt]} =
               Inventory.list_transactions(scope, 73)
    end
  end

  describe "an Extension" do
    # A throwaway Extension, `throwaway/poster`, whose own module declares
    # itself a posting authority and posts production context straight to
    # Inventory instead of through Production Execution.
    setup %{poster: poster} do
      own = Application.fetch_env!(:bilimbi_factory_inventory, :bilimbi_module)

      descriptor = %{
        own
        | id: "throwaway/poster",
          layer: :extension,
          otp_app: :bilimbi_throwaway_poster,
          namespace: Bilimbi.Throwaway.Poster,
          dependencies: ["factory/inventory"],
          graph_module_ids: own.graph_module_ids ++ ["throwaway/poster"]
      }

      env = [bilimbi_module: descriptor, posting_authority: poster]

      :ok =
        :application.load(
          {:application, :bilimbi_throwaway_poster,
           [
             description: ~c"Throwaway Extension",
             vsn: ~c"0.1.0",
             modules: [poster],
             registered: [],
             applications: [:kernel, :stdlib, :bilimbi_factory_inventory],
             env: env
           ]}
        )

      on_exit(fn ->
        Application.unload(:bilimbi_throwaway_poster)
        {:ok, _started} = Application.ensure_all_started(:bilimbi_factory_inventory)
      end)

      Map.put(mill!(), :env, env)
    end

    test "cannot register: its declaration is refused and fails Inventory's boot", context do
      %{poster: poster, env: env} = context

      assert_raise ArgumentError, ~r/bilimbi_throwaway_poster declares/, fn ->
        PostingAuthority.declared!(:bilimbi_throwaway_poster, env, [poster])
      end

      :ok = Application.stop(:bilimbi_factory_inventory)
      assert {:error, reason} = Application.start(:bilimbi_factory_inventory)
      assert inspect(reason) =~ "bilimbi_throwaway_poster declares"
    end

    test "cannot post production or transform context", context do
      %{scope: scope, poster: poster, coil: coil, sheet: sheet} = context
      %{receiving: receiving, slitter: line} = context

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

      refute Inventory.posting_authority_registered?(poster)

      draw = %{item_id: coil.id, location_id: receiving.id, quantity: 5, observation: "measured"}
      make = %{item_id: sheet.id, location_id: line.id, quantity: 5, observation: "counted"}
      production = %{operation_execution: "EXT-RUN-1", work_centre: "SLIT-1"}

      assert {:error, :unregistered_posting_authority} =
               poster.consume(scope, request("C-1", context: production, lines: [draw]))

      assert {:error, :unregistered_posting_authority} =
               poster.output(scope, request("O-1", context: production, lines: [make]))

      assert {:error, :unregistered_posting_authority} =
               poster.transform(scope, request("T-1", inputs: [draw], outputs: [make]))

      assert {:error, :unregistered_posting_authority} =
               poster.consume_as_warehouse(
                 scope,
                 request("C-2", context: production, lines: [draw])
               )

      assert {:ok, [_receipt]} = Inventory.list_transactions(scope, 73)
    end
  end

  defp restart_inventory! do
    :ok = Application.stop(:bilimbi_factory_inventory)
    :ok = Application.start(:bilimbi_factory_inventory)
  end
end
