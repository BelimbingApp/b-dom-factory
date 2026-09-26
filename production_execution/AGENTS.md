# Production Execution

- Use `Bilimbi.Factory.ProductionExecution.complete_operation/5` for live
  commands and historical imports. It validates the selected operation and
  atomically posts through Inventory's public named production functions;
  direct Inventory posting can bypass routing and execution evidence.
- Keep the posting authority declaration in this module's `mix.exs`
  application metadata, not in `bilimbi.module.exs`; module discovery accepts
  only descriptor keys. See `inventory/lib/inventory/posting_authority.ex`.
- Module-local tests use temporary tables in `test/execution_test.exs`.
  Mirror migration constraints there when persistence changes.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
