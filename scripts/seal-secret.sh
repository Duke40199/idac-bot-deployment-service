#!/usr/bin/env bash
#
# Generate the committable SealedSecret from your local secret.env.
#
# Run from the repo root. Requires:
#   - kubeseal installed locally (brew install kubeseal)
#   - the sealed-secrets controller running in the target cluster
#   - your kubectl context pointing at that cluster (kubeseal fetches its public
#     key over the kube API)
#
# What it does: builds a plain Secret manifest in-memory from secret.env, pipes it
# through kubeseal to ENCRYPT it with the cluster's public key, and writes the
# result to the overlay. secret.env never leaves your machine; only the encrypted
# sealed-secret.yaml is committed (safe for a public repo — only this cluster can
# decrypt it).
#
# After running: commit overlays/local/sealed-secret.yaml and push. To update a
# value later, edit secret.env, re-run this, commit + push — same loop as config.
set -euo pipefail

NS="idac-amane"
NAME="idac-amane-bot-secret"
ENV_FILE="projects/idac-amane-bot/base/secret.env"
OUT="projects/idac-amane-bot/overlays/local/sealed-secret.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Copy secret.env.example to secret.env and fill it in." >&2
  exit 1
fi

kubectl create secret generic "$NAME" \
  --namespace "$NS" \
  --from-env-file="$ENV_FILE" \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
  > "$OUT"

echo "wrote $OUT"
echo "next: uncomment the sealed-secret.yaml line in overlays/local/kustomization.yaml (first run only), then commit + push."
