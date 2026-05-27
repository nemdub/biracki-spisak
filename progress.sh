#!/bin/bash

# ============================================================================
# Trenutno stanje obrade
# ============================================================================
# Poredi broj obrađenih adresa (linija u output/state/state_<id>.txt — svaki
# marker = jedan leaf koji je biraci_po_adresi.sh upisao zajedno sa redovima
# u CSV) sa očekivanim brojem adresa po lokalitetu iz
# output/locality_totals.csv (kolona kucni_brojevi).
#
# Po defaultu prikazuje samo lokalitete koji su započeti (processed > 0).
# Sa --all prikazuje sve, --wip samo u progresu, --done samo 100% kompletirane.
#
# Read-only — ne menja state/CSV fajlove.
# ============================================================================

set -e

# Ćirilica je 2-bajtni UTF-8 — pod LC_CTYPE=C i `wc -m` i `column -t` broje
# bajte i tabela se loše poravnava. Forsiramo UTF-8 locale za render.
export LC_ALL=en_US.UTF-8

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

TOTALS_CSV="./output/locality_totals.csv"
STATE_DIR="./output/state"

MODE="active"  # active | all | wip | done
for arg in "$@"; do
    case "$arg" in
        --all)  MODE="all" ;;
        --wip) MODE="wip" ;;
        --done) MODE="done" ;;
        -h|--help)
            cat <<EOF
Upotreba: $0 [--all|--done]
  (default)  Prikaži lokalitete sa processed > 0
  --all      Prikaži sve lokalitete iz locality_totals.csv
  --done     Prikaži samo 100% kompletirane lokalitete
EOF
            exit 0
            ;;
        *)
            echo "Nepoznat argument: $arg (videti --help)" 1>&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$TOTALS_CSV" ]]; then
    echo -e "${RED}✗${NC} Nedostaje ${TOTALS_CSV} — pokreni locality_totals.sh." 1>&2
    exit 2
fi

# Učitavamo locality_totals.csv u paralelne nizove. Format reda:
#   id,"name",mesta,ulice,kucni_brojevi
# Ime je u dvostrukim navodnicima i ne sadrži zarez (vidi locality_totals.sh),
# pa je IFS=',' siguran split, samo skidamo okolne navodnike sa imena.
ids=(); names=(); expected=(); processed=()
total_proc=0
total_exp=0
n_done=0; n_wip=0; n_todo=0; n_orphan=0

while IFS=',' read -r f_id f_name _ _ f_kucni; do
    [[ "$f_id" == "id" ]] && continue
    [[ -z "$f_id" ]] && continue
    f_name="${f_name#\"}"; f_name="${f_name%\"}"
    state_file="${STATE_DIR}/state_${f_id}.txt"
    p=0
    if [[ -f "$state_file" ]]; then
        p=$(wc -l < "$state_file" | tr -d ' ')
    fi
    ids+=("$f_id")
    names+=("$f_name")
    expected+=("$f_kucni")
    processed+=("$p")
    total_proc=$((total_proc + p))
    total_exp=$((total_exp + f_kucni))

    if (( f_kucni == 0 )); then
        if (( p > 0 )); then n_orphan=$((n_orphan + 1)); else : ; fi
    elif (( p == 0 )); then
        n_todo=$((n_todo + 1))
    elif (( p >= f_kucni )); then
        n_done=$((n_done + 1))
    else
        n_wip=$((n_wip + 1))
    fi
done < "$TOTALS_CSV"

total_loc=${#ids[@]}

if (( total_exp > 0 )); then
    grand_pct=$(awk -v p="$total_proc" -v e="$total_exp" 'BEGIN { printf "%.2f", (p * 100.0) / e }')
else
    grand_pct="0.00"
fi

echo
echo -e "${BOLD}== Trenutno stanje obrade ($(date '+%Y-%m-%d %H:%M:%S')) ==${NC}"
printf "  ${BOLD}Adrese:${NC}     %'d / %'d  (${BOLD}%s%%${NC})\n" "$total_proc" "$total_exp" "$grand_pct"
printf "  ${BOLD}Lokaliteti:${NC} %d ukupno  ${GREEN}%d DONE${NC}  ${YELLOW}%d WIP${NC}  %d TODO" \
    "$total_loc" "$n_done" "$n_wip" "$n_todo"
if (( n_orphan > 0 )); then
    printf "  ${RED}%d ORPHAN${NC}" "$n_orphan"
fi
echo

echo
case "$MODE" in
    active) echo -e "${BOLD}== Aktivni lokaliteti (processed > 0) ==${NC}" ;;
    wip)   echo -e "${BOLD}== Lokaliteti u progresu ==${NC}" ;;
    done)   echo -e "${BOLD}== Završeni lokaliteti ==${NC}" ;;
    all)    echo -e "${BOLD}== Svi lokaliteti ==${NC}" ;;
esac

# Tabelu gradimo kao TSV pa puštamo kroz `column -t` — bash printf bi računao
# bajte, ne grafeme, i Ćirilica bi se loše poravnala.
TAB=$'\t'
tsv="ID${TAB}NAME${TAB}PROCESSED${TAB}PCT${TAB}STATUS"
shown=0
for i in "${!ids[@]}"; do
    id="${ids[$i]}"
    name="${names[$i]}"
    e="${expected[$i]}"
    p="${processed[$i]}"

    if (( e == 0 )); then
        pct_num="0.00"
        if (( p > 0 )); then status="ORPHAN"; else status="EMPTY"; fi
    elif (( p == 0 )); then
        pct_num="0.00"
        status="TODO"
    elif (( p >= e )); then
        pct_num="100.00"
        status="DONE"
    else
        pct_num=$(awk -v p="$p" -v e="$e" 'BEGIN { printf "%.2f", (p * 100.0) / e }')
        status="WIP"
    fi

    case "$MODE" in
        active) [[ "$status" == "TODO" || "$status" == "EMPTY" ]] && continue ;;
        wip)   [[ "$status" != "WIP" ]] && continue ;;
        done)   [[ "$status" != "DONE" ]] && continue ;;
    esac

    case "$status" in
        DONE)   colored_status="${GREEN}${status}${NC}"  ;;
        WIP)    colored_status="${YELLOW}${status}${NC}" ;;
        ORPHAN) colored_status="${RED}${status}${NC}"    ;;
        *)      colored_status="$status"                 ;;
    esac

    tsv+=$'\n'"${id}${TAB}${name}${TAB}${p}/${e}${TAB}${pct_num}%${TAB}${colored_status}"
    shown=$((shown + 1))
done

if (( shown == 0 )); then
    echo "  (nema redova za prikaz)"
else
    printf '%b\n' "$tsv" | column -t -s "$TAB" | sed 's/^/  /'
fi
