# From zero to a live app: CI/CD with Kubernetes (k3s) and Flux on one AWS server

**A teaching guide for a junior DevOps engineer.** The trainer follows it step by step and explains as they go.

> **What you will build:** a real production setup. Developers push code, a pipeline builds it, and the
> new version appears on the server by itself. Users reach it at `https://app.example.com` with a valid
> padlock. A database runs on the server.
>
> **You do not need to know any programming language.** You only need to follow the steps, understand
> what each part is for, and check that it works.
>
> **This guide records a setup that was built and is running in production.** Every file and command in it
> has worked, including the fixes for the problems we hit the first time. If you follow it in order you
> should not need trial and error.

Tested on: Ubuntu 24.04, k3s (stable channel), Flux 2.x, cert-manager 1.21, F5 NGINX Ingress Controller 2.8,
Sealed Secrets 2.x, November 2026.

---

## How to use this guide (trainer notes)

- Do the parts **in order**. Each step has the same shape:
  - **What and why:** a short explanation you can read out. Lines starting with 🗣️ are suggested wording.
  - **Do:** the exact commands or file contents.
  - **Check ✅:** what you should see. Do not move on until the check passes.
- Every step starts with a tag saying **where** it happens. Mixing these up is the number one source of
  confusion, so always point at the tag first:

| Tag | Where you are | What it looks like |
|---|---|---|
| **[LAPTOP]** | The WSL Ubuntu terminal on the trainee's Windows laptop | prompt like `you@LAPTOP-123:~$` |
| **[SERVER]** | The AWS server, reached over SSH | prompt like `ubuntu@ip-172-31-26-93:~$` |
| **[AWS]** | The AWS web console in a browser | |
| **[NAMECHEAP]** | The domain registrar's website (or wherever the domain is) | |
| **[GITHUB]** | github.com in a browser | |
| **[DOCKER HUB]** | hub.docker.com in a browser | |

- **Never type or paste a real secret into a chat, ticket or email.** Secrets are typed only into the
  files and tools this guide names.
- Replace the **placeholders** with your real values. The full list is in [Appendix D](#appendix-d-values-you-must-replace).
  The main ones: `example.com` (your domain), `your-dockerhub-user` and `your-github-user`.
- The example application is called **`myapp`**. It has three parts: a **backend** (an API), a
  **frontend** (the website) and a **worker** (a background job runner), plus a **Postgres** database.
  Your developers' real application will have its own names. Part 10 shows how to add more.

---

## Contents

0. [The big picture: concepts first](#part-0-the-big-picture-concepts-first)
1. [Prepare the laptop and the accounts](#part-1-prepare-the-laptop-and-the-accounts)
2. [AWS: the server](#part-2-aws-the-server)
3. [DNS: pointing the domain at the server](#part-3-dns-pointing-the-domain-at-the-server)
4. [The deploy repo: every file, one by one](#part-4-the-deploy-repo-every-file-one-by-one)
5. [CI: the developers' repo builds images](#part-5-ci-the-developers-repo-builds-images)
6. [The server: k3s and Flux](#part-6-the-server-k3s-and-flux)
7. [Secrets: lock them on the laptop, open them on the server](#part-7-secrets-lock-them-on-the-laptop-open-them-on-the-server)
8. [First release and real HTTPS (staging, then production)](#part-8-first-release-and-real-https-staging-then-production)
9. [Final health check](#part-9-final-health-check)
10. [Adding a new service when a developer says it is ready](#part-10-adding-a-new-service-when-a-developer-says-it-is-ready)
11. [Troubleshooting table](#part-11-troubleshooting-table)
12. [Cheat sheet: reading the cluster](#part-12-cheat-sheet-reading-the-cluster)
- Appendices: [A. Folder map](#appendix-a-the-finished-folder-map) · [B. Safety-net validation](#appendix-b-optional-safety-net-validate-before-you-push) · [C. Glossary](#appendix-c-glossary) · [D. Values to replace](#appendix-d-values-you-must-replace)

---

## Part 0. The big picture: concepts first

Spend 20 to 30 minutes here. Everything later makes sense once these ideas are clear.

### 0.1 The whole system in one picture

```
 DEVELOPER ──push code──▶  APP REPO (GitHub)
                              │  CI = GitHub Actions: run tests, build a package ("image"),
                              │       upload it to Docker Hub, then write the new version
                              │       number into the deploy repo
                              ▼
                        DEPLOY REPO (GitHub)  ◀── YOU edit YAML files here
                              │   (the server checks this repo about every minute)
                              ▼
        ┌───────────────────── ONE AWS SERVER (EC2) ─────────────────────┐
        │  k3s = a small Kubernetes                                       │
        │   ├─ Flux ............ reads the deploy repo, makes the server  │
        │   │                    match it ("CD")                          │
        │   ├─ NGINX Ingress ... the receptionist: sends each visitor to  │
        │   │                    the right app by the website address     │
        │   ├─ cert-manager .... gets and renews HTTPS certificates       │
        │   ├─ Sealed Secrets .. unlocks secrets stored safely in git     │
        │   ├─ your apps ....... frontend, backend, worker                │
        │   └─ Postgres ........ the database (on the server's own disk)  │
        └──────────────────────────────────────────────────────────────────┘
                              ▲
   USERS ── https://app.example.com ──▶ DNS (a record at the registrar) ──▶ the server's fixed IP
```

🗣️ *"Two repositories. The **app repo** holds the developers' code. The **deploy repo** holds the
instructions for the server, written as YAML text files. We never log in to the server to install an app.
We change a text file in the deploy repo, and the server copies it."*

### 0.2 Ten ideas you need

**1. Container image.** An app packaged with everything it needs, like a sealed lunchbox. It runs the same
anywhere. Developers write a `Dockerfile`; CI turns it into an *image*.

**2. Docker Hub.** The warehouse where images are stored. The server downloads images from there.
Ours are **public** so the server needs no password to pull them (the code is in a private repo, but the image
holds only the built app, never any secrets).

**3. Kubernetes (here: k3s).** A manager that keeps your apps running. You say "I want 1 copy of the backend
running"; it starts it, restarts it if it crashes, and replaces it during upgrades. **k3s** is Kubernetes in a
single small program, ideal for one server. Words you will meet:

| Word | Plain meaning |
|---|---|
| **Pod** | One running copy of an app (a container or two) |
| **Deployment** | "Keep N pods of this app running, update them gently" |
| **Service** | A fixed internal address for an app (pods come and go; the Service stays) |
| **Namespace** | A department or folder that groups things (`myapp`, `platform`, `flux-system`) |
| **ConfigMap** | A bundle of normal settings (not secret) |
| **Secret** | A bundle of secret settings (passwords, keys) |
| **Ingress** | A routing rule: "website address X goes to Service Y" |

**4. GitOps and Flux (the heart of this guide).** The deploy repo is the **single source of truth** for what
should run. **Flux** is a program inside the cluster that pulls the repo about every minute and makes the
cluster match it. If you change a file and push, the server follows. If someone changes the server by hand,
Flux undoes it. 🗣️ *"Flux is a waiter who re-reads the order book every minute and fixes the table to match."*
Two consequences: **CI never needs access to the server** (the server pulls), and **everything is in git**, so
you have history and can roll back with one revert.

**5. Kustomize and variables.** Plain YAML files are combined by a tool called Kustomize. Two tricks matter:
- The `images:` list in `apps/myapp/kustomization.yaml` holds the *version* of each image. CI rewrites only
  that number on every release. That is what turns "developer pushed code" into "server updated".
- `${APP_HOST}` inside files is replaced by Flux with a value from one small file
  (`cluster-settings.yaml`). Change the website address in one place only. (If you ever need a literal `$`,
  write `$$`.)

**6. Ingress and the NGINX Ingress Controller.** Ports 80 and 443 on the server belong to NGINX. It reads the
website address of each visitor and routes it: `app.example.com/api` to the backend, everything else to the
frontend. 🗣️ *"It is the receptionist at the front desk."* (k3s ships with a different one, Traefik. We switch
it off on purpose, see Part 6.3.)

**7. HTTPS certificates and cert-manager.** Browsers only show the padlock if the site has a valid
certificate. **Let's Encrypt** gives them free; **cert-manager** asks for them and renews them automatically.
There are two Let's Encrypt services:
- **Staging:** unlimited tries, but browsers do **not** trust it (warning page). Use it to prove everything is wired up.
- **Production:** trusted padlock, but strict limits if you get things wrong repeatedly.
We always start on staging, and only when it works do we switch to production (Part 8).

**8. Secrets and Sealed Secrets.** Passwords must never be in git as plain text. **Sealed Secrets** solves it
with a padlock:
- The cluster makes a **key pair**. The **public certificate** is the padlock: anyone can close it, so it is
  safe to store in git (`secrets/pub-cert.pem`).
- The **private key** is the only thing that can open it. It stays inside the cluster, and you keep **one
  offline backup**.
- On your laptop you lock each secret into a *sealed file*. That file is safe to commit. The cluster opens it
  and makes a normal Secret for the app.
🗣️ *"Hackers who read the whole repo see only gibberish. If we lose the server, the offline private-key backup
lets us open the same files on the new one."*

**9. Postgres in the cluster.** The database runs as a pod on the server's own disk. That is simple and
fast. Each app gets its **own database and login**.

> **Important, a decision for this setup:** this build has **no automatic database backup**. The disk of the
> server is the only copy of the data. If the server is lost, the data is lost. That is acceptable only while
> the data is not precious. Decide this with the owner and write the decision down.

**10. CI vs CD.**
- **CI** (continuous integration) = GitHub Actions in the app repo: test, build, push the image, record the new version in the deploy repo.
- **CD** (continuous delivery) = Flux on the server: notice the new version, roll it out.

### 0.3 What happens on every release (memorise this)

```
1. Developer pushes to main in the APP repo.
2. CI runs the tests. Red = stop here, nothing is built.
3. CI builds the images and pushes them to Docker Hub, tagged with the 7-character commit id (e.g. 3fa9c1e).
4. CI edits ONE line in the DEPLOY repo (newTag: 3fa9c1e) and commits it.
5. Within about a minute Flux sees that commit.
6. Flux tells Kubernetes "run the new version". It starts new pods first, and only stops the old ones when
   the new ones answer their health check. Users see no downtime.
```
Nobody logs in to the server. Nobody runs `flux reconcile` (that command only means "check now instead of
waiting a minute").

### 0.4 Who owns what

| Developers own | You (DevOps) own |
|---|---|
| The code, the `Dockerfile`, the tests | The server, DNS, certificates, the deploy repo |
| The list of settings and secrets the app needs | Storing those safely and giving them to the app |
| The health-check address of each app | The CI pipeline file (with the developers' test commands inside) |
| "It is ready" | Adding it to the deploy repo and checking it is reachable |

### 0.5 The order things start (and why a fresh cluster shows red)

Flux applies the deploy repo in four stages, each waiting for the one before:

```
flux-system → infrastructure → infrastructure-config → data → apps
(Flux itself)  (cert-manager,   (the Let's Encrypt     (Postgres  (your apps)
                sealed-secrets, issuers; needs the      the database)
                NGINX)          first stage's tools)
```

On a brand-new cluster, `data` and `apps` stay **red** until you add the sealed secrets in Part 7. That is
**expected**. Tell the junior in advance so they do not panic.

---

## Part 1. Prepare the laptop and the accounts

### 1.1 Accounts to create (about 30 minutes)

| Account | Used for | Notes |
|---|---|---|
| **AWS** | The server | Use region **eu-west-1** (Ireland) in this guide; any region works if you stay consistent. |
| **GitHub** | Two repos: the app repo (exists) and the new deploy repo | Private repos are fine. |
| **Docker Hub** | Stores the images | Free account is enough. |
| **A domain** | The website address | Examples use Namecheap. |
| **Password manager** | Keeping safe copies of keys and secrets | Essential (Part 7). Any manager works. |

### 1.2 Install the tools on the laptop **[LAPTOP]**

Use Windows with **WSL Ubuntu**. Open the **Ubuntu** app (not PowerShell, not Command Prompt). From now on
"the laptop terminal" means this window.

> **Rule:** keep every repo and key in the **Linux side** (your home folder `~`), **not** under `/mnt/c/...`.
> SSH refuses a key file that Windows permissions leave open, and Windows line endings break scripts.

```bash
sudo apt update
sudo apt install -y git openssl openssh-client curl jq
```

Install `kubectl` (only used to *prepare* secrets; the laptop never connects to the cluster):

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl
```

Install `kubeseal` (the secret-locking tool). We pin the version so the download cannot fail on a lookup:

```bash
V=0.41.2
curl -fL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${V}/kubeseal-${V}-linux-amd64.tar.gz" | tar xz kubeseal
sudo install -m 0755 kubeseal /usr/local/bin/kubeseal && rm kubeseal
```

Install `kubeconform`, which checks the YAML before you push (used in Appendix B):

```bash
curl -fsSL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz | tar xz kubeconform
sudo install -m 0755 kubeconform /usr/local/bin/kubeconform && rm kubeconform
```

Set your git identity and make a working folder:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
mkdir -p ~/work ~/safe
```

An editor helps. Visual Studio Code with its **WSL** extension lets you type `code .` inside a WSL folder.

**Check ✅**

```bash
git --version && kubectl version --client && kubeseal --version && kubeconform -v
```
All four print a version number.

---

## Part 2. AWS: the server

Do this in the **AWS console**, region **Europe (Ireland) eu-west-1** (top right corner: check it before every step).

### 2.1 The key pair (the key to the server's door) **[AWS]**

1. Search **EC2** → left menu **Key Pairs** → **Create key pair**.
2. Name `myapp-key`, type **ed25519**, format **.pem**. Create. Your browser downloads `myapp-key.pem`.
3. **Treat this file like a house key.** It is the only way in. Put it in the password manager too.

Move it into WSL and lock its permissions **[LAPTOP]** (adjust the Windows path to where it downloaded):

```bash
mkdir -p ~/.ssh
cp /mnt/c/Users/YOUR_WINDOWS_USER/Downloads/myapp-key.pem ~/.ssh/myapp-key.pem
chmod 600 ~/.ssh/myapp-key.pem
ls -l ~/.ssh/myapp-key.pem
```
**Check ✅** the line starts with `-rw-------`.

### 2.2 Launch the server **[AWS]**

EC2 → **Instances** → **Launch instances**:

| Setting | Value |
|---|---|
| Name | `myapp-prod` |
| Image | **Ubuntu Server 24.04 LTS**, 64-bit (x86) |
| Instance type | **t3.medium** (2 CPU, 4 GB) |
| Key pair | `myapp-key` |
| Network settings → Security group | Create new. Inbound rules: **SSH (22)** from **My IP**, **HTTP (80)** from Anywhere, **HTTPS (443)** from Anywhere. Nothing else. |
| Storage | **30 GiB**, gp3 |

Click **Launch instance**. Wait until **Instance state = Running** and **Status check = 2/2 passed**.

> If your home IP address changes later, SSH (port 22) will stop working. Fix it in the security group by
> editing the SSH rule to your new IP.

### 2.3 A fixed IP address (Elastic IP) **[AWS]**

Without this the server's address changes whenever it restarts and the website breaks.

1. EC2 → **Elastic IPs** → **Allocate Elastic IP address** → **Allocate**.
2. Select it → **Actions** → **Associate Elastic IP address** → choose instance `myapp-prod` → **Associate**.
3. Write the address down. Below it is written **`SERVER_IP`**.

**Check ✅** from the laptop:

```bash
ssh -i ~/.ssh/myapp-key.pem ubuntu@SERVER_IP
```
The first time it asks "Are you sure you want to continue connecting?": type `yes`. You get a prompt like
`ubuntu@ip-172-31-26-93:~$`. Type `exit` to come back.

---

## Part 3. DNS: pointing the domain at the server

🗣️ *"DNS is the phone book. We add one line: `app.example.com` lives at the server's IP."*

**[NAMECHEAP]** (or your registrar): **Domain List** → **Manage** → **Advanced DNS** → **Add new record**:

| Type | Host | Value | TTL |
|---|---|---|---|
| A Record | `app` | `SERVER_IP` | Automatic |

Turn off any "URL redirect" on that host. If you plan to add more services later, you will add one more A
record per host (Part 10).

**Check ✅** from the laptop (it can take 5 to 30 minutes to spread):

```bash
nslookup app.example.com
```
The answer must show `SERVER_IP`. If it shows a **different** address, look for a conflicting record
(for example a wildcard `*` record) and fix it. **Do not continue until it matches**: certificates cannot be
issued while the name points somewhere else.

---

## Part 4. The deploy repo: every file, one by one

This is the most important part. The deploy repo is the set of instructions the server follows. You will
create about 20 small files. For each one, read the **purpose** out loud before pasting its contents.

> **Two kinds of change later:**
> - *Normal settings or versions:* edit a file here, push, and the server follows in about a minute.
> - *Secrets:* never edit here by hand. Use the sealing steps in Part 7.

### 4.1 Create the repository **[GITHUB]** and clone it **[LAPTOP]**

1. GitHub → **New repository** → name `myapp-deploy` → **Private** → tick **Add a README file** (so the
   `main` branch exists) → **Create repository**.
2. Give the laptop permission to push. Create an SSH key and add it to GitHub **[LAPTOP]**:

```bash
ssh-keygen -t ed25519 -C "laptop" -f ~/.ssh/id_github -N ""
cat ~/.ssh/id_github.pub
```
Copy the printed line. **[GITHUB]** → your avatar → **Settings** → **SSH and GPG keys** → **New SSH key** →
paste → **Add SSH key**. Then tell SSH to use it **[LAPTOP]**:

```bash
printf 'Host github.com\n  IdentityFile ~/.ssh/id_github\n  IdentitiesOnly yes\n' >> ~/.ssh/config
chmod 600 ~/.ssh/config
ssh -T git@github.com
```
**Check ✅** it says `Hi your-github-user! You've successfully authenticated`.

3. Clone it **[LAPTOP]**:

```bash
cd ~/work
git clone git@github.com:your-github-user/myapp-deploy.git
cd myapp-deploy
```

### 4.2 Create the folders **[LAPTOP]**

```bash
mkdir -p clusters/production infrastructure/controllers infrastructure/config \
         data/secrets apps/myapp/secrets scripts/on-server secrets .github/workflows docs
```

Open the folder in your editor (`code .`). Create each file below with **exactly** the contents shown. The
folder map at the end of this part ([Appendix A](#appendix-a-the-finished-folder-map)) shows what the result looks like.

### 4.3 Housekeeping files

**`.gitignore`**: stops real secrets ever being committed.

```
# Real secret values live here on your laptop only. Only the ENCRYPTED sealed files are committed.
secrets-local/

# Never commit any kubeconfig, key or token
*.kubeconfig
kubeconfig*
*.key
*.token
sealed-secrets-key-backup*.yaml

# Local scratch
.tmp/
*.log
```

> Note: the **public** certificate `secrets/pub-cert.pem` is meant to be committed. That is why `*.pem` is not ignored.

**`.gitattributes`**: the server is Linux, so always store Linux line endings (Windows ones break scripts).

```
* text=auto eol=lf
*.sh text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
*.md text eol=lf
*.pem text eol=lf
```

### 4.4 The one file with your values: `clusters/production/cluster-settings.yaml`

🗣️ *"Everything that differs between companies is here: the website address and a few emails. They are not
secret, so they live in git in plain text. Flux copies them into every file that has a `${NAME}`."*

```yaml
# The few values that differ per deployment. Edit these once, commit, and Flux applies them.
# They are NOT secret (hostnames and email addresses), so they live in git in plain text.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-settings
  namespace: flux-system
data:
  # Where users open the app (website + /api on one hostname).
  APP_HOST: "app.example.com"
  # Let's Encrypt sends certificate expiry warnings here.
  ACME_EMAIL: "you@example.com"
  # The "from" address on emails the app sends.
  FROM_EMAIL: "no-reply@example.com"
  # Where the app emails you when something needs a person.
  ALERT_EMAIL: "you@example.com"
```

Replace the three example values with the real ones now.

### 4.5 The Flux "wiring": `clusters/production/`

🗣️ *"These three files tell Flux the **order**: infrastructure first, then the database, then the apps.
`dependsOn` means 'wait for that one'. `prune: true` means 'if I delete a file from git, delete the thing from
the server'. For the database we set `prune: false` on purpose, so deleting a file can never delete the database."*

**`clusters/production/infrastructure.yaml`**

```yaml
# The cluster's shared services, in two steps because the second needs the first's tools:
#   1. controllers: cert-manager, sealed-secrets, NGINX Ingress Controller
#   2. config: the Let's Encrypt issuers (needs cert-manager to exist first)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  timeout: 10m
  path: ./infrastructure/controllers
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-config
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure
  interval: 10m
  retryInterval: 2m
  timeout: 5m
  path: ./infrastructure/config
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
```

**`clusters/production/data.yaml`**

```yaml
# Postgres. Deliberately slow and careful:
#   - prune: false  -> removing a file from git NEVER deletes the database or its disk.
#   - no variable substitution -> the shell scripts in here are applied exactly as written.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: data
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure
  interval: 10m
  retryInterval: 2m
  timeout: 10m
  path: ./data
  prune: false
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

**`clusters/production/apps.yaml`**

```yaml
# The applications. This is the Kustomization CI changes: after each build, the pipeline commits
# a new image tag under ./apps and Flux rolls it out.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  dependsOn:
    - name: data
    - name: infrastructure-config
  interval: 5m
  retryInterval: 2m
  timeout: 10m
  path: ./apps
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
```

> The folder `clusters/production/flux-system/` is created **by Flux itself** in Part 6. Do not create it.

### 4.6 Shared services: `infrastructure/controllers/`

🗣️ *"These install three helper programs using **Helm** (like an app store for Kubernetes). We say which store
(`HelmRepository`), which program and which version family (`HelmRelease`)."*

**`infrastructure/controllers/kustomization.yaml`** (the list of what is in this folder)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cert-manager.yaml
  - sealed-secrets.yaml
  - nginx-ingress.yaml
```

**`infrastructure/controllers/cert-manager.yaml`** (the HTTPS certificate robot)

```yaml
# cert-manager: asks Let's Encrypt for HTTPS certificates and renews them before they expire.
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: jetstack
  namespace: cert-manager
spec:
  type: oci
  interval: 24h
  url: oci://quay.io/jetstack/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 1h
  chart:
    spec:
      chart: cert-manager
      version: "1.21.x"
      sourceRef:
        kind: HelmRepository
        name: jetstack
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
  values:
    crds:
      enabled: true
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
    cainjector:
      resources:
        requests:
          cpu: 10m
          memory: 64Mi
    webhook:
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
```

**`infrastructure/controllers/sealed-secrets.yaml`** (the secret unlocker)

```yaml
# Sealed Secrets: lets us keep secrets in git safely. You encrypt a secret on your laptop with the
# cluster's PUBLIC certificate; only this controller (which holds the private key) can decrypt it.
#
# `fullnameOverride` keeps the controller named "sealed-secrets-controller" in kube-system, which
# is where the kubeseal tool looks for it by default.
#
# NOTE: the chart address below is the current one. Older guides show bitnami-labs.github.io,
# which now returns 404.
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: sealed-secrets
  namespace: kube-system
spec:
  interval: 24h
  url: https://bitnami.github.io/sealed-secrets
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: sealed-secrets
  namespace: kube-system
spec:
  interval: 1h
  chart:
    spec:
      chart: sealed-secrets
      version: "2.x"
      sourceRef:
        kind: HelmRepository
        name: sealed-secrets
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    fullnameOverride: sealed-secrets-controller
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
```

**`infrastructure/controllers/nginx-ingress.yaml`** (the receptionist)

```yaml
# F5 NGINX Ingress Controller (open source edition): the web entrance (ports 80/443) that routes
# visitors to the apps. It is NOT the retired community "ingress-nginx" project: it is maintained
# by F5/NGINX, uses the same `nginx` IngressClass name, but has its own annotations (nginx.org/...).
# k3s's built-in Traefik is disabled in 02-install-k3s.sh.
#
# externalTrafficPolicy: Local keeps each visitor's REAL IP address (otherwise every request
# would look like it came from inside the cluster).
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-ingress
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nginx-ingress
  namespace: nginx-ingress
spec:
  type: oci
  interval: 24h
  url: oci://ghcr.io/nginx/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nginx-ingress
  namespace: nginx-ingress
spec:
  interval: 1h
  chart:
    spec:
      chart: nginx-ingress
      version: "2.8.x"
      sourceRef:
        kind: HelmRepository
        name: nginx-ingress
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    controller:
      ingressClass:
        name: nginx
        create: true
        setAsDefaultIngress: true
      service:
        type: LoadBalancer
        externalTrafficPolicy: Local
      # AppArmor is switched off for this pod only. On Ubuntu 24.04 the container runtime's default
      # AppArmor profile denies signals between processes in the pod: the controller could not tell
      # NGINX to reload ("kill(...) failed (13: Permission denied)"), so new routes (including the
      # certificate challenge) were never loaded and returned 404. seccomp stays on.
      podSecurityContext:
        seccompProfile:
          type: RuntimeDefault
        appArmorProfile:
          type: Unconfined
      resources:
        requests:
          cpu: 50m
          memory: 128Mi
```

🗣️ *"The AppArmor lines are a fix for a real problem we met: Ubuntu 24.04's security layer was blocking NGINX
from reloading, so new websites returned 404. We now include the fix from the start."*

### 4.7 The certificate issuers: `infrastructure/config/`

**`infrastructure/config/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cluster-issuers.yaml
```

**`infrastructure/config/cluster-issuers.yaml`**: two Let's Encrypt accounts, staging and production.

```yaml
# Two Let's Encrypt "issuers". Use STAGING first to prove issuing works (browsers will warn, but
# the rate limits are generous), then switch the Ingress annotation to PROD.
# ${ACME_EMAIL} is filled in by Flux from the cluster-settings ConfigMap.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

### 4.8 The database: `data/`

🗣️ *"One Postgres server, one disk. Each app gets its **own database and its own login**, so one app cannot
read another's data. The password comes from a Secret that we create in Part 7."*

**`data/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - postgres.yaml
  # Created by ./scripts/seal-all.sh (encrypted, safe to commit). Until it exists, Flux reports
  # that this Kustomization cannot build; that is expected on a fresh cluster.
  - secrets/postgres-credentials.sealed.yaml
```

**`data/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: platform
  annotations:
    # Flux must never delete this namespace (it holds the database).
    kustomize.toolkit.fluxcd.io/prune: disabled
```

**`data/postgres.yaml`**: includes the three fixes for Ubuntu 24.04 that we found the hard way.

```yaml
# One Postgres server for every app on this cluster. Each app gets its own database and its own
# login. Connection string (built by ./scripts/generate-secrets.sh, stored sealed in the app secret):
#   postgres://myapp:<password>@postgres.platform.svc.cluster.local:5432/myapp
#
# The data lives on a k3s "local-path" volume, i.e. a folder on the EC2's own disk. The disk IS the
# database. There is NO automatic backup in this setup.
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
  namespace: platform
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
data:
  # Runs ONCE, only when the data directory is empty (first ever start). To add a database later,
  # run the same SQL by hand against the running server (Part 10).
  10-create-databases.sh: |
    #!/bin/sh
    set -e
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
    CREATE ROLE myapp LOGIN PASSWORD '$MYAPP_DB_PASSWORD';
    CREATE DATABASE myapp OWNER myapp;
    SQL
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: platform
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
spec:
  clusterIP: None # headless: a stable DNS name straight to the single pod
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: platform
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      terminationGracePeriodSeconds: 60
      # FIX 1: start as the postgres user (uid/gid 70 in the alpine image) from the first
      # instruction. The image otherwise starts as root and switches user with `gosu`; on this
      # server `gosu` spun at 100% CPU and never started Postgres.
      # FIX 2: AppArmor is switched off for THIS pod only. On Ubuntu 24.04 the default AppArmor
      # profile denies the signals Postgres and its health checks send to each other
      # (`sudo dmesg | grep DENIED` shows it), which crashed the first start-up. The container is
      # still isolated and runs as a non-root user.
      securityContext:
        runAsUser: 70
        runAsGroup: 70
        fsGroup: 70
        appArmorProfile:
          type: Unconfined
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: postgres
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_PASSWORD
            - name: MYAPP_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: MYAPP_DB_PASSWORD
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init
              mountPath: /docker-entrypoint-initdb.d
          # FIX 3: the checks use the network address (127.0.0.1), not the local socket. During the
          # very first start, Postgres runs a temporary server on the socket only while it creates
          # the databases; checking the network address means "ready" only counts once the real
          # server is up. The startup probe allows up to 5 minutes for that first start; the other
          # two probes only begin after it passes, so a slow first start is never killed halfway.
          startupProbe:
            exec:
              command: ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"]
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            exec:
              command: ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"]
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"]
            periodSeconds: 10
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
      volumes:
        - name: init
          configMap:
            name: postgres-init
            defaultMode: 0555
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 10Gi
```

### 4.9 The application: `apps/`

🗣️ *"This is what the developers' app needs from us. Notice there are no passwords here. Normal settings are
in `config.env`; secrets arrive from the sealed file."*

> **Developer-specific lines.** The commands marked `# DEVELOPERS` below (migrate, run workers) and the
> health-check paths are what the developers tell you. In this example they are for a Django app.
> For another app, ask the developers for the equivalent. Everything else is the same for any app.

**`apps/kustomization.yaml`** (the list of apps; Part 10 adds to it)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - myapp
```

**`apps/myapp/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

**`apps/myapp/kustomization.yaml`**: **the file CI edits.** Only the two `newTag` lines ever change.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: myapp
resources:
  - namespace.yaml
  - backend.yaml
  - workers.yaml
  - frontend.yaml
  - ingress.yaml
  # Created by ./scripts/seal-all.sh (encrypted, safe to commit). Until it exists, Flux reports
  # that this Kustomization cannot build; that is expected on a fresh cluster.
  - secrets/myapp-secrets.sealed.yaml
# Plain (non-secret) settings. Kustomize adds a hash to the ConfigMap's name, so changing a value
# in config.env automatically restarts the backend and workers onto it.
configMapGenerator:
  - name: myapp-config
    envs:
      - config.env
# CI rewrites ONLY the newTag lines below (to the git commit of each build). Do not edit by hand
# unless you are rolling back.
images:
  - name: your-dockerhub-user/myapp-backend
    newTag: placeholder
  - name: your-dockerhub-user/myapp-frontend
    newTag: placeholder
```

🗣️ *"`newTag: placeholder` is deliberately not a real version. The first CI run in Part 5 replaces it."*

**`apps/myapp/config.env`**: the non-secret settings. **The names come from the developers.**

```
# Non-secret settings for the backend and workers.
# ${APP_HOST}, ${FROM_EMAIL} and ${ALERT_EMAIL} are filled in by Flux from
# clusters/production/cluster-settings.yaml.
# Secret values (keys, passwords, DATABASE_URL) are NOT here: they come from the sealed secret.

# --- web ---
# "localhost" is also allowed so the Kubernetes health checks (which call the pod directly) pass.
DJANGO_ALLOWED_HOSTS=${APP_HOST},localhost
CORS_ALLOWED_ORIGINS=https://${APP_HOST}
CSRF_TRUSTED_ORIGINS=https://${APP_HOST}
FRONTEND_BASE_URL=https://${APP_HOST}
DJANGO_SECURE_SSL_REDIRECT=true
# Migrations run in a dedicated init step before each release (see backend.yaml), not on every boot.
RUN_MIGRATIONS_ON_BOOT=false

# --- email ---
DEFAULT_FROM_EMAIL=${FROM_EMAIL}
ALERT_EMAIL=${ALERT_EMAIL}
```

**`apps/myapp/backend.yaml`**: the API.

```yaml
# The API (gunicorn, port 8000).
#
# Before each new version starts serving, an init step applies any database migrations. With one
# backend pod this is race-free; if you ever scale to several, keep migrations in a Job instead.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: myapp
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0 # start the new pod first, so a deploy never takes the API down
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: migrate
          image: your-dockerhub-user/myapp-backend
          command: ["python", "manage.py", "migrate", "--noinput"]   # DEVELOPERS
          envFrom:
            - configMapRef:
                name: myapp-config
            - secretRef:
                name: myapp-secrets
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
      containers:
        - name: backend
          image: your-dockerhub-user/myapp-backend
          ports:
            - name: http
              containerPort: 8000
          envFrom:
            - configMapRef:
                name: myapp-config
            - secretRef:
                name: myapp-secrets
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          # The app only answers for its real hostname and redirects plain http, so the health
          # checks present themselves as a trusted local https request.
          readinessProbe:
            httpGet:
              path: /api/v1/health/        # DEVELOPERS give you this address
              port: http
              httpHeaders:
                - name: Host
                  value: localhost
                - name: X-Forwarded-Proto
                  value: https
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          # Liveness only checks the process is up (not the database), so a database hiccup
          # cannot trigger a restart loop.
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 20
            periodSeconds: 20
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 768Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: myapp
spec:
  selector:
    app: backend
  ports:
    - name: http
      port: 8000
      targetPort: http
```

🗣️ *"Three details worth explaining: (1) `maxUnavailable: 0` means the new version starts **before** the old
one stops, so no downtime. (2) The **readiness probe** is the health check: Kubernetes only sends visitors to
a pod once it answers. (3) The health check sends a `Host` header because the app refuses addresses it does not
know. Without it the pod never turns ready."*

**`apps/myapp/workers.yaml`**: the background job runner. **Exactly one copy, always.**

```yaml
# The background worker (sends emails, closes things on time, and so on).
#
# EXACTLY ONE at a time, on purpose. Two workers could do the same job twice (for example send the
# same payment twice). That is why this is `replicas: 1` with `strategy: Recreate` (the old pod
# stops before the new one starts), and why it must never be scaled up.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workers
  namespace: myapp
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: workers
  template:
    metadata:
      labels:
        app: workers
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        # Wait until the backend has applied this release's migrations, so a worker never runs
        # new code against an old database. `migrate --check` exits non-zero while any are pending.
        - name: wait-for-migrations
          image: your-dockerhub-user/myapp-backend
          command:   # DEVELOPERS
            - sh
            - -c
            - until python manage.py migrate --check >/dev/null 2>&1; do echo "waiting for migrations"; sleep 5; done
          envFrom:
            - configMapRef:
                name: myapp-config
            - secretRef:
                name: myapp-secrets
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 20m
              memory: 96Mi
            limits:
              memory: 384Mi
      containers:
        - name: workers
          image: your-dockerhub-user/myapp-backend
          command: ["python", "manage.py", "run_workers"]   # DEVELOPERS
          envFrom:
            - configMapRef:
                name: myapp-config
            - secretRef:
                name: myapp-secrets
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 192Mi
            limits:
              memory: 512Mi
```

**`apps/myapp/frontend.yaml`**: the website (static files served by nginx).

```yaml
# The website, served by nginx (port 8080). It is built so the API is at the same address ("/api"),
# so no frontend setting needs to change between environments.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: myapp
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: your-dockerhub-user/myapp-frontend
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /healthz         # DEVELOPERS give you this address
              port: http
            initialDelaySeconds: 2
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: myapp
spec:
  selector:
    app: frontend
  ports:
    - name: http
      port: 80
      targetPort: http
```

**`apps/myapp/ingress.yaml`**: the routing rule and the certificate request.

```yaml
# How the outside world reaches the app: one hostname (${APP_HOST}), routed by path.
#   /api, /admin, /static  -> backend
#   everything else        -> frontend
#
# The NGINX Ingress Controller redirects HTTP to HTTPS by itself for any Ingress that has a `tls:`
# block, and lets Let's Encrypt's HTTP challenge through, so no separate redirect object is needed.
# `http01-edit-in-place` is REQUIRED with this controller: cert-manager then puts the challenge on
# this Ingress instead of creating a separate one (which the controller would not serve).
#
# CERTIFICATES: it starts on Let's Encrypt STAGING (browsers show a warning, but a wrong setup cannot
# hit the real rate limits). Once https://${APP_HOST} works, change `letsencrypt-staging` to
# `letsencrypt-prod` below and follow Part 8.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
    acme.cert-manager.io/http01-edit-in-place: "true"
    nginx.org/ssl-redirect: "true"
    nginx.org/client-max-body-size: 10m
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${APP_HOST}
      secretName: myapp-tls
  rules:
    - host: ${APP_HOST}
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: backend
                port:
                  number: 8000
          - path: /admin
            pathType: Prefix
            backend:
              service:
                name: backend
                port:
                  number: 8000
          - path: /static
            pathType: Prefix
            backend:
              service:
                name: backend
                port:
                  number: 8000
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

🗣️ *"Two annotations are easy to get wrong with this controller. They start with `nginx.org/`, not
`nginx.ingress.kubernetes.io/` (that is the other ingress). And `http01-edit-in-place` must be there or the
certificate never completes."*

### 4.10 The helper scripts for secrets

Both run on the **laptop**. You will use them in Part 7; create them now so the repo is complete.

**`scripts/generate-secrets.sh`**: makes random passwords and keys, and a template for the third-party keys.

```bash
#!/usr/bin/env bash
# Run on YOUR LAPTOP from the repo root:  ./scripts/generate-secrets.sh
#
# Creates secrets-local/*.env with fresh random values (database passwords, app secret key, hash
# pepper, encryption key) and the database connection string. You then paste in the third-party keys
# by hand.
#
# secrets-local/ is git-ignored: these plain files NEVER go to GitHub. Only their ENCRYPTED versions
# (made by ./scripts/seal-all.sh) are committed.
#
# IMPORTANT: back up secrets-local/ in a password manager. Keys that protect stored data must stay the
# same for the life of the data. The script refuses to overwrite existing files.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="secrets-local"
mkdir -p "$OUT"
umask 077

if [ -e "$OUT/myapp.env" ] || [ -e "$OUT/postgres.env" ]; then
  echo "secrets-local/ already has files. Refusing to overwrite them (that could break live data)." >&2
  echo "If you really want fresh ones, move the old folder away first." >&2
  exit 1
fi

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

rand_hex() { openssl rand -hex "$1"; }
rand_key() { openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-64; }
# A Fernet key: 32 random bytes, URL-safe base64 (only if the developers ask for one).
rand_fernet() { openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n'; }

PG_ADMIN="$(rand_hex 16)"
PG_MYAPP="$(rand_hex 16)"
HOST="postgres.platform.svc.cluster.local:5432"

cat > "$OUT/postgres.env" <<EOF
POSTGRES_PASSWORD=$PG_ADMIN
MYAPP_DB_PASSWORD=$PG_MYAPP
EOF

# The NAMES on the left come from the developers (their list of required secrets).
cat > "$OUT/myapp.env" <<EOF
DJANGO_SECRET_KEY=$(rand_key)
HASH_PEPPER=$(rand_hex 32)
PIN_ENCRYPTION_KEY=$(rand_fernet)
DATABASE_URL=postgres://myapp:$PG_MYAPP@$HOST/myapp
THIRD_PARTY_API_KEY=PASTE_THE_REAL_KEY_FROM_THE_DEVELOPERS
EOF

echo "Created:"
ls -1 "$OUT"
echo
echo "Next:"
echo "  1. Open $OUT/myapp.env and replace every PASTE_... value with the real value."
echo "  2. Back up the whole $OUT folder in your password manager."
echo "  3. Run ./scripts/seal-all.sh"
```

**`scripts/seal-all.sh`**: locks the files in `secrets-local/` into sealed files that are safe to commit.

```bash
#!/usr/bin/env bash
# Run on YOUR LAPTOP, from the repo root:  ./scripts/seal-all.sh
#
# Encrypts the files in secrets-local/ into "sealed" Kubernetes secrets that are safe to commit.
# Only the cluster's controller can decrypt them (they are bound to a name and namespace).
#
# Needs: kubectl and kubeseal on PATH, secrets/pub-cert.pem (the cluster's PUBLIC certificate, Part 7),
# and secrets-local/*.env with no PASTE_ values left.
set -euo pipefail

cd "$(dirname "$0")/.."
CERT="secrets/pub-cert.pem"

command -v kubectl >/dev/null || { echo "kubectl not found on PATH" >&2; exit 1; }
command -v kubeseal >/dev/null || { echo "kubeseal not found on PATH" >&2; exit 1; }
[ -f "$CERT" ] || { echo "Missing $CERT. Fetch it from the server first (Part 7)." >&2; exit 1; }

for f in postgres myapp; do
  [ -f "secrets-local/$f.env" ] || { echo "Missing secrets-local/$f.env. Run ./scripts/generate-secrets.sh first." >&2; exit 1; }
done
if grep -n 'PASTE_' secrets-local/*.env; then
  echo "Replace the PASTE_... values above with the real values, then run this again." >&2
  exit 1
fi

seal() { # name namespace env-file output-file
  local name="$1" namespace="$2" envfile="$3" out="$4"
  mkdir -p "$(dirname "$out")"
  kubectl create secret generic "$name" \
    --namespace "$namespace" \
    --from-env-file="$envfile" \
    --dry-run=client -o yaml \
    | kubeseal --cert "$CERT" --format yaml > "$out"
  echo "sealed -> $out"
}

seal postgres-credentials platform secrets-local/postgres.env data/secrets/postgres-credentials.sealed.yaml
seal myapp-secrets myapp secrets-local/myapp.env apps/myapp/secrets/myapp-secrets.sealed.yaml

echo
echo "Done. Commit and push these files:"
echo "  git add data/secrets apps/myapp/secrets secrets/pub-cert.pem"
echo "  git commit -m 'Add sealed secrets' && git push"
```

**`scripts/check-placeholders.sh`**: fails if any placeholder value is still in the files Flux reads.

```bash
#!/usr/bin/env bash
# Fails if any placeholder value is still in the files Flux applies. Run before you push, and before
# the first deploy.   ./scripts/check-placeholders.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -rnE 'example\.com|your-dockerhub-user|CHANGE_ME' clusters apps data infrastructure \
     --include='*.yaml' --include='*.yml' --include='*.env'; then
  echo
  echo "The lines above still need a real value." >&2
  exit 1
fi
echo "No placeholders left."
```

Make them runnable **[LAPTOP]**:

```bash
chmod +x scripts/*.sh
```

### 4.11 Replace the placeholders, check, and push **[LAPTOP]**

Replace these placeholders everywhere they appear (your editor's "Find in Files" is handy):

| Placeholder | Replace with | Appears in |
|---|---|---|
| `app.example.com`, `you@example.com`, `no-reply@example.com` | your real address and emails | `cluster-settings.yaml` |
| `your-dockerhub-user` | your Docker Hub username | `apps/myapp/kustomization.yaml` (twice), `backend.yaml` (twice), `workers.yaml` (twice), `frontend.yaml` |

```bash
./scripts/check-placeholders.sh
```
**Check ✅** it prints `No placeholders left.` If it lists lines, fix them and run it again.

Optional but recommended: the safety net in [Appendix B](#appendix-b-optional-safety-net-validate-before-you-push)
catches typos in the YAML before you push.

Commit and push:

```bash
git add -A
git commit -m "Initial deploy repo"
git push
```

**Check ✅** **[GITHUB]**: the repo shows the folders `apps`, `clusters`, `data`, `infrastructure`, `scripts`.
(If you set up Appendix B, the "Validate manifests" workflow is green.)

---

## Part 5. CI: the developers' repo builds images

🗣️ *"CI is the factory. Every time a developer pushes, it runs their tests, packs the app into images, uploads
them, and writes the new version number into the deploy repo. You write this pipeline file once; the developers
own the test commands inside it."*

This part happens in the **app repo** (the developers' code repo), **not** the deploy repo. Agree with the
developers who may merge into their `main` branch.

### 5.1 What the developers must give you (the "container contract")

Before building a pipeline, get these answers in writing. They are the same for every app:

| Question | Our example answer |
|---|---|
| Which folders hold a deployable app, and does each have a `Dockerfile`? | `backend/` and `frontend/`, each with a `Dockerfile` |
| What commands run the tests? | backend: `pytest` (needs Postgres); frontend: `npm run lint` and `npm run test` |
| Which port does each container listen on? | backend `8000`, frontend `8080` |
| What is each health-check address? | backend `/api/v1/health/`, frontend `/healthz` |
| Does the app run as a normal (non-root) user with a **numeric** user id? | yes, id `1000` for the backend |
| Which settings are secret and which are not? (a list of names) | See `config.env` and `generate-secrets.sh` |
| Are there one-time commands (migrations, starter data) and background jobs? | migrations in an init step; one worker |

### 5.2 Docker Hub **[DOCKER HUB]**

1. **Repositories** → **Create repository** twice: `myapp-backend` and `myapp-frontend`, both **Public**.
2. Avatar → **Account settings** → **Personal access tokens** → **Generate new token**: description
   `ci`, permissions **Read & Write**. **Copy it once and keep it in the password manager.**

### 5.3 A token that lets CI edit the deploy repo **[GITHUB]**

🗣️ *"CI needs to write one line into the deploy repo. We give it a key that can do **only that**: one repository,
contents only."*

1. Avatar → **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens** →
   **Generate new token**.
2. Name `myapp-ci-deploy`. **Expiration:** pick a date and **put a reminder in your calendar a week before it**.
   When a token expires, CI silently stops updating the deploy repo.
3. **Repository access:** *Only select repositories* → `myapp-deploy`.
4. **Permissions** → **Repository permissions** → **Contents: Read and write**.
5. **Generate token**. Copy it once into the password manager.

### 5.4 Give the secrets to the app repo **[GITHUB]**

In the **app repo** → **Settings** → **Secrets and variables** → **Actions**.

On the **Secrets** tab → **New repository secret** (three times):

| Name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | your Docker Hub username |
| `DOCKERHUB_TOKEN` | the Docker Hub token from 5.2 |
| `DEPLOY_REPO_TOKEN` | the fine-grained token from 5.3 |

On the **Variables** tab → **New repository variable**:

| Name | Value |
|---|---|
| `DEPLOY_REPO` | `your-github-user/myapp-deploy` |

### 5.5 The pipeline file **[LAPTOP]** in the app repo

Clone the app repo next to the deploy repo (`cd ~/work && git clone git@github.com:your-github-user/APP-REPO.git`),
create a branch, and add **`.github/workflows/ci-cd.yml`**:

```yaml
name: CI/CD

# On every push to main: test -> build images -> push to Docker Hub -> tell the deploy repo the new
# image tag. Flux inside the cluster sees that commit and rolls out. Pull requests only run tests.
#
# Needed in this repo (Settings > Secrets and variables > Actions):
#   secrets:  DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, DEPLOY_REPO_TOKEN
#   variable: DEPLOY_REPO   e.g.  your-github-user/myapp-deploy
#
# Editing this file also rebuilds BOTH images (it is in both path filters below). Use that when you
# need to force a fresh build without changing application code.

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

env:
  DOCKERHUB_NAMESPACE: your-dockerhub-user

concurrency:
  group: ci-cd-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  # Which parts changed? Only those are tested and built.
  changes:
    runs-on: ubuntu-latest
    outputs:
      backend: ${{ steps.filter.outputs.backend }}
      frontend: ${{ steps.filter.outputs.frontend }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            backend:
              - 'backend/**'
              - '.github/workflows/ci-cd.yml'
            frontend:
              - 'frontend/**'
              - '.github/workflows/ci-cd.yml'

  # ---- DEVELOPERS OWN THE TEST JOBS (commands, versions, services) -------------------------------
  backend-test:
    needs: changes
    if: needs.changes.outputs.backend == 'true'
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: ci
          POSTGRES_PASSWORD: ci
          POSTGRES_DB: event_quiz_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U ci"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
    env:
      TEST_DB_NAME: event_quiz_test
      TEST_DB_USER: ci
      TEST_DB_PASSWORD: ci
      TEST_DB_HOST: 127.0.0.1
      TEST_DB_PORT: "5432"
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
          cache-dependency-path: backend/requirements/dev.txt
      - run: pip install -r requirements/dev.txt
      - run: pytest

  frontend-test:
    needs: changes
    if: needs.changes.outputs.frontend == 'true'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
          cache-dependency-path: frontend/package-lock.json
      - run: npm ci
      - run: npm run lint
      - run: npm run test
  # ---- END OF DEVELOPER-OWNED JOBS --------------------------------------------------------------

  # A build only runs if its tests passed. A red test means nothing is built or deployed.
  build-backend:
    needs: [changes, backend-test]
    if: github.event_name != 'pull_request' && needs.changes.outputs.backend == 'true' && needs.backend-test.result == 'success'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/setup-buildx-action@v3
      - name: Short SHA
        id: sha
        run: echo "short=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - uses: docker/build-push-action@v6
        with:
          context: backend
          push: true
          tags: |
            ${{ env.DOCKERHUB_NAMESPACE }}/myapp-backend:${{ steps.sha.outputs.short }}
            ${{ env.DOCKERHUB_NAMESPACE }}/myapp-backend:latest
          cache-from: type=gha,scope=backend
          cache-to: type=gha,mode=max,scope=backend

  build-frontend:
    needs: [changes, frontend-test]
    if: github.event_name != 'pull_request' && needs.changes.outputs.frontend == 'true' && needs.frontend-test.result == 'success'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/setup-buildx-action@v3
      - name: Short SHA
        id: sha
        run: echo "short=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - uses: docker/build-push-action@v6
        with:
          context: frontend
          push: true
          tags: |
            ${{ env.DOCKERHUB_NAMESPACE }}/myapp-frontend:${{ steps.sha.outputs.short }}
            ${{ env.DOCKERHUB_NAMESPACE }}/myapp-frontend:latest
          cache-from: type=gha,scope=frontend
          cache-to: type=gha,mode=max,scope=frontend

  # Runs only when at least one image was built and nothing failed. Edits the image tags in the
  # deploy repo; Flux does the rest.
  update-deploy-repo:
    needs: [build-backend, build-frontend]
    if: >-
      always() && github.event_name != 'pull_request' &&
      !contains(needs.*.result, 'failure') && !contains(needs.*.result, 'cancelled') &&
      (needs.build-backend.result == 'success' || needs.build-frontend.result == 'success')
    runs-on: ubuntu-latest
    concurrency:
      group: update-deploy-repo
      cancel-in-progress: false
    steps:
      - name: Check the deploy settings exist
        env:
          DEPLOY_REPO: ${{ vars.DEPLOY_REPO }}
          TOKEN: ${{ secrets.DEPLOY_REPO_TOKEN }}
        run: |
          [ -n "$DEPLOY_REPO" ] || { echo "Repository variable DEPLOY_REPO is not set"; exit 1; }
          [ -n "$TOKEN" ] || { echo "Secret DEPLOY_REPO_TOKEN is not set"; exit 1; }

      - uses: actions/checkout@v4
        with:
          repository: ${{ vars.DEPLOY_REPO }}
          token: ${{ secrets.DEPLOY_REPO_TOKEN }}
          path: deploy

      - name: Set the new image tags
        working-directory: deploy
        env:
          BACKEND_BUILT: ${{ needs.build-backend.result == 'success' }}
          FRONTEND_BUILT: ${{ needs.build-frontend.result == 'success' }}
        run: |
          TAG="${GITHUB_SHA::7}"
          FILE=apps/myapp/kustomization.yaml
          if [ "$BACKEND_BUILT" = "true" ]; then
            yq -i "(.images[] | select(.name == \"${DOCKERHUB_NAMESPACE}/myapp-backend\") | .newTag) = \"${TAG}\"" "$FILE"
          fi
          if [ "$FRONTEND_BUILT" = "true" ]; then
            yq -i "(.images[] | select(.name == \"${DOCKERHUB_NAMESPACE}/myapp-frontend\") | .newTag) = \"${TAG}\"" "$FILE"
          fi
          git diff -- "$FILE"

      - name: Commit and push (retry if the deploy repo moved)
        working-directory: deploy
        run: |
          if git diff --quiet; then
            echo "Nothing to change."
            exit 0
          fi
          git config user.name "myapp-ci"
          git config user.email "myapp-ci@users.noreply.github.com"
          git commit -am "myapp: deploy ${GITHUB_SHA::7}" -m "From ${GITHUB_REPOSITORY}@${GITHUB_SHA}"
          for attempt in 1 2 3 4 5; do
            if git push; then
              exit 0
            fi
            echo "Push rejected (attempt $attempt), rebasing and retrying"
            git pull --rebase
            sleep $((attempt * 3))
          done
          echo "Could not push to the deploy repo" >&2
          exit 1
```

🗣️ *"Read the file in four blocks: **changes** (what changed?), **tests** (the developers' part), **build**
(make and upload the image, tagged with the commit id), **update-deploy-repo** (write that id into the deploy
repo). The last block is the bridge between CI and CD."*

Edit the three places that contain `your-dockerhub-user` / `myapp` names so they match your real names.

### 5.6 Run it once and check **[GITHUB]**

Merge the file into `main` (or push it, if the developers allow). Then in the **app repo** → **Actions** →
the **CI/CD** run.

**Check ✅**
- All jobs go green (the test jobs may take several minutes the first time).
- **[DOCKER HUB]** both repos now show a tag that is 7 characters long (like `3fa9c1e`) and `latest`.
- **[GITHUB]** in the **deploy repo** there is a new commit by `myapp-ci` named `myapp: deploy 3fa9c1e`, and
  `apps/myapp/kustomization.yaml` shows the real tag instead of `placeholder`.

Bring that commit down to the laptop **[LAPTOP]**:

```bash
cd ~/work/myapp-deploy
git pull
```

> **If a test fails:** that is a developer problem. Send them the failing job's log link. Nothing is built or
> deployed from a red build; that is the safety net working.

---

## Part 6. The server: k3s and Flux

Now the server. Everything in this part is run **on the server over SSH**, except where marked.

### 6.1 Create the server scripts **[LAPTOP]**

Put these five files in the deploy repo under `scripts/on-server/` (they live in git so the next person can
reuse them). Each is run once, in order.

**`scripts/on-server/01-prepare-os.sh`**: updates the operating system and makes SSH safer.

```bash
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
cat > /etc/ssh/sshd_config.d/99-myapp-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
# Only reload if the configuration is valid, so a typo can never lock you out.
if sshd -t; then
  systemctl reload ssh || systemctl reload sshd
else
  echo "sshd config check failed; removing the hardening file" >&2
  rm -f /etc/ssh/sshd_config.d/99-myapp-hardening.conf
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
```

**`scripts/on-server/02-install-k3s.sh`**: installs k3s. **The `--disable traefik` line is essential.**

```bash
#!/usr/bin/env bash
# Step 2 on the server: install k3s (a small, production-grade Kubernetes) as a single node.
# Run as your normal user (it uses sudo where needed):  bash 02-install-k3s.sh
#
# What this keeps on purpose (the defaults):
#   - ServiceLB exposes ports 80/443 directly on this server
#   - local-path storage for the Postgres disk
# Turned off on purpose: k3s's built-in Traefik (--disable traefik). The ingress controller is the
# F5 NGINX Ingress Controller, installed by Flux. If Traefik stays on, it keeps ports 80/443 and
# NGINX can never receive traffic.
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
  --node-name myapp-prod

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
```

**`scripts/on-server/03-install-flux-cli.sh`**: installs the Flux command-line tool.

```bash
#!/usr/bin/env bash
# Step 3 on the server: install the Flux command-line tool (used once, to connect the cluster to
# your deploy repository, and later to check status).
# Run as your normal user:  bash 03-install-flux-cli.sh
set -euo pipefail

echo "==> Installing the Flux CLI"
curl -s https://fluxcd.io/install.sh | sudo bash

flux --version
echo
echo "Next, create a GitHub token for Flux, then run step 4."
```

**`scripts/on-server/04-bootstrap-flux.sh`**: connects the cluster to the deploy repo.

```bash
#!/usr/bin/env bash
# Step 4 on the server: connect the cluster to your deploy repository with Flux.
#
# From now on, the cluster watches the repo and applies whatever is committed to main. Flux also
# commits its own wiring into clusters/production/flux-system/ (so remember to `git pull` after).
#
# Needs two environment variables (your GitHub token is NOT stored anywhere by this script):
#   export GITHUB_TOKEN=<classic token with the "repo" scope>
#   export GITHUB_OWNER=<your GitHub username, or the organisation that owns the repo>
# Optional:
#   export GITHUB_REPO=myapp-deploy
#   export GITHUB_PERSONAL=true      # true if the repo is under a personal account (default),
#                                    # false if it belongs to an organisation
set -euo pipefail

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN first (see the header of this script)}"
: "${GITHUB_OWNER:?Set GITHUB_OWNER first (see the header of this script)}"
GITHUB_REPO="${GITHUB_REPO:-myapp-deploy}"
GITHUB_PERSONAL="${GITHUB_PERSONAL:-true}"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> Checking the cluster is ready for Flux"
flux check --pre

args=(
  --owner="$GITHUB_OWNER"
  --repository="$GITHUB_REPO"
  --branch=main
  --path=clusters/production
)
if [ "$GITHUB_PERSONAL" = "true" ]; then
  args+=(--personal)
fi

echo "==> Bootstrapping Flux against $GITHUB_OWNER/$GITHUB_REPO"
flux bootstrap github "${args[@]}"

echo
echo "Flux is installed. Watch it work with:   flux get kustomizations --watch"
echo "On a brand-new cluster, 'data' and 'apps' will say they cannot build until you add the"
echo "sealed secrets (Part 7). That is expected."
```

**`scripts/on-server/05-fetch-seal-cert.sh`**: gets the public padlock and backs up the private key.

```bash
#!/usr/bin/env bash
# Step 5 on the server: get the cluster's PUBLIC sealing certificate (so you can encrypt secrets on
# your laptop), and take a one-time backup of the PRIVATE key (so you can rebuild the cluster later).
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

Now copy BOTH files to your laptop (run this on your laptop, not here):

  scp -i ~/.ssh/myapp-key.pem ubuntu@${SERVER_IP}:pub-cert.pem                    secrets/pub-cert.pem
  scp -i ~/.ssh/myapp-key.pem ubuntu@${SERVER_IP}:sealed-secrets-key-backup.yaml  ~/safe/

Store sealed-secrets-key-backup.yaml somewhere safe and OFFLINE, never in git.
Then delete it from the server:   shred -u ~/sealed-secrets-key-backup.yaml
EOF
```

Commit them **[LAPTOP]**:

```bash
cd ~/work/myapp-deploy
chmod +x scripts/on-server/*.sh
git add -A && git commit -m "Add server scripts" && git push
```

### 6.2 Copy the scripts up and prepare the server **[LAPTOP]** then **[SERVER]**

```bash
scp -i ~/.ssh/myapp-key.pem -r scripts/on-server ubuntu@SERVER_IP:
ssh -i ~/.ssh/myapp-key.pem ubuntu@SERVER_IP
```

Now the prompt is `ubuntu@ip-...` so you are on the **server**:

```bash
sudo bash on-server/01-prepare-os.sh
```
If it says a reboot is needed: `sudo reboot`, wait one minute, and `ssh` back in the same way.

**Check ✅** the script ended with "Done. Continue with step 2" (or the reboot message).

### 6.3 Install k3s **[SERVER]**

🗣️ *"We install Kubernetes with one command, and we **turn off Traefik**, k3s's built-in front door, because
we use NGINX. If we forget, Traefik holds ports 80 and 443 and NGINX never gets any traffic."*

```bash
bash on-server/02-install-k3s.sh
```

**Check ✅**

```bash
kubectl get nodes
kubectl -n kube-system get pods
```
- `kubectl get nodes` shows **one** node, `myapp-prod`, status **Ready**.
- The second command lists pods like `coredns` and `local-path-provisioner` and **no pod with `traefik` in its name**.
  If you see `traefik`, stop: the `--disable traefik` line did not apply (see [Part 11](#part-11-troubleshooting-table)).

### 6.4 Install the Flux tool **[SERVER]**

```bash
bash on-server/03-install-flux-cli.sh
```
**Check ✅** it prints a Flux version.

### 6.5 Connect the cluster to the repo (Flux bootstrap)

🗣️ *"This is the moment the server is told: 'from now on, obey this repository'. We give Flux a temporary
GitHub token once, so it can install itself and create its own read-only key. After that the token is not
needed."*

**[GITHUB]** create a **classic** token: avatar → **Settings** → **Developer settings** → **Personal access
tokens** → **Tokens (classic)** → **Generate new token (classic)** → note `flux-bootstrap`, expiration 7 days,
tick the **`repo`** scope → **Generate**. Keep the page open until you have pasted it.

**[SERVER]** type the token **without it showing on screen or being saved in history**, and test it before using it:

```bash
read -rs GITHUB_TOKEN; export GITHUB_TOKEN
export GITHUB_OWNER=your-github-user
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user
```
(After `read -rs`, paste the token and press **Enter**. Nothing appears; that is normal.)

**Check ✅** the `curl` line prints **`200`**. If it prints `401` the token was pasted wrongly or has expired:
create a new one and repeat. Do **not** continue on a 401.

```bash
bash on-server/04-bootstrap-flux.sh
unset GITHUB_TOKEN
```

**Check ✅** the output ends with lines like `✔ all components are healthy`.

**[GITHUB]** you can now **delete** the `flux-bootstrap` token: Flux keeps using its own read-only deploy key.

Flux just committed its own files into the repo. Bring them down **[LAPTOP]**:

```bash
cd ~/work/myapp-deploy
git pull
ls clusters/production/flux-system
```
**Check ✅** you see `gotk-components.yaml`, `gotk-sync.yaml` and `kustomization.yaml`. (If you forget to
`git pull` before your next push, git will complain; just pull and push again.)

### 6.6 Watch the cluster come up **[SERVER]**

```bash
flux get kustomizations --watch
```
Press **Ctrl+C** to stop watching. Give it 5 to 10 minutes. This is the expected result on a fresh cluster:

| Kustomization | Expected now | Why |
|---|---|---|
| `flux-system` | **True** | Flux itself |
| `infrastructure` | **True** (after a few minutes) | cert-manager, sealed-secrets and NGINX installed |
| `infrastructure-config` | **True** | the Let's Encrypt issuers |
| `data` | **False**, message about `secrets/postgres-credentials.sealed.yaml` | **Expected.** The sealed secret does not exist yet (Part 7). |
| `apps` | **False**, "dependency 'flux-system/data' is not ready" | **Expected.** Same reason. |

Then check the helper programs and the front door:

```bash
flux get helmreleases -A
kubectl get pods -A
kubectl -n nginx-ingress get svc
```
**Check ✅**
- Every helm release shows **True** (cert-manager, sealed-secrets, nginx-ingress).
- Pods in `cert-manager`, `nginx-ingress` and `kube-system` (the `sealed-secrets-controller`) are **Running**.
- The `nginx-ingress` service shows an **EXTERNAL-IP** (an address, not `<pending>`). If it is `<pending>`, Traefik
  is probably still holding the ports (Part 11).

From the laptop, test that the front door answers **[LAPTOP]**:

```bash
curl -I http://app.example.com
```
**Check ✅** you get `HTTP/1.1 404 Not Found` with `Server: nginx`. A 404 is **good news** here: it means
traffic reached NGINX, which simply has no website to show yet.

---

## Part 7. Secrets: lock them on the laptop, open them on the server

🗣️ *"The app needs passwords and keys. We never put those in git as text. We lock them with the cluster's
public padlock on the laptop, commit the locked files, and only the cluster can open them."*

### 7.1 Get the padlock and back up the private key **[SERVER]** then **[LAPTOP]**

**[SERVER]**

```bash
bash on-server/05-fetch-seal-cert.sh
```
It ends by printing two `scp` commands. Run them **on the laptop** (from inside the deploy repo folder):

**[LAPTOP]**

```bash
cd ~/work/myapp-deploy
scp -i ~/.ssh/myapp-key.pem ubuntu@SERVER_IP:pub-cert.pem                    secrets/pub-cert.pem
scp -i ~/.ssh/myapp-key.pem ubuntu@SERVER_IP:sealed-secrets-key-backup.yaml  ~/safe/
```

Now the most important safety step:

1. Put **`~/safe/sealed-secrets-key-backup.yaml`** into the **password manager** (as an attached file or a
   secure note) and onto an offline copy (a USB stick).
2. Then delete it from the server **[SERVER]**: `shred -u ~/sealed-secrets-key-backup.yaml`

🗣️ *"This file is the master key. If the server is destroyed and we do not have it, we cannot open the sealed
files and must regenerate every secret. If a stranger gets it, they can read everything. Offline, in the
password manager, never in git."*

**Check ✅** `secrets/pub-cert.pem` exists in the repo folder, and `ls ~/safe` shows the backup.

### 7.2 Generate the secrets **[LAPTOP]**

```bash
./scripts/generate-secrets.sh
```
It creates `secrets-local/postgres.env` and `secrets-local/myapp.env` with random passwords and keys.

Open `secrets-local/myapp.env`. Replace every `PASTE_...` with the **real value the developers or the provider
give you** (for example a payment or email provider key). Do it inside the file only, never in chat or email.

Then **back up the whole `secrets-local/` folder in the password manager.**

> **Never regenerate a key that protects stored data** (in our example `HASH_PEPPER` and
> `PIN_ENCRYPTION_KEY`). Changing it later makes existing data unreadable. The script refuses to overwrite
> `secrets-local/` for this reason.

### 7.3 Lock them (seal) **[LAPTOP]**

```bash
./scripts/seal-all.sh
```
**Check ✅** it prints two `sealed -> ...` lines. Look inside one:

```bash
head -c 600 apps/myapp/secrets/myapp-secrets.sealed.yaml
```
You should see long gibberish starting with `Ag...`. That is the locked version, and it is safe in git.
`secrets-local/` is ignored by git; confirm with `git status` (it must **not** list `secrets-local`).

### 7.4 Commit, push, and watch it come alive **[LAPTOP]** then **[SERVER]**

```bash
git add data/secrets apps/myapp/secrets secrets/pub-cert.pem
git commit -m "Add sealed secrets"
git push
```

**[SERVER]**

```bash
flux get kustomizations --watch
```
Within a few minutes `data` becomes **True**, then `apps` becomes **True**. (Press Ctrl+C when they do.)

**Check ✅**

```bash
kubectl -n platform get pods
kubectl -n platform exec postgres-0 -- psql -U postgres -c '\l'
kubectl -n myapp get pods
```
- `postgres-0` is **1/1 Running**. The first start can take a minute or two (that is what the startup probe allows for).
- The database list includes **`myapp`**.
- `backend`, `workers` and `frontend` pods are **Running** (`1/1`). `backend` may briefly show `Init:0/1` while it
  applies the database migrations.
- If a pod says `ImagePullBackOff`, the image tag does not exist on Docker Hub: CI in Part 5 has not run yet (the
  tag is still `placeholder`).

---

## Part 8. First release and real HTTPS (staging, then production)

### 8.1 Is the app running? **[SERVER]**

```bash
kubectl -n myapp get pods
kubectl -n myapp logs deploy/backend -c migrate --tail=20
```
**Check ✅**
- `backend`, `workers` and `frontend` are `1/1 Running`.
- The `migrate` log (the database setup step) ends without errors. (This is the developers' command; an
  error here is theirs to fix. Send them the log.)

### 8.2 Is the certificate issued? (Let's Encrypt **staging**) **[SERVER]**

🗣️ *"The Ingress asks for a certificate from the **staging** Let's Encrypt first. cert-manager proves to Let's
Encrypt that we own the website name by placing a small file on the website, then Let's Encrypt signs. If
anything is wrong (DNS, ports, routing) it fails here, harmlessly."*

```bash
kubectl get certificate -A
```
Wait up to 3 minutes until **READY** shows **True** for `myapp-tls`. If it stays False:

```bash
kubectl -n myapp describe certificate myapp-tls
kubectl get challenges -A
```
and use [Part 11](#part-11-troubleshooting-table).

**Check ✅ from the laptop** that the website answers and the certificate is the **staging** one:

```bash
curl -k -I https://app.example.com
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null | openssl x509 -noout -issuer
```
- `curl` returns `HTTP/2 200` (or a redirect/200 from the app). `-k` means "ignore the certificate warning".
- The issuer line contains **`(STAGING)`**. A browser shows a "Not secure" warning page. That is **expected** here.

Open `https://app.example.com` in a browser, click through the warning, and confirm the website loads.

### 8.3 Switch to the real certificate (production) **[LAPTOP]** then **[SERVER]**

Only do this once 8.2 passed. 🗣️ *"Production Let's Encrypt has strict limits if you ask repeatedly and fail,
which is why we proved the wiring on staging first."*

**[LAPTOP]** In `apps/myapp/ingress.yaml` change one word:

```yaml
    cert-manager.io/cluster-issuer: letsencrypt-prod      # was: letsencrypt-staging
```

```bash
git add -A && git commit -m "Use production certificates" && git push
```

Wait about a minute for Flux to apply it. **[SERVER]** then delete the old certificate's secret so cert-manager
issues a fresh, trusted one:

```bash
kubectl -n myapp delete secret myapp-tls
kubectl -n myapp get certificate -w
```
(Ctrl+C when `READY` shows **True**; it usually takes under 2 minutes.)

🗣️ *"Changing the annotation alone does not make cert-manager replace a certificate that is already valid, so
we delete the stored certificate and it makes a new one from the production issuer. Do this **once**. Repeating
it over and over in production can hit Let's Encrypt's limits."*

**Check ✅ from the laptop**

```bash
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null | openssl x509 -noout -issuer
```
The issuer now says **`Let's Encrypt`** (not STAGING). Open `https://app.example.com` in a **private browser
window**: a normal padlock, no warning.

### 8.4 First-time application setup (ask the developers)

Some apps need one-time commands after the very first deploy (an admin user, starter data). The developers
give you the exact commands. In our example app:

```bash
# create the first administrator (it asks you for a name and password, typed on screen)
kubectl -n myapp exec -it deploy/backend -- python manage.py createsuperuser
```

> **Real-life lesson:** database migrations create empty tables, not starter content. Our example app showed
> no default questions until a "load starter data" command was run once. Always ask the developers: *"Does a
> brand-new database need any one-time starter data?"* and write the answer into your notes.

### 8.5 Prove the automatic delivery works end to end

This is the moment the whole system proves itself.

1. Ask a developer to make a **tiny visible change** (for example a line of text) and push it to `main`.
2. **[GITHUB]** watch the **Actions** run in the app repo go green.
3. **[GITHUB]** a new commit `myapp: deploy xxxxxxx` appears in the deploy repo.
4. **[SERVER]** within about a minute:

```bash
kubectl -n myapp get pods -w
```
A new `frontend` (or `backend`) pod appears, becomes `1/1 Running`, and the old one disappears. Reload the
website in a private window to see the change.

**Rolling back** (if a release is bad): in the deploy repo on the laptop, revert the bad deploy commit and push.

```bash
cd ~/work/myapp-deploy
git pull
git log --oneline -5            # find the "myapp: deploy ..." commit to undo
git revert <commit-id>
git push
```
Flux rolls the app back within a minute. (This does not undo database changes a release made; tell the
developers.)

---

## Part 9. Final health check

🗣️ *"Before we call it done, we prove every layer with a few read-only commands. If all of them look right, the
system is healthy."*

All on the **[SERVER]** unless marked.

| # | What | Command | You should see |
|---|---|---|---|
| 1 | Flux is happy | `flux get kustomizations` | every line **True** |
| 2 | The helper programs are installed | `flux get helmreleases -A` | cert-manager, sealed-secrets and nginx-ingress all **True** |
| 3 | Everything is running | `kubectl get pods -A` | no pod in `Error`, `CrashLoopBackOff` or `ImagePullBackOff` |
| 4 | The database exists | `kubectl -n platform exec postgres-0 -- psql -U postgres -c '\l'` | a database called `myapp` in the list |
| 5 | Certificates are real | `kubectl get certificate -A` | `myapp-tls` is **READY True** |
| 6 | The website is trusted **[LAPTOP]** | open `https://app.example.com` in a private window | a normal padlock, no warning |
| 7 | Releases are automatic | repeat Part 8.5 | a developer push becomes a new running pod with no manual command |

**Check ✅** all seven rows pass.

> **Reminder about data:** there is **no automatic database backup** in this setup. The server's disk holds the
> only copy of the data. If that ever matters, raise it with the owner before real users depend on the app.

---

## Part 10. Adding a new service when a developer says it is ready

🗣️ *"A new service is mostly copy-and-rename. The server already has everything shared: the front door, the
certificates and the database. A new service only needs its own folder, its own secrets, its own
website name and its own pipeline."*

This part uses a worked example: the developers announce a new service called **`shop`**. Substitute the real
name wherever you see `shop`.

### 10.1 The handoff: the developer's "definition of ready"

Do **not** start until the developer has given you every line of this checklist. Paste it into the ticket.

| # | You need from the developer | Example (`shop`) |
|---|---|---|
| 1 | Repo name and where its `Dockerfile` is | repo `shop-api`, `Dockerfile` at the repo root |
| 2 | The test commands CI should run | `npm ci` then `npm test` |
| 3 | The port the container listens on | `3000` |
| 4 | The health-check address (must answer `200` when ready) | `/health` |
| 5 | The website name they want | `shop.example.com` |
| 6 | **Non-secret** settings (names and values) | `PORT=3000`, `NODE_ENV=production`, `PUBLIC_URL=https://shop.example.com` |
| 7 | **Secret** settings (names only; you generate or receive the values safely) | `JWT_SECRET` (random), `DATABASE_URL` (you build it), `STRIPE_KEY` (from the provider) |
| 8 | Does it need a database? Which kind? | Yes, Postgres, database name `shop` |
| 9 | Must it run as exactly one copy? Does it have background jobs? | One copy is fine |
| 10 | One-time setup commands (migrations, starter data) | none |
| 11 | Does it run as a non-root user with a **numeric** id? | yes, id `1000` |
| 12 | Who to call when it breaks | name and chat handle |

If an answer is "I don't know", send it back. Guessing here is where trial and error comes from.

### 10.2 Order of work (so nothing breaks half-way)

```
1. DNS record  ->  2. website name in cluster-settings (push, verify)  ->  3. database
-> 4. secrets (seal)  ->  5. app folder + register it (push)
-> 6. CI in the developers' repo (first image)  ->  7. check, staging cert, production cert
```

### 10.3 Step 1: DNS **[NAMECHEAP]**

Add an **A record**: Host `shop`, Value `SERVER_IP`. Check from the laptop that `nslookup shop.example.com`
returns the server IP before continuing.

### 10.4 Step 2: add the website name to the shared settings **[LAPTOP]**

Edit `clusters/production/cluster-settings.yaml` and add one line:

```yaml
  # Where the shop service answers.
  SHOP_HOST: "shop.example.com"
```
Commit and push **this on its own, first**:

```bash
cd ~/work/myapp-deploy && git pull
git add -A && git commit -m "Add SHOP_HOST" && git push
```

**[SERVER]** make sure the value has arrived **before** the next push (the settings are re-applied every 10
minutes; this command just applies them now):

```bash
flux reconcile kustomization flux-system --with-source
kubectl -n flux-system get configmap cluster-settings -o jsonpath='{.data.SHOP_HOST}'; echo
```
**Check ✅** it prints `shop.example.com`.

🗣️ *"If the app files were applied before this value existed, `${SHOP_HOST}` would be replaced with nothing
and Kubernetes would create a broken website rule."*

### 10.5 Step 3: create the database and its login **[LAPTOP]**

🗣️ *"Each service gets its **own** database and its **own** login, so one service can never read another's
data. The database was created automatically for `myapp` at first start; for later services we create it by
hand, once."*

This one command block makes a random password, saves the app's secrets file (with the password inside the
connection string), and creates the database over SSH. The password never appears on screen or in your history.

```bash
cd ~/work/myapp-deploy
SHOP_PW="$(openssl rand -hex 16)"
umask 077
cat > secrets-local/shop.env <<EOF
JWT_SECRET=$(openssl rand -hex 32)
DATABASE_URL=postgres://shop:${SHOP_PW}@postgres.platform.svc.cluster.local:5432/shop
STRIPE_KEY=PASTE_THE_REAL_KEY_FROM_THE_DEVELOPERS
EOF
ssh -i ~/.ssh/myapp-key.pem ubuntu@SERVER_IP "kubectl -n platform exec -i postgres-0 -- psql -U postgres -v ON_ERROR_STOP=1" <<SQL
CREATE ROLE shop LOGIN PASSWORD '${SHOP_PW}';
CREATE DATABASE shop OWNER shop;
SQL
unset SHOP_PW
```
**Check ✅** the output shows `CREATE ROLE` and `CREATE DATABASE`.

Now open `secrets-local/shop.env` and replace the `PASTE_...` line with the real value (inside the file only).
Back the `secrets-local/` folder up in the password manager again.

### 10.6 Step 4: seal the new secret **[LAPTOP]**

Edit `scripts/seal-all.sh` in two places:

```bash
# 1) the list of required files:
for f in postgres myapp shop; do

# 2) after the existing two "seal ..." lines, add:
seal shop-secrets shop secrets-local/shop.env apps/shop/secrets/shop-secrets.sealed.yaml
```

Then:

```bash
./scripts/seal-all.sh
```
(It re-seals all three. That is fine: the content is the same, so nothing changes for the existing apps.)
**Check ✅** it prints `sealed -> apps/shop/secrets/shop-secrets.sealed.yaml`.

### 10.7 Step 5: the service's folder **[LAPTOP]**

```bash
mkdir -p apps/shop/secrets
```
(The sealed file from 10.6 is already inside `apps/shop/secrets/`.) Create these files.

**`apps/shop/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
```

**`apps/shop/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shop
resources:
  - namespace.yaml
  - deployment.yaml
  - ingress.yaml
  - secrets/shop-secrets.sealed.yaml
configMapGenerator:
  - name: shop-config
    envs:
      - config.env
# CI rewrites ONLY the newTag line below (to the git commit of each build).
images:
  - name: your-dockerhub-user/shop-api
    newTag: placeholder
```

**`apps/shop/config.env`** (the developer's **non-secret** list from checklist row 6)

```
# Non-secret settings. ${SHOP_HOST} is filled in by Flux from cluster-settings.yaml.
PORT=3000
NODE_ENV=production
PUBLIC_URL=https://${SHOP_HOST}
```

**`apps/shop/deployment.yaml`** (the app and its internal address)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
  namespace: shop
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: shop
  template:
    metadata:
      labels:
        app: shop
    spec:
      # Only keep these two lines if the developers confirm the image runs as numeric user 1000.
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: shop
          image: your-dockerhub-user/shop-api
          ports:
            - name: http
              containerPort: 3000          # checklist row 3
          envFrom:
            - configMapRef:
                name: shop-config
            - secretRef:
                name: shop-secrets
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /health                # checklist row 4
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: 20
            periodSeconds: 20
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: shop
  namespace: shop
spec:
  selector:
    app: shop
  ports:
    - name: http
      port: 80
      targetPort: http
```

**`apps/shop/ingress.yaml`** (starts on **staging**, as always)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: shop
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
    acme.cert-manager.io/http01-edit-in-place: "true"
    nginx.org/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${SHOP_HOST}
      secretName: shop-tls
  rules:
    - host: ${SHOP_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shop
                port:
                  number: 80
```

Now register the service. Edit **`apps/kustomization.yaml`**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - myapp
  - shop
```

Replace `your-dockerhub-user` in the new files, run the checks, and push:

```bash
./scripts/check-placeholders.sh
git add -A
git commit -m "Add the shop service"
git push
```

**[SERVER]** watch it appear:

```bash
kubectl -n shop get pods
```
The pod will show `ImagePullBackOff` or `ErrImagePull` until the first image exists. **That is expected here**
and fixes itself after the next step.

### 10.8 Step 6: the developers' pipeline for the new repo

🗣️ *"Same factory, smaller line. This repo makes one image."* Do exactly what Part 5.2 to 5.4 describes for
this repo:
- **[DOCKER HUB]** create the **public** repository `shop-api`.
- **[GITHUB]** in the `shop-api` repo add the secrets `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`,
  `DEPLOY_REPO_TOKEN` (the **same** values as the other repo; the token is already limited to the deploy repo)
  and the variable `DEPLOY_REPO` = `your-github-user/myapp-deploy`.

Add **`.github/workflows/ci-cd.yml`** to the `shop-api` repo:

```yaml
name: CI/CD

# On every push to main: test -> build image -> push to Docker Hub -> tell the deploy repo the new tag.
# Pull requests only run the tests.
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

env:
  DOCKERHUB_NAMESPACE: your-dockerhub-user
  IMAGE: shop-api

concurrency:
  group: ci-cd-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  # ---- DEVELOPERS OWN THIS JOB ----------------------------------------------------------------
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
      - run: npm ci
      - run: npm test
  # ---------------------------------------------------------------------------------------------

  build:
    needs: test
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/setup-buildx-action@v3
      - name: Short SHA
        id: sha
        run: echo "short=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ env.DOCKERHUB_NAMESPACE }}/${{ env.IMAGE }}:${{ steps.sha.outputs.short }}
            ${{ env.DOCKERHUB_NAMESPACE }}/${{ env.IMAGE }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  update-deploy-repo:
    needs: build
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    concurrency:
      group: update-deploy-repo
      cancel-in-progress: false
    steps:
      - name: Check the deploy settings exist
        env:
          DEPLOY_REPO: ${{ vars.DEPLOY_REPO }}
          TOKEN: ${{ secrets.DEPLOY_REPO_TOKEN }}
        run: |
          [ -n "$DEPLOY_REPO" ] || { echo "Repository variable DEPLOY_REPO is not set"; exit 1; }
          [ -n "$TOKEN" ] || { echo "Secret DEPLOY_REPO_TOKEN is not set"; exit 1; }

      - uses: actions/checkout@v4
        with:
          repository: ${{ vars.DEPLOY_REPO }}
          token: ${{ secrets.DEPLOY_REPO_TOKEN }}
          path: deploy

      - name: Set the new image tag
        working-directory: deploy
        run: |
          TAG="${GITHUB_SHA::7}"
          FILE=apps/shop/kustomization.yaml
          yq -i "(.images[] | select(.name == \"${DOCKERHUB_NAMESPACE}/${IMAGE}\") | .newTag) = \"${TAG}\"" "$FILE"
          git diff -- "$FILE"

      - name: Commit and push (retry if the deploy repo moved)
        working-directory: deploy
        run: |
          if git diff --quiet; then
            echo "Nothing to change."
            exit 0
          fi
          git config user.name "shop-ci"
          git config user.email "shop-ci@users.noreply.github.com"
          git commit -am "shop: deploy ${GITHUB_SHA::7}" -m "From ${GITHUB_REPOSITORY}@${GITHUB_SHA}"
          for attempt in 1 2 3 4 5; do
            if git push; then
              exit 0
            fi
            echo "Push rejected (attempt $attempt), rebasing and retrying"
            git pull --rebase
            sleep $((attempt * 3))
          done
          echo "Could not push to the deploy repo" >&2
          exit 1
```

Push it to `main`. **Check ✅** the run is green, the deploy repo gets a commit `shop: deploy xxxxxxx`, and
**[SERVER]** within about a minute `kubectl -n shop get pods` shows `shop` **1/1 Running**.

### 10.9 Step 7: certificates and the final check

**Staging first, then production.** This is exactly Part 8.2 and 8.3 for the new service:

**[SERVER]**

```bash
kubectl get certificate -A                      # shop-tls READY True (staging)
```
**[LAPTOP]** `curl -k -I https://shop.example.com` answers. Then change `apps/shop/ingress.yaml` to
`letsencrypt-prod`, commit, push, wait a minute, and **[SERVER]**:

```bash
kubectl -n shop delete secret shop-tls
kubectl -n shop get certificate -w
```
Check the issuer shows `Let's Encrypt` (not STAGING) and a private browser window shows the padlock.

### 10.10 Definition of done for any new service

- [ ] The developer's checklist (10.1) is fully answered and saved in the ticket.
- [ ] DNS name resolves to the server.
- [ ] Database and login created (10.5).
- [ ] Secrets sealed and committed; `secrets-local/` backed up in the password manager.
- [ ] Pod is `Running 1/1` and the website shows a **production** padlock.
- [ ] The developers' push produced a new deploy commit and a new pod (Part 8.5 repeated for this repo).
- [ ] A calendar reminder exists for the CI token expiry.

### 10.11 Other everyday changes

| I need to... | Do this |
|---|---|
| Change a normal setting | Edit `apps/<name>/config.env`, push. The app restarts by itself. |
| Add a second website name to an existing app | DNS A record, a new `*_HOST` line in `cluster-settings.yaml` (push first, verify), then add it under `tls:` and `rules:` in that app's `ingress.yaml`, and add the name to the app's allowed-hosts setting. |
| Change a secret | Edit `secrets-local/<name>.env`, run `./scripts/seal-all.sh`, commit, push, then restart: `kubectl -n <namespace> rollout restart deploy/<name>`. (Never change a key that protects stored data.) |
| Remove a service | Delete its line from `apps/kustomization.yaml` and push (Flux deletes it, because `prune` is on). The database stays. Remove the DNS record. Drop the database by hand only when you are sure. |
| Run a one-off command in an app | `kubectl -n <namespace> exec -it deploy/<name> -- <command the developers give you>` |

---

## Part 11. Troubleshooting table

These are the real problems met while building this system the first time. If you followed the guide, you
should not hit them, but here they are with the fix. Run the **Look at** command first; it tells you which row you are in.

| # | Symptom | Cause | Look at / Fix |
|---|---|---|---|
| 1 | `flux bootstrap` fails with **401** | GitHub token pasted wrongly, expired, or missing the `repo` scope | Re-run the `curl` test in 6.5. It must print `200` before you bootstrap. Create a new token if not. |
| 2 | `data` and `apps` are red: "no such file ... `.sealed.yaml`" | The sealed secrets are not committed yet | **Expected** on a fresh cluster. Do Part 7. |
| 3 | A HelmRelease says "no artifact available" or the chart cannot be found | The chart repository address is wrong or has moved | `kubectl describe helmrepository <name> -n <namespace>`, then `curl -I <the url>` from the server. The Sealed Secrets chart is at `https://bitnami.github.io/sealed-secrets` (the older `bitnami-labs.github.io` address returns 404). |
| 4 | The `nginx-ingress` service shows **EXTERNAL-IP `<pending>`**, or `kubectl get pods -A` shows a `traefik` pod | k3s was installed **without** `--disable traefik`, so Traefik holds ports 80/443 | **Look at:** `sudo ss -ltnp \| grep -E ':80\|:443'`. **Fix:** `sudo mkdir -p /etc/rancher/k3s && printf 'disable:\n  - traefik\n' \| sudo tee /etc/rancher/k3s/config.yaml && sudo systemctl restart k3s`, wait two minutes, check the Traefik pods are gone. |
| 5 | The Postgres pod restarts, or uses 100% CPU and never gets ready | Fixes missing from `data/postgres.yaml` (uid 70, startupProbe on 127.0.0.1, AppArmor off for this pod) | Compare your file with Part 4.8. Logs: `kubectl -n platform logs postgres-0`. The message `pg_ctl: could not send stop signal ... Permission denied` means AppArmor: `sudo dmesg \| grep DENIED`. |
| 6 | Postgres still stuck after you fixed the file | A half-finished data folder from the failed first start is skipped by the setup step | **Only if the database holds no real data yet:** `kubectl -n platform scale statefulset postgres --replicas=0`, then `kubectl -n platform delete pvc data-postgres-0`, then `flux reconcile kustomization data --with-source` (it recreates the pod and a clean disk). |
| 7 | New websites return **404**, or the NGINX controller logs say `nginx reload failed ... kill(...) failed (13: Permission denied)` | AppArmor on Ubuntu 24.04 blocks signals inside the controller pod | **Look at:** `kubectl -n nginx-ingress logs deploy/nginx-ingress-controller \| tail`. **Fix:** the `podSecurityContext` with `appArmorProfile: Unconfined` in `nginx-ingress.yaml` (Part 4.6). |
| 8 | Certificate stays `READY False` and a second Ingress called `cm-acme-http-solver-...` exists | The `acme.cert-manager.io/http01-edit-in-place: "true"` annotation is missing | Add it to the app's Ingress (Part 4.9) and push. |
| 9 | Certificate stays `READY False` (no solver Ingress) | DNS not pointing at the server, or port 80 closed | `kubectl -n <ns> describe certificate <name>`, `kubectl get challenges -A`, `kubectl describe challenge -n <ns> <name>`. Check `nslookup`, and the security group allows port 80 from anywhere. |
| 10 | Browser still shows the staging warning after switching to production | The old certificate secret is still stored | `kubectl -n <ns> delete secret <name>-tls`, wait for `READY True`, open a private window. Do this **once**; production has issuing limits. |
| 11 | Backend `CrashLoopBackOff`, log mentions `ImproperlyConfigured` or a missing setting | A required setting or secret is missing | `kubectl -n myapp logs deploy/backend`. The message names the missing item. Add it to `config.env` or to the secret and re-seal. |
| 12 | Backend never becomes Ready; probe shows 400 or 301 | The health check is not sent as a trusted local https request | The probe needs `Host: localhost` and `X-Forwarded-Proto: https`, and `localhost` must be in the allowed hosts setting (Part 4.9). |
| 13 | Pod is `ImagePullBackOff` | The image tag is `placeholder` (CI has not run), or the Docker Hub repo is private or misspelled | `kubectl -n myapp describe pod <pod>`; check the tag in `apps/myapp/kustomization.yaml` and that it exists on Docker Hub. Make the repo **Public**. |
| 14 | The CI run is green but no deploy commit appears | The `update-deploy-repo` job was skipped (a test or build failed) or its token expired or lacks access | Open the run in GitHub Actions. A `403` or "not found" in that job means the `DEPLOY_REPO_TOKEN` expired or has the wrong repository. Create a new one (Part 5.3). |
| 15 | A deploy commit exists but the server still runs the old version | Flux has not picked it up, or the apps Kustomization is failing | `flux get kustomizations`, then `flux reconcile source git flux-system` and look again. |
| 16 | You see the old website after a release | The browser cached it | Test in a private window. Confirm the image tag actually running: `kubectl -n myapp get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].image}'`. |
| 17 | Every visitor appears to have the same IP in the app's logs | The ingress service lost `externalTrafficPolicy: Local` | Check `nginx-ingress.yaml` (Part 4.6). |
| 18 | `ssh`: "Permissions 0644 for key are too open", or "Identity file not accessible" | The key is under `/mnt/c`, or has loose permissions, or the path is wrong | `cp` the key into `~/.ssh/` and `chmod 600` it (Part 2.1). |
| 19 | `ssh` times out | Your home IP changed, so the security group's port 22 rule no longer matches | **[AWS]** security group → edit the SSH rule to **My IP**. |
| 20 | A script fails with `bad interpreter: /usr/bin/env bash^M` | Windows line endings | `sed -i 's/\r$//' scripts/*.sh scripts/on-server/*.sh`, and make sure `.gitattributes` is committed. Keep the repo in the WSL home folder, not `/mnt/c`. |
| 21 | On the server `kubectl` says `connection refused ... localhost:8080` | `KUBECONFIG` is not set in this shell | `export KUBECONFIG=$HOME/.kube/config` (or `source ~/.bashrc`). |
| 22 | A website rule has an empty host, or the build says a variable is not set | A `${NAME}` is used in a file but `NAME` is missing from `cluster-settings.yaml` | Add it, push it **first**, then `flux reconcile kustomization flux-system --with-source` (Part 10.4). |
| 23 | A sealed secret never turns into a normal Secret | It was sealed for a different name or namespace, or with another cluster's certificate | `kubectl -n <ns> describe sealedsecret <name>`. The name and namespace used in `seal-all.sh` must match the app's. If the cluster was rebuilt, restore the private key backup (Part 7.1) before Flux applies the files. |
| 24 | `kubectl top` or deployments fail with "no space left on device" | The server disk is full | `df -h /`. Old container images use space: `sudo k3s crictl rmi --prune`. Consider a larger EBS volume. |

> **When in doubt, read what Flux says:** `flux get kustomizations` and `flux get helmreleases -A` print the
> error message on the failing line. Most problems are explained there in plain words.

---

## Part 12. Cheat sheet: reading the cluster

All on the **[SERVER]**. These only *read*; nothing here changes anything.

| Question | Command |
|---|---|
| Is Flux happy? | `flux get kustomizations` |
| Are the installed helpers (cert-manager, NGINX, Sealed Secrets) happy? | `flux get helmreleases -A` |
| Is everything running? | `kubectl get pods -A` |
| Why is this pod unhappy? | `kubectl -n <ns> describe pod <pod>` |
| What does this app say? | `kubectl -n myapp logs deploy/backend --tail=100` (add `-f` to follow, `-c migrate` for the setup step) |
| Which version is running? | `kubectl -n myapp get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}'; echo` |
| Are the certificates good? | `kubectl get certificate -A` |
| How much CPU and memory? | `kubectl top node` |
| How full is the disk? | `df -h /` |
| Is Flux seeing the latest commit? | `flux get sources git` |

**Two actions that are fine to run:**
- `flux reconcile kustomization apps --with-source`: "check the repo right now" instead of waiting a minute.
- `kubectl -n <ns> rollout restart deploy/<name>`: restart an app (for example after changing a secret).

**Three things you keep safe, offline, in the password manager:**
1. The server key `myapp-key.pem`.
2. The sealed-secrets **private key copy** (`sealed-secrets-key-backup.yaml`, made in Part 7.1).
3. The whole `secrets-local/` folder (the real secret values).

Lose any one of them and recovery gets hard; leak any one of them and someone else can get in.

### Trainer's teach-back questions (ask the junior to explain, in their own words)

1. Why do we have two repos, and which one does the server watch?
2. What is the only thing CI changes in the deploy repo, and why does that start a release?
3. Why does a deploy cause no downtime?
4. What is a Sealed Secret, and why is the public certificate safe to commit but the private key is not?
5. What do we do first when a new website needs a certificate, and why?
6. Why must the worker always be exactly one copy?
7. Why is `prune: false` set on the database, and what is the risk of having no backup?
8. A developer says "my service is ready". What do you ask them before you touch anything?

---

## Appendix A. The finished folder map

```
myapp-deploy/
├── .gitattributes
├── .gitignore
├── .github/workflows/validate.yml        (optional, Appendix B)
├── apps/
│   ├── kustomization.yaml                (the list of apps; add new ones here)
│   ├── myapp/
│   │   ├── namespace.yaml
│   │   ├── kustomization.yaml            (CI edits the two newTag lines)
│   │   ├── config.env                    (normal settings)
│   │   ├── backend.yaml
│   │   ├── workers.yaml
│   │   ├── frontend.yaml
│   │   ├── ingress.yaml
│   │   └── secrets/myapp-secrets.sealed.yaml     (locked secrets)
│   └── shop/                             (example of a second service, Part 10)
├── clusters/production/
│   ├── cluster-settings.yaml             (the website names and emails)
│   ├── infrastructure.yaml               (Flux wiring: stage 1 and 2)
│   ├── data.yaml                         (Flux wiring: the database)
│   ├── apps.yaml                         (Flux wiring: the apps)
│   └── flux-system/                      (written by Flux itself)
├── data/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── postgres.yaml
│   └── secrets/postgres-credentials.sealed.yaml
├── infrastructure/
│   ├── controllers/                      (cert-manager, sealed-secrets, nginx-ingress)
│   └── config/                           (the Let's Encrypt issuers)
├── scripts/
│   ├── generate-secrets.sh
│   ├── seal-all.sh
│   ├── check-placeholders.sh
│   ├── validate.sh                       (optional, Appendix B)
│   └── on-server/ 01..05
├── secrets/pub-cert.pem                  (the public padlock; safe to commit)
└── secrets-local/                        (NOT in git: the real secret values, laptop only)
```

---

## Appendix B. Optional safety net: validate before you push

This catches typing mistakes in the YAML **before** Flux ever sees them. It is optional but recommended.

**`scripts/validate.sh`**

```bash
#!/usr/bin/env bash
# Checks that every manifest renders and matches Kubernetes' (and cert-manager/Flux's) schemas,
# WITHOUT touching a cluster. Runs in CI on every push and you can run it locally.
#
#   ./scripts/validate.sh
#
# Needs: kubectl (for `kubectl kustomize`) and kubeconform on your PATH.
set -euo pipefail

cd "$(dirname "$0")/.."
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v kubeconform >/dev/null || { echo "kubeconform not found" >&2; exit 1; }

# Work on a copy, with stand-in sealed secrets where the real (encrypted) ones are not committed
# yet, so a fresh checkout can still be validated.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R . "$WORK/repo"
cd "$WORK/repo"
rm -rf .git

stub() { # path name namespace
  if [ ! -f "$1" ]; then
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: $2
  namespace: $3
spec:
  encryptedData:
    KEY: AgBstub
  template:
    metadata:
      name: $2
      namespace: $3
EOF
    echo "(stand-in used for $1)"
  fi
}
stub data/secrets/postgres-credentials.sealed.yaml postgres-credentials platform
stub apps/myapp/secrets/myapp-secrets.sealed.yaml myapp-secrets myapp

SCHEMAS=(
  -schema-location default
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
)
CHECK=(kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.31.0 "${SCHEMAS[@]}")

fail=0
for dir in infrastructure/controllers infrastructure/config data apps; do
  echo "==> $dir"
  if ! kubectl kustomize "$dir" > "$WORK/rendered.yaml"; then
    echo "kustomize could not build $dir" >&2
    fail=1
    continue
  fi
  "${CHECK[@]}" "$WORK/rendered.yaml" || fail=1
done

echo "==> clusters/production (Flux wiring)"
"${CHECK[@]}" clusters/production/*.yaml || fail=1

if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED" >&2
  exit 1
fi
echo "All manifests are valid."
```

> When you add a service (Part 10), add one more `stub ...` line for its sealed secret, for example
> `stub apps/shop/secrets/shop-secrets.sealed.yaml shop-secrets shop`.

**`.github/workflows/validate.yml`**: runs the same check on GitHub for every push.

```yaml
name: Validate manifests

# Catches broken YAML before Flux ever sees it. Runs on pull requests and on every push (including
# the automatic image-tag commits from the app pipelines).
on:
  push:
    branches: [main]
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install kubeconform
        run: |
          curl -fsSL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz | tar xz kubeconform
          sudo mv kubeconform /usr/local/bin/

      - name: Validate (kubectl is preinstalled on GitHub runners)
        run: bash ./scripts/validate.sh

      - name: Shell scripts parse
        run: for f in scripts/*.sh scripts/on-server/*.sh; do bash -n "$f"; done

      # A warning, not a failure, so a fresh clone is still green; run it yourself before go-live.
      - name: Placeholders left?
        run: bash ./scripts/check-placeholders.sh
        continue-on-error: true
```

Run it on the laptop any time: `./scripts/validate.sh`. **Check ✅** it ends with `All manifests are valid.`

---

## Appendix C. Glossary

| Word | Meaning |
|---|---|
| **App repo / deploy repo** | The developers' code repository / the repository of server instructions (YAML) that Flux watches. |
| **CI / CD** | Continuous integration (test and build, GitHub Actions) / continuous delivery (roll out, Flux). |
| **Cluster** | The Kubernetes system. Here it is one server running k3s. |
| **ClusterIssuer** | A cert-manager object that knows how to get certificates from one Let's Encrypt service. |
| **ConfigMap / Secret** | Bundles of normal / secret settings that are handed to an app. |
| **Container / image** | A packaged app / the saved package stored on Docker Hub. |
| **cert-manager** | The robot that obtains and renews HTTPS certificates. |
| **Deployment** | "Keep N copies of this app running and upgrade them gently." |
| **EC2** | An AWS virtual server. |
| **Elastic IP** | A fixed public IP address for the server. |
| **Flux** | The program in the cluster that makes the cluster match the deploy repo. |
| **GitOps** | Running infrastructure from files in git, so every change is reviewed and reversible. |
| **Helm / HelmRelease** | An app store for Kubernetes / one installed package from it. |
| **Ingress / Ingress controller** | A routing rule from a website name to an app / the program (NGINX) that follows the rules. |
| **k3s** | A small, complete Kubernetes for one server. |
| **kubeseal / Sealed Secret** | The tool that locks a secret / the locked, git-safe version of it. |
| **Kustomize / Kustomization** | The tool that combines YAML files / a folder of them (and, in Flux, the object that applies a folder). |
| **Migration** | A developer's step that updates the database layout for a new release. |
| **Namespace** | A named group (a "department") inside the cluster. |
| **Pod** | One running copy of an app. |
| **Probe (readiness / liveness)** | A health check. Readiness: "ready for visitors?" Liveness: "still alive?" |
| **PVC** | A request for disk space for a pod. |
| **Reconcile** | "Make reality match the files now." Flux does it automatically; the command only hurries it. |
| **Service** | A fixed internal address for an app. |
| **Staging / production (certificates)** | Let's Encrypt's test service (untrusted, unlimited) / the real one (trusted, limited). |
| **StatefulSet** | Like a Deployment, but for apps with their own disk (the database). |
| **TLS / HTTPS** | The encryption that gives the padlock. |

---

## Appendix D. Values you must replace

| Placeholder in this guide | Replace with | Where it appears |
|---|---|---|
| `example.com`, `app.example.com`, `shop.example.com` | Your real domain and hosts | DNS, `cluster-settings.yaml` |
| `you@example.com`, `no-reply@example.com` | Real email addresses | `cluster-settings.yaml`, git config |
| `your-dockerhub-user` | Your Docker Hub username | `apps/*/kustomization.yaml`, the Deployment files, both CI files |
| `your-github-user` | Your GitHub username or organisation | clone commands, `DEPLOY_REPO`, bootstrap |
| `SERVER_IP` | The Elastic IP from Part 2.3 | SSH, DNS, `scp` |
| `myapp`, `shop` | The real application names | folder and file names, namespaces, image names |
| `eu-west-1` | The AWS region you launch the server in (any region works) | Part 2 |
| `YOUR_WINDOWS_USER` | The Windows user folder name | Part 2.1 |

**Final sign-off checklist (all must be ticked before you call it done):**

- [ ] `https://app.example.com` opens with a normal padlock in a private window.
- [ ] `flux get kustomizations` shows every line **True**.
- [ ] A developer's push reaches the server by itself (Part 8.5) with no manual command.
- [ ] The owner has decided, in writing, how the database will be protected (this build has no automatic backup).
- [ ] The server key, the sealed-secrets private-key backup and `secrets-local/` are saved in the password manager.
- [ ] The CI token's expiry date is in the calendar.
- [ ] Anything that could move money or send messages to real people was tested on a tiny scale first, and
      stays switched off until the developers say it is ready.
