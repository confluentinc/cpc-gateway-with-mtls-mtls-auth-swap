#!/usr/bin/env bash
# Prints the demo settings as export lines for any shell:  eval "$(./lib/env.sh)"
set -euo pipefail
source "$(dirname "$0")/common.sh"
for v in CORE_CTX DMZ_CTX GATEWAY_DOMAIN SR_PUBLIC_HOST PUBLIC_ZONE PRIVATE_ZONE SECRETS_DIR; do
  printf 'export %s=%q\n' "$v" "${!v}"
done
