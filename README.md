# b-dom-factory

Factory Domain for [Bilimbi](https://github.com/BelimbingApp/bilimbi):
Inventory, Product Definition, and Production Execution. It is one optional,
independently versioned repository that a manufacturing adopter mounts into a
Bilimbi checkout; it does not build on its own.

| Module | Descriptor ID | Owns |
| --- | --- | --- |
| [`inventory/`](inventory/docs/README.md) | `factory/inventory` | material facts, the Material Transaction ledger, Lot/Unit Genealogy |
| [`product_definition/`](product_definition/docs/README.md) | `factory/product_definition` | what is made and how: BOMs, routings, work centres |
| [`production_execution/`](production_execution/docs/README.md) | `factory/production_execution` | actual work and its Inventory postings; depends on Inventory and Product Definition |

Inventory has its catalog, locations, units, stock positions, Material
Transaction ledger, lot and unit genealogy, and production posting-authority registry; Product
Definition has Phase 1 product, Formula/BOM and routing revisions;
Production Execution records orders, batches, actual routed work, and
material hold overrides with atomic Inventory postings. Their scope
and phases are in Bilimbi's
[Factory Domain plan](https://github.com/BelimbingApp/bilimbi/blob/main/docs/plans/factory/0000-factory-domain.md) and
[Inventory module plan](https://github.com/BelimbingApp/bilimbi/blob/main/docs/plans/factory/0010-inventory-module.md).

## Mount

Clone this repository into a Bilimbi checkout at `apps/domains/factory`, then
work from the Bilimbi root:

```sh
git clone https://github.com/BelimbingApp/b-dom-factory.git apps/domains/factory
mix deps.get
mix precommit
```

Bilimbi discovers the mounted container from `bilimbi.container.exs`; no list
names it. Removing the directory removes Factory's code from the next build and
keeps its data. The composition rules, including the shared composition lock,
are in Bilimbi's
[composition model](https://github.com/BelimbingApp/bilimbi/blob/main/docs/architecture/0010_composition-model.md).

## Naming

Optional Bilimbi repositories are named `b-<role>-<id>`: `b-` for Bilimbi,
`dom-` for a Domain. The mount folder is the container ID, with hyphens as
underscores, so `b-dom-factory` mounts at `apps/domains/factory`.

## CI

CI checks out Bilimbi at the revision in
[`.github/bilimbi-revision`](.github/bilimbi-revision), mounts this
repository, and runs Bilimbi's precommit over the composed workspace. Bump that
revision to build against a newer Platform.

## License

[MIT](LICENSE).
