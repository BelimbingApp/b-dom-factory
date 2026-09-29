# Production Execution

- Use `Bilimbi.Factory.ProductionExecution.complete_operation/5` for live
  commands and historical imports. It validates the selected operation and
  atomically posts through Inventory's public named production functions;
  direct Inventory posting can bypass routing and execution evidence.
- Keep the posting authority declaration in this module's `mix.exs`
  application metadata, not in `bilimbi.module.exs`; module discovery accepts
  only descriptor keys. See `inventory/lib/inventory/posting_authority.ex`.
- Module-local tests build temporary tables with
  `test/support/test_fixtures.ex`'s `create_production_tables!/0` after
  Inventory's `mill!/0`; mirror migration constraints there when persistence
  changes, rather than creating tables in a test file.
- A resource belongs to a company resource type
  (`ProductDefinition.create_resource_type/3`); a fixture creates one type
  once and passes its `resource_type_id`, and the type's code is fixture
  data, not a code constant.
- Use Inventory's public `trace_backward/3`, `trace_forward/3`, and
  `list_identity_draws/3` for material ancestry and use, then join execution
  context by transaction ID as `lib/production_execution/trace.ex` does;
  never keep another ancestry table.
- For a held input, use Inventory's `identity_id` and immutable source
  transaction through its public API, as described in `docs/README.md`.
  Do not accept a caller-supplied start time. Run the override Authz decision
  before `complete_operation/5` opens its transaction, so a refusal keeps its
  decision log; inside, only insert override evidence with the postings.
- For hold overrides, live or imported, take the recorder from
  `Authz.scope_actor/1` and decide with `Authz.can/4` on the Scope; never
  accept an actor in override data, and refuse an impersonated Scope. An
  import's historical `approver` is source evidence only (`docs/README.md`).
- For a receipt-to-despatch acceptance case, keep configuration and assumed
  plant values in a test fixture and its scenario doc, as in
  `test/support/foam_pack_scenario.ex` and `docs/foam-pack-scenario.md`; use
  Factory facades for postings and leave customer process rules out of
  Inventory.
- For a mix, coat, and slit chain with historical imports, use the public
  import and trace path in `test/support/mix_coat_slit_scenario.ex` and
  `docs/mix-coat-slit-scenario.md`. Product Definition accepts only its
  documented `process_config` keys; list unconfirmed reactor, cleaning, and
  source fields in that doc until a generic public contract is agreed, rather
  than hiding them in another configuration key or the fixture.
- For a run that mixes native units (film by area, glue by mass, counted
  rolls), pass each line in its own unit and give `variance.units` evidence
  per differing unit; read `get_run_yield/3`'s `balances` per unit and its
  `cross_unit` from Inventory. Do not convert lines to one unit before posting
  or compute a cross-unit figure here: `inventory/lib/inventory/balance.ex`
  defines when one exists.
- For a unit's physical size and location, use Inventory identity dimensions
  and `get_identity_positions/3`; for run and input-unit material balances use
  `get_run_yield/3` and `get_unit_yield/3`. Their sources are the existing
  Inventory ledger and execution link, so do not parse line evidence or keep
  another yield or location store.
- For shop-floor capture against a run, resolve the recorder with
  `Capture.recorder/2` and decide with `Capture.authorize/4` before opening a
  transaction (`lib/production_execution/capture.ex`); keep the evidence
  append-only and correct it with a new row naming the corrected one, as
  `lib/production_execution/wastage.ex` does. Never update a capture row.
- A company's shop-floor code list (code, label, active) is a table read
  through `lib/production_execution/capture_codes.ex` and administered with
  `Web.CodeList`; do not hard-code the entries or build another admin screen
  for one.
- Inventory production postings must be called lexically in the facade
  module: the compiled-graph boundary test accepts only the declared
  authority module, so a helper module that posts fails CI.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
