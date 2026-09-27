# Representative mix, coat, and slit scenario

`test/mix_coat_slit_scenario_test.exs` seeds `test/support/mix_coat_slit_scenario.ex`
and exercises Factory's public Inventory, Product Definition, and Production
Execution APIs for a generic tape manufacturer, "Company A". All values are
synthetic. No customer Extension, source-system connection, credential, or
private recipe is present. The two glue operations enter as historical
`:import` submissions; coating and slitting use the live contract. Production
Execution posts all four material transformations into Inventory's one ledger.

The illustrative flow is resin and additive receipts → wet glue mixing in a
reactor → dry glue → film coating on a line → a 1200 mm roll slit into 600 mm
and 300 mm rolls, derived trim, and measured waste. Inventory genealogy traces
each slit roll through coating and glue to all three receipts. Product
Definition stores the selected generic formula shape, process family, and
route revisions, and refuses process metadata it has no contract for. No
confidential recipe is included.

## Stand-in values

Every value is a stand-in, including codes, quantities, units, timing,
identities, people, and provenance.

- Company 73; resin, additive, and film as the three stock items; kilogram as
  each item's native unit; receiving location `RCV`; 70 kg resin lot
  `RESIN-LOT-1`, 30 kg additive lot `ADDITIVE-LOT-1`, and 50 kg film lot
  `FILM-LOT-1`; receipt IDs `RCV-*` with synthetic receiving-ticket evidence.
- Glue batch `GLUE-BATCH-1` on reactor `REACTOR-A`, operator user 9 and
  helper user 12. `MIX-WET` consumes 70 kg resin plus 30 kg additive and
  records 98 kg wet glue lot `GLUE-WET-1` with 2 kg variance. `DRY` consumes
  that 98 kg and records 80 kg dry glue lot `GLUE-DRY-1` with 18 kg variance.
  Both losses are illustrative, not inferred wastage reasons.
- Historical import IDs `IMPORT-GLUE-WET-1` and `IMPORT-GLUE-DRY-1` with an
  opaque source extract reference `SNAPSHOT-1`; receipt at 32 days ago, wet
  mixing at 30 days ago, drying at 29 days ago, and 10 minute run durations.
- Coating order `PO-COAT-1`, line `COATER-A`, `COAT` operation, live request
  `COAT-1` two days ago: 50 kg film plus 80 kg dry glue, 125 kg good coated
  output `COATED-ROLL-1` at a nominal 1200 mm, and 5 kg variance. The example
  yield is 125/130 by mass; this is not a validated coating KPI.
- Slitting order `PO-SLIT-1`, resource `SLITTER-A`, live request `SLIT-1` one
  day ago: the 125 kg coated roll feeds 60 kg `SLIT-600-1` at a measured
  600 mm and 30 kg `SLIT-300-1` at a measured 300 mm, 30 kg derived `TRIM-1`
  for the remaining illustrative 300 mm, 3 kg measured `WASTE-1`, and 2 kg
  variance. Good output is 90/125 by mass in this example.
- Operator, helper, machine codes, synthetic scale and run sheets, and a
  `quality:pending` token are sample evidence only. Energy, labour hours,
  coat weight, wastage reason, and certificate fields are absent; the fixture
  makes no measured claim for them.

## Public contract gaps and limits

- Factory records a historical execution with `source: "import"`, stable
  `request_id`, effective time, evidence, selected definitions, and atomic
  Inventory effects. Its evidence and line maps are opaque. It has no typed
  source identity, extraction timestamp, source schema or version, candidate
  status, freshness, or tenant mapping read model. Those belong to the
  connector Extension that imports from a source system; it retains them and
  submits only validated commands through Production Execution.
- Product Definition `process_config` accepts only process family, tolerances,
  output roles, and material hold rules. Reactor capacity, glue type and
  revision, previous batch, cleaning sequence, and a Quality token have no
  Factory contract and are not stored; the test shows Product Definition
  refusing reactor capacity as `process_config`. Helper is only in execution
  evidence. Which of these must be durable per run and searchable is a
  decision to take before widening a generic contract.
- Identified rolls carry typed width with unit and measured or nominal
  provenance. `Inventory.get_identity/3` reads it, while
  `Inventory.get_identity_positions/3` derives current location and balance
  from stock entries. `ProductionExecution.get_run_yield/3` reads the slitting
  run's 125 kg input, 90 kg product, 30 kg derived trim, 3 kg waste and 2 kg
  variance; `get_unit_yield/3` associates the coated input roll with that
  balance. Physical measurement and KPI policy still need plant confirmation.
- The pending Quality token is an opaque reference, not a quality result. A
  real Quality link and access policy await the shared Quality owner's public
  API and placement decision.

This scenario proves one representative contract path. It does not validate a
source system's schema, plant measurements, confidential recipe policy,
dashboards, or month-end planning and value workflows.
