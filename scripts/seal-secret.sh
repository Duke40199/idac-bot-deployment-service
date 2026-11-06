#!/usr/bin/env bash
#
# Generate the committable SealedSecret for a project from its local secret.env.
#
# Usage:
#   ./scripts/seal-secret.sh [project]
#     project: idac-amane-bot (default) | cloudflared
#
# Run from the repo root. Requires:
#   - kubeseal installed locally (brew install kubeseal / dnf install kubeseal)
#   - the sealed-secrets controller running in the target cluster
#   - your kubectl context pointing at that cluster (kubeseal fetches its public
#     key over the kube API)
#
# What it does: builds a plain Secret manifest in-memory from secret.env, pipes it
# through kubeseal to ENCRYPT it with the cluster's public key, and writes the
# result to the project's overlay. secret.env never leaves your machine; only the
# encrypted sealed-secret.yaml is committed (safe for a public repo — only this
# cluster can decrypt it).
#
# After running: commit overlays/local/sealed-secret.yaml and push. To update a
# value later, edit secret.env, re-run this, commit + push — same loop as config.
set -euo pipefail

PROJECT="${1:-idac-amane-bot}"

# All apps share the idac-amane namespace (see applicationsets/apps.yaml), so the
# SealedSecret is sealed for that namespace. The Secret NAME differs per project.
NS="idac-amane"
case "$PROJECT" in
  idac-amane-bot) NAME="idac-amane-bot-secret" ;;
  cloudflared-tunnel)    NAME="cloudflared-tunnel-token" ;;
  *)
    echo "error: unknown project '$PROJECT' (expected: idac-amane-bot | cloudflared-tunnel)" >&2
    exit 1
    ;;
esac

ENV_FILE="projects/$PROJECT/base/secret.env"
OUT="projects/$PROJECT/overlays/local/sealed-secret.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Copy ${ENV_FILE}.example to $ENV_FILE and fill it in." >&2
  exit 1
fi

kubectl create secret generic "$NAME" \
  --namespace "$NS" \
  --from-env-file="$ENV_FILE" \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
  > "$OUT"

echo "wrote $OUT (secret '$NAME' in namespace '$NS')"
echo "next: uncomment the sealed-secret.yaml line in projects/$PROJECT/overlays/local/kustomization.yaml (first run only), then commit + push."