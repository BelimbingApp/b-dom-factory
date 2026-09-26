# Factory Inventory

Inventory owns Factory's material facts: items, locations, units of measure,
the Material Transaction ledger, material units, and Lot/Unit Genealogy.
Warehouse movements post here directly; production effects arrive through the
production posting authority that Production Execution declares.

The public contract and its phases are defined in Bilimbi's
[Inventory module plan](https://github.com/BelimbingApp/bilimbi/blob/main/docs/plans/factory/0010-inventory-module.md).
Phases 1–3 cover the catalog, ledger, and lot or unit genealogy.

## Public API

`Bilimbi.Factory.Inventory` is the whole API. Every operation takes a
`Bilimbi.Base.Tenancy.Scope` and a company ID; the company must be live in the
scope's tenant (Core Company's `get_company/2` decides). A record of another
company is reported as not found. Results are read models (`Item`, `Unit`,
`Location`, `Material`, `Conversion`, `StockPosition`, `Transaction`,
`Entry`, `Identity`), never schemas.

| Area | Operations |
| --- | --- |
| Item master | `list_items/3`, `get_item/3`, `get_item_by_sku/3`, `create_item/3` |
| Units | `list_units/3`, `get_unit/3`, `create_unit/3` |
| Locations | `list_locations/3`, `get_location/3`, `create_location/3` |
| Material identity | `register_material/4`, `get_material/3` |
| Conversions | `define_conversion/5`, `list_conversions/3`, `get_conversion/5` |
| Stock position | `get_stock_position/4` |
| Ledger postings | `record_receipt/3`, `record_transfer/3`, `record_consumption/3`, `record_correction/3` |
| Production postings | `record_output/4`, `record_transform/4`, `record_production_consumption/4`, `record_production_correction/4` |
| Ledger reads | `get_transaction/3`, `list_transactions/3` |
| Lot and unit genealogy | `get_identity/3`, `trace_backward/3`, `trace_forward/3`, `list_identity_draws/3` |
| Posting authority | `posting_authority_registered?/1` |

- **Material identity.** An item becomes a stocked material once, with a
  native unit that never changes afterwards. Stock quantities are always held
  in that unit.
- **Conversions.** One conversion unit equals `factor` native units. Rows are
  immutable, so a changed factor is the next version. The earlier versions
  stay readable, so a converted quantity can name the basis it used.
- **Stock positions.** A position is read by item and location, in the native
  unit: the sum of the ledger's stock entries there. Inventory does not
  depend on Production Execution.

## Material Transaction ledger

Every movement is one append-only transaction of signed entries in native
units that sum to zero per unit. A stock entry is material at a location; a
boundary entry is its counterpart outside stock (where a receipt came from,
where consumption went); a variance entry is what a transform's observations
do not account for. The `record_*` docs on the facade define each request.

- **What a transaction keeps.** The actor, source evidence, the caller's
  `request_id`, its effective time and Inventory's recorded time (a late entry
  keeps both), and optional opaque context references (operation execution,
  order or batch, Work Centre/Resource, shipment, destination) that Inventory
  never interprets. A stock entry keeps the quantity and unit as recorded,
  how it was obtained (measured, declared, counted, or derived), and the
  conversion ID and version that derived its native quantity.
- **Retries and competing use.** A repeated `request_id` returns the recorded
  transaction; a different request under it is refused. A posting locks the
  materials it touches before reading positions, and no location may go
  negative, so two callers cannot consume the same quantity.
- **Corrections.** A correction is a new transaction with a reason, the ID of
  the transaction it corrects, and signed adjustment lines. The original never
  changes: PostgreSQL refuses UPDATE, DELETE, and TRUNCATE on the ledger, and
  a deferred trigger refuses a commit whose entries do not balance.
- **Transforms.** Inputs, outputs, and their genealogy links commit together.
  Every line shares one native unit. Observed quantities are never adjusted;
  when inputs and outputs differ, the transform needs `variance` evidence and
  a reconciliation basis, and the difference is recorded as a variance entry.
  For example, 100 kg measured in, 78 kg measured finished, 17 kg derived
  trim, and 2 kg measured waste leave a 3 kg variance.

## Lot and unit identities

A receipt or production output line may create an identity with
`identity: %{kind: "lot" | "unit", code: "..."}`. The code is unique for that
material within its company. Subsequent transfer, consumption, or transform
input lines cite its `identity_id`; a transform output creates a fresh identity.
When a transform uses any identity, every input and output must be identified.
Inventory checks both the overall location balance and the balance of the
specific identity, or the unidentified pool, before a draw. The stock entry
exposes `identity_id`, while `get_identity/3` returns the immutable code, kind,
item, and source transaction.

`trace_backward/3` and `trace_forward/3` walk the transform links between
identities across any number of transformations. They return the root identity,
the visited identities, `{input_identity_id, output_identity_id,
transaction_id}` links, and source receipt transactions in `receipts`.
`list_identity_draws/3` lists the consumptions and transforms that drew an
identity, including consumption that created no link. Reads
remain scoped to one live company. Unidentified material remains supported for
workflows that do not track lots or individual units.

## Posting authority

Receipts, transfers, and ordinary consumption and corrections are open to
any caller, through `record_receipt/3`, `record_transfer/3`,
`record_consumption/3`, and `record_correction/3`. Those refuse production
context as `:unregistered_posting_authority`: operation execution, order or
batch, or Work Centre/Resource context, and a correction of a posting that
had an authority. Production postings go through `record_output/4`,
`record_transform/4`, `record_production_consumption/4`, and
`record_production_correction/4`, each naming its authority, which must be
declared.

The registry is the composition metadata; nothing registers at runtime, and
Inventory names no authority. A module is declared by its own OTP
application, beside the descriptor metadata in its `mix.exs` (module
discovery refuses extra keys in `bilimbi.module.exs`):

```elixir
env:
  Bilimbi.Base.ModuleRegistry.MixDiscovery.application_env(__DIR__) ++
    [posting_authority: Bilimbi.Factory.ProductionExecution]
```

Inventory builds the registry once at application start. It accepts a
declaration only from a Domain module of its own container in the validated
graph, naming one of that application's own modules; any other fails boot.
Production Execution is the declared authority. Inventory does not depend on
it, so Inventory's own test build declares `TestPostingAuthority` instead.

The BEAM cannot prove which module calls, so `test/posting_boundary_test.exs`
checks the compiled graph: it fails when a module other than a declared
authority calls or captures a production posting, or when any module outside
Inventory calls or captures one Inventory keeps internal (`@moduledoc false`,
such as `Ledger`).
It needs the whole mounted graph compiled, so a module-folder `mix test`
excludes it; CI runs it with `mix test --only compiled_graph`.

## Persistence

| Table | Disposition | Notes |
| --- | --- | --- |
| `commerce_inventory_items` | compatible baseline | Belimbing's item master, verified by `SchemaContract` and adopted as is |
| `factory_inventory_units`, `factory_inventory_locations`, `factory_inventory_materials`, `factory_inventory_unit_conversions` | Bilimbi-only | company-owned; not in the schema contract, because an adopted Belimbing database gets them from `mix bilimbi.migrate` |
| `factory_inventory_transactions`, `factory_inventory_transaction_entries`, `factory_inventory_genealogy_links` | Bilimbi-only | the ledger; append-only and balance-checked by triggers |
| `factory_inventory_identities` | Bilimbi-only | immutable lot or unit identities, linked to stock entries and their source transaction |

The item master keeps Belimbing's own columns, including the location-less
`quantity_on_hand` and free-text `storage_location`. Inventory neither changes
them nor derives stock positions from them. `category_id` and
`product_template_id` point at Belimbing's Commerce Catalog, which Bilimbi
does not have, so they are read as opaque IDs and `create_item/3` does not
accept them. Belimbing's item photos and marketplace fitments are Commerce
concerns and are not carried here.

The contribution provider declares Belimbing's `commerce.inventory.*`
capabilities under their original keys, so grants in an adopted database keep
naming a declared capability.
