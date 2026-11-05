# idac-bot-deployment-service

GitOps config for deploying [`idac-amane-bot`](https://github.com/Duke40199) to a
**local minikube** cluster via **ArgoCD**. Structure and conventions mirror the
production `deployment-service` repo.

## Layout

```
applications/
  landingzone.yaml         # app-of-apps -> applicationsets/
applicationsets/
  apps.yaml                # AppProject + ApplicationSet (one app per projects/*/overlays/local)
projects/
  idac-amane-bot/
    base/                  # kustomize base: deployment + configmap + secret templates
    overlays/
      local/               # namespace + image tag pin for minikube
```

**This repo uses the app-of-apps + ApplicationSet pattern**, mirroring the
production `deployment-service`: you apply `landingzone.yaml` once, and it manages
the AppProject + ApplicationSet from Git, which in turn generates one ArgoCD
Application per `projects/*/overlays/local`. Add a second app later under
`projects/<app>/overlays/local` and the ApplicationSet picks it up automatically.

## Secrets & this public repo

This repo is public, so no **plaintext** secrets are committed. Config is split:

- **`configmap.yaml`** (committed as-is, safe to publish) — only non-sensitive
  tuning: `APP_ENV`, `PORT`, sync intervals/downtime, `DB_PORT`, `DB_SSLMODE`.
- **The Secret** — everything sensitive OR identifying: the bot token, DB
  credentials/host/name, Discord IDs, and the SEGA/All.Net endpoints. Plaintext
  values live only in your local `secret.env` (gitignored). They reach the repo
  **encrypted**, as a Sealed Secret (`overlays/local/sealed-secret.yaml`), which
  only this cluster can decrypt — so it's safe to commit publicly.

The Deployment does `envFrom` on both the ConfigMap and the (unsealed) Secret, so
Kubernetes merges them into the container's environment. `.gitignore` blocks
`secret.env`, `.env`, `*.secret.yaml`, etc.; the encrypted `sealed-secret.yaml` and
the `*.example` templates are the only secret-related files that get committed.

## One-time prerequisites

1. `minikube start`, and ArgoCD installed in the `argocd` namespace.
2. This repo pushed to GitHub (ArgoCD reads from Git, not your disk).
3. **Sealed Secrets** — the controller in the cluster + the `kubeseal` CLI locally.
   This is how secrets get into a *public* GitOps repo safely (encrypted).

   ```bash
   # cluster-side controller (installs into kube-system as sealed-secrets-controller,
   # which is what kubeseal auto-discovers). Check the releases page for the latest tag:
   # https://github.com/bitnami-labs/sealed-secrets/releases
   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.5/controller.yaml

   # local CLI (macOS)
   brew install kubeseal
   ```

## Deploy

### 1. Build & push the bot image to GHCR

The image is pulled from GitHub Container Registry, so you can build it on the
machine where the code lives — the minikube host just pulls it. GHCR paths must be
**lowercase** (`duke40199`, not `Duke40199`).

```bash
# one-time: log in with a GitHub PAT that has write:packages scope
echo "$CR_PAT" | docker login ghcr.io -u Duke40199 --password-stdin

docker build -t ghcr.io/duke40199/idac-amane-bot:0.1.0 /Users/poteto/go/src/idac-amane-bot
docker push ghcr.io/duke40199/idac-amane-bot:0.1.0
```

The tag `0.1.0` must match `newTag` in `projects/idac-amane-bot/overlays/local/kustomization.yaml`.

First push creates the package as **private**. For the no-pull-secret setup, make
it public: GitHub → your profile → Packages → `idac-amane-bot` → Package settings →
Change visibility → Public. (To keep it private instead, add an `imagePullSecret` —
see the note at the end.)

### 2. Seal the Secret and commit it

Fill in your values locally, then **seal** them — encrypt into a `SealedSecret` that
only this cluster can decrypt, so it's safe to commit to a public repo. `secret.env`
stays local (gitignored); only the encrypted `sealed-secret.yaml` is committed.

```bash
cp projects/idac-amane-bot/base/secret.env.example projects/idac-amane-bot/base/secret.env
# edit secret.env — token, DB creds/host/name, Discord IDs, SEGA/All.Net endpoints

./scripts/seal-secret.sh   # writes projects/idac-amane-bot/overlays/local/sealed-secret.yaml
```

First run only: uncomment the `- sealed-secret.yaml` line in
`projects/idac-amane-bot/overlays/local/kustomization.yaml`. Then commit + push both.
ArgoCD syncs the SealedSecret; the controller unseals it into the real
`idac-amane-bot-secret`, which the Deployment consumes via `envFrom`.

This Secret holds everything sensitive/identifying — the ConfigMap only has
non-sensitive tuning, so there's nothing to hide there.

### 3. (Optional) Adjust the ConfigMap

`configmap.yaml` ships with working defaults. Tweak only if needed — e.g. set
`DB_SSLMODE: require` if your Postgres enforces TLS, or change the sync intervals.
If you edit it, commit + push so ArgoCD picks it up.

### 4. Tell ArgoCD about it

Apply the app-of-apps once:

```bash
kubectl apply -n argocd -f applications/landingzone.yaml
```

That's it — landingzone syncs the ApplicationSet, which generates the
`idac-amane-bot` Application automatically. The ApplicationSet has auto-sync on, so
the app deploys without further clicks; watch it appear in the ArgoCD UI.

### 5. Verify

```bash
kubectl -n idac-amane get pods
kubectl -n idac-amane logs deploy/idac-amane-bot -f
```

Look for the Discord gateway connection and `health server listening on :10000`.

## Updating things over time

There are three kinds of change, and because this repo is **public** they don't
all flow the same way.

### Image (code change) — push-based
Build + push a new tag to GHCR, bump `newTag` in the local overlay, commit + push.
ArgoCD reconciles automatically.

### Non-secret config (`configmap.yaml`) — push-based
Edit it, commit + push. ArgoCD applies the new ConfigMap. One gotcha: the app reads
its env via `envFrom`, so a running pod won't pick up the change until it restarts:

```bash
kubectl -n idac-amane rollout restart deploy/idac-amane-bot
```

(Or install **Stakater Reloader** and annotate the Deployment with
`reloader.stakater.com/auto: "true"` — exactly what `deployment-service` does — to
restart automatically on any ConfigMap/Secret change.)

### Secret / identifying values — push-based via Sealed Secrets
Plaintext values never go in the public repo, but the **encrypted** SealedSecret
does — so updating a secret is the same commit + push loop as config:

```bash
# edit the plaintext value(s) locally (stays gitignored)
vi projects/idac-amane-bot/base/secret.env

# re-encrypt against the cluster's public key, overwriting the sealed file
./scripts/seal-secret.sh

git add projects/idac-amane-bot/overlays/local/sealed-secret.yaml
git commit -m "update secrets" && git push
```

ArgoCD syncs the new SealedSecret and the controller unseals it into
`idac-amane-bot-secret`. The pod still needs a restart to pick up new env (see the
config note above — `rollout restart`, or Stakater Reloader to automate it).

`secret.env` stays on your machine; only the encrypted `sealed-secret.yaml` is
committed. (SOPS is an equivalent alternative to Sealed Secrets.)

> **Lost the cluster?** SealedSecrets are encrypted to a specific controller's key.
> If you recreate minikube, the old sealed-secret.yaml can't be decrypted by the new
> controller — just re-run `scripts/seal-secret.sh` to re-seal against the new key.
> (Back up the controller's sealing key if you want sealed values to survive a
> rebuild.)

## What changed vs. `deployment-service` (AWS -> local)

| Production (`deployment-service`) | Here (minikube) |
| --- | --- |
| ECR image + CI-updated tag | GHCR image, pulled by the node |
| `ExternalSecret` -> AWS Secrets Manager | Sealed Secret committed (encrypted) to Git |
| IRSA `ServiceAccount` | none (bot needs no AWS APIs) |
| `nodeAffinity`/tolerations on EKS node groups | none (single untainted node) |
| Bitbucket SSH remote, `dev-card-platform` ns | GitHub HTTPS remote, `idac-amane` ns |

### Private GHCR image (optional)

If you keep the package private instead of public, the node needs credentials:

```bash
kubectl -n idac-amane create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=Duke40199 \
  --docker-password="$CR_PAT"   # PAT with read:packages
```

Then add `imagePullSecrets: [{name: ghcr-pull}]` to the Deployment's pod spec (or
to the default ServiceAccount). Public images need none of this.
