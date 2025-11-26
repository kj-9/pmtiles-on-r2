#!/usr/bin/env bash
set -euo pipefail

# Download an MBTiles file, convert it to PMTiles, and upload it to Cloudflare R2.
# Required values（環境変数 or フラグで指定）:
#   MBTILES_URL   - Source URL for the MBTiles file.
#   R2_ENDPOINT   - R2 S3-compatible endpoint URL (e.g., https://<account>.r2.cloudflarestorage.com).
#   R2_BUCKET     - R2 bucket name.
# Optional:
#   R2_KEY                 - Object key for the uploaded PMTiles (default: derived from MBTiles file name).
#   PMTILES_CLI_VERSION    - npm package version for pmtiles CLI (default: latest).
#   TMPDIR                 - override temp directory location.
# Flags 例:
#   ./scripts/convert_and_upload.sh \\
#     --url https://example.com/data.mbtiles \\
#     --endpoint https://<account>.r2.cloudflarestorage.com \\
#     --bucket my-bucket \\
#     --key data.pmtiles

usage() {
  cat <<'EOF'
Usage: convert_and_upload.sh [options]

  -u, --url URL              MBTiles URL (required if not set via env MBTILES_URL)
  -e, --endpoint URL         R2 endpoint (required if not set via env R2_ENDPOINT)
  -b, --bucket NAME          R2 bucket (required if not set via env R2_BUCKET)
  -k, --key KEY              Object key (default: derived from MBTiles filename)
      --pmtiles-version VER  pmtiles CLI version (default: 5.5.0)
  -h, --help                 Show this help
EOF
}

MBTILES_URL=${MBTILES_URL:-}
R2_ENDPOINT=${R2_ENDPOINT:-}
R2_BUCKET=${R2_BUCKET:-}
R2_KEY=${R2_KEY:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url) MBTILES_URL=${2:-}; shift 2;;
    -e|--endpoint) R2_ENDPOINT=${2:-}; shift 2;;
    -b|--bucket) R2_BUCKET=${2:-}; shift 2;;
    -k|--key) R2_KEY=${2:-}; shift 2;;
    -h|--help) usage; exit 0;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$MBTILES_URL" || -z "$R2_ENDPOINT" || -z "$R2_BUCKET" ]]; then
  echo "Missing required values." >&2
  usage
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WORKDIR="$PROJECT_ROOT/data"
mkdir -p "$WORKDIR"
MBTILES_PATH="$WORKDIR/$(basename "$MBTILES_URL")"
PMTILES_PATH=${MBTILES_PATH%.mbtiles}.pmtiles
R2_KEY=${R2_KEY:-$(basename "$PMTILES_PATH")}

echo "Downloading MBTiles from $MBTILES_URL ..."
# --continue-at - で中断位置からリジューム、失敗時に数回リトライ
curl -L --continue-at - --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors \
  "$MBTILES_URL" -o "$MBTILES_PATH"

if [[ ! -s "$MBTILES_PATH" ]]; then
  echo "Download failed or file is empty: $MBTILES_PATH" >&2
  exit 1
fi

echo "Installing pmtiles binary..."

curl -sL -o - https://github.com/protomaps/go-pmtiles/releases/download/v1.28.2/go-pmtiles-1.28.2_Darwin_arm64.zip | bsdtar xf -
chmod +x pmtiles
echo "Converting to PMTiles using pmtiles ..."
./pmtiles convert "$MBTILES_PATH" "$PMTILES_PATH"

if [[ ! -s "$PMTILES_PATH" ]]; then
  echo "Conversion failed or output is empty: $PMTILES_PATH" >&2
  exit 1
fi

echo "Uploading to R2 bucket '$R2_BUCKET' with key '$R2_KEY' ..."
npx wrangler r2 object put "${R2_BUCKET}/${R2_KEY}" --file="${PMTILES_PATH}" --remote

echo "Done."
