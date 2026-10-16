#!/usr/bin/env bash
# Anonymization scrub: greps the repo for denylisted terms before any push.
# The denylist itself lives in .scrub-denylist.txt (gitignored, one term per line,
# case-insensitive) so the guard never publishes what it guards.
set -euo pipefail
cd "$(dirname "$0")/.."

LIST=".scrub-denylist.txt"
if [[ ! -f "$LIST" ]]; then
  echo "FAIL: $LIST not found. Create it locally before pushing; the check cannot pass without it." >&2
  exit 1
fi

hits=0
while IFS= read -r term; do
  [[ -z "$term" || "$term" == \#* ]] && continue
  if matches=$(grep -RIn -i -F --exclude-dir=.git --exclude="$LIST" -- "$term" . 2>/dev/null); then
    echo "DENYLIST HIT: '$term'"
    echo "$matches" | head -5
    hits=1
  fi
done < "$LIST"

if [[ $hits -eq 1 ]]; then
  echo ""
  echo "FAIL: denylisted terms found. Do not push."
  exit 1
fi
echo "scrub check: clean"
