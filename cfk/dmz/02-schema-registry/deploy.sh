#!/usr/bin/env bash
# DMZ cluster: read-only Schema Registry followers behind the public ALB (https://sr.<PUBLIC_ZONE>). Needs the core
# step schema-linking (certificate, MDS NLB, role bindings, leader). Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
load_tf_outputs

step "Certificate (issued in the core as CN=sr-dmz), MDS public key, license"
kcore -n confluent wait certificate/schemaregistry-dmz --for=condition=Ready --timeout=120s
s=tls-schemaregistry-dmz
kdmz -n gateway create secret generic "$s" \
  --from-literal=tls.crt="$(kcore -n confluent get secret "$s" -o jsonpath='{.data.tls\.crt}' | base64 -d)" \
  --from-literal=tls.key="$(kcore -n confluent get secret "$s" -o jsonpath='{.data.tls\.key}' | base64 -d)" \
  --from-literal=ca.crt="$(kcore -n confluent get secret "$s" -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
  --dry-run=client -o yaml | kdmz apply -f -
kdmz -n gateway create secret generic mds-token-public \
  --from-file=mdsPublicKey.pem="$SECRETS_DIR/mds-token-public.pem" \
  --dry-run=client -o yaml | kdmz apply -f -
kdmz -n gateway create secret generic confluent-license \
  --from-literal=license.txt="license=$(tr -d '\n' < "$LICENSE_FILE")" \
  --dry-run=client -o yaml | kdmz apply -f -

step "Schema Registry followers and the ALB target group binding"
apply_dmz "$HERE/schema-registry.yaml"
kdmz -n gateway wait schemaregistry/schemaregistry-dmz --for=jsonpath='{.status.phase}'=RUNNING --timeout=900s

step "ALB target health"
for _ in $(seq 40); do
  health="$(aws elbv2 describe-target-health --target-group-arn "$SR_TARGET_GROUP_ARN" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
  echo "  $health"
  [[ -n "$health" && "$health" != *initial* && "$health" != *unhealthy* ]] && break
  sleep 10
done
echo "Public Schema Registry: https://$SR_PUBLIC_HOST (LDAP users, read only)"
