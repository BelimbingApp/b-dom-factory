# Inventory agent notes

- For weighed receipts, use optional typed `receipt_measurement` and its
  `ReceiptMeasurement` read model; free-text evidence cannot validate net stock
  or expose supplier variance consistently. See `lib/inventory/receipt_measurement.ex`
  and `docs/README.md`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
