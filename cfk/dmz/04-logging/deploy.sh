#!/usr/bin/env bash
# DMZ cluster: Alloy collector for the Gateway and read-only SR logs, pushing to the core Loki
# (loki.<PRIVATE_ZONE>:3100). Needs core-logging and dmz-monitoring (monitoring namespace) first.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

apply_dmz "$HERE/alloy.yaml"
kdmz -n monitoring rollout restart deploy/alloy
kdmz -n monitoring rollout status deploy/alloy --timeout=300s
