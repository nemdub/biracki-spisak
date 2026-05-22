#!/usr/bin/env bash
# Generates web/processed_localities.json by listing the processed CSV files.
# Re-run after promote_processed.sh so the web UI knows which localities are browsable.
set -euo pipefail
export LC_ALL=en_US.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$SCRIPT_DIR/data/processed/biraci_po_adresi"
OUT_FILE="$SCRIPT_DIR/web/processed_localities.json"
PREFIX="biraci_po_adresi_"

shopt -s nullglob
entries=()
for f in "$DEST_DIR/$PREFIX"*.csv; do
  base="$(basename "$f")"
  id="${base#"$PREFIX"}"
  id="${id%.csv}"
  [[ "$id" =~ ^[0-9]+$ ]] || continue
  # data rows = total lines minus header
  lines="$(wc -l < "$f" | tr -d ' ')"
  rows=$(( lines > 0 ? lines - 1 : 0 ))
  entries+=("{\"id\":$id,\"rows\":$rows}")
done

mkdir -p "$(dirname "$OUT_FILE")"
{
  printf '['
  for i in "${!entries[@]}"; do
    (( i > 0 )) && printf ','
    printf '%s' "${entries[$i]}"
  done
  printf ']\n'
} > "$OUT_FILE"

echo "Wrote ${#entries[@]} processed localities to $OUT_FILE"
