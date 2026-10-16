#!/usr/bin/env bash
# One-command demo: deploy the finance layer, grant access, seed the verified scenario.
#
#   ./scripts/setup-demo.sh <org-alias>            deploy to an existing org (e.g. a free Developer Edition)
#   ./scripts/setup-demo.sh --scratch [devhub]     create a 7-day scratch org first (requires an authorized Dev Hub)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--scratch" ]]; then
  ORG="finance-layer-demo"
  sf org create scratch --definition-file config/project-scratch-def.json \
     --alias "$ORG" --set-default --duration-days 7 \
     ${2:+--target-dev-hub "$2"}
elif [[ -n "${1:-}" ]]; then
  ORG="$1"
else
  echo "usage: $0 <org-alias> | --scratch" >&2
  exit 1
fi

echo "== deploying source =="
sf project deploy start --source-dir force-app --target-org "$ORG" --wait 15

echo "== assigning permission set =="
sf org assign permset --name Finance_Layer_Access --target-org "$ORG"

echo "== running the Apex test suite =="
sf apex run test --tests RevenueScheduleServiceTest --result-format human --synchronous --target-org "$ORG"

echo "== seeding the demo scenario (self-asserting) =="
sf apex run --file scripts/seed-demo-data.apex --target-org "$ORG"

echo ""
echo "Done. Open the org and find the 'Acme Growth Program' opportunity:"
echo "  sf org open --target-org $ORG"
