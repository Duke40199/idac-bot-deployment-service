#!/usr/bin/env bash
#
# Scaffold a new service under projects/<name>/ with the repo's standard layout
# (base kustomize + overlays/local + sealed-secret workflow). After running, you
# only need to: fill in the ConfigMap + secret.env, seal the Secret, and push.
#
# Usage:
#   ./scripts/new-service.sh <service-name>
#
# <service-name> must be a lowercase DNS-1123 label (a-z, 0-9, '-'; start/end
# alphanumeric), e.g. "webhook-relay". It becomes the project dir, the Deployment /
# ConfigMap / Secret names, the GHCR image path, and the ArgoCD Application name
# (the ApplicationSet generates one app per projects/*/overlays/local).
#
# What it does NOT do (on purpose — these need your input / cluster access):
#   - fill real config/secret values
#   - seal the Secret (run ./scripts/seal-secret.sh <name> on the shoebox)
#   - commit/push
set -euo pipefail

# Resolve the repo root from this script's location, so it runs from anywhere.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Config lives in the repo-root .env (gitignored; copy from .env.example). Values
# already exported in your environment, or set in .env, override the fallbacks.
if [[ -f "$ROOT/.env" ]]; then
  set -a; . "$ROOT/.env"; set +a
fi
GHCR_OWNER="${GHCR_OWNER:-duke40199}"   # must be lowercase for GHCR
NS="${NS:-idac-amane}"                  # shared namespace (see applicationsets/apps.yaml)
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"

# --- args + validation ---
if [[ $# -ne 1 ]]; then
  echo "usage: $0 <service-name>" >&2
  exit 2
fi
SVC="$1"

if ! [[ "$SVC" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "error: '$SVC' is not a valid name. Use a lowercase DNS-1123 label:" >&2
  echo "       lowercase a-z, 0-9 and '-', starting and ending alphanumeric." >&2
  exit 1
fi
if [[ ${#SVC} -gt 50 ]]; then
  echo "error: '$SVC' is too long (max 50 chars, to leave room for -config/-secret)." >&2
  exit 1
fi

PROJ="$ROOT/projects/$SVC"
if [[ -e "$PROJ" ]]; then
  echo "error: $PROJ already exists — refusing to overwrite." >&2
  exit 1
fi

BASE="$PROJ/base"
OVERLAY="$PROJ/overlays/local"
mkdir -p "$BASE" "$OVERLAY"

# --- base/configmap.yaml ---
cat > "$BASE/configmap.yaml" <<EOF
# Non-sensitive config for ${SVC}. Committed as-is (safe to publish). Anything
# sensitive OR identifying belongs in the Secret instead (secret.example.yaml),
# never here.
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${SVC}-config
  labels:
    app: ${SVC}
data:
  # TODO: replace with your service's real non-secret env vars.
  APP_ENV: "dev"
  # PORT: "10000"
EOF

# --- base/deployment.yaml ---
cat > "$BASE/deployment.yaml" <<EOF
# ${SVC} — scaffolded by scripts/new-service.sh.
#
# Config comes entirely from the environment:
#   - ConfigMap  ${SVC}-config : non-secret values
#   - Secret     ${SVC}-secret : sensitive/identifying values (sealed, see overlay)
# envFrom lists the Secret AFTER the ConfigMap, so a duplicated key in the Secret
# overrides the ConfigMap — keep each key in exactly one of them.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SVC}
  labels:
    app: ${SVC}
spec:
  # Bump if your service scales horizontally; keep 1 for singletons.
  replicas: 1
  selector:
    matchLabels:
      app: ${SVC}
  template:
    metadata:
      labels:
        app: ${SVC}
    spec:
      containers:
        - name: ${SVC}
          # Overlay pins newName/newTag -> ghcr.io/${GHCR_OWNER}/${SVC}:${IMAGE_TAG}.
          # Never rely on :latest (ArgoCD can't detect a redeploy if the tag is
          # unchanged, and IfNotPresent would keep a stale cached image).
          image: ${SVC}
          imagePullPolicy: IfNotPresent
          envFrom:
            - configMapRef:
                name: ${SVC}-config
            - secretRef:
                name: ${SVC}-secret
          # TODO: if your service serves HTTP, expose its port + add probes.
          # ports:
          #   - name: health
          #     containerPort: 10000
          # livenessProbe:
          #   httpGet: { path: /healthz, port: health }
          #   initialDelaySeconds: 10
          #   periodSeconds: 15
          # readinessProbe:
          #   httpGet: { path: /healthz, port: health }
          #   initialDelaySeconds: 5
          #   periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
EOF

# --- base/kustomization.yaml ---
cat > "$BASE/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# secret.example.yaml is intentionally NOT listed — the Secret is created
# out-of-band by sealing (see that file + scripts/seal-secret.sh). The encrypted
# SealedSecret lives in the overlay, bound to THIS cluster's key.
resources:
  - configmap.yaml
  - deployment.yaml
EOF

# --- base/secret.env.example ---
cat > "$BASE/secret.env.example" <<EOF
# Template for the sealed Secret for ${SVC}. Copy to secret.env (gitignored), fill
# in real values, then seal:
#   ./scripts/seal-secret.sh ${SVC}
# secret.env is matched by .gitignore so it can never be committed; only the
# encrypted overlays/local/sealed-secret.yaml is.
#
# IMPORTANT: bare KEY=value — NO surrounding quotes, no trailing spaces.
# kubectl --from-env-file stores values literally (quotes included), which silently
# corrupts them. Put ONLY sensitive/identifying keys here; non-secret knobs live in
# configmap.yaml and must not be duplicated (a duplicate key in the Secret overrides
# the ConfigMap via envFrom).

# TODO: add your service's secret keys, e.g.
# API_TOKEN=
# DB_PASSWORD=
EOF

# --- base/secret.example.yaml ---
cat > "$BASE/secret.example.yaml" <<EOF
# EXAMPLE ONLY — do NOT commit a real Secret and do NOT add this file to
# kustomization.yaml. Documents the shape of the Secret the Deployment expects
# (envFrom secretRef: ${SVC}-secret).
#
# The real Secret is produced by SEALING your local secret.env into an encrypted
# SealedSecret that is safe to commit publicly:
#
#   cp secret.env.example secret.env     # fill in real values (gitignored)
#   ./scripts/seal-secret.sh ${SVC}      # -> overlays/local/sealed-secret.yaml
#
# ArgoCD syncs that SealedSecret; the controller unseals it into the live Secret
# below, which the Deployment consumes via envFrom.
apiVersion: v1
kind: Secret
metadata:
  name: ${SVC}-secret
  labels:
    app: ${SVC}
type: Opaque
stringData:
  # TODO: mirror the keys from secret.env.example.
  API_TOKEN: "REPLACE_ME"
EOF

# --- overlays/local/kustomization.yaml ---
cat > "$OVERLAY/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# The ApplicationSet deploys every app into ${NS} (applicationsets/apps.yaml). Keep
# this in sync with that destination; to give this service its own namespace, also
# template the namespace in the ApplicationSet.
namespace: ${NS}

resources:
  - ../../base
  # The SealedSecret is cluster-specific (encrypted to THIS cluster's key), so it
  # lives in the overlay. Generate it on the shoebox with:
  #   ./scripts/seal-secret.sh ${SVC}
  # then uncomment the next line (first run only) and commit sealed-secret.yaml.
  # Until it exists, the pod stays pending on the missing Secret.
  # - sealed-secret.yaml

# Pin the image here (the GitOps place; base stays a default). Build + push:
#   docker buildx build --platform linux/amd64,linux/arm64 \\
#     -t ghcr.io/${GHCR_OWNER}/${SVC}:${IMAGE_TAG} --push <path-to-source>
# Bump newTag to ship a new build.
images:
  - name: ${SVC}
    newName: ghcr.io/${GHCR_OWNER}/${SVC}
    newTag: "${IMAGE_TAG}"
EOF

# --- done: print the manual steps ---
cat <<EOF

Scaffolded projects/${SVC}/
  base/configmap.yaml         base/deployment.yaml      base/kustomization.yaml
  base/secret.env.example     base/secret.example.yaml  overlays/local/kustomization.yaml

Next (manual) steps:
  1. Edit projects/${SVC}/base/configmap.yaml   — non-secret env.
  2. Build + push the image to ghcr.io/${GHCR_OWNER}/${SVC}:${IMAGE_TAG}
     (and make the GHCR package public, or add an imagePullSecret).
  3. On the shoebox (kubeseal + cluster access):
       cp projects/${SVC}/base/secret.env.example projects/${SVC}/base/secret.env
       # fill in secret.env (bare KEY=value, no quotes)
       ./scripts/seal-secret.sh ${SVC}
       # then uncomment the '- sealed-secret.yaml' line in
       #   projects/${SVC}/overlays/local/kustomization.yaml   (first run only)
  4. git add projects/${SVC} && git commit && git push.
     Heads-up: the ApplicationSet auto-creates the '${SVC}' Application on push to
     main, so the pod is pending until the sealed Secret + image are in place.
EOF
