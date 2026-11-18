#!/usr/bin/env bash
# Client side of the demo: certificates and configs for alice and bob (.secrets/clients), the Java producer and
# consumer jar, and the internal client pod in the core cluster.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

step "Client certificates and configs"
"$ROOT/clients/export-client-config.sh"
step "Java demo jar"
(cd "$ROOT/clients/java-gateway-demo" && mvn -q -DskipTests package)
"$ROOT/clients/internal-client/deploy.sh"
echo "External client: ./clients/run.sh producer --topic demo-payments   (see DEMO.md)"
