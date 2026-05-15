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
#   LEAF_SLEEP    - opciono, sekunde između leaf zahteva (default 0 sa rotacijom,
#                   6 bez rotacije)
#   ROTATE_IP_CMD - opciono, shell komanda za rotaciju IP-a kad server vrati 429.
#                   Server ima per-IP limit od ~10 leaf zahteva po prozoru.
#                   Primeri:
#                     ROTATE_IP_CMD="mullvad relay set location any && mullvad reconnect"
#                     ROTATE_IP_CMD="nordvpn d && nordvpn c"
#                     ROTATE_IP_CMD="expressvpn disconnect && expressvpn connect smart"
#                   Bez ove varijable, skripta samo čeka 60-180s na 429.
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
# Server filtrira po User-Agentu: default curl/X.X dobija 302 -> /Home/Error.
# Browser UA prolazi.
USER_AGENT="Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.138 YaBrowser/20.6.0.910 (fnrbhc) Yowser/2.5 Yptp/1.23 Safari/537.36"
# Headeri koji idu uz SVAKI zahtev. Definisani na jednom mestu da bi se
# lako dodavali novi.
# $PROXY primer: socks5://USERNAME:PASSWORD@dcp.evomi.com:2002
CORE_HEADERS=(
    -A "$USER_AGENT"
    -x $PROXY
)
LOCALITIES_FILE="./data/localities.json"
OUTPUT_DIR="./output"
TMP_DIR="./output/tmp"
# Tree keš živi van output/ jer su mesta/ulice/kućni brojevi referentni
# podaci koji se ne menjaju često — opstaju i kad korisnik obriše output/.
CACHE_DIR="./data/cache"
STATE_DIR="./output/state"
COMBINED_CSV="${OUTPUT_DIR}/biraci_po_adresi_svi.csv"
CSV_HEADER='"LokalitetId","Opstina","Mesto","Ulica","KucniBroj","Sprat","Stan","BiracaPrebivaliste","BiracaBoraviste"'
DEBUG_LOG="${OUTPUT_DIR}/debug.log"

info()    { echo -e "${CYAN}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
error()   { echo -e "${RED}✗${NC} $1" 1>&2; }

# Sa DEBUG=1, svaki curl poziv ide kroz wrapper koji upisuje sažet zapis u
# $DEBUG_LOG: metod + URL, -H headere, parsirane kolačiće iz $COOKIE_JAR-a,
# --data-urlencode parametre, response headere (-D), i prvih 200 bajtova
# response body-ja (iz -o fajla). Bez DEBUG=1 je identično običnom curl-u.
# Wrapper čuva curl exit kod, stdout (koristi se za -w "%{http_code}") i
# -o <file> body capture, pa pozivaoci ne moraju da se menjaju.
curl_debug() {
    if [[ "$DEBUG" != "1" ]]; then
        command curl "$@"
        return $?
    fi

    local method="GET" output_file=""
    local cookie_jar_read="" cookie_jar_write=""
    local -a headers=() body_params=()
    local args=("$@")
    local url="${args[$((${#args[@]} - 1))]}"
    local i=0
    while (( i < ${#args[@]} - 1 )); do
        case "${args[$i]}" in
            -X)                method="${args[$((i+1))]}";          i=$((i+2)) ;;
            -H)                headers+=("${args[$((i+1))]}");      i=$((i+2)) ;;
            --data-urlencode)  body_params+=("${args[$((i+1))]}");  i=$((i+2)) ;;
            -o)                output_file="${args[$((i+1))]}";     i=$((i+2)) ;;
            -b)                cookie_jar_read="${args[$((i+1))]}"; i=$((i+2)) ;;
            -c)                cookie_jar_write="${args[$((i+1))]}";i=$((i+2)) ;;
            -A|--max-time|-w)                                       i=$((i+2)) ;;
            -s|-G)                                                  i=$((i+1)) ;;
            *)                                                      i=$((i+1)) ;;
        esac
    done

    # Snapshot kolačiće koji će biti POSLATI sa ovim zahtevom — čitamo -b jar
    # PRE nego što curl pokrene, jer -c piše Set-Cookie iz odgovora preko istog
    # fajla pa kasnije čitanje pokazuje pogrešno stanje.
    # NB: HttpOnly kolačići u Netscape formatu imaju "#HttpOnly_" prefiks ispred
    # domene — ne filtriramo po "^#", oslanjamo se na NF>=7 (komentari nemaju
    # tabove pa naturalno otpadaju).
    local request_cookies=""
    if [[ -n "$cookie_jar_read" && -s "$cookie_jar_read" ]]; then
        request_cookies=$(awk -F'\t' 'NF >= 7 { printf "> Cookie: %s=%s\n", $6, $7 }' "$cookie_jar_read")
    fi

    local resp_hdr
    resp_hdr=$(mktemp "${TMP_DIR}/resp_hdr.XXXXXX")
    command curl -D "$resp_hdr" "$@"
    local rc=$?

    {
        printf '\n===== %s %s %s (rc=%s) =====\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$method" "$url" "$rc"
        local h p total
        for h in "${headers[@]}"; do printf '> %s\n' "$h"; done
        [[ -n "$request_cookies" ]] && printf '%s\n' "$request_cookies"
        for p in "${body_params[@]}"; do printf '> param: %s\n' "$p"; done
        if [[ -s "$resp_hdr" ]]; then
            sed 's/\r$//;/^$/d;s/^/< /' "$resp_hdr"
        fi
        if [[ -n "$output_file" && "$output_file" != "/dev/null" && -s "$output_file" ]]; then
            total=$(wc -c < "$output_file" | tr -d ' ')
            printf '< body (%d bytes):\n' "$total"
            head -c 200 "$output_file"
            if (( total > 200 )); then
                printf '\n< [... truncated, total %d bytes ...]\n' "$total"
            else
                echo
            fi
        fi
    } >> "$DEBUG_LOG"

    rm -f "$resp_hdr"
    return $rc
}

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
# ASP.NET MVC anti-forgery koristi DVA __RequestVerificationToken-a:
#   - Cookie token: Set-Cookie sa Home stranice, ide kao Cookie header
#                   (curl ga sam vodi kroz $COOKIE_JAR).
#   - Form token:   <input name="__RequestVerificationToken" ...> iz HTML body-ja,
#                   ide kao --data-urlencode body parametar u POST-ovima.
# Imena su ista, vrednosti su različite i NISU zamenjive.
#
# Tok:
#   1. GET /                          -> Set-Cookie (cookie token) + HTML sa form tokenom
#   2. GET šifrovani captcha          (Referer: /BiraciPoAdresi)
#   3. GET dešifrovani captcha        (Referer: /BiraciPoAdresi)
#   4. POST /BiraciPoAdresi           cookie token (auto iz jar-a) + form token
#                                     iz Home body-ja; Referer: /BiraciPoAdresi;
#                                     302 -> /PretragaBiracaPoAdresi
#   5. GET /PretragaBiracaPoAdresi    parse svežeg form tokena za naredne POST-ove
#
# `init_session` je public wrapper koji vrti `_init_session_once` sa IP-rotacijom
# kad bilo koji korak vrati 429 (per-IP rate-limit). `_init_session_once`
# postavlja `INIT_SESSION_HTTP_CODE` na HTTP kod neuspešnog koraka — wrapper
# čita to da bi razlikovao rate-limit od ostalih grešaka (parsing, mreža...).
_init_session_once() {
    INIT_SESSION_HTTP_CODE=""
    COOKIE_JAR="${TMP_DIR}/cookies.txt"
    rm -f "$COOKIE_JAR"
    local page_file="${TMP_DIR}/main_page.html"
    local http_code

    # 1. GET / — home page.
    #    Set-Cookie: __RequestVerificationToken=<COOKIE_TOKEN>  (auto u $COOKIE_JAR)
    #    HTML body: <input name="__RequestVerificationToken" value="<FORM_TOKEN>" />
    #    Cookie i form token su DVE razdvojene vrednosti istog imena —
    #    nisu zamenjive. Cookie putuje preko -b $COOKIE_JAR, form token
    #    ide kao --data-urlencode parametar u POST-u.
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -w "%{http_code}" \
        -c "$COOKIE_JAR" \
        -o "$page_file" \
        "${BASE_URL}/")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri učitavanju Home stranice (HTTP: $http_code)"
        INIT_SESSION_HTTP_CODE=$http_code
        return 1
    fi

    local token_line
    token_line=$(grep '__RequestVerificationToken' "$page_file" | head -1)
    FORM_REQUEST_VERIFICATION_TOKEN=$(echo "$token_line" | grep -o 'value="[^"]*"' | sed 's/value="//;s/"$//')
    if [[ -z "$FORM_REQUEST_VERIFICATION_TOKEN" ]]; then
        error "Nije moguće pronaći form __RequestVerificationToken na Home stranici"
        return 1
    fi

    # 2. GET šifrovanog captcha rešenja
    local timestamp_ms
    timestamp_ms=$(($(date +%s) * 1000))
    local captcha_enc_file="${TMP_DIR}/captcha_encrypted.txt"
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -w "%{http_code}" \
        -H "Referer: ${BASE_URL}/BiraciPoAdresi" \
        -o "$captcha_enc_file" \
        "${BASE_URL}/Captcha/EncryptedCaptchaSolution?_=${timestamp_ms}")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri dobavljanju šifrovanog captcha rešenja (HTTP: $http_code)"
        INIT_SESSION_HTTP_CODE=$http_code
        return 1
    fi

    local encrypted_solution
    encrypted_solution=$(tr -d '"' < "$captcha_enc_file")
    if [[ -z "$encrypted_solution" ]]; then
        error "Prazno šifrovano captcha rešenje"
        return 1
    fi

    # 3. GET dešifrovanog captcha
    local captcha_dec_file="${TMP_DIR}/captcha_decrypted.json"
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -w "%{http_code}" \
        -H "Referer: ${BASE_URL}/BiraciPoAdresi" \
        -G \
        -o "$captcha_dec_file" \
        "${BASE_URL}/Captcha/GetCaptchaImageContent?encryptedSolution=${encrypted_solution}")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri dešifrovanju captcha (HTTP: $http_code)"
        INIT_SESSION_HTTP_CODE=$http_code
        return 1
    fi

    local captcha_attempt
    captcha_attempt=$(jq -r '.responseText' "$captcha_dec_file")
    if [[ -z "$captcha_attempt" || "$captcha_attempt" == "null" ]]; then
        error "Nije moguće dešifrovati captcha"
        return 1
    fi

    # 4. POST verifikacije na /BiraciPoAdresi (action forme) — očekuje se 302
    #    redirect na /PretragaBiracaPoAdresi.
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: ${BASE_URL}" \
        -H "Referer: ${BASE_URL}/BiraciPoAdresi" \
        --data-urlencode "__RequestVerificationToken=${FORM_REQUEST_VERIFICATION_TOKEN}" \
        --data-urlencode "JMBG=${JMBG}" \
        --data-urlencode "Document=${DOCUMENT_ID}" \
        --data-urlencode "EncrypedSolution=${encrypted_solution}" \
        --data-urlencode "Attempt=${captcha_attempt}" \
        --data-urlencode "submit=Претражи" \
        -o /dev/null \
        "${BASE_URL}/BiraciPoAdresi")
    if [[ "$http_code" != "302" && "$http_code" != "200" ]]; then
        error "Greška pri verifikaciji captcha (HTTP: $http_code)"
        INIT_SESSION_HTTP_CODE=$http_code
        return 1
    fi

    # 5. GET /PretragaBiracaPoAdresi — strana sa votersSearchForm i konačnim
    #    form tokenom potrebnim za VotersOverviewByAddress.
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -H "Referer: ${BASE_URL}/BiraciPoAdresi" \
        -o "$page_file" \
        "${BASE_URL}/PretragaBiracaPoAdresi")
    if [[ "$http_code" != "200" ]]; then
        error "Greška pri učitavanju /PretragaBiracaPoAdresi (HTTP: $http_code)"
        INIT_SESSION_HTTP_CODE=$http_code
        return 1
    fi

    token_line=$(grep '__RequestVerificationToken' "$page_file" | head -1)
    FORM_REQUEST_VERIFICATION_TOKEN=$(echo "$token_line" | grep -o 'value="[^"]*"' | sed 's/value="//;s/"$//')
    if [[ -z "$FORM_REQUEST_VERIFICATION_TOKEN" ]]; then
        error "Nije moguće pronaći form token na /PretragaBiracaPoAdresi (verifikacija možda nije prošla)"
        return 1
    fi

    return 0
}

# Public wrapper: vrti _init_session_once sa IP rotacijom kad bilo koji korak
# vrati 429. Bez ROTATE_IP_CMD-a — backoff (koji obično ne pomaže kod per-IP
# limita, ali ne pravi štetu). Sve druge greške (parsing, non-429 HTTP) se
# propagiraju kao pre.
init_session() {
    local attempt=0
    while (( attempt <= 3 )); do
        if _init_session_once; then
            return 0
        fi
        if [[ "$INIT_SESSION_HTTP_CODE" != "429" ]]; then
            return 1
        fi
        attempt=$((attempt + 1))
        if (( attempt > 3 )); then
            error "init_session: 429 i posle 3 IP rotacija, odustajem"
            return 1
        fi
        if [[ -n "$ROTATE_IP_CMD" ]]; then
            warn "init_session 429, rotiram IP (pokušaj #${attempt})"
            if ! eval "$ROTATE_IP_CMD"; then
                warn "ROTATE_IP_CMD vratio grešku (nastavljam svejedno)"
            fi
            sleep 3
        else
            local wait_s=$((2 * attempt))
            warn "init_session 429, čekam ${wait_s}s (pokušaj #${attempt})"
            sleep $wait_s
        fi
    done
    return 1
}

# Brzo osvežavanje samo form-tokena bez ponovnog captcha-a. Server često
# invalidira form-token posle 1-2 leaf poziva, ali sama sesija (kolačić) i
# dalje važi — dovoljno je ponovo GET-ovati /PretragaBiracaPoAdresi da bi se
# izvukao novi token. Mnogo jeftinije od pune init_session.
refresh_token() {
    local page_file="${TMP_DIR}/main_page.html"
    local http_code
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -H "Referer: ${BASE_URL}/BiraciPoAdresi" \
        -o "$page_file" \
        "${BASE_URL}/PretragaBiracaPoAdresi")
    if [[ "$http_code" != "200" ]]; then
        return 1
    fi
    local token_line
    token_line=$(grep '__RequestVerificationToken' "$page_file" | head -1)
    FORM_REQUEST_VERIFICATION_TOKEN=$(echo "$token_line" | grep -o 'value="[^"]*"' | sed 's/value="//;s/"$//')
    if [[ -z "$FORM_REQUEST_VERIFICATION_TOKEN" ]]; then
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Tree building (mesta -> ulice -> kućni brojevi)
# ----------------------------------------------------------------------------
# Dropdown endpointi sada zahtevaju captcha-verifikovanu sesiju (server vraća
# prazno telo bez nje). Pozivalac mora pozvati init_session pre tree-build.
fetch_dropdown() {
    local endpoint=$1
    local param_name=$2
    local param_value=$3
    local body_file="${TMP_DIR}/dropdown_body.txt"
    local http_code
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -X POST \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -H "Referer: ${BASE_URL}/PretragaBiracaPoAdresi" \
        --data-urlencode "${param_name}=${param_value}" \
        -o "$body_file" \
        -w "%{http_code}" \
        "${BASE_URL}/NumberOfVotersByAddressPreview/${endpoint}")

    # Prazno telo = form-token istekao tokom tree-builda. Pokušaj refresh.
    local body_len
    body_len=$(wc -c < "$body_file" | tr -d ' ')
    if [[ "$http_code" == "200" && "$body_len" == "0" ]]; then
        if refresh_token; then
            http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -X POST \
                -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
                -H "Referer: ${BASE_URL}/PretragaBiracaPoAdresi" \
                --data-urlencode "${param_name}=${param_value}" \
                -o "$body_file" \
                -w "%{http_code}" \
                "${BASE_URL}/NumberOfVotersByAddressPreview/${endpoint}")
            body_len=$(wc -c < "$body_file" | tr -d ' ')
        fi
        if [[ "$DEBUG" == "1" ]]; then
            echo "    [debug] ${endpoint} ${param_name}=${param_value} -> posle refresh: HTTP ${http_code}, body ${body_len}B" 1>&2
        fi
    fi
    cat "$body_file"
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
            sleep 0.01
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
        # Dropdown endpointi (DajSva...) zahtevaju captcha-verifikovanu sesiju,
        # pa init samo kad zaista gradimo. Leaf-loop više ne deli ovu sesiju —
        # svaki leaf ide kroz svoj pun init_session u fetch_and_write_address.
        if ! init_session; then
            error "init_session pao za tree-build lokaliteta ${locality_id}"
            return 1
        fi
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
# Šalje leaf POST sa trenutnom sesijom; vraća HTTP kod preko stdout.
# Pretpostavlja da su $COOKIE_JAR i $FORM_REQUEST_VERIFICATION_TOKEN postavljeni.
do_leaf_request() {
    local locality_id=$1
    local mesto_id=$2
    local ulica_id=$3
    local kucni_id=$4
    local response_file=$5

    local http_code
    http_code=$(curl_debug -s --max-time 30 "${CORE_HEADERS[@]}" -w "%{http_code}" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -X POST \
        -H "Origin: ${BASE_URL}" \
        -H "Referer: ${BASE_URL}/PretragaBiracaPoAdresi" \
        --data-urlencode "__RequestVerificationToken=${FORM_REQUEST_VERIFICATION_TOKEN}" \
        --data-urlencode "SelectedOpstinaId=${locality_id}" \
        --data-urlencode "SelectedMestoId=${mesto_id}" \
        --data-urlencode "SelectedUlicaId=${ulica_id}" \
        --data-urlencode "SelectedKucniBroj=${kucni_id}" \
        --data-urlencode "JMBG=${JMBG}" \
        --data-urlencode "Document=${DOCUMENT_ID}" \
        -o "$response_file" \
        "${BASE_URL}/NumberOfVotersByAddressPreview/VotersOverviewByAddress")

    # Server ponekad vrati 200 sa JSON-om {"redirect":"/BiraciPoAdresi"}
    # umesto HTML rezultata — sesija je istekla na serverskoj strani
    # (npr. iscrpljen captcha budget). Tretiraj kao retry-vredan otkaz.
    if [[ "$http_code" == "200" ]] && grep -q '"redirect"' "$response_file"; then
        echo "redirect"
    else
        echo "$http_code"
    fi
}

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

    # Pun init_session (GET / + captcha + POST verifikacije + GET
    # /PretragaBiracaPoAdresi) pre SVAKOG leaf-a. Server odbija reuse sesije i
    # form-tokena posle jednog uspešnog leaf-a — vraća 200 sa
    # {"redirect":"/BiraciPoAdresi"} — pa nema smisla štedeti na inicijalizaciji.
    if ! init_session; then
        warn "init_session pao za ${marker}, preskačem"
        return 1
    fi

    # Server često vraća 200 sa redirect JSON-om kad se prebrzo šalju leaf zahtevi — čak i sa svežom sesijom.
    sleep 1.5

    local response_file="${TMP_DIR}/voters_address.html"
    local http_code
    http_code=$(do_leaf_request "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$response_file")

    # Sa fresh sesijom, 429/redirect znači per-IP rate-limit. Ako je dostupna
    # IP rotacija — rotiramo i radimo nov pun init na novom IP-u. Bez nje
    # ostaje samo backoff (koji obično ne pomaže, ali ne pravi štetu).
    local attempt=0
    while [[ ( "$http_code" == "429" || "$http_code" == "redirect" ) && $attempt -lt 3 ]]; do
        attempt=$((attempt + 1))
        if [[ -n "$ROTATE_IP_CMD" ]]; then
            warn "${http_code} za ${marker}, rotiram IP (pokušaj #${attempt})"
            if ! eval "$ROTATE_IP_CMD"; then
                warn "ROTATE_IP_CMD vratio grešku (nastavljam svejedno)"
            fi
            sleep 3
        else
            local wait_s=$((2 * attempt))
            warn "${http_code} za ${marker}, čekam ${wait_s}s (pokušaj #${attempt})"
            sleep $wait_s
        fi
        if ! init_session; then
            warn "init_session pao u retry-u za ${marker}"
            continue
        fi
        http_code=$(do_leaf_request "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$response_file")
    done

    if [[ "$http_code" != "200" ]]; then
        warn "HTTP ${http_code} za ${marker} (svi pokušaji neuspeli)"
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
        # Nema <td>, ali stranica može legitimno biti prazan rezultat —
        # tabela tada renderuje samo <th> zaglavlja. Bez <th> verovatno je
        # tranzijentna greška (redirect, error stranica, prekid u extract_tds);
        # ne markiramo, da se ponovo proba na sledećem prolazu.
        if ! grep -q '<th' "$response_file" 2>/dev/null; then
            warn "Prazan odgovor bez <th> za ${marker} (verovatno tranzijent), ne markiram"

            if [[ "$DEBUG" == "1" ]]; then
                local body_len snippet
                body_len=$(wc -c < "$response_file" | tr -d ' ')
                snippet=$(tr '\n' ' ' < "$response_file" | cut -c1-500)
                echo "    [debug] raw response (${body_len}B, HTTP: ${http_code}): ${snippet}" 1>&2
            fi
            return 1
        fi
        # Validan prazan rezultat — markiraj atomično u odnosu na SIGINT.
        trap '' SIGINT SIGTERM
        echo "$marker" >> "$state_file"
        trap 'echo ""; warn "Prekinuto. Pokreni ponovo da nastaviš sa rezimea."; exit 130' SIGINT SIGTERM
        return 0
    fi

    if (( n % 8 != 0 )); then
        warn "Neočekivan broj ćelija (${n}) za ${marker}, preskačem"
        return 1
    fi

    # Kritična sekcija: redovi u CSV i marker u state moraju proći zajedno.
    # Bez ovoga Ctrl-C između printf-a i echo-a ostavlja CSV/state nesaglasne.
    trap '' SIGINT SIGTERM
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
    trap 'echo ""; warn "Prekinuto. Pokreni ponovo da nastaviš sa rezimea."; exit 130' SIGINT SIGTERM
    return 0
}

# ----------------------------------------------------------------------------
# Resume audit
# ----------------------------------------------------------------------------
# Markeri u state fajlu su autoritativna lista "gotovih" adresa, ali ako je
# script ranije bio prekinut (ili je leaf imao tranzijentnu praznu odgovor)
# moguće je da marker postoji bez odgovarajućeg reda u CSV-u. Ova funkcija
# uklanja takve "stale" markere pre nego što počne glavna petlja, tako da se
# nedostajuće adrese ponovo dohvate.
#
# Verifikacija: za svaki marker mesto:ulica:kucni iz tree-a izvedemo trojku
# imena (Mesto, Ulica, KucniBroj) i proverimo da li u CSV-u postoji bar jedan
# red sa tom trojkom u kolonama 3–5. Ako ne — marker je stale, brisimo ga.
audit_state_against_csv() {
    local locality_id=$1
    local state_file=$2
    local csv_file=$3
    local tree_file=$4

    [[ -s "$state_file" ]] || return 0

    if [[ ! -f "$csv_file" ]]; then
        local stale_count
        stale_count=$(wc -l < "$state_file" | tr -d ' ')
        warn "Audit lokaliteta ${locality_id}: CSV ne postoji, brišem ${stale_count} stale markera"
        : > "$state_file"
        return 0
    fi

    local tmp_csv_keys="${TMP_DIR}/audit_csv_keys_${locality_id}.txt"
    local tmp_marker_map="${TMP_DIR}/audit_marker_map_${locality_id}.txt"
    local tmp_kept="${TMP_DIR}/audit_state_kept_${locality_id}.txt"
    local tmp_stats="${TMP_DIR}/audit_stats_${locality_id}.txt"

    # Jedinstvene (Mesto, Ulica, KucniBroj) trojke iz CSV-a (kolone 3–5).
    # Polja su uvek u "" navodnicima pa -F'","' deli pouzdano; vodeći " na
    # prvom polju i prateći " na poslednjem nas ne tiču jer čitamo $3, $4, $5.
    tail -n +2 "$csv_file" \
        | awk -F'","' 'NF >= 5 { print $3 "|" $4 "|" $5 }' \
        | sort -u > "$tmp_csv_keys"

    # Mapiranje marker → "mesto|ulica|kucni" iz tree-a.
    jq -r '
        .mesta[] as $m
        | $m.ulice[] as $u
        | $u.kucniBrojevi[]
        | "\($m.id):\($u.id):\(.Value)\t\($m.name)|\($u.name)|\(.Text)"
    ' "$tree_file" > "$tmp_marker_map"

    awk -F'\t' \
        -v csv_keys_file="$tmp_csv_keys" \
        -v stats_file="$tmp_stats" '
        BEGIN {
            while ((getline line < csv_keys_file) > 0) csv_keys[line] = 1
            close(csv_keys_file)
        }
        FNR == NR {
            marker_to_key[$1] = $2
            next
        }
        {
            marker = $0
            if (marker == "") next
            if (!(marker in marker_to_key)) {
                # Marker nije u tree-u (tree možda menjan); ne možemo proveriti — zadržavamo.
                print marker
                kept++
                next
            }
            if (marker_to_key[marker] in csv_keys) {
                print marker
                kept++
            } else {
                dropped++
            }
        }
        END {
            printf "%d\t%d\n", kept+0, dropped+0 > stats_file
        }
    ' "$tmp_marker_map" "$state_file" > "$tmp_kept"

    local stats kept_count dropped_count
    stats=$(cat "$tmp_stats" 2>/dev/null)
    kept_count=${stats%%$'\t'*}
    dropped_count=${stats##*$'\t'}
    : "${kept_count:=0}"
    : "${dropped_count:=0}"

    if (( dropped_count > 0 )); then
        mv -f "$tmp_kept" "$state_file"
        info "Audit lokaliteta ${locality_id}: zadržano ${kept_count}, uklonjeno ${dropped_count} stale markera"
    else
        rm -f "$tmp_kept"
        info "Audit lokaliteta ${locality_id}: zadržano ${kept_count}, uklonjeno 0 stale markera"
    fi

    rm -f "$tmp_csv_keys" "$tmp_marker_map" "$tmp_stats"
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

    local tree_file="${CACHE_DIR}/tree_${locality_id}.json"
    local csv_file="${OUTPUT_DIR}/biraci_po_adresi_${locality_id}.csv"
    local state_file="${STATE_DIR}/state_${locality_id}.txt"

    # Bez deljene sesije: load_or_build_tree radi sopstveni init_session ako
    # treba da gradi, a svaki leaf u fetch_and_write_address ide kroz svoj
    # pun init_session (server odbija reuse posle jednog uspešnog leaf-a).
    if ! load_or_build_tree "$locality_id"; then
        warn "Preskačem lokalitet ${locality_id} (stablo nedostupno)"
        return 1
    fi

    if [[ ! -f "$csv_file" ]]; then
        echo "$CSV_HEADER" > "$csv_file"
    fi
    touch "$state_file"

    # Pre nego što počnemo: ukloni "stale" markere (state ima marker ali CSV
    # nema odgovarajući red) tako da se nedostajuće adrese ponovo dohvate.
    audit_state_against_csv "$locality_id" "$state_file" "$csv_file" "$tree_file"

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

        printf "  [%s] [%d/%d] %s ... " "$(date +%H:%M:%S)" "$current" "$total_leaves" "$marker"
        if fetch_and_write_address "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$csv_file" "$state_file"; then
            echo -e "${GREEN}OK${NC}"
            processed=$((processed + 1))
        else
            echo -e "${RED}FAIL${NC}"
        fi
        # Leaf endpoint je per-IP rate-limited (~5 zahteva po nepoznatom prozoru).
        # Sa ROTATE_IP_CMD: burst-uj brzo, reaguj na 429 rotacijom (default 0s).
        if [[ -n "$ROTATE_IP_CMD" ]]; then
            info "Sleep ${LEAF_SLEEP:-0}s"
            sleep "${LEAF_SLEEP:-0}"
        fi
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
