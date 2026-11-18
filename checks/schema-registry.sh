#!/usr/bin/env bash
# Core Schema Registry: placement, the private endpoint (internal NLB + private DNS + certificate), LDAP basic auth
# (accepted / rejected), RBAC on subjects for alice, bob and the Gateway's SR client, and an Avro produce/consume.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
kubectl() { command kubectl --context "$CORE_CTX" "$@"; }

NS=confluent
SR_PRIVATE=https://sr.${PRIVATE_ZONE}
SR_SVC=https://schemaregistry.confluent.svc.cluster.local:8081
BOOTSTRAP=kafka.confluent.svc.cluster.local:9071
TOPIC=demo-sr-check   # not demo-payments: its subject carries the data contract from the data-contracts step
SUBJECT="$TOPIC-value"
WORK="$(mktemp -d)"
load_passwords

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }
# curl as <user> (or "-" for no credentials) against <url>; prints the HTTP status code.
sr() {
  local who=$1 method=$2 url=$3 args=()
  [[ "$who" != - ]] && args+=(-u "$who:$(cat "$WORK/$who.pw")")
  [[ -n "${4:-}" ]] && args+=(--data "$4")
  k exec sr-client -c curl -- curl -s -o /dev/null -w '%{http_code}' --cacert /certs/ca.crt "${args[@]}" \
    -X "$method" -H 'Content-Type: application/vnd.schemaregistry.v1+json' "$url"
}
avro() { k exec sr-client -c avro -- bash -c "$1"; }

echo "== Pods and placement"
ready=$(k get pods -l app=schemaregistry -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true)
[[ "$ready" == 2 ]] && pass "schemaregistry: 2/2 ready" || fail "schemaregistry: $ready/2 ready"
zones=$(k get pods -l app=schemaregistry -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | xargs -I{} kubectl --context "$CORE_CTX" get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' | sort -u)
[[ $(echo "$zones" | grep -c .) == 2 ]] && pass "replicas in 2 AZs: $(echo $zones)" || fail "replicas in: $(echo $zones)"

echo "== Test client pod"
k get secret tls-kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/ca.crt"
k get secret client-alice-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/alice.crt"
k get secret client-alice-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$WORK/alice.key"
openssl pkcs12 -export -in "$WORK/alice.crt" -inkey "$WORK/alice.key" -name alice -out "$WORK/alice.p12" -passout pass:changeit
rm "$WORK/alice.key"
cat > "$WORK/alice.properties" <<EOF
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/alice.p12
ssl.keystore.password=changeit
EOF
printf '%s' "$ALICE_PASSWORD" > "$WORK/alice.pw"
printf '%s' "$BOB_PASSWORD" > "$WORK/bob.pw"
printf '%s' "$CPCGW_SR_PASSWORD" > "$WORK/cpcgw-dmz-sr-client.pw"
printf '%s' "wrong-password" > "$WORK/wrong.pw"
cat > "$WORK/payment.avsc" <<'EOF'
{"type":"record","name":"Payment","namespace":"wf.demo","fields":[{"name":"id","type":"string"},{"name":"amount","type":"double"}]}
EOF
k create secret generic sr-test-clients --from-file="$WORK" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: sr-client
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.11.1
      command: [sleep, infinity]
      volumeMounts: [{ name: certs, mountPath: /certs }]
    - name: avro
      image: confluentinc/cp-schema-registry:8.4.1
      command: [sleep, infinity]
      volumeMounts: [{ name: certs, mountPath: /certs }]
  volumes:
    - name: certs
      secret: { secretName: sr-test-clients }
EOF
k wait pod/sr-client --for=condition=Ready --timeout=300s >/dev/null && pass "sr-client pod ready"

echo "== Private endpoint (internal NLB + private DNS + certificate)"
k exec sr-client -c curl -- nslookup sr.${PRIVATE_ZONE} >/dev/null 2>&1 \
  && pass "sr.${PRIVATE_ZONE} resolves in-VPC" || fail "sr.${PRIVATE_ZONE} does not resolve"
dig +short @1.1.1.1 sr.${PRIVATE_ZONE} | grep -q . && fail "sr.${PRIVATE_ZONE} resolves publicly"
pass "sr.${PRIVATE_ZONE} does not resolve on the public internet"
host=$(k get svc schemaregistry-bootstrap-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
read -r arn scheme azs < <(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='${host}'] | [0].[LoadBalancerArn,Scheme,length(AvailabilityZones)]" --output text)
xz=$(aws elbv2 describe-load-balancer-attributes --region "$AWS_REGION" \
  --load-balancer-arn "$arn" --query "Attributes[?Key=='load_balancing.cross_zone.enabled'].Value" --output text)
healthy=0
for _ in $(seq 1 18); do
  tg=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --load-balancer-arn "$arn" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  healthy=$(aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn "$tg" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
  [[ "$healthy" == 2 ]] && break
  sleep 10
done
[[ "$scheme" == internal && "$azs" == 3 && "$xz" == true && "$healthy" == 2 ]] \
  && pass "SR NLB: internal, 3 AZs, cross-zone on, 2 healthy targets" \
  || fail "SR NLB: scheme=$scheme azs=$azs cross-zone=$xz healthy=$healthy"
code=$(sr - GET "$SR_PRIVATE/subjects")
[[ "$code" == 401 ]] && pass "TLS to $SR_PRIVATE verifies against the private CA (hostname matches); no credentials -> 401" \
  || fail "no-credentials request returned $code"

echo "== LDAP basic auth"
[[ $(sr wrong GET "$SR_PRIVATE/subjects") == 401 ]] && pass "wrong password -> 401" || fail "wrong password not rejected"
[[ $(sr alice GET "$SR_PRIVATE/subjects") == 200 ]] && pass "alice (LDAP credentials) -> 200" || fail "alice not authenticated"

echo "== RBAC on subjects"
schema='{"schemaType":"AVRO","schema":"{\"type\":\"record\",\"name\":\"Payment\",\"namespace\":\"wf.demo\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"},{\"name\":\"amount\",\"type\":\"double\"}]}"}'
code=$(sr alice POST "$SR_PRIVATE/subjects/$SUBJECT/versions" "$schema")
[[ "$code" == 200 ]] && pass "alice registered $SUBJECT" || fail "alice register returned $code"
[[ $(sr alice GET "$SR_PRIVATE/subjects/$SUBJECT/versions/latest") == 200 ]] && pass "alice reads $SUBJECT" || fail "alice read failed"
[[ $(sr alice POST "$SR_PRIVATE/subjects/other-value/versions" "$schema") == 403 ]] \
  && pass "alice refused outside demo-* (other-value -> 403)" || fail "alice registered outside her prefix"
[[ $(sr bob GET "$SR_PRIVATE/subjects/$SUBJECT/versions/latest") == 403 ]] && pass "bob (no role binding) read -> 403" || fail "bob could read"
[[ $(sr bob POST "$SR_PRIVATE/subjects/$SUBJECT/versions" "$schema") == 403 ]] && pass "bob register -> 403" || fail "bob could register"
[[ $(sr cpcgw-dmz-sr-client GET "$SR_PRIVATE/subjects/$SUBJECT/versions/latest") == 200 ]] \
  && pass "cpcgw-dmz-sr-client reads $SUBJECT" || fail "cpcgw-dmz-sr-client cannot read"
[[ $(sr cpcgw-dmz-sr-client POST "$SR_PRIVATE/subjects/$SUBJECT/versions" "$schema") == 403 ]] \
  && pass "cpcgw-dmz-sr-client register -> 403 (read-only)" || fail "cpcgw-dmz-sr-client could register"
[[ $(sr alice GET "$SR_SVC/subjects") == 200 ]] && pass "in-cluster service endpoint also works ($SR_SVC)" || fail "in-cluster endpoint failed"

echo "== Avro produce and consume (Kafka mTLS as alice, SR basic auth as alice)"
stamp=$(date +%s)
srprops="--property schema.registry.url=$SR_PRIVATE --property basic.auth.credentials.source=USER_INFO \
  --property basic.auth.user.info=alice:\$(cat /certs/alice.pw) \
  --property schema.registry.ssl.truststore.type=PEM --property schema.registry.ssl.truststore.location=/certs/ca.crt"
out=$(avro "echo '{\"id\":\"pay-$stamp\",\"amount\":42.5}' | kafka-avro-console-producer --bootstrap-server $BOOTSTRAP \
  --topic $TOPIC --producer.config /certs/alice.properties --property auto.register.schemas=false \
  --property value.schema.file=/certs/payment.avsc $srprops 2>&1" || true)
[[ "$out" != *ERROR* && "$out" != *xception* ]] && pass "alice produced an Avro record to $TOPIC" || fail "Avro produce failed: $out"
out=$(avro "kafka-avro-console-consumer --bootstrap-server $BOOTSTRAP --topic $TOPIC --group demo-sr-check-$stamp \
  --consumer.config /certs/alice.properties --from-beginning --timeout-ms 30000 $srprops 2>/dev/null" || true)
[[ "$out" == *"pay-$stamp"* ]] && pass "alice consumed and deserialized it: $(echo "$out" | grep "pay-$stamp")" \
  || fail "Avro consume failed: $out"

echo "== Cleanup"
k delete pod sr-client --wait=false >/dev/null
k delete secret sr-test-clients >/dev/null
rm -rf "$WORK"
pass "test client removed"
