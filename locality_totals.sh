#!/bin/bash

# ============================================================================
# Per-lokalitet totali iz tree keša
# ============================================================================
# Za svaki lokalitet u data/localities.json upisuje red u
# output/locality_totals.csv sa brojem mesta, ulica i kućnih brojeva iz
# data/cache/tree_<id>.json. Lokaliteti bez keširanog stabla dobijaju 0/0/0
# (CSV je istovremeno coverage izveštaj). Orphan tree fajlovi (id nije u
# localities.json) se ignorišu — ista politika kao u audit_cache.sh.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

LOCALITIES_FILE="./data/localities.json"
CACHE_DIR="./data/cache"
OUT_FILE="./output/locality_totals.csv"

info()    { echo -e "${CYAN}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" 1>&2; }

if ! command -v jq &> /dev/null; then
    error "jq nije instaliran."
    exit 2
fi

if [[ ! -f "$LOCALITIES_FILE" ]]; then
    error "Nedostaje ${LOCALITIES_FILE}"
    exit 2
fi

mkdir -p "$(dirname "$OUT_FILE")"

echo 'id,name,mesta,ulice,kucni_brojevi' > "$OUT_FILE"

TOTAL=0
WITH_TREE=0

while IFS=$'\t' read -r id name; do
    TOTAL=$((TOTAL + 1))
    tree_file="${CACHE_DIR}/tree_${id}.json"
    if [[ -f "$tree_file" ]]; then
        WITH_TREE=$((WITH_TREE + 1))
        counts=$(jq -r '
            "\([.mesta] | flatten | length),\([.mesta[].ulice] | flatten | length),\([.mesta[].ulice[].kucniBrojevi] | flatten | length)"
        ' "$tree_file")
    else
        counts="0,0,0"
    fi
    printf '%s,"%s",%s\n' "$id" "$name" "$counts" >> "$OUT_FILE"
done < <(jq -r '.[] | "\(.id)\t\(.name)"' "$LOCALITIES_FILE" | sort -n)

echo
success "Upisano ${TOTAL} lokaliteta u ${OUT_FILE}"
info    "Sa keširanim stablom: ${WITH_TREE} / ${TOTAL}"
