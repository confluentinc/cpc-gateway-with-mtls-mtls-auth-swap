#!/usr/bin/env bash
# Exports the demo client certificates as JKS files for local use, plus ready-to-use client configs for the
# Gateway (mTLS) and the public Schema Registry (LDAP basic auth). Output: .secrets/clients/ (git-ignored).
#   truststore.jks              demo root CA (trusts the Gateway certificate)
#   <user>.keystore.jks         client certificate and key (CN=<user>), alias <user>
#   <user>-gateway.properties   Kafka client config for kafka.gateway.<PUBLIC_ZONE>:9092
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
OUT="$SECRETS_DIR/clients"
USERS=(alice bob)
load_passwords

mkdir -p "$OUT"
chmod 700 "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -s "$OUT/store.password" ]]; then
  openssl rand -base64 18 | tr -d '/+=' > "$OUT/store.password"
fi
PW="$(cat "$OUT/store.password")"

secret() { kcore -n confluent get secret "$1" -o jsonpath="{.data.${2//./\\.}}" | base64 -d; }

secret cpcgw-dmz-server-tls ca.crt > "$OUT/ca.crt"
rm -f "$OUT/truststore.jks"
keytool -importcert -noprompt -alias wf-demo-root-ca -file "$OUT/ca.crt" \
  -keystore "$OUT/truststore.jks" -storetype JKS -storepass "$PW" >/dev/null 2>&1
echo "truststore.jks        demo root CA"

for who in "${USERS[@]}"; do
  secret "client-$who-tls" tls.crt > "$TMP/$who.crt"
  secret "client-$who-tls" tls.key > "$TMP/$who.key"
  openssl pkcs12 -export -in "$TMP/$who.crt" -inkey "$TMP/$who.key" -certfile "$OUT/ca.crt" -name "$who" \
    -out "$TMP/$who.p12" -passout "pass:$PW"
  rm -f "$OUT/$who.keystore.jks"
  keytool -importkeystore -noprompt -srckeystore "$TMP/$who.p12" -srcstoretype PKCS12 -srcstorepass "$PW" \
    -destkeystore "$OUT/$who.keystore.jks" -deststoretype JKS -deststorepass "$PW" -destkeypass "$PW" >/dev/null 2>&1

  pw_var="$(echo "$who" | tr '[:lower:]' '[:upper:]')_PASSWORD"
  cat > "$OUT/$who-gateway.properties" <<EOF
# $who via the CPC Gateway (mTLS). Brokers authorize all Gateway traffic as User:cpcgw-dmz-client (demo-* only).
bootstrap.servers=${GATEWAY_DOMAIN}:9092
security.protocol=SSL
ssl.truststore.type=JKS
ssl.truststore.location=$OUT/truststore.jks
ssl.truststore.password=$PW
ssl.keystore.type=JKS
ssl.keystore.location=$OUT/$who.keystore.jks
ssl.keystore.password=$PW
ssl.key.password=$PW

# Public Schema Registry (Amazon-issued certificate, so the JVM default truststore is enough).
schema.registry.url=https://${SR_PUBLIC_HOST}
basic.auth.credentials.source=USER_INFO
basic.auth.user.info=$who:${!pw_var}
EOF
  subject=$(keytool -list -v -keystore "$OUT/$who.keystore.jks" -storepass "$PW" -alias "$who" 2>/dev/null \
    | sed -n 's/^Owner: //p' | head -1)
  echo "$who.keystore.jks     $subject"
done
chmod 600 "$OUT"/*
echo "Store and key password: $OUT/store.password"
