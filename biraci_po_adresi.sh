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
#   CREDENTIALS_FILE - opciono, putanja do fajla sa više JMBG,DOCUMENT_ID parova
#                      (jedan po liniji, "JMBG,DOCUMENT_ID"; # i prazne linije
#                      se ignorišu). Ako je postavljeno, skripta rotira kroz
#                      parove round-robin: jedan par po leaf upitu, po tree-buildu
#                      i po retry-u. Bez ovog, koristi se JMBG/DOCUMENT_ID kao
#                      jedinstveni par.
#   JMBG          - 13-cifreni JMBG (obavezno ako CREDENTIALS_FILE nije set)
#   DOCUMENT_ID   - broj lične karte (obavezno ako CREDENTIALS_FILE nije set)
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
#   IP_CHECK_INTERVAL - opciono, na svakih N obrađenih leaf adresa zabeleži
#                   izlazni IP koji curl koristi (kroz isti proxy/headere).
#                   Korisno za potvrdu da IP rotacija stvarno menja IP i za
#                   dijagnozu rate-limita. Default 10; 0 isključuje proveru.
#   IP_ECHO_URL   - opciono, servis koji vraća izlazni IP (default
#                   https://api.ipify.org). Pogađa se kroz isti $PROXY pa NE
#                   troši per-IP budžet gov servera (drugi host).
#   PARALLEL      - opciono, broj paralelnih workera (default 1). Svaki worker
#                   obrađuje po jedan lokalitet iz deljenog reda, sa sopstvenim
#                   cookie jar-om i tmp direktorijumom (output/tmp/worker_<pid>).
#                   NAPOMENA: PARALLEL>1 sa ROTATE_IP_CMD je problematično — workeri
#                   se međusobno ometaju oko jedne IP rotacije. Sa jednim IP-om i
#                   PARALLEL>1 očekuj brže 429-ove jer dele rate-limit budžet.
#   CRED_FAILURE_THRESHOLD - opciono, broj UZASTOPNIH neuspeha (429/redirect/
#                   unavailable/init fail) za isti kredencijal pre nego što se
#                   zaledi (default 3). Brojanje je deljeno među svim workerima i
#                   instancama preko output/state/cred_cooldown.txt. Uspešan leaf
#                   resetuje brojač. NB: 429 je per-IP limit (ne per-kredencijal),
#                   pa sa jednim IP-om / bez ROTATE_IP_CMD podigni prag da burst
#                   429-ova ne zaledi zdrav kredencijal.
#   CRED_COOLDOWN_SECONDS - opciono, trajanje cooldown-a u sekundama (default
#                   10800 = 3h). Zaleđen kredencijal se preskače pri izboru dok ne
#                   istekne. Kad su SVI kredencijali zaleđeni, worker čeka da
#                   najskoriji istekne (uz proveru stop-flag-a) pa nastavlja.
#
# Opcionalni pozicioni argumenti:
#   ./biraci_po_adresi.sh [--trees-only] [lokalitet_id ...]
#   ako su navedeni lokalitet_id-jevi, obrađuju se samo ti lokaliteti.
#   --trees-only: gradi/osvežava samo cache stabla (data/cache/tree_*.json) i
#                 preskače skupljanje birača po adresama. Komponuje se sa
#                 REFRESH_TREE=1 (force rebuild), PARALLEL=N (paralelna gradnja
#                 stabala) i listom lokaliteta.
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
USER_AGENT="Mozilla/5.0 (Macintosh; U; PPC Mac OS X 10_9_4) AppleWebKit/535.0 (KHTML, like Gecko) Chrome/17.0.876.0 Safari/535.0"
# Headeri koji idu uz SVAKI zahtev. Definisani na jednom mestu da bi se
# lako dodavali novi.
# $PROXY primer: socks5://USERNAME:PASSWORD@dcp.evomi.com:2002
# PROXY se uključuje samo ako je env var postavljen — inače `-x ""` (prazan
# string) prouzrokuje da curl pojede sledeći argument kao proxy spec i sve
# pukne na Step 1 sa praznim HTTP kodom.
CORE_HEADERS=(
    -A "$USER_AGENT"
)
if [[ -n "$PROXY" ]]; then
    CORE_HEADERS+=(-x "$PROXY")
fi
# Povremena provera izlaznog IP-a (vidi log_egress_ip). Brojanje je per-worker
# preko $LEAF_PROCESSED_COUNT — svaki worker je zaseban proces pa ne dele brojač.
IP_CHECK_INTERVAL="${IP_CHECK_INTERVAL:-10}"
IP_ECHO_URL="${IP_ECHO_URL:-https://api.ipify.org}"
LEAF_PROCESSED_COUNT=0
LOCALITIES_FILE="./data/localities.json"
OUTPUT_DIR="./output"
# TMP_DIR_BASE je root za sve per-worker tmp direktorijume. Svaki worker
# (uključujući i jedini worker u PARALLEL=1 modu) koristi sopstveni
# poddirektorijum "${TMP_DIR_BASE}/worker_<parent-pid>_<worker-id>" da bi
# cookie jar i scratch fajlovi bili izolovani — i između workera u jednoj
# instanci, i između više istovremeno pokrenutih instanci na istom računaru.
TMP_DIR_BASE="./output/tmp"
QUEUE_FILE="${TMP_DIR_BASE}/queue.txt"
# Postojanje fajla signalizira workerima da stanu na sledećoj granici iteracije
# (između adresa i između lokaliteta) bez novog posla. Main ga touch-uje u
# SIGINT/SIGTERM trapu pre nego što pošalje SIGTERM workerima. Workeri ga
# proveravaju na vrhu svakih retry/loop petlji.
STOP_FLAG_FILE="${TMP_DIR_BASE}/stop_signal"
# Lock je direktorijum (mkdir je atomično na svim FS-ovima i radi i na macOS-u
# gde nema flock-a podrazumevano). pop_locality mkdir-uje pre čitanja, rmdir-uje
# posle.
QUEUE_LOCK_DIR="${TMP_DIR_BASE}/queue.lock.d"
# Tree keš živi van output/ jer su mesta/ulice/kućni brojevi referentni
# podaci koji se ne menjaju često — opstaju i kad korisnik obriše output/.
CACHE_DIR="./data/cache"
STATE_DIR="./output/state"
# Deljeni cooldown za kredencijale: kad isti par napravi CRED_FAILURE_THRESHOLD
# uzastopnih neuspeha (429/redirect/unavailable/init fail), zaledi se na
# CRED_COOLDOWN_SECONDS i preskače se pri izboru. Fajl je na fiksnoj putanji u
# STATE_DIR pa ga dele SVI workeri u jednoj instanci I sve istovremeno pokrenute
# instance na istom računaru; preživi restart unutar cooldown prozora. Lock je
# mkdir-bazovan (isti obrazac kao QUEUE_LOCK_DIR / pop_locality).
COOLDOWN_FILE="${STATE_DIR}/cred_cooldown.txt"
COOLDOWN_LOCK_DIR="${STATE_DIR}/cred_cooldown.lock.d"
CRED_COOLDOWN_SECONDS="${CRED_COOLDOWN_SECONDS:-21600}"
CRED_FAILURE_THRESHOLD="${CRED_FAILURE_THRESHOLD:-3}"
COMBINED_CSV="${OUTPUT_DIR}/biraci_po_adresi_svi.csv"
CSV_HEADER='"LokalitetId","Opstina","Mesto","Ulica","KucniBroj","Sprat","Stan","BiracaPrebivaliste","BiracaBoraviste","Timestamp"'
# DEBUG_LOG se postavlja per-worker u worker_init (output/debug_worker_<pid>.log)
# da paralelni >> appendi ne bi razbijali jedan zajednički log.
DEBUG_LOG=""

# Pool kredencijala: paralelni arrays popunjeni iz CREDENTIALS_FILE ili iz
# pojedinačnih JMBG/DOCUMENT_ID env varijabli (one-entry fallback). CRED_IDX
# je per-worker pokazivač u pool — u PARALLEL>1 modu svaki worker je subshell
# i ima sopstveni CRED_IDX (i sopstvene JMBG/DOCUMENT_ID), pa nema deljenja
# preko procesnih granica. CRED_LAST_IDX čuva poslednji izabrani indeks (za
# _cred_tag log poruke).
CRED_JMBGS=()
CRED_DOCS=()
CRED_IDX=0
CRED_LAST_IDX=0

# U paralelnom modu, svaka log linija dobija [W#] prefiks da bi se output od
# različitih workera lako razdvajao. WORKER_ID se postavlja u worker_init samo
# kad PARALLEL>1 (vidi main); u sekvencijalnom modu prefix se ne pojavljuje pa
# log izgleda identično kao pre.
_log_prefix() { printf '[%s] ' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; [[ -n "$WORKER_ID" ]] && printf '[W%s] ' "$WORKER_ID"; }
info()    { echo -e "${CYAN}ℹ${NC} $(_log_prefix)$1" 1>&2; }
success() { echo -e "${GREEN}✓${NC} $(_log_prefix)$1" 1>&2; }
warn()    { echo -e "${YELLOW}⚠${NC} $(_log_prefix)$1" 1>&2; }
error()   { echo -e "${RED}✗${NC} $(_log_prefix)$1" 1>&2; }

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
            cat "$output_file"
            echo
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
    mkdir -p "$OUTPUT_DIR" "$TMP_DIR_BASE" "$CACHE_DIR" "$STATE_DIR"
    # Eventualni leftover iz prethodnog run-a (npr. kraš pre nego što je
    # `setup_directories` pozvan u sledećem run-u).
    rm -f "$STOP_FLAG_FILE"
}

# Učitava pool kredencijala u CRED_JMBGS / CRED_DOCS. Ako je CREDENTIALS_FILE
# postavljen — parsira fajl (jedan "JMBG,DOCUMENT_ID" par po liniji, # i prazne
# linije se ignorišu). Inače — uzima JMBG/DOCUMENT_ID env varijable kao
# jedinstveni par (backwards-compat). Validacija je ista u oba slučaja:
# JMBG mora biti 13 cifara, DOCUMENT_ID ne sme biti prazan.
load_credentials() {
    CRED_JMBGS=()
    CRED_DOCS=()
    local invalid=0

    if [[ -n "$CREDENTIALS_FILE" ]]; then
        if [[ ! -f "$CREDENTIALS_FILE" ]]; then
            error "CREDENTIALS_FILE ne postoji: $CREDENTIALS_FILE"
            exit 1
        fi
        local lineno=0 raw jmbg doc
        while IFS= read -r raw || [[ -n "$raw" ]]; do
            lineno=$((lineno + 1))
            raw="${raw%$'\r'}"
            raw="${raw#"${raw%%[![:space:]]*}"}"
            raw="${raw%"${raw##*[![:space:]]}"}"
            [[ -z "$raw" ]] && continue
            [[ "$raw" == \#* ]] && continue
            jmbg="${raw%%,*}"
            doc="${raw#*,}"
            if [[ "$doc" == "$raw" ]]; then
                warn "CREDENTIALS_FILE linija ${lineno}: nema zareza, preskačem"
                invalid=$((invalid + 1))
                continue
            fi
            jmbg="${jmbg#"${jmbg%%[![:space:]]*}"}"
            jmbg="${jmbg%"${jmbg##*[![:space:]]}"}"
            doc="${doc#"${doc%%[![:space:]]*}"}"
            doc="${doc%"${doc##*[![:space:]]}"}"
            if [[ ! "$jmbg" =~ ^[0-9]{13}$ ]]; then
                warn "CREDENTIALS_FILE linija ${lineno}: JMBG '${jmbg}' nije 13 cifara, preskačem"
                invalid=$((invalid + 1))
                continue
            fi
            if [[ -z "$doc" ]]; then
                warn "CREDENTIALS_FILE linija ${lineno}: prazan DOCUMENT_ID, preskačem"
                invalid=$((invalid + 1))
                continue
            fi
            CRED_JMBGS+=("$jmbg")
            CRED_DOCS+=("$doc")
        done < "$CREDENTIALS_FILE"

        if (( ${#CRED_JMBGS[@]} == 0 )); then
            error "CREDENTIALS_FILE (${CREDENTIALS_FILE}) ne sadrži nijedan validan par"
            exit 1
        fi
        if (( invalid > 0 )); then
            warn "CREDENTIALS_FILE: ${invalid} linija preskočeno, ${#CRED_JMBGS[@]} validnih parova učitano"
        else
            info "Učitano ${#CRED_JMBGS[@]} kredencijalnih parova iz ${CREDENTIALS_FILE}"
        fi
        return 0
    fi

    if [[ -z "$JMBG" ]]; then
        error "Nedostaje JMBG (postavi environment varijablu JMBG ili CREDENTIALS_FILE)"
        exit 1
    fi
    if [[ ! "$JMBG" =~ ^[0-9]{13}$ ]]; then
        error "JMBG mora imati tačno 13 cifara"
        exit 1
    fi
    if [[ -z "$DOCUMENT_ID" ]]; then
        error "Nedostaje DOCUMENT_ID (postavi environment varijablu DOCUMENT_ID ili CREDENTIALS_FILE)"
        exit 1
    fi
    CRED_JMBGS+=("$JMBG")
    CRED_DOCS+=("$DOCUMENT_ID")
}

# ----------------------------------------------------------------------------
# Deljeni cooldown kredencijala (output/state/cred_cooldown.txt)
# ----------------------------------------------------------------------------
# Format: jedna linija po kredencijalu sa stanjem —
#   <JMBG>\t<broj_uzastopnih_neuspeha>\t<ban_until_epoch>
# ban_until_epoch == 0 -> nije zaleđen, samo nosi brojač neuspeha.
# Cooldown je aktivan iff ban_until_epoch > sada. Brojanje je GLOBALNO po
# kredencijalu (deljeno među workerima i instancama): neuspesi iz bilo kog
# workera se sabiraju, uspešan leaf iz bilo kog workera resetuje brojač.
#
# Read-modify-write ide pod mkdir-lock-om (COOLDOWN_LOCK_DIR), isti spin/force
# obrazac kao pop_locality. Jeftina read-only provera (cred_in_cooldown) čita
# bez lock-a — best-effort, u skladu sa ostalim lock-free čitanjima u skripti.
_now_epoch() { date +%s; }

_cooldown_lock() {
    local attempts=0
    local -r max_attempts=600   # 600 * 0.1s = 60s
    while ! mkdir "$COOLDOWN_LOCK_DIR" 2>/dev/null; do
        attempts=$((attempts + 1))
        if (( attempts >= max_attempts )); then
            warn "cooldown lock zaglavljen 60s, forsiram"
            rm -rf "$COOLDOWN_LOCK_DIR"
            mkdir "$COOLDOWN_LOCK_DIR" 2>/dev/null || true
            break
        fi
        sleep 0.1
    done
}
_cooldown_unlock() { rmdir "$COOLDOWN_LOCK_DIR" 2>/dev/null || true; }

# Vraća 0 ako je kredencijal trenutno zaleđen (ban_until > sada), inače 1.
cred_in_cooldown() {
    local jmbg=$1
    [[ -s "$COOLDOWN_FILE" ]] || return 1
    local now
    now=$(_now_epoch)
    awk -F'\t' -v j="$jmbg" -v now="$now" '
        $1 == j && ($3 + 0) > now { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$COOLDOWN_FILE"
}

# Pod lock-om: inkrementira brojač neuspeha za JMBG. Kad dostigne prag, postavlja
# ban_until = sada + CRED_COOLDOWN_SECONDS i resetuje brojač. Prilikom upisa
# prunuje istekle/nulte zapise (count==0 i ban_until<=sada).
cred_record_failure() {
    local jmbg=$1
    local now
    now=$(_now_epoch)
    _cooldown_lock
    touch "$COOLDOWN_FILE"   # garantuje da awk ima ulaz i da END radi insert
    local tmp="${COOLDOWN_FILE}.tmp.$$"
    local banned=0
    awk -F'\t' -v j="$jmbg" -v now="$now" \
        -v thr="$CRED_FAILURE_THRESHOLD" -v dur="$CRED_COOLDOWN_SECONDS" \
        -v flag="$tmp.banned" '
        BEGIN { OFS = "\t" }
        {
            if ($1 == j) {
                seen = 1
                cnt = $2 + 1
                ban = $3 + 0
                if (ban <= now && cnt >= thr) { ban = now + dur; cnt = 0; print "1" > flag }
                if (cnt == 0 && ban <= now) next   # prune
                print $1, cnt, ban
            } else {
                if (($2 + 0) == 0 && ($3 + 0) <= now) next   # prune tuđe istekle
                print $1, $2, $3
            }
        }
        END {
            if (!seen) {
                cnt = 1; ban = 0
                if (cnt >= thr) { ban = now + dur; cnt = 0; print "1" > flag }
                if (!(cnt == 0 && ban <= now)) print j, cnt, ban
            }
        }
    ' "$COOLDOWN_FILE" > "$tmp"
    mv -f "$tmp" "$COOLDOWN_FILE"
    [[ -f "$tmp.banned" ]] && banned=1 && rm -f "$tmp.banned"
    _cooldown_unlock
    if (( banned == 1 )); then
        warn "Kredencijal JMBG ${jmbg} zaleđen na ${CRED_COOLDOWN_SECONDS}s posle ${CRED_FAILURE_THRESHOLD} uzastopnih grešaka"
    fi
}

# Pod lock-om: briše zapis za JMBG (reset brojača + uklanja eventualni istekli
# ban). Uspešan leaf znači da kredencijal radi, pa krećemo iz čistog stanja.
cred_record_success() {
    local jmbg=$1
    [[ -s "$COOLDOWN_FILE" ]] || return 0
    local now
    now=$(_now_epoch)
    _cooldown_lock
    local tmp="${COOLDOWN_FILE}.tmp.$$"
    awk -F'\t' -v j="$jmbg" -v now="$now" '
        BEGIN { OFS = "\t" }
        $1 == j { next }
        ($2 + 0) == 0 && ($3 + 0) <= now { next }   # prune istekle
        { print $1, $2, $3 }
    ' "$COOLDOWN_FILE" > "$tmp" 2>/dev/null || : > "$tmp"
    mv -f "$tmp" "$COOLDOWN_FILE"
    _cooldown_unlock
}

# Postavlja globalne JMBG / DOCUMENT_ID na sledeći NE-zaleđeni par iz pool-a
# (round-robin počev od CRED_IDX) i pomera CRED_IDX. CRED_LAST_IDX čuva izabrani
# indeks (0-based) za _cred_tag. Kad su SVI parovi zaleđeni, čeka da najskoriji
# istekne (sleep u koracima od max 60s uz proveru stop-flag-a) pa ponovo proba.
# Vraća non-zero samo ako je prekinut stop-flag-om.
select_credential() {
    local n=${#CRED_JMBGS[@]}
    while :; do
        [[ -f "$STOP_FLAG_FILE" ]] && return 1
        local i idx jmbg
        for (( i = 0; i < n; i++ )); do
            idx=$(( (CRED_IDX + i) % n ))
            jmbg="${CRED_JMBGS[$idx]}"
            if ! cred_in_cooldown "$jmbg"; then
                CRED_LAST_IDX=$idx
                JMBG="$jmbg"
                DOCUMENT_ID="${CRED_DOCS[$idx]}"
                CRED_IDX=$(( (idx + 1) % n ))
                return 0
            fi
        done
        # Svi zaleđeni — nađi najskoriji ban_until SAMO za parove iz ovog pool-a
        # i čekaj. Cooldown fajl je deljen sa drugim workerima (drugi JMBG-ovi);
        # bez filtera na naš pool budili bismo se na tuđe thaw-ove dok su naši
        # i dalje zaleđeni, vrteći "svi zaleđeni" bez ijednog pokušaja.
        local now soonest wait_s jmbg_set
        now=$(_now_epoch)
        jmbg_set=$(printf '%s\n' "${CRED_JMBGS[@]}")
        soonest=$(awk -F'\t' -v now="$now" -v set="$jmbg_set" '
            BEGIN { n = split(set, a, "\n"); for (k = 1; k <= n; k++) mine[a[k]] = 1 }
            ($1 in mine) && ($3 + 0) > now { if (m == 0 || $3 < m) m = $3 }
            END { print m + 0 }
        ' "$COOLDOWN_FILE" 2>/dev/null)
        if [[ -z "$soonest" || "$soonest" -le "$now" ]]; then
            # Ništa zaleđeno (race: cooldown istekao između provere i ovde) —
            # vrti ponovo, sledeći prolaz će izabrati par.
            continue
        fi
        wait_s=$(( soonest - now ))
        (( wait_s > 60 )) && wait_s=60
        warn "Svi kredencijali zaleđeni, čekam ${wait_s}s da cooldown istekne"
        sleep "$wait_s"
    done
}

# Kratak human-friendly tag za log poruke, npr. "[cred 2/5]". 1-based brojevi.
_cred_tag() {
    printf '[cred %d/%d]' "$((CRED_LAST_IDX + 1))" "${#CRED_JMBGS[@]}"
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
# vrati 429, ili sa back-off-om kad curl vrati 000 (DNS/TLS/connect timeout —
# tranzijentna mrežna greška, ne per-IP limit, pa rotacija ne pomaže). Sve
# druge greške (parsing, drugi non-200 HTTP kodovi) se propagiraju kao pre.
init_session() {
    local -r max_attempts=5
    local attempt=0
    while (( attempt <= max_attempts )); do
        # Hard-stop: ako je korisnik pritisnuo Ctrl-C, ne ulazi u novi pokušaj.
        [[ -f "$STOP_FLAG_FILE" ]] && return 1
        if _init_session_once; then
            return 0
        fi
        case "$INIT_SESSION_HTTP_CODE" in
            429|000) ;;
            *) return 1 ;;
        esac
        attempt=$((attempt + 1))
        if (( attempt > max_attempts )); then
            error "init_session: ${INIT_SESSION_HTTP_CODE} i posle ${max_attempts} pokušaja, odustajem"
            return 1
        fi
        if [[ "$INIT_SESSION_HTTP_CODE" == "429" && -n "$ROTATE_IP_CMD" ]]; then
            warn "init_session 429, rotiram IP (pokušaj #${attempt})"
            if ! eval "$ROTATE_IP_CMD"; then
                warn "ROTATE_IP_CMD vratio grešku (nastavljam svejedno)"
            fi
            sleep 3
        else
            local wait_s=$((2 * attempt))
            warn "init_session ${INIT_SESSION_HTTP_CODE}, čekam ${wait_s}s (pokušaj #${attempt})"
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

# Best-effort: pogađa $IP_ECHO_URL kroz iste headere/proxy kao pravi zahtevi i
# loguje izlazni IP. Drugi host od gov servera pa ne troši njegov per-IP budžet.
# Nikad ne obara obradu — ako echo servis zakaže, samo upozori.
log_egress_ip() {
    local ip
    ip=$(curl_debug -s --max-time 15 "${CORE_HEADERS[@]}" "$IP_ECHO_URL" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$ip" ]]; then
        info "Izlazni IP (curl): ${ip}"
    else
        warn "Provera izlaznog IP-a nije uspela (${IP_ECHO_URL})"
    fi
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

    # Uspeh iff HTTP 200 i body je JSON array. Sve drugo (non-200, ne-JSON,
    # redirect JSON, error HTML, prazno telo posle refresh-a) je greška —
    # callerima vraćamo non-zero da bi se razlikovala validna sesija od tihog
    # otkaza koji je ranije završavao kao "ulica sa 0 kućnih brojeva" u kešu.
    if [[ "$http_code" != "200" ]] || ! jq -e 'type == "array"' < "$body_file" > /dev/null 2>&1; then
        if [[ "$DEBUG" == "1" ]]; then
            local snippet
            snippet=$(tr '\n' ' ' < "$body_file" | cut -c1-200)
            echo "    [debug] fetch_dropdown ${endpoint} ${param_name}=${param_value} fail: HTTP=${http_code}, body=${body_len}B, snippet=${snippet}" 1>&2
        fi
        return 1
    fi
    return 0
}

# Wrapper oko fetch_dropdown-a za tree-build. fetch_dropdown sam radi jedan
# jeftin refresh_token retry; ovde dodajemo do 5 punih pokušaja sa
# init_session-om (i opcionalnom IP rotacijom) između — analogno leaf-fetch
# retry petlji u fetch_and_write_address. Empty array se tretira kao greška:
# u domenu, ulica nikad nema 0 kućnih brojeva, mesto nikad 0 ulica, opština
# nikad 0 mesta. Ranije je tihi 0-rezultat trajno korumpirao keš.
#
# $4 (context) je samo za log poruke ("lokalitet 271", "mesto X (12)", itd.).
fetch_dropdown_retry() {
    local endpoint=$1
    local param_name=$2
    local param_value=$3
    local context=$4

    local body count
    local attempt=0
    local -r max_attempts=5
    while (( attempt < max_attempts )); do
        [[ -f "$STOP_FLAG_FILE" ]] && return 1
        attempt=$((attempt + 1))
        if body=$(fetch_dropdown "$endpoint" "$param_name" "$param_value"); then
            count=$(echo "$body" | jq 'length')
            if (( count > 0 )); then
                printf '%s' "$body"
                return 0
            fi
            warn "${context}: ${endpoint} vratio prazan array (pokušaj #${attempt}/${max_attempts})"
        else
            warn "${context}: ${endpoint} neispravan odgovor (pokušaj #${attempt}/${max_attempts})"
        fi

        if (( attempt >= max_attempts )); then
            break
        fi

        # Između pokušaja: IP rotacija ako je dostupna, inače linearni backoff.
        # Onda pun init_session (kolačić + form-token + captcha).
        if [[ -n "$ROTATE_IP_CMD" ]]; then
            warn "${context}: rotiram IP pre pokušaja #$((attempt + 1))"
            if ! eval "$ROTATE_IP_CMD"; then
                warn "ROTATE_IP_CMD vratio grešku (nastavljam svejedno)"
            fi
            sleep 3
        else
            local wait_s=$((2 * attempt))
            warn "${context}: čekam ${wait_s}s pre pokušaja #$((attempt + 1))"
            sleep $wait_s
        fi
        if ! init_session; then
            warn "${context}: init_session pao u retry-u"
        fi
    done

    error "${context}: ${endpoint} neuspeo posle ${max_attempts} pokušaja"
    return 1
}

build_tree() {
    local locality_id=$1
    local tree_file="${CACHE_DIR}/tree_${locality_id}.json"

    info "Gradim stablo (mesta/ulice/kućni brojevi) za lokalitet ${locality_id}..."

    local mesta_json
    if ! mesta_json=$(fetch_dropdown_retry "DajSvaMestaZaOpstinaId" "opstinaId" "$locality_id" "lokalitet ${locality_id}"); then
        return 1
    fi

    local tree='{"localityId": '"${locality_id}"', "mesta": []}'

    local mesto_id mesto_name
    while IFS=$'\t' read -r mesto_id mesto_name; do
        [[ -z "$mesto_id" ]] && continue

        local ulice_json
        if ! ulice_json=$(fetch_dropdown_retry "DajSveUliceZaMestoId" "mestoId" "$mesto_id" "lokalitet ${locality_id}, mesto '${mesto_name}' (${mesto_id})"); then
            return 1
        fi

        local ulica_total
        ulica_total=$(echo "$ulice_json" | jq 'length') || return 1

        local ulice_with_kucni='[]'
        local ulica_count=0
        local kucni_total=0

        # Inicijalni status (pre prve iteracije). U paralelnom modu (WORKER_ID
        # postavljen) preskačemo \r-bazirane live update-ove jer bi se lomili
        # između workera; samo finalni red po mestu se ispisuje (vidi ispod).
        if [[ -z "$WORKER_ID" ]]; then
            printf "  └─ mesto %s (%s) — 0/%d ulica" "$mesto_name" "$mesto_id" "$ulica_total"
        fi

        local ulica_id ulica_name
        while IFS=$'\t' read -r ulica_id ulica_name; do
            [[ -z "$ulica_id" ]] && continue
            local kucni_json
            if ! kucni_json=$(fetch_dropdown_retry "DajSveKucneBrojeveZaUlicaId" "ulicaId" "$ulica_id" "lokalitet ${locality_id}, mesto '${mesto_name}' (${mesto_id}), ulica '${ulica_name}' (${ulica_id})"); then
                [[ -z "$WORKER_ID" ]] && echo
                return 1
            fi
            # Diagnostički guard: build_tree se zove kao `build_tree ... || return 1`
            # u load_or_build_tree, što gasi `set -e` unutar funkcije. Ako ovde
            # `kucni_json` ne parsira kao JSON array, --argjson dole crkne i tiha
            # kaskada (svaki sledeći jq dobija praznu stdin) na kraju ostavi
            # prazan tree_<id>.json. Dampujemo offending bajtove i prekidamo tree
            # build za ovaj lokalitet — zadržava postojeći keš netaknut.
            if ! printf '%s' "$kucni_json" | jq -e 'type == "array"' > /dev/null 2>&1; then
                local _bad_dump="${OUTPUT_DIR}/bad_kucni_${locality_id}_${mesto_id}_${ulica_id}.bin"
                printf '%s' "$kucni_json" > "$_bad_dump"
                error "kucni_json nije validan JSON array za ulicu '${ulica_name}' (${ulica_id}); dump: ${_bad_dump} ($(wc -c < "$_bad_dump" | tr -d ' ') bytes)"
                return 1
            fi

            local kucni_count
            kucni_count=$(echo "$kucni_json" | jq 'length') || return 1
            kucni_total=$((kucni_total + kucni_count))
            ulica_count=$((ulica_count + 1))

            ulice_with_kucni=$(echo "$ulice_with_kucni" | jq -c \
                --arg id "$ulica_id" \
                --arg name "$ulica_name" \
                --argjson kucni "$kucni_json" \
                '. + [{"id": $id, "name": $name, "kucniBrojevi": $kucni}]') || return 1

            # Live progres na istoj liniji (\r + clear-to-EOL). Samo u
            # sekvencijalnom modu — u paralelnom bi se workeri međusobno gazili.
            if [[ -z "$WORKER_ID" ]]; then
                printf "\r\033[K  └─ mesto %s (%s) — %d/%d ulica, %d kućnih brojeva (%s)" \
                    "$mesto_name" "$mesto_id" "$ulica_count" "$ulica_total" "$kucni_total" "$ulica_name"
                sleep 0.01
            fi
        done < <(echo "$ulice_json" | jq -r '.[] | "\(.Value)\t\(.Text)"')

        tree=$(echo "$tree" | jq -c \
            --arg id "$mesto_id" \
            --arg name "$mesto_name" \
            --argjson ulice "$ulice_with_kucni" \
            '.mesta += [{"id": $id, "name": $name, "ulice": $ulice}]') || return 1

        # Finalni red (sa novim redom) — sažeti rezultat za mesto. U paralelnom
        # modu prefiksujemo [W#] da se vidi koji worker piše (i izbacujemo \r
        # jer u worker modu nikada ništa nije ispisano na ovoj liniji pre).
        if [[ -n "$WORKER_ID" ]]; then
            printf "  [W%s] └─ mesto %s (%s) — %d ulica, %d kućnih brojeva\n" \
                "$WORKER_ID" "$mesto_name" "$mesto_id" "$ulica_count" "$kucni_total"
        else
            printf "\r\033[K  └─ mesto %s (%s) — %d ulica, %d kućnih brojeva\n" \
                "$mesto_name" "$mesto_id" "$ulica_count" "$kucni_total"
        fi
    done < <(echo "$mesta_json" | jq -r '.[] | "\(.Value)\t\(.Text)"')

    # Sanity check pred upis: build_tree se zove kao `build_tree ... || return 1`
    # pa `set -e` ovde ne važi; ako je iz nekog razloga $tree ostao prazan ili
    # nije validan JSON object, BEZ ovoga bismo atomski rename-ovali "" preko
    # potencijalno dobrog postojećeg keša.
    if ! printf '%s' "$tree" | jq -e 'type == "object"' > /dev/null 2>&1; then
        error "tree za lokalitet ${locality_id} nije validan JSON pred upis; ne pišem keš"
        return 1
    fi

    # Atomicno upisivanje: piši u .tmp pa rename. Ako tree-build pukne ili je
    # Ctrl-C usred zapisa, postojeći cache fajl ostaje netaknut. Bez ovoga je
    # bilo moguće dobiti polu-flush-ovan JSON na disku.
    local tmp_tree="${tree_file}.tmp.$$"
    echo "$tree" > "$tmp_tree"
    mv "$tmp_tree" "$tree_file"
    success "Stablo sačuvano: ${tree_file}"
}

load_or_build_tree() {
    local locality_id=$1
    local tree_file="${CACHE_DIR}/tree_${locality_id}.json"

    # Validacija keša pre upotrebe. Stari build_tree je tihi 0-rezultat (greška
    # servera, istek tokena, redirect JSON) konvertovao u prazan array i taj
    # pad-cache je posle ostajao zauvek. Auto-heal: ako keš sadrži praznu ulicu
    # ili prazan mesto, ignorišemo ga i gradimo iznova — kao da je REFRESH_TREE=1.
    local need_build=0
    local rebuild_reason=""
    if [[ "$REFRESH_TREE" == "1" ]]; then
        need_build=1
        rebuild_reason="REFRESH_TREE=1"
    elif [[ ! -f "$tree_file" ]]; then
        need_build=1
        rebuild_reason="keš ne postoji"
    elif ! jq empty "$tree_file" 2>/dev/null; then
        need_build=1
        rebuild_reason="keš nije validan JSON"
    else
        local empty_streets empty_mesta
        empty_streets=$(jq '[.mesta[].ulice[] | select(.kucniBrojevi | length == 0)] | length' "$tree_file" 2>/dev/null)
        empty_mesta=$(jq '[.mesta[] | select(.ulice | length == 0)] | length' "$tree_file" 2>/dev/null)
        if [[ "${empty_streets:-0}" -gt 0 ]] || [[ "${empty_mesta:-0}" -gt 0 ]]; then
            need_build=1
            rebuild_reason="korumpiran keš (${empty_streets:-0} praznih ulica, ${empty_mesta:-0} praznih mesta)"
        fi
    fi

    if [[ "$need_build" == "1" ]]; then
        # Dropdown endpointi (DajSva...) zahtevaju captcha-verifikovanu sesiju,
        # pa init samo kad zaista gradimo. Leaf-loop više ne deli ovu sesiju —
        # svaki leaf ide kroz svoj pun init_session u fetch_and_write_address.
        # Jedan init_session po lokalitetu, pa svi dropdown sub-zahtevi
        # (mesta/ulice/kućni brojevi) koriste istu sesiju.
        [[ -f "$STOP_FLAG_FILE" ]] && return 1
        select_credential || return 1
        warn "Tree-build za lokalitet ${locality_id}: ${rebuild_reason} $(_cred_tag)"
        if ! init_session; then
            cred_record_failure "$JMBG"
            error "init_session pao za tree-build lokaliteta ${locality_id} $(_cred_tag)"
            return 1
        fi
        cred_record_success "$JMBG"
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
    elif [[ "$http_code" == "200" ]] && grep -q 'СИСТЕМ ЈЕ ТРЕНУТНО НЕДОСТУПАН' "$response_file"; then
        echo "unavailable"
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

    # Povremena provera izlaznog IP-a — samo za stvarno obrađene adrese (posle
    # skip-a već urađenih). if-uslov je izuzet iz `set -e`, pa (( ... == 0 ))
    # koje vrati 1 (false) ne obara skriptu.
    LEAF_PROCESSED_COUNT=$((LEAF_PROCESSED_COUNT + 1))
    if (( IP_CHECK_INTERVAL > 0 )) && (( LEAF_PROCESSED_COUNT % IP_CHECK_INTERVAL == 1 )); then
        log_egress_ip
    fi

    local -r BACKOFF_BASE=2

    # Pun init_session (GET / + captcha + POST verifikacije + GET
    # /PretragaBiracaPoAdresi) pre SVAKOG leaf-a. Server odbija reuse sesije i
    # form-tokena posle jednog uspešnog leaf-a — vraća 200 sa
    # {"redirect":"/BiraciPoAdresi"} — pa nema smisla štedeti na inicijalizaciji.
    [[ -f "$STOP_FLAG_FILE" ]] && return 1
    # Probaj init_session redom kroz kredencijale: ako tekući par ne uspe da
    # inicira sesiju (npr. iscrpljen / rate-limited / odbijen), rotiraj na
    # sledeći par i probaj ponovo. Skip tek kad svih N parova padne u jednom
    # prolazu — tako jedan loš kredencijal ne obara ceo leaf.
    local init_try=0
    local init_max=${#CRED_JMBGS[@]}
    local init_ok=0
    while (( init_try < init_max )); do
        [[ -f "$STOP_FLAG_FILE" ]] && return 1
        select_credential || return 1
        init_try=$((init_try + 1))
        if init_session; then
            init_ok=1
            break
        fi
        cred_record_failure "$JMBG"
        warn "init_session pao za ${marker} $(_cred_tag), probam sledeći kredencijal"
    done
    if (( init_ok != 1 )); then
        warn "init_session pao za svih ${init_max} kredencijala za ${marker}, preskačem"
        return 1
    fi

    # Server često vraća 200 sa redirect JSON-om kad se prebrzo šalju leaf zahtevi — čak i sa svežom sesijom.
    sleep "$BACKOFF_BASE"

    local response_file="${TMP_DIR}/voters_address.html"
    local http_code
    http_code=$(do_leaf_request "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$response_file")
    # Prvi leaf neuspeh je sa kredencijalom izabranim u init petlji — zabeleži ga
    # pre nego što retry petlja izabere sledeći par (sprečava dvostruko brojanje).
    if [[ "$http_code" == "429" || "$http_code" == "redirect" || "$http_code" == "unavailable" ]]; then
        cred_record_failure "$JMBG"
    fi

    # Sa fresh sesijom, 429/redirect znači per-IP rate-limit. Ako je dostupna
    # IP rotacija — rotiramo i radimo nov pun init na novom IP-u. Bez nje
    # ostaje samo backoff (koji obično ne pomaže, ali ne pravi štetu).
    local attempt=0
    while [[ ( "$http_code" == "429" || "$http_code" == "redirect" || "$http_code" == "unavailable" ) && $attempt -lt 5 ]]; do
        [[ -f "$STOP_FLAG_FILE" ]] && return 1
        attempt=$((attempt + 1))
        # Svaki retry koristi sledeći NE-zaleđeni par iz pool-a. Biramo pre warn-a
        # da log poruka može da kaže koji par sledi. Neuspeh svakog pokušaja
        # (init ili leaf) beleži se odmah po nastanku za tačan kredencijal.
        select_credential || return 1
        if [[ -n "$ROTATE_IP_CMD" ]]; then
            warn "${http_code} za ${marker}, rotiram IP (pokušaj #${attempt}, $(_cred_tag))"
            if ! eval "$ROTATE_IP_CMD"; then
                warn "ROTATE_IP_CMD vratio grešku (nastavljam svejedno)"
            fi
            sleep 3
        else
            local wait_s=$((BACKOFF_BASE * attempt))
            warn "${http_code} za ${marker}, čekam ${wait_s}s (pokušaj #${attempt}, $(_cred_tag))"
            sleep $wait_s
        fi
        if ! init_session; then
            cred_record_failure "$JMBG"
            warn "init_session pao u retry-u za ${marker} $(_cred_tag)"
            continue
        fi
        http_code=$(do_leaf_request "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$response_file")
        if [[ "$http_code" == "429" || "$http_code" == "redirect" || "$http_code" == "unavailable" ]]; then
            cred_record_failure "$JMBG"
        fi
    done

    if [[ "$http_code" != "200" ]]; then
        warn "HTTP ${http_code} za ${marker} (svi pokušaji neuspeli)"
        return 1
    fi

    # HTTP 200 = kredencijal trenutno radi; resetuj njegov brojač uzastopnih
    # neuspeha (zajednički sa ostalim workerima/instancama).
    cred_record_success "$JMBG"

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
        # Validan prazan rezultat — markiraj atomično. SIGHUP uključen za slučaj
        # da terminal nestane (SSH drop, zatvaranje laptopa) usred pisanja —
        # default SIGHUP handler ubija proces i ostavlja state nesinkronizovan.
        trap '' SIGINT SIGTERM SIGHUP
        echo "$marker" >> "$state_file"
        trap 'echo ""; warn "Prekinuto. Pokreni ponovo da nastaviš sa rezimea."; exit 130' SIGINT SIGTERM SIGHUP
        return 0
    fi

    if (( n % 8 != 0 )); then
        warn "Neočekivan broj ćelija (${n}) za ${marker}, preskačem"
        return 1
    fi

    # Kritična sekcija: redovi u CSV i marker u state moraju proći zajedno.
    # Bez ovoga Ctrl-C/SIGHUP između printf-a i echo-a ostavlja CSV/state
    # nesaglasne — što je upravo izvor "stale marker" / "ponovni fetch" simptoma.
    trap '' SIGINT SIGTERM SIGHUP
    local rows_written=0
    local row_ts
    row_ts=$(date +%s)
    local j
    for (( j=0; j<n; j+=8 )); do
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$locality_id" \
            "${cells[j]}" \
            "${cells[j+1]}" \
            "${cells[j+2]}" \
            "${cells[j+3]}" \
            "${cells[j+4]}" \
            "${cells[j+5]}" \
            "${cells[j+6]}" \
            "${cells[j+7]}" \
            "$row_ts" \
            >> "$csv_file"
        rows_written=$((rows_written + 1))
    done

    echo "$marker" >> "$state_file"
    trap 'echo ""; warn "Prekinuto. Pokreni ponovo da nastaviš sa rezimea."; exit 130' SIGINT SIGTERM SIGHUP
    return 0
}

# ----------------------------------------------------------------------------
# Resume audit
# ----------------------------------------------------------------------------
# Cilj: state file da reflektuje realnost CSV-a. Dva moguća rasterećenja:
#
#   (a) marker postoji u state-u ali (Mesto, Ulica, KucniBroj) trio NIJE u CSV-u
#       — adresa je legitimno bila prazna (samo <th> ćelije) ili je tree menjan.
#       Zadržavamo marker (tako da se NE refetch-uje); za prazne adrese ovo
#       sprečava ponovni rad svakog restarta.
#
#   (b) trio postoji u CSV-u ali marker NIJE u state-u — pisanje state-a je
#       prekinuto (Ctrl-C između CSV i state writes pre nego što je kritična
#       sekcija postojala, SIGHUP, ranija verzija skripte, prekid pre f5d051e).
#       Self-heal: backfill-ujemo marker u state iz tree-a, tako da glavna
#       petlja `grep -qxF` skip-uje ovu adresu i ne pravi duplikat reda.
#
# Bez (b)-a, nakon Ctrl-C-a, gomilali smo duplikate u CSV-u na svakom restartu
# jer state nije "video" red u CSV-u. Empirijski (npr. lokalitet 271): 4809
# jedinstvenih CSV trojki, 753 state markera — 4056 adresa bi se refetch-ovalo
# pri sledećem run-u. Sa backfill-om, state se rekonstruiše iz CSV-a.
audit_state_against_csv() {
    local locality_id=$1
    local state_file=$2
    local csv_file=$3
    local tree_file=$4

    if [[ ! -f "$csv_file" ]]; then
        # Bez CSV-a nema čime da se verifikuje. Ako u state-u ima markera, to su
        # bile prazne adrese ili tree drift — zadržavamo (defensive).
        return 0
    fi

    local tmp_csv_keys="${TMP_DIR}/audit_csv_keys_${locality_id}.txt"
    local tmp_marker_map="${TMP_DIR}/audit_marker_map_${locality_id}.txt"
    local tmp_state_in="${TMP_DIR}/audit_state_in_${locality_id}.txt"
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

    if [[ -s "$state_file" ]]; then
        cp "$state_file" "$tmp_state_in"
    else
        : > "$tmp_state_in"
    fi

    awk -F'\t' \
        -v csv_keys_file="$tmp_csv_keys" \
        -v stats_file="$tmp_stats" '
        BEGIN {
            while ((getline line < csv_keys_file) > 0) csv_keys[line] = 1
            close(csv_keys_file)
        }
        # Faza 1: čitamo marker_to_key iz tree map-a.
        FNR == NR {
            marker_to_key[$1] = $2
            next
        }
        # Faza 2: čitamo postojeće state markere. Zadržavamo SVE (uključujući
        # one kojima trio nije u CSV-u — prazne adrese; i one koji nisu u tree-u
        # — defensive). Drop-ujemo samo prave duplikate (već viđeni marker).
        {
            marker = $0
            if (marker == "") next
            if (marker in seen_state) next
            seen_state[marker] = 1
            print marker
            kept++
        }
        END {
            # Faza 3: backfill — za svaki tree marker čiji je trio u CSV-u,
            # dodaj ga ako već nije u state-u.
            for (m in marker_to_key) {
                if (marker_to_key[m] in csv_keys && !(m in seen_state)) {
                    print m
                    backfilled++
                }
            }
            printf "%d\t%d\n", kept+0, backfilled+0 > stats_file
        }
    ' "$tmp_marker_map" "$tmp_state_in" > "$tmp_kept"

    local stats kept_count backfilled_count
    stats=$(cat "$tmp_stats" 2>/dev/null)
    kept_count=${stats%%$'\t'*}
    backfilled_count=${stats##*$'\t'}
    : "${kept_count:=0}"
    : "${backfilled_count:=0}"

    if (( backfilled_count > 0 )); then
        mv -f "$tmp_kept" "$state_file"
        info "Audit lokaliteta ${locality_id}: zadržano ${kept_count}, backfill iz CSV-a ${backfilled_count}"
    else
        rm -f "$tmp_kept"
        info "Audit lokaliteta ${locality_id}: zadržano ${kept_count}, backfill 0"
    fi

    rm -f "$tmp_csv_keys" "$tmp_marker_map" "$tmp_state_in" "$tmp_stats"
}

# ----------------------------------------------------------------------------
# CSV migration: backfill Timestamp kolonu u CSV-ovima nastalim pre uvođenja
# te kolone. Detekcija: header ne sadrži "Timestamp". Vrednost: mtime fajla
# (unix sekunde) — gruba aproksimacija, ali bolje nego prazno. Idempotentno —
# već migrirani fajlovi se preskaču. Zove se u main() pre nego što workeri
# krenu da pišu, da se izbegne race gde worker appenduje 10-kolonski red u
# još 9-kolonski fajl.
#
# Takođe popravlja CSV-ove oštećene ranijom verzijom ove funkcije, koja je
# (pogrešno na Linuxu) ubacivala `stat -f %m` filesystem-info blok u svaki red.
# Detekcija oštećenja: red sadrži "  File: ". Recovery uzima izvorni mtime iz
# embedded numeric line-a i prepisuje svaki data red samo prvim 9 polja + ts.
# ----------------------------------------------------------------------------
migrate_csv_timestamps() {
    local f mtime
    shopt -s nullglob
    for f in "${OUTPUT_DIR}"/biraci_po_adresi_*.csv; do
        [[ "$f" == "$COMBINED_CSV" ]] && continue
        [[ ! -s "$f" ]] && continue

        # Recovery path: prethodna verzija je upisala višeredni `stat -f`
        # output kao Timestamp vrednost. Signatura — bilo koji red sadrži
        # "  File: " (linija iz `stat -f` outputa).
        if grep -q '  File: ' "$f" 2>/dev/null; then
            local recovered_mtime
            # Originalni mtime je sačuvan kao standalone numeric line unutar
            # garbage bloka — uzmi prvi takav.
            recovered_mtime=$(awk '/^[0-9]+"$/ { sub(/"$/, "", $0); print $0; exit }' "$f")
            if [[ -z "$recovered_mtime" ]]; then
                warn "Ne mogu da izvučem originalni mtime iz $f, koristim trenutni"
                recovered_mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
            fi
            warn "Popravljam oštećenja u $f (mtime=${recovered_mtime})"
            local tmp="${f}.migrate.tmp"
            awk -v ts="$recovered_mtime" -v hdr="$CSV_HEADER" '
                BEGIN { print hdr }
                /^"[0-9]+",/ {
                    n = split($0, a, "\",\"")
                    if (n < 9) next
                    out = a[1]
                    for (i = 2; i <= 9; i++) out = out "\",\"" a[i]
                    # a[9] je BiracaBoraviste bez prateći ", jer je split
                    # konzumirao ", između nje i početka garbage-a.
                    out = out "\",\"" ts "\""
                    print out
                }
            ' "$f" > "$tmp" && mv "$tmp" "$f"
            continue
        fi

        if head -1 "$f" | grep -q 'Timestamp'; then
            continue
        fi
        # Linux GNU stat: -c %Y. macOS BSD stat: -f %m. GNU stat -f znači
        # "filesystem status" i pravi smeće — zato GNU forma ide prva.
        mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
        if [[ -z "$mtime" ]]; then
            warn "migrate_csv_timestamps: ne mogu da pročitam mtime za $f, preskačem"
            continue
        fi
        info "Migriram $f (mtime=${mtime})"
        local tmp="${f}.migrate.tmp"
        {
            echo "$CSV_HEADER"
            tail -n +2 "$f" | awk -v ts="$mtime" '{ printf "%s,\"%s\"\n", $0, ts }'
        } > "$tmp" && mv "$tmp" "$f"
    done
    shopt -u nullglob
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

    if [[ "$TREES_ONLY" == "1" ]]; then
        success "Lokalitet ${locality_id}: stablo spremno (trees-only mod)"
        return 0
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
        # Hard-stop posle Ctrl-C: ne uzimaj novu adresu. Već započete pišu se
        # atomski u kritičnoj sekciji u fetch_and_write_address.
        [[ -f "$STOP_FLAG_FILE" ]] && break
        [[ -z "$kucni_id" ]] && continue
        current=$((current + 1))
        local marker="${mesto_id}:${ulica_id}:${kucni_id}"
        if grep -qxF "$marker" "$state_file" 2>/dev/null; then
            continue
        fi

        # Sekvencijalni mod: printf bez \n + odvojeni echo na istoj liniji.
        # Paralelni mod: skupimo sve u jedan echo da različiti workeri ne bi
        # mešali "head ... " i "OK"/"FAIL" delove iste linije.
        # _cred_tag reflektuje POSLEDNJI iskorišćeni par (uključujući retry
        # rotacije), pa OK/FAIL linija pokazuje par koji je zaista pogodio server.
        if [[ -z "$WORKER_ID" ]]; then
            printf "  [%s] [%d/%d] %s ... " "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$current" "$total_leaves" "$marker"
            if fetch_and_write_address "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$csv_file" "$state_file"; then
                echo -e "${GREEN}OK${NC} $(_cred_tag)"
                processed=$((processed + 1))
            else
                echo -e "${RED}FAIL${NC} $(_cred_tag)"
            fi
        else
            local _ts="$(date +%H:%M:%S)"
            if fetch_and_write_address "$locality_id" "$mesto_id" "$ulica_id" "$kucni_id" "$csv_file" "$state_file"; then
                echo -e "  [W${WORKER_ID}] [${_ts}] [${current}/${total_leaves}] [${locality_id}] ${marker} ... ${GREEN}OK${NC} $(_cred_tag)"
                processed=$((processed + 1))
            else
                echo -e "  [W${WORKER_ID}] [${_ts}] [${current}/${total_leaves}] [${locality_id}] ${marker} ... ${RED}FAIL${NC} $(_cred_tag)"
            fi
        fi
        # Leaf endpoint je per-IP rate-limited (~5 zahteva po nepoznatom prozoru).
        # Sa ROTATE_IP_CMD: burst-uj brzo, reaguj na 429 rotacijom (default 0s).
        if [[ -n "$ROTATE_IP_CMD" ]]; then
            info "Sleep ${LEAF_SLEEP:-0}s"
            sleep "${LEAF_SLEEP:-0}"
        else
            info "Sleep ${LEAF_SLEEP:-1}s"
            sleep "${LEAF_SLEEP:-1}"
        fi
    done < <(
        jq -r '.mesta[] as $m | $m.ulice[] as $u | $u.kucniBrojevi[] | "\($m.id)\t\($u.id)\t\(.Value)"' "$tree_file"
    )

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
# Worker pool (PARALLEL)
# ----------------------------------------------------------------------------
# Svaki worker (uključujući i jedinog u PARALLEL=1 modu) ide kroz worker_init
# pa worker_loop. worker_init izoluje TMP_DIR (cookie jar i scratch fajlovi
# tako ne kolaju ni između paralelnih workera, ni između više istovremeno
# pokrenutih instanci skripte). worker_loop atomično vadi po jedan lokalitet
# iz $QUEUE_FILE-a (zaštićen mkdir-bazovanim lock-om u $QUEUE_LOCK_DIR) i
# poziva postojeću scrape_locality. Kad red postane prazan, worker se završava.
worker_init() {
    # Ključ izolacije = parent PID + WORKER_ID. Razlozi:
    #   - macOS-ov default bash je 3.2; nema BASHPID, a `$$` u subshell-u uvek
    #     vraća PID roditeljskog shella. Svi `cmd &` subshell-ovi tako dele isti
    #     `$$`, pa "per-PID" putanje ne razlikuju workere.
    #   - WORKER_ID je 1..N u paralelnom modu, prazan/0 u sekvencijalnom.
    #   - Parent PID razlikuje više istovremenih instanci skripte (svaka ima
    #     svoj PID), pa dve shell-a mogu da rade PARALLEL=N istovremeno bez
    #     kolizije nad worker_<PID>_<W> putanjama.
    local key="${$}_${WORKER_ID:-0}"
    TMP_DIR="${TMP_DIR_BASE}/worker_${key}"
    DEBUG_LOG="${OUTPUT_DIR}/debug_worker_${key}.log"
    mkdir -p "$TMP_DIR"
    [[ "$DEBUG" == "1" ]] && info "DEBUG=1: pišem u $DEBUG_LOG"
    # Workeri u paralelnom modu ne smeju svi da startuju na istom kredencijalu,
    # inače bi prvi krug leaf-ova svi tukli isti par. WORKER_ID je 1..N (paralelno)
    # ili prazno (sekvencijalno) — `${WORKER_ID:-1}-1` daje 0..N-1 odnosno 0.
    CRED_IDX=$(( ( ${WORKER_ID:-1} - 1 ) % ${#CRED_JMBGS[@]} ))
    # NAMERNO ne postavljamo EXIT trap ovde:
    #   - U PARALLEL=1 modu worker_init se zove u glavnom procesu, pa bi EXIT
    #     trap pregazio main-ov koji čisti queue/lock i sve worker_${$}_* dirove.
    #   - U PARALLEL>1 modu bash 3.2 ionako ne aktivira EXIT u backgrounded
    #     subshell-ovima, pa nema benefita od trap-a tamo.
    # Cleanup ide kroz: worker_loop eksplicitno rm-ra "$TMP_DIR" na kraju
    # (happy path) + main EXIT trap glob-čisti "${TMP_DIR_BASE}/worker_${$}"_*
    # (sve ostalo: SIGINT, set -e, kraj subshell-a, normalan kraj main-a).
}

# Atomično skida prvi red iz $QUEUE_FILE-a i ispisuje ga na stdout. Ako je red
# prazan, ispisuje praznu liniju (callsite tretira kao kraj).
#
# Lock je mkdir-bazovan jer flock(1) nije instaliran na macOS-u podrazumevano.
# mkdir je atomično na svim popularnim FS-ovima — ako uspe, mi smo vlasnici;
# ako ne uspe, neko drugi drži. Spinujemo na 100ms inkrementima do 60s; ako
# lock i posle 60s stoji, pretpostavljamo zombi-vlasnika i forsirano otimamo.
pop_locality() {
    local line=""
    local attempts=0
    local -r max_attempts=600   # 600 * 0.1s = 60s
    while ! mkdir "$QUEUE_LOCK_DIR" 2>/dev/null; do
        attempts=$((attempts + 1))
        if (( attempts >= max_attempts )); then
            warn "pop_locality: lock zaglavljen 60s, forsiram"
            rm -rf "$QUEUE_LOCK_DIR"
            mkdir "$QUEUE_LOCK_DIR" 2>/dev/null || true
            break
        fi
        sleep 0.1
    done
    if [[ -s "$QUEUE_FILE" ]]; then
        line=$(head -n 1 "$QUEUE_FILE")
        tail -n +2 "$QUEUE_FILE" > "${QUEUE_FILE}.tmp"
        mv "${QUEUE_FILE}.tmp" "$QUEUE_FILE"
    fi
    rmdir "$QUEUE_LOCK_DIR" 2>/dev/null || true
    printf '%s\n' "$line"
}

worker_loop() {
    worker_init
    local line id name
    while :; do
        # Hard-stop posle Ctrl-C: ne pop-uj novi lokalitet iz reda.
        [[ -f "$STOP_FLAG_FILE" ]] && break
        line=$(pop_locality)
        [[ -z "$line" ]] && break
        IFS=$'\t' read -r id name <<< "$line"
        [[ -z "$id" ]] && continue
        scrape_locality "$id" "$name" || true
    done
    # Eksplicitno čišćenje za happy path (vidi worker_init komentar o EXIT
    # trap-u u bash 3.2 background subshell-ovima).
    rm -rf "$TMP_DIR"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    print_banner
    check_dependencies
    setup_directories
    load_credentials
    migrate_csv_timestamps

    if [[ ! -f "$LOCALITIES_FILE" ]]; then
        error "Nedostaje fajl: $LOCALITIES_FILE"
        exit 1
    fi

    # Filter argumenata - opciono ograničavanje na navedene lokalitete.
    # --trees-only se izdvaja u TREES_ONLY globalku (čita ga scrape_locality
    # u istom procesu za PARALLEL=1, ili nasleđuje preko env-a u backgrounded
    # subshell-ovima za PARALLEL>1). Sve ostale pozicione vrednosti su locality
    # ID filteri kao i pre.
    local -a filter_ids=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --trees-only) TREES_ONLY=1 ;;
            *)            filter_ids+=("$arg") ;;
        esac
    done

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

    # Resolve PARALLEL i napuni red. Workeri vade lokalitete iz $QUEUE_FILE-a
    # (FIFO, jedan po jedan, sa flock-om) — tako se posao prirodno load-balansuje
    # između workera (worker zaglavljen na velikom gradu ne blokira ostale).
    local parallel=${PARALLEL:-1}
    if ! [[ "$parallel" =~ ^[0-9]+$ ]] || [[ "$parallel" -lt 1 ]]; then
        warn "PARALLEL='$parallel' nije validan, koristim 1"
        parallel=1
    fi
    if [[ "$parallel" -gt "$total" ]]; then
        info "PARALLEL=$parallel > broj lokaliteta ($total), spuštam na $total"
        parallel=$total
    fi

    info "Obrađujem ${total} lokaliteta sa ${parallel} worker(a)"

    : > "$QUEUE_FILE"
    rm -rf "$QUEUE_LOCK_DIR"
    local i
    for ((i=0; i<total; i++)); do
        printf '%s\t%s\n' "${locality_ids[$i]}" "${locality_names[$i]}" >> "$QUEUE_FILE"
    done

    # EXIT trap pokriva i happy path i pad: kill svih job-ova (no-op kad su već
    # gotovi), glob-čišćenje worker dirova ove instance (bash 3.2 ne aktivira
    # EXIT u backgrounded subshell-u, pa se oslanjamo na main da pokupi sve),
    # i brisanje queue fajla i lock dira. ${$} u trap-u (single quote) se širi
    # u trenutku okidanja — `$$` je stabilan tokom celog života main procesa.
    # `|| true` posle svakog koraka jer je set -e aktivan: bez njega, prva
    # komanda koja vrati non-zero (npr. kill kad nema job-ova) bi prekinula trap
    # pre nego što stignemo do brisanja queue fajla.
    trap '
        kill $(jobs -p) 2>/dev/null || true
        rm -rf "${TMP_DIR_BASE}/worker_${$}"_* 2>/dev/null || true
        rm -f "$QUEUE_FILE" 2>/dev/null || true
        rm -rf "$QUEUE_LOCK_DIR" 2>/dev/null || true
    ' EXIT

    if [[ "$parallel" -eq 1 ]]; then
        # Sekvencijalni mod: WORKER_ID nije postavljen pa logovi ostaju bez
        # [W#] prefiksa (identično ponašanje kao pre uvođenja paralelizacije).
        worker_loop
    else
        # Paralelni mod: forkujemo N background workera. SIGINT/SIGTERM trap
        # im šalje signal pre nego što main propagira exit (EXIT trap onda
        # čisti queue + dirove). Workeri imaju nasledni SIGINT/SIGTERM trap
        # iz globalnog set-a na dnu fajla — exit-uju 130 i (na bash 3.2) ne
        # čiste se sami; glob u main EXIT trap-u to pokriva.
        # Hard-stop drain: signaliziramo workerima preko flag fajla (proveravan
        # na svim loop/retry granicama), pošaljemo SIGTERM da prekinemo blocking
        # sleep ili curl --max-time wait, pa `wait`-ujemo na njih PRE exit-a.
        # Bez `wait`-a, EXIT trap niže bi `rm -rf`-ovao worker TMP_DIR-ove dok
        # workeri još koriste cookie jar / response fajlove, generišući bučne
        # greške i potencijalno gubeći već fetch-ovan response u letu.
        trap '
            echo ""
            warn "Prekinuto. Čekam workere da završe..."
            touch "$STOP_FLAG_FILE"
            kill -TERM $(jobs -p) 2>/dev/null || true
            wait
            warn "Pokreni ponovo da nastaviš sa rezimea."
            exit 130
        ' SIGINT SIGTERM
        local w
        for ((w=1; w<=parallel; w++)); do
            WORKER_ID=$w worker_loop &
        done
        wait
    fi

    if [[ "$TREES_ONLY" != "1" ]]; then
        rebuild_combined_csv
    fi

    echo ""
    success "Završeno."
}

trap 'echo ""; warn "Prekinuto. Pokreni ponovo da nastaviš sa rezimea."; exit 130' SIGINT SIGTERM

main "$@"
