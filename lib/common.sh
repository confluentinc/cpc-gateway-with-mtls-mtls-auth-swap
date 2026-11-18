# Shared settings and helpers, sourced by setup.sh, teardown.sh, check.sh and every step script.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-$ROOT/config.env}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

[[ -f "$CONFIG" ]] || die "missing $CONFIG. Create it with: cp config.env.example config.env (then edit it)"
set -a
# shellcheck disable=SC1090
source "$CONFIG"
set +a
for v in AWS_REGION OWNER CORE_CLUSTER DMZ_CLUSTER CORE_VPC_CIDR DMZ_VPC_CIDR PARENT_ZONE PUBLIC_ZONE PRIVATE_ZONE \
  PUBLIC_ALLOWED_CIDRS; do
  [[ -n "${!v:-}" ]] || die "config.env: $v is not set"
done
[[ -n "${AWS_PROFILE:-}" ]] || unset AWS_PROFILE
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

SECRETS_DIR="$ROOT/.secrets"
case "${CONFLUENT_LICENSE_FILE:-.secrets/confluent-license.txt}" in
  /*) LICENSE_FILE="$CONFLUENT_LICENSE_FILE" ;;
  *) LICENSE_FILE="$ROOT/${CONFLUENT_LICENSE_FILE:-.secrets/confluent-license.txt}" ;;
esac
CFK_CHART_VERSION=0.2038.1
CORE_CTX="$CORE_CLUSTER"
DMZ_CTX="$DMZ_CLUSTER"
GATEWAY_DOMAIN="kafka.gateway.$PUBLIC_ZONE"
SR_PUBLIC_HOST="sr.$PUBLIC_ZONE"
yaml_list() { local IFS=,; local items=($1); local out; out=$(printf '%s, ' "${items[@]// /}"); echo "[${out%, }]"; }
PUBLIC_ALLOWED_CIDRS_YAML="$(yaml_list "$PUBLIC_ALLOWED_CIDRS")"
export SECRETS_DIR LICENSE_FILE CORE_CTX DMZ_CTX GATEWAY_DOMAIN SR_PUBLIC_HOST PUBLIC_ALLOWED_CIDRS_YAML

kcore() { kubectl --context "$CORE_CTX" "$@"; }
kdmz() { kubectl --context "$DMZ_CTX" "$@"; }
hcore() { helm --kube-context "$CORE_CTX" "$@"; }
hdmz() { helm --kube-context "$DMZ_CTX" "$@"; }

load_passwords() {
  [[ -s "$SECRETS_DIR/passwords.env" ]] || die "$SECRETS_DIR/passwords.env is missing; run ./setup.sh core-platform first"
  set -a
  # shellcheck disable=SC1091
  source "$SECRETS_DIR/passwords.env"
  set +a
}

# Terraform inputs from config.env (terraform/<stack>/config.auto.tfvars.json, git-ignored).
write_tfvars() {  # core | dmz
  local out="$ROOT/terraform/$1/config.auto.tfvars.json"
  _tfvars "$1" > "$out"
}
_tfvars() {
  local profile="${AWS_PROFILE:-}"
  case "$1" in
    core) jq -n --arg p "$profile" --arg r "$AWS_REGION" --arg n "$CORE_CLUSTER" --arg c "$CORE_VPC_CIDR" \
            --arg z "$PRIVATE_ZONE" --arg o "$OWNER" \
            '{aws_profile: $p, region: $r, cluster_name: $n, vpc_cidr: $c, private_zone_name: $z, owner: $o}' ;;
    dmz) jq -n --arg p "$profile" --arg r "$AWS_REGION" --arg n "$DMZ_CLUSTER" --arg c "$DMZ_VPC_CIDR" \
           --arg pz "$PARENT_ZONE" --arg z "$PUBLIC_ZONE" --arg cidrs "$PUBLIC_ALLOWED_CIDRS" --arg o "$OWNER" \
           '{aws_profile: $p, region: $r, cluster_name: $n, vpc_cidr: $c, parent_zone_name: $pz, public_zone_name: $z,
             public_allowed_cidrs: ($cidrs | split(",") | map(gsub(" "; ""))), owner: $o}' ;;
  esac
}

# Terraform outputs that manifests need (security group, IAM roles, KMS key, target group, subnets).
load_tf_outputs() {
  local core dmz
  core="$(terraform -chdir="$ROOT/terraform/core" output -json)" || die "no terraform/core outputs; run ./setup.sh infra-core"
  dmz="$(terraform -chdir="$ROOT/terraform/dmz" output -json)" || die "no terraform/dmz outputs; run ./setup.sh infra-dmz"
  [[ "$dmz" != "{}" ]] || die "terraform/dmz has no outputs; run ./setup.sh infra-dmz"
  CORE_PRIVATE_CIDRS_YAML="$(jq -r '.private_subnet_cidrs.value | "[" + join(", ") + "]"' <<<"$core")"
  DMZ_PRIVATE_CIDRS_YAML="$(jq -r '.private_subnet_cidrs.value | "[" + join(", ") + "]"' <<<"$dmz")"
  GATEWAY_NLB_SG="$(jq -r .gateway_nlb_security_group_id.value <<<"$dmz")"
  GATEWAY_IRSA_ROLE_ARN="$(jq -r .gateway_irsa_role_arn.value <<<"$dmz")"
  GATEWAY_KMS_ROLE_ARN="$(jq -r .gateway_kms_role_arn.value <<<"$dmz")"
  PAYMENTS_KEK_ARN="$(jq -r .payments_kek_arn.value <<<"$dmz")"
  SR_TARGET_GROUP_ARN="$(jq -r .sr_target_group_arn.value <<<"$dmz")"
  export CORE_PRIVATE_CIDRS_YAML DMZ_PRIVATE_CIDRS_YAML GATEWAY_NLB_SG GATEWAY_IRSA_ROLE_ARN GATEWAY_KMS_ROLE_ARN \
    PAYMENTS_KEK_ARN SR_TARGET_GROUP_ARN
}

# Prints a manifest with ${NAME} replaced for the variables below only, so $(nodeId), $1 and ${file:...} stay as they
# are. Fails if the file uses one of them while it is unset (e.g. load_tf_outputs was not called).
RENDER_VARS=(PUBLIC_ZONE PRIVATE_ZONE GATEWAY_DOMAIN SR_PUBLIC_HOST CORE_VPC_CIDR DMZ_VPC_CIDR PUBLIC_ALLOWED_CIDRS_YAML
  CORE_PRIVATE_CIDRS_YAML DMZ_PRIVATE_CIDRS_YAML GATEWAY_NLB_SG GATEWAY_IRSA_ROLE_ARN GATEWAY_KMS_ROLE_ARN
  PAYMENTS_KEK_ARN SR_TARGET_GROUP_ARN)
render() {
  local v
  for v in "${RENDER_VARS[@]}"; do
    if grep -q "\${$v}" "$1" && [[ -z "${!v:-}" ]]; then die "$1 needs \${$v}, which is not set"; fi
  done
  envsubst "$(printf '${%s} ' "${RENDER_VARS[@]}")" < "$1"
}
apply_core() { render "$1" | kcore apply -f -; }
apply_dmz() { render "$1" | kdmz apply -f -; }

wait_rolebindings() {
  local rb
  for rb in "$@"; do
    kcore -n confluent wait "confluentrolebinding/$rb" --for=jsonpath='{.status.state}'=CREATED --timeout=300s
  done
}

# Port-forwards a service to localhost:<port> until the calling script exits.
PF_PIDS=()
port_forward() {  # <kcore|kdmz> <namespace> <service> <local port> <remote port>
  "$1" -n "$2" port-forward "svc/$3" "$4:$5" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  trap 'kill "${PF_PIDS[@]}" 2>/dev/null || true' EXIT
  for _ in $(seq 30); do nc -z 127.0.0.1 "$4" 2>/dev/null && return; sleep 1; done
  die "port-forward to $3 failed"
}

# Admin REST calls to a core Schema Registry through a port-forward, as testadmin. The CA comes from the cluster and
# --connect-to keeps the service name, so the certificate is still verified.
#   sr_admin_open <service> <local port>; sr_admin <service> <path> [curl args...]
sr_admin_open() {
  [[ -n "${SR_CA:-}" ]] || SR_CA="$SECRETS_DIR/ca.crt"
  kcore -n confluent get secret tls-kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > "$SR_CA"
  port_forward kcore confluent "$1" "$2" 8081
  eval "SR_PORT_${1//-/_}=$2"
}
sr_admin() {
  local svc=$1 path=$2 port_var="SR_PORT_${1//-/_}"; shift 2
  local host="$svc.confluent.svc.cluster.local"
  curl -sS --fail-with-body --cacert "$SR_CA" --connect-to "$host:8081:127.0.0.1:${!port_var}" \
    -u "testadmin:$TESTADMIN_PASSWORD" -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
    "https://$host:8081$path" "$@"
}
