#!/usr/bin/env bash
# Removes everything setup.sh created, in reverse order: workloads first (so Kubernetes deletes their load balancers,
# DNS records and volumes while the controllers still run), then terraform destroy for the DMZ and the core stacks.
#   ./teardown.sh        asks once before starting
#   ./teardown.sh -y     no prompts
# .secrets/ is kept (passwords, MDS keys, client stores); delete it yourself for a clean slate.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
AUTO_APPROVE=""
[[ "${1:-}" == -y ]] && AUTO_APPROVE=-auto-approve
if [[ -z "$AUTO_APPROVE" ]]; then
  read -r -p "Destroy clusters $CORE_CLUSTER and $DMZ_CLUSTER, their VPCs and zones $PUBLIC_ZONE / $PRIVATE_ZONE? [y/N] " a
  [[ "$a" == y || "$a" == Y ]] || exit 1
  AUTO_APPROVE=-auto-approve
fi

ctx_ok() { kubectl --context "$1" get ns kube-system >/dev/null 2>&1; }
wait_no_lb() {  # <kcore|kdmz>: until no LoadBalancer services and no TargetGroupBindings are left
  for _ in $(seq 60); do
    n=$("$1" get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' | grep -c . || true)
    t=$("$1" get targetgroupbindings -A --no-headers 2>/dev/null | grep -c . || true)
    [[ "$n" == 0 && "$t" == 0 ]] && return
    echo "  waiting for $n load balancer service(s) and $t target group binding(s)"
    sleep 10
  done
  die "load balancers still present; check the AWS Load Balancer Controller logs"
}
delete_ns() { "$1" delete ns "${@:2}" --ignore-not-found --wait=true --timeout=600s; }
delete_cfk_rest() {  # <kcore|kdmz> <ns>: CFK resources carry operator finalizers, so delete them all before uninstalling it
  local kinds
  kinds=$("$1" api-resources --api-group=platform.confluent.io --namespaced -o name | paste -sd, -)
  [[ -z "$kinds" ]] || "$1" -n "$2" delete "$kinds" --all --ignore-not-found --wait=true --timeout=300s
}

if ctx_ok "$DMZ_CTX"; then
  step "DMZ workloads"
  kdmz -n gateway delete gateway --all --ignore-not-found --wait=true --timeout=600s
  kdmz -n gateway delete schemaregistry --all --ignore-not-found --wait=true --timeout=600s
  kdmz -n gateway delete targetgroupbinding --all --ignore-not-found --wait=true --timeout=300s
  delete_ns kdmz monitoring
  wait_no_lb kdmz
  delete_cfk_rest kdmz gateway
  hdmz uninstall confluent-operator -n gateway --ignore-not-found --wait
  delete_ns kdmz gateway
fi

if ctx_ok "$CORE_CTX"; then
  step "Core workloads"
  delete_ns kcore clients
  # Role bindings and topics are removed through Kafka, so they go first.
  kcore -n confluent delete confluentrolebinding,kafkatopic,schema --all --ignore-not-found --wait=true --timeout=600s
  kcore -n confluent delete controlcenter,schemaregistry --all --ignore-not-found --wait=true --timeout=600s
  kcore -n confluent delete kafka,kraftcontroller --all --ignore-not-found --wait=true --timeout=900s
  kcore -n confluent delete svc mds-lb --ignore-not-found
  delete_ns kcore logging
  wait_no_lb kcore
  kcore -n confluent delete statefulset ldap --ignore-not-found --wait=true --timeout=300s
  kcore -n confluent delete pvc --all --ignore-not-found --wait=true --timeout=300s
  delete_cfk_rest kcore confluent
  hcore uninstall confluent-operator -n confluent --ignore-not-found --wait
  delete_ns kcore confluent
fi

step "Waiting for ExternalDNS to remove its records"
for _ in $(seq 30); do
  zones="$(aws route53 list-hosted-zones --query \
    "HostedZones[?Name=='$PRIVATE_ZONE.' || Name=='$PUBLIC_ZONE.'].Id" --output text)"
  left=0
  for z in $zones; do
    n=$(aws route53 list-resource-record-sets --hosted-zone-id "$z" \
      --query "length(ResourceRecordSets[?Type!='NS' && Type!='SOA' && !starts_with(Name, '_')])" --output text)
    left=$((left + n))
  done
  # The public zone keeps sr.<zone> (Terraform) until terraform destroy.
  [[ "$left" -le 1 ]] && break
  echo "  $left record(s) left"
  sleep 20
done

for stack in dmz core; do
  step "terraform destroy ($stack)"
  write_tfvars "$stack"
  terraform -chdir="$ROOT/terraform/$stack" init -upgrade=false -input=false >/dev/null
  terraform -chdir="$ROOT/terraform/$stack" destroy -input=false $AUTO_APPROVE
done
for c in "$DMZ_CTX" "$CORE_CTX"; do kubectl config delete-context "$c" >/dev/null 2>&1 || true; done
echo "Done. KMS keys are scheduled for deletion (AWS minimum: 7 days)."
