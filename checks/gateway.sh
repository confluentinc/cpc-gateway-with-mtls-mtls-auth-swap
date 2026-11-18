#!/usr/bin/env bash
# External path, run from this machine over the internet with the Java demo client: public DNS and exposed ports, the
# Gateway certificate, mTLS at the Gateway (trusted, missing and untrusted client certificates), Gateway names only in
# metadata, produce/consume, schema validation and CEL rules on demo-payments, route fencing, and field encryption
# (ciphertext on the brokers, plaintext through the Gateway).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_passwords
BOOTSTRAP="$GATEWAY_DOMAIN:9092"
CONF="$SECRETS_DIR/clients/alice-gateway.properties"
JAR="$ROOT/clients/java-gateway-demo/target/gateway-demo.jar"
[[ -s "$CONF" && -s "$JAR" ]] || die "run ./setup.sh clients first"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }
note() { printf '  NOTE  %s\n' "$*"; }
port_open() { if nc -h 2>&1 | grep -q -- '-G'; then nc -z -G 5 "$1" "$2"; else nc -z -w 5 "$1" "$2"; fi; }
producer() { java -cp "$JAR" com.wf.demo.Producer --interval-ms 0 --count 1 --max.block.ms 20000 "$@" 2>&1 || true; }
consumer() { java -cp "$JAR" com.wf.demo.Consumer --idle-timeout-sec 15 --from beginning "$@" 2>&1 || true; }

step "Public DNS and exposed ports"
for h in "$GATEWAY_DOMAIN" "b0.$GATEWAY_DOMAIN" "b1.$GATEWAY_DOMAIN" "b2.$GATEWAY_DOMAIN" "$SR_PUBLIC_HOST"; do
  [[ -n $(dig +short @1.1.1.1 "$h") ]] && pass "$h resolves publicly" || fail "$h does not resolve"
done
for h in "kafka.$PRIVATE_ZONE" "b0.$PRIVATE_ZONE" "sr.$PRIVATE_ZONE" "mds.$PRIVATE_ZONE"; do
  [[ -z $(dig +short @1.1.1.1 "$h") ]] && pass "$h does not resolve publicly" || fail "$h resolves publicly"
done
port_open "$GATEWAY_DOMAIN" 9092 && pass "9092 (Kafka route) reachable" || fail "9092 not reachable"
for p in 9190 9180; do
  ! port_open "$GATEWAY_DOMAIN" "$p" && pass "$p (Gateway admin/http) blocked" || fail "$p reachable from the internet"
done

step "Gateway certificate (SNI per broker name)"
kcore -n confluent get secret cpcgw-dmz-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/ca.crt"
for h in "$GATEWAY_DOMAIN" "b1.$GATEWAY_DOMAIN"; do
  out=$(echo | openssl s_client -connect "$GATEWAY_DOMAIN:9092" -servername "$h" -CAfile "$WORK/ca.crt" 2>/dev/null || true)
  subject=$(echo "$out" | openssl x509 -noout -subject 2>/dev/null || true)
  [[ "$subject" == *"cpc-gateway-server"* && "$out" == *"Verify return code: 0"* ]] \
    && pass "SNI $h -> Gateway certificate, verified by the demo CA" || fail "unexpected certificate for $h: $subject"
done

step "mTLS at the Gateway"
grep -v '^ssl.key' "$CONF" | grep -v '^ssl.keystore' > "$WORK/none.properties"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/O=WF Demo/CN=mallory" \
  -keyout "$WORK/mallory.key" -out "$WORK/mallory.crt" 2>/dev/null
openssl pkcs12 -export -in "$WORK/mallory.crt" -inkey "$WORK/mallory.key" -name mallory -out "$WORK/mallory.p12" \
  -passout pass:changeit
{ cat "$WORK/none.properties"
  printf 'ssl.keystore.type=PKCS12\nssl.keystore.location=%s\nssl.keystore.password=changeit\n' "$WORK/mallory.p12"; } \
  > "$WORK/mallory.properties"
out=$(producer --topic demo-orders --config "$CONF")
[[ "$out" == *"sent  key="* ]] && pass "alice (demo CA certificate) accepted and produced to demo-orders" \
  || fail "alice rejected: $(echo "$out" | tail -3)"
advertised=$(echo "$out" | sed -n '/Brokers advertised/,/Partition leaders/p' | grep -c "\.$GATEWAY_DOMAIN:9092" || true)
[[ "$advertised" == 3 ]] && pass "metadata advertises only b0/b1/b2.$GATEWAY_DOMAIN" || fail "metadata: $out"
[[ "$out" != *"$PRIVATE_ZONE"* && "$out" != *svc.cluster.local* ]] && pass "no internal names in metadata" \
  || fail "internal names leaked to the client"
for who in none mallory; do
  out=$(producer --topic demo-orders --config "$WORK/$who.properties")
  [[ "$out" != *"sent  key="* && "$out" == *SSL* ]] \
    && pass "$who: refused during the TLS handshake ($(echo "$out" | grep -m1 -oE 'SSL[A-Za-z]*Exception[^.]*' | cut -c1-90))" \
    || fail "$who was not refused: $(echo "$out" | tail -3)"
done

step "Produce and consume through the Gateway"
key=$(producer --topic demo-orders --config "$CONF" | sed -n 's/^sent  key=\([^ ]*\).*/\1/p')
consumer --topic demo-orders --group "demo-check-$RANDOM" --config "$CONF" | grep -q "key=$key " \
  && pass "alice consumed her demo-orders record ($key)" || fail "demo-orders consume failed"

step "Data contracts on demo-payments (schemas from https://$SR_PUBLIC_HOST)"
out=$(producer --topic demo-payments --avro false --config "$CONF")
[[ "$out" == *REJECTED* ]] && pass "plain-text record refused by schema validation" || fail "plain text accepted: $out"
out=$(producer --topic demo-payments --config "$CONF")
[[ "$out" == *"sent  key="* ]] && pass "valid Payment accepted" || fail "valid Payment refused: $(echo "$out" | tail -3)"
key=$(echo "$out" | sed -n 's/^sent  key=\([^ ]*\).*/\1/p')
for bad in amount currency card; do
  out=$(producer --topic demo-payments --invalid "$bad" --config "$CONF")
  [[ "$out" == *REJECTED* ]] && pass "CEL rule refuses an invalid $bad" || fail "invalid $bad accepted"
done
out=$(consumer --topic demo-payments --group "demo-check-$RANDOM" --config "$CONF" | grep "key=$key " || true)
[[ "$out" == *'"card_number": "4'* ]] && pass "consumed through the Gateway with card_number decrypted" \
  || fail "Payment not consumed or not decrypted: $out"
out=$(kcore -n clients exec internal-client -- consumer --topic demo-payments --group "demo-check-$RANDOM" \
  --from beginning --idle-timeout-sec 15 --rule.executors._default_.disabled true 2>&1 | grep "key=$key " || true)
[[ -n "$out" && "$out" != *'"card_number": "4'* ]] && pass "on the brokers card_number is ciphertext (internal client, no KMS)" \
  || fail "card_number not encrypted on the brokers: $out"

step "Route fencing"
out=$(producer --topic demo-fenced --config "$CONF" --delivery.timeout.ms 15000 --request.timeout.ms 10000 --max.block.ms 20000)
[[ "$out" == *REJECTED* || "$out" != *"sent  key="* ]] && pass "produce to demo-fenced refused by the Gateway" \
  || fail "demo-fenced accepted a record"

step "Schema Registry users"
out=$(java -cp "$JAR" com.wf.demo.Producer --interval-ms 0 --count 1 --topic demo-payments \
  --config "$SECRETS_DIR/clients/bob-gateway.properties" 2>&1 || true)
[[ "$out" == *AuthorizationException* || "$out" == *403* ]] \
  && pass "bob (no SR role bindings) cannot look up the schema (403)" || note "bob: $(echo "$out" | tail -2)"
