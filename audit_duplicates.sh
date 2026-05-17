#!/bin/bash

# ============================================================================
# Audit duplikata u output/biraci_po_adresi_*.csv
# ============================================================================
# Adresni ključ je peterka (Mesto, Ulica, KucniBroj, Sprat, Stan) — LokalitetId
# je u svakom fajlu konstantan, a Sprat+Stan su deo ključa jer jedan KucniBroj
# vraća red po stanu.
#
# Pravilo dedupliciranja:
#   1. Za svaki ključ nađi max(Timestamp).
#   2. Drop-uj redove sa Timestamp < max(Timestamp) — re-scrape garbage iz
#      starijih prolaza.
#   3. Među preostalim redovima (svi na max_ts za taj ključ) drop-uj samo
#      tačne (byte-for-byte) duplikate. Različit BiracaPrebivaliste/Boraviste
#      na istom max_ts ostaje — server ponekad vrati dve legitimne sub-stavke
#      za istu adresu (potvrđeno u 423/424/433 gde nema Sprat/Stan razlike).
#
# Stara verzija ovog skripta je tretirala SVE redove sa istim ključem kao
# duplikate i bacala sve sem jednog, što je za adrese tipa ВИТИНА|3 ([1, 221])
# obrisalo polovinu legitimnih podataka. Novo pravilo to čuva.
#
# Combined fajl (biraci_po_adresi_svi.csv) se preskače jer se regeneriše iz
# per-lokalitet fajlova prilikom sledećeg pokretanja biraci_po_adresi.sh.
#
# Sa --dedupe flagom skripta posle skeniranja prepisuje fajlove sa duplikatima.
# Pre prepisivanja se pravi <fajl>.bak.
#
# Exit kod (default): 0 ako nigde nema duplikata, 1 ako ih ima.
# Exit kod (--dedupe): 0 ako su svi duplikati uspešno uklonjeni, 1 inače.
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OUTPUT_DIR="./output"
COMBINED_BASENAME="biraci_po_adresi_svi.csv"

info()    { echo -e "${CYAN}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" 1>&2; }

DEDUPE=0
case "${1:-}" in
    "")        ;;
    --dedupe)  DEDUPE=1 ;;
    -h|--help)
        echo "Usage: $0 [--dedupe]"
        echo "  bez flag-a: samo prijavljuje duplikate (read-only)"
        echo "  --dedupe:   posle skeniranja prepisuje fajlove sa duplikatima,"
        echo "              zadržavajući po ključu red sa najvećim Timestamp-om."
        echo "              Originali se sačuvaju kao <fajl>.bak."
        exit 0
        ;;
    *)
        error "Nepoznat argument: $1 (probaj --help)"
        exit 2
        ;;
esac

shopt -s nullglob
csv_files=("${OUTPUT_DIR}"/biraci_po_adresi_*.csv)
shopt -u nullglob

if (( ${#csv_files[@]} == 0 )); then
    info "Nema fajlova ${OUTPUT_DIR}/biraci_po_adresi_*.csv — nema šta da se proveri."
    exit 0
fi

echo -e "${BOLD}== Duplikati po adresnom ključu (Mesto|Ulica|KucniBroj|Sprat|Stan) ==${NC}"
printf "  %-10s  %-40s  %10s  %10s  %10s\n" "Lokalitet" "Fajl" "Redova" "Dup ključ" "Dup redova"

files_scanned=0
files_with_dups=0
total_extra=0
dup_files=()

for f in "${csv_files[@]}"; do
    base="${f##*/}"
    if [[ "$base" == "$COMBINED_BASENAME" ]]; then
        continue
    fi
    files_scanned=$((files_scanned + 1))

    # awk vraća: total_rows<TAB>dup_keys<TAB>extra_dup_rows
    # extra = redovi koji bi otpali pravilom (older-ts | exact-byte-dup-at-max-ts).
    # dup_keys = broj ključeva sa bar jednim takvim redom.
    read -r total dup_keys extra < <(
        awk -F'","' '
            NR == 1 { next }
            NF < 10 { total++; next }
            {
                total++
                key = $3 "|" $4 "|" $5 "|" $6 "|" $7
                ts = $10; sub(/"$/, "", ts)
                row_key[NR]  = key
                row_ts[NR]   = ts + 0
                row_line[NR] = $0
                if (!(key in max_ts) || (ts + 0) > max_ts[key]) max_ts[key] = ts + 0
            }
            END {
                for (i in row_key) {
                    k = row_key[i]
                    drop = 0
                    if (row_ts[i] != max_ts[k]) drop = 1
                    else if (row_line[i] in seen) drop = 1
                    else seen[row_line[i]] = 1
                    if (drop) {
                        extra++
                        if (!(k in dropped_keys)) { dropped_keys[k] = 1; dup_keys++ }
                    }
                }
                printf "%d\t%d\t%d\n", total+0, dup_keys+0, extra+0
            }
        ' "$f"
    )

    if (( extra > 0 )); then
        files_with_dups=$((files_with_dups + 1))
        total_extra=$((total_extra + extra))
        dup_files+=("$f")
        locality_id="${base#biraci_po_adresi_}"
        locality_id="${locality_id%.csv}"
        printf "  %-10s  %-40s  %10d  %10d  %10d\n" \
            "$locality_id" "$base" "$total" "$dup_keys" "$extra"
    fi
done

echo
echo -e "${BOLD}== Totali ==${NC}"
info "Skenirano fajlova:        ${files_scanned}"
if (( files_with_dups == 0 )); then
    success "Nema duplikata ni u jednom fajlu."
    exit 0
fi
warn "Fajlova sa duplikatima:   ${files_with_dups}"
warn "Ukupno suvišnih redova:   ${total_extra}"

if (( DEDUPE == 0 )); then
    info "Pokreni sa --dedupe da očistiš duplikate (originali idu u <fajl>.bak)."
    exit 1
fi

echo
echo -e "${BOLD}== Dedupe ==${NC}"
removed_total=0
failed=0
for f in "${dup_files[@]}"; do
    base="${f##*/}"
    bak="${f}.bak"
    tmp="${f}.dedup.tmp"

    if [[ -e "$bak" ]]; then
        error "${bak} već postoji — preskačem ${base} (ručno ukloni .bak pa pokreni ponovo)."
        failed=$((failed + 1))
        continue
    fi

    # Po ključu (peterka iz polja 3–7) zadržavamo SVE redove čiji je Timestamp
    # (polje 10) jednak max(Timestamp) za taj ključ. Među preostalim redovima
    # bacamo samo tačne (byte-for-byte) duplikate. Redosled je original CSV
    # redosled (iteriramo po NR), pa diff originala i deduped fajla ostaje minimalan.
    awk -F'","' '
        NR == 1 { print; next }
        NF < 10 { mal_line[NR] = $0; next }
        {
            key = $3 "|" $4 "|" $5 "|" $6 "|" $7
            ts = $10; sub(/"$/, "", ts)
            row_key[NR]  = key
            row_ts[NR]   = ts + 0
            row_line[NR] = $0
            if (!(key in max_ts) || (ts + 0) > max_ts[key]) max_ts[key] = ts + 0
        }
        END {
            for (i = 2; i <= NR; i++) {
                if (i in mal_line) { print mal_line[i]; continue }
                if (!(i in row_key)) continue
                k = row_key[i]
                if (row_ts[i] != max_ts[k]) continue
                if (row_line[i] in seen) continue
                seen[row_line[i]] = 1
                print row_line[i]
            }
        }
    ' "$f" > "$tmp"

    # Backup pa atomični mv. Bez set -e oslanjanja: greška na bilo kom koraku
    # ostavlja .bak i .tmp na disku za ručnu inspekciju.
    if ! cp -p "$f" "$bak"; then
        error "cp ${f} -> ${bak} pao, preskačem"
        rm -f "$tmp"
        failed=$((failed + 1))
        continue
    fi
    if ! mv "$tmp" "$f"; then
        error "mv ${tmp} -> ${f} pao; vraćam iz ${bak}"
        mv "$bak" "$f" || true
        failed=$((failed + 1))
        continue
    fi

    new_rows=$(($(wc -l < "$f") - 1))
    old_rows=$(($(wc -l < "$bak") - 1))
    diff_rows=$((old_rows - new_rows))
    removed_total=$((removed_total + diff_rows))
    success "${base}: ${old_rows} -> ${new_rows} (-${diff_rows}), backup: ${base}.bak"
done

echo
if (( failed == 0 )); then
    success "Dedupe završen. Uklonjeno ukupno: ${removed_total} redova."
    info "Combined fajl ${COMBINED_BASENAME} NIJE diran — regeneriše se sledećim pokretanjem biraci_po_adresi.sh."
    exit 0
else
    warn "Dedupe završen sa greškama u ${failed} fajl(ov)a. Uklonjeno: ${removed_total} redova."
    exit 1
fi
