#!/usr/bin/env bash
# Core cluster add-ons healthy, and an internal NLB + private DNS record work end to end.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
kubectl() { command kubectl --context "$CORE_CTX" "$@"; }

ZONE="$PRIVATE_ZONE"
HOST="lbtest.${ZONE}"
NS=lbtest

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }

cleanup() {
  kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

echo "== Add-ons"
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s >/dev/null \
  && pass "aws-load-balancer-controller ready" || fail "aws-load-balancer-controller not ready"
kubectl -n kube-system rollout status deploy/external-dns --timeout=180s >/dev/null \
  && pass "external-dns ready" || fail "external-dns not ready"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl -n cert-manager rollout status "deploy/$d" --timeout=180s >/dev/null \
    && pass "$d ready" || fail "$d not ready"
done

echo "== Internal NLB + private DNS test ($HOST)"
trap cleanup EXIT
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
spec:
  replicas: 1
  selector:
    matchLabels: { app: echo }
  template:
    metadata:
      labels: { app: echo }
    spec:
      containers:
        - name: nginx
          image: public.ecr.aws/nginx/nginx:stable
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-attributes: load_balancing.cross_zone.enabled=true
    external-dns.kubernetes.io/hostname: ${HOST}
spec:
  type: LoadBalancer
  selector: { app: echo }
  ports: [{ port: 80, targetPort: 80 }]
EOF
kubectl -n "$NS" rollout status deploy/echo --timeout=180s >/dev/null && pass "test pod running"

lb=""
for _ in $(seq 1 60); do
  lb=$(kubectl -n "$NS" get svc echo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$lb" ]] && break
  sleep 5
done
[[ -n "$lb" ]] && pass "NLB provisioned: $lb" || fail "no NLB hostname after 5 minutes"
read -r arn scheme azs < <(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='${lb}'] | [0].[LoadBalancerArn,Scheme,length(AvailabilityZones)]" --output text)
[[ "$scheme" == internal ]] && pass "NLB scheme is internal" || fail "NLB scheme is '$scheme'"
[[ "$azs" == 3 ]] && pass "NLB spans 3 AZs" || fail "NLB spans $azs AZs"
xz=$(aws elbv2 describe-load-balancer-attributes --region "$AWS_REGION" --load-balancer-arn "$arn" \
  --query "Attributes[?Key=='load_balancing.cross_zone.enabled'].Value" --output text)
[[ "$xz" == true ]] && pass "cross-zone load balancing enabled" || fail "cross-zone is '$xz'"

echo "  ...waiting for DNS record and NLB targets (can take 3-5 minutes)"
ok=""
for _ in $(seq 1 40); do
  if kubectl -n "$NS" run probe --rm -i --restart=Never --quiet \
       --image=public.ecr.aws/docker/library/busybox:stable -- \
       sh -c "nslookup ${HOST} >/dev/null 2>&1 && wget -q -T 5 -O /dev/null http://${HOST}/" >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 10
done
[[ -n "$ok" ]] && pass "${HOST} resolves in-VPC and serves HTTP through the internal NLB" \
  || fail "${HOST} did not resolve or serve HTTP within ~7 minutes"

if dig +short @1.1.1.1 "$HOST" | grep -q .; then
  fail "${HOST} resolves on the public internet"
else
  pass "${HOST} does not resolve on the public internet"
fi

echo "== Cleanup (removes the test NLB and DNS record)"
cleanup
trap - EXIT
pass "test resources deleted"
