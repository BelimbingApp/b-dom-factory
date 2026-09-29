# Factory Production Execution

Production Execution records orders or batches, completed routed operations,
material hold overrides, and shop-floor capture against a run. The public
facade is `Bilimbi.Factory.ProductionExecution`. The module declares its
Inventory production posting authority in `mix.exs` application metadata.

Create an order with `create_order(scope, company_id, attrs)`. Attributes are
`code`, `kind` (`"order"` or `"batch"`), `product_id`,
`formula_version`, `routing_version`, and optional opaque `demand_ref`
(the demand-source reference Bilimbi's
`docs/plans/factory/0000-factory-domain.md` line 89 allows on an order).
The exact pair of revisions is validated through Product Definition and
retained on the order and every execution.

Use `complete_operation(scope, company_id, order_id, source, attrs)` for
both live commands (`source: :live`) and historical imports
(`source: :import`).

An import requires the `factory.production-execution.import` capability for
the order's company on the Scope's principal. An administrator grants it to a
user or a named system principal for that company; without the grant,
`complete_operation/5` returns `{:error, :import_not_authorized}` before
posting. Live completion does not require this capability. Identical import
retries are checked again, so revoking a grant also prevents retries.

Attributes are:

- `request_id`: company-unique retry key. Identical retries return the
  original execution; conflicting retries fail.
- `operation_code`, `resource_id`: a step in the selected routing and
  one of its allowed physical resources.
- `operator_type`, `operator_id`, `started_at`, `completed_at`, `evidence`:
  who did the work, when, and its source record. Both times are UTC DateTimes;
  a late import keeps its historical completion time as Inventory's effective
  time and gets a separate recorded time.
- `inputs`, `outputs`: actual lines with `item_id`, `location_id`,
  positive `quantity`, `observation`, and optional `unit_id`,
  `conversion_version`, `evidence`, `output_role`, `identity_id` on inputs,
  and `identity` on outputs. Items must belong to the selected operation.
  Inventory validates stock, units, and conversions. Lines may mix native
  units, as coating (film by area, glue by mass) and slitting (counted rolls,
  weighed trim) do; Inventory balances each native unit on its own.
- `variance`: optional Inventory transform evidence, required for every
  native unit whose actual inputs and outputs differ: `evidence` and
  `reconciliation_basis` shared by the differing units, or `units` naming a
  unit's own (`unit_id`, `evidence`, `reconciliation_basis`), not both.
  Accepted only when the execution has both inputs and outputs. Inventory
  records the difference per unit as a variance entry; nothing is converted.
- A Formula input with `material_hold_rule: %{"hours" => positive_integer}`
  (or a Formula or routing `process_config.material_hold_rules` entry keyed by
  the input item ID; the longest applicable minimum governs)
  requires each matching actual input to name an Inventory `identity_id`.
  Inventory resolves its immutable source transaction; the hold age runs from
  that transaction's effective time to execution completion. A missing,
  mismatched, or future source is refused. Inventory verifies that the named
  identity still holds the consumed quantity at the location. An identified
  transform input also requires identified outputs.
- For early consumption, provide `hold_override` with a nonblank `reason`.
  The Scope must carry an authenticated user in the execution's company, with
  the `factory.production-execution.material-hold.override` capability; a
  system Scope is refused, and so is an impersonated session
  (`:override_refused_under_impersonation`). The decision runs before the
  posting transaction, so a refused attempt keeps its Authz decision log.
  Callers cannot name the recorder, or a live approver, in the override data.
- A live override records the Scope's authenticated user as both approver
  (`actor_*`) and recorder (`recorded_by_*`), timed when authorized. An import
  also supplies source `evidence`, the historical `occurred_at` (not after
  completion), and optionally the historical `approver` (`type`, `id`, and an
  agent's `acting_for_user_id`); its approver is null when the source names
  none, is never used for the permission check, and the Scope's user is
  recorded only in `recorded_by_*`.
  `list_hold_overrides/3` returns the source, approver, recorder, time,
  reason, evidence, identity, execution, and Inventory transaction.

The facade posts through Inventory's named production functions, carrying
opaque execution, order/batch, and resource references. Execution and material
effects use one Repo transaction, so neither survives a failure in the other.
The identity is the affected lot or physical unit. Create it on the Inventory
receipt or production output, and preserve its ID on subsequent material
movements.

## Production trace

`trace_backward(scope, company_id, identity_id)` and
`trace_forward(scope, company_id, identity_id)` return `%{material: genealogy,
runs: runs}`. `material` is Inventory's public trace result: root identity,
visited identities, transform links, and source receipts. Each run contains
the execution ID, order or batch, operation code, resource, timing, source,
and Inventory transaction ID. Runs are ordered by completion time and ID.
The view joins executions by the Inventory transaction IDs on visited
identities and links; a forward trace also joins the consumptions and
transforms that drew a visited identity (`Inventory.list_identity_draws/3`),
so a run without an identified output still appears. Inventory alone stores
material ancestry.

`get_run_yield/3` derives one execution's `balances` from its linked Inventory
transaction: one group per native unit, each with that unit, input, product,
trim, waste, and signed variance. A single-unit run has one group; a run that
mixes kilograms and litres has two, and quantities are never converted between
units. `cross_unit` is Inventory's `get_transaction_balance/3` agreement
across units: present only in a unit every line was posted in, natively or
as its recorded unit, naming the conversion versions the lines were posted
through, and empty otherwise; a later conversion version does not change it.
Product includes output roles other than `trim` and `waste`. Each
correction of the run's transaction, and each correction of those corrections
(`Inventory.list_corrections/3`), nets into the side of the run entry it adjusts,
so yields agree with `Inventory.get_identity_positions/3`. `corrected` is true
when any exist and `correction_transaction_ids` lists them in ID order.
`get_unit_yield/3` lists the balances of the unit's creation run and later
production draws; each group also carries that unit's own `unit_input` and
`unit_output`. A balance belongs to the whole run; Factory does not invent a
share of a multi-input run for one unit.
Only transforms have an input-to-output conservation balance; a standalone
output or consumption run has one side only.

## Shop-floor capture

A run is an execution: the unit an operator records against on the shop
floor. Capture takes the same recorder rule as a live hold override: the
Scope's authenticated user in the run's company is the recorder, a caller
cannot name one, and an impersonated session is refused
(`:capture_refused_under_impersonation`). Each write is decided by Base Authz
against the run's production order before any transaction opens, so a
refusal (`:capture_not_authorized`) keeps its decision log. Recording and
correcting are separate capabilities, so a company can let operators record
and only supervisors correct. Capture evidence is append-only: PostgreSQL
refuses UPDATE, DELETE, and TRUNCATE, and a correction is a new record that
names the one it corrects, with a nonblank `correction_reason`. A record is
corrected at most once, so its corrections form one chain; a list marks each
record's `corrected_by_id`, and records without one are current.

### Wastage

Wastage reasons are the company's configuration, managed at
`/factory/wastage-reasons` or through `create_wastage_reason/3`,
`update_wastage_reason/4`, `get_wastage_reason/3`, and
`list_wastage_reasons/3`: an upper-cased `code` that is fixed once created,
a `label`, and `active`. Deactivating a reason stops new records from using
it; recorded wastage keeps it.

`record_wastage(scope, company_id, execution_id, attrs)` needs
`factory.production-execution.wastage.record` on the order. It takes a
company-unique `request_id` (an identical retry returns the record, a
different one under it is `:request_id_conflict`), an active `reason_id`,
the `item_id` and `identity_id` of one of the run's posted stock lines, the
`location_id` it is drawn from, a positive `quantity` in that material's
native unit, an `observation` from `Inventory.observations/0`, an optional
`note`, and an optional past `occurred_at` that is not before the run
started (default now). It posts through Inventory as production consumption
carrying the run's execution, order, and resource context, with the reason
in its evidence, so the scrapped material leaves stock at that location.

`correct_wastage(scope, company_id, wastage_id, attrs)` needs
`factory.production-execution.wastage.correct`. It takes a `request_id`,
`correction_reason`, the corrected `quantity` (zero voids the record), and
optionally a different active `reason_id` or `note`. A changed quantity
posts an Inventory correction of the chain's consumption for the
difference; an unchanged one posts nothing. `list_wastage/3` reads a run's
records in ID order.

`get_run_yield/3` includes recorded wastage: a draw nets into the side of
the run's line it came from (a run's input material raises input, its own
output lowers product) and the same quantity counts as waste, so input still
equals product, trim, waste, and variance. Each balance also carries
`wastage`, the recorded part of `waste`, and the run lists its
`wastage_transaction_ids`. Positions from `Inventory.get_identity_positions/3`
agree.

### Labour

Labour roles are the company's configuration, managed at
`/factory/labour-roles` or through `create_labour_role/3`,
`update_labour_role/4`, `get_labour_role/3`, and `list_labour_roles/3`, the
same shape as wastage reasons.

A labour entry is time a company user (Core User, in the order's company)
works on an order, optionally on one of its runs (`execution_id`), in an
active role. `clock_in/4` opens one now; `clock_out/3` closes it now, the one
update an entry allows, recording who stopped it; `record_labour/4` records a
finished entry with past `started_at` and `stopped_at`. Recording one's own
time needs `factory.production-execution.labour.record`; anyone else's, and
every correction, needs `factory.production-execution.labour.manage`. A
worker has at most one open entry (`:worker_already_clocked_in`) and a
worker's current entries never overlap (`:labour_overlap`; an open entry
runs to now). `correct_labour/4` replaces an entry with a new one naming it,
keeping its worker and order and changing any of its times, role, run, or
note; a corrected entry can no longer be clocked out. `list_labour/3` lists
an order's entries with each closed entry's `seconds`, and
`labour_summary/3` totals the current ones per run and per worker, with those
still open.

### Output measurements

Measurement types are the company's configuration, managed at
`/factory/measurement-types` or through `create_measurement_type/3`,
`update_measurement_type/4`, `get_measurement_type/3`, and
`list_measurement_types/3`. A type is one property definition in Inventory's
shape (`Bilimbi.Factory.Inventory.PropertyDefinition`): a `label`, a
`value_type` (`string`, `integer`, `decimal`, or `boolean`), and a `unit`
only for a numeric type, plus an upper-cased `code` and, for a numeric type,
optional decimal `minimum`, `maximum`, and `target` (minimum not above
maximum). For example, a company might define a mass-per-area measure in
`g/m2` with a target and limits. The code, value type, and unit are fixed
once created; the label, limits, and `active` change.

`record_measurement(scope, company_id, execution_id, attrs)` needs
`factory.production-execution.measurement.record` on the order and follows
the capture recorder rule. It takes a company-unique `request_id`, an active
`measurement_type_id`, a `value` validated as that type's property value (a
decimal as a string or Decimal), an optional `identity_id` naming one of the
run's output lots or units (nil measures the run's output as a whole;
anything else is `:identity_not_run_output`), an optional `note`, and an
optional past `measured_at`, not before the run started. The measurement
keeps the type's unit and limits as they were, and `out_of_range` is true
when a numeric value falls outside the inclusive minimum or maximum, false
inside them, and nil when the type had no limits or is not numeric, so a
later change to a type's limits never restates a recorded flag.
`correct_measurement/4` (`factory.production-execution.measurement.correct`)
replaces a value or note with a new measurement naming the original, judged
against the original's limits; `list_measurements/3` reads a run's
measurements in ID order.

### Shop-floor page

`/factory/floor` (`factory.production-execution.floor.view`) is the
tablet page: pick an order, then one of its runs, then record wastage with
large controls, measure its output (out-of-range values are flagged), and
see the run's yield. The order and each run also show a labour panel: pick
a role and clock in or out, see totals per run, and, for a supervisor, clock
in someone else, add a finished entry, or correct one.
Entered times are read in the company time zone the page displays (UTC for
a reader who displays UTC); a labour correction's time left as shown keeps
the entry's exact recorded time. Recording and correcting controls
appear only with their capabilities, and the facade refuses a forged event
regardless. Orders and runs are read with `list_orders/3` and
`list_executions/3`.

The [representative foam pack scenario](foam-pack-scenario.md) exercises
these contracts from receipt to despatch and lists every plant assumption and
public-contract limit found during that validation.
The [representative mix, coat, and slit scenario](mix-coat-slit-scenario.md)
does the same for glue mixing, coating, and slitting, including historical
import submissions.
