#!/usr/bin/env bash
# Deploys the internal client pod in the core cluster and copies the Java demo jar into it. Uses the JKS stores from
# clients/export-client-config.sh and the jar from clients/java-gateway-demo (both done by clients/deploy.sh).
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENTS_DIR="$SECRETS_DIR/clients"
JAR="$ROOT/clients/java-gateway-demo/target/gateway-demo.jar"
USERS=(alice bob)
load_passwords
[[ -s "$JAR" && -s "$CLIENTS_DIR/truststore.jks" ]] || die "run clients/deploy.sh (builds the jar and exports the stores)"
PW="$(tr -d '\n' < "$CLIENTS_DIR/store.password")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
files=(--from-file="$CLIENTS_DIR/truststore.jks")
for who in "${USERS[@]}"; do
  pw_var="$(echo "$who" | tr '[:lower:]' '[:upper:]')_PASSWORD"
  cat > "$TMP/$who-internal.properties" <<EOF
# $who directly on the core brokers through the internal NLB (mTLS). Brokers authorize as User:$who.
bootstrap.servers=kafka.${PRIVATE_ZONE}:9092
security.protocol=SSL
ssl.truststore.type=JKS
ssl.truststore.location=/etc/kafka-client/truststore.jks
ssl.truststore.password=$PW
ssl.keystore.type=JKS
ssl.keystore.location=/etc/kafka-client/$who.keystore.jks
ssl.keystore.password=$PW
ssl.key.password=$PW

# Internal Schema Registry (WF Demo CA certificate), LDAP basic auth as $who.
schema.registry.url=https://sr.${PRIVATE_ZONE}
schema.registry.ssl.truststore.type=JKS
schema.registry.ssl.truststore.location=/etc/kafka-client/truststore.jks
schema.registry.ssl.truststore.password=$PW
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=$who:${!pw_var}
EOF
  files+=(--from-file="$CLIENTS_DIR/$who.keystore.jks" --from-file="$TMP/$who-internal.properties")
done

step "Secret clients/internal-client"
kcore apply -f - <<<'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"clients"}}'
kcore -n clients create secret generic internal-client "${files[@]}" --dry-run=client -o yaml | kcore apply -f -

step "Pod clients/internal-client"
apply_core "$HERE/client-pod.yaml"
kcore -n clients wait pod/internal-client --for=condition=Ready --timeout=300s

step "Copying $JAR"
kcore -n clients cp "$JAR" internal-client:/app/gateway-demo.jar -c client
