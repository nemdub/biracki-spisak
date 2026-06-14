#!/usr/bin/env bash
# Prepares download artifacts during build (run from the repo root):
#   - One combined CSV of every served per-locality file, zipped.
#   - exports.json manifest (zip size, locality/row counts) for the viewer.
#
# The per-locality CSVs are served as-is from data/processed/biraci_po_adresi/,
# so the viewer links to them directly — only the combined export is assembled
# here. Nothing is generated live; this runs once at deploy time.
#
# Usage: bash generate_exports.sh [OUT_DIR]   (default OUT_DIR=dist/data/exports)
set -euo pipefail

SRC_DIR="data/processed/biraci_po_adresi"
OUT_DIR="${1:-dist/data/exports}"
COMBINED_NAME="biraci_po_adresi_sve.csv"
ZIP_NAME="biraci_po_adresi_sve.csv.zip"

mkdir -p "$OUT_DIR"

shopt -s nullglob
files=("$SRC_DIR"/*.csv)
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No per-locality CSVs found in $SRC_DIR" >&2
  exit 1
fi

combined="$OUT_DIR/$COMBINED_NAME"
# Keep the header from the first file only, append data rows from every file.
# Using print (not a raw byte concat) normalizes any missing trailing newline,
# so the last row of one file never glues onto the next file's header.
awk 'FNR==1 && NR!=1 {next} {print}' "${files[@]}" > "$combined"

# Zip with no stored path components, then drop the loose CSV.
( cd "$OUT_DIR" && rm -f "$ZIP_NAME" && zip -q -j "$ZIP_NAME" "$COMBINED_NAME" && rm -f "$COMBINED_NAME" )

zip_bytes=$(wc -c < "$OUT_DIR/$ZIP_NAME" | tr -d ' ')
locality_count=${#files[@]}
# Total data rows = every line minus one header line per file.
row_count=$(awk 'FNR==1 {next} {n++} END {print n+0}' "${files[@]}")

cat > "$OUT_DIR/exports.json" <<EOF
{"all":{"file":"$ZIP_NAME","bytes":$zip_bytes,"localities":$locality_count,"rows":$row_count}}
EOF

echo "Wrote $OUT_DIR/$ZIP_NAME ($zip_bytes bytes, $locality_count localities, $row_count rows)"
