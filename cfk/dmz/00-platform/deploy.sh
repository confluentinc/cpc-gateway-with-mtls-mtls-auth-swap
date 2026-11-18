#!/usr/bin/env bash
# DMZ cluster: gateway namespace, CFK operator, and the Gateway's certificates and SR credentials. The certificates
# are issued by the private CA in the core cluster and copied here; no CA key lives in the DMZ. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
load_passwords
copy_pem() {  # <secret>: core confluent/<secret> -> DMZ gateway/<secret>
  kdmz -n gateway create secret generic "$1" \
    --from-literal=tls.crt="$(kcore -n confluent get secret "$1" -o jsonpath='{.data.tls\.crt}' | base64 -d)" \
    --from-literal=tls.key="$(kcore -n confluent get secret "$1" -o jsonpath='{.data.tls\.key}' | base64 -d)" \
    --from-literal=ca.crt="$(kcore -n confluent get secret "$1" -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
    --dry-run=client -o yaml | kdmz apply -f -
}

step "Namespace and CFK operator (chart $CFK_CHART_VERSION)"
kdmz apply -f "$HERE/namespace.yaml"
helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo update confluentinc >/dev/null
hdmz upgrade --install confluent-operator confluentinc/confluent-for-kubernetes --version "$CFK_CHART_VERSION" \
  -n gateway -f "$HERE/operator-values.yaml" --wait

step "Gateway certificates (copied from the core cluster)"
kcore -n confluent wait certificate/cpcgw-dmz-server certificate/cpcgw-dmz-client --for=condition=Ready --timeout=120s
copy_pem cpcgw-dmz-server-tls
copy_pem cpcgw-dmz-client-tls
kdmz -n gateway create secret generic cpcgw-dmz-ca \
  --from-literal=ca.crt="$(kcore -n confluent get secret cpcgw-dmz-client-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
  --dry-run=client -o yaml | kdmz apply -f -

step "Gateway's LDAP credentials for Schema Registry (governance)"
kdmz -n gateway create secret generic cpcgw-dmz-sr-credentials \
  --from-literal=basic.txt="$(printf 'username=cpcgw-dmz-sr-client\npassword=%s' "$CPCGW_SR_PASSWORD")" \
  --dry-run=client -o yaml | kdmz apply -f -
