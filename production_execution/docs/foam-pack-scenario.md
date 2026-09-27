# Representative foam pack scenario

`test/foam_pack_scenario_test.exs` runs the configuration and seed in
`test/support/foam_pack_scenario.ex` against the pinned Bilimbi workspace for
a generic packaging manufacturer. It is acceptance evidence for Factory's
public contracts, not a record of a confirmed plant process. No customer
Extension or migration is installed.

The route is receipt → warehouse stage → blend and extrude two labelled rolls →
cure-bay transfer → one early lamination with a refused attempt and authorised
override → one mature lamination → separate cuts at 1200 mm to 800 mm → separate
packs → terminal Inventory despatch. Inventory holds stock, movements, unit
identities, variance and genealogy. Product Definition retains the formula,
route, resources and seven-day hold. Production Execution owns each run and its
hold evidence. A `forecast:...` order reference and `shipment:...` and
`customer:...` despatch references remain opaque.

## Assumptions requiring plant confirmation

Every value below is representative.

| Area | Scenario stand-in to confirm |
| --- | --- |
| Weighing point, clerk, unit and source | Receiving `RCV`, clerk user 11, kilogram unit, ticket `WT-1`, supplier `SUP-1`, vehicle `JQK-1234`, declared net 72 kg, scale gross 812 kg, tare 742 kg, measured net 70 kg. Inventory stores these as typed receipt measurement values; only measured net enters stock. Supplier variance is declared minus measured net (+2 kg). The second 30 kg recycled receipt and 4 kg film receipt are also illustrative. |
| Storage and labels | Stage at `EXTRUDER-A`, then `CURE-A`; `ROLL-A` and `ROLL-B` are example unit labels. Physical label material, placement, scan reliability and network coverage remain untested. |
| Blend, colours, dimensions, extrusion | 70 kg virgin plus 30 kg recycled, blue of a proposed three-colour range, two 48 kg rolls, 4 kg process variance; each roll carries measured identity dimensions (and matching line evidence) of 1200 mm wide, 2 mm thick and 100 m long; each cut is a nominal 800 mm wide. Extruder `FP-EXTRUDE` and its timings are representative. |
| Cure and permission | 168 hours, an early attempt at 24 hours, a mature use at 192 hours, and granted user 9 with the illustrative reason “Representative supervised release”. Neither the actual minimum per product nor the actual approver and permission assignment is confirmed. |
| Demand, conversion and pack | `forecast:2026-09:sample` is an opaque demand token, not a claim that orders come from a sales backlog. One illustrative 1200→800 mm cut per roll turns 49 kg laminate into 32 kg product, 14 kg derived trim and 2 kg measured waste, leaving 1 kg variance. Per-roll cut yield is 32/49; the two-run yield is 64/98. Each 32 kg cut yields a 31 kg pack and 1 kg measured packing waste. Kilograms are a ledger unit, not a confirmed selling or packing unit. |
| Despatch and operational scope | `shipment:SHP-1` and `customer:DEST-1` are opaque examples. Destination, replacement of the plant's existing despatch record, certification scope and customer acceptance remain to be confirmed. The scenario makes no certification claim. |

## Public-contract limits found

- Inventory's typed receipt measurement closes the generic weigh-ticket gap:
  supplier-declared, gross, tare, net, shared unit, and weighing point are
  validated and readable, including declared-minus-net supplier variance.
  Supplier, vehicle, and ticket identifiers remain source evidence because the
  current contract does not define typed supplier or transport references.
  Grouping these fields in a report remains out of scope.
- Inventory now retains typed width, length and thickness with units and
  measured or nominal provenance on each identified output. `get_identity/3`
  reads them and `get_identity_positions/3` derives remaining locations and
  quantities from the ledger. A fully drawn roll has no current stock position.
  The scenario proves these reads for rolls and packs, while actual label and
  measurement practice still needs plant confirmation.
- `get_run_yield/3` reads each cut's 49 kg input, 32 kg product, 14 kg trim,
  2 kg waste and 1 kg variance from its Inventory transaction;
  `get_unit_yield/3` associates the input laminate unit with that run. These
  balances are native-unit quantities, not a plant-approved KPI definition.
  Should packs be stocked by count rather than mass, a cut or pack run may
  mix native units: Inventory then balances each unit on its own with a
  variance per unit, and reads a cross-unit balance only where the pack
  lines are also recorded in the other unit.
- The ledger and execution read models expose the facts needed for per-run
  material balance, but Factory has no monthly supplier/run/resource/location
  report API yet. In this scenario supplier remains free text and trim is
  marked derived. A customer month and its report remain unvalidated. This is
  reporting work, not evidence of a customer-specific rule.

The scenario covers contract expressibility for one representative flow. It
does not confirm plant values or complete a monthly acceptance phase.
