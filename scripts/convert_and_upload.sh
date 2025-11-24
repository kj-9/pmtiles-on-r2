#!/usr/bin/env bash
set -euo pipefail

# Download an MBTiles file, convert it to PMTiles, and upload it to Cloudflare R2.
# Required environment variables:
#   MBTILES_URL   - Source URL for the MBTiles file.
#   R2_ENDPOINT   - R2 S3-compatible endpoint URL (e.g., https://<account>.r2.cloudflarestorage.com).
#   R2_BUCKET     - R2 bucket name.
#   R2_KEY        - Object key for the uploaded PMTiles (default: derived from MBTILES file name).
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY - R2 credentials.
# Optional:
#   PMTILES_CLI_VERSION - npm package version for pmtiles CLI (default: 5.5.0).
#   TMPDIR - override temp directory location.

: "${MBTILES_URL:?Set MBTILES_URL to the source .mbtiles URL}"
: "${R2_ENDPOINT:?Set R2_ENDPOINT to your Cloudflare R2 endpoint (S3-compatible URL)}"
: "${R2_BUCKET:?Set R2_BUCKET to your Cloudflare R2 bucket name}"
: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID for R2 access}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY for R2 access}"

PMTILES_CLI_VERSION=${PMTILES_CLI_VERSION:-5.5.0}
WORKDIR=$(mktemp -d)
MBTILES_PATH="$WORKDIR/$(basename "$MBTILES_URL")"
PMTILES_PATH=${MBTILES_PATH%.mbtiles}.pmtiles
R2_KEY=${R2_KEY:-$(basename "$PMTILES_PATH")}

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "Downloading MBTiles from $MBTILES_URL ..."
curl -L "$MBTILES_URL" -o "$MBTILES_PATH"

if [[ ! -s "$MBTILES_PATH" ]]; then
  echo "Download failed or file is empty: $MBTILES_PATH" >&2
  exit 1
fi

echo "Converting to PMTiles using pmtiles@$PMTILES_CLI_VERSION ..."
npx -y "pmtiles@${PMTILES_CLI_VERSION}" convert "$MBTILES_PATH" "$PMTILES_PATH"

if [[ ! -s "$PMTILES_PATH" ]]; then
  echo "Conversion failed or output is empty: $PMTILES_PATH" >&2
  exit 1
fi

echo "Uploading to R2 bucket '$R2_BUCKET' with key '$R2_KEY' ..."
AWS_EC2_METADATA_DISABLED=true aws \
  --endpoint-url "$R2_ENDPOINT" \
  s3 cp "$PMTILES_PATH" "s3://$R2_BUCKET/$R2_KEY" \
  --acl public-read

echo "Done. Public URL (if the bucket allows):"
echo "  https://$R2_BUCKET.$(echo "$R2_ENDPOINT" | sed 's#^https\?://##')/$R2_KEY"
