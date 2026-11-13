#!/usr/bin/env bash
# Step 4 on the server: connect the cluster to your giveaway-deploy repository with Flux.
#
# From now on, the cluster watches the repo and applies whatever is committed to main. Flux also
# commits its own wiring into clusters/production/flux-system/ (so remember to `git pull` after).
#
# Needs two environment variables (your GitHub token is NOT stored anywhere by this script):
#   export GITHUB_TOKEN=<fine-grained or classic token with admin/contents access to the repo>
#   export GITHUB_OWNER=<your GitHub username, or the organisation that owns giveaway-deploy>
# Optional:
#   export GITHUB_REPO=giveaway-deploy
#   export GITHUB_PERSONAL=true      # true if the repo is under a personal account (default),
#                                    # false if it belongs to an organisation
set -euo pipefail

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN first (see the header of this script)}"
: "${GITHUB_OWNER:?Set GITHUB_OWNER first (see the header of this script)}"
GITHUB_REPO="${GITHUB_REPO:-giveaway-deploy}"
GITHUB_PERSONAL="${GITHUB_PERSONAL:-true}"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> Checking the cluster is ready for Flux"
flux check --pre

args=(
  --owner="$GITHUB_OWNER"
  --repository="$GITHUB_REPO"
  --branch=main
  --path=clusters/production
)
if [ "$GITHUB_PERSONAL" = "true" ]; then
  args+=(--personal)
fi

echo "==> Bootstrapping Flux against $GITHUB_OWNER/$GITHUB_REPO"
flux bootstrap github "${args[@]}"

echo
echo "Flux is installed. Watch it work with:   flux get kustomizations --watch"
echo "On a brand-new cluster, 'data' and 'apps' will say they cannot build until you add the"
echo "sealed secrets (BUILD-RUNBOOK step 10). That is expected."
