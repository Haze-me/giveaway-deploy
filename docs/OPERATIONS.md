# Operations

Everyday tasks once the environment is built. Server commands assume you are SSHed in as `ubuntu`.

## Deploying

**App code (giveaway):** push to `main` in the app repo. Tests run; if they pass, images are built, pushed, and
`apps/giveaway/kustomization.yaml` here gets a commit like `giveaway: deploy 3fa9c1e`. Flux applies it within
about five minutes. To skip the wait: `flux reconcile kustomization apps --with-source`.

**Config change** (hostnames, money switches, etc.): edit `apps/giveaway/config.env` (or
`clusters/production/cluster-settings.yaml`), run `./scripts/validate.sh`, commit, push. The backend and
workers restart on their own because the ConfigMap name changes with its content.

Watch a rollout:

```bash
flux get kustomizations
kubectl -n giveaway rollout status deploy/backend
kubectl -n giveaway get pods
```

Database migrations run in an init container of the backend before the new version takes traffic. If a
migration fails the new pod stays `Init:Error` and the old one keeps serving. Read it with
`kubectl -n giveaway logs deploy/backend -c migrate` (the container name is in `apps/giveaway/backend.yaml`).

## Rolling back

Preferred (keeps history): find the bad deploy commit in this repo and revert it.

```bash
git revert <commit>      # on your PC, in giveaway-deploy
git push
```

Or edit `newTag` in `apps/giveaway/kustomization.yaml` back to an earlier 7-character hash (every build
stays on Docker Hub under its hash) and push. The next CI run would move it forward again, which is correct.

Rolling the code back does **not** roll back database migrations. If a bad release ran a migration, restore
the database (below) or write a fix-forward migration.

## Looking at things

```bash
kubectl get pods -A
kubectl -n giveaway logs deploy/backend --tail=200 -f
kubectl -n giveaway logs deploy/workers --tail=200 -f
kubectl -n giveaway describe pod <name>
kubectl get certificate -A
kubectl top node                   # CPU and memory
df -h /                            # disk
```

Django admin: `https://app.example.com/admin/`. A shell in the app:
`kubectl -n giveaway exec -it deploy/backend -- python manage.py shell`.

## Backups and restores

Nightly at 02:00 UTC the CronJob dumps each database, verifies the dump, and uploads to
`s3://<bucket>/<db>/<db>-<timestamp>.dump`. Old dumps expire after 14 days (bucket lifecycle rule).

Run one now:

```bash
kubectl -n platform create job --from=cronjob/postgres-backup backup-now
kubectl -n platform logs -f job/backup-now
kubectl -n platform delete job backup-now
```

Check the last run: `kubectl -n platform get jobs`.

**Restore a database** (this replaces its contents):

```bash
kubectl -n giveaway scale deploy/backend deploy/workers --replicas=0     # stop writers first
CONFIRM=yes bash on-server/restore-db.sh giveaway s3://<bucket>/giveaway/giveaway-<timestamp>.dump
flux reconcile kustomization apps --with-source                           # restores replica counts
```

If Flux does not restore them, scale back: backend to its normal count (see `backend.yaml`), workers **to 1**.

Restore drill: do this once before launch, and again after major changes. Restore into the real DB while the
app has no real data, then confirm the app starts and the admin login works.

## Rotating a secret

1. Edit the value in `secrets-local/*.env` (and update your password manager).
2. `./scripts/seal-all.sh`, commit the three sealed files, push.
3. Flux updates the Secret, but **running pods do not reload it**. Restart them:

```bash
kubectl -n giveaway rollout restart deploy/backend deploy/workers
```

Never rotate `HASH_PEPPER` or `PIN_ENCRYPTION_KEY` once real data exists. A Paystack or VTpass key rotation is
safe; do it outside busy hours.

Changing a database password also needs `ALTER ROLE` inside Postgres, because the init script only runs on
first start:
`kubectl -n platform exec -it postgres-0 -- psql -U postgres -c "ALTER ROLE giveaway PASSWORD '<new>'"`,
and the password inside `DATABASE_URL` must change in the same commit.

## Disaster recovery (server lost)

1. Launch a new server and run build steps 2 to 8 (use the same Elastic IP: re-associate it).
2. Restore the **sealed-secrets private key** from your backup before Flux applies secrets:
   `kubectl apply -f sealed-secrets-key-backup.yaml` then `kubectl -n kube-system rollout restart deploy/sealed-secrets-controller`.
   Do not run `generate-secrets.sh` again: you must reuse the original `secrets-local/` values, because
   `HASH_PEPPER` and `PIN_ENCRYPTION_KEY` have to match the restored data.
3. When Postgres is running, restore each database with `restore-db.sh` from the latest S3 dump.
4. Expect to lose up to 24 hours of data (the gap since the last backup). Reconcile Paystack/VTpass records by hand
   for that window.

## Updating the platform itself

- **OS patches:** `sudo apt update && sudo apt upgrade`, reboot in a quiet hour (app is down for about a minute).
  Unattended security upgrades are already on (`01-prepare-os.sh`).
- **k3s:** re-run `02-install-k3s.sh` (it installs from the `stable` channel) after reading the release notes.
- **cert-manager, Sealed Secrets:** bump the chart version in `infrastructure/controllers/*.yaml`, validate, push.
  Pin versions; never use `latest`.
- Certificates renew automatically about 30 days before expiry. Expiry warnings go to `ACME_EMAIL`.

## Adding things

**Another app:** copy `apps/giveaway/` as a template to `apps/<name>/`, add it to `apps/kustomization.yaml`,
add a role and database in the Postgres init section of `data/postgres.yaml` (and a password key in the
postgres secret), seal a new secret, add an A record. See [REUSE-PLAYBOOK.md](REUSE-PLAYBOOK.md).

**A staging environment:** copy `clusters/production/` to `clusters/staging/` with its own
`cluster-settings.yaml`, run Flux bootstrap with `--path=clusters/staging` on a second server. Use separate
sealed secrets (a different cluster has a different sealing key).

## Hard rules

- Never scale `workers` above one replica.
- Never delete Postgres's volume (the PVC in the `platform` namespace) or the `data` Kustomization.
- Never put plain secrets in git. If one leaks: rotate it, then rewrite the history.
- Keep `PAYOUTS_ENABLED` and `PRIZE_REFUNDS_ENABLED` changes as separate, reviewed commits.
