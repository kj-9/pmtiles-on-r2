#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cog_to_webp_pmtiles.sh [options] INPUT_COG OUTPUT_PMTILES

Create WebP PMTiles from an alpha/no-data COG via GDAL MBTiles.

Options:
  -q, --quality N       WebP quality, 1-100 (default: 90)
  -t, --tile-size N     Tile size in pixels (default: 512)
  -n, --name NAME       Tileset name (default: output basename)
  -h, --help            Show this help

Example:
  ./scripts/cog_to_webp_pmtiles.sh \
    data/tokyo5000-white-mask-250-deflate.cog.tif \
    data/output/tokyo5000-webp-q90.pmtiles
EOF
}

QUALITY=90
TILE_SIZE=512
NAME=

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quality) QUALITY=${2:-}; shift 2;;
    -t|--tile-size) TILE_SIZE=${2:-}; shift 2;;
    -n|--name) NAME=${2:-}; shift 2;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *) break;;
  esac
done

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

INPUT_COG=$1
OUTPUT_PMTILES=$2

if [[ ! -s "$INPUT_COG" ]]; then
  echo "Input COG does not exist or is empty: $INPUT_COG" >&2
  exit 1
fi

if ! command -v gdal_translate >/dev/null 2>&1; then
  echo "gdal_translate is required." >&2
  exit 1
fi

if ! command -v gdaladdo >/dev/null 2>&1; then
  echo "gdaladdo is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PMTILES_BIN=${PMTILES_BIN:-"$PROJECT_ROOT/pmtiles"}

if [[ ! -x "$PMTILES_BIN" ]]; then
  echo "pmtiles CLI is required at $PMTILES_BIN." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PMTILES")"

BASENAME=$(basename "$OUTPUT_PMTILES" .pmtiles)
NAME=${NAME:-$BASENAME}
OUTPUT_MBTILES=${OUTPUT_PMTILES%.pmtiles}.mbtiles

if [[ -e "$OUTPUT_MBTILES" ]]; then
  TEMP_DIR=$(mktemp -d /private/tmp/cog-webp-pmtiles.XXXXXX)
  OUTPUT_MBTILES="$TEMP_DIR/$BASENAME.mbtiles"
  echo "Existing MBTiles found. Using temporary MBTiles: $OUTPUT_MBTILES"
fi

echo "Creating WebP MBTiles: $OUTPUT_MBTILES"
gdal_translate \
  -of MBTiles \
  -co TILE_FORMAT=WEBP \
  -co QUALITY="$QUALITY" \
  -co BLOCKSIZE="$TILE_SIZE" \
  -co NAME="$NAME" \
  -co TYPE=overlay \
  "$INPUT_COG" \
  "$OUTPUT_MBTILES"

echo "Creating lower zoom overviews..."
gdaladdo -r average "$OUTPUT_MBTILES" 2 4 8 16 32 64 128 256 512 1024

BOUNDS=$(gdalinfo -json "$INPUT_COG" | jq -r '.wgs84Extent.coordinates[0] | [.[0][0], .[1][1], .[2][0], .[0][1]] | @csv')
MIN_LON=$(cut -d, -f1 <<<"$BOUNDS")
MIN_LAT=$(cut -d, -f2 <<<"$BOUNDS")
MAX_LON=$(cut -d, -f3 <<<"$BOUNDS")
MAX_LAT=$(cut -d, -f4 <<<"$BOUNDS")
CENTER_LON=$(awk -v a="$MIN_LON" -v b="$MAX_LON" 'BEGIN { printf "%.14f", (a + b) / 2 }')
CENTER_LAT=$(awk -v a="$MIN_LAT" -v b="$MAX_LAT" 'BEGIN { printf "%.14f", (a + b) / 2 }')
MIN_ZOOM=$(sqlite3 "$OUTPUT_MBTILES" "select min(zoom_level) from tiles;")

sqlite3 "$OUTPUT_MBTILES" \
  "insert or replace into metadata(name,value) values('center','$CENTER_LON,$CENTER_LAT,$MIN_ZOOM');"

echo "Converting to PMTiles: $OUTPUT_PMTILES"
"$PMTILES_BIN" convert "$OUTPUT_MBTILES" "$OUTPUT_PMTILES"
"$PMTILES_BIN" verify "$OUTPUT_PMTILES"

echo "Done."
