#!/bin/bash

# ============================================================================
# Birački Spisak
# ============================================================================
# Ova skripta koristi zvanični veb servis za učitavanje podataka iz
# biračkog spiska:
# https://upit.birackispisak.gov.rs
#
# Skripta vodi korisnika kroz proces odabir izbora, opštine/grada,
# biračkih mesta i unosa ličnih podataka (JMBG i broj lične karte),
# zatim učitava spisak glasača i snima ih u CSV fajlove.
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration
BASE_URL="https://upit.birackispisak.gov.rs"
OUTPUT_DIR="./output"
TMP_DIR="./output/tmp"

# Print banner
print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                           Birački Spisak                          ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Print step header
print_step() {
    local step_num=$1
    local step_title=$2
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}Korak ${step_num}: ${step_title}${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Print info message
info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

# Print success message
success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Print warning message
warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Print error message
error() {
    echo -e "${RED}✗${NC} $1"
}

# Check dependencies
check_dependencies() {
    local missing_deps=()

    for cmd in curl jq sed grep; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "Nedostajući programi: ${missing_deps[*]}"
        echo ""
        echo "Molimo instalirajte ih na jedan od sledećih načina:"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        echo "  macOS:         brew install ${missing_deps[*]}"
        echo "  Fedora:        sudo dnf install ${missing_deps[*]}"
        exit 1
    fi

    success "Svi neophodni programi su već instalirani"
}

# Create output directory
setup_directories() {
    mkdir -p "$OUTPUT_DIR"
    mkdir -p "$TMP_DIR"
    success "Kreiran izlazni direktorijum: $OUTPUT_DIR"
}

# Interactive arrow-key menu selector with scrolling viewport
# Usage: select_from_menu ids_array_name names_array_name
# Returns: Sets MENU_SELECTED_INDEX to the chosen index
select_from_menu() {
    local ids_name=$1
    local names_name=$2

    # Copy arrays using eval (compatible with bash 3.x)
    eval "menu_ids=(\"\${${ids_name}[@]}\")"
    eval "menu_names=(\"\${${names_name}[@]}\")"

    local total=${#menu_ids[@]}
    local selected=0
    local viewport_size=15
    local viewport_start=0
    local key
    local i
    local display_count

    # Adjust viewport size if total items is smaller
    if [[ $total -lt $viewport_size ]]; then
        viewport_size=$total
    fi
    display_count=$viewport_size

    info "Koristite strelice GORE/DOLE za navigaciju, ENTER za potvrdu izbora"
    echo ""

    # Hide cursor
    tput civis 2>/dev/null || true

    # Draw menu with scrolling viewport
    _draw_menu() {
        local redraw=$1
        local clear_line

        # Get clear-to-end-of-line sequence
        clear_line=$(tput el 2>/dev/null || printf "\033[K")

        # Adjust viewport to keep selected item visible
        if [[ $selected -lt $viewport_start ]]; then
            viewport_start=$selected
        elif [[ $selected -ge $((viewport_start + viewport_size)) ]]; then
            viewport_start=$((selected - viewport_size + 1))
        fi

        # Calculate how many lines to draw
        display_count=$viewport_size
        if [[ $((viewport_start + viewport_size)) -gt $total ]]; then
            display_count=$((total - viewport_start))
        fi

        # Move cursor up to redraw
        if [[ $redraw -eq 1 ]]; then
            tput cuu $((viewport_size + 2)) 2>/dev/null || printf "\033[%dA" $((viewport_size + 2))
        fi

        # Show scroll indicator at top
        if [[ $viewport_start -gt 0 ]]; then
            printf "%s${CYAN}  ▲ još %d iznad${NC}\n" "$clear_line" "$viewport_start"
        else
            printf "%s\n" "$clear_line"
        fi

        # Draw visible items
        for ((i=viewport_start; i<viewport_start+viewport_size && i<total; i++)); do
            if [[ $i -eq $selected ]]; then
                printf "%s${GREEN}> [%s] %s${NC}\n" "$clear_line" "${menu_ids[$i]}" "${menu_names[$i]}"
            else
                printf "%s  [%s] %s\n" "$clear_line" "${menu_ids[$i]}" "${menu_names[$i]}"
            fi
        done

        # Pad with empty lines if needed
        for ((i=display_count; i<viewport_size; i++)); do
            printf "%s\n" "$clear_line"
        done

        # Show scroll indicator at bottom
        local remaining=$((total - viewport_start - viewport_size))
        if [[ $remaining -gt 0 ]]; then
            printf "%s${CYAN}  ▼ još %d ispod${NC}\n" "$clear_line" "$remaining"
        else
            printf "%s\n" "$clear_line"
        fi
    }

    _draw_menu 0

    while true; do
        IFS= read -rsn1 key

        if [[ $key == $'\x1b' ]]; then
            read -rsn2 -t 1 key
            case "$key" in
                '[A') ((selected > 0)) && ((selected--)) ;;
                '[B') ((selected < total - 1)) && ((selected++)) ;;
            esac
            _draw_menu 1
        elif [[ $key == "" ]]; then
            break
        fi
    done

    tput cnorm 2>/dev/null || true

    MENU_SELECTED_INDEX=$selected
}

# Step 1: Choose election
choose_elections() {
    print_step 1 "Odabir izbora"
    info "Odaberite jedan od sledećih izbora za koje želite da pretražite birački spisak:"
    echo ""

    local election_ids=(
        100 101 102 98 99 92 93 94 95 96 97 91 90 86 87 88 89 85 84 83
        67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 66
    )
    local election_names=(
        "Избори за одборнике Скупштине општине Мионица - 30.11.2025."
        "Избори за одборнике Скупштине општине Неготин - 30.11.2025."
        "Избори за одборнике Скупштине општине Сечањ - 30.11.2025."
        "Избори за одборнике Скупштине града Зајечара - 08.06.2025."
        "Избори за одборнике Скупштине општине Косјерић - 08.06.2025."
        "Избори за одборнике Скупштине града Београда - 02.06.2024."
        "Избори за одборнике скупштина градова у Републици Србији - 02.06.2024."
        "Избори за одборнике скупштина општина у Републици Србији - 02.06.2024."
        "Избори за одборнике скупштина градских општина града Београда - 02.06.2024."
        "Избори за одборнике скупштина градских општина града Ниша - 02.06.2024."
        "Избори за одборнике Скупштине градске општине Костолац - 02.06.2024."
        "Референдум - самодопринос Апатин - 07.04.2024."
        "Референдум - самодопринос Гунарош, Његошево, Стара Моравица - 03.03.2024."
        "Избори за народне посланике - 17.12.2023."
        "Избори за одборнике скупштина градова - 17.12.2023."
        "Избори за одборнике скупштина општина - 17.12.2023."
        "Избори за посланике у Скупштину АП Војводине - 17.12.2023."
        "Референдум - самодопринос Мали Београд и Томиславци - 14.05.2023."
        "Саветодавни референдум Нова Варош - 25.12.2022."
        "Референдум - самодопринос Свилајнац - 20.11.2022."
        "Избори за одборнике Скупштине градске општине Севојно - 03.04.2022."
        "Избори за народне посланике - 03.04.2022."
        "Избори за одборнике Скупштине града Београда - 03.04.2022."
        "Избори за одборнике Скупштине града Бора - 03.04.2022."
        "Избори за одборнике Скупштине општине Аранђеловац - 03.04.2022."
        "Избори за одборнике Скупштине општине Смедеревска Паланка - 03.04.2022."
        "Избори за одборнике Скупштине општине Лучани - 03.04.2022."
        "Избори за одборнике Скупштине општине Медвеђа - 03.04.2022."
        "Избори за одборнике Скупштине општине Књажевац - 03.04.2022."
        "Избори за одборнике Скупштине општине Бајина Башта - 03.04.2022."
        "Избори за одборнике Скупштине општине Дољевац - 03.04.2022."
        "Избори за одборнике Скупштине општине Кула - 03.04.2022."
        "Избори за одборнике Скупштине општине Кладово - 03.04.2022."
        "Избори за одборнике Скупштине општине Мајданпек - 03.04.2022."
        "Избори за одборнике Скупштине општине Сечањ - 03.04.2022."
        "Избори за председника Републике - 03.04.2022."
        "Републички референдум о промени Устава - 16.01.2022."
    )

    select_from_menu election_ids election_names

    ELECTION_ID="${election_ids[$MENU_SELECTED_INDEX]}"
    export ELECTION_ID

    echo ""
    success "Izabrani izbori: [${ELECTION_ID}] ${election_names[$MENU_SELECTED_INDEX]}"
}

# Step 2: Choose local community
choose_local_community() {
    print_step 2 "Odabir opštine / grada"

    info "Učitavam dostupne opštine/gradove..."
    echo ""

    # Fetch local communities from API
    local form_data="electionId=${ELECTION_ID}"
    local url="${BASE_URL}/NumberOfVotersPreview/GetJlsForElectionId"
    local response_file="${TMP_DIR}/communities_response_$(date +%Y%m%d_%H%M%S).json"

    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        -X POST \
        -d "${form_data}" \
        -o "$response_file" \
        "${url}")

    if [[ "$http_code" != "200" ]]; then
        error "Greška pri učitavanju opština/gradova (HTTP: $http_code)"
        exit 1
    fi

    # Parse JSON response into arrays using jq (bash 3.x compatible)
    community_ids=()
    community_names=()

    while IFS= read -r line; do
        community_ids+=("$line")
    done < <(jq -r '.[].Value' "$response_file")

    while IFS= read -r line; do
        community_names+=("$line")
    done < <(jq -r '.[].Text' "$response_file")

    local total=${#community_ids[@]}

    if [[ $total -eq 0 ]]; then
        error "Nema dostupnih opština/gradova za izabrane izbore."
        exit 1
    fi

    success "Učitano $total opština/gradova"
    echo ""
    info "Odaberite opštinu/grad:"
    echo ""

    select_from_menu community_ids community_names

    COMMUNITY_ID="${community_ids[$MENU_SELECTED_INDEX]}"
    COMMUNITY_NAME="${community_names[$MENU_SELECTED_INDEX]}"
    export COMMUNITY_ID COMMUNITY_NAME

    echo ""
    success "Izabrana opština/grad: [${COMMUNITY_ID}] ${COMMUNITY_NAME}"
}

# Step 3: Get polling stations
get_polling_stations() {
    print_step 3 "Učitavanje biračkih mesta"
    info "Učitavam dostupna biračka mesta za odabranu opštinu/grad..."
    echo ""

    # Fetch polling stations from API
    local form_data="electionId=${ELECTION_ID}&jlsId=${COMMUNITY_ID}"
    local url="${BASE_URL}/NumberOfVotersPreview/GetPoolingStationForJlsId"
    local response_file="${TMP_DIR}/polling_stations_response_$(date +%Y%m%d_%H%M%S).json"

    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        -X POST \
        -d "${form_data}" \
        -o "$response_file" \
        "${url}")

    if [[ "$http_code" != "200" ]]; then
        error "Greška pri učitavanju biračkih mesta (HTTP: $http_code)"
        exit 1
    fi

    # Parse JSON response into arrays using jq (bash 3.x compatible)
    polling_station_ids=()
    polling_station_names=()

    while IFS= read -r line; do
        polling_station_ids+=("$line")
    done < <(jq -r '.[].Value' "$response_file")

    while IFS= read -r line; do
        polling_station_names+=("$line")
    done < <(jq -r '.[].Text' "$response_file")

    local total=${#polling_station_ids[@]}

    if [[ $total -eq 0 ]]; then
        error "Nema dostupnih biračkih mesta za izabranu opštinu/grad."
        exit 1
    fi

    success "Učitano $total biračkih mesta"
    echo ""
}

# Step 4: Get required user info
get_user_parameters() {
    print_step 4 "Unesite neophodne podatke o sebi"

    info "Unesite podatke koji su neophodni za izvršenje upita."
    echo ""

    # JMBG
    echo -e "${BOLD}Unesite JMBG (13 cifara):${NC}"
    while true; do
        read -r JMBG
        if [[ "$JMBG" =~ ^[0-9]{13}$ ]]; then
            success "JMBG prihvaćen: $JMBG"
            break
        else
            warn "JMBG mora sadržati tačno 13 cifara. Molimo probajte ponovo:"
        fi
    done

    # ID Document number
    echo ""
    echo -e "${BOLD}Unesite broj lične karte:${NC}"
    read -r DOCUMENT_ID

    export JMBG DOCUMENT_ID
}

# Parse HTML table and extract voter names to CSV
# Usage: parse_voters_html input_html output_csv
parse_voters_html() {
    local html_file=$1
    local csv_file=$2

    # Write CSV header
    echo "Prezime,Ime" > "$csv_file"

    # Collapse HTML to single line, extract <td> contents, pair them up
    # 1. Remove newlines
    # 2. Extract just the text inside <td>...</td> tags, one per line
    # 3. Read pairs of lines (surname, firstname)
    tr '\n\r' ' ' < "$html_file" | \
    grep -o '<td[^>]*>[^<]*</td>' | \
    sed 's/<td[^>]*>//g; s/<\/td>//g' | \
    while true; do
        local surname firstname
        if ! read -r surname; then break; fi
        if ! read -r firstname; then break; fi

        # Trim whitespace
        surname=$(echo "$surname" | xargs)
        firstname=$(echo "$firstname" | xargs)

        # Skip header row
        if [[ "$surname" == "ПРЕЗИМЕ" || "$surname" == "PREZIME" ]]; then
            continue
        fi

        if [[ -n "$surname" && -n "$firstname" ]]; then
            echo "\"$surname\",\"$firstname\"" >> "$csv_file"
        fi
    done
}

# Step 5: Get voters from all polling stations
get_voters() {
    print_step 5 "Učitavanje birača sa svih biračkih mesta"
    info "Učitavam spisak birača sa svih biračkih mesta za odabranu opštinu/grad..."
    echo ""

    local total_stations=${#polling_station_ids[@]}
    local url="${BASE_URL}/ListaBiraca"
    local combined_csv="${OUTPUT_DIR}/svi_biraci_${ELECTION_ID}_${COMMUNITY_ID}.csv"
    local station_id station_name
    local i

    # Initialize combined CSV with header
    echo "Biračko mesto ID,Biračko mesto,Prezime,Ime" > "$combined_csv"

    info "Ukupno biračkih mesta: $total_stations"
    echo ""

    for ((i=0; i<total_stations; i++)); do
        station_id="${polling_station_ids[$i]}"
        station_name="${polling_station_names[$i]}"

        printf "  [%d/%d] Učitavam BM ID %s: %s..." "$((i+1))" "$total_stations" "$station_id" "$station_name"

        # Fetch voters from API
        local form_data="MupServiceResponse=DA&JMBG=${JMBG}&Document=${DOCUMENT_ID}&TipDokumenta=1&SelectedElectionId=${ELECTION_ID}&SelectedJlsId=${COMMUNITY_ID}&SelectedPollingStationsId=${station_id}"
        local response_file="${TMP_DIR}/voters_html_${station_id}.html"
        local station_csv="${OUTPUT_DIR}/biraci_${ELECTION_ID}_${COMMUNITY_ID}_${station_id}.csv"

        # info "form_data: $form_data"
        local http_code
        http_code=$(curl -s -w "%{http_code}" \
            -X POST \
            -d "${form_data}" \
            -o "$response_file" \
            -H "Referer: https://upit.birackispisak.gov.rs/PretragaBiraca" \
            "${url}")

        if [[ "$http_code" != "200" ]]; then
            echo -e " ${RED}GREŠKA (HTTP: $http_code)${NC}"
            continue
        fi

        # Parse HTML and save to individual CSV
        parse_voters_html "$response_file" "$station_csv"

        # Count voters (exclude header)
        local voter_count
        voter_count=$(($(wc -l < "$station_csv") - 1))

        # Append to combined CSV (skip header, add station info)
        tail -n +2 "$station_csv" | while IFS= read -r line; do
            echo "\"$station_id\",\"$station_name\",$line" >> "$combined_csv"
        done

        echo -e " ${GREEN}OK${NC} ($voter_count birača)"

        # Small delay to avoid overwhelming the server
        sleep 0.5
    done

    echo ""
    local total_voters
    total_voters=$(($(wc -l < "$combined_csv") - 1))
    success "Završeno! Ukupno birača: $total_voters"
    success "Kombinovani fajl: $combined_csv"
    success "Pojedinačni fajlovi: ${OUTPUT_DIR}/biraci_${ELECTION_ID}_${COMMUNITY_ID}_*.csv"
}

# Cleanup function
cleanup() {
    echo ""
    warn "Skripta je prekinuta..."
    exit 1
}

# Set up trap for cleanup
trap cleanup SIGINT SIGTERM

# Main execution
main() {
    clear
    print_banner

    echo "Ova skripta pomaže da se dobiju podaci"
    echo "o biračima iz Biračkog spiska."
    echo ""

    # Check dependencies
    check_dependencies
    setup_directories

    # Main flow
    choose_elections
    choose_local_community
    get_polling_stations
    get_user_parameters
    get_voters

    echo ""
    info "Svi podaci su sačuvani u: $OUTPUT_DIR"
}

# Run main function
main "$@"
