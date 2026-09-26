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
- Never commit a lock file here. Mounted builds share Bilimbi's ignored
  `.scratchpad/composition-lock/` overlay (`mix/composition_lock.exs`).
- CI is `.github/workflows/ci.yml`; the Bilimbi revision it builds against is
  the single line in `.github/bilimbi-revision`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
