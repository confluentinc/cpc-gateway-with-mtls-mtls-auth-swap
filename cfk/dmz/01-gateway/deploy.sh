#!/usr/bin/env bash
# Gateway role bindings in the core cluster, then the CPC Gateway (public NLB, DNS, KMS access) in the DMZ cluster.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
load_tf_outputs

step "Core: role bindings for User:cpcgw-dmz-client"
apply_core "$HERE/core-rbac.yaml"
wait_rolebindings cpcgw-dmz-client-demo-topics-write cpcgw-dmz-client-demo-topics-read

step "DMZ: Gateway (IRSA service account and KMS executor params first)"
apply_dmz "$HERE/kms-irsa.yaml"
apply_dmz "$HERE/gateway.yaml"
kdmz -n gateway wait gateway/cpcgw-dmz --for=jsonpath='{.status.phase}'=RUNNING --timeout=900s
echo "Gateway: $GATEWAY_DOMAIN:9092 (mTLS, client certificates from the demo CA)"
