#!/usr/bin/env bash
# Restore one database from a backup in S3. Use for a real recovery, and for the restore drill
# you should run once before launch (docs/OPERATIONS.md).
#
#   CONFIRM=yes bash restore-db.sh <database> <s3-uri>
#   e.g. CONFIRM=yes bash restore-db.sh giveaway s3://my-bucket/giveaway/giveaway-20261120-020001.dump
#
# This REPLACES the contents of the database with the backup. Stop the apps that use it first:
#   kubectl -n giveaway scale deploy/backend deploy/workers --replicas=0
# and start them again afterwards (Flux restores the replica counts on its next sync, or run
#   flux reconcile kustomization apps --with-source ).
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

DB="${1:?usage: CONFIRM=yes $0 <database> <s3-uri>}"
S3_URI="${2:?usage: CONFIRM=yes $0 <database> <s3-uri>}"

case "$DB" in
  giveaway|landing) ;;
  *) echo "Unknown database '$DB' (expected giveaway or landing)" >&2; exit 1 ;;
esac

if [ "${CONFIRM:-}" != "yes" ]; then
  echo "This will overwrite the '$DB' database with $S3_URI." >&2
  echo "Re-run with CONFIRM=yes to proceed." >&2
  exit 1
fi

PGPASSWORD="$(kubectl -n platform get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"

echo "==> Restoring $DB from $S3_URI"
kubectl -n platform run "restore-$DB" --rm -i --restart=Never \
  --image=postgres:16-alpine \
  --env="PGHOST=postgres.platform.svc.cluster.local" \
  --env="PGUSER=postgres" \
  --env="PGPASSWORD=$PGPASSWORD" \
  --env="S3_URI=$S3_URI" \
  --env="DB=$DB" \
  -- sh -c '
    set -eu
    apk add --no-cache aws-cli >/dev/null
    aws s3 cp --only-show-errors "$S3_URI" /tmp/restore.dump
    pg_restore --list /tmp/restore.dump >/dev/null
    pg_restore --clean --if-exists --no-owner --role="$DB" --dbname="$DB" /tmp/restore.dump
    echo "restore finished"
  '

echo "Done. Start the apps again and check them (kubectl -n giveaway get pods)."
