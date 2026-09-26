defmodule Bilimbi.Factory.Inventory.LedgerTest do
  use Bilimbi.Base.Database.DataCase, async: true

  alias Bilimbi.Base.Repo
  alias Bilimbi.Factory.Inventory
  alias Bilimbi.Factory.Inventory.Entry
  alias Bilimbi.Factory.Inventory.Transaction
  alias Ecto.Adapters.SQL

  import Bilimbi.Factory.Inventory.TestFixtures

  setup do
    mill!()
  end

  defp quantity(scope, item, location) do
    {:ok, position} = Inventory.get_stock_position(scope, 73, item.id, location.id)
    position.quantity
  end

  defp receive!(context, request_id, quantity) do
    %{scope: scope, coil: coil, receiving: receiving} = context

    {:ok, transaction} =
      Inventory.record_receipt(
        scope,
        73,
        request(request_id,
          lines: [
            %{
              item_id: coil.id,
              location_id: receiving.id,
              quantity: quantity,
              observation: "measured"
            }
          ]
        )
      )

    transaction
  end

  describe "receipts" do
    test "record a balanced transaction with its actor, evidence, and times", context do
      %{scope: scope, coil: coil, receiving: receiving, kg: kg} = context

      assert %Transaction{kind: :receipt, actor_type: "user", actor_id: 9} =
               receipt =
               receive!(context, "R-1", "120.5")

      assert receipt.evidence == "GRN-R-1"
      assert receipt.request_id == "R-1"

      assert receipt.effective_at == receipt.recorded_at or
               DateTime.before?(receipt.effective_at, receipt.recorded_at)

      assert [
               %Entry{role: :stock, observation: :measured} = stock,
               %Entry{role: :boundary, location_id: nil, observation: nil} = boundary
             ] = receipt.entries

      assert stock.item_id == coil.id and boundary.item_id == coil.id
      assert stock.location_id == receiving.id
      assert stock.native_unit == kg and stock.recorded_unit == kg
      assert Decimal.eq?(stock.native_quantity, "120.5")
      assert Decimal.eq?(boundary.native_quantity, "-120.5")
      assert Decimal.eq?(quantity(scope, coil, receiving), "120.5")
    end

    test "keep a quantity recorded in another unit and name the conversion basis", context do
      %{scope: scope, coil: coil, coil_unit: coil_unit, receiving: receiving, kg: kg} = context
      {:ok, _v2} = Inventory.define_conversion(scope, 73, coil.id, coil_unit.id, "248")

      line = %{
        item_id: coil.id,
        location_id: receiving.id,
        quantity: 2,
        unit_id: coil_unit.id,
        observation: "counted"
      }

      assert {:ok, %Transaction{entries: [current | _]}} =
               Inventory.record_receipt(scope, 73, request("R-1", lines: [line]))

      assert {:ok, %Transaction{entries: [historical | _]}} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-2", lines: [Map.put(line, :conversion_version, 1)])
               )

      assert current.recorded_unit == coil_unit and current.native_unit == kg
      assert Decimal.eq?(current.recorded_quantity, 2)
      assert Decimal.eq?(current.native_quantity, 496)
      assert current.conversion_version == 2
      assert historical.conversion_version == 1
      assert Decimal.eq?(historical.native_quantity, 500)
      assert Decimal.eq?(quantity(scope, coil, receiving), 996)

      assert {:error, :conversion_not_found} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-3", lines: [Map.put(line, :conversion_version, 3)])
               )
    end

    test "keep a late entry's effective time beside the time it was recorded", context do
      %{scope: scope, coil: coil, receiving: receiving} = context
      effective_at = ~U[2026-09-01 06:30:00.000000Z]

      line = %{item_id: coil.id, location_id: receiving.id, quantity: 5, observation: "declared"}

      assert {:ok, %Transaction{effective_at: ^effective_at, recorded_at: recorded_at}} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-1", effective_at: effective_at, lines: [line])
               )

      assert DateTime.after?(recorded_at, effective_at)

      future = DateTime.add(DateTime.utc_now(), 1, :hour)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-2", effective_at: future, lines: [line])
               )

      assert %{effective_at: [_]} = errors_on(changeset)
    end

    test "keep optional opaque context references", context do
      %{scope: scope, coil: coil, receiving: receiving} = context
      line = %{item_id: coil.id, location_id: receiving.id, quantity: 5, observation: "declared"}

      assert {:ok, %Transaction{context: %{shipment: "SHP-9"}}} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-1", context: %{"shipment" => "SHP-9"}, lines: [line])
               )

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-2", context: %{invoice: "INV-1"}, lines: [line])
               )

      assert %{context: [_]} = errors_on(changeset)
    end

    test "report every invalid line by position", context do
      %{scope: scope, coil: coil, receiving: receiving} = context

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-1",
                   actor_type: nil,
                   lines: [
                     %{
                       item_id: coil.id,
                       location_id: receiving.id,
                       quantity: 1,
                       observation: "measured"
                     },
                     %{
                       item_id: coil.id,
                       location_id: receiving.id,
                       quantity: 0,
                       observation: "guessed"
                     }
                   ]
                 )
               )

      assert %{actor_type: ["can't be blank"], lines: lines} = errors_on(changeset)
      assert "line 2: quantity must be greater than 0" in lines
      assert "line 2: observation is invalid" in lines

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_receipt(scope, 73, request("R-1", lines: []))

      assert %{lines: ["needs at least one line"]} = errors_on(changeset)
    end
  end

  describe "retries" do
    test "repeat a recorded request without a duplicate", context do
      %{scope: scope, coil: coil, receiving: receiving} = context
      receipt = receive!(context, "R-1", 10)

      assert ^receipt = receive!(context, "R-1", 10)
      assert Decimal.eq?(quantity(scope, coil, receiving), 10)
      assert {:ok, [^receipt]} = Inventory.list_transactions(scope, 73)
    end

    test "refuse a different request under a recorded ID", context do
      %{scope: scope, coil: coil, receiving: receiving} = context
      _receipt = receive!(context, "R-1", 10)

      assert {:error, :request_id_conflict} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-1",
                   lines: [
                     %{
                       item_id: coil.id,
                       location_id: receiving.id,
                       quantity: 11,
                       observation: "measured"
                     }
                   ]
                 )
               )

      assert Decimal.eq?(quantity(scope, coil, receiving), 10)
    end

    test "are scoped to the company", context do
      %{scope: scope} = context
      {:ok, kg} = Inventory.create_unit(scope, 74, %{code: "kg", name: "Kilogram"})
      {:ok, item} = Inventory.create_item(scope, 74, %{sku: "AL-COIL", title: "Coil"})
      {:ok, _material} = Inventory.register_material(scope, 74, item.id, kg.id)
      {:ok, bay} = Inventory.create_location(scope, 74, %{code: "RCV", name: "Receiving"})
      _receipt = receive!(context, "R-1", 10)

      assert {:ok, %Transaction{company_id: 74}} =
               Inventory.record_receipt(
                 scope,
                 74,
                 request("R-1",
                   lines: [
                     %{
                       item_id: item.id,
                       location_id: bay.id,
                       quantity: 10,
                       observation: "measured"
                     }
                   ]
                 )
               )
    end
  end

  describe "transfers and consumption" do
    test "move and use stock without letting a position go negative", context do
      %{scope: scope, coil: coil, receiving: receiving, slitter: line} = context
      _receipt = receive!(context, "R-1", 10)

      transfer =
        request("T-1",
          lines: [
            %{
              item_id: coil.id,
              from_location_id: receiving.id,
              to_location_id: line.id,
              quantity: 6,
              observation: "declared"
            }
          ]
        )

      assert {:ok, %Transaction{kind: :transfer, entries: [from, to]}} =
               Inventory.record_transfer(scope, 73, transfer)

      assert from.location_id == receiving.id and Decimal.eq?(from.native_quantity, -6)
      assert to.location_id == line.id and Decimal.eq?(to.native_quantity, 6)
      assert Decimal.eq?(quantity(scope, coil, receiving), 4)
      assert Decimal.eq?(quantity(scope, coil, line), 6)

      consume = fn request_id, amount ->
        Inventory.record_consumption(
          scope,
          73,
          request(request_id,
            lines: [
              %{item_id: coil.id, location_id: line.id, quantity: amount, observation: "measured"}
            ]
          )
        )
      end

      # The first consumer takes the material; the second cannot take it again.
      assert {:ok, %Transaction{kind: :consumption}} = consume.("C-1", 4)
      assert {:error, :insufficient_stock} = consume.("C-2", 4)
      assert {:ok, _consumption} = consume.("C-3", 2)
      assert {:error, :insufficient_stock} = consume.("C-4", "0.001")
      assert Decimal.eq?(quantity(scope, coil, line), 0)

      assert {:error, :insufficient_stock} =
               Inventory.record_transfer(scope, 73, %{transfer | request_id: "T-2"})
    end

    test "never let a posting's own additions cover its draws", context do
      %{scope: scope, coil: coil, receiving: receiving, slitter: line} = context
      _receipt = receive!(context, "R-1", 10)

      move = fn from, to ->
        %{
          item_id: coil.id,
          from_location_id: from.id,
          to_location_id: to.id,
          quantity: 5,
          observation: "declared"
        }
      end

      assert {:error, :insufficient_stock} =
               Inventory.record_transfer(
                 scope,
                 73,
                 request("T-1", lines: [move.(receiving, line), move.(line, receiving)])
               )

      assert Decimal.eq?(quantity(scope, coil, line), 0)
      assert Decimal.eq?(quantity(scope, coil, receiving), 10)
    end

    test "refuse a transfer to the same location", context do
      %{scope: scope, coil: coil, receiving: receiving} = context

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_transfer(
                 scope,
                 73,
                 request("T-1",
                   lines: [
                     %{
                       item_id: coil.id,
                       from_location_id: receiving.id,
                       to_location_id: receiving.id,
                       quantity: 1,
                       observation: "declared"
                     }
                   ]
                 )
               )

      assert %{lines: ["line 1: to_location_id must differ from from_location_id"]} =
               errors_on(changeset)
    end
  end

  describe "corrections" do
    test "are new transactions that name the original, which never changes", context do
      %{scope: scope, coil: coil, receiving: receiving} = context
      receipt = receive!(context, "R-1", 10)

      assert {:ok, %Transaction{kind: :correction} = correction} =
               Inventory.record_correction(
                 scope,
                 73,
                 request("X-1",
                   corrects_transaction_id: receipt.id,
                   reason: "Scale ticket misread",
                   lines: [
                     %{
                       item_id: coil.id,
                       location_id: receiving.id,
                       quantity: -2,
                       observation: "measured"
                     }
                   ]
                 )
               )

      assert correction.corrects_transaction_id == receipt.id
      assert correction.reason == "Scale ticket misread"
      assert [%Entry{role: :stock} = stock, %Entry{role: :boundary}] = correction.entries
      assert Decimal.eq?(stock.native_quantity, -2) and Decimal.eq?(stock.recorded_quantity, 2)
      assert Decimal.eq?(quantity(scope, coil, receiving), 8)
      assert {:ok, ^receipt} = Inventory.get_transaction(scope, 73, receipt.id)
      assert {:ok, [^correction, ^receipt]} = Inventory.list_transactions(scope, 73)
    end

    test "need a reason and a transaction of the same company", context do
      %{scope: scope, coil: coil, receiving: receiving} = context
      receipt = receive!(context, "R-1", 10)
      line = %{item_id: coil.id, location_id: receiving.id, quantity: -2, observation: "counted"}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.record_correction(
                 scope,
                 73,
                 request("X-1", corrects_transaction_id: receipt.id, lines: [line])
               )

      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      assert {:error, :transaction_not_found} =
               Inventory.record_correction(
                 scope,
                 74,
                 request("X-1", corrects_transaction_id: receipt.id, reason: "r", lines: [line])
               )

      assert {:error, :insufficient_stock} =
               Inventory.record_correction(
                 scope,
                 73,
                 request("X-1",
                   corrects_transaction_id: receipt.id,
                   reason: "r",
                   lines: [%{line | quantity: -11}]
                 )
               )
    end
  end

  describe "scope" do
    test "refuses another tenant, another company's records, and unregistered items", context do
      %{scope: scope, customer: customer, coil: coil, receiving: receiving} = context
      line = %{item_id: coil.id, location_id: receiving.id, quantity: 1, observation: "counted"}
      receipt = receive!(context, "R-1", 1)

      assert {:error, :company_not_found} =
               Inventory.record_receipt(customer, 73, request("R-2", lines: [line]))

      assert {:error, :company_not_found} = Inventory.get_transaction(customer, 73, receipt.id)
      assert {:error, :transaction_not_found} = Inventory.get_transaction(scope, 74, receipt.id)

      assert {:error, :item_not_found} =
               Inventory.record_receipt(scope, 74, request("R-2", lines: [line]))

      {:ok, sister_bay} = Inventory.create_location(scope, 74, %{code: "RCV", name: "Receiving"})

      assert {:error, :location_not_found} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-2", lines: [%{line | location_id: sister_bay.id}])
               )

      {:ok, loose} = Inventory.create_item(scope, 73, %{sku: "LOOSE", title: "Loose"})

      assert {:error, :material_not_found} =
               Inventory.record_receipt(
                 scope,
                 73,
                 request("R-2", lines: [%{line | item_id: loose.id}])
               )
    end

    test "lists transactions by item", context do
      %{scope: scope, sheet: sheet, slitter: line} = context
      receipt = receive!(context, "R-1", 1)

      {:ok, other} =
        Inventory.record_receipt(
          scope,
          73,
          request("R-2",
            lines: [
              %{item_id: sheet.id, location_id: line.id, quantity: 1, observation: "counted"}
            ]
          )
        )

      assert {:ok, [^other]} = Inventory.list_transactions(scope, 73, item_id: sheet.id)
      assert {:ok, [^receipt]} = Inventory.list_transactions(scope, 73, item_id: context.coil.id)
      assert {:ok, [^other]} = Inventory.list_transactions(scope, 73, limit: 1)
    end
  end

  describe "the database" do
    test "refuses to change or delete a recorded transaction", context do
      receipt = receive!(context, "R-1", 10)

      for {sql, params} <- [
            {"UPDATE factory_inventory_transactions SET evidence = 'x' WHERE id = $1",
             [receipt.id]},
            {"DELETE FROM factory_inventory_transaction_entries WHERE transaction_id = $1",
             [receipt.id]},
            {"TRUNCATE factory_inventory_genealogy_links", []}
          ] do
        # The savepoint keeps the test's own transaction usable afterwards.
        assert_raise Postgrex.Error, ~r/append-only/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, params) end)
        end
      end

      assert {:ok, ^receipt} = Inventory.get_transaction(context.scope, 73, receipt.id)
    end

    test "refuses a transaction whose entries do not balance", context do
      receipt = receive!(context, "R-1", 10)
      [stock | _] = receipt.entries

      SQL.query!(
        Repo,
        """
        INSERT INTO factory_inventory_transaction_entries
          (company_id, transaction_id, role, material_id, native_quantity, native_unit_id)
        SELECT company_id, transaction_id, 'boundary', material_id, 1, native_unit_id
        FROM factory_inventory_transaction_entries WHERE id = $1
        """,
        [stock.id]
      )

      assert_raise Postgrex.Error, ~r/does not balance/, &check_deferred_constraints!/0
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, &elem(&1, 0))
  end
end
