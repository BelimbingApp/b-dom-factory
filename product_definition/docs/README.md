# Factory Product Definition

Product Definition links a company's Inventory item to a product definition and
publishes immutable, numbered Formula/BOM and routing revisions. A formula has
input and output lines with item, unit, quantity, optional output role and
material hold rule. A routing has ordered logical operations, their inputs and
outputs, and allowed Work Centres/Resources. `process_config` keeps process
family, tolerances, output roles and material hold rules as revisioned data.

The public facade is `Bilimbi.Factory.ProductDefinition`. Every call takes a
Tenancy scope and company ID, and item and unit references are validated through
Inventory's public API. `select_revisions/5` returns the exact product, formula
and routing revisions a future order will retain. Definitions do not create
orders or post material movements.

The tables are Bilimbi-only; they have no Belimbing adoption baseline. Use
`mix bilimbi.migrate` from the mounted Bilimbi root.
