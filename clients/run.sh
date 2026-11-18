#!/usr/bin/env bash
# Runs the Java demo producer or consumer on this machine, through the public Gateway and Schema Registry.
#   ./clients/run.sh producer --topic demo-payments [--count 10] [--invalid amount|currency|card]
#   ./clients/run.sh consumer --topic demo-payments [--from beginning] [--group demo-<name>]
#   ./clients/run.sh --user bob producer ...       (default alice; configs from clients/export-client-config.sh)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
USER_NAME=alice
if [[ "${1:-}" == --user ]]; then USER_NAME="$2"; shift 2; fi
case "${1:-}" in
  producer) CLASS=com.wf.demo.Producer ;;
  consumer) CLASS=com.wf.demo.Consumer ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
shift
JAR="$ROOT/clients/java-gateway-demo/target/gateway-demo.jar"
CONF="$SECRETS_DIR/clients/$USER_NAME-gateway.properties"
[[ -s "$JAR" && -s "$CONF" ]] || die "run ./setup.sh clients first"
exec java -cp "$JAR" "$CLASS" --config "$CONF" "$@"
