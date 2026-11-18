#!/usr/bin/env bash
# Core Schema Registry (RBAC, LDAP basic auth via MDS, internal NLB sr.<PRIVATE_ZONE>), its role bindings and the
# Avro demo topics. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

step "License secret (from $LICENSE_FILE)"
kcore -n confluent create secret generic confluent-license \
  --from-literal=license.txt="license=$(tr -d '\n' < "$LICENSE_FILE")" \
  --dry-run=client -o yaml | kcore apply -f -

step "Password encoder for schema exporter configs (generated once into .secrets/sr-password-encoder.txt)"
ENCODER="$SECRETS_DIR/sr-password-encoder.txt"
[[ -s "$ENCODER" ]] || (umask 077 && openssl rand -hex 32 > "$ENCODER")
kcore -n confluent create secret generic sr-password-encoder \
  --from-literal=password-encoder.txt="password=$(tr -d '\n' < "$ENCODER")" \
  --dry-run=client -o yaml | kcore apply -f -

# Before SR starts: its extensions create their own topics (DEK registry, exporter).
step "Role bindings"
apply_core "$HERE/rbac.yaml"
wait_rolebindings alice-demo-subjects-write alice-demo-subjects-read sr-dek-registry-topic sr-schema-exporter-topics \
  cpcgw-dmz-sr-client-demo-subjects-read cpcgw-dmz-sr-client-payments-kek

step "Schema Registry"
apply_core "$HERE/schema-registry.yaml"
kcore -n confluent wait schemaregistry/schemaregistry --for=jsonpath='{.status.phase}'=RUNNING --timeout=900s

step "Avro demo topics"
apply_core "$HERE/topics.yaml"
for t in demo-payments demo-csfle-test demo-sr-check; do
  kcore -n confluent wait "kafkatopic/$t" --for=jsonpath='{.status.state}'=CREATED --timeout=300s
done
