#!/usr/bin/env bash
# Fails if any CHANGE_ME placeholder is still in the files Flux applies. Run before you push, and
# before the first deploy.   ./scripts/check-placeholders.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -rn 'CHANGE_ME' clusters apps data infrastructure \
     --include='*.yaml' --include='*.yml' --include='*.env'; then
  echo
  echo "The lines above still need a real value." >&2
  exit 1
fi
echo "No CHANGE_ME placeholders left."
