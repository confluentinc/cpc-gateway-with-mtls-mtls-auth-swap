#!/usr/bin/env bash
# Core cluster: KRaft controllers, Kafka brokers (mTLS, RBAC, MDS on LDAP), internal NLBs, demo topics and role
# bindings. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
load_passwords

step "MDS token key pair and LDAP bind credentials"
if [[ ! -f "$SECRETS_DIR/mds-token-keypair.pem" ]]; then
  openssl genrsa -out "$SECRETS_DIR/mds-token-keypair.pem" 2048 2>/dev/null
  openssl rsa -in "$SECRETS_DIR/mds-token-keypair.pem" -outform PEM -pubout \
    -out "$SECRETS_DIR/mds-token-public.pem" 2>/dev/null
  chmod 600 "$SECRETS_DIR"/mds-token-*.pem
fi
kcore -n confluent create secret generic mds-token \
  --from-file=mdsTokenKeyPair.pem="$SECRETS_DIR/mds-token-keypair.pem" \
  --from-file=mdsPublicKey.pem="$SECRETS_DIR/mds-token-public.pem" \
  --dry-run=client -o yaml | kcore apply -f -
kcore -n confluent create secret generic mds-ldap-bind \
  --from-literal=ldap.txt="$(printf 'username=cn=mds,dc=wf,dc=demo\npassword=%s' "$LDAP_READONLY_USER_PASSWORD")" \
  --dry-run=client -o yaml | kcore apply -f -

step "Rack awareness service account"
kcore apply -f "$HERE/rack-awareness.yaml"

step "KRaft + Kafka"
apply_core "$HERE/kafka.yaml"
kcore -n confluent wait kraftcontroller/kraftcontroller --for=jsonpath='{.status.phase}'=RUNNING --timeout=900s
kcore -n confluent wait kafka/kafka --for=jsonpath='{.status.phase}'=RUNNING --timeout=1200s

step "Demo topics and role bindings"
apply_core "$HERE/topics-rbac.yaml"
for t in demo-orders demo-fenced; do
  kcore -n confluent wait "kafkatopic/$t" --for=jsonpath='{.status.state}'=CREATED --timeout=300s
done
wait_rolebindings alice-demo-topics-write alice-demo-topics-read
