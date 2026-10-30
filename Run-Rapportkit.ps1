<#
.SYNOPSIS
  Rapportkit: hämtar verktygen, loggar in, kör tre read-only rapportverktyg mot en Azure-tenant
  och sammanfattar resultatet i en HTML-rapport.

.DESCRIPTION
  Scriptet gör följande, i ordning (varje steg skriver ut vad som händer medan det körs):

    Steg 1  Förberedelser    Tenant-ID, resultatmappar, loggfil
    Steg 2  Beroenden        Laddar ner och installerar det som saknas på den här datorn:
                               - PowerShell 7           (winget)
                               - Azure CLI              (winget)
                               - azqr                   (winget, annars direktnedladdning från GitHub)
                               - Azure Governance Visualizer (zip från GitHub)
                               - PowerShell-moduler Az.Accounts, AzAPICall, Pester, Maester (PSGallery)
    Steg 3  Inloggning       Azure CLI, Az PowerShell och (valfritt) Microsoft Graph
    Steg 4  Governance Visualizer   Management groups, policies, rolltilldelningar
    Steg 5  azqr                    Rekommendationer per resurs + Advisor + Defender
    Steg 6  Maester                 Tester av Entra ID (valfritt)
    Steg 7  HTML-rapport     Sammanfattning i <resultatmapp>\rapport.html

  Allt är read-only: inget i Azure eller Entra ändras. Det som installeras hamnar på den här
  datorn (program via winget, moduler i <OutputRoot>\_modules).

.PARAMETER TenantId
  Tenant-ID (GUID). Frågas efter om det inte anges.
.PARAMETER ManagementGroupId
  Management group som Governance Visualizer startar på. Standard är tenant root (= tenant-ID).
.PARAMETER OutputRoot
  Rotmapp för resultat och hämtade verktyg. Standard C:\rapportkit.
.PARAMETER Period
  Namn på undermappen för den här körningen. Standard är innevarande månad (yyyy-MM).
.PARAMETER SkipGovViz / SkipAzqr / SkipMaester
  Hoppa över respektive verktyg.
.PARAMETER NoPIMEligibility
  Skicka vidare -NoPIMEligibility till Governance Visualizer (använd om det stoppar på PIM).
.PARAMETER DeviceLogin
  Logga in med kod (https://login.microsoft.com/device) istället för webbläsarfönster.
.PARAMETER NoInstall
  Installera/hämta ingenting; använd bara det som redan finns.
.PARAMETER Offline
  Ladda inte ner något från internet; använd bara mappen tools\ (se Build-Bundle.ps1).
.PARAMETER ReportOnly
  Kör inga verktyg, bygg bara om HTML-rapporten från befintliga resultat.

.EXAMPLE
  .\Run-Rapportkit.ps1
.EXAMPLE
  .\Run-Rapportkit.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -SkipMaester
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ManagementGroupId,
    [string]$OutputRoot = 'C:\rapportkit',
    [string]$Period = (Get-Date -Format 'yyyy-MM'),
    [switch]$SkipGovViz,
    [switch]$SkipAzqr,
    [switch]$SkipMaester,
    [switch]$NoPIMEligibility,
    [switch]$DeviceLogin,
    [switch]$NoInstall,
    [switch]$Offline,
    [switch]$ReportOnly
)

# Avbryt vid fel som standard; enskilda verktygssteg fångar sina egna fel (try/catch) så att
# ett misslyckat verktyg inte stoppar de andra.
$ErrorActionPreference = 'Stop'
# Nedladdningar går mycket snabbare i Windows PowerShell utan förloppsindikatorn.
$ProgressPreference = 'SilentlyContinue'

$ScriptRoot = Split-Path -Parent $PSCommandPath
$ToolsDir = Join-Path $ScriptRoot 'tools'        # används bara för offline-bundle
$TotalSteps = 7

# ===========================================================================
# Hjälpfunktioner för utskrift. Varje åtgärd skriver en rad så att man ser vad som händer.
# ===========================================================================

# Rubrik för ett huvudsteg, med förklaring av vad steget gör och ungefär hur länge det tar.
function Write-Step([int]$Number, [string]$Title, [string]$Explain) {
    Write-Host ''
    Write-Host ("=== Steg {0}/{1}: {2} ===" -f $Number, $TotalSteps, $Title) -ForegroundColor Cyan
    if ($Explain) { Write-Host "    $Explain" -ForegroundColor DarkCyan }
}
# En enskild åtgärd inom ett steg ("nu gör jag detta").
function Write-Action($msg) { Write-Host "  -> $msg" -ForegroundColor White }
# Bekräftelse att något gick bra.
function Write-Ok($msg)     { Write-Host "  [OK] $msg" -ForegroundColor Green }
# Varning: något gick fel men scriptet fortsätter.
function Write-Warn2($msg)  { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
# Instruktion till den som kör scriptet (något de själva måste göra).
function Write-Todo($msg)   { Write-Host "  >>> $msg" -ForegroundColor Magenta }

# Läser om PATH från registret så att nyinstallerade program (az, azqr, pwsh) hittas direkt,
# utan att man behöver starta om fönstret.
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# Finns kommandot på datorn?
function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Laddar ner en fil från internet (eller stoppar om -Offline är satt).
function Get-Download([string]$Url, [string]$Dest) {
    if ($Offline) { throw "Offline-läge: kan inte ladda ner $Url" }
    Write-Action "Laddar ner $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Dest -Headers @{ 'User-Agent' = 'azure-rapportkit' }
}

# Installerar ett program med winget. Winget är det som följer med Windows 11 / uppdaterad Windows 10.
function Install-WithWinget([string]$Name, [string]$Id) {
    if (-not (Test-Cmd winget)) { throw "winget saknas, så $Name kan inte installeras automatiskt. Installera $Name manuellt och kör scriptet igen." }
    Write-Action "winget install $Id  (kan öppna ett godkännande-fönster, tryck Ja)"
    winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Host
    Update-SessionPath
}

# Hämtar en PowerShell-modul till vår egen modulmapp ($ModDir) och gör den sökbar.
# Egen mapp används för att undvika problem när Dokument är omdirigerat till OneDrive.
function Install-PsModule([string]$Name, [string]$Version) {
    if (Get-Module -ListAvailable -Name $Name) { Write-Ok "Modul $Name finns redan"; return }
    if (Test-Path "$ToolsDir\modules\$Name") {            # offline-bundle
        Write-Action "Kopierar modul $Name från tools\modules"
        Copy-Item "$ToolsDir\modules\$Name" $ModDir -Recurse -Force
    }
    elseif (-not $Offline) {
        Write-Action "Hämtar modul $Name $Version från PowerShell Gallery"
        if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
            $p = @{ Name = $Name; Path = $ModDir; TrustRepository = $true; Quiet = $true }
            if ($Version) { $p.Version = $Version }
            Save-PSResource @p
        }
        else {
            Install-PackageProvider NuGet -Scope CurrentUser -Force | Out-Null
            $p = @{ Name = $Name; Path = $ModDir; Force = $true }
            if ($Version) { $p.RequiredVersion = $Version }
            Save-Module @p
        }
    }
    else { throw "Modulen $Name finns inte i tools\modules och -Offline är satt." }
    Write-Ok "Modul $Name klar"
}

# ===========================================================================
# Bootstrap: allt nedan kräver PowerShell 7. Körs scriptet i Windows PowerShell 5.1
# installeras PowerShell 7 och scriptet startas om där med samma parametrar.
# ===========================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host '=== Startar: PowerShell 7 krävs ===' -ForegroundColor Cyan
    Write-Host '    Du kör Windows PowerShell 5.1. Verktygen kräver PowerShell 7.' -ForegroundColor DarkCyan
    Update-SessionPath
    if (-not (Test-Cmd pwsh)) {
        if ($NoInstall -or $Offline) { throw 'PowerShell 7 saknas och installation är avstängd (-NoInstall/-Offline).' }
        Install-WithWinget 'PowerShell 7' 'Microsoft.PowerShell'
    }
    # Bygg om parametrarna så att de skickas vidare till den nya processen.
    $fwd = @()
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $fwd += "-$k" } } else { $fwd += "-$k"; $fwd += "$v" }
    }
    Write-Action 'Startar om scriptet i PowerShell 7'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    exit $LASTEXITCODE
}

# ===========================================================================
# STEG 1: Förberedelser
# ===========================================================================
Write-Step 1 'Förberedelser' 'Tenant-ID, mappar och loggfil. Tar några sekunder.'
Update-SessionPath

# Egen modulmapp, tillagd först i modulsökvägen för den här sessionen.
$ModDir = Join-Path $OutputRoot '_modules'
New-Item -ItemType Directory -Force $ModDir | Out-Null
if ($env:PSModulePath -notlike "*$ModDir*") { $env:PSModulePath = "$ModDir;$env:PSModulePath" }

# Tenant-ID: använd parametern, annars föreslå det Azure CLI redan är inloggat mot.
if (-not $TenantId) {
    $guess = $null
    if (Test-Cmd az) { $guess = az account show --query tenantId -o tsv 2>$null }
    $prompt = 'Ange tenant-ID (Entra ID > Overview > Tenant ID)'
    if ($guess) { $prompt += " [Enter = $guess]" }
    $TenantId = Read-Host $prompt
    if (-not $TenantId) { $TenantId = $guess }
}
if ($TenantId -notmatch '^[0-9a-fA-F-]{36}$') { throw "Ogiltigt tenant-ID: '$TenantId' (förväntar ett GUID)" }
Write-Ok "Tenant: $TenantId"

# Resultatmappar: en per verktyg under <OutputRoot>\<Period>\
$RunDir = Join-Path $OutputRoot $Period
$Dirs = @{}
foreach ($n in 'azgovviz', 'azqr', 'maester', 'portal') {
    $Dirs[$n] = Join-Path $RunDir $n
    New-Item -ItemType Directory -Force $Dirs[$n] | Out-Null
}
Write-Ok "Resultatmapp: $RunDir"

# Logga allt som skrivs i fönstret till en fil (bra att skicka med vid felsökning).
Start-Transcript -Path (Join-Path $RunDir 'rapportkit.log') -Append | Out-Null

# Status per verktyg, visas överst i rapporten.
$Status = [ordered]@{}
function Set-Status($step, $state, $note = '') { $Status[$step] = @{ State = $state; Note = $note } }

if (-not $ReportOnly) {

    # =======================================================================
    # STEG 2: Beroenden
    # =======================================================================
    Write-Step 2 'Hämtar och installerar beroenden' 'Bara det som saknas på den här datorn. Första gången tar det 5-10 minuter.'
    if ($NoInstall) { Write-Warn2 '-NoInstall: hoppar över all installation' }
    else {
        # Azure CLI: används för inloggning och som underlag till azqr.
        if (Test-Cmd az) { Write-Ok 'Azure CLI finns redan' }
        else { Install-WithWinget 'Azure CLI' 'Microsoft.AzureCLI' }

        # azqr: först winget, annars hämtas senaste releasen direkt från GitHub.
        if (-not $SkipAzqr) {
            if (Test-Cmd azqr) { Write-Ok 'azqr finns redan' }
            else {
                try { Install-WithWinget 'azqr' 'Microsoft.Azure.QuickReview' }
                catch {
                    Write-Warn2 "winget misslyckades ($($_.Exception.Message)). Hämtar azqr direkt från GitHub."
                    $zip = Join-Path $env:TEMP 'azqr.zip'
                    if (Test-Path "$ToolsDir\azqr.zip") { Copy-Item "$ToolsDir\azqr.zip" $zip -Force }
                    else {
                        $rel = Invoke-RestMethod 'https://api.github.com/repos/Azure/azqr/releases/latest' -Headers @{ 'User-Agent' = 'azure-rapportkit' }
                        $asset = $rel.assets | Where-Object name -like 'azqr-win-amd64.zip' | Select-Object -First 1
                        Get-Download $asset.browser_download_url $zip
                    }
                    $azqrDir = Join-Path $env:LOCALAPPDATA 'azqr'
                    Expand-Archive $zip $azqrDir -Force
                    $env:Path += ";$azqrDir"
                }
            }
        }

        # Azure Governance Visualizer: ett PowerShell-script i en GitHub-repo. Vi hämtar zip-filen
        # (kräver inte git).
        if (-not $SkipGovViz) {
            $GvDir = Join-Path $OutputRoot 'Azure-Governance-Visualizer'
            if (Test-Path (Join-Path $GvDir 'pwsh\AzGovVizParallel.ps1')) { Write-Ok 'Governance Visualizer finns redan' }
            else {
                $zip = Join-Path $env:TEMP 'azgovviz.zip'
                if (Test-Path "$ToolsDir\AzGovViz.zip") { Copy-Item "$ToolsDir\AzGovViz.zip" $zip -Force }
                else { Get-Download 'https://github.com/Azure/Azure-Governance-Visualizer/archive/refs/heads/main.zip' $zip }
                $tmp = Join-Path $OutputRoot '_gv_tmp'
                if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
                Expand-Archive $zip $tmp -Force
                Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $GvDir
                Remove-Item $tmp -Recurse -Force
                Write-Ok "Governance Visualizer hämtad till $GvDir"
            }
            # Az.Accounts = inloggning för Az PowerShell. AzAPICall = hjälpmodul som AzGovViz kräver (exakt version).
            Install-PsModule 'Az.Accounts'
            Install-PsModule 'AzAPICall' '1.4.1'
        }

        # Maester + Pester (testramverket Maester bygger på).
        if (-not $SkipMaester) { Install-PsModule 'Pester'; Install-PsModule 'Maester' }
    }

    # =======================================================================
    # STEG 3: Inloggning
    # =======================================================================
    Write-Step 3 'Inloggning' 'Du loggar in med ett konto som har läsrättigheter (se README). Ett webbläsarfönster öppnas för varje inloggning.'
    $azOk = $false

    # 3a. Azure CLI (används av azqr)
    if (Test-Cmd az) {
        $cur = az account show --query tenantId -o tsv 2>$null
        if ($cur -eq $TenantId) { Write-Ok 'Azure CLI är redan inloggad mot rätt tenant' }
        else {
            Write-Todo 'Logga in i webbläsarfönstret som öppnas (Azure CLI)...'
            if ($DeviceLogin) { az login --tenant $TenantId --use-device-code --only-show-errors | Out-Null }
            else              { az login --tenant $TenantId --only-show-errors | Out-Null }
        }
        $azOk = ((az account show --query tenantId -o tsv 2>$null) -eq $TenantId)
        if ($azOk) { Write-Ok 'Azure CLI inloggad' } else { Write-Warn2 'Azure CLI-inloggning misslyckades' }
    }

    # 3b. Az PowerShell (används av Governance Visualizer)
    if (-not $SkipGovViz) {
        Import-Module Az.Accounts -ErrorAction SilentlyContinue
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        # En AccessToken-session kan inte förnyas, och Governance Visualizer behöver det: logga in på nytt.
        if ($ctx -and $ctx.Tenant.Id -eq $TenantId -and $ctx.Account.Type -ne 'AccessToken') { Write-Ok 'Az PowerShell är redan inloggad' }
        else {
            Write-Todo 'Logga in igen (Az PowerShell)...'
            if ($DeviceLogin) { Connect-AzAccount -TenantId $TenantId -UseDeviceAuthentication | Out-Null }
            else              { Connect-AzAccount -TenantId $TenantId | Out-Null }
            Write-Ok 'Az PowerShell inloggad'
        }
    }

    # 3c. Microsoft Graph för Maester (valfritt; kräver admin consent första gången)
    if (-not $SkipMaester) {
        Write-Host '  Maester läser Entra ID via Microsoft Graph. Första gången måste en Global Administrator godkänna behörigheterna.'
        $ans = Read-Host '  Logga in till Microsoft Graph för Maester nu? (j/N)'
        if ($ans -notmatch '^[jJyY]') { $SkipMaester = $true; Set-Status 'Maester' 'Hoppad över' 'Valdes bort vid inloggningsfrågan' }
        else {
            try { Connect-Maester -TenantId $TenantId | Out-Null; Write-Ok 'Microsoft Graph inloggad' }
            catch { $SkipMaester = $true; Set-Status 'Maester' 'Fel' "Graph-inloggning: $($_.Exception.Message)"; Write-Warn2 $_.Exception.Message }
        }
    }

    # =======================================================================
    # STEG 4: Azure Governance Visualizer
    # =======================================================================
    Write-Step 4 'Azure Governance Visualizer' 'Går igenom management groups, subscriptions, policies och roller. 10-45 min i stora miljöer, några minuter i små. Mycket text i fönstret är normalt.'
    if ($SkipGovViz) { Write-Action 'Hoppas över (-SkipGovViz)'; Set-Status 'Governance Visualizer' 'Hoppad över' }
    else {
        try {
            $gvScript = Join-Path $GvDir 'pwsh\AzGovVizParallel.ps1'
            # AzGovViz kontrollerar sina moduler med Get-InstalledModule och ställer en y/n-fråga om de
            # saknas. Det fungerar inte utan admin och hänger utan tangentbord, så vi hoppar över
            # kontrollen för moduler som redan finns i vår modulmapp (patch av den hämtade kopian).
            $src = Get-Content $gvScript -Raw
            if ($src -notmatch 'RAPPORTKIT-PATCH') {
                $marker = '$moduleVersion = $module.ModuleVersion'
                $patched = $src.Replace($marker, "if (Get-Module -ListAvailable -Name `$module.ModuleName) { Write-Host '  (rapportkit) modul finns, hoppar över verifiering'; continue } # RAPPORTKIT-PATCH`n        $marker")
                if ($patched -eq $src) { Write-Warn2 'Kunde inte patcha modulkontrollen i AzGovViz (kan fråga y/n)' }
                Set-Content $gvScript $patched -Encoding utf8
            }
            $mg = if ($ManagementGroupId) { $ManagementGroupId } else { $TenantId }
            Write-Action "Kör AzGovVizParallel.ps1 mot management group '$mg'"
            $gvArgs = @{ ManagementGroupId = $mg; OutputPath = $Dirs.azgovviz }
            if ($NoPIMEligibility) { $gvArgs.NoPIMEligibility = $true }
            & $gvScript @gvArgs
            Set-Status 'Governance Visualizer' 'OK'
            Write-Ok 'Governance Visualizer klar'
        }
        catch {
            Write-Warn2 $_.Exception.Message
            Set-Status 'Governance Visualizer' 'Fel' ($_.Exception.Message + ' Vanlig orsak: Reader saknas på Tenant Root Group (se README), eller ange -ManagementGroupId. Stoppar det på PIM: kör med -NoPIMEligibility.')
        }
    }

    # =======================================================================
    # STEG 5: azqr
    # =======================================================================
    Write-Step 5 'Azure Quick Review (azqr)' 'Skannar alla subscriptions du har läsrätt till. 1-30 min.'
    if ($SkipAzqr) { Write-Action 'Hoppas över (-SkipAzqr)'; Set-Status 'azqr' 'Hoppad över' }
    else {
        try {
            Push-Location $Dirs.azqr
            Write-Action 'Kör: azqr scan --json --csv --xlsx'
            # --json/--csv gör att vi kan läsa resultatet i HTML-rapporten; --xlsx är den fullständiga rapporten.
            azqr scan --json --csv --xlsx -o "azqr_$Period" 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "azqr avslutades med kod $LASTEXITCODE" }
            Set-Status 'azqr' 'OK'
            Write-Ok 'azqr klar'
        }
        catch { Write-Warn2 $_.Exception.Message; Set-Status 'azqr' 'Fel' $_.Exception.Message }
        finally { Pop-Location }
    }

    # =======================================================================
    # STEG 6: Maester
    # =======================================================================
    Write-Step 6 'Maester (Entra ID-tester)' 'Valfritt. 10-20 min.'
    if ($SkipMaester) { Write-Action 'Hoppas över'; if (-not $Status.Contains('Maester')) { Set-Status 'Maester' 'Hoppad över' } }
    else {
        try {
            Push-Location $Dirs.maester
            $testsDir = Join-Path $Dirs.maester 'maester-tests'
            if (-not (Test-Path $testsDir)) { Write-Action 'Hämtar Maesters testsvit (Install-MaesterTests)'; Install-MaesterTests }
            Write-Action 'Kör Invoke-Maester'
            Invoke-Maester -Path $testsDir -OutputFolder (Join-Path $Dirs.maester 'test-results') `
                -OutputJsonFile (Join-Path $Dirs.maester 'test-results\maester.json') -NonInteractive -PassThru | Out-Null
            Set-Status 'Maester' 'OK'
            Write-Ok 'Maester klar'
        }
        catch { Write-Warn2 $_.Exception.Message; Set-Status 'Maester' 'Fel' $_.Exception.Message }
        finally { Pop-Location }
    }
}

# ===========================================================================
# STEG 7: HTML-rapport
# ===========================================================================
Write-Step 7 'Bygger HTML-rapport' 'Läser resultatfilerna och skriver rapport.html.'
Add-Type -AssemblyName System.Web

# HTML-koda text. (Får inte heta H: det är ett alias för Get-History.)
function Esc($s) { [System.Web.HttpUtility]::HtmlEncode([string]$s) }

# Bygger en HTML-tabell av objekt. $cols = lista med @{Name=<egenskap>; Label=<rubrik>}.
function ConvertTo-HtmlTable($rows, $cols, $max = 25) {
    if (-not $rows) { return '<p class="muted">Inga rader.</p>' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $cols) { [void]$sb.Append("<th>$(Esc $c.Label)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in @($rows) | Select-Object -First $max) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) {
            $v = $r.($c.Name)
            $cls = ''
            # Impact/Result visas som färgade märken.
            if ($c.Name -in 'Impact', 'Result') { $cls = " class=`"pill $(([string]$v).ToLower())`"" }
            [void]$sb.Append("<td><span$cls>$(Esc $v)</span></td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    $extra = @($rows).Count - $max
    if ($extra -gt 0) { [void]$sb.Append("<p class=`"muted`">…och $extra rader till (se fullständig fil).</p>") }
    $sb.ToString()
}

# Ett nyckeltal-kort.
function Tile($label, $value, $cls = '') { "<div class=`"tile $cls`"><div class=`"v`">$(Esc $value)</div><div class=`"l`">$(Esc $label)</div></div>" }
# Relativ länk från rapport.html till en fil under resultatmappen.
function RelLink($path) { (($path.Substring($RunDir.Length + 1)) -replace '\\', '/') }

$body = [System.Text.StringBuilder]::new()

# --- Körningsstatus ---------------------------------------------------------
if ($Status.Count) {
    Write-Action 'Sammanställer körningsstatus'
    $rows = $Status.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Steg = $_.Key; Status = $_.Value.State; Notering = $_.Value.Note } }
    [void]$body.Append('<h2>Körningsstatus</h2>' + (ConvertTo-HtmlTable $rows @(@{Name='Steg';Label='Steg'}, @{Name='Status';Label='Status'}, @{Name='Notering';Label='Notering'})))
}

# --- azqr: läs CSV-filerna azqr skrev ----------------------------------------
$impFile = Get-ChildItem $Dirs.azqr -Filter '*.impacted.csv' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($impFile) {
    Write-Action 'Läser azqr-resultat'
    $imp = Import-Csv $impFile.FullName
    $invFile = Get-ChildItem $Dirs.azqr -Filter '*.inventory.csv' | Select-Object -First 1
    $inv = if ($invFile) { Import-Csv $invFile.FullName } else { @() }
    $subs = @($inv | Select-Object -ExpandProperty 'Subscription Id' -Unique).Count
    $hi = @($imp | Where-Object Impact -eq 'High').Count
    $me = @($imp | Where-Object Impact -eq 'Medium').Count
    $lo = @($imp | Where-Object Impact -eq 'Low').Count
    [void]$body.Append('<h2>Resurser och rekommendationer (azqr)</h2><div class="tiles">')
    [void]$body.Append((Tile 'Resurser' @($inv).Count) + (Tile 'Subscriptions' $subs) + (Tile 'Hög påverkan' $hi 'high') + (Tile 'Medel' $me 'medium') + (Tile 'Låg' $lo 'low') + '</div>')

    $byType = $inv | Group-Object 'Resource Type' | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Typ = $_.Name; Antal = $_.Count } }
    [void]$body.Append('<h3>Resurser per typ</h3>' + (ConvertTo-HtmlTable $byType @(@{Name='Typ';Label='Resurstyp'}, @{Name='Antal';Label='Antal'}) 15))

    $byCat = $imp | Group-Object Category | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Kategori = $_.Name; Antal = $_.Count } }
    [void]$body.Append('<h3>Avvikelser per kategori</h3>' + (ConvertTo-HtmlTable $byCat @(@{Name='Kategori';Label='Kategori'}, @{Name='Antal';Label='Antal'})))

    $topRec = $imp | Where-Object Impact -eq 'High' | Group-Object Recommendation | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Impact = 'High'; Rekommendation = $_.Name; Resurser = $_.Count; Exempel = ($_.Group | Select-Object -First 3 -ExpandProperty 'Resource Name') -join ', ' } }
    [void]$body.Append('<h3>Rekommendationer med hög påverkan</h3>' + (ConvertTo-HtmlTable $topRec @(@{Name='Impact';Label='Påverkan'}, @{Name='Rekommendation';Label='Rekommendation'}, @{Name='Resurser';Label='Resurser'}, @{Name='Exempel';Label='Exempel'}) 20))

    # Azure Advisor-rekommendationer följer med i azqr-skanningen.
    $advFile = Get-ChildItem $Dirs.azqr -Filter '*.advisor.csv' | Select-Object -First 1
    if ($advFile) {
        $adv = Import-Csv $advFile.FullName
        [void]$body.Append("<h3>Azure Advisor ($(@($adv).Count) rekommendationer)</h3>" + (ConvertTo-HtmlTable ($adv | Sort-Object { switch ($_.Impact) { 'High' { 0 } 'Medium' { 1 } default { 2 } } }) @(@{Name='Impact';Label='Påverkan'}, @{Name='Category';Label='Kategori'}, @{Name='Resource Name';Label='Resurs'}, @{Name='Description';Label='Beskrivning'}) 15))
    }
    $xl = Get-ChildItem $Dirs.azqr -Filter '*.xlsx' | Select-Object -First 1
    if ($xl) { [void]$body.Append("<p>Fullständig rapport: <a href=`"$(RelLink $xl.FullName)`">$(Esc $xl.Name)</a></p>") }
}

# --- Governance Visualizer: länk till den interaktiva rapporten + enkla tal --
$gvHtml = Get-ChildItem $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gvHtml) {
    Write-Action 'Läser Governance Visualizer-resultat'
    [void]$body.Append('<h2>Styrning (Governance Visualizer)</h2>')
    $csvs = Get-ChildItem $Dirs.azgovviz -Filter '*.csv' -Recurse -ErrorAction SilentlyContinue
    $roleCsv = $csvs | Where-Object Name -like '*RoleAssignments*' | Select-Object -First 1
    $polCsv  = $csvs | Where-Object Name -like '*PolicyAssignments*' | Select-Object -First 1
    [void]$body.Append('<div class="tiles">')
    if ($roleCsv) { [void]$body.Append((Tile 'Rolltilldelningar' @(Import-Csv $roleCsv.FullName -Delimiter ';').Count)) }
    if ($polCsv)  { [void]$body.Append((Tile 'Policytilldelningar' @(Import-Csv $polCsv.FullName -Delimiter ';').Count)) }
    [void]$body.Append('</div>')
    [void]$body.Append("<p>Interaktiv rapport: <a href=`"$(RelLink $gvHtml.FullName)`">$(Esc $gvHtml.Name)</a></p>")
}

# --- Maester: läs JSON-resultatet --------------------------------------------
$mj = Get-ChildItem $Dirs.maester -Filter '*.json' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*test-results*' } | Select-Object -First 1
if ($mj) {
    Write-Action 'Läser Maester-resultat'
    $m = Get-Content $mj.FullName -Raw | ConvertFrom-Json
    [void]$body.Append('<h2>Entra ID-tester (Maester)</h2><div class="tiles">')
    [void]$body.Append((Tile 'Godkända' $m.PassedCount 'ok') + (Tile 'Underkända' $m.FailedCount 'high') + (Tile 'Överhoppade' $m.SkippedCount) + '</div>')
    $failed = @($m.Tests | Where-Object Result -eq 'Failed' | Select-Object -First 25 | ForEach-Object { [pscustomobject]@{ Result = 'Failed'; Test = $_.Name } })
    [void]$body.Append('<h3>Underkända tester</h3>' + (ConvertTo-HtmlTable $failed @(@{Name='Result';Label='Resultat'}, @{Name='Test';Label='Test'}) 25))
    $mh = Get-ChildItem $Dirs.maester -Filter '*.html' -Recurse | Select-Object -First 1
    if ($mh) { [void]$body.Append("<p>Fullständig rapport: <a href=`"$(RelLink $mh.FullName)`">$(Esc $mh.Name)</a></p>") }
}

# --- Manuella exporter från portalen: bara en checklista över vad som lagts i portal\ ----
$portalFiles = Get-ChildItem $Dirs.portal -File -ErrorAction SilentlyContinue
$expected = @(
    @{ Label = 'Defender for Cloud: rekommendationer (CSV)'; Pat = '*.csv' },
    @{ Label = 'Skärmdump Secure Score / Defender-planer / kostnad'; Pat = '*.png' }
)
[void]$body.Append('<h2>Manuella exporter från portalen</h2><ul>')
foreach ($e in $expected) {
    $n = @($portalFiles | Where-Object Name -like $e.Pat).Count
    $mark = if ($n) { "&#10003; $n fil(er)" } else { '&#9744; saknas' }
    [void]$body.Append("<li>$(Esc $e.Label): $mark</li>")
}
[void]$body.Append('</ul>')

# --- Utseende (ljust/mörkt läge följer webbläsaren) -------------------------
$css = @'
:root{--bg:#fff;--fg:#1d2733;--mut:#667;--card:#f4f6f9;--bd:#dde2e8;--hi:#c0392b;--me:#d68910;--lo:#2e86c1;--ok:#1e8449}
@media(prefers-color-scheme:dark){:root{--bg:#14181d;--fg:#e6e9ed;--mut:#9aa4af;--card:#1c222a;--bd:#2d3540}}
body{font:15px/1.5 system-ui,Segoe UI,sans-serif;background:var(--bg);color:var(--fg);max-width:1000px;margin:0 auto;padding:24px 16px}
h1{margin:0 0 4px}h2{margin-top:36px;border-bottom:1px solid var(--bd);padding-bottom:6px}h3{margin-top:22px}
.muted{color:var(--mut)}a{color:var(--lo)}
.tiles{display:flex;flex-wrap:wrap;gap:12px;margin:12px 0}
.tile{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:12px 18px;min-width:120px;border-top:3px solid var(--bd)}
.tile .v{font-size:26px;font-weight:700}.tile .l{color:var(--mut);font-size:13px}
.tile.high{border-top-color:var(--hi)}.tile.medium{border-top-color:var(--me)}.tile.low{border-top-color:var(--lo)}.tile.ok{border-top-color:var(--ok)}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--bd);vertical-align:top}th{color:var(--mut);font-weight:600}
.pill{padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;color:#fff}
.pill.high,.pill.failed{background:var(--hi)}.pill.medium{background:var(--me)}.pill.low{background:var(--lo)}.pill.passed{background:var(--ok)}
@media(max-width:600px){table{display:block;overflow-x:auto}}
'@

$html = @"
<!doctype html><html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rapportkit $Period</title><style>$css</style></head><body>
<h1>Rapportkit $Period</h1>
<p class="muted">Tenant $TenantId &middot; skapad $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; endast läsrättigheter, inget i miljön har ändrats.</p>
$($body.ToString())
</body></html>
"@
$reportPath = Join-Path $RunDir 'rapport.html'
Set-Content -Path $reportPath -Value $html -Encoding utf8
Write-Ok "Rapport: $reportPath"
Stop-Transcript | Out-Null

Write-Host ''
Write-Host 'Klart. Nästa steg:' -ForegroundColor Cyan
Write-Host "  1. Öppna $reportPath och kontrollera innehållet."
Write-Host "  2. Lägg portalexporterna (Defender, Advisor, skärmdumpar) i $($Dirs.portal) enligt instruktionen."
Write-Host "  3. Zippa mappen $RunDir och lämna den på överenskommen plats (innehåller konfidentiell information)."
# RAPPORTKIT_NOOPEN används vid automatiska tester så att ingen webbläsare startas.
if (-not $env:RAPPORTKIT_NOOPEN) { Start-Process $reportPath }
