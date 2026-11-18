#!/usr/bin/env bash
# Core cluster: Control Center next-gen (with Prometheus and Alertmanager, mTLS) and testadmin's role bindings.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
load_passwords

step "C3's LDAP credentials for Schema Registry"
kcore -n confluent create secret generic c3-sr-basic \
  --from-literal=basic.txt="$(printf 'username=c3\npassword=%s' "$C3_PASSWORD")" \
  --dry-run=client -o yaml | kcore apply -f -

step "Control Center"
apply_core "$HERE/control-center.yaml"
kcore -n confluent wait controlcenter/controlcenter --for=jsonpath='{.status.phase}'=RUNNING --timeout=900s

step "Role bindings"
apply_core "$HERE/rbac.yaml"
wait_rolebindings testadmin-kafka-clusteradmin testadmin-sr-systemadmin c3-demo-subjects-read
