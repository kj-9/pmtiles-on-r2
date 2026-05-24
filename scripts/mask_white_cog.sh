#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: mask_white_cog.sh [options] INPUT_COG OUTPUT_COG

Mask white-ish pixels into alpha using the Tokyo workflow:
alpha = 0 when R/G/B are all >= threshold, otherwise 255.

Options:
  -t, --threshold N    White threshold for each RGB band (default: 250)
  -c, --compress NAME  GeoTIFF compression, e.g. DEFLATE or ZSTD (default: DEFLATE)
  -h, --help           Show this help
EOF
}

THRESHOLD=250
COMPRESS=DEFLATE

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--threshold) THRESHOLD=${2:-}; shift 2 ;;
    -c|--compress) COMPRESS=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) break ;;
  esac
done

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

INPUT_COG=$1
OUTPUT_COG=$2

if [[ ! -s "$INPUT_COG" ]]; then
  echo "Input COG does not exist or is empty: $INPUT_COG" >&2
  exit 1
fi

if ! command -v gdal_calc.py >/dev/null 2>&1; then
  echo "gdal_calc.py is required." >&2
  exit 1
fi

if ! command -v gdalbuildvrt >/dev/null 2>&1; then
  echo "gdalbuildvrt is required." >&2
  exit 1
fi

TEMP_DIR=$(mktemp -d /private/tmp/kanto-white-mask.XXXXXX)
trap 'rm -rf "$TEMP_DIR"' EXIT
RED_VRT="$TEMP_DIR/red.vrt"
GREEN_VRT="$TEMP_DIR/green.vrt"
BLUE_VRT="$TEMP_DIR/blue.vrt"
ALPHA_TIF="$TEMP_DIR/alpha.tif"
RGBA_VRT="$TEMP_DIR/rgba.vrt"

mkdir -p "$(dirname "$OUTPUT_COG")"

echo "Creating alpha mask from $INPUT_COG using RGB >= $THRESHOLD"
gdal_translate -b 1 -of VRT "$INPUT_COG" "$RED_VRT"
gdal_translate -b 2 -of VRT "$INPUT_COG" "$GREEN_VRT"
gdal_translate -b 3 -of VRT "$INPUT_COG" "$BLUE_VRT"

gdal_calc.py \
  -A "$INPUT_COG" --A_band=1 \
  -B "$INPUT_COG" --B_band=2 \
  -C "$INPUT_COG" --C_band=3 \
  --calc="where((A>=$THRESHOLD)*(B>=$THRESHOLD)*(C>=$THRESHOLD),0,255)" \
  --outfile="$ALPHA_TIF" \
  --type=Byte \
  --NoDataValue=none

gdalbuildvrt -separate "$RGBA_VRT" "$RED_VRT" "$GREEN_VRT" "$BLUE_VRT" "$ALPHA_TIF"

echo "Building COG $OUTPUT_COG"
gdal_translate \
  "$RGBA_VRT" \
  "$OUTPUT_COG" \
  -of COG \
  -colorinterp red,green,blue,alpha \
  -co COMPRESS="$COMPRESS" \
  -co PREDICTOR=2 \
  -co BLOCKSIZE=256 \
  -co OVERVIEWS=AUTO \
  -co BIGTIFF=IF_SAFER \
  -stats

echo "Masked COG written to $OUTPUT_COG"
