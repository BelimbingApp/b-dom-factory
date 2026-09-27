#!/usr/bin/env bash
# AGENTS.md: resource types, material types, item statuses, and the default
# item currency are company configuration, never constants in domain code.
# This gate refuses the code shapes that turn one back into a constant: a
# literal vocabulary validated on such a field, or a literal schema default for
# an item's status or currency. Run from this repository's root, with or
# without a Bilimbi checkout around it.
set -euo pipefail

cd "$(dirname "$0")/../.."

fail=0

# A vocabulary of meta-terms that the ledger or execution model itself defines
# (a transaction's kind, an identity's lot or unit kind, an order or batch, an
# observation, a line role) may stay a constant. Those sites are listed here;
# extending the list is a review decision made in the change that adds a site.
meta_term_sites='^inventory/lib/inventory/schemas/identity\.ex:|^production_execution/lib/production_execution/schemas\.ex:'

vocabulary_hits=$(grep -rnE 'validate_inclusion\(:(status|currency_code|kind|resource_type(_id)?|material_type(_id)?)\b' \
  --include='*.ex' -- */lib 2>/dev/null | grep -vE "$meta_term_sites" || true)

if [ -n "$vocabulary_hits" ]; then
  echo "FAIL configurable concepts: a literal vocabulary on a company-configured field:" >&2
  echo "$vocabulary_hits" >&2
  echo "Validate against the company's configuration (its type's property definitions," >&2
  echo "or Inventory.item_settings/2), not a list in code." >&2
  fail=1
fi

default_hits=$(grep -rnE 'field[ (]:(status|currency_code),.*default:' --include='*.ex' -- */lib 2>/dev/null || true)

if [ -n "$default_hits" ]; then
  echo "FAIL configurable concepts: a literal item status or currency default in a schema:" >&2
  echo "$default_hits" >&2
  echo "The default comes from the company's settings (Inventory.item_settings/2)." >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "Configurable concepts are data: no literal vocabulary or default in domain code."
fi

exit "$fail"
