<#
.SYNOPSIS
  Rapportkit: hämtar verktygen, loggar in, kör tre read-only rapportverktyg mot en Azure-tenant
  och sammanfattar resultatet i en HTML-rapport.

.DESCRIPTION
  Scriptet gör följande, i ordning (varje steg skriver ut vad som händer medan det körs):

    Steg 1  Förberedelser    Tenant-ID, resultatmappar, loggfil
    Steg 2  Förkontroll      Kontrollerar förutsättningar (verktyg, nätverk, disk) innan något hämtas, och
                             låter dig välja om du vill fortsätta även om något saknas
    Steg 3  Azure CLI, inloggning och rollkontroll
                             Installerar Azure CLI, loggar in och kontrollerar att kontot har rätt roller
                             (Reader, Security Reader, Cost Management Reader, Global Reader). Saknas roller
                             visas hur de läggs till, och du väljer om du vill avsluta eller fortsätta.
    Steg 4  Beroenden        Laddar ner och installerar det som saknas på den här datorn:
                               - PowerShell 7           (winget, redan i bootstrap)
                               - azqr                   (winget, annars direktnedladdning från GitHub)
                               - Azure Governance Visualizer (zip från GitHub, fast version)
                               - PowerShell-moduler Az.Accounts, AzAPICall, Pester 5.5+, Maester (PSGallery)
                             Varje nedladdning verifieras (storlek, zip-integritet, förväntade filer).
    Steg 5  Inloggning       Az PowerShell och (valfritt) Microsoft Graph, samt kontroll av management group
    Steg 6  Governance Visualizer   Management groups, policies, rolltilldelningar
    Steg 7  azqr                    Rekommendationer per resurs + Advisor + Defender
    Steg 8  Maester                 Tester av Entra ID (valfritt)
    Steg 9  Defender och kostnad    Defender-planer, Secure Score, Defender-rekommendationer och kostnad
                                    (12 mån) hämtas automatiskt och sparas som CSV i portal\
    Steg 10 HTML-rapport     Sammanfattning i <resultatmapp>\rapport.html. Resultatfilerna kontrolleras
                             innan de läses; avvikelser visas som varningar i rapporten.

  Scriptet skriver inget i Azure-resurser eller i Entra-konfigurationen och använder bara läsande anrop. Det gör
  däremot följande, vilket är bra att veta:
    - installerar verktyg på den här datorn (program via winget, moduler i <OutputRoot>\_modules),
    - skapar inloggningssessioner, som syns i tenantens inloggnings- och granskningsloggar,
    - för Maester måste en administratör godkänna läsbehörigheter för "Microsoft Graph Command Line Tools"
      (admin consent), vilket är en ändring i tenanten,
    - sparar resultat med konfidentiell information i resultatmappen (zip skapas om du inte anger -NoZip).

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
  Rotmapp för resultat och hämtade verktyg. Anges den inte frågar scriptet var den ska ligga (förslag: %USERPROFILE%\rapportkit).
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
.PARAMETER SkipPortal
  Hoppa över hämtningen av Defender- och kostnadsdata (steg 9).
.PARAMETER MaxPortalSubscriptions
  Högst så många (aktiva) prenumerationer hämtas Defender- och kostnadsdata för (standard 25). Cost Management
  begränsar anrop hårt, så hundratals prenumerationer tar timmar.
.PARAMETER HidePersonalData
  Dölj användardata (namn och e-postadresser i rolltilldelningar) i Governance Visualizers rapport. Gäller inte
  Maesters rapport, som kan innehålla användarnamn.
.PARAMETER KeepLogin
  Logga inte ut från de sessioner scriptet själv skapade (Azure CLI, Azure PowerShell, Microsoft Graph).
.PARAMETER NoZip
  Skapa ingen zip-fil av resultatet.
.PARAMETER Plain
  Rita ramar och staplar med vanliga ASCII-tecken (för konsoler som visar specialtecken fel).
.PARAMETER LatestTools
  Använd senaste versionerna av verktygen istället för de testade (pinnade) och hoppa över kontrollsummor.
.PARAMETER AllowUnverified
  Fortsätt även om en nedladdad fil inte stämmer med den testade kontrollsumman. Använd bara efter egen kontroll.
.PARAMETER Yes
  Svara ja på alla "fortsätta ändå?"-frågor (förkontroll och behörighetskontroll), t.ex. för automatiska körningar.

.EXAMPLE
  .\Run-Rapportkit.ps1
.EXAMPLE
  .\Run-Rapportkit.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -SkipMaester
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ManagementGroupId,
    [string]$OutputRoot,
    [string]$Period = (Get-Date -Format 'yyyy-MM'),
    [switch]$SkipGovViz,
    [switch]$SkipAzqr,
    [switch]$SkipMaester,
    [switch]$DeviceLogin,
    [switch]$NoInstall,
    [switch]$Offline,
    [switch]$ReportOnly,
    [switch]$SkipPortal,
    [int]$MaxPortalSubscriptions = 25,
    [switch]$HidePersonalData,
    [switch]$KeepLogin,
    [switch]$NoZip,
    [switch]$Plain,
    [switch]$LatestTools,
    [switch]$AllowUnverified,
    [switch]$Yes
)

# Avbryt vid fel som standard. Varje verktygssteg fångar sina egna fel (try/catch) så att ett
# misslyckat verktyg inte stoppar de andra.
$ErrorActionPreference = 'Stop'
# Nedladdningar går mycket snabbare utan förloppsindikatorn.
$ProgressPreference = 'SilentlyContinue'
# Företagsproxy kräver ofta att Windows-inloggningen skickas med (annars HTTP 407). Gäller både Windows PowerShell 5.1
# och PowerShell 7.
try { [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials } catch { }
try { [System.Net.Http.HttpClient]::DefaultProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials } catch { }

# Sparas direkt: $PSBoundParameters går inte att nå från funktioner. Används för att bygga
# "kör om"-kommandot och för att starta om scriptet i PowerShell 7.
$BoundParams = @{}
foreach ($k in $PSBoundParameters.Keys) { $BoundParams[$k] = $PSBoundParameters[$k] }

$ScriptRoot = Split-Path -Parent $PSCommandPath
$ToolsDir = Join-Path $ScriptRoot 'tools'        # används bara för offline-bundle
$TotalSteps = 10
# Governance Visualizer hämtas som en fast version (den som testats). Ändras med flit, inte av misstag.
$GvVersion = '6.7.2'
$GvUrl = "https://github.com/Azure/Azure-Governance-Visualizer/archive/refs/tags/$GvVersion.zip"
$KitVersion = '1.0.7'

# Testade (pinnade) verktygsversioner, och kontrollsummor (SHA256) för de zip-filer som hämtas direkt. Då får kunden
# samma verktyg som vi har testat, och en ändrad fil upptäcks. Verktygen installerade via winget kontrolleras av winget
# själv mot dess manifest. -LatestTools byter till senaste versioner och stänger av kontrollsummorna.
$Pins = @{
    Azqr         = '4.3.0'
    AzqrSha256   = '1A88B48AD88B9F02CB95A6AFA76A825A0CD3F7A8340CAEDD3294105328C4F3EC'
    GovVizSha256 = 'EA6E6F85846CD3D257A5D77558DDCC877198B42F99BA0B15A58715718CE80F86'
    AzAccounts   = '5.5.3'
    AzApiCall    = '1.4.1'
    Pester       = '5.9.1'
    Maester      = '2.3.0'
}
if ($LatestTools) { foreach ($k in @($Pins.Keys)) { if ($k -ne 'AzApiCall') { $Pins[$k] = $null } } }
$AzqrZipUrl = "https://github.com/Azure/azqr/releases/download/v.$($Pins.Azqr)/azqr-win-amd64.zip"

# Tillstånd som behövs vid avslutet (utloggning). Sätts längre ned när scriptet själv loggar in.
$azReady = $false
$azWasLoggedIn = $false
$azPsByUs = $false
$graphByUs = $false

$ExitCode = 0            # slutkod, se FELHANTERING ovan
$Completed = $false      # sätts när hela körningen gått igenom
$AbortShown = $false     # true när vi redan skrivit ett eget avbrottsmeddelande

# ===========================================================================
# Utskrift (UI) och loggning. Varje åtgärd skriver en rad i fönstret och en rad i loggen.
# ===========================================================================

# --- Tecken för ramar och staplar. De byggs av teckenkoder så att det fungerar oavsett hur filen är sparad.
#     -Plain ger vanliga ASCII-tecken (för konsoler som ritar specialtecken fel).
$UiWidth = 78
if ($Plain) { $G = @{ H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; DH = '='; DV = '|'; DTL = '+'; DTR = '+'; DBL = '+'; DBR = '+'; Full = '#'; Empty = '.' } }
else {
    $G = @{}
    foreach ($pair in @(@('H', 0x2500), @('V', 0x2502), @('TL', 0x250C), @('TR', 0x2510), @('BL', 0x2514), @('BR', 0x2518), @('DH', 0x2550), @('DV', 0x2551), @('DTL', 0x2554), @('DTR', 0x2557), @('DBL', 0x255A), @('DBR', 0x255D), @('Full', 0x2588), @('Empty', 0x2591))) { $G[$pair[0]] = [string][char]$pair[1] }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}

# --- Rensad logg: tidsstämpel, nivå och text, utan färger. Före steg 1 buffras raderna tills resultatmappen finns.
#     Den fullständiga konsolutskriften (med verktygens egen text) sparas separat i rapportkit-console.log.
$script:LogFile = $null
$script:LogBuffer = [System.Collections.Generic.List[string]]::new()
$script:RunStart = Get-Date
function Write-Log([string]$Level, [string]$Msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1,-7} {2}' -f (Get-Date), $Level, ($Msg -replace '\s*\r?\n\s*', ' ')
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 } catch { } }
    else { $script:LogBuffer.Add($line) }
}
# Startar loggfilen i resultatmappen: skriver en rubrik med miljöuppgifter och tömmer det som buffrats.
function Initialize-Log([string]$Dir) {
    $script:LogFile = Join-Path $Dir 'rapportkit.log'
    $opts = ($BoundParams.Keys | Sort-Object | ForEach-Object { if ($BoundParams[$_] -is [switch]) { "-$_" } else { "-$_ $($BoundParams[$_])" } }) -join ' '
    $hdr = @(
        ('# Azure Rapportkit {0}' -f $KitVersion),
        ('# Start: {0:yyyy-MM-dd HH:mm:ss}   Värd: {1}   OS: {2}   PowerShell: {3}' -f $script:RunStart, $env:COMPUTERNAME, [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion),
        ("# Parametrar: $opts"),
        '# Tid                  Nivå    Meddelande'
    )
    Add-Content -Path $script:LogFile -Value $hdr -Encoding utf8
    foreach ($l in $script:LogBuffer) { Add-Content -Path $script:LogFile -Value $l -Encoding utf8 }
    $script:LogBuffer.Clear()
}

# --- Hjälpfunktioner för text och ramar
function Format-Duration([double]$Sec) {
    if ($Sec -lt 60) { return ('{0:N0} s' -f $Sec) }
    '{0} min {1:00} s' -f [int][math]::Floor($Sec / 60), [int]($Sec % 60)
}
# Radbryter text vid ord så att ingen rad blir längre än $Width.
function Format-Wrap([string]$Text, [int]$Width, [string]$Indent = '') {
    $out = [System.Collections.Generic.List[string]]::new()
    $line = ''
    foreach ($w in ($Text -split '\s+')) {
        if (-not $w) { continue }
        if ($line -and (($line.Length + $w.Length + 1) -gt $Width)) { $out.Add($Indent + $line); $line = $w }
        else { $line = if ($line) { "$line $w" } else { $w } }
    }
    if ($line) { $out.Add($Indent + $line) }
    , $out
}
# En rad i en ram: $Segments = lista med @(text, färg). Fylls ut till ramens bredd.
function Write-BoxLine($Segments, [string]$EdgeColor = 'DarkCyan', [switch]$Double) {
    $edge = if ($Double) { $G.DV } else { $G.V }
    $len = 0
    foreach ($s in $Segments) { $len += ([string]$s[0]).Length }
    Write-Host $edge -NoNewline -ForegroundColor $EdgeColor
    foreach ($s in $Segments) { Write-Host ([string]$s[0]) -NoNewline -ForegroundColor $s[1] }
    Write-Host ((' ' * [math]::Max(0, $UiWidth - 2 - $len)) + $edge) -ForegroundColor $EdgeColor
}
function Write-Badge([string]$Text, [string]$Color) {
    $w = 9
    $pad = [int][math]::Floor(($w - $Text.Length) / 2)
    Write-Host (((' ' * [math]::Max(0, $pad)) + $Text).PadRight($w)) -NoNewline -ForegroundColor Black -BackgroundColor $Color
}
# En statusrad: färgad etikett följt av text som radbryts med hängande indrag.
function Write-Line([string]$Badge, [string]$Color, [string]$Msg, [string]$MsgColor = 'Gray') {
    $lines = Format-Wrap $Msg ($UiWidth - 14)
    Write-Host '  ' -NoNewline
    Write-Badge $Badge $Color
    Write-Host ('  ' + $(if ($lines.Count) { $lines[0] } else { '' })) -ForegroundColor $MsgColor
    for ($i = 1; $i -lt $lines.Count; $i++) { Write-Host ((' ' * 13) + $lines[$i]) -ForegroundColor $MsgColor }
}

# --- Rubrik för ett huvudsteg: ruta med stegnummer, förloppsstapel och rubrik, plus en förklaring.
$script:StepLog = [ordered]@{}
$script:CurStep = 0
$script:CurTitle = ''
$script:CurStart = $null
# Stänger det pågående steget och sparar hur lång tid det tog.
function Complete-Step {
    if ($script:CurStep -gt 0 -and $script:CurStart) {
        $sec = [math]::Round(((Get-Date) - $script:CurStart).TotalSeconds, 1)
        $script:StepLog[[string]$script:CurStep] = @{ Title = $script:CurTitle; Seconds = $sec }
        Write-Log 'STEG' ('Steg {0} klart: {1} ({2:N1} s)' -f $script:CurStep, $script:CurTitle, $sec)
        $script:CurStart = $null
    }
}
function Write-Step([int]$Number, [string]$Title, [string]$Explain) {
    Complete-Step
    $script:CurStep = $Number; $script:CurTitle = $Title; $script:CurStart = Get-Date
    $filled = [int][math]::Round(10 * $Number / $TotalSteps)
    $bar = ($G.Full * $filled) + ($G.Empty * (10 - $filled))
    $label = ' STEG {0} AV {1}  ' -f $Number, $TotalSteps
    $titleMax = $UiWidth - 2 - $label.Length - 10 - 2
    $shown = if ($Title.Length -gt $titleMax) { $Title.Substring(0, $titleMax - 1) + '.' } else { $Title }
    Write-Host ''
    Write-Host ($G.TL + ($G.H * ($UiWidth - 2)) + $G.TR) -ForegroundColor DarkCyan
    Write-BoxLine @(@($label, 'Cyan'), @($bar, 'Cyan'), @(('  ' + $shown), 'White'))
    Write-Host ($G.BL + ($G.H * ($UiWidth - 2)) + $G.BR) -ForegroundColor DarkCyan
    if ($Explain) { foreach ($l in (Format-Wrap $Explain ($UiWidth - 4))) { Write-Host ('  ' + $l) -ForegroundColor DarkGray } }
    Write-Log 'STEG' ('Steg {0} av {1}: {2}' -f $Number, $TotalSteps, $Title)
}

# --- Rader under ett steg
function Write-Action($msg) {                       # "nu gör jag detta"
    Write-Log 'ÅTGÄRD' ([string]$msg)
    $lines = Format-Wrap ([string]$msg) ($UiWidth - 6)
    for ($i = 0; $i -lt $lines.Count; $i++) { Write-Host ($(if ($i -eq 0) { '   > ' } else { '     ' }) + $lines[$i]) -ForegroundColor White }
}
function Write-Ok($msg)    { Write-Log 'OK' ([string]$msg);     Write-Line 'OK' 'Green' ([string]$msg) 'Gray' }            # det gick bra
function Write-Warn2($msg) { Write-Log 'VARNING' ([string]$msg); Write-Line 'VARNING' 'Yellow' ([string]$msg) 'Yellow' }   # något gick fel, vi går vidare
function Write-Todo($msg)  { Write-Log 'GÖR' ([string]$msg);     Write-Line 'GÖR' 'Magenta' ([string]$msg) 'Magenta' }       # något DU ska göra
# En kontrollrad (förkontroll, rollkontroll): OK / INFO / VARNING / SAKNAS.
function Write-Check([string]$State, [string]$Name, [string]$Detail) {
    $color = switch ($State) { 'OK' { 'Green' } 'INFO' { 'Cyan' } 'VARNING' { 'Yellow' } default { 'Red' } }
    $msgColor = switch ($State) { 'VARNING' { 'Yellow' } 'SAKNAS' { 'Red' } default { 'Gray' } }
    Write-Log $State "${Name}: $Detail"
    Write-Line $State $color "${Name}: $Detail" $msgColor
}
function Write-KeyValue([string]$Key, [string]$Value) {
    Write-Host ('   {0,-11}' -f $Key) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

# --- Banner som visas först
function Write-Banner {
    Write-Host ''
    Write-Host ($G.DTL + ($G.DH * ($UiWidth - 2)) + $G.DTR) -ForegroundColor Cyan
    Write-BoxLine @(, @('', 'White')) 'Cyan' -Double
    Write-BoxLine @(@('   AZURE RAPPORTKIT', 'White'), @("   v$KitVersion", 'Cyan')) 'Cyan' -Double
    Write-BoxLine @(, @('   Kartlägger styrning, säkerhet och kostnad i en Azure-tenant', 'Gray')) 'Cyan' -Double
    Write-BoxLine @(, @('', 'White')) 'Cyan' -Double
    Write-BoxLine @(, @('   Skriver inget i Azure-resurser eller Entra-konfigurationen.', 'DarkGray')) 'Cyan' -Double
    Write-BoxLine @(, @('   Avbryt med Ctrl+C när som helst och kör om: det som är gjort återanvänds.', 'DarkGray')) 'Cyan' -Double
    Write-Host ($G.DBL + ($G.DH * ($UiWidth - 2)) + $G.DBR) -ForegroundColor Cyan
    Write-Log 'INFO' "Azure Rapportkit v$KitVersion startar"
}

# --- Statusetikett för en sammanfattningsrad
function Get-StateBadge([string]$State) {
    switch ($State) {
        'OK'     { return @('OK', 'Green') }
        'Fel'    { return @('FEL', 'Red') }
        'Delvis' { return @('DELVIS', 'Yellow') }
        default  { return @('HOPPAD', 'DarkGray') }
    }
}

# --- Sammanfattningsruta i slutet: en rad per verktyg med tid, noteringar och sökvägar.
function Write-SummaryBox($StatusTable, $Facts) {
    $toolStep = @{ 'Governance Visualizer' = 6; 'azqr' = 7; 'Maester' = 8; 'Defender och kostnad' = 9 }
    Write-Host ''
    Write-Host ($G.DTL + ($G.DH * ($UiWidth - 2)) + $G.DTR) -ForegroundColor Cyan
    Write-BoxLine @(, @('   SAMMANFATTNING', 'White')) 'Cyan' -Double
    Write-Host ($G.DBL + ($G.DH * ($UiWidth - 2)) + $G.DBR) -ForegroundColor Cyan
    foreach ($k in $StatusTable.Keys) {
        $s = $StatusTable[$k]
        $b = Get-StateBadge $s.State
        $dur = ''
        if ($toolStep.ContainsKey($k) -and $script:StepLog.Contains([string]$toolStep[$k]) -and $s.State -ne 'Hoppad över') { $dur = '   ' + (Format-Duration $script:StepLog[[string]$toolStep[$k]].Seconds) }
        Write-Host '  ' -NoNewline
        Write-Badge $b[0] $b[1]
        Write-Host ('  ' + $k) -NoNewline -ForegroundColor White
        Write-Host $dur -ForegroundColor DarkGray
        if ($s.State -in 'Fel', 'Delvis' -and $s.Note) {
            foreach ($l in (Format-Wrap $s.Note ($UiWidth - 14))) { Write-Host ((' ' * 13) + $l) -ForegroundColor Yellow }
        }
    }
    Write-Host ''
    foreach ($fact in $Facts) {
        $lines = Format-Wrap ([string]$fact[1]) ($UiWidth - 18)
        Write-Host ('  {0,-14}' -f $fact[0]) -NoNewline -ForegroundColor DarkGray
        Write-Host ($(if ($lines.Count) { $lines[0] } else { '' })) -ForegroundColor White
        for ($i = 1; $i -lt $lines.Count; $i++) { Write-Host ((' ' * 16) + $lines[$i]) -ForegroundColor White }
    }
    Write-Host ($G.H * $UiWidth) -ForegroundColor DarkCyan
}
# ===========================================================================
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
    $t + (Get-SignInHelp $ex.Message)
}

# Känner igen vanliga inloggningsfel i företagsmiljöer (Conditional Access, MFA, kompatibel enhet, blockerad app) och
# ger en text som kunden kan ta vidare till sin IT-avdelning. Tom sträng om inget känns igen.
function Get-SignInHelp([string]$Text) {
    if ($Text -match 'AADSTS(53000|53001|53002|53003|53004|530003|530004|50105|50020|700016|65001|900144|50076|50079|50158)|[Cc]onditional [Aa]ccess|compliant|blocked by|not compliant|device (is )?not') {
        return ' Det här ser ut som att tenantens villkorsstyrda åtkomst (Conditional Access) eller en consent-inställning stoppar inloggningen. Be IT att tillåta apparna "Microsoft Azure CLI", "Azure PowerShell" och "Microsoft Graph Command Line Tools" för ditt konto, eller kör scriptet från en hanterad/kompatibel dator.'
    }
    ''
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
function Set-Status($step, $state, $note = '') { $Status[$step] = @{ State = $state; Note = $note }; Write-Log 'STATUS' "$step = $state $note" }
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

# Går adressen att nå? Ett HTTP-svar (även 401/403/405) räknas som nåbart; bara uteblivet svar är fel.
function Test-Endpoint([string]$Url) {
    try { Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 8 -UseBasicParsing | Out-Null; return $true }
    catch { return [bool]$_.Exception.Response }
}

# Ställer en ja/nej-fråga. Standardsvaret är nej. -Yes svarar ja. Kan frågan inte ställas
# (ingen inmatning, t.ex. automatisk körning) fortsätter vi.
function Confirm-Continue([string]$Question) {
    if ($Yes) { Write-Host "  $Question -> ja (-Yes)" -ForegroundColor DarkCyan; return $true }
    try { $a = Read-Host "  $Question (j/N)" }
    catch { Write-Warn2 'Frågan kan inte ställas (ingen inmatning). Fortsätter.'; return $true }
    return [bool](("$a").Trim([char]0xFEFF).Trim() -match '^[jJyY]')
}

# Tillåter de effektiva behörigheterna ($Perms = svar från Microsoft.Authorization/permissions) åtgärden?
# Wildcards (*) i roller hanteras med -like; notActions drar bort.
function Test-ActionAllowed($Perms, [string]$Action) {
    foreach ($p in @($Perms)) {
        $ok = $false
        foreach ($a in @($p.actions)) { if ($Action -like $a) { $ok = $true; break } }
        if (-not $ok) { continue }
        $denied = $false
        foreach ($n in @($p.notActions)) { if ($Action -like $n) { $denied = $true; break } }
        if (-not $denied) { return $true }
    }
    return $false
}

# Anropar Azure Resource Manager via az rest (inget az-tillägg behövs). Försöker 3 gånger vid
# hastighetsbegränsning (429). Kastar fel med Azures meddelande om anropet misslyckas.
function Invoke-ArmRest([string]$Method, [string]$Url, $Body) {
    $azArgs = @('rest', '--method', $Method, '--url', $Url, '-o', 'json')
    $tmp = $null
    if ($Body) {
        $tmp = Join-Path $env:TEMP ('azrest-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 8))
        $azArgs += @('--body', "@$tmp")
    }
    try {
        for ($i = 1; $i -le 5; $i++) {
            $out = & az @azArgs 2>$null
            $code = $LASTEXITCODE
            # Vissa API:er (t.ex. Defender) ger exit-kod 1 trots fullständigt svar. Giltig JSON utan felfält accepteras.
            $text = ($out | Out-String).Trim()
            if ($text) {
                try { $parsed = $text | ConvertFrom-Json; if ($code -eq 0 -or -not $parsed.error) { return $parsed } } catch { }
            }
            if ($code -eq 0) { return $null }
            # Kör igen med stderr för att få felmeddelandet.
            $txt = (& az @azArgs 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) { return ($txt | ConvertFrom-Json) }
            # Hastighetsbegränsning (Cost Management är strikt): vänta allt längre och försök igen, upp till 5 gånger.
            if ($txt -match 'TooManyRequests|Too Many Requests|429' -and $i -lt 5) { Write-Host "      (begränsat av Azure, väntar $(15 * $i) s och försöker igen)" -ForegroundColor DarkGray; Start-Sleep -Seconds (15 * $i); continue }
            $short = ($txt -split "`n" | Where-Object { $_ -match 'ERROR|Error|error|message' } | Select-Object -First 1)
            throw $(if ($short) { $short.Trim() } else { $txt })
        }
    }
    finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

# Kontrollerar det inloggade kontots roller (Azure på tenant root, Entra via Graph) mot det som valda verktyg behöver.
# Ger en lista med State (OK/VARNING/SAKNAS/INFO), Kind (Azure/Entra), Role, Name och Detail.
function Get-RoleChecks([string]$Tenant, [bool]$NeedGovViz, [bool]$NeedPortal, [bool]$NeedMaester) {
    $res = [System.Collections.Generic.List[object]]::new()
    $add = { param($s, $k, $role, $d) $res.Add([pscustomobject]@{ State = $s; Kind = $k; Role = $role; Name = $role; Detail = $d }) }

    # Roller som är tilldelade på tenant root (inklusive via grupper) samt effektiva behörigheter där och på första subscription.
    $names = @()
    $meId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($meId) { $names = @(az role assignment list --scope '/' --assignee $meId --include-inherited --include-groups --query '[].roleDefinitionName' -o tsv 2>$null | Where-Object { $_ }) }
    $rootPerms = $null; $subPerms = $null
    try { $rootPerms = (az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/$Tenant/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json 2>$null | ConvertFrom-Json).value } catch { }
    $firstSub = az account list --query '[0].id' -o tsv 2>$null
    if ($firstSub) { try { $subPerms = (az rest --method get --url "https://management.azure.com/subscriptions/$firstSub/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json 2>$null | ConvertFrom-Json).value } catch { } }
    $have = if ($names.Count) { $names -join ', ' } else { 'inga på tenant root' }

    # Läsrätt på tenant root. Governance Visualizer testar bara att management group går att läsa, så vilken roll
    # som ger läsrätten spelar ingen roll. Rollen Reader är ändå rekommenderad (minst rättigheter): har kontot
    # fler roller än Reader skriver verktyget en "least privilege"-rekommendation (som scriptet inte låter pausa).
    $effRoot = Test-ActionAllowed $rootPerms 'Microsoft.Management/managementGroups/read'
    $effSub = Test-ActionAllowed $subPerms 'Microsoft.Resources/subscriptions/resources/read'
    if ($names -contains 'Reader') { & $add 'OK' 'Azure' 'Reader' 'tilldelad på tenant root' }
    elseif ($effRoot) { & $add 'OK' 'Azure' 'Reader' "läsrätt på tenant root finns via annan roll ($have). Rollen Reader rekommenderas men krävs inte." }
    elseif ($effSub) { & $add 'VARNING' 'Azure' 'Reader' 'saknas på tenant root men finns på subscription: azqr och portaldata fungerar, Governance Visualizer (kräver tenant root) gör det inte' }
    else { & $add 'SAKNAS' 'Azure' 'Reader' "saknas (har: $have)" }

    if ($NeedPortal) {
        foreach ($d in @(@{ Role = 'Security Reader'; Action = 'Microsoft.Security/assessments/read'; Why = 'Defender-data' }, @{ Role = 'Cost Management Reader'; Action = 'Microsoft.CostManagement/query/read'; Why = 'kostnadsdata' })) {
            if ($names -contains $d.Role) { & $add 'OK' 'Azure' $d.Role 'tilldelad på tenant root' }
            elseif (Test-ActionAllowed $rootPerms $d.Action) { & $add 'OK' 'Azure' $d.Role "behörighet för $($d.Why) finns via annan roll" }
            elseif (Test-ActionAllowed $subPerms $d.Action) { & $add 'VARNING' 'Azure' $d.Role "saknas på tenant root men $($d.Why) går att hämta på subscription-nivå" }
            else { & $add 'SAKNAS' 'Azure' $d.Role "saknas, så $($d.Why) kan inte hämtas" }
        }
    }

    # Entra ID-roll för Maester (Global Reader eller Global Administrator), läst via Microsoft Graph.
    if ($NeedMaester) {
        $dirRoles = @(az rest --method get --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName' --query 'value[].displayName' -o tsv 2>$null | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { & $add 'INFO' 'Entra' 'Global Reader' 'kunde inte kontrolleras här (kontrolleras när Maester loggar in)' }
        elseif ($dirRoles -contains 'Global Reader' -or $dirRoles -contains 'Global Administrator') { & $add 'OK' 'Entra' 'Global Reader' "Entra-roll finns ($($dirRoles -join ', '))" }
        else { & $add 'SAKNAS' 'Entra' 'Global Reader' 'saknas i Entra ID (Global Reader eller Global Administrator behövs för Maester)' }
    }
    $res
}

# Ger instruktioner (en rad per element) för att lägga till de roller som saknas.
function Get-RoleInstructions($Missing) {
    $azure = @($Missing | Where-Object { $_.Kind -eq 'Azure' })
    $entra = @($Missing | Where-Object { $_.Kind -eq 'Entra' })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Använder ni Privileged Identity Management (PIM)? Aktivera då rollerna först (Entra ID > Privileged Identity Management > My roles) och kör om. Inget saknas då, rollerna är bara inte aktiva.')
    if ($azure.Count) {
        $lines.Add('Azure-roller (på tenant root, scope "/"):')
        $lines.Add('1. Entra ID > Properties > "Access management for Azure resources" = Yes. Spara, logga ut och in igen.')
        $lines.Add('2. Kör i PowerShell:')
        $lines.Add('     $me = az ad signed-in-user show --query id -o tsv')
        foreach ($r in $azure) { $lines.Add(('     az role assignment create --assignee-object-id $me --assignee-principal-type User --role "{0}" --scope "/"' -f $r.Role)) }
        $lines.Add('3. Sätt "Access management for Azure resources" tillbaka till No. Rollerna kan ta någon minut att slå igenom.')
    }
    if ($entra.Count) { $lines.Add('Entra-roll: Entra ID > Roles and administrators > Global Reader > Add assignments > välj ditt konto.') }
    $lines
}

# Ställer en ja/nej-fråga med standardsvar. -Yes svarar ja. Kan frågan inte ställas (ingen inmatning) används standardsvaret.
function Read-YesNo([string]$Question, [bool]$DefaultYes = $true) {
    if ($Yes) { Write-Log 'INFO' "$Question -> ja (-Yes)"; return $true }
    $hint = if ($DefaultYes) { 'J/n' } else { 'j/N' }
    try { $a = Read-Host "  $Question ($hint)" } catch { return $DefaultYes }
    $a = ("$a").Trim([char]0xFEFF).Trim()
    if (-not $a) { return $DefaultYes }
    return [bool]($a -match '^[jJyY]')
}

# Kontrollerar SHA256 för en nedladdad fil mot den testade kontrollsumman. Stämmer den inte avbryts körningen, om inte
# -AllowUnverified (eller -LatestTools, som inte har några kontrollsummor) är satt.
function Assert-FileHash([string]$Path, [string]$Expected, [string]$What) {
    if (-not $Expected) { return }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -eq $Expected) { Write-Ok "${What}: kontrollsumman (SHA256) stämmer med den testade versionen"; return }
    if ($AllowUnverified) { Add-Warning "${What}: kontrollsumman stämmer inte (väntade $Expected, fick $actual). Fortsätter eftersom -AllowUnverified är satt."; return }
    Fail "${What}: kontrollsumman (SHA256) stämmer inte med den testade versionen (väntade $($Expected.Substring(0, 16))..., fick $($actual.Substring(0, 16))...). Filen kan vara ändrad eller skadad." 'Kör om scriptet för att hämta filen igen. Upprepas felet: kontakta den som gav dig scriptet. Först efter egen kontroll kan -AllowUnverified användas.'
}

# Mappväljare (dialogruta). Ger $null om den inte kan visas eller om användaren avbryter.
function Show-FolderDialog {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Välj en mapp. En undermapp "rapportkit" skapas där för resultatet.'
        $d.ShowNewFolderButton = $true
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return (Join-Path $d.SelectedPath 'rapportkit') }
    }
    catch { Write-Warn2 'Mappväljaren kunde inte öppnas. Skriv sökvägen istället.' }
    return $null
}

# Varningar för en vald resultatmapp: OneDrive (synkas till molnet), mappar som Windows skyddar mot skrivning
# (Kontrollerad mappåtkomst) och för långa sökvägar (gräns 260 tecken).
function Get-OutputRootWarnings([string]$Path) {
    $w = [System.Collections.Generic.List[string]]::new()
    $full = try { [IO.Path]::GetFullPath($Path) } catch { $Path }
    foreach ($e in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
        $v = [Environment]::GetEnvironmentVariable($e)
        if ($v -and $full -like "$v*") { $w.Add('Mappen ligger i OneDrive: resultatet (som är konfidentiellt) synkas då till molnet.'); break }
    }
    foreach ($sf in 'MyDocuments', 'Desktop', 'MyPictures', 'MyVideos', 'MyMusic') {
        $p = try { [Environment]::GetFolderPath($sf) } catch { $null }
        if ($p -and $full -like "$p*") { $w.Add("Mappen ligger under $sf, som Windows kan skydda mot skrivning från okända program (Kontrollerad mappåtkomst)."); break }
    }
    if ($full.Length -gt 90) { $w.Add('Sökvägen är lång. Verktygens filnamn blir långa och Windows har en gräns på 260 tecken.') }
    , $w
}

# Frågar var resultatet ska sparas. Anges -OutputRoot (eller kan frågan inte ställas) används den/standardmappen.
function Select-OutputRoot([string]$Given) {
    if ($Given) { return $Given }
    $profileDir = Join-Path $env:USERPROFILE 'rapportkit'
    if ($Yes -or [Console]::IsInputRedirected) { Write-Action "Resultatmapp (standard): $profileDir"; return $profileDir }
    Write-Host ''
    Write-Host '  Var ska resultatet sparas?' -ForegroundColor White
    Write-Host '  Det innehåller konfidentiell information om miljön. Verktygen hämtas också dit.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("    [1] {0}   (rekommenderas)" -f $profileDir)
    Write-Host '    [2] C:\rapportkit'
    Write-Host '    [3] Annan mapp: skriv sökvägen här, eller [B] för att bläddra'
    Write-Host ''
    while ($true) {
        try { $a = Read-Host '  Välj [Enter = 1]' } catch { return $profileDir }
        $a = ("$a").Trim([char]0xFEFF).Trim().Trim('"')
        if (-not $a -or $a -eq '1') { $p = $profileDir }
        elseif ($a -eq '2') { $p = 'C:\rapportkit' }
        elseif ($a -match '^[bB]$') { $p = Show-FolderDialog; if (-not $p) { continue } }
        elseif ($a -eq '3') { Write-Host '  Skriv sökvägen (t.ex. D:\rapportkit) eller B för att bläddra.'; continue }
        else { $p = [Environment]::ExpandEnvironmentVariables($a) }
        if (-not [IO.Path]::IsPathRooted($p)) { Write-Warn2 'Ange en fullständig sökväg (t.ex. D:\rapportkit).'; continue }
        $warn = Get-OutputRootWarnings $p
        if ($warn.Count) {
            foreach ($x in $warn) { Write-Warn2 $x }
            if (-not (Read-YesNo "Använda $p ändå?" $false)) { continue }
        }
        return $p
    }
}

# Loggar ut från de sessioner scriptet själv skapade (en inloggning som fanns innan rörs inte), om inte -KeepLogin är satt.
# På en kunds dator ska inga tokens ligga kvar efter körningen.
function Invoke-SessionCleanup {
    $targets = [System.Collections.Generic.List[string]]::new()
    if ($azReady -and -not $azWasLoggedIn) { $targets.Add('Azure CLI') }
    if ($azPsByUs) { $targets.Add('Azure PowerShell') }
    if ($graphByUs) { $targets.Add('Microsoft Graph') }
    if (-not $targets.Count) { return }
    $list = $targets -join ', '
    if ($KeepLogin) { Write-Action "Inloggningarna ($list) lämnas kvar (-KeepLogin)."; return }
    Write-Host ''
    if (-not (Read-YesNo "Logga ut från $list, som scriptet loggade in? (rekommenderas på en kunds dator)" $true)) { Write-Action "Inloggningarna ($list) lämnas kvar."; return }
    if ($targets -contains 'Azure CLI') { try { az logout 2>$null | Out-Null; Write-Ok 'Utloggad från Azure CLI' } catch { Write-Warn2 'Kunde inte logga ut från Azure CLI (kör az logout).' } }
    if ($targets -contains 'Azure PowerShell') { try { Disconnect-AzAccount -ErrorAction Stop | Out-Null; Write-Ok 'Utloggad från Azure PowerShell' } catch { Write-Warn2 'Kunde inte logga ut från Azure PowerShell (kör Disconnect-AzAccount).' } }
    if ($targets -contains 'Microsoft Graph') { try { Disconnect-MgGraph -ErrorAction Stop | Out-Null; Write-Ok 'Utloggad från Microsoft Graph' } catch { Write-Warn2 'Kunde inte logga ut från Microsoft Graph (kör Disconnect-MgGraph).' } }
}

# Version av en installerad modul (högsta), eller $null.
function Get-ModuleVersionText([string]$Name) {
    $m = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    if ($m) { $m.Version.ToString() } else { $null }
}

# Maskinläsbar sammanfattning av körningen (run-summary.json i resultatmappen): bevis på vad som kördes, med vilka
# versioner, hur lång tid det tog och hur det gick.
function Write-RunSummary([int]$Code) {
    if (-not $RunDir -or -not (Test-Path $RunDir)) { return }
    $end = Get-Date
    $obj = [ordered]@{
        kitVersion      = $KitVersion
        startedAt       = $script:RunStart.ToString('s')
        finishedAt      = $end.ToString('s')
        durationSeconds = [math]::Round(($end - $script:RunStart).TotalSeconds, 1)
        exitCode        = $Code
        tenantId        = $TenantId
        period          = $Period
        options         = [ordered]@{ hidePersonalData = [bool]$HidePersonalData; latestTools = [bool]$LatestTools; offline = [bool]$Offline; skipGovViz = [bool]$SkipGovViz; skipAzqr = [bool]$SkipAzqr; skipMaester = [bool]$SkipMaester; skipPortal = [bool]$SkipPortal; managementGroupId = $ManagementGroupId; maxPortalSubscriptions = $MaxPortalSubscriptions }
        environment     = [ordered]@{ os = [Environment]::OSVersion.VersionString; powershell = $PSVersionTable.PSVersion.ToString(); computer = $env:COMPUTERNAME }
        tools           = [ordered]@{ governanceVisualizer = $GvVersion; azqrPinned = $Pins.Azqr; azAccounts = (Get-ModuleVersionText 'Az.Accounts'); maester = (Get-ModuleVersionText 'Maester'); pester = (Get-ModuleVersionText 'Pester') }
        results         = @($Status.Keys | ForEach-Object { [ordered]@{ name = $_; state = $Status[$_].State; note = $Status[$_].Note } })
        steps           = @($script:StepLog.Keys | ForEach-Object { [ordered]@{ step = [int]$_; title = $script:StepLog[$_].Title; seconds = $script:StepLog[$_].Seconds } })
        warnings        = @($Warnings)
    }
    try { $obj | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $RunDir 'run-summary.json') -Encoding utf8 } catch { }
}

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
function Install-WithWinget([string]$Name, [string]$Id, [string]$Command, [string]$ManualUrl, [string]$Version) {
    if (-not (Test-Cmd winget)) {
        Fail "$Name saknas och winget finns inte, så det kan inte installeras automatiskt." "Installera $Name manuellt ($ManualUrl), öppna ett NYTT PowerShell-fönster och kör om scriptet."
    }
    $wa = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($Version) { $wa += @('--version', $Version) }
    Write-Action "winget $($wa -join ' ')  (kan öppna ett godkännande-fönster: välj Ja)"
    winget @wa | Out-Host
    Update-SessionPath
    if (-not (Test-Cmd $Command)) {
        Fail "$Name installerades inte (winget slutkod $LASTEXITCODE)." "Installera $Name manuellt ($ManualUrl), öppna ett NYTT PowerShell-fönster och kör om scriptet."
    }
    Write-Ok "$Name installerad"
}

# Hämtar en PowerShell-modul till vår egen modulmapp ($ModDir) och kontrollerar att den går att hitta.
# Egen mapp används för att undvika problem när Dokument är omdirigerat till OneDrive.
# $MinVersion/$MaxVersion = godkänt intervall för redan installerade versioner (max räknas som "lägre än"). Finns ingen
# godkänd version hämtas $Pin (den testade versionen), eller senaste inom intervallet om $Pin saknas (-LatestTools).
# Versionen kontrolleras: Windows har t.ex. en inbyggd Pester 3.4 som inte duger åt Maester (kräver 5.5+).
function Install-PsModule([string]$Name, [string]$Pin, [string]$MinVersion, [string]$MaxVersion) {
    $have = @(Get-Module -ListAvailable -Name $Name)
    if ($MinVersion) { $have = @($have | Where-Object { $_.Version -ge [version]$MinVersion }) }
    if ($MaxVersion) { $have = @($have | Where-Object { $_.Version -lt [version]$MaxVersion }) }
    if ($have.Count) { Write-Ok "Modul $Name finns redan (version $($have[0].Version))"; return }
    if (Test-Path "$ToolsDir\modules\$Name") {            # offline-bundle
        Write-Action "Kopierar modul $Name från tools\modules"
        Copy-Item "$ToolsDir\modules\$Name" $ModDir -Recurse -Force
    }
    elseif (-not $Offline) {
        Write-Action "Hämtar modul $Name $Pin från PowerShell Gallery"
        try {
            if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
                $p = @{ Name = $Name; Path = $ModDir; TrustRepository = $true; Quiet = $true }
                if ($Pin) { $p.Version = $Pin }
                elseif ($MinVersion) { $p.Version = if ($MaxVersion) { "[$MinVersion,$MaxVersion)" } else { "[$MinVersion,)" } }
                Save-PSResource @p
            }
            else {
                Install-PackageProvider NuGet -Scope CurrentUser -Force | Out-Null
                $p = @{ Name = $Name; Path = $ModDir; Force = $true }
                if ($Pin) { $p.RequiredVersion = $Pin }
                else {
                    if ($MinVersion) { $p.MinimumVersion = $MinVersion }
                    if ($MaxVersion) { $p.MaximumVersion = $MaxVersion }
                }
                Save-Module @p
            }
        }
        catch { Fail "Kunde inte hämta modulen $Name från PowerShell Gallery: $($_.Exception.Message)" 'Kontrollera internetanslutningen (www.powershellgallery.com) och kör om scriptet.' }
    }
    else { Fail "Modulen $Name finns inte i tools\modules och -Offline är satt." 'Bygg om bundlen med Build-Bundle.ps1 eller kör utan -Offline.' }
    $have = @(Get-Module -ListAvailable -Name $Name)
    if ($MinVersion) { $have = @($have | Where-Object { $_.Version -ge [version]$MinVersion }) }
    if (-not $have.Count) { Fail "Modulen $Name hämtades men gick inte att hitta i $ModDir." 'Radera mappen och kör om scriptet.' }
    Write-Ok "Modul $Name klar (version $($have[0].Version))"
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
    Write-Banner
    Write-Step 1 'Förberedelser' 'Tenant-ID, var resultatet sparas och loggfil. Tar några sekunder.'
    Update-SessionPath

    # Tenant-ID: använd parametern, annars föreslå det Azure CLI redan är inloggat mot. Förslaget kommer
    # alltså från den inloggning som redan finns på datorn (az account show); inget tenant-ID är sparat i scriptet.
    if (-not $TenantId) {
        $guess = $null
        if (Test-Cmd az) {
            try {
                $guess = az account show --query tenantId -o tsv 2>$null
                $who = az account show --query user.name -o tsv 2>$null
            } catch { }
        }
        $prompt = 'Ange tenant-ID (Entra ID > Overview > Tenant ID)'
        if ($guess) { $prompt += " [Enter = $guess, hämtat från Azure CLI-inloggningen som $who]" }
        try { $TenantId = Read-Host $prompt } catch { $TenantId = $null }
        if (-not $TenantId) { $TenantId = $guess }
    }
    if (-not $TenantId) { Fail 'Tenant-ID saknas.' 'Kör om med -TenantId <guid> (hittas i Entra ID > Overview).' }
    if ($TenantId -notmatch '^[0-9a-fA-F-]{36}$') { Fail "Ogiltigt tenant-ID: '$TenantId' (ett GUID förväntas)." 'Kopiera Tenant ID från Entra ID > Overview och kör om.' }
    $BoundParams['TenantId'] = $TenantId        # så att "kör om"-kommandot inte frågar igen
    Write-Ok "Tenant: $TenantId"

    # Var ska resultatet ligga? Anges inte -OutputRoot frågar vi (med varning för OneDrive och skyddade mappar).
    $OutputRoot = Select-OutputRoot $OutputRoot
    $BoundParams['OutputRoot'] = $OutputRoot        # så att "kör om"-kommandot använder samma mapp

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

    # Loggar: en rensad logg (rapportkit.log) och hela konsolutskriften inklusive verktygens text (rapportkit-console.log).
    Initialize-Log $RunDir
    try { Start-Transcript -Path (Join-Path $RunDir 'rapportkit-console.log') -Append | Out-Null; $TranscriptStarted = $true } catch { Write-Warn2 'Kunde inte starta konsolloggen (fortsätter ändå).' }
    Write-Host ''
    Write-KeyValue 'Tenant' $TenantId
    Write-KeyValue 'Period' $Period
    Write-KeyValue 'Resultat' $RunDir
    Write-KeyValue 'Loggar' 'rapportkit.log (rensad), rapportkit-console.log (allt), run-summary.json'

    if ($ReportOnly) { Write-Action '-ReportOnly: hoppar över steg 2-9 och bygger bara rapporten.' }
    else {

        # ===================================================================
        # STEG 2: Förkontroll. Kontrollerar förutsättningarna INNAN något hämtas eller installeras,
        # visar vad som saknas och låter dig välja om du vill fortsätta ändå.
        # ===================================================================
        Write-Step 2 'Förkontroll av förutsättningar' 'Kontrollerar att allt som behövs finns eller går att hämta, innan något installeras. Saknas något får du välja om du vill fortsätta ändå.'
        $checks = [System.Collections.Generic.List[object]]::new()
        function Add-Check([string]$State, [string]$Name, [string]$Detail) { $checks.Add([pscustomobject]@{ State = $State; Name = $Name; Detail = $Detail }) }

        # Program och moduler: finns de redan, eller måste de hämtas?
        $need = [System.Collections.Generic.List[string]]::new()
        $wingetNeeded = $false
        # Azure CLI behövs alltid: inloggning, rollkontroll, azqr och Defender/kostnadsdata.
        if (-not (Test-Cmd az)) { $need.Add('Azure CLI (winget)'); $wingetNeeded = $true }
        if (-not $SkipAzqr) {
            if (-not (Test-Cmd azqr) -and -not (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'azqr') -Recurse -Filter 'azqr.exe' -ErrorAction SilentlyContinue)) { $need.Add('azqr (winget/GitHub)'); $wingetNeeded = $true }
        }
        if (-not $SkipGovViz) {
            if (-not (Test-Path (Join-Path $GvDir 'pwsh\AzGovVizParallel.ps1'))) { $need.Add("Governance Visualizer $GvVersion (GitHub)") }
            foreach ($m in 'Az.Accounts', 'AzAPICall') { if (-not (Get-Module -ListAvailable -Name $m)) { $need.Add("modulen $m (PSGallery)") } }
        }
        if (-not $SkipMaester) {
            if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.5.0' })) { $need.Add('modulen Pester 5.5+ (PSGallery)') }
            if (-not (Get-Module -ListAvailable -Name Maester)) { $need.Add('modulen Maester (PSGallery)') }
        }
        if (-not $need.Count) { Add-Check 'OK' 'Verktyg' 'allt som behövs finns redan på datorn' }
        elseif ($NoInstall) { Add-Check 'SAKNAS' 'Verktyg' "saknas men -NoInstall är satt: $($need -join ', ')" }
        elseif ($Offline) {
            if (Test-Path $ToolsDir) { Add-Check 'INFO' 'Verktyg' "hämtas från tools\ (offline): $($need -join ', ')" }
            else { Add-Check 'SAKNAS' 'Verktyg' "-Offline är satt men mappen tools\ saknas. Behövs: $($need -join ', ')" }
        }
        else { Add-Check 'INFO' 'Verktyg' "hämtas/installeras: $($need -join ', ')" }

        # winget behövs för Azure CLI och azqr (azqr har en reservväg via GitHub).
        if ($wingetNeeded -and -not $NoInstall -and -not $Offline) {
            if (Test-Cmd winget) { Add-Check 'OK' 'winget' 'finns' }
            else { Add-Check 'SAKNAS' 'winget' 'finns inte: Azure CLI måste installeras manuellt (https://aka.ms/installazurecliwindows)' }
        }

        # Nätverk: det som behövs för nedladdning, och det som behövs för inloggning och körning.
        $endpoints = @()
        if ($need.Count -and -not $Offline -and -not $NoInstall) {
            if (@($need -match 'GitHub|winget').Count) { $endpoints += , @('github.com', 'https://github.com', 'hämtar Governance Visualizer/azqr') }
            if (@($need -match 'PSGallery').Count) { $endpoints += , @('www.powershellgallery.com', 'https://www.powershellgallery.com', 'hämtar PowerShell-moduler') }
        }
        $endpoints += , @('login.microsoftonline.com', 'https://login.microsoftonline.com', 'inloggning')
        if (-not $SkipGovViz -or -not $SkipAzqr) { $endpoints += , @('management.azure.com', 'https://management.azure.com', 'Azure Resource Manager') }
        if (-not $SkipMaester) { $endpoints += , @('graph.microsoft.com', 'https://graph.microsoft.com', 'Microsoft Graph (Maester)') }
        foreach ($e in $endpoints) {
            if (Test-Endpoint $e[1]) { Add-Check 'OK' "Nätverk $($e[0])" $e[2] }
            else { Add-Check 'SAKNAS' "Nätverk $($e[0])" "går inte att nå ($($e[2])). Kontrollera internet, proxy och brandvägg." }
        }

        # Diskutrymme, Windows-behörighet och om frågor kan besvaras.
        try {
            $drive = Get-PSDrive -Name ($RunDir.Substring(0, 1)) -ErrorAction Stop
            if ($drive.Free -lt 1GB) { Add-Check 'VARNING' 'Diskutrymme' ("bara {0:N1} GB kvar på {1}: (minst 1 GB rekommenderas)" -f ($drive.Free / 1GB), $drive.Name) }
            else { Add-Check 'OK' 'Diskutrymme' ("{0:N1} GB ledigt på {1}:" -f ($drive.Free / 1GB), $drive.Name) }
        }
        catch { }
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Add-Check 'INFO' 'Windows-behörighet' $(if ($isAdmin) { 'förhöjd (administratör). Krävs inte.' } else { 'vanlig användare. Räcker; Windows kan be om godkännande (UAC) vid installation av PowerShell 7/Azure CLI.' })
        if ([Console]::IsInputRedirected) { Add-Check 'VARNING' 'Interaktivt fönster' 'inmatning är omdirigerad: frågor går inte att besvara och inloggning kan misslyckas' }
        # AppLocker/WDAC sätter PowerShell i begränsat läge, där scriptets .NET-anrop blockeras och körningen går sönder mitt i.
        $langMode = $ExecutionContext.SessionState.LanguageMode
        if ($langMode -ne 'FullLanguage') { Add-Check 'SAKNAS' 'PowerShell-läge' "begränsat läge ($langMode), t.ex. via AppLocker/WDAC. Scriptet använder anrop som blockeras. Be IT om undantag, eller kör på en annan dator." }
        else { Add-Check 'OK' 'PowerShell-läge' 'FullLanguage' }
        $gpoPolicy = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined' })
        if ($gpoPolicy.Count) { Add-Check 'INFO' 'Körpolicy (grupprincip)' ("styrs av grupprincip: " + (($gpoPolicy | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', ') + ". -ExecutionPolicy Bypass gäller inte då; fungerar det här steget går scriptet att köra.") }
        Add-Check 'INFO' 'Behörigheter i Azure' 'kontrolleras direkt efter inloggningen i steg 3 (Reader, Security Reader, Cost Management Reader, Global Reader); saknas något får du välja att avsluta'

        foreach ($c in $checks) { Write-Check $c.State $c.Name $c.Detail }
        $problems = @($checks | Where-Object { $_.State -in 'SAKNAS', 'VARNING' })
        if ($problems.Count) {
            Write-Host ''
            if (-not (Confirm-Continue "$($problems.Count) förutsättning(ar) saknas eller är osäkra (se ovan). Fortsätta ändå?")) {
                Fail 'Avbrutet på din begäran efter förkontrollen.' 'Åtgärda det som är markerat SAKNAS/VARNING ovan och kör om scriptet.'
            }
        }
        else { Write-Ok 'Förkontrollen gav inga anmärkningar' }

        # ===================================================================
        # STEG 3: Azure CLI, inloggning och rollkontroll. Görs före all övrig hämtning så att du får veta
        # direkt om roller saknas.
        # ===================================================================
        Write-Step 3 'Azure CLI, inloggning och rollkontroll' 'Installerar Azure CLI om det saknas, loggar in (ett webbläsarfönster öppnas) och kontrollerar att kontot har rätt roller, innan resten hämtas. Hinner du inte: tryck Ctrl+C och kör om scriptet.'
        $azReady = $false
        $subCount = 0
        try {
            if (Test-Cmd az) { Write-Ok 'Azure CLI finns redan' }
            elseif ($NoInstall) { Fail 'Azure CLI saknas (-NoInstall är satt).' 'Installera Azure CLI (https://aka.ms/installazurecliwindows) och kör om.' }
            else { Install-WithWinget 'Azure CLI' 'Microsoft.AzureCLI' 'az' 'https://aka.ms/installazurecliwindows' }

            $cur = az account show --query tenantId -o tsv 2>$null
            $azWasLoggedIn = ($cur -eq $TenantId)        # fanns inloggningen redan? Då loggar vi inte ut den i slutet.
            if ($cur -eq $TenantId) { Write-Ok 'Azure CLI är redan inloggad mot rätt tenant' }
            else {
                Write-Todo 'Logga in i webbläsarfönstret som öppnas (Azure CLI)...'
                $loginLines = [System.Collections.Generic.List[string]]::new()
                # Utskriften visas (enhetskoden vid -DeviceLogin måste synas) men sparas också.
                if ($DeviceLogin) { az login --tenant $TenantId --use-device-code --allow-no-subscriptions --only-show-errors 2>&1 | ForEach-Object { $loginLines.Add("$_"); $_ } | Out-Host }
                else              { az login --tenant $TenantId --allow-no-subscriptions --only-show-errors 2>&1 | ForEach-Object { $loginLines.Add("$_"); $_ } | Out-Host }
            }
            if ((az account show --query tenantId -o tsv 2>$null) -ne $TenantId) {
                Fail ('Azure CLI-inloggningen mot rätt tenant slutfördes inte.' + (Get-SignInHelp ($loginLines -join ' '))) 'Kör om scriptet och logga in när webbläsarfönstret öppnas (eller använd -DeviceLogin).'
            }
            # (Räknas i PowerShell: parenteser i --query förstörs av az.cmd:s citering.)
            # Bara aktiva prenumerationer räknas (inaktiva ger bara fel).
            $subCount = @(az account list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' }).Count
            Write-Ok "Azure CLI inloggad ($subCount subscription(s) synliga)"
            $azReady = $true
        }
        catch {
            $m = Get-ErrorText $_
            Write-Warn2 $m
            foreach ($tool in 'azqr', 'Defender och kostnad') { Set-Status $tool 'Fel' "Azure CLI-inloggning saknas: $m" }
            $SkipAzqr = $true; $SkipPortal = $true
        }
        if ($azReady -and $subCount -lt 1) {
            Write-Warn2 'Kontot ser ingen subscription i tenanten, så azqr och Defender/kostnad kan inte köras. Tilldela rollen Reader (se README).'
            foreach ($tool in 'azqr', 'Defender och kostnad') { Set-Status $tool 'Fel' 'Kontot har inte åtkomst till någon subscription i tenanten. Tilldela rollen Reader (se README).' }
            $SkipAzqr = $true; $SkipPortal = $true
        }

        # Rollkontroll: har kontot de roller som de valda verktygen behöver? Saknas något visas hur du lägger till dem,
        # och du väljer om du vill avsluta (standard) eller fortsätta ändå.
        if ($azReady) {
            Write-Action 'Kontrollerar kontots roller'
            $roleChecks = @(Get-RoleChecks -Tenant $TenantId -NeedGovViz (-not $SkipGovViz) -NeedPortal (-not $SkipPortal) -NeedMaester (-not $SkipMaester))
            foreach ($c in $roleChecks) { Write-Check $c.State $c.Role $c.Detail }
            $missingRoles = @($roleChecks | Where-Object { $_.State -eq 'SAKNAS' })
            if ($missingRoles.Count) {
                Write-Host ''
                Write-Line 'ÅTGÄRD' 'Yellow' 'Så här lägger du till de roller som saknas (görs av en Global Administrator):' 'Yellow'
                foreach ($line in (Get-RoleInstructions $missingRoles)) { Write-Host "             $line" -ForegroundColor White; Write-Log 'ÅTGÄRD' $line }
                Write-Host ''
                if (-not (Confirm-Continue "$($missingRoles.Count) roll(er) saknas. Fortsätta ändå (delar av körningen kan misslyckas)?")) {
                    Fail 'Avbrutet: roller som behövs saknas.' 'Lägg till rollerna enligt instruktionen ovan (logga ut och in efteråt) och kör om scriptet.'
                }
            }
            else { Write-Ok 'Rollerna ser ut att stämma' }
        }

        # ===================================================================
        # STEG 4: Beroenden. Varje verktyg hämtas för sig; misslyckas ett stängs just det
        # verktyget av (status "Fel") och de andra körs vidare.
        # ===================================================================
        Write-Step 4 'Hämtar och installerar beroenden' 'Bara det som saknas på den här datorn. Första gången tar det 5-10 minuter.'
        if ($NoInstall) { Write-Warn2 '-NoInstall: hoppar över all hämtning och installation.' }
        if ($LatestTools) { Write-Warn2 '-LatestTools: senaste versioner används och kontrollsummor hoppas över. Resultatet är inte testat med dessa.' }
        else { Write-Action ("Testade versioner: azqr {0}, Governance Visualizer {1}, Maester {2}, Pester {3}, Az.Accounts {4}" -f $Pins.Azqr, $GvVersion, $Pins.Maester, $Pins.Pester, $Pins.AzAccounts) }

        # (Azure CLI installerades redan i steg 3.)

        # azqr: först winget (fast version; winget kontrollerar själv installationsfilens hash), annars hämtas samma version
        # som zip direkt från GitHub och kontrolleras mot den testade kontrollsumman. Zippen packar upp azqr.exe i en
        # undermapp (bin\windows_amd64), så vi letar upp den där.
        if (-not $SkipAzqr) {
            try {
                $azqrDir = Join-Path $env:LOCALAPPDATA 'azqr'
                $azqrExe = Get-ChildItem $azqrDir -Recurse -Filter 'azqr.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($azqrExe -and $env:Path -notlike "*$($azqrExe.DirectoryName)*") { $env:Path += ";$($azqrExe.DirectoryName)" }
                if (Test-Cmd azqr) { Write-Ok 'azqr finns redan' }
                elseif ($NoInstall) { Fail 'azqr saknas (-NoInstall är satt).' 'Installera azqr (winget install azqr) och kör om.' }
                else {
                    try { Install-WithWinget 'azqr' 'Microsoft.Azure.QuickReview' 'azqr' 'https://github.com/Azure/azqr/releases' $Pins.Azqr }
                    catch {
                        Write-Warn2 "winget gav inget resultat ($($_.Exception.Message)). Hämtar azqr direkt från GitHub."
                        $zip = Join-Path $env:TEMP 'azqr.zip'
                        if (Test-Path "$ToolsDir\azqr.zip") { Copy-Item "$ToolsDir\azqr.zip" $zip -Force }
                        else {
                            $azqrUrl = $AzqrZipUrl
                            if ($LatestTools) {
                                $rel = Invoke-RestMethod 'https://api.github.com/repos/Azure/azqr/releases/latest' -Headers @{ 'User-Agent' = 'azure-rapportkit' }
                                $asset = $rel.assets | Where-Object name -like 'azqr-win-amd64.zip' | Select-Object -First 1
                                if (-not $asset) { Fail 'Hittade ingen Windows-zip i senaste azqr-releasen.' 'Hämta azqr manuellt från https://github.com/Azure/azqr/releases och kör om.' }
                                $azqrUrl = $asset.browser_download_url
                            }
                            Get-Download $azqrUrl $zip 1MB
                        }
                        Assert-FileHash $zip $Pins.AzqrSha256 'azqr'
                        if (-not (Test-Zip $zip '*azqr.exe')) { Fail 'Den nedladdade azqr-filen är skadad eller innehåller inte azqr.exe.' 'Kör om scriptet för att hämta den igen.' }
                        Expand-Archive $zip $azqrDir -Force
                        $azqrExe = Get-ChildItem $azqrDir -Recurse -Filter 'azqr.exe' | Select-Object -First 1
                        if (-not $azqrExe) { Fail 'azqr packades upp men azqr.exe hittades inte.' "Kontrollera mappen $azqrDir, eller installera azqr manuellt, och kör om." }
                        $env:Path += ";$($azqrExe.DirectoryName)"
                        if (-not (Test-Cmd azqr)) { Fail 'azqr packades upp men kommandot hittas inte.' "Kontrollera att $($azqrExe.FullName) går att starta, eller installera azqr manuellt, och kör om." }
                        Write-Ok "azqr hämtad till $($azqrExe.DirectoryName)"
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
                    Assert-FileHash $zip $Pins.GovVizSha256 'Governance Visualizer'
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
                Install-PsModule 'Az.Accounts' -Pin $Pins.AzAccounts -MinVersion $Pins.AzAccounts
                Install-PsModule 'AzAPICall' -Pin $Pins.AzApiCall -MinVersion '1.2.4'
            }
            catch { Set-Status 'Governance Visualizer' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipGovViz = $true }
        }

        # Maester + Pester (testramverket Maester bygger på).
        if (-not $SkipMaester) {
            try {
                if ($NoInstall -and -not (Get-Module -ListAvailable -Name Maester)) { Fail 'Maester saknas (-NoInstall är satt).' 'Kör om utan -NoInstall.' }
                # Maester kräver Pester 5.5 eller nyare. Pester 6 hålls utanför eftersom Maester är testad mot 5.x.
                Install-PsModule 'Pester' -Pin $Pins.Pester -MinVersion '5.5.0' -MaxVersion '6.0.0'
                Install-PsModule 'Maester' -Pin $Pins.Maester -MinVersion $Pins.Maester
            }
            catch { Set-Status 'Maester' 'Fel' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipMaester = $true }
        }

        # Finns det något kvar att köra? Annars är det ingen idé att fortsätta.
        if ($SkipGovViz -and $SkipAzqr -and $SkipMaester -and $SkipPortal) {
            Fail 'Inget verktyg kunde förberedas, så det finns inget att köra.' 'Se felen ovan, åtgärda dem och kör om scriptet.'
        }

        # ===================================================================
        # STEG 5: Inloggning. Misslyckas en inloggning stängs bara de verktyg som behöver
        # den av; resten körs.
        # ===================================================================
        Write-Step 5 'Inloggning' 'Du loggar in med ett konto som har läsrättigheter (se README). Ett webbläsarfönster öppnas för varje inloggning. Hinner du inte: tryck Ctrl+C och kör om scriptet.'

        # (Azure CLI-inloggningen och rollkontrollen görs redan i steg 3.)

        # 5a. Az PowerShell (används av Governance Visualizer)
        if (-not $SkipGovViz) {
            try {
                Import-Module Az.Accounts -ErrorAction Stop
                $ctx = Get-AzContext -ErrorAction SilentlyContinue
                # En AccessToken-session kan inte förnyas, och Governance Visualizer behöver det: logga in på nytt.
                if ($ctx -and $ctx.Tenant.Id -eq $TenantId -and $ctx.Account.Type -ne 'AccessToken') { Write-Ok 'Az PowerShell är redan inloggad' }
                else {
                    Write-Todo 'Logga in igen (Az PowerShell)...'
                    $azPsByUs = $true
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
                try { Connect-Maester -TenantId $TenantId | Out-Null; $graphByUs = $true; Write-Ok 'Microsoft Graph inloggad' }
                catch {
                    $SkipMaester = $true
                    Set-Status 'Maester' 'Fel' ("Graph-inloggning misslyckades: $($_.Exception.Message) En Global Administrator behöver ge admin consent för 'Microsoft Graph Command Line Tools'. Kör sedan om scriptet." + (Get-SignInHelp $_.Exception.Message))
                    Write-Warn2 $Status['Maester'].Note
                }
            }
        }

        # 4d. Behörighetskontroll: ser kontot den management group som Governance Visualizer startar på?
        # Förutsägs ett fel får du välja att köra ändå eller hoppa över verktyget.
        if (-not $SkipGovViz) {
            $mgCheck = if ($ManagementGroupId) { $ManagementGroupId } else { $TenantId }
            Write-Action "Kontrollerar att kontot kan läsa management group '$mgCheck'"
            $code = $null
            try { $code = (Invoke-AzRestMethod -Method GET -Path "/providers/Microsoft.Management/managementGroups/${mgCheck}?api-version=2021-04-01").StatusCode } catch { }
            if ($code -eq 200) { Write-Ok "Management group '$mgCheck' är läsbar" }
            else {
                Write-Warn2 "Kontot kan inte läsa management group '$mgCheck' (svar: $code). Governance Visualizer kommer sannolikt att misslyckas. Reader behövs på tenant root (se README). Har du höjt åtkomsten (User Access Administrator) men inte tilldelat Reader ännu: gör det, eller ange en annan grupp med -ManagementGroupId."
                if (-not (Confirm-Continue 'Köra Governance Visualizer ändå?')) {
                    $SkipGovViz = $true
                    Set-Status 'Governance Visualizer' 'Hoppad över' "Valdes bort efter behörighetskontrollen: Reader saknas på management group '$mgCheck'."
                }
            }
        }

        if ($SkipGovViz -and $SkipAzqr -and $SkipMaester -and $SkipPortal) {
            Fail 'Inget verktyg återstår att köra: alla är bortvalda eller saknar inloggning/behörighet.' 'Se meddelandena ovan, åtgärda (logga in, få rätt roll) och kör om scriptet. Installationen är redan gjord, så det går snabbt.'
        }

        # ===================================================================
        # STEG 6: Azure Governance Visualizer
        # ===================================================================
        Write-Step 6 'Azure Governance Visualizer' 'Går igenom management groups, subscriptions, policies och roller. 10-45 min i stora miljöer, några minuter i små. Mycket text i fönstret är normalt.'
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
                # Verktyget pausar och väntar på tangenttryckning vid tre rådgivande meddelanden (nyare version finns,
                # PIM-tips, "least privilege"-rekommendation). Inget av dem är fel, och de stoppar körningen, så vi
                # kommenterar bort alla "Pause" i den hämtade kopian.
                if ($src -notmatch 'RAPPORTKIT-NOPAUSE') {
                    $src2 = Get-Content $gvScript -Raw
                    $noPause = [regex]::Replace($src2, '(?m)^(\s*)Pause\s*$', '$1# Pause (borttagen av rapportkit) RAPPORTKIT-NOPAUSE')
                    if ($noPause -eq $src2) { Add-Warning 'Hittade inga pauser att ta bort i Governance Visualizer (verktyget kan vänta på tangenttryckning).' }
                    else { Set-Content $gvScript $noPause -Encoding utf8 }
                }
                # Classic administrators (klassiska prenumerationsadministratörer) är pensionerat i Azure, och API:et svarar
                # 404 "InvalidResourceType" på t.ex. MSDN-prenumerationer. Verktyget är inställt på att STOPPA vid det
                # felet, så vi hoppar över just det anropet: funktionen får samma svar som när listningen misslyckats.
                if ($src -notmatch 'RAPPORTKIT-NOCLASSIC') {
                    $src3 = Get-Content $gvScript -Raw
                    $noClassic = [regex]::Replace($src3, '(?s)(function dataCollectionClassicAdministratorsSub \{.*?)\$AzApiCallResult = AzAPICall @azAPICallPayload', "`$1`$AzApiCallResult = 'ClassicAdministratorListFailed' # RAPPORTKIT-NOCLASSIC (API pensionerat)")
                    if ($noClassic -eq $src3) { Add-Warning 'Kunde inte hoppa över classic administrators i Governance Visualizer (kan stoppa på äldre prenumerationstyper).' }
                    else { Set-Content $gvScript $noClassic -Encoding utf8 }
                }
                $mg = if ($ManagementGroupId) { $ManagementGroupId } else { $TenantId }
                Write-Action "Kör AzGovVizParallel.ps1 mot management group '$mg'"
                $gvArgs = @{ ManagementGroupId = $mg; OutputPath = $Dirs.azgovviz }
                # Versionskontrollen av Azure Landing Zones-policyer klonar ett GitHub-repo med git (som inte alltid finns)
                # och behövs inte för rapporten.
                $gvArgs.NoALZPolicyVersionChecker = $true
                # PIM-behörighetsrapportering kräver ett servicekonto och kan inte köras som vanlig användare.
                # Utan flaggan pausar verktyget och väntar på tangenttryckning, så vi stänger av det direkt.
                $gvArgs.NoPIMEligibility = $true
                # -HidePersonalData: verktyget döljer namn och e-postadresser i rolltilldelningarna i sin rapport.
                if ($HidePersonalData) { $gvArgs.DoNotShowRoleAssignmentsUserData = $true; Write-Action 'Användardata döljs i Governance Visualizers rapport (-HidePersonalData).' }
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
                $msg = $_.Exception.Message
                # Spara verktygets hela utskrift och plocka ut raderna som förklarar felet. Mönstren är
                # skiftlägeskänsliga (-cmatch) så att t.ex. parametern "PSRuleFailedOnly" inte räknas som ett fel.
                $consoleFile = Join-Path $Dirs.azgovviz 'azgovviz-console.txt'
                try { $gvLines | Set-Content $consoleFile -Encoding utf8 } catch { }
                $reason = @($gvLines | ForEach-Object { "$_".Trim() } |
                    Where-Object { $_ -cmatch '(^|[\s\[])(ERROR|Error)\b|check FAILED|AuthorizationFailed|not authorized|Forbidden|Exception' } |
                    Select-Object -Last 3) -join ' | '
                # Rubriken "Permission check results" skrivs även när kontrollen går bra, så felet känns igen på
                # raden "check FAILED" (kontot kan inte läsa management group).
                $permFail = [bool]($gvLines | Where-Object { $_ -clike '*check FAILED*' })
                if ($reason) { $msg = "$reason ($msg)" }
                # Behörighetsfel: ge den vanliga förklaringen. Annars: hänvisa till utskriften.
                $hint = if ($permFail -or $msg -cmatch 'check FAILED|AuthorizationFailed|not authorized|Forbidden') {
                            ' Åtgärd: kontot kan inte läsa management group. Tilldela Reader på tenant root (se "Ge dig själv läsrätt" i README och kontrollera att rollen ligger på Tenant Root Group), eller ange en annan grupp med -ManagementGroupId.' }
                        else { " Hela utskriften finns i $consoleFile." }
                # Kan rapporten ha hunnit skapas före felet? Då är resultatet delvis användbart.
                $partial = Get-ChildItem $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue | Where-Object Length -gt 10KB | Select-Object -First 1
                if ($partial) {
                    Write-Warn2 "Governance Visualizer rapporterade fel men skapade en rapport: $msg"
                    Set-Status 'Governance Visualizer' 'Delvis' ("Rapporten skapades men verktyget avslutades med fel, så den kan sakna delar. $msg$hint")
                }
                else {
                    Write-Warn2 $msg
                    Set-Status 'Governance Visualizer' 'Fel' ($msg + $hint)
                }
            }
        }

        # ===================================================================
        # STEG 7: azqr
        # ===================================================================
        Write-Step 7 'Azure Quick Review (azqr)' 'Skannar alla subscriptions du har läsrätt till. 1-30 min.'
        if ($SkipAzqr) { Write-Action 'Hoppas över'; Set-SkippedUnlessFailed 'azqr' }
        else {
            try {
                Push-Location $Dirs.azqr
                # Rensa gamla resultat för samma period så att vi inte läser blandade körningar.
                Get-ChildItem $Dirs.azqr -Filter "azqr_$Period*" -ErrorAction SilentlyContinue | Remove-Item -Force
                # Kan azqr startas alls? Antivirus/EDR/AppLocker kan blockera nedladdade exe-filer utan tydligt fel.
                & azqr --help *> $null
                if ($LASTEXITCODE -ne 0) { throw "azqr går inte att köra (exit-kod $LASTEXITCODE). Blockeras det av antivirus/EDR/AppLocker? Be IT tillåta azqr.exe och kör om." }
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
        # STEG 8: Maester
        # ===================================================================
        Write-Step 8 'Maester (Entra ID-tester)' 'Valfritt. 10-20 min.'
        if ($SkipMaester) { Write-Action 'Hoppas över'; Set-SkippedUnlessFailed 'Maester' }
        else {
            try {
                Push-Location $Dirs.maester
                Import-Module Maester -ErrorAction Stop
                $testsDir = Join-Path $Dirs.maester 'maester-tests'
                # -Path anges uttryckligen: utan den hamnar testerna i processens arbetsmapp (t.ex. C:\Windows\System32 när man kör som admin).
                if (-not (Test-Path $testsDir)) { Write-Action 'Hämtar Maesters testsvit (Install-MaesterTests)'; Install-MaesterTests -Path $testsDir }
                if (-not (Test-Path $testsDir)) { throw 'Maesters testsvit hämtades inte (mappen maester-tests saknas). Kontrollera internetanslutningen och kör om.' }
                Write-Action 'Kör Invoke-Maester'
                $mtOut = Join-Path $Dirs.maester 'test-results'
                $mtJson = Join-Path $mtOut 'maester.json'
                New-Item -ItemType Directory -Force $mtOut | Out-Null      # mappen ska finnas innan Maester skriver dit
                $res = Invoke-Maester -Path $testsDir -OutputFolder $mtOut -OutputJsonFile $mtJson -NonInteractive -PassThru | Select-Object -Last 1
                if (-not (Test-Path $mtJson)) {
                    # Maester skrev ingen JSON-fil. Finns ett resultatobjekt skriver vi en egen sammanfattning av det.
                    if ($res -and (@($res.PSObject.Properties.Name) -contains 'PassedCount')) {
                        Add-Warning 'Maester skrev ingen maester.json (kan bero på blockerad skrivning, se README). Sammanfattar från resultatobjektet istället.'
                        [pscustomobject]@{
                            PassedCount = $res.PassedCount; FailedCount = $res.FailedCount; SkippedCount = $res.SkippedCount
                            Tests = @($res.Tests | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Result = $_.Result } })
                        } | ConvertTo-Json -Depth 4 | Set-Content $mtJson -Encoding utf8
                    }
                    else {
                        $found = (Get-ChildItem $Dirs.maester -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { $_.FullName.Substring($Dirs.maester.Length + 1) }) -join ', '
                        if (-not $found) { $found = '(inga)' }
                        throw "Maester avslutades men maester.json saknas. Filer i maester-mappen: $found. Blockerar Windows Defender (Kontrollerad mappåtkomst) skrivning? Se felsökning i README."
                    }
                }
                Set-Status 'Maester' 'OK'
                Write-Ok 'Maester klar'
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'Maester' 'Fel' $_.Exception.Message }
            finally { Pop-Location }
        }

        # ===================================================================
        # STEG 9: Defender och kostnad. Hämtar det som annars exporteras manuellt från portalen: Defender-planer,
        # Secure Score, Defender-rekommendationer och kostnad för 12 månader. Allt är read-only och går via
        # Azure Resource Manager (az rest), så inga extra tillägg behövs. Varje källa fångas för sig.
        # ===================================================================
        Write-Step 9 'Defender och kostnad' 'Hämtar Defender-planer, Secure Score, Defender-rekommendationer och kostnad för 12 månader direkt från Azure (read-only) och sparar dem som CSV i portal\. 1-5 min.'
        if ($SkipPortal) { Write-Action 'Hoppas över'; Set-SkippedUnlessFailed 'Defender och kostnad' }
        else {
            $portalErrors = [System.Collections.Generic.List[string]]::new()
            $portalOk = 0
            try {
                $subs = @(az account list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' } | Sort-Object name)
                if ($subs.Count -gt $MaxPortalSubscriptions) {
                    Add-Warning "Kontot ser $($subs.Count) aktiva prenumerationer. Defender och kostnad hämtas bara för de första $MaxPortalSubscriptions (alfabetiskt): ändra med -MaxPortalSubscriptions."
                    $subs = @($subs | Select-Object -First $MaxPortalSubscriptions)
                }
                $subNo = 0
                $planRows = [System.Collections.Generic.List[object]]::new()
                $scoreRows = [System.Collections.Generic.List[object]]::new()
                $recRows = [System.Collections.Generic.List[object]]::new()
                $costRows = [System.Collections.Generic.List[object]]::new()
                $ctrlRows = [System.Collections.Generic.List[object]]::new()
                foreach ($s in $subs) {
                    $sid = $s.id; $sname = $s.name; $subNo++
                    Write-Action "Prenumeration $subNo/$($subs.Count): $sname"

                    # Defender-planer (på/av per tjänst)
                    try {
                        $r = Invoke-ArmRest 'GET' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/pricings?api-version=2024-01-01"
                        foreach ($p in @($r.value)) { $planRows.Add([pscustomobject]@{ Prenumeration = $sname; Plan = $p.name; Niva = $p.properties.pricingTier; Delplan = $p.properties.subPlan }) }
                        $portalOk++
                    }
                    catch { $portalErrors.Add("Defender-planer ($sname): $($_.Exception.Message)") }

                    # Secure Score
                    try {
                        $r = Invoke-ArmRest 'GET' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/secureScores?api-version=2020-01-01"
                        foreach ($sc in @($r.value)) { $scoreRows.Add([pscustomobject]@{ Prenumeration = $sname; Poang = $sc.properties.score.current; Max = $sc.properties.score.max; Andel = $sc.properties.score.percentage }) }
                        $portalOk++
                    }
                    catch { $portalErrors.Add("Secure Score ($sname): $($_.Exception.Message)") }

                    # Secure Score per kontroll (poäng, antal osunda/friska resurser). Behövs eftersom Azures lista över
                    # enskilda rekommendationer kan vara ofullständig: kontrollerna visar hur många resurser som är osunda.
                    try {
                        $r = Invoke-ArmRest 'GET' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/secureScoreControls?api-version=2020-01-01"
                        foreach ($c in @($r.value)) { $ctrlRows.Add([pscustomobject]@{ Prenumeration = $sname; Kontroll = $c.properties.displayName; Poang = $c.properties.score.current; Max = $c.properties.score.max; Osunda = [int]$c.properties.unhealthyResourceCount; Friska = [int]$c.properties.healthyResourceCount }) }
                        $portalOk++
                    }
                    catch { $portalErrors.Add("Secure Score-kontroller ($sname): $($_.Exception.Message)") }

                    # Defender-rekommendationer (sidindelat; högst 30 sidor, och vi stannar om nextLink upprepas)
                    try {
                        $url = "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/assessments?api-version=2021-06-01&`$expand=metadata"
                        $pages = 0; $seen = @{}; $seenIds = @{}
                        while ($url -and $pages -lt 30 -and -not $seen.ContainsKey($url)) {
                            $seen[$url] = $true; $pages++
                            $r = Invoke-ArmRest 'GET' $url
                            foreach ($a in @($r.value)) {
                                # Defender kan returnera samma sida igen via en nextLink som pekar på sig själv: hoppa över dubletter.
                                if ($a.id -and $seenIds.ContainsKey($a.id)) { continue }
                                if ($a.id) { $seenIds[$a.id] = $true }
                                $recRows.Add([pscustomobject]@{ Prenumeration = $sname; Rekommendation = $a.properties.displayName; Status = $a.properties.status.code; Allvarlighet = $a.properties.metadata.severity; Resurs = $a.properties.resourceDetails.Id })
                            }
                            $url = $r.nextLink
                        }
                        $portalOk++
                    }
                    catch { $portalErrors.Add("Defender-rekommendationer ($sname): $($_.Exception.Message)") }

                    # Kostnad per månad, senaste 12 månaderna (Cost Management tillåter högst ett år)
                    try {
                        $from = (Get-Date).AddDays(-364).ToString('yyyy-MM-dd'); $to = (Get-Date).ToString('yyyy-MM-dd')
                        $costBody = @{ type = 'ActualCost'; timeframe = 'Custom'; timePeriod = @{ from = "${from}T00:00:00+00:00"; to = "${to}T23:59:59+00:00" }
                                       dataset = @{ granularity = 'Monthly'; aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } } }
                        $r = Invoke-ArmRest 'POST' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.CostManagement/query?api-version=2023-03-01" $costBody
                        $cols = @($r.properties.columns | ForEach-Object { $_.name })
                        $iCost = [array]::IndexOf($cols, 'Cost'); $iCur = [array]::IndexOf($cols, 'Currency')
                        $iMonth = [array]::IndexOf($cols, 'BillingMonth'); if ($iMonth -lt 0) { $iMonth = [array]::IndexOf($cols, 'UsageDate') }
                        if ($iCost -lt 0 -or $iMonth -lt 0) { throw "oväntade kolumner i kostnadssvaret: $($cols -join ', ')" }
                        foreach ($row in @($r.properties.rows)) {
                            # ConvertFrom-Json gör om ISO-datum till DateTime, så formatera dem oberoende av språkinställning.
                            $mv = $row[$iMonth]
                            $ms = if ($mv -is [datetime]) { $mv.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$mv }
                            $month = if ($ms -match '^\d{8}$') { $ms.Substring(0, 4) + '-' + $ms.Substring(4, 2) } else { $ms.Substring(0, [Math]::Min(7, $ms.Length)) }
                            $costRows.Add([pscustomobject]@{ Prenumeration = $sname; Manad = $month; Kostnad = [math]::Round([double]$row[$iCost], 2); Valuta = $(if ($iCur -ge 0) { $row[$iCur] } else { '' }) })
                        }
                        $portalOk++
                    }
                    catch { $portalErrors.Add("Kostnad ($sname): $($_.Exception.Message)") }
                }

                # Spara som CSV (UTF-8 med BOM så att Excel visar å/ä/ö rätt)
                $save = @(@('defender-planer.csv', $planRows), @('secure-score.csv', $scoreRows), @('secure-score-kontroller.csv', $ctrlRows), @('defender-rekommendationer.csv', $recRows), @('kostnad.csv', $costRows))
                foreach ($sv in $save) {
                    if ($sv[1].Count) { $sv[1] | Export-Csv -Path (Join-Path $Dirs.portal $sv[0]) -NoTypeInformation -Encoding utf8BOM; Write-Ok "$($sv[0]): $($sv[1].Count) rader" }
                }
                # Stämmer rekommendationslistan med kontrollerna? Annars har Azures lista (en egenhet i API:et) tappat osunda resurser.
                $ctrlUnhealthy = [int](($ctrlRows | Measure-Object -Property Osunda -Sum).Sum)
                $recUnhealthy = @($recRows | Where-Object { $_.Status -eq 'Unhealthy' }).Count
                if ($ctrlUnhealthy -gt $recUnhealthy) { Add-Warning "Secure Score-kontrollerna visar $ctrlUnhealthy osunda resurser, men rekommendationslistan innehåller bara $recUnhealthy. Azures lista är troligen ofullständig; använd tabellen Secure Score per kontroll." }
                if ($portalErrors.Count -eq 0) { Set-Status 'Defender och kostnad' 'OK' "Sparat i $($Dirs.portal)" }
                else {
                    foreach ($e in $portalErrors) { Write-Warn2 $e }
                    $hint = if ($portalErrors -match 'AuthorizationFailed|Forbidden|does not have authorization|403') { ' Vanlig orsak: roll saknas (Reader, Security Reader eller Cost Management Reader), se README.' } else { '' }
                    Set-Status 'Defender och kostnad' $(if ($portalOk -gt 0) { 'Delvis' } else { 'Fel' }) (($portalErrors -join ' | ') + $hint)
                }
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'Defender och kostnad' 'Fel' $_.Exception.Message }
        }
    }

    # =======================================================================
    # STEG 10: HTML-rapport. Varje avsnitt byggs för sig; går ett avsnitt inte att bygga
    # blir det en varning i rapporten, inte ett avbrott.
    # =======================================================================
    Write-Step 10 'Bygger HTML-rapport' 'Kontrollerar och läser resultatfilerna och skriver rapport.html.'
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
        $gvAll = @(Get-ChildItem $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue)
        # Huvudrapporten heter AzGovViz_<version>_<datum>_<tid>_<tenant-ID>.html. Övriga (DefinitionInsights, en per
        # prenumeration) är sidorapporter, och de kan vara mycket stora, så välj inte bara första bästa fil.
        $gvHtml = $gvAll | Where-Object { $_.Name -match '_\d{8}_\d{6}_[0-9a-fA-F-]{36}\.html$' } | Select-Object -First 1
        if (-not $gvHtml) { $gvHtml = $gvAll | Sort-Object Name | Select-Object -First 1 }
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
        $gvOthers = @($gvAll | Where-Object { $_.FullName -ne $gvHtml.FullName })
        if ($gvOthers.Count) { [void]$body.Append("<p class=`"muted`">Fler rapporter från verktyget ($($gvOthers.Count) st, t.ex. DefinitionInsights) finns i mappen azgovviz\.</p>") }
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

        # Tester som hoppades över: ange orsaken (oftast licens), så att läsaren vet vad som INTE kontrollerats.
        $skipped = @($m.Tests | Where-Object Result -eq 'Skipped')
        if ($skipped.Count) {
            $labels = @{
                NotLicensedEntraIDP1 = 'Licens saknas: Entra ID P1'; NotLicensedEntraIDP2 = 'Licens saknas: Entra ID P2'
                NotLicensedEntraIDGovernance = 'Licens saknas: Entra ID Governance'; NotLicensedEntraIDP2OrGovernance = 'Licens saknas: Entra ID P2 eller Governance'
                NotLicensedEntraWorkloadID = 'Licens saknas: Entra Workload ID'; NotLicensedIntune = 'Licens saknas: Intune'
                NotLicensedEop = 'Licens saknas: Exchange Online Protection'; NotLicensedMdo = 'Licens saknas: Defender for Office 365'
                NotLicensedMdoP1 = 'Licens saknas: Defender for Office 365 P1'; NotLicensedMdoP2 = 'Licens saknas: Defender for Office 365 P2'
                NotLicensedExoDlp = 'Licens saknas: Exchange DLP'; NotLicensedAdvAudit = 'Licens saknas: Advanced Auditing'
                NotLicensedDefenderXDR = 'Licens saknas: Defender XDR'; NotLicensedCustomerLockbox = 'Licens saknas: Customer Lockbox'
                Error = 'Testet kunde inte köras (fel)'
            }
            $skipRows = $skipped | Group-Object {
                $d = $_.ResultDetail
                $k = if ($d -and $d.TestSkipped) { [string]$d.TestSkipped } else { 'Okänd orsak' }
                # Fri text från testet ("Custom") används som orsak; markdown-länkar [text](url) kortas till text.
                if ($k -eq 'Custom' -and $d.SkippedReason) { ([string]$d.SkippedReason) -replace '\[([^\]]+)\]\([^)]+\)', '$1' } else { $k }
            } | Sort-Object Count -Descending | ForEach-Object {
                [pscustomobject]@{
                    Orsak  = $(if ($labels.ContainsKey($_.Name)) { $labels[$_.Name] } else { $_.Name })
                    Antal  = $_.Count
                    Exempel = ($_.Group | Select-Object -First 2 -ExpandProperty Name) -join '; '
                }
            }
            $licSkipped = @($skipped | Where-Object { $_.ResultDetail.TestSkipped -like 'NotLicensed*' }).Count
            [void]$body.Append("<h3>Tester som inte kunde köras ($($skipped.Count))</h3><p class=`"muted`">Dessa kontroller ingår <strong>inte</strong> i resultatet. $licSkipped av dem beror på att tenanten saknar en licens (t.ex. Entra ID P1/P2) och resten på att funktionen inte är aktiverad eller inte gick att läsa. Det säger alltså inget om huruvida inställningen är bra eller dålig.</p>" +
                (ConvertTo-HtmlTable $skipRows @(@{Name='Orsak';Label='Orsak'}, @{Name='Antal';Label='Antal'}, @{Name='Exempel';Label='Exempel på test'}) 20))
        }
        $mh = Get-ChildItem $Dirs.maester -Filter '*.html' -Recurse | Select-Object -First 1
        if ($mh) { [void]$body.Append("<p>Fullständig rapport: <a href=`"$(RelLink $mh.FullName)`">$(Esc $mh.Name)</a></p>") }
    }

    # --- Defender och kostnad: läs CSV-filerna som steg 9 sparade i portal\ ----------
    Invoke-Section 'Defender och kostnad' {
        $planF = Join-Path $Dirs.portal 'defender-planer.csv'
        $scoreF = Join-Path $Dirs.portal 'secure-score.csv'
        $recF = Join-Path $Dirs.portal 'defender-rekommendationer.csv'
        $costF = Join-Path $Dirs.portal 'kostnad.csv'
        [void]$body.Append('<h2>Defender och kostnad</h2>')
        if (-not ((Test-Path $planF) -or (Test-Path $scoreF) -or (Test-Path $recF) -or (Test-Path $costF))) {
            [void]$body.Append('<p class="muted">Ingen Defender- eller kostnadsdata hämtades (se körningsstatus ovan). Rollerna Security Reader och Cost Management Reader behövs.</p>')
        }
        else {
            Write-Action 'Läser Defender- och kostnadsdata'
            [void]$body.Append('<div class="tiles">')
            # Secure Score
            if (Test-Path $scoreF) {
                $sc = Import-CsvChecked $scoreF @('Prenumeration', 'Poang', 'Max', 'Andel')
                foreach ($r in @($sc)) {
                    $pct = [math]::Round(([double]($r.Andel -replace ',', '.')) * 100)
                    [void]$body.Append((Tile "Secure Score ($($r.Prenumeration))" ("{0} % ({1}/{2})" -f $pct, $r.Poang, $r.Max)))
                }
            }
            # Defender-planer: hur många är på?
            $plans = if (Test-Path $planF) { Import-CsvChecked $planF @('Prenumeration', 'Plan', 'Niva') } else { $null }
            if ($null -ne $plans) {
                $on = @($plans | Where-Object Niva -eq 'Standard').Count
                [void]$body.Append((Tile 'Defender-planer påslagna' "$on av $(@($plans).Count)" $(if ($on -eq 0) { 'medium' } else { 'ok' })))
            }
            # Defender-rekommendationer som inte uppfylls
            $recs = if (Test-Path $recF) { Import-CsvChecked $recF @('Rekommendation', 'Status', 'Allvarlighet', 'Resurs') } else { $null }
            if ($null -ne $recs) {
                $unh = @($recs | Where-Object Status -eq 'Unhealthy')
                [void]$body.Append((Tile 'Rekommendationer: hög' @($unh | Where-Object Allvarlighet -eq 'High').Count 'high') + (Tile 'Medel' @($unh | Where-Object Allvarlighet -eq 'Medium').Count 'medium') + (Tile 'Låg' @($unh | Where-Object Allvarlighet -eq 'Low').Count 'low'))
            }
            # Kostnad
            $costs = if (Test-Path $costF) { Import-CsvChecked $costF @('Prenumeration', 'Manad', 'Kostnad', 'Valuta') } else { $null }
            if ($null -ne $costs -and @($costs).Count) {
                foreach ($g in ($costs | Group-Object Valuta)) {
                    $tot = ($g.Group | ForEach-Object { [double]($_.Kostnad -replace ',', '.') } | Measure-Object -Sum).Sum
                    [void]$body.Append((Tile "Kostnad senaste 12 mån ($($g.Name))" ("{0:N0}" -f $tot)))
                }
            }
            [void]$body.Append('</div>')

            if ($null -ne $plans -and @($plans).Count) {
                $planView = $plans | ForEach-Object { [pscustomobject]@{ Prenumeration = $_.Prenumeration; Plan = $_.Plan; Status = $(if ($_.Niva -eq 'Standard') { 'På' } else { 'Av' }) } }
                [void]$body.Append('<h3>Defender-planer</h3>' + (ConvertTo-HtmlTable $planView @(@{Name='Prenumeration';Label='Prenumeration'}, @{Name='Plan';Label='Plan'}, @{Name='Status';Label='Status'}) 40))
            }
            # Secure Score per kontroll: poäng och antal osunda/friska resurser.
            $ctrlF = Join-Path $Dirs.portal 'secure-score-kontroller.csv'
            if (Test-Path $ctrlF) {
                $ctrls = Import-CsvChecked $ctrlF @('Prenumeration', 'Kontroll', 'Poang', 'Max', 'Osunda', 'Friska')
                if ($null -ne $ctrls -and @($ctrls).Count) {
                    $ctrlView = @($ctrls | Where-Object { [int]$_.Max -gt 0 -or [int]$_.Osunda -gt 0 } | Sort-Object { -[int]$_.Osunda }, Kontroll | ForEach-Object {
                            [pscustomobject]@{ Kontroll = $_.Kontroll; Poang = ('{0} av {1}' -f $_.Poang, $_.Max); Osunda = $_.Osunda; Friska = $_.Friska } })
                    [void]$body.Append('<h3>Secure Score per kontroll</h3><p class="muted">Poäng och antal osunda respektive friska resurser per kontroll. Tabellen är mer tillförlitlig än listan över enskilda rekommendationer nedan, som Azures API ibland returnerar ofullständig.</p>' + (ConvertTo-HtmlTable $ctrlView @(@{Name='Kontroll';Label='Kontroll'}, @{Name='Poang';Label='Poäng'}, @{Name='Osunda';Label='Osunda resurser'}, @{Name='Friska';Label='Friska resurser'}) 30))
                }
            }
            if ($null -ne $recs -and @($recs | Where-Object Status -eq 'Unhealthy').Count) {
                $sevOrder = @{ High = 0; Medium = 1; Low = 2 }
                $recView = @($recs | Where-Object Status -eq 'Unhealthy' | Sort-Object { if ($sevOrder.ContainsKey($_.Allvarlighet)) { $sevOrder[$_.Allvarlighet] } else { 3 } } |
                    ForEach-Object { [pscustomobject]@{ Impact = $_.Allvarlighet; Rekommendation = $_.Rekommendation; Resurs = ($_.Resurs -split '/')[-1] } })
                [void]$body.Append('<h3>Defender-rekommendationer som inte uppfylls</h3>' + (ConvertTo-HtmlTable $recView @(@{Name='Impact';Label='Allvarlighet'}, @{Name='Rekommendation';Label='Rekommendation'}, @{Name='Resurs';Label='Resurs'}) 20))
            }
            if ($null -ne $costs -and @($costs).Count) {
                [void]$body.Append('<h3>Kostnad per månad</h3>' + (ConvertTo-HtmlTable ($costs | Sort-Object Manad) @(@{Name='Prenumeration';Label='Prenumeration'}, @{Name='Manad';Label='Månad'}, @{Name='Kostnad';Label='Kostnad'}, @{Name='Valuta';Label='Valuta'}) 36))
            }
            [void]$body.Append('<p class="muted">Hämtat automatiskt via Azure. Fullständiga CSV-filer finns i mappen portal\. Azure Advisor-rekommendationer finns under azqr ovan.</p>')
        }
        $shots = @(Get-ChildItem $Dirs.portal -File -Filter '*.png' -ErrorAction SilentlyContinue).Count
        [void]$body.Append("<p class=`"muted`">Skärmdumpar från portalen (valfritt): $(if ($shots) { "&#10003; $shots fil(er) i portal\" } else { 'inga' }).</p>")
    }

    # --- Begränsningar och fakta om körningen -------------------------------------
    Invoke-Section 'Begränsningar' {
        [void]$body.Append('<h2>Begränsningar och avgränsningar</h2>')
        $lim = [System.Collections.Generic.List[string]]::new()
        $lim.Add('Rapporten sammanfattar verktygens resultat och ersätter inte en granskning. Den visar läget vid körningstillfället.')
        foreach ($k in $Status.Keys) {
            $s = $Status[$k]
            if ($s.State -eq 'Hoppad över') { $lim.Add("$k kördes inte (hoppades över).") }
            elseif ($s.State -eq 'Fel') { $lim.Add("$k misslyckades och saknas därför i rapporten: $($s.Note)") }
            elseif ($s.State -eq 'Delvis') { $lim.Add("$k lyckades bara delvis: $($s.Note)") }
        }
        $lim.Add('Governance Visualizer körs som vanlig användare, så roller som bara är tillgängliga via PIM men inte aktiverade ingår inte (kräver servicekonto). Klassiska prenumerationsadministratörer (ett pensionerat API) och kontrollen av Azure Landing Zones-policyversioner ingår inte.')
        $lim.Add('Defender-rekommendationer hämtas från Azures API, som kan returnera en ofullständig lista. Använd Secure Score per kontroll som referens.')
        $lim.Add('Kostnad avser de senaste 12 månaderna per prenumeration. Prognos och kostnad per tagg ingår inte.')
        if ($HidePersonalData) { $lim.Add('Användardata är dolda i Governance Visualizers rapport (-HidePersonalData). Övriga rapporter, bland annat Maesters, kan innehålla namn.') }
        else { $lim.Add('Rapporterna kan innehålla namn och e-postadresser (rolltilldelningar, Maester). Hantera dem som konfidentiella.') }
        [void]$body.Append('<ul>' + (($lim | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul>')

        $meta = @(
            [pscustomobject]@{ Falt = 'Rapportkit'; Varde = "v$KitVersion" },
            [pscustomobject]@{ Falt = 'Körd'; Varde = $script:RunStart.ToString('yyyy-MM-dd HH:mm') },
            [pscustomobject]@{ Falt = 'Tenant'; Varde = $TenantId },
            [pscustomobject]@{ Falt = 'Verktygsversioner'; Varde = $(if ($LatestTools) { 'senaste (-LatestTools), inte testade med detta kit' } else { "testade: Governance Visualizer $GvVersion, azqr $($Pins.Azqr), Maester $($Pins.Maester), Pester $($Pins.Pester), Az.Accounts $($Pins.AzAccounts)" }) },
            [pscustomobject]@{ Falt = 'Installerat'; Varde = ("Maester {0}, Az.Accounts {1}" -f (Get-ModuleVersionText 'Maester'), (Get-ModuleVersionText 'Az.Accounts')) },
            [pscustomobject]@{ Falt = 'Dator'; Varde = ("PowerShell {0}, {1}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString) }
        )
        [void]$body.Append('<h3>Om körningen</h3>' + (ConvertTo-HtmlTable $meta @(@{Name='Falt';Label='Fält'}, @{Name='Varde';Label='Värde'}) 20))
        [void]$body.Append('<p class="muted">Scriptet skriver inget i Azure-resurser eller Entra-konfigurationen. Det installerar verktyg lokalt, skapar inloggningssessioner (som syns i tenantens loggar), och för Maester krävs att en administratör godkänner läsbehörigheter för Microsoft Graph Command Line Tools.</p>')
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
.pill.high,.pill.failed,.pill.fel{background:var(--hi)}.pill.medium,.pill.delvis{background:var(--me)}.pill.low{background:var(--lo)}.pill.passed,.pill.ok{background:var(--ok)}
@media(max-width:600px){table{display:block;overflow-x:auto}}
'@
    $html = @"
<!doctype html><html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rapportkit $Period</title><style>$css</style></head><body>
<h1>Rapportkit $Period</h1>
<p class="muted">Tenant $TenantId &middot; skapad $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; Rapportkit v$KitVersion &middot; konfidentiell information</p>
$($top.ToString())
$($body.ToString())
</body></html>
"@
    $reportPath = Join-Path $RunDir 'rapport.html'
    Set-Content -Path $reportPath -Value $html -Encoding utf8
    Write-Ok "Rapport: $reportPath"

    # =======================================================================
    # Avslut: körningssammanfattning, zip för leverans, sammanfattningsruta, utloggning och städning.
    # =======================================================================
    Complete-Step
    $anyFail = @($Status.Values | Where-Object { $_.State -eq 'Fel' }).Count -gt 0
    if ($anyFail) { $ExitCode = 2 }
    Write-RunSummary $ExitCode

    # Zip av resultatmappen för leverans, med SHA256 så att mottagaren kan kontrollera att filen kommit fram oförändrad.
    # Konsolloggen (rapportkit-console.log) tas inte med: den är en felsökningslogg och är låst medan scriptet körs.
    $zipPath = $null; $zipHash = $null
    if (-not $NoZip) {
        try {
            $zipPath = Join-Path $OutputRoot ('rapportkit_{0}_{1}.zip' -f $TenantId.Substring(0, 8), $Period)
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            Get-ChildItem -Path $RunDir -Force | Where-Object { $_.Name -ne 'rapportkit-console.log' } | Compress-Archive -DestinationPath $zipPath -Force
            $zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
            Set-Content -Path "$zipPath.sha256" -Value ('{0} *{1}' -f $zipHash, (Split-Path $zipPath -Leaf)) -Encoding ascii
            Write-Ok ('Zip skapad ({0:N1} MB), kontrollsumma sparad i {1}.sha256' -f ((Get-Item $zipPath).Length / 1MB), (Split-Path $zipPath -Leaf))
        }
        catch { Add-Warning "Kunde inte skapa zip-filen: $($_.Exception.Message)"; $zipPath = $null }
    }

    $facts = [System.Collections.Generic.List[object]]::new()
    $facts.Add(@('Rapport', $reportPath))
    $facts.Add(@('Resultatmapp', $RunDir))
    if ($zipPath) { $facts.Add(@('Zip', $zipPath)); $facts.Add(@('SHA256', $zipHash)) }
    $facts.Add(@('Loggar', 'rapportkit.log (rensad), rapportkit-console.log (allt) och run-summary.json i resultatmappen'))
    $facts.Add(@('Total tid', (Format-Duration ((Get-Date) - $script:RunStart).TotalSeconds)))
    if ($anyFail) { $facts.Add(@('Kör om', (Get-RerunCommand))) }
    Write-SummaryBox $Status $facts
    if ($anyFail) { Write-Warn2 'Något verktyg misslyckades (se ovan). Rapporten visar det som gick bra. Åtgärda och kör om med kommandot ovan.' }
    Write-Host ''
    Write-Action 'Nästa steg: öppna rapporten och kontrollera innehållet. Resultatet är konfidentiellt: lämna det bara på överenskommen plats.'

    Invoke-SessionCleanup
    foreach ($tmpf in @((Join-Path $env:TEMP 'azqr.zip'), (Join-Path $env:TEMP "azgovviz-$GvVersion.zip"))) { Remove-Item $tmpf -Force -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $env:TEMP 'azrest-*.json') -Force -ErrorAction SilentlyContinue

    $Completed = $true
    Write-Log 'KLAR' "Körningen klar. Slutkod $ExitCode"
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
    Complete-Step
    Write-Host ''
    Write-Line 'AVBRUTEN' 'Red' 'Körningen avbröts' 'Red'
    if ($ex.Data -and $ex.Data['Fix']) {
        Write-Log 'FEL' ('Avbruten: ' + $ex.Message)
        Write-Line 'ORSAK' 'Red' $ex.Message 'Red'
        Write-Line 'ÅTGÄRD' 'Yellow' ([string]$ex.Data['Fix']) 'Yellow'
        Write-Log 'ÅTGÄRD' ([string]$ex.Data['Fix'])
    }
    else {
        Write-Log 'FEL' ('Oväntat fel: {0} (rad {1}: {2})' -f $ex.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
        Write-Line 'FEL' 'Red' "Oväntat fel: $($ex.Message)" 'Red'
        Write-Host ('             Plats: rad {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
        Write-Line 'ÅTGÄRD' 'Yellow' 'Skicka rapportkit.log (och rapportkit-console.log) från resultatmappen till den som gav dig scriptet.' 'Yellow'
    }
    Write-Line 'KÖR OM' 'Cyan' 'När det är åtgärdat, kör om scriptet (det som redan är installerat återanvänds):' 'Gray'
    Write-Host "             $(Get-RerunCommand)" -ForegroundColor White
    Write-RunSummary 1
}
finally {
    # Körs alltid, även vid Ctrl+C eller stängt fönster: förklara avbrottet, städa och stäng loggen.
    if (-not $Completed -and -not $AbortShown) {
        Complete-Step
        Write-Host ''
        Write-Line 'AVBRUTEN' 'Yellow' 'Körningen avbröts (Ctrl+C eller stängt fönster). Inget har ändrats i Azure.' 'Yellow'
        Write-Log 'FEL' 'Avbruten av användaren (Ctrl+C eller stängt fönster)'
        if ($TenantId) {
            Write-Line 'KÖR OM' 'Cyan' 'Kör om scriptet; det som redan är installerat återanvänds:' 'Gray'
            Write-Host "             $(Get-RerunCommand)" -ForegroundColor White
        }
        Write-RunSummary 1
    }
    if (-not $Completed -and ($azPsByUs -or $graphByUs -or ($azReady -and -not $azWasLoggedIn))) {
        Write-Host '  Obs: inloggningar som scriptet skapade kan finnas kvar. Logga ut med: az logout   (samt Disconnect-AzAccount och Disconnect-MgGraph)' -ForegroundColor DarkYellow
    }
    foreach ($tmpf in @((Join-Path $env:TEMP 'azqr.zip'), (Join-Path $env:TEMP "azgovviz-$GvVersion.zip"))) { Remove-Item $tmpf -Force -ErrorAction SilentlyContinue }
    if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
exit $ExitCode
