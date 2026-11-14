#!/usr/bin/env bash
# Run on YOUR PC (Git Bash or WSL), from the repo root:  ./scripts/generate-secrets.sh
#
# Creates secrets-local/*.env with fresh random values (database passwords, Django secret key,
# hash pepper, PIN encryption key) and the database connection strings. You then paste in the
# third-party keys (Paystack, VTpass, Resend, Gemini) by hand.
#
# secrets-local/ is git-ignored: these plain files NEVER go to GitHub. Only their ENCRYPTED
# versions (made by ./scripts/seal-all.sh) are committed.
#
# IMPORTANT: back up secrets-local/ in a password manager. HASH_PEPPER and PIN_ENCRYPTION_KEY must
# stay the same for the life of the data: changing them later breaks duplicate-entry detection and
# makes stored prize PINs unreadable. The script refuses to overwrite existing files.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="secrets-local"
mkdir -p "$OUT"
umask 077

if [ -e "$OUT/giveaway.env" ] || [ -e "$OUT/postgres.env" ]; then
  echo "secrets-local/ already has files. Refusing to overwrite them (that could break live data)." >&2
  echo "If you really want fresh ones, move the old folder away first." >&2
  exit 1
fi

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

rand_hex() { openssl rand -hex "$1"; }
rand_key() { openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-64; }
# A Fernet key: 32 random bytes, URL-safe base64.
rand_fernet() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n'; }

PG_ADMIN="$(rand_hex 16)"
PG_GIVEAWAY="$(rand_hex 16)"
# The landing login still exists in Postgres (data/postgres.yaml creates it, and the old landing
# database is kept for rollback), so its password is still generated. No app uses it any more.
PG_LANDING="$(rand_hex 16)"
HOST="postgres.platform.svc.cluster.local:5432"

cat > "$OUT/postgres.env" <<EOF
POSTGRES_PASSWORD=$PG_ADMIN
GIVEAWAY_DB_PASSWORD=$PG_GIVEAWAY
LANDING_DB_PASSWORD=$PG_LANDING
EOF

cat > "$OUT/giveaway.env" <<EOF
DJANGO_SECRET_KEY=$(rand_key)
HASH_PEPPER=$(rand_hex 32)
PIN_ENCRYPTION_KEY=$(rand_fernet)
DATABASE_URL=postgres://giveaway:$PG_GIVEAWAY@$HOST/giveaway
PAYSTACK_SECRET_KEY=PASTE_YOUR_LIVE_PAYSTACK_SECRET_KEY
VTPASS_API_KEY=PASTE_YOUR_LIVE_VTPASS_API_KEY
VTPASS_PUBLIC_KEY=PASTE_YOUR_LIVE_VTPASS_PUBLIC_KEY
VTPASS_SECRET_KEY=PASTE_YOUR_LIVE_VTPASS_SECRET_KEY
RESEND_API_KEY=PASTE_YOUR_RESEND_API_KEY
GEMINI_API_KEY=PASTE_YOUR_GEMINI_API_KEY
EOF

echo "Created:"
ls -1 "$OUT"
echo
echo "Next:"
echo "  1. Open $OUT/giveaway.env and replace every PASTE_... value with your real LIVE key."
echo "     (Use the live Paystack key that starts with sk_live_, and the LIVE VTpass keys.)"
echo "  2. Back up the whole $OUT folder in your password manager."
echo "  3. Run ./scripts/seal-all.sh"
