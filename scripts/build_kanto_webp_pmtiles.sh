#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build_kanto_webp_pmtiles.sh

Build the kanto WebP PMTiles while keeping raw/intermediate files outside DVC.

Required env vars:
  KANTO_SOURCE_URL
  KANTO_OUTPUT_PMTILES

Optional env vars:
  KANTO_WHITE_THRESHOLD  default: 250
  KANTO_COMPRESSION      default: DEFLATE
  KANTO_WEBP_QUALITY     default: 90
  KANTO_TILE_SIZE        default: 512
  KANTO_OUTPUT_NAME      default: output basename
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${KANTO_SOURCE_URL:-}" || -z "${KANTO_OUTPUT_PMTILES:-}" ]]; then
  usage >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMP_DIR=$(mktemp -d /private/tmp/kanto-webp-pmtiles.XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT

RAW_COG="$TEMP_DIR/cog-kanto_rapid-3857.tif"
MASKED_COG="$TEMP_DIR/cog-kanto_rapid-white-mask.tif"
OUTPUT_NAME=${KANTO_OUTPUT_NAME:-$(basename "$KANTO_OUTPUT_PMTILES" .pmtiles)}

"$SCRIPT_DIR/download_cog.sh" "$KANTO_SOURCE_URL" "$RAW_COG"
"$SCRIPT_DIR/mask_white_cog.sh" \
  --threshold "${KANTO_WHITE_THRESHOLD:-250}" \
  --compress "${KANTO_COMPRESSION:-DEFLATE}" \
  "$RAW_COG" \
  "$MASKED_COG"
"$SCRIPT_DIR/cog_to_webp_pmtiles.sh" \
  --quality "${KANTO_WEBP_QUALITY:-90}" \
  --tile-size "${KANTO_TILE_SIZE:-512}" \
  --name "$OUTPUT_NAME" \
  "$MASKED_COG" \
  "$KANTO_OUTPUT_PMTILES"
