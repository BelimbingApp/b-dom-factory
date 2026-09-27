# Factory Inventory

Inventory owns Factory's material facts: items, locations, units of measure,
the Material Transaction ledger, material units, and Lot/Unit Genealogy.
Warehouse movements post here directly; production effects arrive through the
production posting authority that Production Execution declares.

The public contract and its phases are defined in Bilimbi's
[Inventory module plan](https://github.com/BelimbingApp/bilimbi/blob/main/docs/plans/factory/0010-inventory-module.md).
Phases 1–3 cover the catalog, ledger, and lot or unit genealogy; Phase 4
proves them against Factory's composition (see [Integration proof](#integration-proof)).

## Public API

`Bilimbi.Factory.Inventory` is the whole API. Every operation takes a
`Bilimbi.Base.Tenancy.Scope` and a company ID; the company must be live in the
scope's tenant (Core Company's `get_company/2` decides). A record of another
company is reported as not found. Results are read models (`Item`, `Unit`,
`Location`, `Material`, `Conversion`, `StockPosition`, `Transaction`,
`Entry`, `Balance`, `Identity`), never schemas.

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
| Ledger reads | `get_transaction/3`, `list_transactions/3`, `list_corrections/3`, `get_transaction_balance/3` |
| Lot and unit genealogy | `get_identity/3`, `get_identity_positions/3`, `trace_backward/3`, `trace_forward/3`, `list_identity_draws/3` |
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
- **Weighed receipts.** The optional `receipt_measurement` on a receipt keeps
  supplier-declared, gross, tare, and net values in one unit, plus a weighing
  point reference. Gross less tare must equal net, and that net and unit must
  match the receipt's sole measured stock line. The typed read model exposes
  supplier variance as declared net minus measured net; the stock ledger
  receives measured net once.
- **Retries and competing use.** A repeated `request_id` returns the recorded
  transaction; a different request under it is refused. A posting locks the
  materials it touches before reading positions, and no location may go
  negative, so two callers cannot consume the same quantity.
- **Corrections.** A correction is a new transaction with a reason, the ID of
  the transaction it corrects, and signed adjustment lines. The original never
  changes: PostgreSQL refuses UPDATE, DELETE, and TRUNCATE on the ledger, and
  a deferred trigger refuses a commit whose entries do not balance.
  `list_corrections/3` reads a transaction's corrections, following
  corrections of corrections.
- **Transforms.** Inputs, outputs, and their genealogy links commit together.
  Observed quantities are never adjusted; when inputs and outputs differ, the
  transform needs `variance` evidence and a reconciliation basis, and the
  difference is recorded as a variance entry. For example, 100 kg measured
  in, 78 kg measured finished, 17 kg derived trim, and 2 kg measured waste
  leave a 3 kg variance.
- **Mixed native units.** A transform's lines may be in several native units,
  as a coating run is (film by area, glue by mass, coated film by area) or a
  slitting run (one counted roll in, counted rolls and weighed trim out).
  Each native unit balances on its own, and nothing is converted between
  units: every unit whose inputs and outputs differ records its difference as
  a variance entry in that unit, so the glue's mass on a coated roll measured
  by area is an 80 kg variance whose evidence and basis say so, not a hidden
  loss. `variance` carries `evidence` and `reconciliation_basis` shared by
  every differing unit, or `units` naming each differing unit's own, never
  both. Genealogy
  links are unaffected. A single-unit transform behaves as before.
- **Balances.** `get_transaction_balance/3` reads a transaction net of its
  corrections: `per_unit` gives each native unit's observed input, output,
  difference, and recorded variance. Accounting balance is separate from
  measurement agreement: `cross_unit` compares inputs and outputs across
  units only in a native unit that every line was posted in, natively or as
  its recorded unit. A recorded line counts at its recorded quantity, and
  the conversion version it was posted through is named, so film and a
  coated roll recorded in kilograms give a mass balance that the glue's
  kilograms enter as recorded. Nothing is converted at read time: a later
  conversion version never restates a posted balance, and a unit some line
  was not posted in has no cross-unit balance. No entry records a
  cross-unit difference.

## Lot and unit identities

A receipt or production output line may create an identity with
`identity: %{kind: "lot" | "unit", code: "..."}`. The code is unique for that
material within its company. Subsequent transfer, consumption, or transform
input lines cite its `identity_id`; a transform output creates a fresh identity.
When a transform uses any identity, every input and output must be identified.
Inventory checks both the overall location balance and the balance of the
specific identity, or the unidentified pool, before a draw. The stock entry
exposes `identity_id`, while `get_identity/3` returns the immutable code, kind,
item, and source transaction. For an individual unit, the creating line may
also include `dimensions: %{width: %{value: "1200", unit: "mm", provenance:
"measured"}}` inside `identity`. `length` and `thickness` use the same shape;
units are `um`, `mm`, `cm`, or `m`, and provenance is `measured` or `nominal`.
The typed dimensions remain on the immutable identity. `get_identity_positions/3`
returns its positive stock balances by location from the ledger, or an empty
list after the unit has been fully drawn.

`trace_backward/3` and `trace_forward/3` walk the transform links between
identities across any number of transformations. They return the root identity,
the visited identities, `{input_identity_id, output_identity_id,
transaction_id}` links, and source receipt transactions in `receipts`.
`list_identity_draws/3` lists the consumptions and transforms that drew an
identity, including consumption that created no link. Reads remain scoped to
one live company. Unidentified material remains supported for workflows that do
not track lots or individual units.

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

## Integration proof

These tests hold Inventory's Phase 4 claims:

| Claim | Test |
| --- | --- |
| Catalog, ledger, stock positions, and genealogy serve warehouse work in a runtime without Production Execution | `test/standalone_test.exs` |
| Inventory does not depend on Production Execution: no descriptor dependency, and its catalog, ledger, stock, and genealogy run where Production Execution is not loadable | `test/inventory_test.exs`, `test/standalone_test.exs` |
| With no authority registered, every production and transform posting is refused and warehouse postings continue | `test/posting_authority_test.exs` |
| An Extension cannot register (its declaration fails Inventory's boot) or post production context | `test/posting_authority_test.exs` |
| Production Execution is the declared authority, and its postings carry actual inputs and outputs, opaque context, and the execution's evidence atomically | `test/posting_boundary_test.exs` (compiled graph), `production_execution/test/execution_test.exs`, `production_execution/test/workflow_test.exs` |
| Distinct factory workflows (a foam extrude-cure-laminate-cut chain, coil slitting, and a coating-and-slitting chain mixing area, mass, and counted rolls) reconcile from Inventory transactions without changing earlier history | `production_execution/test/workflow_test.exs` |
| A transform balances per native unit with a variance per unit, and a cross-unit balance exists only in a unit every line was posted in | `test/transform_test.exs`, `production_execution/test/workflow_test.exs` |

The workflows are test fixtures only; Inventory holds no process rule or
source mapping for either.

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
