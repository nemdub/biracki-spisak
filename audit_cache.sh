#!/bin/bash

# ============================================================================
# Audit cache stabla
# ============================================================================
# Read-only provera keširanih tree fajlova u data/cache/tree_<id>.json u
# odnosu na data/localities.json:
#   1. Koji lokaliteti iz localities.json nemaju keširano stablo?
#   2. Postoje li orphan tree_*.json fajlovi čiji id nije u localities.json?
#   3. Korumpirana stabla: tree_*.json sa praznom ulicom (0 kućnih brojeva) ili
#      praznim mestom (0 ulica). Po domenu, ulica uvek ima >=1 kućnih brojeva
#      i mesto uvek ima >=1 ulica; bilo koja "prazna" grana je rezidual greške
#      tokom tree-builda (server vratio 429/500/HTML/redirect) i znači da CSV
#      za taj lokalitet propušta podatke.
#   4. Ukupan broj mesta, ulica i kućnih brojeva u prisutnim stablima
#      (orphan fajlovi se ne sabiraju u total).
#
# Exit kod: 0 ako nema missing/orphan/corrupt, inače 1.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOCALITIES_FILE="./data/localities.json"
CACHE_DIR="./data/cache"

info()    { echo -e "${CYAN}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" 1>&2; }

if ! command -v jq &> /dev/null; then
    error "jq nije instaliran. Instaliraj jq pa pokreni ponovo."
    exit 2
fi

if [[ ! -f "$LOCALITIES_FILE" ]]; then
    error "Nedostaje ${LOCALITIES_FILE}"
    exit 2
fi

if ! jq empty "$LOCALITIES_FILE" 2>/dev/null; then
    error "${LOCALITIES_FILE} nije validan JSON"
    exit 2
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

EXPECTED_TSV="${TMP_DIR}/expected.tsv"     # id<TAB>name, sorted by id
EXPECTED_IDS="${TMP_DIR}/expected_ids.txt" # sorted ids
PRESENT_IDS="${TMP_DIR}/present_ids.txt"   # sorted ids found in cache

jq -r '.[] | "\(.id)\t\(.name)"' "$LOCALITIES_FILE" | sort -n > "$EXPECTED_TSV"
cut -f1 "$EXPECTED_TSV" > "$EXPECTED_IDS"

: > "$PRESENT_IDS"
shopt -s nullglob
for f in "${CACHE_DIR}"/tree_*.json; do
    base="${f##*/}"
    id="${base#tree_}"
    id="${id%.json}"
    echo "$id"
done | sort -n > "$PRESENT_IDS"
shopt -u nullglob

EXPECTED_COUNT=$(wc -l < "$EXPECTED_IDS" | tr -d ' ')
PRESENT_COUNT=$(wc -l < "$PRESENT_IDS" | tr -d ' ')

# comm needs LC_ALL=C for byte-wise comparison; sort -n already produced
# numerically-sorted lines but comm only cares that both inputs share the
# same sort order, so we re-sort lexicographically for comm and look up
# names via awk afterwards.
EXP_LEX="${TMP_DIR}/expected_lex.txt"
PRES_LEX="${TMP_DIR}/present_lex.txt"
LC_ALL=C sort "$EXPECTED_IDS" > "$EXP_LEX"
LC_ALL=C sort "$PRESENT_IDS"  > "$PRES_LEX"

MISSING_IDS="${TMP_DIR}/missing.txt"
ORPHAN_IDS="${TMP_DIR}/orphan.txt"
LC_ALL=C comm -23 "$EXP_LEX" "$PRES_LEX" | sort -n > "$MISSING_IDS"
LC_ALL=C comm -13 "$EXP_LEX" "$PRES_LEX" | sort -n > "$ORPHAN_IDS"

MISSING_COUNT=$(wc -l < "$MISSING_IDS" | tr -d ' ')
ORPHAN_COUNT=$(wc -l < "$ORPHAN_IDS"   | tr -d ' ')

echo
echo -e "${BOLD}== Missing lokaliteti (nema tree fajla) ==${NC}"
if (( MISSING_COUNT == 0 )); then
    success "Nema missing lokaliteta."
else
    awk -F'\t' 'NR==FNR { name[$1]=$2; next } { printf "  %s\t%s\n", $1, name[$1] }' \
        "$EXPECTED_TSV" "$MISSING_IDS"
    warn "${MISSING_COUNT} / ${EXPECTED_COUNT} lokaliteta nema keširano stablo."
fi

echo
echo -e "${BOLD}== Orphan tree fajlovi (id nije u localities.json) ==${NC}"
if (( ORPHAN_COUNT == 0 )); then
    success "Nema orphan tree fajlova."
else
    while IFS= read -r id; do
        printf "  %s\t%s/tree_%s.json\n" "$id" "$CACHE_DIR" "$id"
    done < "$ORPHAN_IDS"
    warn "${ORPHAN_COUNT} orphan tree fajl(ov)a u ${CACHE_DIR}/."
fi

# Sabiramo samo validne tree fajlove (id ∈ expected) — orphani ne idu u total.
VALID_FILES=()
while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if LC_ALL=C grep -qxF "$id" "$EXP_LEX"; then
        VALID_FILES+=("${CACHE_DIR}/tree_${id}.json")
    fi
done < "$PRESENT_IDS"

# Provera korumpiranih stabala: ulica bez kućnih brojeva ili mesto bez ulica
# je domenska nemogućnost — postoji samo kao posledica greške tokom tree-builda
# koja je u staroj implementaciji bila tihi `[]` fallback. Brojači po fajlu se
# parsiraju iz jednog jq poziva da bismo izbegli N skupih invokacija.
echo
echo -e "${BOLD}== Korumpirana stabla (prazne ulice / prazna mesta) ==${NC}"
CORRUPT_COUNT=0
if (( ${#VALID_FILES[@]} > 0 )); then
    while IFS=$'\t' read -r path empty_ulice empty_mesta; do
        if (( empty_ulice > 0 || empty_mesta > 0 )); then
            id="${path##*/tree_}"; id="${id%.json}"
            printf "  %s\t%s\t(praznih ulica: %d, praznih mesta: %d)\n" \
                "$id" "$path" "$empty_ulice" "$empty_mesta"
            CORRUPT_COUNT=$((CORRUPT_COUNT + 1))
        fi
    done < <(
        for f in "${VALID_FILES[@]}"; do
            jq -r --arg path "$f" '
                "\($path)\t\([.mesta[].ulice[] | select(.kucniBrojevi | length == 0)] | length)\t\([.mesta[] | select(.ulice | length == 0)] | length)"
            ' "$f"
        done
    )
fi
if (( CORRUPT_COUNT == 0 )); then
    success "Nema korumpiranih stabala."
else
    warn "${CORRUPT_COUNT} korumpiran(o/ih) tree fajl(ov)a — pokreni biraci_po_adresi.sh sa tim ID-jevima da se auto-rebuild aktivira."
fi

echo
echo -e "${BOLD}== Totali (preko ${#VALID_FILES[@]} validnih tree fajlova) ==${NC}"
if (( ${#VALID_FILES[@]} == 0 )); then
    info "Nema validnih tree fajlova za sabiranje."
    mesta=0; ulice=0; kucni=0
else
    read -r mesta ulice kucni < <(
        jq -s -r '
            {
              m: ([.[].mesta[]]                        | length),
              u: ([.[].mesta[].ulice[]]                | length),
              k: ([.[].mesta[].ulice[].kucniBrojevi[]] | length)
            }
            | "\(.m) \(.u) \(.k)"
        ' "${VALID_FILES[@]}"
    )
fi
success "mesta:         ${mesta}"
success "ulice:         ${ulice}"
success "kućni brojevi: ${kucni}"

echo
if (( MISSING_COUNT == 0 && ORPHAN_COUNT == 0 && CORRUPT_COUNT == 0 )); then
    exit 0
else
    exit 1
fi
