#!/usr/bin/env bash
# Step 3 on the server: install the Flux command-line tool (used once, to connect the cluster to
# your giveaway-deploy repository, and later to check status).
# Run as your normal user:  bash 03-install-flux-cli.sh
set -euo pipefail

echo "==> Installing the Flux CLI"
curl -s https://fluxcd.io/install.sh | sudo bash

flux --version
echo
echo "Next, create a GitHub token for Flux (docs/BUILD-RUNBOOK.md, step 8), then run step 4."
