#!/bin/bash

# ============================================================================
# Birači po adresi - broj birača po kućnom broju
# ============================================================================
# Skripta automatski prolazi kroz sve lokalitete iz data/localities.json,
# za svaki lokalitet enumeriše naseljena mesta, ulice i kućne brojeve,
# i preuzima broj birača po prebivalištu i boravištu za svaku adresu.
#
# Izvor podataka: https://upit.birackispisak.gov.rs/PretragaBiracaPoAdresi
#
# Konfiguracija preko environment varijabli:
#   JMBG          - 13-cifreni JMBG (obavezno)
#   DOCUMENT_ID   - broj lične karte (obavezno)
#   MAX_LOCALITIES - opciono, ograničava broj lokaliteta za obradu
#   REFRESH_TREE  - opciono, ako je "1" ponovo gradi stablo lokaliteta
#
# Opcionalni pozicioni argumenti:
#   ./biraci_po_adresi.sh [lokalitet_id ...]
#   ako su navedeni, obrađuju se samo ti lokaliteti
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Configuration
BASE_URL="https://upit.birackispisak.gov.rs"
LOCALITIES_FILE="./data/localities.json"
OUTPUT_DIR="./output"
TMP_DIR="./output/tmp"
CACHE_DIR="./output/cache"
STATE_DIR="./output/state"
COMBINED_CSV="${OUTPUT_DIR}/biraci_po_adresi_svi.csv"
CSV_HEADER='"LokalitetId","Opstina","Mesto","Ulica","KucniBroj","Sprat","Stan","BiracaPrebivaliste","BiracaBoraviste"'

info()    { echo -e "${CYAN}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" 1>&2; }

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                   Birači po adresi (svi lokaliteti)               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_dependencies() {
    local missing=()
    for cmd in curl jq sed grep tr xargs; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Nedostajući programi: ${missing[*]}"
        echo "  macOS:         brew install ${missing[*]}"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing[*]}"
        exit 1
    fi
}

setup_directories() {
    mkdir -p "$OUTPUT_DIR" "$TMP_DIR" "$CACHE_DIR" "$STATE_DIR"
}

validate_credentials() {
    if [[ -z "$JMBG" ]]; then
        error "Nedostaje JMBG (postavi environment varijablu JMBG)"
        exit 1
    fi
    if [[ ! "$JMBG" =~ ^[0-9]{13}$ ]]; then
        error "JMBG mora imati tačno 13 cifara"
        exit 1
    fi
    if [[ -z "$DOCUMENT_ID" ]]; then
        error "Nedostaje DOCUMENT_ID (postavi environment varijablu DOCUMENT_ID)"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Session / captcha
# ----------------------------------------------------------------------------
# Tok je drugačiji od /Verifikacija u biracki_spisak.sh:
#   1. GET /                         -> postavlja inicijalni anti-forgery kolačić
#   2. GET /BiraciPoAdresi (Ref: /)  -> rotira kolačić i vraća formu sa tokenom
#   3. GET šifrovani captcha
#   4. GET dešifrovani captcha
#   5. POST /BiraciPoAdresi (action) -> 302 redirect; -L prati ka /PretragaBiracaPoAdresi
#      koji vraća formu votersSearchForm sa konačnim tokenom za VotersOverviewByAddress.
init_session() {
    COOKIE_JAR="${TMP_DIR}/cookies.txt"
    rm -f "$COOKIE_JAR"
    local page_file="${TMP_DIR}/main_page.html"
    local http_code

    # 1. GET /
    http_code=$(curl -s --max-time 30 -w "%{http_code}" \
        -c "$COOKIE_JAR" \
        -o "$page_file" \
        "${BASE_URL}/")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri učitavanju Home stranice (HTTP: $http_code)"
        return 1
    fi

    # 2. GET /BiraciPoAdresi (zahteva Referer: / i kolačić iz prethodnog koraka)
    http_code=$(curl -s --max-time 30 -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -H "Referer: ${BASE_URL}/" \
        -o "$page_file" \
        "${BASE_URL}/BiraciPoAdresi")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri učitavanju /BiraciPoAdresi (HTTP: $http_code)"
        return 1
    fi

    local token_line
    token_line=$(grep '__RequestVerificationToken' "$page_file" | head -1)
    REQUEST_VERIFICATION_TOKEN=$(echo "$token_line" | grep -o 'value="[^"]*"' | sed 's/value="//;s/"$//')
    if [[ -z "$REQUEST_VERIFICATION_TOKEN" ]]; then
        error "Nije moguće pronaći __RequestVerificationToken na /BiraciPoAdresi"
        return 1
    fi

    # 3. GET šifrovanog captcha rešenja
    local timestamp_ms
    timestamp_ms=$(($(date +%s) * 1000))
    local captcha_enc_file="${TMP_DIR}/captcha_encrypted.txt"
    http_code=$(curl -s --max-time 30 -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -o "$captcha_enc_file" \
        "${BASE_URL}/Captcha/EncryptedCaptchaSolution?_=${timestamp_ms}")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri dobavljanju šifrovanog captcha rešenja (HTTP: $http_code)"
        return 1
    fi

    local encrypted_solution
    encrypted_solution=$(tr -d '"' < "$captcha_enc_file")
    if [[ -z "$encrypted_solution" ]]; then
        error "Prazno šifrovano captcha rešenje"
        return 1
    fi

    # 4. GET dešifrovanog captcha
    local captcha_dec_file="${TMP_DIR}/captcha_decrypted.json"
    http_code=$(curl -s --max-time 30 -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -G \
        -o "$captcha_dec_file" \
        "${BASE_URL}/Captcha/GetCaptchaImageContent?encryptedSolution=${encrypted_solution}")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri dešifrovanju captcha (HTTP: $http_code)"
        return 1
    fi

    local captcha_attempt
    captcha_attempt=$(jq -r '.responseText' "$captcha_dec_file")
    if [[ -z "$captcha_attempt" || "$captcha_attempt" == "null" ]]; then
        error "Nije moguće dešifrovati captcha"
        return 1
    fi

    # 5. POST verifikacije na /BiraciPoAdresi (action forme) — očekuje se 302
    #    redirect na /PretragaBiracaPoAdresi.
    http_code=$(curl -s --max-time 30 -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: ${BASE_URL}" \
        -H "Referer: ${BASE_URL}/BiraciPoAdresi" \
        --data-urlencode "__RequestVerificationToken=${REQUEST_VERIFICATION_TOKEN}" \
        --data-urlencode "JMBG=${JMBG}" \
        --data-urlencode "Document=${DOCUMENT_ID}" \
        --data-urlencode "EncrypedSolution=${encrypted_solution}" \
        --data-urlencode "Attempt=${captcha_attempt}" \
        --data-urlencode "submit=Претражи" \
        -o /dev/null \
        "${BASE_URL}/BiraciPoAdresi")
    if [[ "$http_code" != "302" && "$http_code" != "200" ]]; then
        error "Greška pri verifikaciji captcha (HTTP: $http_code)"
        return 1
    fi

    # 6. GET /PretragaBiracaPoAdresi — strana sa votersSearchForm i konačnim
    #    tokenom potrebnim za VotersOverviewByAddress.
    http_code=$(curl -s --max-time 30 -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -H "Referer: ${BASE_URL}/BiraciPoAdresi" \
        -o "$page_file" \
        "${BASE_URL}/PretragaBiracaPoAdresi")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri učitavanju /PretragaBiracaPoAdresi (HTTP: $http_code)"
        return 1
    fi

    token_line=$(grep '__RequestVerificationToken' "$page_file" | head -1)
    REQUEST_VERIFICATION_TOKEN=$(echo "$token_line" | grep -o 'value="[^"]*"' | sed 's/value="//;s/"$//')
    if [[ -z "$REQUEST_VERIFICATION_TOKEN" ]]; then
        error "Nije moguće pronaći token na /PretragaBiracaPoAdresi (verifikacija možda nije prošla)"
        return 1
    fi

    return 0
}

# ----------------------------------------------------------------------------
# Tree building (mesta -> ulice -> kućni brojevi)
# ----------------------------------------------------------------------------
# Dropdown endpointi se mogu zvati bez verifikacije captcha.
fetch_dropdown() {
    local endpoint=$1
    local param_name=$2
    local param_value=$3
    curl -s --max-time 30 -X POST \
        -H "Referer: ${BASE_URL}/PretragaBiracaPoAdresi" \
        --data-urlencode "${param_name}=${param_value}" \
        "${BASE_URL}/NumberOfVotersByAddressPreview/${endpoint}"
}

build_tree() {
    local locality_id=$1
    local tree_file="${CACHE_DIR}/tree_${locality_id}.json"

    info "Gradim stablo (mesta/ulice/kućni brojevi) za lokalitet ${locality_id}..."

    local mesta_json
    mesta_json=$(fetch_dropdown "DajSvaMestaZaOpstinaId" "opstinaId" "$locality_id")
    if ! echo "$mesta_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
        error "Lokalitet ${locality_id}: neispravan odgovor za listu mesta"
        return 1
    fi

    local tree='{"localityId": '"${locality_id}"', "mesta": []}'

    local mesto_id mesto_name
    while IFS=$'\t' read -r mesto_id mesto_name; do
        [[ -z "$mesto_id" ]] && continue

        local ulice_json
        ulice_json=$(fetch_dropdown "DajSveUliceZaMestoId" "mestoId" "$mesto_id")
        if ! echo "$ulice_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
            echo "  └─ mesto ${mesto_name} (${mesto_id}) [neispravan odgovor za ulice, preskačem]"
            continue
        fi

        local ulica_total
        ulica_total=$(echo "$ulice_json" | jq 'length')

        local ulice_with_kucni='[]'
        local ulica_count=0
        local kucni_total=0

        # Inicijalni status (pre prve iteracije)
        printf "  └─ mesto %s (%s) — 0/%d ulica" "$mesto_name" "$mesto_id" "$ulica_total"

        local ulica_id ulica_name
        while IFS=$'\t' read -r ulica_id ulica_name; do
            [[ -z "$ulica_id" ]] && continue
            local kucni_json
            kucni_json=$(fetch_dropdown "DajSveKucneBrojeveZaUlicaId" "ulicaId" "$ulica_id")
            if ! echo "$kucni_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
                kucni_json='[]'
            fi
            local kucni_count
            kucni_count=$(echo "$kucni_json" | jq 'length')
            kucni_total=$((kucni_total + kucni_count))
            ulica_count=$((ulica_count + 1))

            ulice_with_kucni=$(echo "$ulice_with_kucni" | jq -c \
                --arg id "$ulica_id" \
                --arg name "$ulica_name" \
                --argjson kucni "$kucni_json" \
                '. + [{"id": $id, "name": $name, "kucniBrojevi": $kucni}]')

            # Live progres na istoj liniji (\r + clear-to-EOL).
            printf "\r\033[K  └─ mesto %s (%s) — %d/%d ulica, %d kućnih brojeva (%s)" \
                "$mesto_name" "$mesto_id" "$ulica_count" "$ulica_total" "$kucni_total" "$ulica_name"
            sleep 0.05
        done < <(echo "$ulice_json" | jq -r '.[] | "\(.Value)\t\(.Text)"')

        tree=$(echo "$tree" | jq -c \
            --arg id "$mesto_id" \
            --arg name "$mesto_name" \
            --argjson ulice "$ulice_with_kucni" \
            '.mesta += [{"id": $id, "name": $name, "ulice": $ulice}]')

        # Finalni red (sa novim redom) — sažeti rezultat za mesto.
        printf "\r\033[K  └─ mesto %s (%s) — %d ulica, %d kućnih brojeva\n" \
            "$mesto_name" "$mesto_id" "$ulica_count" "$kucni_total"
    done < <(echo "$mesta_json" | jq -r '.[] | "\(.Value)\t\(.Text)"')

    echo "$tree" > "$tree_file"
    success "Stablo sačuvano: ${tree_file}"
}

load_or_build_tree() {
    local locality_id=$1
    local tree_file="${CACHE_DIR}/tree_${locality_id}.json"
    if [[ "$REFRESH_TREE" == "1" || ! -f "$tree_file" ]]; then
        build_tree "$locality_id" || return 1
    else
        info "Koristim keširano stablo: ${tree_file}"
    fi
}

# ----------------------------------------------------------------------------
# HTML parsing
# ----------------------------------------------------------------------------
# Vraća sve <td> ćelije, jedna po liniji. Svaki red rezultata ima 8 ćelija.
# Filter "<td>" eksplicitno ignoriše <th> ćelije zaglavlja.
extract_tds() {
    local html_file=$1
    tr '\n\r' ' ' < "$html_file" | \
        grep -o '<td[^>]*>[^<]*</td>' | \
        sed 's/<td[^>]*>//g; s/<\/td>//g'
}

# ----------------------------------------------------------------------------
# Leaf fetch + write
# ----------------------------------------------------------------------------
fetch_and_write_address() {
    local locality_id=$1
    local mesto_id=$2
    local ulica_id=$3
    local kucni_id=$4
    local csv_file=$5
    local state_file=$6

    local marker="${mesto_id}:${ulica_id}:${kucni_id}"
    if grep -qxF "$marker" "$state_file" 2>/dev/null; then
        return 0
    fi

    if ! init_session; then
        warn "init_session pao za ${marker}, preskačem"
        return 1
    fi

    local response_file="${TMP_DIR}/voters_address.html"
    local http_code
    http_code=$(curl -s --max-time 30 -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -X POST \
        -H "Origin: ${BASE_URL}" \
        -H "Referer: ${BASE_URL}/PretragaBiracaPoAdresi" \
        --data-urlencode "__RequestVerificationToken=${REQUEST_VERIFICATION_TOKEN}" \
        --data-urlencode "SelectedOpstinaId=${locality_id}" \
        --data-urlencode "SelectedMestoId=${mesto_id}" \
        --data-urlencode "SelectedUlicaId=${ulica_id}" \
        --data-urlencode "SelectedKucniBroj=${kucni_id}" \
        --data-urlencode "JMBG=${JMBG}" \
        --data-urlencode "Document=${DOCUMENT_ID}" \
        -o "$response_file" \
        "${BASE_URL}/NumberOfVotersByAddressPreview/VotersOverviewByAddress")

    if [[ "$http_code" != "200" ]]; then
        warn "HTTP ${http_code} za ${marker}"
        return 1
    fi

    # Skupi sve <td> ćelije; grupiši po 8.
    local cells=()
    while IFS= read -r cell; do
        cell=$(echo "$cell" | xargs)
        cells+=("$cell")
    done < <(extract_tds "$response_file")

    local n=${#cells[@]}
    if (( n == 0 )); then
        # Nema reda - nepoznata adresa ili prazan odgovor.
        # Označi kao gotovo da je ne ponavljamo na resume-u.
        echo "$marker" >> "$state_file"
        return 0
    fi

    if (( n % 8 != 0 )); then
        warn "Neočekivan broj ćelija (${n}) za ${marker}, preskačem"
        return 1
    fi

    local rows_written=0
    local j
    for (( j=0; j<n; j+=8 )); do
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$locality_id" \
            "${cells[j]}" \
            "${cells[j+1]}" \
            "${cells[j+2]}" \
            "${cells[j+3]}" \
            "${cells[j+4]}" \
            "${cells[j+5]}" \
            "${cells[j+6]}" \
            "${cells[j+7]}" \
            >> "$csv_file"
        rows_written=$((rows_written + 1))
    done

    echo "$marker" >> "$state_file"
    return 0
}

# ----------------------------------------------------------------------------
# Per-locality scrape
# ----------------------------------------------------------------------------
scrape_locality() {
    local locality_id=$1
    local locality_name=$2

    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}Lokalitet [${locality_id}] ${locality_name}${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if ! load_or_build_tree "$locality_id"; then
        warn "Preskačem lokalitet ${locality_id} (stablo nedostupno)"
        return 1
    fi

    local tree_file="${CACHE_DIR}/tree_${locality_id}.json"
    local csv_file="${OUTPUT_DIR}/biraci_po_adresi_${locality_id}.csv"
    local state_file="${STATE_DIR}/state_${locality_id}.txt"

    if [[ ! -f "$csv_file" ]]; then
        echo "$CSV_HEADER" > "$csv_file"
    fi
    touch "$state_file"

    # Brojanje ukupno listova i već urađenih
    local total_leaves done_leaves
    total_leaves=$(jq '[.mesta[].ulice[].kucniBrojevi | length] | add // 0' "$tree_file")
    done_leaves=$(wc -l < "$state_file" | tr -d ' ')
    info "Ukupno adresa: ${total_leaves}, već urađeno: ${done_leaves}"

    local processed=0
    local current=0

    local mesto_id ulica_id kucni_id
    while IFS=$'\t' read -r mesto_id ulica_id kucni_id; do
        [[ -z "$kucni_id" ]] && continue
        current=$((current + 1))
        local marker="${mesto_id}:${ulica_id}:${kucni_id}"
        if grep -qxF "$marker" "$state_file" 2>/dev/null; then
            continue
        fi

        printf "  [%d/%d] %s ... " "$current" "$total_leaves" "$marker"
        if fetch_and_write_address "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$csv_file" "$state_file"; then
            echo -e "${GREEN}OK${NC}"
            processed=$((processed + 1))
        else
            echo -e "${RED}FAIL${NC}"
        fi
        sleep 0.5
    done < <(jq -r '.mesta[] as $m | $m.ulice[] as $u | $u.kucniBrojevi[] | "\($m.id)\t\($u.id)\t\(.Value)"' "$tree_file")

    success "Lokalitet ${locality_id}: obrađeno ${processed} novih adresa (ukupno gotovih: $(wc -l < "$state_file" | tr -d ' '))"
}

# ----------------------------------------------------------------------------
# Combined output
# ----------------------------------------------------------------------------
rebuild_combined_csv() {
    info "Pravim kombinovani fajl ${COMBINED_CSV}..."
    echo "$CSV_HEADER" > "$COMBINED_CSV"
    local f
    for f in "${OUTPUT_DIR}"/biraci_po_adresi_*.csv; do
        [[ "$f" == "$COMBINED_CSV" ]] && continue
        [[ ! -f "$f" ]] && continue
        tail -n +2 "$f" >> "$COMBINED_CSV"
    done
    local total
    total=$(($(wc -l < "$COMBINED_CSV") - 1))
    success "Kombinovani fajl: ${COMBINED_CSV} (${total} redova)"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    print_banner
    check_dependencies
    setup_directories
    validate_credentials

    if [[ ! -f "$LOCALITIES_FILE" ]]; then
        error "Nedostaje fajl: $LOCALITIES_FILE"
        exit 1
    fi

    # Filter argumenata - opciono ograničavanje na navedene lokalitete
    local -a filter_ids=("$@")

    # Učitaj sve lokalitete iz JSON-a
    local -a locality_ids=()
    local -a locality_names=()
    while IFS=$'\t' read -r id name; do
        [[ -z "$id" ]] && continue
        if [[ ${#filter_ids[@]} -gt 0 ]]; then
            local match=0
            local f
            for f in "${filter_ids[@]}"; do
                if [[ "$f" == "$id" ]]; then match=1; break; fi
            done
            [[ $match -eq 0 ]] && continue
        fi
        locality_ids+=("$id")
        locality_names+=("$name")
    done < <(jq -r '.[] | "\(.id)\t\(.name)"' "$LOCALITIES_FILE")

    local total=${#locality_ids[@]}
    if [[ $total -eq 0 ]]; then
        error "Nema lokaliteta za obradu"
        exit 1
    fi

    if [[ -n "$MAX_LOCALITIES" && "$MAX_LOCALITIES" -gt 0 && "$MAX_LOCALITIES" -lt "$total" ]]; then
        info "Ograničavam na prvih ${MAX_LOCALITIES} od ${total} lokaliteta (MAX_LOCALITIES)"
        total=$MAX_LOCALITIES
    fi

    info "Obrađujem ${total} lokaliteta"

    local i
    for ((i=0; i<total; i++)); do
        scrape_locality "${locality_ids[$i]}" "${locality_names[$i]}" || true
    done

    rebuild_combined_csv

    echo ""
    success "Završeno."
}

trap 'echo ""; warn "Prekinuto. Pokreni ponovo da nastaviš sa rezimea."; exit 130' SIGINT SIGTERM

main "$@"
