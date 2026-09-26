# Factory Inventory

Inventory owns Factory's material facts: items, locations, units of measure,
the Material Transaction ledger, material units, and Lot/Unit Genealogy.
Warehouse movements post here directly; production effects arrive through the
production posting authority that Production Execution registers.

The public contract and its phases are defined in Bilimbi's
[Inventory module plan](https://github.com/BelimbingApp/bilimbi/blob/main/docs/plans/factory/0010-inventory-module.md).
Phase 1 (catalog, locations, and units) is built; the ledger, genealogy, and
posting authority are not.

## Public API

`Bilimbi.Factory.Inventory` is the whole API. Every operation takes a
`Bilimbi.Base.Tenancy.Scope` and a company ID; the company must be live in the
scope's tenant (Core Company's `get_company/2` decides). A record of another
company is reported as not found. Results are read models (`Item`, `Unit`,
`Location`, `Material`, `Conversion`, `StockPosition`), never schemas.

| Area | Operations |
| --- | --- |
| Item master | `list_items/3`, `get_item/3`, `get_item_by_sku/3`, `create_item/3` |
| Units | `list_units/3`, `get_unit/3`, `create_unit/3` |
| Locations | `list_locations/3`, `get_location/3`, `create_location/3` |
| Material identity | `register_material/4`, `get_material/3` |
| Conversions | `define_conversion/5`, `list_conversions/3`, `get_conversion/5` |
| Stock position | `get_stock_position/4` |

- **Material identity.** An item becomes a stocked material once, with a
  native unit that never changes afterwards. Stock quantities are always held
  in that unit.
- **Conversions.** One conversion unit equals `factor` native units. Rows are
  immutable, so a changed factor is the next version. The earlier versions
  stay readable, so a converted quantity can name the basis it used.
- **Stock positions.** A position is read by item and location, in the native
  unit. Positions are views over the Material Transaction ledger. That ledger
  is Phase 2, so every position reads zero today. Inventory does not depend on
  Production Execution.

## Persistence

| Table | Disposition | Notes |
| --- | --- | --- |
| `commerce_inventory_items` | compatible baseline | Belimbing's item master, verified by `SchemaContract` and adopted as is |
| `factory_inventory_units`, `factory_inventory_locations`, `factory_inventory_materials`, `factory_inventory_unit_conversions` | Bilimbi-only | company-owned; not in the schema contract, because an adopted Belimbing database gets them from `mix bilimbi.migrate` |

The item master keeps Belimbing's own columns, including the location-less
`quantity_on_hand` and free-text `storage_location`. Inventory neither changes
them nor derives stock positions from them. `category_id` and
`product_template_id` point at Belimbing's Commerce Catalog, which Bilimbi
does not have, so they are read as opaque IDs and `create_item/3` does not
accept them. Belimbing's item photos and marketplace fitments are Commerce
concerns and are not carried here.

The contribution provider declares Belimbing's `commerce.inventory.*`
capabilities under their original keys, so grants in an adopted database keep
naming a declared capability.
