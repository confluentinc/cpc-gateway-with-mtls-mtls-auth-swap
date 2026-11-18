#!/usr/bin/env bash
# Kafka: placement across AZs, mTLS + RBAC (allowed and refused), private endpoint through the internal NLBs,
# per-broker NLB health, and surviving a broker restart.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
kubectl() { command kubectl --context "$CORE_CTX" "$@"; }

NS=confluent
TOPIC=demo-orders
INTERNAL_BOOTSTRAP=kafka.confluent.svc.cluster.local:9071
PRIVATE_BOOTSTRAP=kafka.${PRIVATE_ZONE}:9092
WORK="$(mktemp -d)"

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }
k() { kubectl -n "$NS" "$@"; }
kc() { k exec kafka-client -- "$@"; }

echo "== Pods and placement"
for app in kraftcontroller kafka; do
  zones=$(k get pods -l "app=$app" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | xargs -I{} kubectl --context "$CORE_CTX" get node {} -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}' | sort -u)
  n=$(echo "$zones" | grep -c .)
  ready=$(k get pods -l "app=$app" -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true)
  [[ "$ready" == 3 ]] && pass "$app: 3/3 ready" || fail "$app: $ready/3 ready"
  [[ "$n" == 3 ]] && pass "$app spread over 3 AZs: $(echo $zones)" || fail "$app in $n AZs: $(echo $zones)"
done
for i in 0 1 2; do
  pod_zone=$(kubectl get node "$(k get pod kafka-$i -o jsonpath='{.spec.nodeName}')" \
    -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  pv=$(k get pvc "data0-kafka-$i" -o jsonpath='{.spec.volumeName}')
  pv_zone=$(kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}')
  [[ "$pod_zone" == "$pv_zone" ]] && pass "kafka-$i and its gp3 PV are both in $pod_zone" \
    || fail "kafka-$i in $pod_zone but PV in $pv_zone"
done

echo "== Test client pod (alice, bob and the kafka super user, each with its own certificate)"
for who in alice bob; do
  k get secret "client-$who-tls" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/$who.crt"
  k get secret "client-$who-tls" -o jsonpath='{.data.tls\.key}' | base64 -d > "$WORK/$who.key"
done
k get secret tls-kafka -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/admin.crt"
k get secret tls-kafka -o jsonpath='{.data.tls\.key}' | base64 -d > "$WORK/admin.key"
k get secret tls-kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/ca.crt"
for who in alice bob admin; do
  openssl pkcs12 -export -in "$WORK/$who.crt" -inkey "$WORK/$who.key" -name "$who" \
    -out "$WORK/$who.p12" -passout pass:changeit
  cat > "$WORK/$who.properties" <<EOF
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/certs/ca.crt
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/$who.p12
ssl.keystore.password=changeit
EOF
done
k create secret generic kafka-test-clients --from-file="$WORK" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kafka-client
spec:
  containers:
    - name: client
      image: confluentinc/cp-server:8.4.1
      command: [sleep, infinity]
      volumeMounts: [{ name: certs, mountPath: /certs }]
  volumes:
    - name: certs
      secret: { secretName: kafka-test-clients }
EOF
k wait pod/kafka-client --for=condition=Ready --timeout=300s >/dev/null && pass "kafka-client pod ready"

echo "== Topic and broker configuration (as the kafka super user)"
desc=$(kc kafka-topics --bootstrap-server "$INTERNAL_BOOTSTRAP" --command-config /certs/admin.properties --describe --topic "$TOPIC")
echo "$desc" | grep -q "PartitionCount: 6" && echo "$desc" | grep -q "ReplicationFactor: 3" \
  && pass "$TOPIC: 6 partitions, replication factor 3" || fail "unexpected topic layout: $desc"
echo "$desc" | grep -q "min.insync.replicas=2" && pass "$TOPIC: min.insync.replicas=2" || fail "min.insync.replicas not 2"
racks=""
for id in 0 1 2; do
  rack=$(kc kafka-configs --bootstrap-server "$INTERNAL_BOOTSTRAP" --command-config /certs/admin.properties \
    --describe --entity-type brokers --entity-name "$id" --all | sed -n 's/.*broker.rack=\([^ ]*\).*/\1/p' | head -1)
  racks="$racks $id=$rack"
done
[[ $(echo "$racks" | tr ' ' '\n' | cut -d= -f2 | grep -c "$AWS_REGION") == 3 ]] \
  && pass "broker.rack set from the node zone:$racks" || fail "broker.rack missing:$racks"

echo "== mTLS + RBAC"
produce() {  # who bootstrap message
  kc bash -c "echo '$3' | kafka-console-producer --bootstrap-server $2 --topic $TOPIC \
    --producer.config /certs/$1.properties --producer-property acks=all 2>&1"
}
consume() {  # who bootstrap group
  kc bash -c "kafka-console-consumer --bootstrap-server $2 --topic $TOPIC --group $3 \
    --consumer.config /certs/$1.properties --from-beginning --timeout-ms 20000 2>/dev/null"
}
stamp=$(date +%s)
out=$(produce alice "$INTERNAL_BOOTSTRAP" "internal-$stamp")
[[ "$out" != *rror* ]] && pass "alice produced via $INTERNAL_BOOTSTRAP (mTLS, User:alice)" || fail "alice produce failed: $out"
consume alice "$INTERNAL_BOOTSTRAP" "demo-check-internal-$stamp" | grep -q "internal-$stamp" \
  && pass "alice consumed her record via the internal listener" || fail "alice did not consume her record"

out=$(produce bob "$INTERNAL_BOOTSTRAP" "bob-$stamp" || true)
[[ "$out" == *TopicAuthorizationException* || "$out" == *"Not authorized"* ]] \
  && pass "bob (valid certificate, no role binding) is refused: TopicAuthorizationException" \
  || fail "bob was not refused: $out"

echo "== Private endpoint (internal NLBs + private DNS)"
for h in kafka b0 b1 b2; do
  kc getent hosts "$h.${PRIVATE_ZONE}" >/dev/null && pass "$h.${PRIVATE_ZONE} resolves in-VPC" \
    || fail "$h.${PRIVATE_ZONE} does not resolve"
  if dig +short @1.1.1.1 "$h.${PRIVATE_ZONE}" | grep -q .; then
    fail "$h.${PRIVATE_ZONE} resolves on the public internet"
  fi
done
pass "none of the private names resolve on the public internet"
out=$(produce alice "$PRIVATE_BOOTSTRAP" "private-$stamp")
[[ "$out" != *rror* ]] && pass "alice produced via $PRIVATE_BOOTSTRAP" || fail "private produce failed: $out"
consume alice "$PRIVATE_BOOTSTRAP" "demo-check-private-$stamp" | grep -q "private-$stamp" \
  && pass "alice consumed via the private endpoint (bootstrap + per-broker NLBs)" || fail "private consume failed"

echo "== Internal NLBs"
for svc in $(k get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' | grep -E '^(kafka-|mds-lb)'); do
  host=$(k get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  read -r arn scheme azs < <(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?DNSName=='${host}'] | [0].[LoadBalancerArn,Scheme,length(AvailabilityZones)]" --output text)
  xz=$(aws elbv2 describe-load-balancer-attributes --region "$AWS_REGION" \
    --load-balancer-arn "$arn" --query "Attributes[?Key=='load_balancing.cross_zone.enabled'].Value" --output text)
  healthy=0
  for tg in $(aws elbv2 describe-target-groups --region "$AWS_REGION" \
      --load-balancer-arn "$arn" --query 'TargetGroups[].TargetGroupArn' --output text); do
    h=$(aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn "$tg" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
    healthy=$((healthy + h))
  done
  [[ "$scheme" == internal && "$azs" == 3 && "$xz" == true ]] \
    || fail "$svc: scheme=$scheme azs=$azs cross-zone=$xz"
  if [[ "$svc" == kafka-bootstrap-lb || "$svc" == mds-lb ]]; then
    [[ "$healthy" == 3 ]] || fail "$svc: $healthy healthy targets (expected 3)"
  else
    [[ "$healthy" == 1 ]] || fail "$svc: $healthy healthy targets (expected 1)"
  fi
  pass "$svc: internal, 3 AZs, cross-zone on, $healthy healthy target(s)"
done

if [[ "${FAILOVER:-0}" != 1 ]]; then
  echo "== Broker restart: skipped (FAILOVER=1 ./check.sh kafka deletes kafka-1 while producing)"
else
echo "== Broker restart (delete kafka-1 while producing)"
k delete pod kafka-1 --wait=false >/dev/null
sleep 5
ok=0
for i in $(seq 1 6); do
  out=$(produce alice "$PRIVATE_BOOTSTRAP" "failover-$stamp-$i")
  [[ "$out" != *rror* ]] && ok=$((ok + 1))
  sleep 5
done
[[ "$ok" == 6 ]] && pass "6/6 acks=all produces succeeded while kafka-1 was restarting" \
  || fail "$ok/6 produces succeeded during the restart"
k wait pod/kafka-1 --for=condition=Ready --timeout=600s >/dev/null && pass "kafka-1 back to ready"
urp=""
for _ in $(seq 1 30); do
  urp=$(kc kafka-topics --bootstrap-server "$INTERNAL_BOOTSTRAP" --command-config /certs/admin.properties \
    --describe --under-replicated-partitions)
  [[ -z "$urp" ]] && break
  sleep 10
done
[[ -z "$urp" ]] && pass "no under-replicated partitions after recovery" || fail "under-replicated partitions remain: $urp"
n=$(consume alice "$INTERNAL_BOOTSTRAP" "demo-check-failover-$stamp" | grep -c "failover-$stamp-")
[[ "$n" == 6 ]] && pass "all 6 records written during the restart are readable" || fail "$n/6 records readable"
fi

echo "== Cleanup"
k delete pod kafka-client --wait=false >/dev/null
k delete secret kafka-test-clients >/dev/null
rm -rf "$WORK"
pass "test client removed"
