#!/usr/bin/env bash
# Core cluster: Loki (10-day retention, 20Gi gp3, internal NLB loki.<PRIVATE_ZONE> for the DMZ) and the Alloy
# collector for the broker and KRaft logs.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

apply_core "$HERE/loki.yaml"
kcore -n logging rollout status sts/loki --timeout=300s
apply_core "$HERE/alloy.yaml"
kcore -n logging rollout restart deploy/alloy
kcore -n logging rollout status deploy/alloy --timeout=300s
