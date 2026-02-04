# ============================================================================
# Birački Spisak - Windows PowerShell verzija
# ============================================================================
# Ova skripta koristi zvanični veb servis za učitavanje podataka iz
# biračkog spiska:
# https://upit.birackispisak.gov.rs
#
# Skripta vodi korisnika kroz proces odabira izbora, opštine/grada,
# biračkih mesta i unosa ličnih podataka (JMBG i broj lične karte),
# zatim učitava spisak glasača i snima ih u CSV fajlove.
# ============================================================================

# Set console encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Configuration
$BASE_URL = "https://upit.birackispisak.gov.rs"
$OUTPUT_DIR = ".\output"
$TMP_DIR = ".\output\tmp"

# Colors
$Colors = @{
    Red = "Red"
    Green = "Green"
    Yellow = "Yellow"
    Blue = "Blue"
    Cyan = "Cyan"
    White = "White"
}

# Print banner
function Print-Banner {
    Write-Host ""
    Write-Host "+=================================================================+" -ForegroundColor Cyan
    Write-Host "|                         Birački Spisak                          |" -ForegroundColor Cyan
    Write-Host "+=================================================================+" -ForegroundColor Cyan
    Write-Host ""
}

# Print step header
function Print-Step {
    param([int]$StepNum, [string]$StepTitle)
    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor Blue
    Write-Host "Korak ${StepNum}: ${StepTitle}" -ForegroundColor Green
    Write-Host "===================================================================" -ForegroundColor Blue
    Write-Host ""
}

# Print messages
function Info { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }
function Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Error-Msg { param([string]$Message) Write-Host "[x] $Message" -ForegroundColor Red }

# Setup directories
function Setup-Directories {
    if (-not (Test-Path $OUTPUT_DIR)) {
        New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
    }
    if (-not (Test-Path $TMP_DIR)) {
        New-Item -ItemType Directory -Path $TMP_DIR -Force | Out-Null
    }
    Success "Kreiran izlazni direktorijum: $OUTPUT_DIR"
}

# Interactive menu selector
function Select-FromMenu {
    param(
        [array]$Ids,
        [array]$Names
    )

    $total = $Ids.Count
    $selected = 0
    $viewportSize = 15
    $viewportStart = 0

    if ($total -lt $viewportSize) {
        $viewportSize = $total
    }

    Info "Koristite strelice GORE/DOLE za navigaciju, ENTER za potvrdu izbora"
    Write-Host ""

    # Hide cursor
    [Console]::CursorVisible = $false

    # Initial draw position
    $startY = [Console]::CursorTop

    # Get console width (leave 1 char margin to prevent wrapping)
    $consoleWidth = [Console]::WindowWidth - 1

    function Draw-Menu {
        # Adjust viewport to keep selected item visible
        if ($selected -lt $viewportStart) {
            $script:viewportStart = $selected
        }
        elseif ($selected -ge ($viewportStart + $viewportSize)) {
            $script:viewportStart = $selected - $viewportSize + 1
        }

        $lineNum = 0

        # Top scroll indicator
        [Console]::SetCursorPosition(0, $startY + $lineNum)
        if ($viewportStart -gt 0) {
            $text = "  ^ jos $viewportStart iznad"
            $text = $text.PadRight($consoleWidth).Substring(0, $consoleWidth)
            Write-Host $text -ForegroundColor Cyan -NoNewline
        } else {
            Write-Host (" " * $consoleWidth) -NoNewline
        }
        $lineNum++

        # Draw visible items
        for ($i = 0; $i -lt $viewportSize; $i++) {
            [Console]::SetCursorPosition(0, $startY + $lineNum)

            $itemIndex = $viewportStart + $i
            if ($itemIndex -lt $total) {
                $id = $Ids[$itemIndex]
                $name = $Names[$itemIndex]

                # Truncate name if too long
                $maxNameLen = $consoleWidth - 10 - $id.ToString().Length
                if ($name.Length -gt $maxNameLen) {
                    $name = $name.Substring(0, $maxNameLen - 3) + "..."
                }

                $text = "  [$id] $name"
                if ($itemIndex -eq $selected) {
                    $text = "> [$id] $name"
                }
                $text = $text.PadRight($consoleWidth).Substring(0, $consoleWidth)

                if ($itemIndex -eq $selected) {
                    Write-Host $text -ForegroundColor Green -NoNewline
                } else {
                    Write-Host $text -NoNewline
                }
            } else {
                Write-Host (" " * $consoleWidth) -NoNewline
            }
            $lineNum++
        }

        # Bottom scroll indicator
        [Console]::SetCursorPosition(0, $startY + $lineNum)
        $remaining = $total - $viewportStart - $viewportSize
        if ($remaining -gt 0) {
            $text = "  v jos $remaining ispod"
            $text = $text.PadRight($consoleWidth).Substring(0, $consoleWidth)
            Write-Host $text -ForegroundColor Cyan -NoNewline
        } else {
            Write-Host (" " * $consoleWidth) -NoNewline
        }
        $lineNum++

        # Move cursor to end
        [Console]::SetCursorPosition(0, $startY + $lineNum)
    }

    Draw-Menu

    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        switch ($key.VirtualKeyCode) {
            38 { # Up arrow
                if ($selected -gt 0) { $selected-- }
                Draw-Menu
            }
            40 { # Down arrow
                if ($selected -lt ($total - 1)) { $selected++ }
                Draw-Menu
            }
            13 { # Enter
                [Console]::CursorVisible = $true
                Write-Host ""
                return $selected
            }
        }
    }
}

# Step 1: Choose election
function Choose-Elections {
    Print-Step 1 "Odabir izbora"
    Info "Odaberite jedan od sledecih izbora za koje zelite da pretrazite biracki spisak:"
    Write-Host ""

    $electionIds = @(
        100, 101, 102, 98, 99, 92, 93, 94, 95, 96, 97, 91, 90, 86, 87, 88, 89, 85, 84, 83,
        67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 66
    )
    $electionNames = @(
        "Izbori za odbornike Skupstine opstine Mionica - 30.11.2025."
        "Izbori za odbornike Skupstine opstine Negotin - 30.11.2025."
        "Izbori za odbornike Skupstine opstine Secanj - 30.11.2025."
        "Izbori za odbornike Skupstine grada Zajecara - 08.06.2025."
        "Izbori za odbornike Skupstine opstine Kosjeric - 08.06.2025."
        "Izbori za odbornike Skupstine grada Beograda - 02.06.2024."
        "Izbori za odbornike skupstina gradova u Republici Srbiji - 02.06.2024."
        "Izbori za odbornike skupstina opstina u Republici Srbiji - 02.06.2024."
        "Izbori za odbornike skupstina gradskih opstina grada Beograda - 02.06.2024."
        "Izbori za odbornike skupstina gradskih opstina grada Nisa - 02.06.2024."
        "Izbori za odbornike Skupstine gradske opstine Kostolac - 02.06.2024."
        "Referendum - samodoprinosi Apatin - 07.04.2024."
        "Referendum - samodoprinosi Gunaros, Njegosevo, Stara Moravica - 03.03.2024."
        "Izbori za narodne poslanike - 17.12.2023."
        "Izbori za odbornike skupstina gradova - 17.12.2023."
        "Izbori za odbornike skupstina opstina - 17.12.2023."
        "Izbori za poslanike u Skupstinu AP Vojvodine - 17.12.2023."
        "Referendum - samodoprinosi Mali Beograd i Tomislavci - 14.05.2023."
        "Savetodavni referendum Nova Varos - 25.12.2022."
        "Referendum - samodoprinosi Svilajnac - 20.11.2022."
        "Izbori za odbornike Skupstine gradske opstine Sevojno - 03.04.2022."
        "Izbori za narodne poslanike - 03.04.2022."
        "Izbori za odbornike Skupstine grada Beograda - 03.04.2022."
        "Izbori za odbornike Skupstine grada Bora - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Arandjelovac - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Smederevska Palanka - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Lucani - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Medvedja - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Knjazevac - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Bajina Basta - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Doljevac - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Kula - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Kladovo - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Majdanpek - 03.04.2022."
        "Izbori za odbornike Skupstine opstine Secanj - 03.04.2022."
        "Izbori za predsednika Republike - 03.04.2022."
        "Republicki referendum o promeni Ustava - 16.01.2022."
    )

    $selectedIndex = Select-FromMenu -Ids $electionIds -Names $electionNames

    $script:ELECTION_ID = $electionIds[$selectedIndex]

    Write-Host ""
    Success "Izabrani izbori: [$ELECTION_ID] $($electionNames[$selectedIndex])"
}

# Step 2: Choose local community
function Choose-LocalCommunity {
    Print-Step 2 "Odabir opstine / grada"
    Info "Ucitavam dostupne opstine/gradove..."
    Write-Host ""

    $url = "$BASE_URL/NumberOfVotersPreview/GetJlsForElectionId"
    $body = "electionId=$ELECTION_ID"

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        Error-Msg "Greska pri ucitavanju opstina/gradova: $_"
        exit 1
    }

    $communityIds = @()
    $communityNames = @()

    foreach ($item in $response) {
        $communityIds += $item.Value
        $communityNames += $item.Text
    }

    if ($communityIds.Count -eq 0) {
        Error-Msg "Nema dostupnih opstina/gradova za izabrane izbore."
        exit 1
    }

    Success "Ucitano $($communityIds.Count) opstina/gradova"
    Write-Host ""
    Info "Odaberite opstinu/grad:"
    Write-Host ""

    $selectedIndex = Select-FromMenu -Ids $communityIds -Names $communityNames

    $script:COMMUNITY_ID = $communityIds[$selectedIndex]
    $script:COMMUNITY_NAME = $communityNames[$selectedIndex]

    Write-Host ""
    Success "Izabrana opstina/grad: [$COMMUNITY_ID] $COMMUNITY_NAME"
}

# Step 3: Get polling stations
function Get-PollingStations {
    Print-Step 3 "Ucitavanje birackih mesta"
    Info "Ucitavam dostupna biracka mesta za odabranu opstinu/grad..."
    Write-Host ""

    $url = "$BASE_URL/NumberOfVotersPreview/GetPoolingStationForJlsId"
    $body = "electionId=$ELECTION_ID&jlsId=$COMMUNITY_ID"

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        Error-Msg "Greska pri ucitavanju birackih mesta: $_"
        exit 1
    }

    $script:pollingStationIds = @()
    $script:pollingStationNames = @()

    foreach ($item in $response) {
        $script:pollingStationIds += $item.Value
        $script:pollingStationNames += $item.Text
    }

    if ($pollingStationIds.Count -eq 0) {
        Error-Msg "Nema dostupnih birackih mesta za izabranu opstinu/grad."
        exit 1
    }

    Success "Ucitano $($pollingStationIds.Count) birackih mesta"
    Write-Host ""
}

# Step 4: Get user parameters
function Get-UserParameters {
    Print-Step 4 "Unesite neophodne podatke o sebi"
    Info "Unesite podatke koji su neophodni za izvrsenje upita."
    Write-Host ""

    # JMBG
    Write-Host "Unesite JMBG (13 cifara):" -ForegroundColor White
    while ($true) {
        $script:JMBG = Read-Host
        if ($JMBG -match '^\d{13}$') {
            Success "JMBG prihvacen: $JMBG"
            break
        } else {
            Warn "JMBG mora sadrzati tacno 13 cifara. Molimo probajte ponovo:"
        }
    }

    # Document ID
    Write-Host ""
    Write-Host "Unesite broj licne karte:" -ForegroundColor White
    $script:DOCUMENT_ID = Read-Host
}

# Parse HTML and extract voters
function Parse-VotersHtml {
    param([string]$HtmlContent, [string]$CsvFile)

    # Write header
    "Prezime,Ime" | Out-File -FilePath $CsvFile -Encoding UTF8

    # Extract td contents using regex
    $matches = [regex]::Matches($HtmlContent, '<td[^>]*>([^<]*)</td>')

    $values = @()
    foreach ($match in $matches) {
        $values += $match.Groups[1].Value.Trim()
    }

    # Process pairs (surname, firstname)
    for ($i = 0; $i -lt $values.Count - 1; $i += 2) {
        $surname = $values[$i]
        $firstname = $values[$i + 1]

        # Skip header
        if ($surname -eq "PREZIME" -or $surname -eq "ПРЕЗИМЕ") {
            continue
        }

        if ($surname -and $firstname) {
            "`"$surname`",`"$firstname`"" | Out-File -FilePath $CsvFile -Encoding UTF8 -Append
        }
    }
}

# Step 5: Get voters
function Get-Voters {
    Print-Step 5 "Ucitavanje biraca sa svih birackih mesta"
    Info "Ucitavam spisak biraca sa svih birackih mesta za odabranu opstinu/grad..."
    Write-Host ""

    $totalStations = $pollingStationIds.Count
    $url = "$BASE_URL/ListaBiraca"
    $combinedCsv = "$OUTPUT_DIR\svi_biraci_${ELECTION_ID}_${COMMUNITY_ID}.csv"

    # Initialize combined CSV
    "Biracko mesto ID,Biracko mesto,Prezime,Ime" | Out-File -FilePath $combinedCsv -Encoding UTF8

    Info "Ukupno birackih mesta: $totalStations"
    Write-Host ""

    for ($i = 0; $i -lt $totalStations; $i++) {
        $stationId = $pollingStationIds[$i]
        $stationName = $pollingStationNames[$i]

        Write-Host "  [$($i+1)/$totalStations] Ucitavam BM ID ${stationId}: ${stationName}..." -NoNewline

        $body = "MupServiceResponse=DA&JMBG=$JMBG&Document=$DOCUMENT_ID&TipDokumenta=1&SelectedElectionId=$ELECTION_ID&SelectedJlsId=$COMMUNITY_ID&SelectedPollingStationsId=$stationId"
        $responseFile = "$TMP_DIR\voters_html_$stationId.html"
        $stationCsv = "$OUTPUT_DIR\biraci_${ELECTION_ID}_${COMMUNITY_ID}_${stationId}.csv"

        try {
            $headers = @{
                "Referer" = "https://upit.birackispisak.gov.rs/PretragaBiraca"
            }
            $response = Invoke-WebRequest -Uri $url -Method Post -Body $body -ContentType "application/x-www-form-urlencoded" -Headers $headers
            $response.Content | Out-File -FilePath $responseFile -Encoding UTF8

            # Parse HTML
            Parse-VotersHtml -HtmlContent $response.Content -CsvFile $stationCsv

            # Count voters
            $voterCount = (Get-Content $stationCsv | Measure-Object -Line).Lines - 1

            # Append to combined CSV
            Get-Content $stationCsv | Select-Object -Skip 1 | ForEach-Object {
                "`"$stationId`",`"$stationName`",$_" | Out-File -FilePath $combinedCsv -Encoding UTF8 -Append
            }

            Write-Host " OK ($voterCount biraca)" -ForegroundColor Green
        }
        catch {
            Write-Host " GRESKA: $_" -ForegroundColor Red
        }

        # Small delay
        Start-Sleep -Milliseconds 500
    }

    Write-Host ""
    $totalVoters = (Get-Content $combinedCsv | Measure-Object -Line).Lines - 1
    Success "Zavrseno! Ukupno biraca: $totalVoters"
    Success "Kombinovani fajl: $combinedCsv"
    Success "Pojedinacni fajlovi: $OUTPUT_DIR\biraci_${ELECTION_ID}_${COMMUNITY_ID}_*.csv"
}

# Main execution
function Main {
    Clear-Host
    Print-Banner

    Write-Host "Ova skripta pomaze da se dobiju podaci"
    Write-Host "o biracima iz Birackog spiska."
    Write-Host ""

    Setup-Directories

    Choose-Elections
    Choose-LocalCommunity
    Get-PollingStations
    Get-UserParameters
    Get-Voters

    Write-Host ""
    Info "Svi podaci su sacuvani u: $OUTPUT_DIR"
}

# Run
Main
