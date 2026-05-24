#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: upload_pmtiles_to_r2.sh INPUT_PMTILES R2_KEY

Upload a PMTiles file to a stable Cloudflare R2 object key for application use.

Required env vars:
  DVC_R2_BUCKET
  DVC_R2_ENDPOINT
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
EOF
}

if [[ $# -ne 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage >&2
  exit 1
fi

if [[ -f .env ]]; then
  # Load repo-local R2 credentials when the script is run from the repo root.
  # shellcheck disable=SC1091
  source .env
fi

INPUT_PMTILES=$1
R2_KEY=$2

if [[ ! -s "$INPUT_PMTILES" ]]; then
  echo "Input PMTiles does not exist or is empty: $INPUT_PMTILES" >&2
  exit 1
fi

if [[ -z "${DVC_R2_BUCKET:-}" || -z "${DVC_R2_ENDPOINT:-}" ]]; then
  usage >&2
  exit 1
fi

aws s3 cp \
  "$INPUT_PMTILES" \
  "s3://$DVC_R2_BUCKET/$R2_KEY" \
  --endpoint-url "$DVC_R2_ENDPOINT" \
  --content-type application/octet-stream
