#!/usr/bin/env bash
# Step 1 on the server: update the operating system and apply basic hardening.
# Run as:  sudo bash 01-prepare-os.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo:  sudo bash $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating packages"
apt-get update -y
apt-get upgrade -y
apt-get install -y curl ca-certificates unattended-upgrades fail2ban jq git

echo "==> Setting the clock to UTC (logs, backups and the app all assume UTC)"
timedatectl set-timezone UTC

echo "==> Turning on automatic security updates and brute-force protection for SSH"
systemctl enable --now unattended-upgrades
systemctl enable --now fail2ban

echo "==> SSH: keys only, no root login"
cat > /etc/ssh/sshd_config.d/99-giveaway-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
# Only reload if the configuration is valid, so a typo can never lock you out.
if sshd -t; then
  systemctl reload ssh || systemctl reload sshd
else
  echo "sshd config check failed; removing the hardening file" >&2
  rm -f /etc/ssh/sshd_config.d/99-giveaway-hardening.conf
  exit 1
fi

if [ -f /var/run/reboot-required ]; then
  echo
  echo "A reboot is needed to finish the updates. Run:  sudo reboot"
  echo "Then reconnect with SSH and continue with step 2."
else
  echo
  echo "Done. Continue with step 2 (02-install-k3s.sh)."
fi
