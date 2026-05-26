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
  # data rows = total lines minus header; stan = rows with a non-empty Stan field (7th column).
  # preb/borav = sum of voter counts (8th/9th columns).
  # Fields are quoted, so splitting on the "," separator keeps interior values clean.
  read -r rows stan preb borav < <(awk -F'","' 'NR>1 { t++; if ($7 != "") s++; p += $8; b += $9 } END { print (t+0), (s+0), (p+0), (b+0) }' "$f")
  entries+=("{\"id\":$id,\"rows\":$rows,\"stan\":$stan,\"preb\":$preb,\"borav\":$borav}")
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
