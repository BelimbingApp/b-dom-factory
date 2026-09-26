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
- Use Inventory's public `trace_backward/3`, `trace_forward/3`, and
  `list_identity_draws/3` for material ancestry and use, then join execution
  context by transaction ID as `lib/production_execution/trace.ex` does;
  never keep another ancestry table.
- For a held input, use Inventory's `identity_id` and immutable source
  transaction through its public API, as described in `docs/README.md`.
  Do not accept a caller-supplied start time. Run the override Authz decision
  before `complete_operation/5` opens its transaction, so a refusal keeps its
  decision log; inside, only insert override evidence with the postings.
- For a customer receipt-to-despatch acceptance case, keep configuration and
  assumed plant values in a test fixture and its scenario doc, as in
  `test/support/mr_packaging_scenario.ex` and `docs/mr-packaging-scenario.md`;
  use Factory facades for postings and leave customer process rules out of
  Inventory.
- For SBG glue, coating, and slitting, use the public import and trace path in
  `test/support/sbg_scenario.ex` and `docs/sbg-scenario.md`. Product Definition
  accepts only its documented `process_config` keys; list unconfirmed reactor,
  cleaning, and source fields in that doc until a generic public contract is
  agreed, rather than hiding them in another configuration key or the fixture.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
