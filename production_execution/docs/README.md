# Factory Production Execution

Production Execution records actual work: production orders or batches, their
operation executions, and the inputs, outputs, resources, and variance each
one recorded. It posts material effects through Inventory's public contract
and builds trace as a read model over Inventory genealogy, so its descriptor
declares `factory/inventory`.

This package is a scaffold. It declares the module identity and dependency and
has no public API, schema, or migration yet. Its scope and phases are in
Bilimbi's [Factory Domain plan](https://github.com/BelimbingApp/bilimbi/blob/main/docs/plans/factory/0000-factory-domain.md).
