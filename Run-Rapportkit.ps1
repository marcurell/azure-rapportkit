<#
.SYNOPSIS
  Rapportkit: hämtar verktygen, loggar in, kör tre read-only rapportverktyg mot en Azure-tenant
  och sammanfattar resultatet i en HTML-rapport.

.DESCRIPTION
  Scriptet gör följande, i ordning (varje steg skriver ut vad som händer medan det körs):

    Steg 1  Förberedelser    Tenant-ID, resultatmappar, loggfil, förkontroller (internet, diskutrymme)
    Steg 2  Beroenden        Laddar ner och installerar det som saknas på den här datorn:
                               - PowerShell 7           (winget)
                               - Azure CLI              (winget)
                               - azqr                   (winget, annars direktnedladdning från GitHub)
                               - Azure Governance Visualizer (zip från GitHub, fast version)
                               - PowerShell-moduler Az.Accounts, AzAPICall, Pester, Maester (PSGallery)
                             Varje nedladdning verifieras (storlek, zip-integritet, förväntade filer).
    Steg 3  Inloggning       Azure CLI, Az PowerShell och (valfritt) Microsoft Graph
    Steg 4  Governance Visualizer   Management groups, policies, rolltilldelningar
    Steg 5  azqr                    Rekommendationer per resurs + Advisor + Defender
    Steg 6  Maester                 Tester av Entra ID (valfritt)
    Steg 7  HTML-rapport     Sammanfattning i <resultatmapp>\rapport.html. Resultatfilerna kontrolleras
                             innan de läses; avvikelser visas som varningar i rapporten.

  Allt är read-only: inget i Azure eller Entra ändras. Det som installeras hamnar på den här
  datorn (program via winget, moduler i <OutputRoot>\_modules).

  FELHANTERING
    - Ett verktyg som misslyckas stoppar inte de andra. Felet och vad du ska göra syns i
      statustabellen i konsolen och i rapporten.
    - Kan scriptet inte fortsätta alls skriver det vad som gick fel, hur du går vidare och
      exakt vilket kommando du kör om. Det som redan är installerat återanvänds.
    - Avbryter du med Ctrl+C eller stänger fönstret: kör bara scriptet igen.
    - Slutkod: 0 = allt gick bra (eller hoppades över med avsikt), 2 = något verktyg misslyckades
      men rapport finns, 1 = körningen avbröts.

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
    [switch]$DeviceLogin,
    [switch]$NoInstall,
    [switch]$Offline,
    [switch]$ReportOnly
)

# Avbryt vid fel som standard. Varje verktygssteg fångar sina egna fel (try/catch) så att ett
# misslyckat verktyg inte stoppar de andra.
$ErrorActionPreference = 'Stop'
# Nedladdningar går mycket snabbare utan förloppsindikatorn.
$ProgressPreference = 'SilentlyContinue'

# Sparas direkt: $PSBoundParameters går inte att nå från funktioner. Används för att bygga
# "kör om"-kommandot och för att starta om scriptet i PowerShell 7.
$BoundParams = @{}
foreach ($k in $PSBoundParameters.Keys) { $BoundParams[$k] = $PSBoundParameters[$k] }

$ScriptRoot = Split-Path -Parent $PSCommandPath
$ToolsDir = Join-Path $ScriptRoot 'tools'        # används bara för offline-bundle
$TotalSteps = 7
# Governance Visualizer hämtas som en fast version (den som testats). Ändras med flit, inte av misstag.
$GvVersion = '6.7.2'
$GvUrl = "https://github.com/Azure/Azure-Governance-Visualizer/archive/refs/tags/$GvVersion.zip"

$ExitCode = 0            # slutkod, se FELHANTERING ovan
$Completed = $false      # sätts när hela körningen gått igenom
$AbortShown = $false     # true när vi redan skrivit ett eget avbrottsmeddelande

# ===========================================================================
# Hjälpfunktioner för utskrift. Varje åtgärd skriver en rad så att man ser vad som händer.
# ===========================================================================

# Rubrik för ett huvudsteg, med förklaring av vad steget gör och ungefär hur länge det tar.
function Write-Step([int]$Number, [string]$Title, [string]$Explain) {
    Write-Host ''
    Write-Host ("=== Steg {0}/{1}: {2} ===" -f $Number, $TotalSteps, $Title) -ForegroundColor Cyan
    if ($Explain) { Write-Host "    $Explain" -ForegroundColor DarkCyan }
}
function Write-Action($msg) { Write-Host "  -> $msg" -ForegroundColor White }      # "nu gör jag detta"
function Write-Ok($msg)     { Write-Host "  [OK] $msg" -ForegroundColor Green }    # det gick bra
function Write-Warn2($msg)  { Write-Host "  [!]  $msg" -ForegroundColor Yellow }   # något gick fel, vi går vidare
function Write-Todo($msg)   { Write-Host "  >>> $msg" -ForegroundColor Magenta }  # något DU ska göra

# ===========================================================================
# Felhantering
# ===========================================================================

# Avbryter hela körningen med ett tydligt meddelande. $Fix = vad användaren ska göra.
function Fail([string]$What, [string]$Fix) {
    $ex = [System.Exception]::new($What)
    $ex.Data['Fix'] = $Fix
    throw $ex
}

# Gör om ett fångat fel till en text (meddelande + eventuell åtgärd) för status/varningar.
function Get-ErrorText($err) {
    $ex = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { $err }
    $t = $ex.Message
    if ($ex.Data -and $ex.Data['Fix']) { $t += ' ' + $ex.Data['Fix'] }
    $t
}

# Bygger kommandot för att köra om scriptet med samma val (inkl. tenant-ID, så ingen fråga ställs).
function Get-RerunCommand {
    $p = @()
    foreach ($k in $BoundParams.Keys) {
        $v = $BoundParams[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $p += "-$k" } }
        else { $p += "-$k"; $p += $(if ("$v" -match '\s') { "'$v'" } else { "$v" }) }
    }
    '.\Run-Rapportkit.ps1 ' + ($p -join ' ')
}

# Varningar som visas i rapporten (t.ex. oväntat filformat).
$Warnings = [System.Collections.Generic.List[string]]::new()
function Add-Warning([string]$msg) { $Warnings.Add($msg); Write-Warn2 $msg }

# Status per verktyg, visas i konsolen och överst i rapporten.
$Status = [ordered]@{}
function Set-Status($step, $state, $note = '') { $Status[$step] = @{ State = $state; Note = $note } }
# Sätter "Hoppad över" bara om ett fel inte redan registrerats för steget.
function Set-SkippedUnlessFailed($step, $note = '') { if (-not $Status.Contains($step)) { Set-Status $step 'Hoppad över' $note } }

# ===========================================================================
# Hjälpfunktioner för att hitta, hämta och verifiera verktyg
# ===========================================================================

# Läser in PATH från registret och lägger till poster som saknas, så att nyinstallerade program
# (az, azqr, pwsh) hittas direkt utan att fönstret startas om. Befintliga poster behålls.
function Update-SessionPath {
    $fresh = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
    $have = @($env:Path -split ';' | Where-Object { $_ })
    $add = @($fresh -split ';' | Where-Object { $_ -and ($have -notcontains $_) })
    $env:Path = ($have + $add) -join ';'
}

# Finns kommandot på datorn?
function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Är filen en hel zip som innehåller (minst) en post som matchar $MustContain?
function Test-Zip([string]$Path, [string]$MustContain) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return ($z.Entries.Count -gt 0) -and (-not $MustContain -or [bool]($z.Entries | Where-Object { $_.FullName -like $MustContain })) }
        finally { $z.Dispose() }
    }
    catch { return $false }
}

# Laddar ner en fil. Försöker 3 gånger och kontrollerar att filen inte är tom/för liten.
function Get-Download([string]$Url, [string]$Dest, [long]$MinBytes = 1024) {
    if ($Offline) { Fail "Offline-läge: kan inte ladda ner $Url." 'Kör utan -Offline, eller lägg filen i mappen tools\ (se Build-Bundle.ps1).' }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Write-Action "Laddar ner $Url (försök $i/3)"
            Invoke-WebRequest -Uri $Url -OutFile $Dest -Headers @{ 'User-Agent' = 'azure-rapportkit' } -UseBasicParsing
            $len = (Get-Item $Dest).Length
            if ($len -lt $MinBytes) { throw "filen blev bara $len byte" }
            return
        }
        catch {
            Write-Warn2 "Försök $i/3 misslyckades: $($_.Exception.Message)"
            Remove-Item $Dest -Force -ErrorAction SilentlyContinue
            if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    Fail "Kunde inte ladda ner $Url." 'Kontrollera internetanslutning, proxy och brandvägg (github.com, api.github.com, objects.githubusercontent.com och www.powershellgallery.com måste gå att nå). Kör sedan om scriptet.'
}

# Installerar ett program med winget och kontrollerar sedan att kommandot faktiskt finns.
# (winget-slutkoder är otydliga, så vi litar på kontrollen av att programmet gick att hitta.)
function Install-WithWinget([string]$Name, [string]$Id, [string]$Command, [string]$ManualUrl) {
    if (-not (Test-Cmd winget)) {
        Fail "$Name saknas och winget finns inte, så det kan inte installeras automatiskt." "Installera $Name manuellt ($ManualUrl), öppna ett NYTT PowerShell-fönster och kör om scriptet."
    }
    Write-Action "winget install $Id  (kan öppna ett godkännande-fönster: välj Ja)"
    winget install --id $Id --exact --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Host
    Update-SessionPath
    if (-not (Test-Cmd $Command)) {
        Fail "$Name installerades inte (winget slutkod $LASTEXITCODE)." "Installera $Name manuellt ($ManualUrl), öppna ett NYTT PowerShell-fönster och kör om scriptet."
    }
    Write-Ok "$Name installerad"
}

# Hämtar en PowerShell-modul till vår egen modulmapp ($ModDir) och kontrollerar att den går att hitta.
# Egen mapp används för att undvika problem när Dokument är omdirigerat till OneDrive.
# $Version = exakt version. $MinVersion/$MaxVersion = tillåtet intervall (max räknas som "lägre än" för PSResourceGet).
# Versionen kontrolleras: Windows har t.ex. en inbyggd Pester 3.4 som inte duger åt Maester (kräver 5.5+).
function Install-PsModule([string]$Name, [string]$Version, [string]$MinVersion, [string]$MaxVersion) {
    $have = @(Get-Module -ListAvailable -Name $Name)
    if ($MinVersion) { $have = @($have | Where-Object { $_.Version -ge [version]$MinVersion }) }
    if ($have.Count) { Write-Ok "Modul $Name finns redan (version $($have[0].Version))"; return }
    if (Test-Path "$ToolsDir\modules\$Name") {            # offline-bundle
        Write-Action "Kopierar modul $Name från tools\modules"
        Copy-Item "$ToolsDir\modules\$Name" $ModDir -Recurse -Force
    }
    elseif (-not $Offline) {
        Write-Action "Hämtar modul $Name $Version från PowerShell Gallery"
        try {
            if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
                $p = @{ Name = $Name; Path = $ModDir; TrustRepository = $true; Quiet = $true }
                if ($Version) { $p.Version = $Version }
                elseif ($MinVersion) { $p.Version = if ($MaxVersion) { "[$MinVersion,$MaxVersion)" } else { "[$MinVersion,)" } }
                Save-PSResource @p
            }
            else {
                Install-PackageProvider NuGet -Scope CurrentUser -Force | Out-Null
                $p = @{ Name = $Name; Path = $ModDir; Force = $true }
                if ($Version) { $p.RequiredVersion = $Version }
                if ($MinVersion) { $p.MinimumVersion = $MinVersion }
                if ($MaxVersion) { $p.MaximumVersion = $MaxVersion }
                Save-Module @p
            }
        }
        catch { Fail "Kunde inte hämta modulen $Name från PowerShell Gallery: $($_.Exception.Message)" 'Kontrollera internetanslutningen (www.powershellgallery.com) och kör om scriptet.' }
    }
    else { Fail "Modulen $Name finns inte i tools\modules och -Offline är satt." 'Bygg om bundlen med Build-Bundle.ps1 eller kör utan -Offline.' }
    $have = @(Get-Module -ListAvailable -Name $Name)
    if ($MinVersion) { $have = @($have | Where-Object { $_.Version -ge [version]$MinVersion }) }
    if (-not $have.Count) { Fail "Modulen $Name hämtades men gick inte att hitta i $ModDir." 'Radera mappen och kör om scriptet.' }
    Write-Ok "Modul $Name klar"
}

# Läser en CSV-fil och kontrollerar att förväntade kolumner finns. Ger $null (och en varning) om
# filen inte går att läsa eller har ett oväntat format, så att resten av rapporten ändå kan byggas.
function Import-CsvChecked([string]$Path, [string[]]$Required, [string]$Delimiter = ',') {
    $leaf = Split-Path $Path -Leaf
    try {
        if ((Get-Item $Path).Length -eq 0) { Add-Warning "$leaf är tom."; return $null }
        $rows = @(Import-Csv -Path $Path -Delimiter $Delimiter)
        if ($rows.Count -gt 0) {
            $have = @($rows[0].PSObject.Properties.Name)
            $missing = @($Required | Where-Object { $have -notcontains $_ })
            if ($missing.Count) {
                Add-Warning "$leaf saknar kolumnerna: $($missing -join ', '). Verktygets filformat kan ha ändrats; använd den fullständiga rapportfilen istället."
                return $null
            }
        }
        return , $rows     # tomt men giltigt resultat (inga rader) är OK
    }
    catch { Add-Warning "Kunde inte läsa ${leaf}: $($_.Exception.Message)"; return $null }
}

# ===========================================================================
# Bootstrap: allt nedan kräver PowerShell 7. Körs scriptet i Windows PowerShell 5.1
# installeras PowerShell 7 och scriptet startas om där med samma parametrar.
# ===========================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host '=== Startar: PowerShell 7 krävs ===' -ForegroundColor Cyan
    Write-Host '    Du kör Windows PowerShell 5.1. Verktygen kräver PowerShell 7.' -ForegroundColor DarkCyan
    try {
        Update-SessionPath
        if (-not (Test-Cmd pwsh)) {
            if ($NoInstall -or $Offline) { Fail 'PowerShell 7 saknas och installation är avstängd (-NoInstall/-Offline).' 'Installera PowerShell 7 (https://aka.ms/powershell) och kör om scriptet.' }
            Install-WithWinget 'PowerShell 7' 'Microsoft.PowerShell' 'pwsh' 'https://aka.ms/powershell'
        }
    }
    catch {
        Write-Host ''
        Write-Host '=== Körningen avbröts ===' -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)"
        if ($_.Exception.Data['Fix']) { Write-Host "  Så här går du vidare: $($_.Exception.Data['Fix'])" -ForegroundColor Yellow }
        exit 1
    }
    # Skicka vidare parametrarna till den nya processen.
    $fwd = @()
    foreach ($k in $BoundParams.Keys) {
        $v = $BoundParams[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $fwd += "-$k" } } else { $fwd += "-$k"; $fwd += "$v" }
    }
    Write-Action 'Startar om scriptet i PowerShell 7'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    exit $LASTEXITCODE
}

# ===========================================================================
# Själva körningen. Allt ligger i try/catch/finally så att ett avbrott alltid ger ett
# begripligt meddelande och att loggen stängs.
# ===========================================================================
$TranscriptStarted = $false
try {

    # =======================================================================
    # STEG 1: Förberedelser
    # =======================================================================
    Write-Step 1 'Förberedelser' 'Tenant-ID, mappar, loggfil och förkontroller. Tar några sekunder.'
    Update-SessionPath

    # Tenant-ID: använd parametern, annars föreslå det Azure CLI redan är inloggat mot.
    if (-not $TenantId) {
        $guess = $null
        if (Test-Cmd az) { try { $guess = az account show --query tenantId -o tsv 2>$null } catch { } }
        $prompt = 'Ange tenant-ID (Entra ID > Overview > Tenant ID)'
        if ($guess) { $prompt += " [Enter = $guess]" }
        try { $TenantId = Read-Host $prompt } catch { $TenantId = $null }
        if (-not $TenantId) { $TenantId = $guess }
    }
    if (-not $TenantId) { Fail 'Tenant-ID saknas.' 'Kör om med -TenantId <guid> (hittas i Entra ID > Overview).' }
    if ($TenantId -notmatch '^[0-9a-fA-F-]{36}$') { Fail "Ogiltigt tenant-ID: '$TenantId' (ett GUID förväntas)." 'Kopiera Tenant ID från Entra ID > Overview och kör om.' }
    $BoundParams['TenantId'] = $TenantId        # så att "kör om"-kommandot inte frågar igen
    Write-Ok "Tenant: $TenantId"

    # Resultatmappar: en per verktyg under <OutputRoot>\<Period>\, plus en egen modulmapp.
    $RunDir = Join-Path $OutputRoot $Period
    $ModDir = Join-Path $OutputRoot '_modules'
    $GvDir = Join-Path $OutputRoot "Azure-Governance-Visualizer-$GvVersion"
    $Dirs = @{}
    try {
        foreach ($n in 'azgovviz', 'azqr', 'maester', 'portal') {
            $Dirs[$n] = Join-Path $RunDir $n
            New-Item -ItemType Directory -Force $Dirs[$n] | Out-Null
        }
        New-Item -ItemType Directory -Force $ModDir | Out-Null
        # Testa att vi faktiskt kan skriva i mappen (t.ex. skyddade eller skrivskyddade platser).
        $probe = Join-Path $RunDir '.write-test'
        Set-Content -Path $probe -Value 'x'; Remove-Item $probe -Force
    }
    catch { Fail "Kan inte skriva i $OutputRoot ($($_.Exception.Message))." 'Välj en annan mapp med -OutputRoot (till exempel C:\Users\<du>\rapportkit) och kör om.' }
    if ($env:PSModulePath -notlike "*$ModDir*") { $env:PSModulePath = "$ModDir;$env:PSModulePath" }
    Write-Ok "Resultatmapp: $RunDir"

    # Logga allt som skrivs i fönstret till en fil (bra att skicka med vid felsökning).
    try { Start-Transcript -Path (Join-Path $RunDir 'rapportkit.log') -Append | Out-Null; $TranscriptStarted = $true } catch { Write-Warn2 'Kunde inte starta loggfil (fortsätter ändå).' }

    # Förkontroller: ledigt diskutrymme och internetåtkomst. Båda ger bara varning, inget avbrott.
    try {
        $drive = Get-PSDrive -Name ($RunDir.Substring(0, 1)) -ErrorAction Stop
        if ($drive.Free -lt 1GB) { Write-Warn2 ("Lite diskutrymme kvar på {0}: ({1:N1} GB). Rekommenderat minst 1 GB." -f $drive.Name, ($drive.Free / 1GB)) }
    }
    catch { }
    if (-not $Offline -and -not $NoInstall -and -not $ReportOnly) {
        try { Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 10 -UseBasicParsing | Out-Null; Write-Ok 'Internetåtkomst (github.com) fungerar' }
        catch { Write-Warn2 "Kunde inte nå github.com ($($_.Exception.Message)). Nedladdningar kan misslyckas: kontrollera proxy/brandvägg." }
    }

    if ($ReportOnly) { Write-Host "`n  -ReportOnly: hoppar över steg 2-6 och bygger bara rapporten." -ForegroundColor DarkCyan }
    else {

        # ===================================================================
        # STEG 2: Beroenden. Varje verktyg hämtas för sig; misslyckas ett stängs just det
        # verktyget av (status "Fel") och de andra körs vidare.
        # ===================================================================
        Write-Step 2 'Hämtar och installerar beroenden' 'Bara det som saknas på den här datorn. Första gången tar det 5-10 minuter.'
        if ($NoInstall) { Write-Warn2 '-NoInstall: hoppar över all hämtning och installation.' }

        # Azure CLI (behövs bara av azqr: används för inloggning).
        if (-not $SkipAzqr) {
            try {
                if (Test-Cmd az) { Write-Ok 'Azure CLI finns redan' }
                elseif ($NoInstall) { Fail 'Azure CLI saknas (-NoInstall är satt).' 'Installera Azure CLI (https://aka.ms/installazurecliwindows) och kör om.' }
                else { Install-WithWinget 'Azure CLI' 'Microsoft.AzureCLI' 'az' 'https://aka.ms/installazurecliwindows' }
            }
            catch { Set-Status 'azqr' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipAzqr = $true }
        }

        # azqr: först winget, annars hämtas senaste releasen direkt från GitHub (och zipen verifieras).
        if (-not $SkipAzqr) {
            try {
                $azqrDir = Join-Path $env:LOCALAPPDATA 'azqr'
                if (Test-Path "$azqrDir\azqr.exe") { if ($env:Path -notlike "*$azqrDir*") { $env:Path += ";$azqrDir" } }
                if (Test-Cmd azqr) { Write-Ok 'azqr finns redan' }
                elseif ($NoInstall) { Fail 'azqr saknas (-NoInstall är satt).' 'Installera azqr (winget install azqr) och kör om.' }
                else {
                    try { Install-WithWinget 'azqr' 'Microsoft.Azure.QuickReview' 'azqr' 'https://github.com/Azure/azqr/releases' }
                    catch {
                        Write-Warn2 "winget gav inget resultat ($($_.Exception.Message)). Hämtar azqr direkt från GitHub."
                        $zip = Join-Path $env:TEMP 'azqr.zip'
                        if (Test-Path "$ToolsDir\azqr.zip") { Copy-Item "$ToolsDir\azqr.zip" $zip -Force }
                        else {
                            $rel = Invoke-RestMethod 'https://api.github.com/repos/Azure/azqr/releases/latest' -Headers @{ 'User-Agent' = 'azure-rapportkit' }
                            $asset = $rel.assets | Where-Object name -like 'azqr-win-amd64.zip' | Select-Object -First 1
                            if (-not $asset) { Fail 'Hittade ingen Windows-zip i senaste azqr-releasen.' 'Hämta azqr manuellt från https://github.com/Azure/azqr/releases och kör om.' }
                            Get-Download $asset.browser_download_url $zip 1MB
                        }
                        if (-not (Test-Zip $zip '*azqr*.exe')) { Fail 'Den nedladdade azqr-filen är skadad eller innehåller inte azqr.exe.' 'Kör om scriptet för att hämta den igen.' }
                        Expand-Archive $zip $azqrDir -Force
                        $env:Path += ";$azqrDir"
                        if (-not (Test-Cmd azqr)) { Fail 'azqr packades upp men kommandot hittas inte.' "Kontrollera att $azqrDir\azqr.exe finns, eller installera azqr manuellt, och kör om." }
                        Write-Ok "azqr hämtad till $azqrDir"
                    }
                }
            }
            catch { Set-Status 'azqr' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipAzqr = $true }
        }

        # Azure Governance Visualizer: ett PowerShell-script i en GitHub-repo. Vi hämtar en fast version
        # som zip (kräver inte git), kontrollerar zipen och att huvudscriptet finns efter uppackning.
        if (-not $SkipGovViz) {
            try {
                $gvMain = Join-Path $GvDir 'pwsh\AzGovVizParallel.ps1'
                if (Test-Path $gvMain) { Write-Ok "Governance Visualizer $GvVersion finns redan" }
                elseif ($NoInstall) { Fail 'Governance Visualizer saknas (-NoInstall är satt).' 'Kör om utan -NoInstall.' }
                else {
                    $zip = Join-Path $env:TEMP "azgovviz-$GvVersion.zip"
                    if (Test-Path "$ToolsDir\AzGovViz.zip") { Copy-Item "$ToolsDir\AzGovViz.zip" $zip -Force }
                    else { Get-Download $GvUrl $zip 100KB }
                    if (-not (Test-Zip $zip '*pwsh/AzGovVizParallel.ps1')) { Fail 'Den nedladdade Governance Visualizer-filen är skadad eller ofullständig.' 'Kör om scriptet för att hämta den igen.' }
                    $tmp = Join-Path $OutputRoot '_gv_tmp'
                    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
                    Expand-Archive $zip $tmp -Force
                    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
                    if (Test-Path $GvDir) { Remove-Item $GvDir -Recurse -Force }
                    Move-Item $inner.FullName $GvDir
                    Remove-Item $tmp -Recurse -Force
                    if (-not (Test-Path $gvMain)) { Fail "Governance Visualizer packades upp men $gvMain saknas." 'Radera mappen och kör om scriptet.' }
                    Write-Ok "Governance Visualizer $GvVersion hämtad till $GvDir"
                }
                # Az.Accounts = inloggning för Az PowerShell. AzAPICall = hjälpmodul som AzGovViz kräver (exakt version).
                Install-PsModule 'Az.Accounts'
                Install-PsModule 'AzAPICall' '1.4.1'
            }
            catch { Set-Status 'Governance Visualizer' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipGovViz = $true }
        }

        # Maester + Pester (testramverket Maester bygger på).
        if (-not $SkipMaester) {
            try {
                if ($NoInstall -and -not (Get-Module -ListAvailable -Name Maester)) { Fail 'Maester saknas (-NoInstall är satt).' 'Kör om utan -NoInstall.' }
                # Maester kräver Pester 5.5 eller nyare. Pester 6 hålls utanför eftersom Maester är testad mot 5.x.
                Install-PsModule 'Pester' -MinVersion '5.5.0' -MaxVersion '6.0.0'
                Install-PsModule 'Maester'
            }
            catch { Set-Status 'Maester' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipMaester = $true }
        }

        # Finns det något kvar att köra? Annars är det ingen idé att fortsätta.
        if ($SkipGovViz -and $SkipAzqr -and $SkipMaester) {
            Fail 'Inget verktyg kunde förberedas, så det finns inget att köra.' 'Se felen ovan, åtgärda dem och kör om scriptet.'
        }

        # ===================================================================
        # STEG 3: Inloggning. Misslyckas en inloggning stängs bara de verktyg som behöver
        # den av; resten körs.
        # ===================================================================
        Write-Step 3 'Inloggning' 'Du loggar in med ett konto som har läsrättigheter (se README). Ett webbläsarfönster öppnas för varje inloggning. Hinner du inte: tryck Ctrl+C och kör om scriptet.'

        # 3a. Azure CLI (används av azqr)
        if (-not $SkipAzqr) {
            try {
                $cur = az account show --query tenantId -o tsv 2>$null
                if ($cur -eq $TenantId) { Write-Ok 'Azure CLI är redan inloggad mot rätt tenant' }
                else {
                    Write-Todo 'Logga in i webbläsarfönstret som öppnas (Azure CLI)...'
                    if ($DeviceLogin) { az login --tenant $TenantId --use-device-code --allow-no-subscriptions --only-show-errors | Out-Null }
                    else              { az login --tenant $TenantId --allow-no-subscriptions --only-show-errors | Out-Null }
                }
                if ((az account show --query tenantId -o tsv 2>$null) -ne $TenantId) {
                    Fail 'Azure CLI-inloggningen mot rätt tenant slutfördes inte.' 'Kör om scriptet och logga in när webbläsarfönstret öppnas (eller använd -DeviceLogin).'
                }
                # (Räknas i PowerShell: parenteser i --query förstörs av az.cmd:s citering.)
                $subCount = @(az account list --query '[].id' -o tsv 2>$null | Where-Object { $_ }).Count
                if ($subCount -lt 1) { Fail 'Kontot har inte åtkomst till någon subscription i tenanten.' 'Tilldela rollen Reader (se README) och kör om scriptet.' }
                Write-Ok "Azure CLI inloggad ($subCount subscription(s) synliga)"
            }
            catch { Set-Status 'azqr' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipAzqr = $true }
        }

        # 3b. Az PowerShell (används av Governance Visualizer)
        if (-not $SkipGovViz) {
            try {
                Import-Module Az.Accounts -ErrorAction Stop
                $ctx = Get-AzContext -ErrorAction SilentlyContinue
                # En AccessToken-session kan inte förnyas, och Governance Visualizer behöver det: logga in på nytt.
                if ($ctx -and $ctx.Tenant.Id -eq $TenantId -and $ctx.Account.Type -ne 'AccessToken') { Write-Ok 'Az PowerShell är redan inloggad' }
                else {
                    Write-Todo 'Logga in igen (Az PowerShell)...'
                    if ($DeviceLogin) { Connect-AzAccount -TenantId $TenantId -UseDeviceAuthentication | Out-Null }
                    else              { Connect-AzAccount -TenantId $TenantId | Out-Null }
                }
                $ctx = Get-AzContext
                if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId) { Fail 'Az PowerShell-inloggningen mot rätt tenant slutfördes inte.' 'Kör om scriptet och logga in när webbläsarfönstret öppnas (eller använd -DeviceLogin).' }
                Write-Ok 'Az PowerShell inloggad'
            }
            catch { Set-Status 'Governance Visualizer' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipGovViz = $true }
        }

        # 3c. Microsoft Graph för Maester (valfritt; kräver admin consent första gången)
        if (-not $SkipMaester) {
            Write-Host '  Maester läser Entra ID via Microsoft Graph. Första gången måste en Global Administrator godkänna behörigheterna.'
            try { $ans = Read-Host '  Logga in till Microsoft Graph för Maester nu? (j/N)' } catch { $ans = 'n' }
            if ($ans -notmatch '^[jJyY]') { $SkipMaester = $true; Set-Status 'Maester' 'Hoppad över' 'Valdes bort vid inloggningsfrågan. Kör om och svara j, eller använd -SkipMaester.' }
            else {
                try { Connect-Maester -TenantId $TenantId | Out-Null; Write-Ok 'Microsoft Graph inloggad' }
                catch {
                    $SkipMaester = $true
                    Set-Status 'Maester' 'Fel' "Graph-inloggning misslyckades: $($_.Exception.Message) En Global Administrator behöver ge admin consent för 'Microsoft Graph Command Line Tools'. Kör sedan om scriptet."
                    Write-Warn2 $Status['Maester'].Note
                }
            }
        }

        if ($SkipGovViz -and $SkipAzqr -and $SkipMaester) {
            Fail 'Ingen inloggning lyckades, så inget verktyg kan köras.' 'Se meddelandena ovan, logga in och kör om scriptet (installationen är redan gjord, så det går snabbt).'
        }

        # ===================================================================
        # STEG 4: Azure Governance Visualizer
        # ===================================================================
        Write-Step 4 'Azure Governance Visualizer' 'Går igenom management groups, subscriptions, policies och roller. 10-45 min i stora miljöer, några minuter i små. Mycket text i fönstret är normalt.'
        if ($SkipGovViz) { Write-Action 'Hoppas över'; Set-SkippedUnlessFailed 'Governance Visualizer' }
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
                    if ($patched -eq $src) { Add-Warning 'Kunde inte patcha modulkontrollen i Governance Visualizer (verktyget kan fråga y/n).' }
                    else { Set-Content $gvScript $patched -Encoding utf8 }
                }
                $mg = if ($ManagementGroupId) { $ManagementGroupId } else { $TenantId }
                Write-Action "Kör AzGovVizParallel.ps1 mot management group '$mg'"
                $gvArgs = @{ ManagementGroupId = $mg; OutputPath = $Dirs.azgovviz }
                # PIM-behörighetsrapportering kräver ett servicekonto och kan inte köras som vanlig användare.
                # Utan flaggan pausar verktyget och väntar på tangenttryckning, så vi stänger av det direkt.
                $gvArgs.NoPIMEligibility = $true
                # Utskriften sparas också i $gvLines så att den verkliga orsaken kan plockas fram vid fel.
                $gvLines = [System.Collections.Generic.List[string]]::new()
                & $gvScript @gvArgs *>&1 | ForEach-Object { $gvLines.Add("$_"); $_ } | Out-Host
                # Verifiera: verktyget kan avsluta utan fel men utan resultat.
                $gvHtmlOut = Get-ChildItem $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue | Where-Object Length -gt 10KB | Select-Object -First 1
                if (-not $gvHtmlOut) { throw "Körningen avslutades men ingen rapport (AzGovViz*.html) hittades i $($Dirs.azgovviz)." }
                Set-Status 'Governance Visualizer' 'OK'
                Write-Ok 'Governance Visualizer klar'
            }
            catch {
                # Plocka ut raderna i verktygets utskrift som förklarar felet (t.ex. "permissions ... check FAILED").
                $reason = @($gvLines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match 'FAILED|Permission check|not authorized|AuthorizationFailed' } | Select-Object -Last 2) -join ' | '
                $msg = $_.Exception.Message
                if ($reason) { $msg = "$reason ($msg)" }
                Write-Warn2 $msg
                Set-Status 'Governance Visualizer' 'Fel' ($msg + ' Vanlig orsak: Reader saknas på Tenant Root Group (se README) - ange då en annan grupp med -ManagementGroupId.')
            }
        }

        # ===================================================================
        # STEG 5: azqr
        # ===================================================================
        Write-Step 5 'Azure Quick Review (azqr)' 'Skannar alla subscriptions du har läsrätt till. 1-30 min.'
        if ($SkipAzqr) { Write-Action 'Hoppas över'; Set-SkippedUnlessFailed 'azqr' }
        else {
            try {
                Push-Location $Dirs.azqr
                # Rensa gamla resultat för samma period så att vi inte läser blandade körningar.
                Get-ChildItem $Dirs.azqr -Filter "azqr_$Period*" -ErrorAction SilentlyContinue | Remove-Item -Force
                Write-Action 'Kör: azqr scan --json --csv --xlsx'
                # --json/--csv gör att vi kan läsa resultatet i HTML-rapporten; --xlsx är den fullständiga rapporten.
                azqr scan --json --csv --xlsx -o "azqr_$Period" 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "azqr avslutades med kod $LASTEXITCODE." }
                # Verifiera att resultatfilerna finns och inte är tomma.
                $xlsxOut = Get-ChildItem $Dirs.azqr -Filter '*.xlsx' | Where-Object Length -gt 0 | Select-Object -First 1
                $invOut = Get-ChildItem $Dirs.azqr -Filter '*.inventory.csv' | Where-Object Length -gt 0 | Select-Object -First 1
                if (-not $xlsxOut -or -not $invOut) { throw 'azqr avslutades men resultatfilerna (Excel/CSV) saknas eller är tomma. Kontrollera att kontot har Reader på minst en subscription.' }
                Set-Status 'azqr' 'OK'
                Write-Ok 'azqr klar'
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'azqr' 'Fel' $_.Exception.Message }
            finally { Pop-Location }
        }

        # ===================================================================
        # STEG 6: Maester
        # ===================================================================
        Write-Step 6 'Maester (Entra ID-tester)' 'Valfritt. 10-20 min.'
        if ($SkipMaester) { Write-Action 'Hoppas över'; Set-SkippedUnlessFailed 'Maester' }
        else {
            try {
                Push-Location $Dirs.maester
                Import-Module Maester -ErrorAction Stop
                $testsDir = Join-Path $Dirs.maester 'maester-tests'
                if (-not (Test-Path $testsDir)) { Write-Action 'Hämtar Maesters testsvit (Install-MaesterTests)'; Install-MaesterTests }
                if (-not (Test-Path $testsDir)) { throw 'Maesters testsvit hämtades inte (mappen maester-tests saknas). Kontrollera internetanslutningen och kör om.' }
                Write-Action 'Kör Invoke-Maester'
                Invoke-Maester -Path $testsDir -OutputFolder (Join-Path $Dirs.maester 'test-results') `
                    -OutputJsonFile (Join-Path $Dirs.maester 'test-results\maester.json') -NonInteractive -PassThru | Out-Null
                if (-not (Test-Path (Join-Path $Dirs.maester 'test-results\maester.json'))) { throw 'Maester avslutades men resultatfilen maester.json saknas.' }
                Set-Status 'Maester' 'OK'
                Write-Ok 'Maester klar'
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'Maester' 'Fel' $_.Exception.Message }
            finally { Pop-Location }
        }
    }

    # =======================================================================
    # STEG 7: HTML-rapport. Varje avsnitt byggs för sig; går ett avsnitt inte att bygga
    # blir det en varning i rapporten, inte ett avbrott.
    # =======================================================================
    Write-Step 7 'Bygger HTML-rapport' 'Kontrollerar och läser resultatfilerna och skriver rapport.html.'
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
                if ($c.Name -in 'Impact', 'Result', 'Status') { $cls = " class=`"pill $(([string]$v).ToLower())`"" }
                [void]$sb.Append("<td><span$cls>$(Esc $v)</span></td>")
            }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</tbody></table>')
        $extra = @($rows).Count - $max
        if ($extra -gt 0) { [void]$sb.Append("<p class=`"muted`">…och $extra rader till (se fullständig fil).</p>") }
        $sb.ToString()
    }

    function Tile($label, $value, $cls = '') { "<div class=`"tile $cls`"><div class=`"v`">$(Esc $value)</div><div class=`"l`">$(Esc $label)</div></div>" }
    # Relativ länk från rapport.html till en fil under resultatmappen.
    function RelLink($path) { (($path.Substring($RunDir.Length + 1)) -replace '\\', '/') }
    # Kör ett avsnitt; fel blir en varning istället för ett avbrott.
    # (Parametern får inte heta $Body: PowerShell skiljer inte på versaler och den skulle skugga $body nedan.)
    function Invoke-Section([string]$Name, [scriptblock]$Action) {
        try { & $Action } catch { Add-Warning "Avsnittet '$Name' i rapporten kunde inte byggas: $($_.Exception.Message)" }
    }

    $body = [System.Text.StringBuilder]::new()

    # --- azqr: läs CSV-filerna azqr skrev ------------------------------------
    Invoke-Section 'azqr' {
        $impFile = Get-ChildItem $Dirs.azqr -Filter '*.impacted.csv' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $impFile) { return }
        Write-Action 'Läser azqr-resultat'
        $imp = Import-CsvChecked $impFile.FullName @('Impact', 'Category', 'Recommendation', 'Resource Name')
        $invFile = Get-ChildItem $Dirs.azqr -Filter '*.inventory.csv' | Select-Object -First 1
        $inv = if ($invFile) { Import-CsvChecked $invFile.FullName @('Resource Type', 'Subscription Id') } else { $null }
        $xl = Get-ChildItem $Dirs.azqr -Filter '*.xlsx' | Select-Object -First 1
        $xlLink = if ($xl) { "<p>Fullständig rapport: <a href=`"$(RelLink $xl.FullName)`">$(Esc $xl.Name)</a></p>" } else { '' }
        if ($null -eq $imp -or $null -eq $inv) {
            [void]$body.Append('<h2>Resurser och rekommendationer (azqr)</h2><p class="muted">Kunde inte sammanfatta azqr-resultatet (se varningar). Använd den fullständiga rapporten.</p>' + $xlLink)
            return
        }
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
            $adv = Import-CsvChecked $advFile.FullName @('Impact', 'Category', 'Resource Name', 'Description')
            if ($null -ne $adv) {
                [void]$body.Append("<h3>Azure Advisor ($(@($adv).Count) rekommendationer)</h3>" + (ConvertTo-HtmlTable ($adv | Sort-Object { switch ($_.Impact) { 'High' { 0 } 'Medium' { 1 } default { 2 } } }) @(@{Name='Impact';Label='Påverkan'}, @{Name='Category';Label='Kategori'}, @{Name='Resource Name';Label='Resurs'}, @{Name='Description';Label='Beskrivning'}) 15))
            }
        }
        [void]$body.Append($xlLink)
    }

    # --- Governance Visualizer: länk till den interaktiva rapporten + enkla tal ----
    Invoke-Section 'Governance Visualizer' {
        $gvHtml = Get-ChildItem $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $gvHtml) { return }
        Write-Action 'Läser Governance Visualizer-resultat'
        [void]$body.Append('<h2>Styrning (Governance Visualizer)</h2>')
        $csvs = Get-ChildItem $Dirs.azgovviz -Filter '*.csv' -Recurse -ErrorAction SilentlyContinue
        $roleCsv = $csvs | Where-Object Name -like '*RoleAssignments*' | Select-Object -First 1
        $polCsv  = $csvs | Where-Object Name -like '*PolicyAssignments*' | Select-Object -First 1
        [void]$body.Append('<div class="tiles">')
        if ($roleCsv) { $r = Import-CsvChecked $roleCsv.FullName @() ';'; if ($null -ne $r) { [void]$body.Append((Tile 'Rolltilldelningar' @($r).Count)) } }
        if ($polCsv)  { $r = Import-CsvChecked $polCsv.FullName @() ';';  if ($null -ne $r) { [void]$body.Append((Tile 'Policytilldelningar' @($r).Count)) } }
        [void]$body.Append('</div>')
        [void]$body.Append("<p>Interaktiv rapport: <a href=`"$(RelLink $gvHtml.FullName)`">$(Esc $gvHtml.Name)</a></p>")
    }

    # --- Maester: läs JSON-resultatet ----------------------------------------
    Invoke-Section 'Maester' {
        $mj = Get-ChildItem $Dirs.maester -Filter '*.json' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*test-results*' } | Select-Object -First 1
        if (-not $mj) { return }
        Write-Action 'Läser Maester-resultat'
        $m = Get-Content $mj.FullName -Raw | ConvertFrom-Json
        $props = @($m.PSObject.Properties.Name)
        $missing = @('PassedCount', 'FailedCount', 'SkippedCount', 'Tests') | Where-Object { $props -notcontains $_ }
        if ($missing) {
            Add-Warning "maester.json saknar fälten: $($missing -join ', '). Filformatet kan ha ändrats; använd Maesters egen HTML-rapport."
            return
        }
        [void]$body.Append('<h2>Entra ID-tester (Maester)</h2><div class="tiles">')
        [void]$body.Append((Tile 'Godkända' $m.PassedCount 'ok') + (Tile 'Underkända' $m.FailedCount 'high') + (Tile 'Överhoppade' $m.SkippedCount) + '</div>')
        $failed = @($m.Tests | Where-Object Result -eq 'Failed' | Select-Object -First 25 | ForEach-Object { [pscustomobject]@{ Result = 'Failed'; Test = $_.Name } })
        [void]$body.Append('<h3>Underkända tester</h3>' + (ConvertTo-HtmlTable $failed @(@{Name='Result';Label='Resultat'}, @{Name='Test';Label='Test'}) 25))
        $mh = Get-ChildItem $Dirs.maester -Filter '*.html' -Recurse | Select-Object -First 1
        if ($mh) { [void]$body.Append("<p>Fullständig rapport: <a href=`"$(RelLink $mh.FullName)`">$(Esc $mh.Name)</a></p>") }
    }

    # --- Manuella exporter från portalen: bara en checklista över vad som lagts i portal\ ----
    Invoke-Section 'Portalexporter' {
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
    }

    # --- Status och varningar överst i rapporten ----------------------------
    $top = [System.Text.StringBuilder]::new()
    if ($Status.Count) {
        $rows = $Status.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Steg = $_.Key; Status = $_.Value.State; Notering = $_.Value.Note } }
        [void]$top.Append('<h2>Körningsstatus</h2>' + (ConvertTo-HtmlTable $rows @(@{Name='Steg';Label='Steg'}, @{Name='Status';Label='Status'}, @{Name='Notering';Label='Notering'})))
    }
    if ($Warnings.Count) {
        [void]$top.Append('<h2>Varningar</h2><ul>' + (($Warnings | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul>')
    }

    # --- Utseende (ljust/mörkt läge följer webbläsaren) ---------------------
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
.pill{padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;color:#fff;background:var(--mut)}
.pill.high,.pill.failed,.pill.fel{background:var(--hi)}.pill.medium{background:var(--me)}.pill.low{background:var(--lo)}.pill.passed,.pill.ok{background:var(--ok)}
@media(max-width:600px){table{display:block;overflow-x:auto}}
'@
    $html = @"
<!doctype html><html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rapportkit $Period</title><style>$css</style></head><body>
<h1>Rapportkit $Period</h1>
<p class="muted">Tenant $TenantId &middot; skapad $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; endast läsrättigheter, inget i miljön har ändrats.</p>
$($top.ToString())
$($body.ToString())
</body></html>
"@
    $reportPath = Join-Path $RunDir 'rapport.html'
    Set-Content -Path $reportPath -Value $html -Encoding utf8
    Write-Ok "Rapport: $reportPath"

    # =======================================================================
    # Sammanfattning i konsolen
    # =======================================================================
    Write-Host ''
    Write-Host '=== Sammanfattning ===' -ForegroundColor Cyan
    $anyFail = $false
    foreach ($k in $Status.Keys) {
        $s = $Status[$k]
        $color = switch ($s.State) { 'OK' { 'Green' } 'Fel' { 'Red' } default { 'DarkGray' } }
        Write-Host ("  {0,-24} {1}" -f $k, $s.State) -ForegroundColor $color
        if ($s.State -eq 'Fel') { $anyFail = $true; Write-Host "      $($s.Note)" -ForegroundColor Yellow }
    }
    if ($anyFail) {
        $ExitCode = 2
        Write-Host ''
        Write-Host '  Något verktyg misslyckades (se ovan). Rapporten visar det som gick bra.' -ForegroundColor Yellow
        Write-Host '  Åtgärda det som står under respektive fel och kör om scriptet:' -ForegroundColor Yellow
        Write-Host "    $(Get-RerunCommand)" -ForegroundColor White
    }
    Write-Host ''
    Write-Host 'Nästa steg:' -ForegroundColor Cyan
    Write-Host "  1. Öppna $reportPath och kontrollera innehållet."
    Write-Host "  2. Lägg portalexporterna (Defender, Advisor, skärmdumpar) i $($Dirs.portal) enligt instruktionen."
    Write-Host "  3. Zippa mappen $RunDir och lämna den på överenskommen plats (innehåller konfidentiell information)."
    $Completed = $true
    # RAPPORTKIT_NOOPEN används vid automatiska tester så att ingen webbläsare startas.
    if (-not $env:RAPPORTKIT_NOOPEN) { try { Start-Process $reportPath } catch { } }
}
catch {
    # Avbrott: skriv vad som hände, vad man ska göra och exakt vilket kommando som körs om.
    $ex = $_.Exception
    # Ctrl+C kan komma hit som PipelineStoppedException: låt finally-blocket skriva avbrottsmeddelandet.
    if ($ex -is [System.Management.Automation.PipelineStoppedException]) { exit 1 }
    $ExitCode = 1
    $AbortShown = $true
    Write-Host ''
    Write-Host '=== Körningen avbröts ===' -ForegroundColor Red
    if ($ex.Data -and $ex.Data['Fix']) {
        Write-Host "  Orsak: $($ex.Message)" -ForegroundColor Red
        Write-Host "  Så här går du vidare: $($ex.Data['Fix'])" -ForegroundColor Yellow
    }
    else {
        Write-Host "  Oväntat fel: $($ex.Message)" -ForegroundColor Red
        Write-Host "  Plats: $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray
        Write-Host '  Skicka loggfilen (rapportkit.log i resultatmappen) till den som gav dig scriptet.' -ForegroundColor Yellow
    }
    Write-Host '  När det är åtgärdat, kör om scriptet. Det som redan är installerat återanvänds:' -ForegroundColor Yellow
    Write-Host "    $(Get-RerunCommand)" -ForegroundColor White
}
finally {
    # Körs alltid, även vid Ctrl+C eller stängt fönster: stäng loggen och förklara avbrottet.
    if (-not $Completed -and -not $AbortShown) {
        Write-Host ''
        Write-Host '=== Körningen avbröts (Ctrl+C eller stängt fönster) ===' -ForegroundColor Yellow
        Write-Host '  Inget har ändrats i Azure. Kör om scriptet; det som redan är installerat återanvänds:' -ForegroundColor Yellow
        if ($TenantId) { Write-Host "    $(Get-RerunCommand)" -ForegroundColor White }
    }
    if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
exit $ExitCode
