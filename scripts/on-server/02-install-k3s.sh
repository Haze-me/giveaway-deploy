#!/usr/bin/env bash
# Step 2 on the server: install k3s (a small, production-grade Kubernetes) as a single node.
# Run as your normal user (it uses sudo where needed):  bash 02-install-k3s.sh
#
# What this keeps on purpose (the defaults):
#   - ServiceLB exposes ports 80/443 directly on this server
#   - local-path storage for the Postgres disk
# Turned off on purpose: k3s's built-in Traefik (--disable traefik). The ingress controller is the F5 NGINX Ingress Controller, installed by Flux.
# Added: --secrets-encryption encrypts Kubernetes Secrets at rest in the cluster database.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user (ubuntu), not root; it will ask for sudo itself." >&2
  exit 1
fi

echo "==> Installing k3s (stable channel)"
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - server \
  --write-kubeconfig-mode 644 \
  --secrets-encryption \
  --disable traefik \
  --node-name giveaway-prod

echo "==> Making kubectl work for this user"
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
if ! grep -q 'KUBECONFIG=' "$HOME/.bashrc"; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "$HOME/.bashrc"
fi
export KUBECONFIG="$HOME/.kube/config"

echo "==> Waiting for the node to be Ready (up to 3 minutes)"
for _ in $(seq 1 36); do
  if kubectl get nodes 2>/dev/null | grep -q ' Ready '; then
    break
  fi
  sleep 5
done
kubectl get nodes

kubectl -n kube-system get pods

echo
echo "k3s is running. Continue with step 3 (03-install-flux-cli.sh)."
echo "Open a new shell, or run:  source ~/.bashrc"
