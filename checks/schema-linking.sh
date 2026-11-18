#!/usr/bin/env bash
# Schema linking: the exporter is running, the read-only cluster has the same subjects and IDs as the core registry,
# the DMZ followers are healthy behind the ALB, and the public endpoint is read-only (users read their subjects,
# writes are refused, no DEK registry, no exporter API).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_passwords
load_tf_outputs
PUBLIC="https://$SR_PUBLIC_HOST"
SUBJECT=demo-payments-value

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }
public() {  # <user|-> <method> <path> [body]: prints the HTTP status
  local args=()
  case "$1" in -) ;; *) local v; v="$(echo "$1" | tr '[:lower:]' '[:upper:]')_PASSWORD"; args+=(-u "$1:${!v}") ;; esac
  [[ -n "${4:-}" ]] && args+=(--data "$4")
  curl -s -o /dev/null -w '%{http_code}' "${args[@]}" -X "$2" -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
    "$PUBLIC$3"
}

step "Exporter and read-only cluster (core)"
sr_admin_open schemaregistry 18092
sr_admin_open schemaregistry-ro 18091
state=$(sr_admin schemaregistry /exporters/dmz-readonly/status | jq -r .state)
[[ "$state" == RUNNING ]] && pass "exporter dmz-readonly: RUNNING" || fail "exporter dmz-readonly: $state"
[[ $(sr_admin schemaregistry-ro /mode | jq -r .mode) == IMPORT ]] && pass "read-only cluster in IMPORT mode" \
  || fail "read-only cluster not in IMPORT mode"
core_subjects=$(sr_admin schemaregistry /subjects | jq -c sort)
ro_subjects=$(sr_admin schemaregistry-ro /subjects | jq -c sort)
[[ "$core_subjects" == "$ro_subjects" ]] && pass "same subjects on both: $ro_subjects" \
  || fail "subjects differ: core $core_subjects, read-only $ro_subjects"
core_id=$(sr_admin schemaregistry "/subjects/$SUBJECT/versions/latest" | jq -r .id)
ro_id=$(sr_admin schemaregistry-ro "/subjects/$SUBJECT/versions/latest" | jq -r .id)
[[ "$core_id" == "$ro_id" ]] && pass "$SUBJECT: same schema ID $ro_id" || fail "$SUBJECT IDs differ: $core_id vs $ro_id"

step "DMZ followers behind the public ALB"
ready=$(kdmz -n gateway get pods -l app=schemaregistry-dmz \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true || true)
[[ "$ready" == 2 ]] && pass "schemaregistry-dmz: 2/2 ready" || fail "schemaregistry-dmz: $ready/2 ready"
healthy=$(aws elbv2 describe-target-health --target-group-arn "$SR_TARGET_GROUP_ARN" \
  --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
[[ "$healthy" == 2 ]] && pass "ALB target group: 2 healthy pod targets" || fail "ALB target group: $healthy healthy"
step "Public endpoint $PUBLIC"
[[ $(public - GET /subjects) == 401 ]] && pass "no credentials -> 401" || fail "no credentials not refused"
[[ $(public alice GET "/subjects/$SUBJECT/versions/latest") == 200 ]] && pass "alice reads $SUBJECT" || fail "alice cannot read"
id=$(curl -s -u "alice:$ALICE_PASSWORD" "$PUBLIC/subjects/$SUBJECT/versions/latest" | jq -r .id)
[[ "$id" == "$core_id" ]] && pass "public schema ID $id matches the core" || fail "public ID $id, core $core_id"
rules=$(curl -s -u "alice:$ALICE_PASSWORD" "$PUBLIC/subjects/$SUBJECT/versions/latest" | jq -c '[.ruleSet.domainRules[].name]')
[[ "$rules" != "[]" && "$rules" != null ]] && pass "rule set linked too: $rules" || fail "no rule set on the public schema"
[[ $(public bob GET "/subjects/$SUBJECT/versions/latest") == 403 ]] && pass "bob (no role bindings) -> 403" || fail "bob not refused"
schema='{"schemaType":"AVRO","schema":"{\"type\":\"record\",\"name\":\"X\",\"fields\":[{\"name\":\"a\",\"type\":\"string\"}]}"}'
code=$(public alice POST /subjects/demo-public-write-value/versions "$schema")
[[ "$code" == 403 ]] && pass "alice register -> 403 (read role only)" || fail "alice register returned $code"
code=$(public testadmin POST /subjects/demo-public-write-value/versions "$schema")
[[ "$code" != 200 ]] && pass "admin register -> $code (read-only cluster in IMPORT mode)" || fail "admin could register"
code=$(public testadmin GET /dek-registry/v1/keks)
[[ "$code" == 404 ]] && pass "no DEK registry on the public endpoint (404)" || fail "DEK registry answered $code"
code=$(public testadmin GET /exporters)
[[ "$code" == 404 ]] && pass "no exporter API on the public endpoint (404)" || fail "exporter API answered $code"
