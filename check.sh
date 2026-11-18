#!/usr/bin/env bash
# Runs the checks in order, or only the given ones. Each prints PASS/FAIL lines and stops at the first failure.
#   ./check.sh                    all
#   ./check.sh gateway schema-linking
#   FAILOVER=1 ./check.sh kafka   also restarts a broker while producing
set -euo pipefail
cd "$(dirname "$0")"
ALL=(core-addons core-platform kafka schema-registry schema-linking gateway)
[[ $# -gt 0 ]] && ALL=("$@")
for c in "${ALL[@]}"; do
  [[ -x "checks/$c.sh" ]] || { echo "unknown check $c (have: $(ls checks | sed 's/\.sh$//' | tr '\n' ' '))"; exit 1; }
  printf '\n######## %s\n' "$c"
  "checks/$c.sh"
done
printf '\nAll checks passed.\n'
