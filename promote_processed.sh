#!/bin/bash

# ============================================================================
# Promovisanje kompletnih CSV-ova u data/processed/biraci_po_adresi/
# ============================================================================
# Za svaki output/biraci_po_adresi_<id>.csv poredi broj linija u
# output/state/state_<id>.txt (= obrađenih leaf adresa, uključujući legitimno
# prazne adrese bez glasača) sa kucni_brojevi iz output/locality_totals.csv.
# Isti signal koji koristi progress.sh — ne broj redova niti jedinstvene
# trojke u CSV-u, jer jedan kućni broj može imati više redova (stan/sprat)
# ili nijedan (prazna adresa). Ako CSV nema odgovarajući state fajl, preskače
# se sa upozorenjem (kompletnost se ne može validirati).
#
# Po defaultu prepisuje postojeće fajlove u odredištu (sa anotacijom
# "(overwrite)"). Sa --dry-run ne menja ništa, samo prijavljuje šta bi uradio.
# ============================================================================

set -e

# Ćirilica je 2-bajtni UTF-8 — pod LC_CTYPE=C `printf` i alignment-utiliti
# broje bajte i kolone se loše poravnavaju. Forsiramo UTF-8 locale.
export LC_ALL=en_US.UTF-8

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTALS_CSV="./output/locality_totals.csv"
STATE_DIR="./output/state"
SRC_DIR="./output"
DEST_DIR="./data/processed/biraci_po_adresi"
SRC_PREFIX="biraci_po_adresi_"

info()    { echo -e "${CYAN}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" 1>&2; }

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)
            cat <<EOF
Upotreba: $0 [--dry-run]
  (default)   Kopira sve kompletne ${SRC_PREFIX}*.csv iz ${SRC_DIR}/ u
              ${DEST_DIR}/. CSV je kompletan kada je broj linija u
              ${STATE_DIR}/state_<id>.txt >= kucni_brojevi iz
              ${TOTALS_CSV} (isti signal kao progress.sh).
              Postojeći fajlovi u odredištu se prepisuju.
  -n, --dry-run
              Ne menja ništa, samo ispiše koje bi fajlove kopirao i koje
              bi preskočio.
  -h, --help  Ovaj help.
EOF
            exit 0
            ;;
        *)
            error "Nepoznat argument: $arg (videti --help)"
            exit 2
            ;;
    esac
done

if [[ ! -f "$TOTALS_CSV" ]]; then
    error "Nedostaje ${TOTALS_CSV} — pokreni locality_totals.sh."
    exit 2
fi

if [[ ! -d "$SRC_DIR" ]]; then
    error "Nedostaje ${SRC_DIR}/"
    exit 2
fi

if (( DRY_RUN == 0 )); then
    mkdir -p "$DEST_DIR"
fi

# Učitavamo locality_totals.csv u paralelne nizove (bash 3.2 na macOS nema
# asocijativne nizove — koristimo isti obrazac kao progress.sh).
# Format: id,"name",mesta,ulice,kucni_brojevi. Ime je u dvostrukim navodnicima
# i ne sadrži zarez (vidi locality_totals.sh), pa je IFS=',' siguran split.
exp_ids=()
exp_kucni=()
while IFS=',' read -r f_id f_name _ _ f_kucni; do
    [[ "$f_id" == "id" ]] && continue
    [[ -z "$f_id" ]] && continue
    exp_ids+=("$f_id")
    exp_kucni+=("$f_kucni")
done < "$TOTALS_CSV"

# Linearno pretraži paralelne nizove. ECHO: ispiše kucni_brojevi za dati id,
# ili praznu vrednost ako id nije nađen. exit 0/1 = nađen/nije.
lookup_expected() {
    local needle="$1" i
    for i in "${!exp_ids[@]}"; do
        if [[ "${exp_ids[$i]}" == "$needle" ]]; then
            echo "${exp_kucni[$i]}"
            return 0
        fi
    done
    return 1
}

shopt -s nullglob
src_files=("$SRC_DIR"/${SRC_PREFIX}*.csv)
shopt -u nullglob

if (( ${#src_files[@]} == 0 )); then
    warn "Nema fajlova ${SRC_PREFIX}*.csv u ${SRC_DIR}/."
    exit 0
fi

n_copied=0
n_incomplete=0
n_unknown=0
n_zero=0
n_no_state=0

if (( DRY_RUN )); then
    echo -e "${BOLD}== Dry-run: ${SRC_DIR}/${SRC_PREFIX}*.csv → ${DEST_DIR}/ ==${NC}"
else
    echo -e "${BOLD}== Promovisanje: ${SRC_DIR}/${SRC_PREFIX}*.csv → ${DEST_DIR}/ ==${NC}"
fi

for src in "${src_files[@]}"; do
    base="${src##*/}"
    id="${base#${SRC_PREFIX}}"
    id="${id%.csv}"

    if ! exp=$(lookup_expected "$id"); then
        warn "${base} — id '${id}' nije u ${TOTALS_CSV}; preskačem"
        n_unknown=$((n_unknown + 1))
        continue
    fi

    if (( exp == 0 )); then
        warn "${base} — očekivan broj redova = 0 (nepoznato); preskačem"
        n_zero=$((n_zero + 1))
        continue
    fi

    state_file="${STATE_DIR}/state_${id}.txt"
    if [[ ! -f "$state_file" ]]; then
        warn "${base} — nedostaje ${state_file}; preskačem (kompletnost se ne može validirati)"
        n_no_state=$((n_no_state + 1))
        continue
    fi

    processed=$(wc -l < "$state_file" | tr -d ' ')

    if (( processed < exp )); then
        pct=$(awk -v r="$processed" -v e="$exp" 'BEGIN { printf "%.2f", (r * 100.0) / e }')
        info "${base} — nedovršen (${processed}/${exp} adresa, ${pct}%); preskačem"
        n_incomplete=$((n_incomplete + 1))
        continue
    fi

    dest="${DEST_DIR}/${base}"
    if [[ -e "$dest" ]]; then
        annot=" (overwrite)"
    else
        annot=""
    fi

    if (( DRY_RUN )); then
        success "[dry-run] Kopirao bih ${base} (${processed}/${exp} adresa)${annot}"
    else
        cp -f "$src" "$dest"
        success "Kopirano ${base} (${processed}/${exp} adresa)${annot}"
    fi
    n_copied=$((n_copied + 1))
done

echo
if (( DRY_RUN )); then
    echo -e "${BOLD}== Dry-run sažetak ==${NC}"
    printf "  ${GREEN}%d${NC} bi bilo kopirano\n" "$n_copied"
else
    echo -e "${BOLD}== Sažetak ==${NC}"
    printf "  ${GREEN}%d${NC} kopirano\n" "$n_copied"
fi
printf "  %d nedovršeno\n" "$n_incomplete"
if (( n_no_state > 0 )); then
    printf "  ${YELLOW}%d${NC} bez state fajla\n" "$n_no_state"
fi
if (( n_unknown > 0 )); then
    printf "  ${YELLOW}%d${NC} nepoznat id\n" "$n_unknown"
fi
if (( n_zero > 0 )); then
    printf "  ${YELLOW}%d${NC} bez očekivanog brojača\n" "$n_zero"
fi
