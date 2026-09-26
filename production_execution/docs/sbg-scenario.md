# Representative SBG Factory scenario

`test/sbg_scenario_test.exs` seeds `test/support/sbg_scenario.ex` and exercises
Factory's public Inventory, Product Definition, and Production Execution APIs.
All values are synthetic. No SBG Extension, AX connection, AX credential, or
private recipe is present. The two glue operations enter as historical
`:import` submissions; coating and slitting use the live contract. Production
Execution posts all four material transformations into Inventory's one ledger.

The illustrative flow is BA and additive receipts → wet glue mixing in a
reactor → dry glue → BOPP coating on a line → a 1200 mm roll slit into 600 mm
and 300 mm rolls, derived trim, and measured waste. Inventory genealogy traces
each slit roll through coating and glue to all three receipts. Product
Definition stores the selected generic formula shape, process family, and
route revisions, and refuses the proposed glue process metadata. No
confidential recipe is included.

## Values requiring SBG confirmation

Line references are to Bilimbi's `docs/plans/factory/sbg-requirements.md`.
Every value below is a stand-in, including codes, quantities, units, timing,
identities, people, and provenance. Glue metadata with no Factory contract
(capacity, type, revision, previous batch, cleaning, Quality token) appears
only here, not in the fixture.

| Requirement lines | Scenario value requiring confirmation |
| --- | --- |
| 49–52, 161, 203–215 | Company 73; BA, additive, and BOPP as the three stock items; kilogram as each item's native unit; receiving location `RCV`; 70 kg BA lot `BA-LOT-1`, 30 kg additive lot `ADDITIVE-LOT-1`, and 50 kg BOPP lot `BOPP-LOT-1`; receipt IDs `SBG-RCV-*` and synthetic receiving ticket evidence. These quantities are measured examples, not AX facts. Confirm actual item codes, source, UOM, warehouse, lot and ticket identifiers, and receipt ownership. |
| 35–37, 78–84, 166–169, 221–225 | Glue batch/job `SBG-GLUE-BATCH-1`, prior batch `SBG-GLUE-BATCH-0`, reactor `REACTOR-A`, stated 120 kg capacity, representative glue type A, revision `R1`, cleaning sequence `CLEAN-1`, pending Quality result token `quality:pending`, operator user 9 and helper user 12. Confirm whether helper, previous batch, cleaning, capacity, and Quality reference are source facts, operator evidence, or unavailable. No Quality result is asserted. |
| 35–37, 166–169, 223–228 | `MIX-WET` consumes 70 kg BA plus 30 kg additive and records 98 kg wet glue lot `GLUE-WET-1` with 2 kg variance. `DRY` consumes that 98 kg and records 80 kg dry glue lot `GLUE-DRY-1` with 18 kg variance. Both use reactor `REACTOR-A`. Confirm actual wet/dry units, observations, reconciliation basis, permissible tolerances, and whether drying is a distinct routed operation. The 2 kg and 18 kg are illustrative losses, not inferred wastage reasons. |
| 72–76, 107–137, 161–165, 226–228, 310–311 | Historical import IDs `SBG-AX-GLUE-WET-1` and `SBG-AX-GLUE-DRY-1`, synthetic source batch `AX-SNAPSHOT-1`, receipt at 32 days ago, wet mixing at 30 days ago, dry at 29 days ago, and 10 minute run durations. Confirm real AX keys, source schema and version, extract time, effective period, time zone, candidate/active state, freshness threshold, tenant/company mapping, and import actor. The source batch text is opaque evidence only; no AX row or connector is implemented. |
| 35–37, 170–173, 229–232 | Coating order `SBG-PO-COAT-1`, line `COATER-A`, `COAT` operation, live request `SBG-COAT-1`, 50 kg BOPP plus 80 kg dry glue, 125 kg good coated output `COATED-ROLL-1`, and 5 kg variance; coating occurs two days ago. Confirm order and line identifiers, material mix, good-output observation, variance basis, operator and timing. The example yield is 125/130 by mass; this is not a validated coating KPI. |
| 35–37, 170–173, 229–232 | Slitting order `SBG-PO-SLIT-1`, resource `SLITTER-A`, live request `SBG-SLIT-1`, one day ago; a 125 kg coated roll at 1200 mm feeds 60 kg `SLIT-600-1` at 600 mm and 30 kg `SLIT-300-1` at 300 mm, 30 kg derived `TRIM-1` for the remaining illustrative 300 mm, 3 kg measured `WASTE-1`, and 2 kg variance. Confirm actual width/weight measurement, width allocation, trim derivation, observed waste, variance basis, output labels, and yield denominator. Good output is 90/125 by mass in this example. |
| 61–63, 125–137, 190–192, 231–234 | Operator user 9, helper user 12, machine codes, synthetic scale/run sheets, and `quality:pending` are sample evidence only. Energy, labour hours, GSM, wastage reason, and discontinued COA fields are absent. Confirm who may see each source and recipe field and how missing data is shown. The fixture makes no measured claim for those unavailable fields. |

## Public contract gaps and limits

- Factory records a historical execution with `source: "import"`, stable
  `request_id`, effective time, evidence, selected definitions, and atomic
  Inventory effects. Its evidence and line maps are opaque. It has no typed
  AX source identity, extraction timestamp, source schema/version, candidate
  status, freshness, or tenant mapping read model. Those are SBG Connector
  responsibilities under lines 72–76 and 163–165; the Extension must retain
  them and submit only validated commands through Production Execution.
- Product Definition `process_config` accepts only process family, tolerances,
  output roles, and material hold rules. The proposed reactor capacity, glue
  type/revision, previous batch, cleaning sequence, and Quality token are
  listed above but not stored; the test shows Product Definition refusing
  reactor capacity as `process_config`. Helper is only in execution evidence. Factory has
  no typed public query for these fields. Confirm which must be durable per
  run and searchable before widening a generic contract (lines 166–169,
  223–225).
- Identified rolls now carry typed width with unit and measured or nominal
  provenance. `Inventory.get_identity/3` reads it, while
  `Inventory.get_identity_positions/3` derives current location and balance
  from stock entries. `ProductionExecution.get_run_yield/3` reads the slitting
  run's 125 kg input, 90 kg product, 30 kg derived trim, 3 kg waste and 2 kg
  variance; `get_unit_yield/3` associates the coated input roll with that
  balance. Physical measurement and KPI policy still need plant confirmation
  (lines 170–173, 229–232).
- The pending Quality token is an opaque reference, not a QAC result. A real
  Quality link and access policy await the shared Quality owner's public API
  and placement decision (lines 57–60, 184–189, 271–278).

This scenario proves one representative contract path. It does not validate AX
schema, plant measurements, confidential recipe policy, dashboards, or
month-end planning and value workflows.
