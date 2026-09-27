# Factory Product Definition

Product Definition links a company's Inventory item to a product definition and
publishes immutable, numbered Formula/BOM and routing revisions. A formula has
input and output lines with item, unit, quantity, optional output role and
material hold rule. A routing has ordered logical operations, their inputs and
outputs, and allowed resources. `process_config` keeps process family,
tolerances, output roles and material hold rules as revisioned data.

## Resource types and resources

A resource is a physical thing an operation may run on. What kinds of
resource a company has, and what each kind records about its resources, is
that company's configuration: `create_resource_type/3` defines a type by
`code`, `name`, and `property_definitions`, a list validated by
`Bilimbi.Factory.Inventory.PropertyDefinition` (key, label, value type,
optional unit, required). `create_resource/3` names the type and holds
`properties` validated against its definitions; values the type does not
define, a missing required value, a value of the wrong type, or another
company's type are refused. `get_resource_type/3`, `list_resource_types/2`,
and `get_resource/3` read them back. A type is immutable in this slice.

Nothing in code names a kind of resource. The migration that introduced types
turned each `kind` a company's resources had used into one of that company's
types, so earlier rows kept their meaning as data.

The public facade is `Bilimbi.Factory.ProductDefinition`. Every call takes a
Tenancy scope and company ID, and item and unit references are validated through
Inventory's public API. `select_revisions/5` returns the exact product, formula
and routing revisions a future order will retain, refusing a routing whose
operation inputs are not Formula/BOM inputs, whose outputs are not Formula/BOM
outputs, or that never outputs the product's item. Definitions do not create
orders or post material movements.

The tables are Bilimbi-only; they have no Belimbing adoption baseline. Use
`mix bilimbi.migrate` from the mounted Bilimbi root.
