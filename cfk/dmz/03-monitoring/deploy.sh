#!/usr/bin/env bash
# DMZ cluster: Prometheus and Grafana for the Gateway metrics, Loki (core) as the log data source.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
PW_FILE="$SECRETS_DIR/grafana-admin.password"

step "Prometheus"
apply_dmz "$HERE/prometheus.yaml"

step "Grafana admin password (.secrets/grafana-admin.password)"
[[ -s "$PW_FILE" ]] || (umask 077; openssl rand -base64 18 | tr -d '/+=\n' > "$PW_FILE")
kdmz -n monitoring create secret generic grafana-admin --from-literal=password="$(tr -d '\n' < "$PW_FILE")" \
  --dry-run=client -o yaml | kdmz apply -f -

step "Grafana dashboards and Grafana"
kdmz -n monitoring create configmap grafana-dashboards --from-file="$HERE/dashboards" \
  --dry-run=client -o yaml | kdmz apply -f -
apply_dmz "$HERE/grafana.yaml"
kdmz -n monitoring rollout restart deploy/grafana
kdmz -n monitoring rollout status deploy/prometheus --timeout=300s
kdmz -n monitoring rollout status deploy/grafana --timeout=300s
