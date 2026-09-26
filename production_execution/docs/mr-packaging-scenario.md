# Representative Mr Packaging scenario

`test/mr_packaging_scenario_test.exs` runs the configuration and seed in
`test/support/mr_packaging_scenario.ex` against the pinned Bilimbi workspace.
It is acceptance evidence for Factory's public contracts, not a record of a
confirmed Muar plant process. No customer Extension or migration is installed.

The route is receipt → warehouse stage → blend and extrude two labelled rolls →
cure-bay transfer → one early lamination with a refused attempt and authorised
override → one mature lamination → separate cuts at 1200 mm to 800 mm → separate
packs → terminal Inventory despatch. Inventory holds stock, movements, unit
identities, variance and genealogy. Product Definition retains the formula,
route, resources and seven-day hold. Production Execution owns each run and its
hold evidence. A `forecast:...` order reference and `shipment:...` and
`customer:...` despatch references remain opaque.

## Assumptions requiring plant confirmation

Every value below is representative. Line numbers refer to Bilimbi's
`docs/plans/factory/mr-packaging-requirements.md` at the pinned revision.

| Requirement | Scenario stand-in to confirm |
| --- | --- |
| 52–54, 128–130: weighing point, clerk, unit and source | Receiving `RCV`, clerk user 11, kilogram native unit, ticket `WT-1`, supplier `SUP-1`, vehicle `JQK-1234`, declared net 72 kg, scale gross 812 kg, tare 742 kg, measured net 70 kg, difference −2 kg. The ticket values are explicit evidence; the ledger receives only measured net. The second 30 kg recycled receipt and 4 kg film receipt are also illustrative. |
| 55, 70, 137–139: storage and labels | Stage at `EXTRUDER-A`, then `CURE-A`; `ROLL-A` and `ROLL-B` are example unit labels. Physical label material, placement, scan reliability and network coverage remain untested. |
| 61–64, 147–149: blend, colours, dimensions, extrusion | 70 kg virgin plus 30 kg recycled, blue of a proposed three-colour range, two 48 kg rolls, 4 kg process variance; each roll is described in line evidence as 1200 mm wide, 2 mm thick and 100 m long. Extruder `MRP-EXTRUDE` and its timings are representative. |
| 71–73, 147, 151: cure and permission | 168 hours, an early attempt at 24 hours, a mature use at 192 hours, and granted user 9 with the illustrative reason “Representative supervised release”. Neither the actual minimum per product nor the actual approver and permission assignment is confirmed. |
| 79–83, 158–160: demand, conversion and pack | `forecast:2026-09:sample` is an opaque demand token, not a claim that orders come from a sales backlog. One illustrative 1200→800 mm cut per roll turns 49 kg laminate into 32 kg product, 14 kg derived trim and 2 kg measured waste, leaving 1 kg variance. Per-roll cut yield is 32/49; the two-run yield is 64/98. Each 32 kg cut yields a 31 kg pack and 1 kg measured packing waste. Kilograms are a ledger unit, not a confirmed selling or packing unit. |
| 82, 115, 177–181: despatch and operational scope | `shipment:SHP-1` and `customer:DEST-1` are opaque examples. Destination, AutoCard replacement, certification scope and customer acceptance remain to be confirmed. The scenario makes no certification claim. |

## Public-contract limits found

- Inventory's receipt records one stock quantity and free-text evidence. It has
  no typed declared, gross or tare measurements, supplier or vehicle reference,
  or calculated supplier-variance read model. The scenario keeps all ticket
  values and their source in evidence, posts measured net once, and calculates
  the difference as an assumption. A report cannot group or validate those
  fields reliably through today's public read model (requirements 52–54, 89,
  111). This is a generic receiving measurement gap to confirm with the plant;
  no MrPackaging Extension is proposed yet.
- Identity contains code, kind, item and immutable source transaction, while
  dimensions are only line evidence and location is inferred from transaction
  history. There is no public typed per-roll dimensions or current location
  read. The scenario proves the labelled transfer and derives cure age from
  the roll's source transaction, but a scan screen would need a generic Factory
  read model for those fields (requirements 63, 70–71, 113, 150). Confirm the
  actual label and measurement workflow before deciding whether an Extension
  is justified.
- The ledger and execution read models expose the facts needed for per-run
  material balance, but Factory has no monthly supplier/run/resource/location
  report API yet. In this scenario supplier remains free text and trim is
  marked derived. A customer month and its report remain unvalidated
  (requirements 89–92, 118, 167–171). This is reporting work, not evidence
  of a customer-specific rule.

The scenario covers contract expressibility for one representative flow. It
does not confirm plant values or complete the requirements' monthly acceptance
phase.
