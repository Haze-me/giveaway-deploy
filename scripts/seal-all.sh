#!/usr/bin/env bash
# Run on YOUR PC, from the repo root:  ./scripts/seal-all.sh
#
# Encrypts the files in secrets-local/ into "sealed" Kubernetes secrets that are safe to commit.
# Only the cluster's controller can decrypt them (they are bound to a name and namespace).
#
# Needs:
#   - kubectl and kubeseal on your PATH
#       kubeseal download: https://github.com/bitnami-labs/sealed-secrets/releases
#   - secrets/pub-cert.pem   the cluster's PUBLIC certificate (BUILD-RUNBOOK step 9)
#   - secrets-local/*.env    made by ./scripts/generate-secrets.sh, with no PASTE_ values left
#
# Re-run it any time a secret changes (for example you rotate a key), commit the three output
# files and push. Then restart the app so it picks the new value (docs/OPERATIONS.md).
set -euo pipefail

cd "$(dirname "$0")/.."
CERT="secrets/pub-cert.pem"

command -v kubectl >/dev/null || { echo "kubectl not found on PATH" >&2; exit 1; }
command -v kubeseal >/dev/null || { echo "kubeseal not found on PATH (see the header of this script)" >&2; exit 1; }
[ -f "$CERT" ] || { echo "Missing $CERT. Fetch it from the server first (BUILD-RUNBOOK step 9)." >&2; exit 1; }

for f in postgres giveaway landing; do
  [ -f "secrets-local/$f.env" ] || { echo "Missing secrets-local/$f.env. Run ./scripts/generate-secrets.sh first." >&2; exit 1; }
done
if grep -n 'PASTE_' secrets-local/*.env; then
  echo "Replace the PASTE_... values above with your real keys, then run this again." >&2
  exit 1
fi

seal() { # name namespace env-file output-file
  local name="$1" namespace="$2" envfile="$3" out="$4"
  mkdir -p "$(dirname "$out")"
  kubectl create secret generic "$name" \
    --namespace "$namespace" \
    --from-env-file="$envfile" \
    --dry-run=client -o yaml \
    | kubeseal --cert "$CERT" --format yaml > "$out"
  echo "sealed -> $out"
}

seal postgres-credentials platform secrets-local/postgres.env data/secrets/postgres-credentials.sealed.yaml
seal giveaway-secrets giveaway secrets-local/giveaway.env apps/giveaway/secrets/giveaway-secrets.sealed.yaml
seal landing-secrets landing secrets-local/landing.env apps/landing/secrets/landing-secrets.sealed.yaml

echo
echo "Done. Commit and push these three files:"
echo "  git add data/secrets apps/giveaway/secrets apps/landing/secrets secrets/pub-cert.pem"
echo "  git commit -m 'Add sealed secrets' && git push"
