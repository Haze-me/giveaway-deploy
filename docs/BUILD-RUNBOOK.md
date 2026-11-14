# Build runbook: from nothing to a running production

Follow the steps in order. Each says where to run it: **PC** (your computer), **SERVER** (over SSH),
**AWS**, **GitHub**, **Namecheap**. Allow a few hours. Tick a step only when its "Check" passes.

Values used below (change them to yours): region `eu-west-1`, domain `example.com`, app at
`app.example.com`, landing API at `landing-api.example.com`, bucket `example-giveaway-backups`.

> Script numbering: the files in `scripts/on-server/` are numbered 01 to 05 and are separate from the
> numbered steps in this document.

---

## Step 1. Prepare your PC and accounts (PC)

You need: a domain on Namecheap, an AWS account, GitHub, Docker Hub, Resend (email), live Paystack and
VTpass accounts.

On your PC (Git Bash on Windows is fine) install: `git`, `openssl`, `ssh`/`scp`, `kubectl`, and
`kubeseal` (https://github.com/bitnami-labs/sealed-secrets/releases; use a 0.2x release that matches the
controller, which `infrastructure/controllers/sealed-secrets.yaml` pins to the `2.x` chart line).

Before you deploy the app, commit and push all pending work in the app repo (`Birthday App`), including
the new `.github/workflows/ci-cd.yml`. The pipeline only builds what is on GitHub.

Check: `git --version`, `kubectl version --client`, `kubeseal --version` all print a version.

## Step 2. AWS: bucket, role, server (AWS console, region eu-west-1)

**2a. Backup bucket.** S3 > Create bucket. Name `example-giveaway-backups` (must be globally unique).
Region eu-west-1. Keep "Block all public access" ON. Then bucket > Management > Lifecycle rule: apply to
all objects, "Expire current versions" after **14 days**.

**2b. IAM policy.** IAM > Policies > Create policy > JSON (replace the bucket name):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::example-giveaway-backups" },
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"], "Resource": "arn:aws:s3:::example-giveaway-backups/*" }
  ]
}
```

Name it `giveaway-backup-access`.

**2c. IAM role.** IAM > Roles > Create role > AWS service > EC2. Attach `giveaway-backup-access`. Name it
`giveaway-server-role`.

**2d. Key pair.** EC2 > Key pairs > Create (type ed25519, format `.pem`). Keep the file safe; it is the only
way in over SSH.

**2e. Launch the instance.** EC2 > Launch instance:

- Name `giveaway-prod`. Image **Ubuntu Server 24.04 LTS** (64-bit x86).
- Type **t3.medium**. Key pair from 2d.
- Network: security group with inbound **22** (My IP), **80** and **443** (anywhere). Nothing else.
- Storage **30 GiB gp3**.
- Advanced details: **IAM instance profile** `giveaway-server-role`; **Metadata version** "V2 only";
  **Metadata response hop limit `2`** (this lets pods use the role for the backup; with 1 the backups fail).

**2f. Elastic IP.** EC2 > Elastic IPs > Allocate > Associate with `giveaway-prod`. Use this fixed IP for DNS.
(Without it the address changes when the server restarts.)

Check: from your PC `ssh -i key.pem ubuntu@<elastic-ip>` gives a prompt.

## Step 3. DNS (Namecheap)

Domain List > Manage > Advanced DNS > add two **A records** to the Elastic IP:

| Host | Value |
|---|---|
| `app` | Elastic IP |
| `landing-api` | Elastic IP |

(Turn off any Namecheap URL redirect on those hosts.) Check from your PC after a few minutes:
`nslookup app.example.com` returns the Elastic IP. Certificates cannot be issued until this resolves.

## Step 4. Create the deploy repo (GitHub + PC)

1. GitHub > New repository `giveaway-deploy`. Private is fine and recommended.
2. On your PC, in the folder `giveaway-deploy`:
   - Edit `clusters/production/cluster-settings.yaml`: the six `CHANGE_ME` values (app host, landing API host,
     landing site origin, ACME email, from address, alert email).
   - Edit `data/backup-cronjob.yaml`: `BACKUP_BUCKET` to your bucket name.
3. `./scripts/check-placeholders.sh` and `./scripts/validate.sh` must pass (validate may print stand-in
   notes for the secrets: that is fine).
4. Commit and push `main` to GitHub.

Check: the "Validate manifests" workflow is green in the Actions tab.

## Step 5. Prepare the server and install k3s (SERVER)

Copy the scripts up and run the first two (PC):

```bash
scp -i key.pem -r scripts/on-server ubuntu@<elastic-ip>:
ssh -i key.pem ubuntu@<elastic-ip>
```

On the server:

```bash
sudo bash on-server/01-prepare-os.sh      # updates + hardening; reboot if it says so, then reconnect
bash on-server/02-install-k3s.sh
kubectl get nodes                          # should show one node: Ready
```

## Step 6. Install the Flux command (SERVER)

```bash
bash on-server/03-install-flux-cli.sh
```

## Step 7. Accounts and tokens for the pipelines (Docker Hub + GitHub)

1. **Docker Hub** > Account settings > Personal access tokens > Generate (Read & Write). Repos
   `birthday-backend` and `birthday-frontend` are created on first push; make sure
   each is **Public**.
2. **GitHub token for CI** (fine-grained personal access token): repository access = **only
   `giveaway-deploy`**; permission **Contents: Read and write**. Call it `DEPLOY_REPO_TOKEN`.
3. In the **app repo** > Settings > Secrets and variables > Actions:
   - Secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DEPLOY_REPO_TOKEN`
   - Variable: `DEPLOY_REPO` = `your-github-user/giveaway-deploy`

Do NOT put `VITE_*` values in GitHub; for the landing page they go in Vercel.

## Step 8. Connect the cluster to the repo (SERVER)

Create a GitHub token for Flux: a classic token with the `repo` scope is simplest. It is used once and not
stored by the script. On the server:

```bash
export GITHUB_TOKEN=<token>
export GITHUB_OWNER=<your-github-user>
bash on-server/04-bootstrap-flux.sh
flux get kustomizations
```

Flux commits its own files to `clusters/production/flux-system/` in the repo. **On your PC run
`git pull`** so you do not overwrite them. Delete the Flux token on GitHub now if you like; the cluster
keeps using a read-only deploy key.

Expect: `infrastructure` becomes Ready (cert-manager, Sealed Secrets, NGINX Ingress Controller).
`data` and `apps` stay red ("cannot build", missing sealed secret files). That is expected until step 10.

## Step 9. Get the sealing certificate (SERVER, then PC)

```bash
bash on-server/05-fetch-seal-cert.sh
```

It prints two `scp` commands: run them **on your PC**. Put `pub-cert.pem` in the repo at
`secrets/pub-cert.pem`. Move `sealed-secrets-key-backup.yaml` to your password manager or offline storage,
then on the server `shred -u ~/sealed-secrets-key-backup.yaml`.

**This private key backup is the only way to decrypt your sealed secrets if the server is lost.** Without it
you would have to generate and seal every secret again, and that includes keys that must never change
(see step 10).

## Step 10. Create and seal the secrets (PC)

```bash
./scripts/generate-secrets.sh
```

Open `secrets-local/giveaway.env` and replace every `PASTE_...` with your real **live** keys (Paystack
`sk_live_...`, VTpass, Resend, Gemini). Put the whole `secrets-local/` folder in your password manager.

**Never regenerate `HASH_PEPPER` or `PIN_ENCRYPTION_KEY` after launch.** Doing so breaks duplicate-entry
detection and makes stored prize PINs unreadable.

```bash
./scripts/seal-all.sh
git add data/secrets apps/giveaway/secrets secrets/pub-cert.pem
git commit -m "Add sealed secrets"
git push
```

On the server `flux get kustomizations --watch`: `data` then `apps` turn Ready. Postgres starts first.
The app pods may show `ImagePullBackOff` (no image yet) until step 11.

Check: `kubectl -n platform get pods` shows `postgres-0` Running.

## Step 11. First release (PC and SERVER)

1. Push the app code to `main` in the app repo. The "CI/CD" workflow runs tests, builds and pushes both
   images, then commits the new tags to `giveaway-deploy`. Watch the Actions tab. If tests fail, fix them:
   nothing is built or deployed from a red build.
2. On the server: `flux reconcile kustomization apps --with-source`, then
   `kubectl -n giveaway get pods` should show `backend`, `workers`, `frontend` Running.
4. Create your admin login:

```bash
kubectl -n giveaway exec -it deploy/backend -- python manage.py createsuperuser
```

Check: `curl -k -I https://app.example.com` answers (the `-k` is because the certificate is still the test
one, see step 12).

## Step 12. Real HTTPS certificates (PC)

Until now the certificate comes from Let's Encrypt's **staging** service (untrusted by browsers, but no rate
limits while you test). Check it was issued: `kubectl get certificate -A` shows `READY True` for
`giveaway-tls` and `landing-api-tls` (both come from the one giveaway ingress).

Then switch to production. In `apps/giveaway/ingress.yaml` change
`cert-manager.io/cluster-issuer: letsencrypt-staging` to `letsencrypt-prod`. Push, then on the server:

```bash
kubectl -n giveaway delete secret giveaway-tls landing-api-tls
```

(cert-manager issues a fresh certificate.) Check in a browser: `https://app.example.com` shows a valid
padlock.

## Step 13. Point the outside world at it

- **Landing site (Vercel):** set `VITE_API_BASE_URL=https://landing-api.example.com` (full URL), plus the
  `VITE_*` contact values, then redeploy. Make sure that site's address is in `LANDING_ORIGINS` in
  `cluster-settings.yaml`.
- **Paystack** (dashboard > Settings > API Keys & Webhooks, live mode): webhook URL
  `https://app.example.com/api/v1/billing/paystack/webhook/`.
- **VTpass:** add the server's Elastic IP to the live allow-list, fund the live wallet.
- **Resend:** the sending domain in `FROM_EMAIL` must be verified.

## Step 14. Live rehearsal, then turn the money on (SERVER + PC)

Payouts and refunds are OFF (`PAYOUTS_ENABLED=false`, `PRIZE_REFUNDS_ENABLED=false`). Rehearse with real but
tiny amounts:

1. `kubectl -n giveaway exec deploy/backend -- python manage.py vtpass_smoke` (a real call of about N100).
2. Create a test event with a N50 fee, join it, and pay through Paystack live. Confirm the webhook arrived
   (`kubectl -n giveaway logs deploy/backend | grep -i paystack`) and the payment shows as successful.
3. Fund the VTpass wallet. In `apps/giveaway/config.env` set `PAYOUTS_ENABLED=true`, push, wait for the
   rollout, finish the test event, and confirm the winner's airtime or data arrives.
4. Only then set `PRIZE_REFUNDS_ENABLED=true`, push, and test a cancel-and-refund on a tiny event.

If anything looks wrong, set the switch back to `false` and push.

## Step 15. Backup drill (SERVER)

Do this once before real users:

```bash
kubectl -n platform create job --from=cronjob/postgres-backup backup-test
kubectl -n platform logs -f job/backup-test
aws s3 ls s3://example-giveaway-backups/giveaway/     # needs the aws CLI, or check in the S3 console
```

Then follow "Restore a database" in [OPERATIONS.md](OPERATIONS.md) against a copy to prove the restore works.

---

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `data`/`apps` red with "secret ... not found" or kustomize build error | Sealed secret files not committed yet (step 10). |
| Certificate stays `READY False` and a separate `cm-acme-http-solver` Ingress exists | The `acme.cert-manager.io/http01-edit-in-place: "true"` annotation is missing from the app Ingress. |
| Certificate stays `READY False` | DNS not pointing at the server yet, or port 80 blocked in the security group. `kubectl describe certificate -A`, `kubectl get challenges -A`. |
| Backend `CrashLoopBackOff` with `ImproperlyConfigured` | A required setting or secret is missing; `kubectl -n giveaway logs deploy/backend` names it. |
| Pods `ImagePullBackOff` | The image tag does not exist on Docker Hub (CI not finished) or the repo is private. |
| Backups fail with access denied | IMDS hop limit is 1 (step 2e), or the role lacks the bucket policy. |
| Everyone's IP looks the same in the audit log | ingress controller `externalTrafficPolicy: Local` was not applied; check `infrastructure/controllers/nginx-ingress.yaml`. |
| Flux shows an old commit | `flux reconcile source git flux-system` then `flux get kustomizations`. |
