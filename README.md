# giveaway-deploy

Deployment repository for the Event Giveaway app. It holds
**everything the server runs**, and nothing else. The application code lives in separate repos.

A single AWS EC2 server runs **k3s** (small production Kubernetes). **Flux** inside the cluster watches
this repo and applies whatever is on `main`. Postgres runs in the cluster. Nothing is deployed by hand.

```
 git push (app repo)
      |
      v
 GitHub Actions: test -> build images -> push to Docker Hub
      |
      v
 CI edits the image tag in THIS repo (apps/giveaway/kustomization.yaml)
      |
      v
 Flux (in the cluster) sees the commit -> rolls out the new version
```

## Read these

| Document | Use it when |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | You want to understand how it fits together and why |
| [docs/BUILD-RUNBOOK.md](docs/BUILD-RUNBOOK.md) | Building the environment from nothing, step by step |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day to day: deploy, roll back, logs, backups, rotate a secret |
| [docs/REUSE-PLAYBOOK.md](docs/REUSE-PLAYBOOK.md) | Building the same kind of environment for another project |

## What is in the repo

```
clusters/production/   Flux wiring + cluster-settings.yaml (the few values you edit: hostnames, emails)
infrastructure/        cert-manager (HTTPS certificates), Sealed Secrets, NGINX Ingress Controller, Let's Encrypt issuers
data/                  Postgres (StatefulSet) and the nightly backup to S3
apps/giveaway/         backend, workers, frontend, ingress for the giveaway app (its backend also answers
                       the landing page's feedback API on the landing-api host; the site stays on Vercel)
scripts/               PC-side: generate-secrets, seal-all, validate, check-placeholders
scripts/on-server/     Run on the EC2 server in order: 01 .. 05, plus restore-db.sh
.github/workflows/     Validates the manifests on every push
```

## The four rules

1. **Git is the source of truth.** Change the cluster by committing here, not by running `kubectl apply`.
2. **Secrets are never committed in plain text.** Only encrypted `*.sealed.yaml` files are. The plain
   files live in `secrets-local/` on your PC (git-ignored) and in your password manager.
3. **The money switches default to OFF.** `PAYOUTS_ENABLED` and `PRIZE_REFUNDS_ENABLED` stay `false` in
   `apps/giveaway/config.env` until the live rehearsal passes (BUILD-RUNBOOK step 14).
4. **Run `./scripts/validate.sh` before pushing** a manifest change (CI does it too).

## Quick reference

```bash
./scripts/validate.sh                 # do the manifests render and match their schemas?
./scripts/check-placeholders.sh       # any CHANGE_ME left?
./scripts/generate-secrets.sh         # first time only: create secrets-local/*.env
./scripts/seal-all.sh                 # encrypt secrets-local/*.env into committed *.sealed.yaml
```

On the server (after `ssh`):

```bash
flux get kustomizations               # is everything Ready?
kubectl get pods -A                   # is everything Running?
kubectl -n giveaway logs deploy/backend --tail=100
```
