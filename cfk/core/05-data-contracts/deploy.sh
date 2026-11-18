#!/usr/bin/env bash
# Data contracts on the core Schema Registry: the payments KEK (AWS KMS key from terraform/dmz) in the DEK registry and
# the Payment schema with its rule set (CEL conditions, ENCRYPT on PII fields, enableAt GATEWAY). Uses the REST API
# as testadmin through a port-forward; the Schema CR has no ruleSet field.
#   SUBJECTS="demo-csfle-test-value" ./deploy.sh                 # only the scratch subject
#   SUBJECTS="demo-csfle-test-value" ENABLE_AT=ALL ./deploy.sh   # clients run the rules too
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
load_passwords
load_tf_outputs
SUBJECTS="${SUBJECTS:-demo-csfle-test-value demo-payments-value}"
sr_admin_open schemaregistry 18092

KEK="$(jq -r .name "$HERE/kek.json")"
step "KEK $KEK"
if sr_admin schemaregistry "/dek-registry/v1/keks/$KEK" >/dev/null 2>&1; then
  echo "exists: $(sr_admin schemaregistry "/dek-registry/v1/keks/$KEK" | jq -c '{name, kmsType, kmsKeyId}')"
else
  render "$HERE/kek.json" | sr_admin schemaregistry /dek-registry/v1/keks -X POST -d @-; echo
fi

body="$(jq -n --rawfile schema "$HERE/schemas/payment.avsc" --argjson ruleSet "$(render "$HERE/schemas/payment-rules.json")" \
  --arg enableAt "${ENABLE_AT:-}" \
  '{schemaType: "AVRO", schema: $schema, ruleSet: ($ruleSet + (if $enableAt == "" then {} else {enableAt: $enableAt} end))}')"
for subject in $SUBJECTS; do
  step "$subject"
  sr_admin schemaregistry "/subjects/$subject/versions" -X POST -d "$body"; echo
  sr_admin schemaregistry "/subjects/$subject/versions/latest" |
    jq -c '{subject, version, id, rules: [.ruleSet.domainRules[].name], enableAt: .ruleSet.enableAt}'
done
