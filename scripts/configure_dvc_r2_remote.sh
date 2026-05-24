#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure_dvc_r2_remote.sh

Required env vars:
  DVC_R2_BUCKET
  DVC_R2_ENDPOINT

Optional env vars:
  DVC_R2_REMOTE_NAME   default: r2-final
  DVC_R2_REGION        default: auto

This updates .dvc/config to point a DVC remote at a Cloudflare R2 bucket.
Credentials should be provided via AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -f .env ]]; then
  # Load repo-local secrets from .env if present.
  # shellcheck disable=SC1091
  source .env
fi

if [[ -z "${DVC_R2_BUCKET:-}" || -z "${DVC_R2_ENDPOINT:-}" ]]; then
  usage >&2
  exit 1
fi

REMOTE_NAME=${DVC_R2_REMOTE_NAME:-r2-final}
REGION=${DVC_R2_REGION:-auto}
DVC_BIN=${DVC_BIN:-uv run --with dvc[s3] dvc}

echo "Configuring DVC remote '$REMOTE_NAME' for s3://$DVC_R2_BUCKET"
$DVC_BIN remote add -f "$REMOTE_NAME" "s3://$DVC_R2_BUCKET"
$DVC_BIN remote modify "$REMOTE_NAME" endpointurl "$DVC_R2_ENDPOINT"
$DVC_BIN remote modify "$REMOTE_NAME" region "$REGION"

echo "Configured DVC remote '$REMOTE_NAME'"
