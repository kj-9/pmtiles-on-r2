#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: download_cog.sh URL OUTPUT

Download a COG with resume/retry support.
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

URL=$1
OUTPUT=$2

mkdir -p "$(dirname "$OUTPUT")"

echo "Downloading $URL"
curl -L --continue-at - --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors \
  "$URL" -o "$OUTPUT"

if [[ ! -s "$OUTPUT" ]]; then
  echo "Download failed or file is empty: $OUTPUT" >&2
  exit 1
fi

echo "Downloaded to $OUTPUT"
