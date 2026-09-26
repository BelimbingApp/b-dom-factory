# b-dom-factory Agent Guide

This repository is the Factory Domain for Bilimbi. It is not a standalone Mix
project: it builds only when mounted in a Bilimbi checkout at
`apps/domains/factory` (see `README.md` for the mount commands and naming
convention). Read Bilimbi's root `AGENTS.md`, `apps/domains/AGENTS.md`, and
`docs/architecture/0010_composition-model.md` in that checkout before changing
anything here; they govern this code and are not copied here. Factory's scope
and phases are Bilimbi's `docs/plans/factory/0000-factory-domain.md` and
`docs/plans/factory/0010-inventory-module.md`.

## Working here

- Run Mix from the Bilimbi root, not from this repository: `mix precommit`
  there tests every mounted module, and database tasks refuse a partial graph.
  To test one module, run `mix test` inside that module's folder.
- The container (`bilimbi.container.exs`, `mix.exs`) holds no `lib/`,
  `priv/`, or `test/`; Bilimbi's workspace-boundary test rejects them. Code
  lives in an immediate child module folder with its own `bilimbi.module.exs`,
  `mix.exs`, `lib/<folder>.ex` facade, `test/`, and `docs/`.
- A module's `bilimbi.module.exs` is its dependency list; `mix.exs` derives
  path dependencies from it. Declare every `Bilimbi.*` namespace a module
  references there, or Bilimbi's `.github/scripts/graph_edges.exs` fails.
- Namespaces are `Bilimbi.Factory.<Module>` with OTP app
  `:bilimbi_factory_<folder>`, matching Base and Core's
  `Bilimbi.<Container>.<Module>` shape that the graph-edge check keys on.
- Use `ProductDefinition.select_revisions/5` for an order's exact definition
  selection; its facade validates Inventory references through Inventory's public
  API. Do not read either module's private tables from another module.
- Mount a real copy (clone or `rsync`), not a symlink: `mix.exs` locates the
  Platform with `__DIR__`, which resolves through a symlink to this checkout.
- A `schema_contract` describes only `:compatible_baseline` tables (Belimbing's
  shape); adoption refuses a missing table, so Bilimbi-only tables stay out,
  as Core Geonames' postcode overrides do. `inventory/lib/inventory/schema_contract.ex`
  is the example.
- Module tests run against temporary tables built in each module's
  `test/support/test_fixtures.ex`, not its migrations (Core Compatibility runs
  those). Mirror a new migration's constraints and triggers there, or a test
  that makes PostgreSQL refuse proves nothing.
- Lot and unit postings use `identity` on a receipt or output line and
  `identity_id` on later draws; Inventory's `trace_backward/3` and
  `trace_forward/3` read the existing transform links. See
  `inventory/docs/README.md` and `inventory/lib/inventory/genealogy.ex`;
  do not build a second ancestry store.
- A new factory workflow shape is proved as a fixture in
  `production_execution/test/workflow_test.exs`, which reconciles it from
  Inventory transactions; never add a process rule or source mapping to
  Inventory. Inventory's boundary claims and their tests are listed in
  `inventory/docs/README.md` (Integration proof).
- `ModuleRegistry.installed_modules!/0` raises in a module-folder `mix test`,
  which loads only part of the graph. Read one application's descriptor with
  `Application.get_env(app, :bilimbi_module)`, as
  `inventory/lib/inventory/posting_authority.ex` does.
- Module discovery refuses any `bilimbi.module.exs` key beyond the
  descriptor's own. Carry extra composition metadata in the module's
  `mix.exs` application env beside `MixDiscovery.application_env/1`, as a
  production posting authority is declared (`inventory/docs/README.md`).
- `inventory/test/posting_boundary_test.exs`'s `:compiled_graph` test needs
  the whole mounted graph compiled; a module-folder `mix test` excludes it,
  and CI runs it with `mix test --only compiled_graph` after compiling.
- `.github/scripts/missing_dependency.sh` moves Factory out of the mounted
  workspace and mounts a throwaway Extension, so CI runs it as the last step;
  never commit that fixture or add a real Extension to prove the refusal.
- Never commit a lock file here. Mounted builds share Bilimbi's ignored
  `.scratchpad/composition-lock/` overlay (`mix/composition_lock.exs`).
- CI is `.github/workflows/ci.yml`; the Bilimbi revision it builds against is
  the single line in `.github/bilimbi-revision`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
