# Inventory agent notes

- For weighed receipts, use optional typed `receipt_measurement` and its
  `ReceiptMeasurement` read model; free-text evidence cannot validate net stock
  or expose supplier variance consistently. See `lib/inventory/receipt_measurement.ex`
  and `docs/README.md`.
- For a transform whose lines mix native units, post the observed quantities
  in their own units with `variance.units` evidence per differing unit, and
  read agreement across units with `get_transaction_balance/3`; never convert
  a line to another unit before posting or add a conversion the item does not
  define. `lib/inventory/ledger.ex` balances per unit and `docs/README.md`
  defines the shapes.
- Put unit dimensions on a new receipt or production output's `identity`, as
  validated by `lib/inventory/ledger/request.ex`; use `get_identity/3` and
  `get_identity_positions/3` for dimensions and current stock. Do not parse
  line evidence for dimensions or persist a separate current-location field:
  `lib/inventory/ledger.ex` derives locations from stock entries.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
