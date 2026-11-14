#!/usr/bin/env bash
# Step 5 on the server: get the cluster's PUBLIC sealing certificate (so you can encrypt secrets on
# your PC), and take a one-time backup of the PRIVATE key (so you can rebuild the cluster later).
#
# Run after the sealed-secrets controller is up:  bash 05-fetch-seal-cert.sh
#
# Output:
#   ~/pub-cert.pem                        PUBLIC. Safe to commit. Copy it to secrets/pub-cert.pem in the repo.
#   ~/sealed-secrets-key-backup.yaml      PRIVATE. Whoever has this can decrypt every sealed secret.
#                                         Download it, store it OFFLINE (password manager), then delete it here.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> Waiting for the sealed-secrets controller"
kubectl -n kube-system rollout status deployment/sealed-secrets-controller --timeout=180s

echo "==> Public certificate"
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > "$HOME/pub-cert.pem"
openssl x509 -in "$HOME/pub-cert.pem" -noout -subject -dates

echo "==> Private key backup"
umask 077
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > "$HOME/sealed-secrets-key-backup.yaml"

SERVER_IP="$(curl -s -m 5 https://checkip.amazonaws.com || echo '<server-ip>')"
cat <<EOF

Now copy BOTH files to your PC (run this on your PC, not here):

  scp -i <your-key.pem> ubuntu@${SERVER_IP}:pub-cert.pem                    secrets/pub-cert.pem
  scp -i <your-key.pem> ubuntu@${SERVER_IP}:sealed-secrets-key-backup.yaml  ~/safe-place/

Store sealed-secrets-key-backup.yaml somewhere safe and OFFLINE, never in git.
Then delete it from the server:   shred -u ~/sealed-secrets-key-backup.yaml
EOF
