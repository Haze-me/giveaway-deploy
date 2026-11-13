#!/usr/bin/env bash
# Checks that every manifest renders and matches Kubernetes' (and cert-manager/Flux's)
# schemas, WITHOUT touching a cluster. Runs in CI on every push and you can run it locally.
#
#   ./scripts/validate.sh
#
# Needs: kubectl (for `kubectl kustomize`) and kubeconform on your PATH.
#   kubeconform: https://github.com/yannh/kubeconform/releases
set -euo pipefail

cd "$(dirname "$0")/.."
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }

# Work on a copy, with stand-in sealed secrets where the real (encrypted) ones are not committed
# yet, so a fresh checkout can still be validated.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R . "$WORK/repo"
cd "$WORK/repo"
rm -rf .git

stub() { # path name namespace
  if [ ! -f "$1" ]; then
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: $2
  namespace: $3
spec:
  encryptedData:
    KEY: AgBstub
  template:
    metadata:
      name: $2
      namespace: $3
EOF
    echo "(stand-in used for $1)"
  fi
}
stub data/secrets/postgres-credentials.sealed.yaml postgres-credentials platform
stub apps/giveaway/secrets/giveaway-secrets.sealed.yaml giveaway-secrets giveaway
stub apps/landing/secrets/landing-secrets.sealed.yaml landing-secrets landing

SCHEMAS=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
CHECK=(kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0 "${SCHEMAS[@]}")

fail=0
for dir in infrastructure/controllers infrastructure/config data apps; do
  echo "==> $dir"
  if ! kubectl kustomize "$dir" > "$WORK/rendered.yaml"; then
    echo "kustomize could not build $dir" >&2
    fail=1
    continue
  fi
  "${CHECK[@]}" "$WORK/rendered.yaml" || fail=1
done

echo "==> clusters/production (Flux wiring)"
"${CHECK[@]}" clusters/production/*.yaml || fail=1

if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED" >&2
  exit 1
fi
echo "All manifests are valid."
