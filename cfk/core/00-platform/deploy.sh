#!/usr/bin/env bash
# Core cluster: CFK operator, private CA and certificates, OpenLDAP. Generates the demo passwords once into
# .secrets/passwords.env. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
PASSWORDS="$SECRETS_DIR/passwords.env"
USERS=(LDAP_ADMIN LDAP_CONFIG LDAP_READONLY_USER KAFKA SR C3 CPCGW_SR SR_EXPORTER TESTADMIN ALICE BOB)

step "Passwords in $PASSWORDS (missing ones are generated)"
mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
touch "$PASSWORDS" && chmod 600 "$PASSWORDS"
for u in "${USERS[@]}"; do
  grep -q "^${u}_PASSWORD=" "$PASSWORDS" ||
    echo "${u}_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)" >> "$PASSWORDS"
done
load_passwords

step "Namespace"
kcore apply -f "$HERE/namespace.yaml"

step "CFK operator (chart $CFK_CHART_VERSION)"
helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo update confluentinc >/dev/null
hcore upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --version "$CFK_CHART_VERSION" --namespace confluent -f "$HERE/operator-values.yaml" --wait

step "Private CA and certificates"
kcore apply -f "$HERE/ca-issuer.yaml"
kcore -n cert-manager wait certificate/wf-demo-root-ca --for=condition=Ready --timeout=120s
kcore wait clusterissuer/wf-demo-ca --for=condition=Ready --timeout=120s
apply_core "$HERE/certificates.yaml"
kcore -n confluent wait certificate --all --for=condition=Ready --timeout=180s

step "OpenLDAP"
kcore -n confluent create secret generic ldap-env \
  --from-literal=LDAP_ADMIN_PASSWORD="$LDAP_ADMIN_PASSWORD" \
  --from-literal=LDAP_CONFIG_PASSWORD="$LDAP_CONFIG_PASSWORD" \
  --from-literal=LDAP_READONLY_USER_PASSWORD="$LDAP_READONLY_USER_PASSWORD" \
  --dry-run=client -o yaml | kcore apply -f -
kcore -n confluent create secret generic ldap-ldifs \
  --from-literal=50-bootstrap.ldif="$(envsubst "$(printf '${%s_PASSWORD} ' "${USERS[@]}")" < "$HERE/ldap-bootstrap.ldif.tmpl")" \
  --dry-run=client -o yaml | kcore apply -f -
kcore apply -f "$HERE/ldap.yaml"
kcore -n confluent rollout status statefulset/ldap --timeout=300s
