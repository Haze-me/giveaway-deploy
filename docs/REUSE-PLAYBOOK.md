# Reuse playbook: the same environment for another project

This is the short version, for starting a new project on this pattern. The detail is in
[BUILD-RUNBOOK.md](BUILD-RUNBOOK.md) and the reasons are in [ARCHITECTURE.md](ARCHITECTURE.md).

## The pattern

```
app repo (code) --CI: test, build, push--> Docker Hub
        \--CI: commit image tag--> deploy repo (YAML) <--pulled by-- Flux in k3s on one EC2 server
                                                         Postgres in the cluster, nightly backup to S3
```

Two repos per project: **code** and **deploy**. The server pulls; CI never has cluster access.

## What to copy and what to change

Copy this whole repo as the starting point of `<project>-deploy`, then:

| Change | Where |
|---|---|
| Hostnames, emails | `clusters/production/cluster-settings.yaml` |
| Backup bucket | `data/backup-cronjob.yaml` |
| App manifests | `apps/<app>/` (copy `apps/landing/` for a plain web API, `apps/giveaway/` for web + worker + frontend) |
| Image names | `images:` in `apps/<app>/kustomization.yaml`, and `DOCKERHUB_NAMESPACE`/names in the app repo's `ci-cd.yml` |
| Databases and roles | init script in `data/postgres.yaml`, keys in `scripts/generate-secrets.sh` and `scripts/seal-all.sh` |
| Non-secret settings | `apps/<app>/config.env` |
| Secret settings | `secrets-local/<app>.env`, sealed by `scripts/seal-all.sh` |

Copy `.github/workflows/ci-cd.yml` from the app repo and adjust the paths, test commands and image names.

## Checklist (about half a day the second time)

1. Pick names: deploy repo, domain hosts, bucket, Docker Hub repos (public).
2. AWS: bucket (14-day lifecycle) + IAM role limited to it + t3.medium Ubuntu 24.04, 30 GB gp3,
   **IMDS hop limit 2**, ports 22/80/443, Elastic IP.
3. DNS A records to the Elastic IP.
4. Deploy repo: fill placeholders, `./scripts/validate.sh`, push.
5. Server: scripts `01` to `03`, token, `04` (Flux), `05` (sealing cert + **private key backup**).
6. PC: `generate-secrets.sh`, fill live keys, `seal-all.sh`, push.
7. App repo: secrets `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DEPLOY_REPO_TOKEN`; variable `DEPLOY_REPO`.
8. Push app code. Watch the pipeline, then `flux get kustomizations`.
9. Staging certificate works -> switch both ingresses to `letsencrypt-prod`.
10. Backup drill and restore drill.
11. Anything that moves money stays OFF until a live rehearsal passes.

## Lessons baked in (do not relearn these)

- **Ask the owner before choosing any stack component.** This project uses the F5 NGINX Ingress Controller at the owner's request (the community ingress-nginx was retired in March 2026); k3s's Traefik is disabled with `--disable traefik`.
- **Annotations differ:** this controller uses `nginx.org/...`, not `nginx.ingress.kubernetes.io/...`. Every Ingress that gets a cert-manager certificate needs `acme.cert-manager.io/http01-edit-in-place: "true"`.
- **HTTPS redirect:** the controller redirects per Ingress that has a `tls:` block and lets the certificate challenge through; do not add a blanket redirect rule.
- **`externalTrafficPolicy: Local`** or every visitor shows the same internal IP.
- **IMDS hop limit 2** or pods cannot use the instance role and S3 backups fail.
- **Flux envsubst:** `${VAR}` in manifests is replaced from `cluster-settings`. A literal `$` needs `$$`.
  Shell scripts with `$` belong in a Kustomization without `postBuild` (the `data` one).
- **Helm repo addresses move.** The Sealed Secrets chart is at `https://bitnami.github.io/sealed-secrets` (the older `bitnami-labs.github.io` address returns 404). If a HelmRelease says "no artifact available", run `kubectl describe helmrepository <name>` and curl the URL from the server.
- **`--disable traefik` must really be in the k3s install command** (check `/etc/rancher/k3s/config.yaml` or the service flags); otherwise Traefik keeps ports 80/443 and the NGINX controller's service stays Pending.
- **Postgres on Ubuntu 24.04 + k3s:** the official image needed three fixes: run as uid 70 (`gosu` spun at 100% CPU as root), a `startupProbe` with probes on `127.0.0.1`, and `appArmorProfile: Unconfined` on the pod (AppArmor denied the signals between Postgres and its probes; check `sudo dmesg | grep DENIED`). After fixing a broken first start, wipe the empty volume (scale to 0, delete the PVC, scale to 1) because a half-finished data folder is skipped by the init step.
- **Fresh cluster shows red Kustomizations** until the sealed secrets are committed. Expected.
- **Health probes** must send the right `Host` header (it must be in `ALLOWED_HOSTS`) and
  `X-Forwarded-Proto: https`, or Django answers 400/301 and the pod never becomes Ready.
- **Migrations in an init container**, not a Job (Jobs are immutable under Flux) and not on every boot.
- **Background workers: one replica, `Recreate`.** Anything that pays or sends must never run twice.
- **`prune: false` for data.** Deleting a YAML file must not delete a database.
- **Back up the sealed-secrets private key** offline the moment it exists.
- **Keys that tie to stored data** (hash pepper, encryption keys) must never be regenerated.
- **Dump to a file, verify, then upload.** Streaming a dump straight to S3 can store a half-written backup.
- **Non-numeric container users** break `runAsNonRoot`; use a numeric `runAsUser`.
- **Test gate:** a red test stops the image build; style checks stay advisory until the code base is clean.
- **Let's Encrypt staging first**, switch to prod when issuance works (production has rate limits).

## Not included (add when needed)

Terraform for the server, a staging cluster (layout supports `clusters/staging/`), monitoring and alerting
(Uptime Kuma or a hosted pinger is the cheapest first step), HA Postgres or RDS, image scanning.
