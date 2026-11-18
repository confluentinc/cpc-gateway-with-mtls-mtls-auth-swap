#!/usr/bin/env bash
# Builds the demo in order, or only the given steps. Every step is safe to re-run.
#   ./setup.sh                 all steps
#   ./setup.sh dmz-sr          one step (or several)
#   ./setup.sh --from dmz-gateway
#   ./setup.sh list
#   -y                         no Terraform approval prompt
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

STEPS=(
  "infra-core      Core VPC, EKS, private DNS zone, LB controller, ExternalDNS, cert-manager  terraform/core"
  "infra-dmz       DMZ VPC, EKS, peering, NACLs, public DNS zone, SR ALB, KMS key              terraform/dmz"
  "core-platform   CFK operator, private CA and certificates, OpenLDAP                         cfk/core/00-platform"
  "core-kafka      KRaft, Kafka (mTLS, RBAC, MDS on LDAP), internal NLBs, demo topics            cfk/core/01-kafka"
  "core-sr         Schema Registry (core), data-contract topics and role bindings               cfk/core/02-schema-registry"
  "core-c3         Control Center                                                               cfk/core/03-control-center"
  "core-logging    Loki and Alloy for broker logs                                               cfk/core/04-logging"
  "data-contracts  payments KEK and the Payment schema with CEL and ENCRYPT rules                 cfk/core/05-data-contracts"
  "schema-linking  Read-only SR leader, MDS NLB for the DMZ, exporter to the read-only cluster   cfk/core/06-schema-linking"
  "dmz-platform    CFK operator in the DMZ, Gateway certificates and credentials                 cfk/dmz/00-platform"
  "dmz-gateway     CPC Gateway (public NLB, mTLS SNI route, governance, encryption, fencing)    cfk/dmz/01-gateway"
  "dmz-sr          Read-only SR followers behind the public ALB (sr.<PUBLIC_ZONE>)              cfk/dmz/02-schema-registry"
  "dmz-monitoring  Prometheus and Grafana with the Gateway dashboards                           cfk/dmz/03-monitoring"
  "dmz-logging     Alloy for the Gateway logs (to the core Loki)                                cfk/dmz/04-logging"
  "clients         Client certificates and configs, Java demo jar, internal client pod          clients"
)
name_of() { echo "${1%% *}"; }
dir_of() { echo "${1##* }"; }

AUTO_APPROVE=""
SELECTED=()
FROM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y) AUTO_APPROVE=-auto-approve ;;
    --from) FROM="${2:?--from needs a step name}"; shift ;;
    list)
      for s in "${STEPS[@]}"; do printf '  %s\n' "$(echo "$s" | sed -E 's/ {2,}[^ ]+$//')"; done
      exit 0 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) SELECTED+=("$1") ;;
  esac
  shift
done

check_prereqs() {
  local missing=() t
  for t in aws terraform kubectl helm jq envsubst openssl curl nc dig keytool java mvn; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]} (see README.md, Prerequisites)"
  [[ -s "$LICENSE_FILE" ]] || die "Confluent license not found at $LICENSE_FILE (CONFLUENT_LICENSE_FILE in config.env)"
  aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not valid${AWS_PROFILE:+ for profile $AWS_PROFILE} (aws sso login?)"
}

run_terraform() {  # core | dmz
  local dir="$ROOT/terraform/$1" cluster
  write_tfvars "$1"
  terraform -chdir="$dir" init -upgrade=false -input=false >/dev/null
  terraform -chdir="$dir" apply -input=false $AUTO_APPROVE
  cluster="$(terraform -chdir="$dir" output -raw cluster_name)"
  aws eks update-kubeconfig --name "$cluster" --region "$AWS_REGION" --alias "$cluster" >/dev/null
  echo "kubectl context: $cluster"
}

run_step() {
  local name dir
  name="$(name_of "$1")"
  dir="$(dir_of "$1")"
  printf '\n######## %s (%s)\n' "$name" "$dir"
  case "$dir" in
    terraform/*) run_terraform "${dir#terraform/}" ;;
    *) "$ROOT/$dir/deploy.sh" ;;
  esac
}

run=()
started=""
[[ -z "$FROM" ]] && started=1
for s in "${STEPS[@]}"; do
  n="$(name_of "$s")"
  if [[ ${#SELECTED[@]} -gt 0 ]]; then
    for want in "${SELECTED[@]}"; do [[ "$want" == "$n" ]] && run+=("$s"); done
  else
    [[ "$n" == "$FROM" ]] && started=1
    [[ -n "$started" ]] && run+=("$s")
  fi
done
[[ ${#run[@]} -gt 0 ]] || die "no matching steps; see ./setup.sh list"
if [[ ${#SELECTED[@]} -gt 0 && ${#run[@]} -ne ${#SELECTED[@]} ]]; then die "unknown step in: ${SELECTED[*]}"; fi

check_prereqs
for s in "${run[@]}"; do run_step "$s"; done
printf '\nDone. Next: ./check.sh, then DEMO.md\n'
