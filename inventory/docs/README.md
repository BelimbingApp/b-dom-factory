# Factory Inventory

Inventory owns Factory's material facts: items, locations, units of measure,
the Material Transaction ledger, material units, and Lot/Unit Genealogy.
Warehouse movements post here directly; production effects arrive through the
production posting authority that Production Execution registers.

This package is a scaffold. It declares the module identity and has no public
API, schema, or migration yet. The public contract and its phases are defined
in Bilimbi's [Inventory module plan](https://github.com/BelimbingApp/bilimbi/blob/main/docs/plans/factory/0010-inventory-module.md).
