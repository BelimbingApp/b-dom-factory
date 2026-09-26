# Factory Production Execution

Production Execution records orders or batches, completed routed operations,
and material hold overrides. The public
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
(`source: :import`). Attributes are:

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
  Inventory validates stock, units, and conversions.
- `variance`: optional Inventory transform evidence with `evidence` and
  `reconciliation_basis`; required when actual inputs and outputs differ.
  Accepted only when the execution has both inputs and outputs.
- A Formula input with `material_hold_rule: %{"hours" => positive_integer}`
  (or a Formula or routing `process_config.material_hold_rules` entry keyed by
  the input item ID; the longest applicable minimum governs)
  requires each matching actual input to name an Inventory `identity_id`.
  Inventory resolves its immutable source transaction; the hold age runs from
  that transaction's effective time to execution completion. A missing,
  mismatched, or future source is refused. Inventory verifies that the named
  identity still holds the consumed quantity at the location. An identified
  transform input also requires identified outputs.
- For early consumption, provide `hold_override` with `actor`, a
  `Bilimbi.Base.Authz.Actor` in the scope's tenant and the execution's
  company, and a nonblank `reason`. Base Authz must grant
  `factory.production-execution.material-hold.override` to that actor. The
  decision runs before the posting transaction, so a refused attempt keeps
  its Authz decision log. Bilimbi's `Scope` does not yet carry an
  authenticated actor, so this principal is caller-asserted until it does.
- A live override records the actor as both approver (`actor_*`) and
  recorder (`recorded_by_*`), timed when authorized. An import also supplies
  the source `evidence`, the historical `occurred_at` (not after completion),
  and optionally the historical `approver` (`type`, `id`, and an agent's
  `acting_for_user_id`); its approver is null when the source names none,
  and the importing actor is recorded only in `recorded_by_*`.
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

The [representative Mr Packaging scenario](mr-packaging-scenario.md) exercises
these contracts from receipt to despatch and lists every plant assumption and
public-contract limit found during that validation.
The [representative SBG scenario](sbg-scenario.md) does the same for glue,
coating, and slitting.
