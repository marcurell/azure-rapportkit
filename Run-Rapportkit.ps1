<#
.SYNOPSIS
  Rapportkit: fetches the tools, signs in, runs three read-only report tools against an Azure tenant
  and summarises the result in an HTML report.

.DESCRIPTION
  The script does the following, in order (each step prints what is happening while it runs):

    Step 1  Preparation      Tenant ID, result folders, log file
    Step 2  Pre-flight       Checks the prerequisites (tools, network, disk) before anything is fetched, and
                             lets you choose whether to continue even if something is missing
    Step 3  Azure CLI, sign-in and role check
                             Installs Azure CLI, signs in and checks that the account has the right roles
                             (Reader, Security Reader, Cost Management Reader, Global Reader). If roles are missing
                             it shows how to add them, and you choose whether to stop or continue.
    Step 4  Dependencies     Downloads and installs what is missing on this computer:
                               - PowerShell 7           (winget, already in the bootstrap)
                               - azqr                   (winget, otherwise a direct download from GitHub)
                               - Azure Governance Visualizer (zip from GitHub, fixed version)
                               - PowerShell modules Az.Accounts, AzAPICall, Pester 5.5+, Maester (PSGallery)
                             Every download is verified (size, zip integrity, expected files).
    Step 5  Sign-in          Az PowerShell and (optionally) Microsoft Graph, and a check of the management group
    Step 6  Governance Visualizer   Management groups, policies, role assignments
    Step 7  azqr                    Recommendations per resource + Advisor + Defender
    Step 8  Maester                 Tests of Entra ID (optional)
    Step 9  Defender, cost   Defender plans, Secure Score, recommendations and cost (12 months), plus
            and structure    management groups and networks (VNets, peerings): saved as CSV in portal\ and struktur\
    Step 10 HTML report      Summary in <result folder>\rapport.html. The result files are checked
                             before they are read; deviations are shown as warnings in the report.

  The script writes nothing to Azure resources or the Entra configuration and only makes read calls. It does,
  however, do the following, which is good to know:
    - installs tools on this computer (programs via winget, modules in <OutputRoot>\_modules),
    - creates sign-in sessions, which show in the tenant's sign-in and audit logs,
    - for Maester an administrator must approve read permissions for "Microsoft Graph Command Line Tools"
      (admin consent), which is a change in the tenant,
    - saves results with confidential information in the result folder (a zip is created unless you pass -NoZip).

  ERROR HANDLING
    - A tool that fails does not stop the others. The error and what to do about it show in
      the status table in the console and in the report.
    - If the script cannot continue at all it writes what went wrong, how to proceed and
      the exact command to run again. What is already installed is reused.
    - If you stop with Ctrl+C or close the window: just run the script again.
    - Exit code: 0 = everything went well (or was skipped on purpose), 2 = a tool failed
      but a report exists, 1 = the run was aborted.

.PARAMETER TenantId
  Tenant ID (GUID). Asked for if it is not given.
.PARAMETER ManagementGroupId
  Management group that Governance Visualizer starts at. Default is the tenant root (= tenant ID).
.PARAMETER OutputRoot
  Root folder for results and downloaded tools. If it is not given the script asks where it should be (suggestion: %USERPROFILE%\rapportkit).
.PARAMETER Period
  Name of the subfolder for this run. Default is the current month (yyyy-MM).
.PARAMETER SkipGovViz / SkipAzqr / SkipMaester
  Skip the respective tool.
.PARAMETER DeviceLogin
  Sign in with a code (https://login.microsoft.com/device) instead of a browser window.
.PARAMETER NoInstall
  Install/fetch nothing; use only what already exists.
.PARAMETER Offline
  Do not download anything from the internet; use only the folder tools\ (see Build-Bundle.ps1).
.PARAMETER ReportOnly
  Run no tools, only rebuild the HTML report from existing results.
.PARAMETER SkipPortal
  Skip fetching Defender and cost data (step 9).
.PARAMETER MaxPortalSubscriptions
  At most this many (active) subscriptions are queried for Defender and cost data (default 25). Cost Management
  limits calls hard, so hundreds of subscriptions take hours.
.PARAMETER HidePersonalData
  Hide user data (names and e-mail addresses in role assignments) in Governance Visualizer's report. Does not apply to
  Maester's report, which can contain user names.
.PARAMETER KeepLogin
  Do not sign out of the sessions the script created itself (Azure CLI, Azure PowerShell, Microsoft Graph).
.PARAMETER NoZip
  Do not create a zip file of the result.
.PARAMETER Anonymize
  Also build an anonymized version of the report in the folder anonym\ (names, e-mail addresses and IDs are replaced by aliases), for
  demos or sharing. If it is not given the script asks at the start (unless -Yes is set).
.PARAMETER ReportLanguage
  Language of the report text: the code of a language pack in the folder lang\ (en, sv). If it is not given, "language" in
  branding\theme.json is used, and if that is missing English (en). Applies to the report only; the script's own messages are in English.
.PARAMETER NoEncrypt
  Do not encrypt the zip file (by default it is encrypted with a password that you enter at the start of the run).
  Use only if the result does not leave the computer.
.PARAMETER ZipPassword
  Password (SecureString) for the zip file, for automated runs. If it is left out the script asks at the start.
.PARAMETER Plain
  Draw frames and bars with plain ASCII characters (for consoles that show special characters wrongly).
.PARAMETER LatestTools
  Use the latest versions of the tools instead of the tested (pinned) ones and skip checksums.
.PARAMETER AllowUnverified
  Continue even if a downloaded file does not match the tested checksum. Use only after your own check.
.PARAMETER Yes
  Answer yes to all "continue anyway?" questions (pre-flight and permission check), for example for automated runs.

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
    [switch]$Anonymize,
    [ValidatePattern('^[a-z]{2,3}(-[A-Za-z]{2,4})?$')]
    [string]$ReportLanguage,
    [switch]$NoEncrypt,
    [System.Security.SecureString]$ZipPassword,
    [switch]$Plain,
    [switch]$LatestTools,
    [switch]$AllowUnverified,
    [switch]$Yes
)

# Stop on errors by default. Every tool step catches its own errors (try/catch) so that a
# failed tool does not stop the others.
$ErrorActionPreference = 'Stop'
# Downloads are much faster without the progress indicator.
$ProgressPreference = 'SilentlyContinue'
# A corporate proxy often requires the Windows sign-in to be sent along (otherwise HTTP 407). Applies to both Windows PowerShell 5.1
# and PowerShell 7.
try { [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials } catch { }
try { [System.Net.Http.HttpClient]::DefaultProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials } catch { }

# Saved right away: $PSBoundParameters cannot be reached from functions. Used to build
# the "run again" command and to restart the script in PowerShell 7.
$BoundParams = @{}
foreach ($k in $PSBoundParameters.Keys) { $BoundParams[$k] = $PSBoundParameters[$k] }
# The password must never be passed on the command line or written in the "run again" command.
[void]$BoundParams.Remove('ZipPassword')

$ScriptRoot = Split-Path -Parent $PSCommandPath
$ToolsDir = Join-Path $ScriptRoot 'tools'        # only used for the offline bundle
$TotalSteps = 10
# Governance Visualizer is fetched as a fixed version (the one that was tested). Changed on purpose, not by accident.
$GvVersion = '6.7.2'
$GvUrl = "https://github.com/Azure/Azure-Governance-Visualizer/archive/refs/tags/$GvVersion.zip"
$KitVersion = '1.4.3'

# Tested (pinned) tool versions, and checksums (SHA256) for the zip files that are fetched directly. The customer then gets
# the same tools that we tested, and a changed file is detected. Tools installed via winget are checked by winget
# itself against its manifest. -LatestTools switches to the latest versions and turns the checksums off.
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

# State needed at the end (sign-out). Set further down when the script signs in itself.
$azReady = $false
$azWasLoggedIn = $false
$azPsByUs = $false
$graphByUs = $false

$ExitCode = 0            # exit code, see ERROR HANDLING above
$Completed = $false      # set when the whole run has gone through
$AbortShown = $false     # true when we have already written our own abort message

# ===========================================================================
# Output (UI) and logging. Every action writes a line in the window and a line in the log.
# ===========================================================================

# --- Characters for frames and bars. They are built from character codes so that it works however the file is saved.
#     -Plain gives plain ASCII characters (for consoles that draw special characters wrongly).
$UiWidth = 78
if ($Plain) { $G = @{ H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; DH = '='; DV = '|'; DTL = '+'; DTR = '+'; DBL = '+'; DBR = '+'; Full = '#'; Empty = '.' } }
else {
    $G = @{}
    foreach ($pair in @(@('H', 0x2500), @('V', 0x2502), @('TL', 0x250C), @('TR', 0x2510), @('BL', 0x2514), @('BR', 0x2518), @('DH', 0x2550), @('DV', 0x2551), @('DTL', 0x2554), @('DTR', 0x2557), @('DBL', 0x255A), @('DBR', 0x255D), @('Full', 0x2588), @('Empty', 0x2591))) { $G[$pair[0]] = [string][char]$pair[1] }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}

# --- Clean log: timestamp, level and text, without colours. Before step 1 the lines are buffered until the result folder exists.
#     The full console output (with the tools' own text) is saved separately in rapportkit-console.log.
$script:LogFile = $null
$script:LogBuffer = [System.Collections.Generic.List[string]]::new()
$script:RunStart = Get-Date
function Write-Log([string]$Level, [string]$Msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1,-7} {2}' -f (Get-Date), $Level, ($Msg -replace '\s*\r?\n\s*', ' ')
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 } catch { } }
    else { $script:LogBuffer.Add($line) }
}
# Starts the log file in the result folder: writes a header with environment details and empties what was buffered.
function Initialize-Log([string]$Dir) {
    $script:LogFile = Join-Path $Dir 'rapportkit.log'
    $opts = ($BoundParams.Keys | Sort-Object | ForEach-Object { if ($BoundParams[$_] -is [switch]) { "-$_" } else { "-$_ $($BoundParams[$_])" } }) -join ' '
    $hdr = @(
        ('# Azure Rapportkit {0}' -f $KitVersion),
        ('# Start: {0:yyyy-MM-dd HH:mm:ss}   Host: {1}   OS: {2}   PowerShell: {3}' -f $script:RunStart, $env:COMPUTERNAME, [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion),
        ("# Parameters: $opts"),
        '# Time                 Level   Message'
    )
    Add-Content -Path $script:LogFile -Value $hdr -Encoding utf8
    foreach ($l in $script:LogBuffer) { Add-Content -Path $script:LogFile -Value $l -Encoding utf8 }
    $script:LogBuffer.Clear()
}

# --- Helper functions for text and frames
function Format-Duration([double]$Sec) {
    if ($Sec -lt 60) { return ('{0:N0} s' -f $Sec) }
    '{0} min {1:00} s' -f [int][math]::Floor($Sec / 60), [int]($Sec % 60)
}
# Wraps text at words so that no line gets longer than $Width.
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
# A line in a frame: $Segments = list of @(text, colour). Padded to the width of the frame.
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
# A status line: coloured label followed by text that wraps with a hanging indent.
function Write-Line([string]$Badge, [string]$Color, [string]$Msg, [string]$MsgColor = 'Gray') {
    $lines = Format-Wrap $Msg ($UiWidth - 14)
    Write-Host '  ' -NoNewline
    Write-Badge $Badge $Color
    Write-Host ('  ' + $(if ($lines.Count) { $lines[0] } else { '' })) -ForegroundColor $MsgColor
    for ($i = 1; $i -lt $lines.Count; $i++) { Write-Host ((' ' * 13) + $lines[$i]) -ForegroundColor $MsgColor }
}

# --- Heading for a main step: box with the step number, progress bar and heading, plus an explanation.
$script:StepLog = [ordered]@{}
$script:CurStep = 0
$script:CurTitle = ''
$script:CurStart = $null
# Closes the current step and saves how long it took.
function Complete-Step {
    if ($script:CurStep -gt 0 -and $script:CurStart) {
        $sec = [math]::Round(((Get-Date) - $script:CurStart).TotalSeconds, 1)
        $script:StepLog[[string]$script:CurStep] = @{ Title = $script:CurTitle; Seconds = $sec }
        Write-Log 'STEP' ('Step {0} done: {1} ({2:N1} s)' -f $script:CurStep, $script:CurTitle, $sec)
        $script:CurStart = $null
    }
}
function Write-Step([int]$Number, [string]$Title, [string]$Explain) {
    Complete-Step
    $script:CurStep = $Number; $script:CurTitle = $Title; $script:CurStart = Get-Date
    $filled = [int][math]::Round(10 * $Number / $TotalSteps)
    $bar = ($G.Full * $filled) + ($G.Empty * (10 - $filled))
    $label = ' STEP {0} OF {1}  ' -f $Number, $TotalSteps
    $titleMax = $UiWidth - 2 - $label.Length - 10 - 2
    $shown = if ($Title.Length -gt $titleMax) { $Title.Substring(0, $titleMax - 1) + '.' } else { $Title }
    Write-Host ''
    Write-Host ($G.TL + ($G.H * ($UiWidth - 2)) + $G.TR) -ForegroundColor DarkCyan
    Write-BoxLine @(@($label, 'Cyan'), @($bar, 'Cyan'), @(('  ' + $shown), 'White'))
    Write-Host ($G.BL + ($G.H * ($UiWidth - 2)) + $G.BR) -ForegroundColor DarkCyan
    if ($Explain) { foreach ($l in (Format-Wrap $Explain ($UiWidth - 4))) { Write-Host ('  ' + $l) -ForegroundColor DarkGray } }
    Write-Log 'STEP' ('Step {0} of {1}: {2}' -f $Number, $TotalSteps, $Title)
}

# --- Lines within a step
function Write-Action($msg) {                       # "now I am doing this"
    Write-Log 'ACTION' ([string]$msg)
    $lines = Format-Wrap ([string]$msg) ($UiWidth - 6)
    for ($i = 0; $i -lt $lines.Count; $i++) { Write-Host ($(if ($i -eq 0) { '   > ' } else { '     ' }) + $lines[$i]) -ForegroundColor White }
}
function Write-Ok($msg)    { Write-Log 'OK' ([string]$msg);     Write-Line 'OK' 'Green' ([string]$msg) 'Gray' }            # it went well
function Write-Warn2($msg) { Write-Log 'WARNING' ([string]$msg); Write-Line 'WARNING' 'Yellow' ([string]$msg) 'Yellow' }   # something went wrong, we continue
function Write-Todo($msg)  { Write-Log 'TODO' ([string]$msg);     Write-Line 'TODO' 'Magenta' ([string]$msg) 'Magenta' }       # something YOU must do
# A check line (pre-flight, role check): OK / INFO / WARNING / MISSING.
function Write-Check([string]$State, [string]$Name, [string]$Detail) {
    $color = switch ($State) { 'OK' { 'Green' } 'INFO' { 'Cyan' } 'WARNING' { 'Yellow' } default { 'Red' } }
    $msgColor = switch ($State) { 'WARNING' { 'Yellow' } 'MISSING' { 'Red' } default { 'Gray' } }
    Write-Log $State "${Name}: $Detail"
    Write-Line $State $color "${Name}: $Detail" $msgColor
}
function Write-KeyValue([string]$Key, [string]$Value) {
    Write-Host ('   {0,-11}' -f $Key) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

# --- Banner shown first
function Write-Banner {
    Write-Host ''
    Write-Host ($G.DTL + ($G.DH * ($UiWidth - 2)) + $G.DTR) -ForegroundColor Cyan
    Write-BoxLine @(, @('', 'White')) 'Cyan' -Double
    Write-BoxLine @(@('   AZURE RAPPORTKIT', 'White'), @("   v$KitVersion", 'Cyan')) 'Cyan' -Double
    Write-BoxLine @(, @('   Maps governance, security and cost in an Azure tenant', 'Gray')) 'Cyan' -Double
    Write-BoxLine @(, @('', 'White')) 'Cyan' -Double
    Write-BoxLine @(, @('   Writes nothing to Azure resources or the Entra configuration.', 'DarkGray')) 'Cyan' -Double
    Write-BoxLine @(, @('   Stop with Ctrl+C at any time and run again: what is done is reused.', 'DarkGray')) 'Cyan' -Double
    Write-Host ($G.DBL + ($G.DH * ($UiWidth - 2)) + $G.DBR) -ForegroundColor Cyan
    Write-Log 'INFO' "Azure Rapportkit v$KitVersion starting"
}

# --- Status label for a summary line
function Get-StateBadge([string]$State) {
    switch ($State) {
        'OK'     { return @('OK', 'Green') }
        'Failed' { return @('FAILED', 'Red') }
        'Partial' { return @('PARTIAL', 'Yellow') }
        default  { return @('SKIPPED', 'DarkGray') }
    }
}

# --- Summary box at the end: one line per tool with time, notes and paths.
function Write-SummaryBox($StatusTable, $Facts) {
    $toolStep = @{ 'Governance Visualizer' = 6; 'azqr' = 7; 'Maester' = 8; 'Defender and cost' = 9; 'Structure' = 9 }
    Write-Host ''
    Write-Host ($G.DTL + ($G.DH * ($UiWidth - 2)) + $G.DTR) -ForegroundColor Cyan
    Write-BoxLine @(, @('   SUMMARY', 'White')) 'Cyan' -Double
    Write-Host ($G.DBL + ($G.DH * ($UiWidth - 2)) + $G.DBR) -ForegroundColor Cyan
    foreach ($k in $StatusTable.Keys) {
        $s = $StatusTable[$k]
        $b = Get-StateBadge $s.State
        $dur = ''
        if ($toolStep.ContainsKey($k) -and $script:StepLog.Contains([string]$toolStep[$k]) -and $s.State -ne 'Skipped') { $dur = '   ' + (Format-Duration $script:StepLog[[string]$toolStep[$k]].Seconds) }
        Write-Host '  ' -NoNewline
        Write-Badge $b[0] $b[1]
        Write-Host ('  ' + $k) -NoNewline -ForegroundColor White
        Write-Host $dur -ForegroundColor DarkGray
        if ($s.State -in 'Failed', 'Partial' -and $s.Note) {
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

# Aborts the whole run with a clear message. $Fix = what the user should do.
function Fail([string]$What, [string]$Fix) {
    $ex = [System.Exception]::new($What)
    $ex.Data['Fix'] = $Fix
    throw $ex
}

# Turns a caught error into a text (message + any action) for status/warnings.
function Get-ErrorText($err) {
    $ex = if ($err -is [System.Management.Automation.ErrorRecord]) { $err.Exception } else { $err }
    $t = $ex.Message
    if ($ex.Data -and $ex.Data['Fix']) { $t += ' ' + $ex.Data['Fix'] }
    $t + (Get-SignInHelp $ex.Message)
}

# Recognises common sign-in errors in corporate environments (Conditional Access, MFA, compliant device, blocked app) and
# gives a text that the customer can take to their IT department. Empty string if nothing is recognised.
function Get-SignInHelp([string]$Text) {
    if ($Text -match 'AADSTS(53000|53001|53002|53003|53004|530003|530004|50105|50020|700016|65001|900144|50076|50079|50158)|[Cc]onditional [Aa]ccess|compliant|blocked by|not compliant|device (is )?not') {
        return ' This looks like the tenant''s Conditional Access or a consent setting is stopping the sign-in. Ask IT to allow the apps "Microsoft Azure CLI", "Azure PowerShell" and "Microsoft Graph Command Line Tools" for your account, or run the script from a managed/compliant computer.'
    }
    ''
}

# Builds the command to run the script again with the same choices (incl. tenant ID, so no question is asked).
function Get-RerunCommand {
    $p = @()
    foreach ($k in $BoundParams.Keys) {
        $v = $BoundParams[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $p += "-$k" } }
        else { $p += "-$k"; $p += $(if ("$v" -match '\s') { "'$v'" } else { "$v" }) }
    }
    '.\Run-Rapportkit.ps1 ' + ($p -join ' ')
}

# Warnings shown in the report (for example an unexpected file format).
$Warnings = [System.Collections.Generic.List[string]]::new()
function Add-Warning([string]$msg) { $Warnings.Add($msg); Write-Warn2 $msg }

# Status per tool, shown in the console and at the top of the report.
$Status = [ordered]@{}
function Set-Status($step, $state, $note = '') { $Status[$step] = @{ State = $state; Note = $note }; Write-Log 'STATUS' "$step = $state $note" }
# Sets "Skipped" only if no error has been registered for the step yet.
function Set-SkippedUnlessFailed($step, $note = '') { if (-not $Status.Contains($step)) { Set-Status $step 'Skipped' $note } }

# ===========================================================================
# Helper functions for finding, fetching and verifying tools
# ===========================================================================

# Reads PATH from the registry and adds entries that are missing, so that newly installed programs
# (az, azqr, pwsh) are found right away without restarting the window. Existing entries are kept.
function Update-SessionPath {
    $fresh = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
    $have = @($env:Path -split ';' | Where-Object { $_ })
    $add = @($fresh -split ';' | Where-Object { $_ -and ($have -notcontains $_) })
    $env:Path = ($have + $add) -join ';'
}

# Does the command exist on the computer?
function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Can the address be reached? Any HTTP response (even 401/403/405) counts as reachable; only no response is an error.
function Test-Endpoint([string]$Url) {
    try { Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 8 -UseBasicParsing | Out-Null; return $true }
    catch { return [bool]$_.Exception.Response }
}

# Asks a yes/no question (y/yes; j/ja also count as yes). The default answer is no. -Yes answers yes. If the question cannot be asked
# (no input, for example an automated run) we continue.
function Confirm-Continue([string]$Question) {
    if ($Yes) { Write-Host "  $Question -> yes (-Yes)" -ForegroundColor DarkCyan; return $true }
    try { $a = Read-Host "  $Question (y/N)" }
    catch { Write-Warn2 'The question cannot be asked (no input). Continuing.'; return $true }
    return [bool](("$a").Trim([char]0xFEFF).Trim() -match '^[jJyY]')
}

# Do the effective permissions ($Perms = response from Microsoft.Authorization/permissions) allow the action?
# Wildcards (*) in roles are handled with -like; notActions subtract.
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

# Calls Azure Resource Manager via az rest (no az extension needed). Tries 3 times on
# throttling (429). Throws an error with Azure's message if the call fails.
function Invoke-ArmRest([string]$Method, [string]$Url, $Body) {
    # The query string is sent as --url-parameters: an & in --url is otherwise split by cmd.exe (az is a .cmd file) and everything after it disappears.
    # The values are decoded first, because az encodes them again.
    $base, $qs = $Url -split '\?', 2
    $azArgs = @('rest', '--method', $Method, '--url', $base, '-o', 'json')
    if ($qs) { $azArgs += '--url-parameters'; $azArgs += @($qs -split '&' | Where-Object { $_ } | ForEach-Object { $kv = $_ -split '=', 2; if ($kv.Count -eq 2) { '{0}={1}' -f $kv[0], [uri]::UnescapeDataString($kv[1]) } else { $_ } }) }
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
            # Some APIs (for example Defender) give exit code 1 despite a complete response. Valid JSON without an error field is accepted.
            $text = ($out | Out-String).Trim()
            if ($text) {
                try { $parsed = $text | ConvertFrom-Json; if ($code -eq 0 -or -not $parsed.error) { return $parsed } } catch { }
            }
            if ($code -eq 0) { return $null }
            # Run again with stderr to get the error message.
            $txt = (& az @azArgs 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) { return ($txt | ConvertFrom-Json) }
            # Throttling (Cost Management is strict): wait longer each time and try again, up to 5 times.
            if ($txt -match 'TooManyRequests|Too Many Requests|429' -and $i -lt 5) { Write-Host "      (throttled by Azure, waiting $(15 * $i) s and trying again)" -ForegroundColor DarkGray; Start-Sleep -Seconds (15 * $i); continue }
            $short = ($txt -split "`n" | Where-Object { $_ -match 'ERROR|Error|error|message' } | Select-Object -First 1)
            throw $(if ($short) { $short.Trim() } else { $txt })
        }
    }
    finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

# Checks the roles of the signed-in account (Azure at tenant root, Entra via Graph) against what the chosen tools need.
# Gives a list with State (OK/WARNING/MISSING/INFO), Kind (Azure/Entra), Role, Name and Detail.
function Get-RoleChecks([string]$Tenant, [bool]$NeedGovViz, [bool]$NeedPortal, [bool]$NeedMaester) {
    $res = [System.Collections.Generic.List[object]]::new()
    $add = { param($s, $k, $role, $d) $res.Add([pscustomobject]@{ State = $s; Kind = $k; Role = $role; Name = $role; Detail = $d }) }

    # Roles assigned at tenant root (including via groups) and effective permissions there and on the first subscription.
    $names = @()
    $meId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($meId) { $names = @(az role assignment list --scope '/' --assignee $meId --include-inherited --include-groups --query '[].roleDefinitionName' -o tsv 2>$null | Where-Object { $_ }) }
    $rootPerms = $null; $subPerms = $null
    try { $rootPerms = (az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/$Tenant/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json 2>$null | ConvertFrom-Json).value } catch { }
    $firstSub = az account list --query '[0].id' -o tsv 2>$null
    if ($firstSub) { try { $subPerms = (az rest --method get --url "https://management.azure.com/subscriptions/$firstSub/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json 2>$null | ConvertFrom-Json).value } catch { } }
    $have = if ($names.Count) { $names -join ', ' } else { 'none at tenant root' }

    # Read access at tenant root. Governance Visualizer only tests that the management group can be read, so which role
    # gives the read access does not matter. The Reader role is still recommended (least privilege): if the account has
    # more roles than Reader the tool writes a "least privilege" recommendation (which the script does not let pause).
    $effRoot = Test-ActionAllowed $rootPerms 'Microsoft.Management/managementGroups/read'
    $effSub = Test-ActionAllowed $subPerms 'Microsoft.Resources/subscriptions/resources/read'
    if ($names -contains 'Reader') { & $add 'OK' 'Azure' 'Reader' 'assigned at tenant root' }
    elseif ($effRoot) { & $add 'OK' 'Azure' 'Reader' "read access at tenant root exists via another role ($have). The Reader role is recommended but not required." }
    elseif ($effSub) { & $add 'WARNING' 'Azure' 'Reader' 'missing at tenant root but present on a subscription: azqr and portal data work, Governance Visualizer (needs tenant root) does not' }
    else { & $add 'MISSING' 'Azure' 'Reader' "missing (has: $have)" }

    if ($NeedPortal) {
        foreach ($d in @(@{ Role = 'Security Reader'; Action = 'Microsoft.Security/assessments/read'; Why = 'Defender data' }, @{ Role = 'Cost Management Reader'; Action = 'Microsoft.CostManagement/query/read'; Why = 'cost data' })) {
            if ($names -contains $d.Role) { & $add 'OK' 'Azure' $d.Role 'assigned at tenant root' }
            elseif (Test-ActionAllowed $rootPerms $d.Action) { & $add 'OK' 'Azure' $d.Role "permission for $($d.Why) exists via another role" }
            elseif (Test-ActionAllowed $subPerms $d.Action) { & $add 'WARNING' 'Azure' $d.Role "missing at tenant root but $($d.Why) can be fetched at subscription level" }
            else { & $add 'MISSING' 'Azure' $d.Role "missing, so $($d.Why) cannot be fetched" }
        }
    }

    # Entra ID role for Maester (Global Reader or Global Administrator), read via Microsoft Graph.
    if ($NeedMaester) {
        $dirRoles = @(az rest --method get --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName' --query 'value[].displayName' -o tsv 2>$null | Where-Object { $_ })
        if ($LASTEXITCODE -ne 0) { & $add 'INFO' 'Entra' 'Global Reader' 'could not be checked here (checked when Maester signs in)' }
        elseif ($dirRoles -contains 'Global Reader' -or $dirRoles -contains 'Global Administrator') { & $add 'OK' 'Entra' 'Global Reader' "Entra role exists ($($dirRoles -join ', '))" }
        else { & $add 'MISSING' 'Entra' 'Global Reader' 'missing in Entra ID (Global Reader or Global Administrator is needed for Maester)' }
    }
    $res
}

# Gives instructions (one line per element) for adding the roles that are missing.
function Get-RoleInstructions($Missing) {
    $azure = @($Missing | Where-Object { $_.Kind -eq 'Azure' })
    $entra = @($Missing | Where-Object { $_.Kind -eq 'Entra' })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Do you use Privileged Identity Management (PIM)? Then activate the roles first (Entra ID > Privileged Identity Management > My roles) and run again. Nothing is missing in that case, the roles are just not active.')
    if ($azure.Count) {
        $lines.Add('Azure roles (at tenant root, scope "/"):')
        $lines.Add('1. Entra ID > Properties > "Access management for Azure resources" = Yes. Save, sign out and sign in again.')
        $lines.Add('2. Run in PowerShell:')
        $lines.Add('     $me = az ad signed-in-user show --query id -o tsv')
        foreach ($r in $azure) { $lines.Add(('     az role assignment create --assignee-object-id $me --assignee-principal-type User --role "{0}" --scope "/"' -f $r.Role)) }
        $lines.Add('3. Set "Access management for Azure resources" back to No. The roles can take a minute to take effect.')
    }
    if ($entra.Count) { $lines.Add('Entra role: Entra ID > Roles and administrators > Global Reader > Add assignments > choose your account.') }
    $lines
}

# Asks a yes/no question with a default answer. -Yes answers yes. If the question cannot be asked (no input) the default answer is used.
function Read-YesNo([string]$Question, [bool]$DefaultYes = $true) {
    if ($Yes) { Write-Log 'INFO' "$Question -> yes (-Yes)"; return $true }
    $hint = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    try { $a = Read-Host "  $Question ($hint)" } catch { return $DefaultYes }
    $a = ("$a").Trim([char]0xFEFF).Trim()
    if (-not $a) { return $DefaultYes }
    return [bool]($a -match '^[jJyY]')
}

# Checks SHA256 of a downloaded file against the tested checksum. If it does not match the run is aborted, unless
# -AllowUnverified (or -LatestTools, which has no checksums) is set.
function Assert-FileHash([string]$Path, [string]$Expected, [string]$What) {
    if (-not $Expected) { return }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    if ($actual -eq $Expected) { Write-Ok "${What}: the checksum (SHA256) matches the tested version"; return }
    if ($AllowUnverified) { Add-Warning "${What}: the checksum does not match (expected $Expected, got $actual). Continuing because -AllowUnverified is set."; return }
    Fail "${What}: the checksum (SHA256) does not match the tested version (expected $($Expected.Substring(0, 16))..., got $($actual.Substring(0, 16))...). The file may be modified or damaged." 'Run the script again to fetch the file again. If the error repeats: contact whoever gave you the script. Only after your own check can -AllowUnverified be used.'
}

# Folder picker (dialog). Gives $null if it cannot be shown or if the user cancels.
function Show-FolderDialog {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Choose a folder. A subfolder "rapportkit" is created there for the result.'
        $d.ShowNewFolderButton = $true
        if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return (Join-Path $d.SelectedPath 'rapportkit') }
    }
    catch { Write-Warn2 'The folder picker could not be opened. Type the path instead.' }
    return $null
}

# Warnings for a chosen result folder: OneDrive (syncs to the cloud), folders that Windows protects against writing
# (Controlled folder access) and too long paths (limit 260 characters).
function Get-OutputRootWarnings([string]$Path) {
    $w = [System.Collections.Generic.List[string]]::new()
    $full = try { [IO.Path]::GetFullPath($Path) } catch { $Path }
    foreach ($e in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
        $v = [Environment]::GetEnvironmentVariable($e)
        if ($v -and $full -like "$v*") { $w.Add('The folder is in OneDrive: the result (which is confidential) is then synced to the cloud.'); break }
    }
    foreach ($sf in 'MyDocuments', 'Desktop', 'MyPictures', 'MyVideos', 'MyMusic') {
        $p = try { [Environment]::GetFolderPath($sf) } catch { $null }
        if ($p -and $full -like "$p*") { $w.Add("The folder is under $sf, which Windows can protect against writing from unknown programs (Controlled folder access)."); break }
    }
    if ($full.Length -gt 90) { $w.Add('The path is long. The tools'' file names become long and Windows has a limit of 260 characters.') }
    , $w
}

# Asks where the result should be saved. If -OutputRoot is given (or the question cannot be asked) it/the default folder is used.
function Select-OutputRoot([string]$Given) {
    if ($Given) { return $Given }
    $profileDir = Join-Path $env:USERPROFILE 'rapportkit'
    if ($Yes -or [Console]::IsInputRedirected) { Write-Action "Result folder (default): $profileDir"; return $profileDir }
    Write-Host ''
    Write-Host '  Where should the result be saved?' -ForegroundColor White
    Write-Host '  It contains confidential information about the environment. The tools are fetched there too.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ("    [1] {0}   (recommended)" -f $profileDir)
    Write-Host '    [2] C:\rapportkit'
    Write-Host '    [3] Another folder: type the path here, or [B] to browse'
    Write-Host ''
    while ($true) {
        try { $a = Read-Host '  Choose [Enter = 1]' } catch { return $profileDir }
        $a = ("$a").Trim([char]0xFEFF).Trim().Trim('"')
        if (-not $a -or $a -eq '1') { $p = $profileDir }
        elseif ($a -eq '2') { $p = 'C:\rapportkit' }
        elseif ($a -match '^[bB]$') { $p = Show-FolderDialog; if (-not $p) { continue } }
        elseif ($a -eq '3') { Write-Host '  Type the path (for example D:\rapportkit) or B to browse.'; continue }
        else { $p = [Environment]::ExpandEnvironmentVariables($a) }
        if (-not [IO.Path]::IsPathRooted($p)) { Write-Warn2 'Give a full path (for example D:\rapportkit).'; continue }
        $warn = Get-OutputRootWarnings $p
        if ($warn.Count) {
            foreach ($x in $warn) { Write-Warn2 $x }
            if (-not (Read-YesNo "Use $p anyway?" $false)) { continue }
        }
        return $p
    }
}

# Signs out of the sessions the script created itself (a sign-in that existed before is not touched), unless -KeepLogin is set.
# On a customer's computer no tokens should remain after the run.
function Invoke-SessionCleanup {
    $targets = [System.Collections.Generic.List[string]]::new()
    if ($azReady -and -not $azWasLoggedIn) { $targets.Add('Azure CLI') }
    if ($azPsByUs) { $targets.Add('Azure PowerShell') }
    if ($graphByUs) { $targets.Add('Microsoft Graph') }
    if (-not $targets.Count) { return }
    $list = $targets -join ', '
    if ($KeepLogin) { Write-Action "The sign-ins ($list) are left in place (-KeepLogin)."; return }
    Write-Host ''
    if (-not (Read-YesNo "Sign out of $list, which the script signed in to? (recommended on a customer's computer)" $true)) { Write-Action "The sign-ins ($list) are left in place."; return }
    if ($targets -contains 'Azure CLI') { try { az logout 2>$null | Out-Null; Write-Ok 'Signed out of Azure CLI' } catch { Write-Warn2 'Could not sign out of Azure CLI (run az logout).' } }
    if ($targets -contains 'Azure PowerShell') { try { Disconnect-AzAccount -ErrorAction Stop | Out-Null; Write-Ok 'Signed out of Azure PowerShell' } catch { Write-Warn2 'Could not sign out of Azure PowerShell (run Disconnect-AzAccount).' } }
    if ($targets -contains 'Microsoft Graph') { try { Disconnect-MgGraph -ErrorAction Stop | Out-Null; Write-Ok 'Signed out of Microsoft Graph' } catch { Write-Warn2 'Could not sign out of Microsoft Graph (run Disconnect-MgGraph).' } }
}

# Version of an installed module (highest), or $null.
function Get-ModuleVersionText([string]$Name) {
    $m = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    if ($m) { $m.Version.ToString() } else { $null }
}

# State per data source for run-summary.json, finer than the steps: Defender and cost are one step but several sources.
# Anything that did not run is reported as the step's own state (for example Skipped).
function Get-SourceStates {
    $src = [ordered]@{}
    foreach ($m in @(@('azgovviz', 'Governance Visualizer'), @('azqr', 'azqr'), @('maester', 'Maester'), @('structure', 'Structure'))) {
        if ($Status.Contains($m[1])) { $src[$m[0]] = [ordered]@{ state = $Status[$m[1]].State; note = $Status[$m[1]].Note } }
    }
    if ($script:PortalSources) { foreach ($k in $script:PortalSources.Keys) { $src[$k] = $script:PortalSources[$k] } }
    elseif ($Status.Contains('Defender and cost')) {
        foreach ($k in 'plans', 'secureScore', 'secureScoreControls', 'recommendations', 'cost') { $src[$k] = [ordered]@{ state = $Status['Defender and cost'].State; note = $Status['Defender and cost'].Note } }
    }
    $src
}

# Machine-readable summary of the run (run-summary.json in the result folder): evidence of what was run, with which
# versions, how long it took and how it went.
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
        sources         = Get-SourceStates
        results         = @($Status.Keys | ForEach-Object { [ordered]@{ name = $_; state = $Status[$_].State; note = $Status[$_].Note } })
        steps           = @($script:StepLog.Keys | ForEach-Object { [ordered]@{ step = [int]$_; title = $script:StepLog[$_].Title; seconds = $script:StepLog[$_].Seconds } })
        warnings        = @($Warnings)
    }
    try { $obj | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $RunDir 'run-summary.json') -Encoding utf8 } catch { }
}

# Is the file a complete zip that contains (at least) one entry that matches $MustContain?
function Test-Zip([string]$Path, [string]$MustContain) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try { return ($z.Entries.Count -gt 0) -and (-not $MustContain -or [bool]($z.Entries | Where-Object { $_.FullName -like $MustContain })) }
        finally { $z.Dispose() }
    }
    catch { return $false }
}

# Downloads a file. Tries 3 times and checks that the file is not empty/too small.
function Get-Download([string]$Url, [string]$Dest, [long]$MinBytes = 1024) {
    if ($Offline) { Fail "Offline mode: cannot download $Url." 'Run without -Offline, or put the file in the folder tools\ (see Build-Bundle.ps1).' }
    for ($i = 1; $i -le 3; $i++) {
        try {
            Write-Action "Downloading $Url (attempt $i/3)"
            Invoke-WebRequest -Uri $Url -OutFile $Dest -Headers @{ 'User-Agent' = 'azure-rapportkit' } -UseBasicParsing
            $len = (Get-Item $Dest).Length
            if ($len -lt $MinBytes) { throw "the file was only $len bytes" }
            return
        }
        catch {
            Write-Warn2 "Attempt $i/3 failed: $($_.Exception.Message)"
            Remove-Item $Dest -Force -ErrorAction SilentlyContinue
            if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
        }
    }
    Fail "Could not download $Url." 'Check the internet connection, proxy and firewall (github.com, api.github.com, objects.githubusercontent.com and www.powershellgallery.com must be reachable). Then run the script again.'
}

# Installs a program with winget and then checks that the command actually exists.
# (winget exit codes are unclear, so we rely on the check that the program can be found.)
function Install-WithWinget([string]$Name, [string]$Id, [string]$Command, [string]$ManualUrl, [string]$Version) {
    if (-not (Test-Cmd winget)) {
        Fail "$Name is missing and winget does not exist, so it cannot be installed automatically." "Install $Name manually ($ManualUrl), open a NEW PowerShell window and run the script again."
    }
    $wa = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($Version) { $wa += @('--version', $Version) }
    Write-Action "winget $($wa -join ' ')  (may open an approval window: choose Yes)"
    winget @wa | Out-Host
    Update-SessionPath
    if (-not (Test-Cmd $Command)) {
        Fail "$Name was not installed (winget exit code $LASTEXITCODE)." "Install $Name manually ($ManualUrl), open a NEW PowerShell window and run the script again."
    }
    Write-Ok "$Name installed"
}

# Installs Azure CLI: first with winget if it exists, otherwise (or if winget fails) by fetching Microsoft's
# installer file (MSI) from https://aka.ms/installazurecliwindows, checking that it is signed by Microsoft and running
# it silently. The MSI install asks for administrator approval (UAC): choose Yes.
function Install-AzureCli {
    $manual = 'https://aka.ms/installazurecliwindows'
    if (Test-Cmd winget) {
        try { Install-WithWinget 'Azure CLI' 'Microsoft.AzureCLI' 'az' $manual; return }
        catch { Write-Warn2 "winget could not install Azure CLI ($($_.Exception.Message)). Trying the installer file from Microsoft." }
    }
    else { Write-Warn2 'winget does not exist on this computer. Azure CLI is fetched as an installer file (MSI) from Microsoft instead.' }
    $msi = Join-Path $env:TEMP 'azure-cli-rapportkit.msi'
    try {
        Get-Download $manual $msi 10MB
        $sig = Get-AuthenticodeSignature -FilePath $msi
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            Fail ('The Azure CLI installer file is not signed by Microsoft (signature status: {0}).' -f $sig.Status) "Install Azure CLI manually ($manual) and run the script again."
        }
        Write-Ok 'The installer file is signed by Microsoft'
        Write-Todo 'Approve the installation in the window that opens (Yes at the administrator prompt). The installation takes a minute.'
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"{0}"' -f $msi), '/qn', '/norestart') -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { Fail "The Azure CLI installation failed (msiexec exit code $($p.ExitCode))." "Install Azure CLI manually ($manual), open a NEW PowerShell window and run the script again." }
    }
    catch [System.ComponentModel.Win32Exception] {
        Fail 'The Azure CLI installation was cancelled (administrator approval was denied or is blocked by the computer''s policies).' "Ask IT to install Azure CLI ($manual), open a NEW PowerShell window and run the script again."
    }
    finally { Remove-Item $msi -Force -ErrorAction SilentlyContinue }
    Update-SessionPath
    $wbin = Join-Path $env:ProgramFiles 'Microsoft SDKs\Azure\CLI2\wbin'
    if (-not (Test-Cmd az) -and (Test-Path (Join-Path $wbin 'az.cmd'))) { $env:Path = "$wbin;$env:Path" }
    if (-not (Test-Cmd az)) { Fail 'Azure CLI was installed but could not be found.' "Open a NEW PowerShell window and run the script again (the installation is complete then). Otherwise: $manual" }
    Write-Ok 'Azure CLI installed'
}

# Fetches a PowerShell module into our own module folder ($ModDir) and checks that it can be found.
# A separate folder is used to avoid problems when Documents is redirected to OneDrive.
# $MinVersion/$MaxVersion = accepted range for already installed versions (max counts as "lower than"). If there is no
# accepted version $Pin (the tested version) is fetched, or the latest within the range if $Pin is missing (-LatestTools).
# The version is checked: Windows has for example a built-in Pester 3.4 that is no use to Maester (needs 5.5+).
function Install-PsModule([string]$Name, [string]$Pin, [string]$MinVersion, [string]$MaxVersion) {
    $have = @(Get-Module -ListAvailable -Name $Name)
    if ($MinVersion) { $have = @($have | Where-Object { $_.Version -ge [version]$MinVersion }) }
    if ($MaxVersion) { $have = @($have | Where-Object { $_.Version -lt [version]$MaxVersion }) }
    if ($have.Count) { Write-Ok "Module $Name already exists (version $($have[0].Version))"; return }
    if (Test-Path "$ToolsDir\modules\$Name") {            # offline-bundle
        Write-Action "Copying module $Name from tools\modules"
        Copy-Item "$ToolsDir\modules\$Name" $ModDir -Recurse -Force
    }
    elseif (-not $Offline) {
        Write-Action "Fetching module $Name $Pin from PowerShell Gallery"
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
        catch { Fail "Could not fetch the module $Name from PowerShell Gallery: $($_.Exception.Message)" 'Check the internet connection (www.powershellgallery.com) and run the script again.' }
    }
    else { Fail "The module $Name does not exist in tools\modules and -Offline is set." 'Rebuild the bundle with Build-Bundle.ps1 or run without -Offline.' }
    $have = @(Get-Module -ListAvailable -Name $Name)
    if ($MinVersion) { $have = @($have | Where-Object { $_.Version -ge [version]$MinVersion }) }
    if (-not $have.Count) { Fail "The module $Name was fetched but could not be found in $ModDir." 'Delete the folder and run the script again.' }
    Write-Ok "Module $Name ready (version $($have[0].Version))"
}
# Reads a CSV file and checks that the expected columns exist. Gives $null (and a warning) if
# the file cannot be read or has an unexpected format, so that the rest of the report can still be built.
function Import-CsvChecked([string]$Path, [string[]]$Required, [string]$Delimiter = ',') {
    $leaf = Split-Path $Path -Leaf
    try {
        if ((Get-Item $Path).Length -eq 0) { Add-Warning "$leaf is empty."; return $null }
        $rows = @(Import-Csv -Path $Path -Delimiter $Delimiter)
        if ($rows.Count -gt 0) {
            $have = @($rows[0].PSObject.Properties.Name)
            $missing = @($Required | Where-Object { $have -notcontains $_ })
            if ($missing.Count) {
                Add-Warning "$leaf is missing the columns: $($missing -join ', '). The tool's file format may have changed; use the full report file instead."
                return $null
            }
        }
        return , $rows     # an empty but valid result (no rows) is OK
    }
    catch { Add-Warning "Could not read ${leaf}: $($_.Exception.Message)"; return $null }
}

# ===========================================================================
# Bootstrap: everything below requires PowerShell 7. If the script runs in Windows PowerShell 5.1
# PowerShell 7 is installed and the script is restarted there with the same parameters.
# ===========================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host '=== Starting: PowerShell 7 is required ===' -ForegroundColor Cyan
    Write-Host '    You are running Windows PowerShell 5.1. The tools require PowerShell 7.' -ForegroundColor DarkCyan
    try {
        Update-SessionPath
        if (-not (Test-Cmd pwsh)) {
            if ($NoInstall -or $Offline) { Fail 'PowerShell 7 is missing and installation is turned off (-NoInstall/-Offline).' 'Install PowerShell 7 (https://aka.ms/powershell) and run the script again.' }
            Install-WithWinget 'PowerShell 7' 'Microsoft.PowerShell' 'pwsh' 'https://aka.ms/powershell'
        }
    }
    catch {
        Write-Host ''
        Write-Host '=== The run was aborted ===' -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)"
        if ($_.Exception.Data['Fix']) { Write-Host "  How to proceed: $($_.Exception.Data['Fix'])" -ForegroundColor Yellow }
        exit 1
    }
    # Pass the parameters on to the new process.
    $fwd = @()
    foreach ($k in $BoundParams.Keys) {
        $v = $BoundParams[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $fwd += "-$k" } } else { $fwd += "-$k"; $fwd += "$v" }
    }
    Write-Action 'Restarting the script in PowerShell 7'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    exit $LASTEXITCODE
}

# ===========================================================================
# The run itself. Everything is in try/catch/finally so that an interruption always gives an
# understandable message and the log is closed.
# ===========================================================================
$TranscriptStarted = $false
try {

    # =======================================================================
    # STEP 1: Preparation
    # =======================================================================
    Write-Banner
    Write-Step 1 'Preparation' 'Tenant ID, where the result is saved, and the log file. Takes a few seconds.'
    Update-SessionPath

    # Tenant ID: use the parameter, otherwise suggest the one Azure CLI is already signed in to. The suggestion comes
    # from the sign-in that already exists on the computer (az account show); no tenant ID is saved in the script.
    if (-not $TenantId) {
        $guess = $null
        if (Test-Cmd az) {
            try {
                $guess = az account show --query tenantId -o tsv 2>$null
                $who = az account show --query user.name -o tsv 2>$null
            } catch { }
        }
        $prompt = 'Enter the tenant ID (Entra ID > Overview > Tenant ID)'
        if ($guess) { $prompt += " [Enter = $guess, taken from the Azure CLI sign-in as $who]" }
        try { $TenantId = Read-Host $prompt } catch { $TenantId = $null }
        if (-not $TenantId) { $TenantId = $guess }
    }
    if (-not $TenantId) { Fail 'The tenant ID is missing.' 'Run again with -TenantId <guid> (found in Entra ID > Overview).' }
    if ($TenantId -notmatch '^[0-9a-fA-F-]{36}$') { Fail "Invalid tenant ID: '$TenantId' (a GUID is expected)." 'Copy the Tenant ID from Entra ID > Overview and run again.' }
    $BoundParams['TenantId'] = $TenantId        # so that the "run again" command does not ask again
    Write-Ok "Tenant: $TenantId"

    # Where should the result go? If -OutputRoot is not given we ask (with a warning for OneDrive and protected folders).
    $OutputRoot = Select-OutputRoot $OutputRoot
    $BoundParams['OutputRoot'] = $OutputRoot        # so that the "run again" command uses the same folder

    # Result folders: one per tool under <OutputRoot>\<Period>\, plus a module folder of our own.
    $RunDir = Join-Path $OutputRoot $Period
    $ModDir = Join-Path $OutputRoot '_modules'
    $GvDir = Join-Path $OutputRoot "Azure-Governance-Visualizer-$GvVersion"
    $Dirs = @{}
    try {
        foreach ($n in 'azgovviz', 'azqr', 'maester', 'portal', 'struktur') {
            $Dirs[$n] = Join-Path $RunDir $n
            New-Item -ItemType Directory -Force $Dirs[$n] | Out-Null
        }
        New-Item -ItemType Directory -Force $ModDir | Out-Null
        # Test that we can actually write in the folder (for example protected or read-only locations).
        $probe = Join-Path $RunDir '.write-test'
        Set-Content -Path $probe -Value 'x'; Remove-Item $probe -Force
    }
    catch { Fail "Cannot write to $OutputRoot ($($_.Exception.Message))." 'Choose another folder with -OutputRoot (for example C:\Users\<you>\rapportkit) and run again.' }
    if ($env:PSModulePath -notlike "*$ModDir*") { $env:PSModulePath = "$ModDir;$env:PSModulePath" }
    Write-Ok "Result folder: $RunDir"

    # Password for the zip file: asked for right away, before the long run, so that a mistyped or too short password is not
    # discovered only afterwards. The question comes before the console log starts. The password is never saved in any file or log.
    # Encryption is optional: first a yes/no question (-Yes means yes), then the password. No gives an ordinary zip.
    if (-not $NoZip -and -not $NoEncrypt -and -not $ZipPassword -and -not $Yes) {
        Write-Host ''
        $encrypt = $true
        try { $encrypt = [bool](Read-YesNo 'Do you want to encrypt the result package (the zip file) with a password? Recommended if it is to be sent on.' $true) } catch { }
        if (-not $encrypt) { $NoEncrypt = [switch]$true; $BoundParams['NoEncrypt'] = [switch]$true }
    }
    if (-not $NoZip -and -not $NoEncrypt) {
        . (Join-Path $ScriptRoot 'lib\Crypto.ps1')
        if (-not $ZipPassword) {
            Write-Host ''
            Write-Action 'The result is packed in an encrypted file. Choose a password (at least 12 characters) and send it to the recipient by another channel than the file (for example SMS or phone).'
            for ($try = 1; $try -le 3 -and -not $ZipPassword; $try++) {
                try {
                    $p1 = Read-Host 'Password for the zip file' -AsSecureString
                    $p2 = Read-Host 'Type the password again' -AsSecureString
                }
                catch { Fail 'Cannot ask for a password in this environment.' 'Give -ZipPassword (SecureString) or, if the result does not leave the computer, -NoEncrypt.' }
                $t1 = ConvertFrom-RkSecureString $p1
                $t2 = ConvertFrom-RkSecureString $p2
                if ($t1 -ne $t2) { Write-Warn2 'The passwords differed. Try again.' }
                elseif ($t1.Length -lt $script:RkMinPasswordLength) { Write-Warn2 "The password is too short (at least $($script:RkMinPasswordLength) characters). Try again." }
                else { $ZipPassword = $p1 }
                $t1 = $null; $t2 = $null
            }
            if (-not $ZipPassword) { Fail 'No valid password was given.' 'Run again and choose a password of at least 12 characters, or use -NoEncrypt if the result does not leave the computer.' }
        }
        elseif ((ConvertFrom-RkSecureString $ZipPassword).Length -lt $script:RkMinPasswordLength) { Fail "The password in -ZipPassword is too short (at least $($script:RkMinPasswordLength) characters)." 'Give a longer password.' }
        Write-Ok 'Password for the zip file is chosen'
    }

    # Anonymized version of the report (for demos or sharing). Only asked interactively; -Yes means "no" here.
    if (-not $Anonymize -and -not $Yes) {
        Write-Host ''
        try { if (Read-YesNo 'Do you also want to create an anonymized version of the report (for demos or sharing, names and IDs are replaced by aliases)?' $false) { $Anonymize = [switch]$true; $BoundParams['Anonymize'] = [switch]$true } }
        catch { }
    }

    # Logs: a clean log (rapportkit.log) and the whole console output including the tools' text (rapportkit-console.log).
    Initialize-Log $RunDir
    try { Start-Transcript -Path (Join-Path $RunDir 'rapportkit-console.log') -Append | Out-Null; $TranscriptStarted = $true } catch { Write-Warn2 'Could not start the console log (continuing anyway).' }
    Write-Host ''
    Write-KeyValue 'Tenant' $TenantId
    Write-KeyValue 'Period' $Period
    Write-KeyValue 'Result' $RunDir
    Write-KeyValue 'Logs' 'rapportkit.log (cleaned), rapportkit-console.log (everything), run-summary.json'

    if ($ReportOnly) { Write-Action '-ReportOnly: skipping steps 2-9 and only building the report.' }
    else {

        # ===================================================================
        # STEP 2: Pre-flight. Checks the prerequisites BEFORE anything is fetched or installed,
        # shows what is missing and lets you choose whether to continue anyway.
        # ===================================================================
        Write-Step 2 'Pre-flight check of prerequisites' 'Checks that everything needed exists or can be fetched, before anything is installed. If something is missing you can choose whether to continue anyway.'
        $checks = [System.Collections.Generic.List[object]]::new()
        function Add-Check([string]$State, [string]$Name, [string]$Detail) { $checks.Add([pscustomobject]@{ State = $State; Name = $Name; Detail = $Detail }) }

        # Programs and modules: do they already exist, or must they be fetched?
        $need = [System.Collections.Generic.List[string]]::new()
        $wingetNeeded = $false
        # Azure CLI is always needed: sign-in, role check, azqr and Defender/cost data.
        if (-not (Test-Cmd az)) { $need.Add('Azure CLI (winget or MSI from Microsoft)'); $wingetNeeded = $true }
        if (-not $SkipAzqr) {
            if (-not (Test-Cmd azqr) -and -not (Get-ChildItem (Join-Path $env:LOCALAPPDATA 'azqr') -Recurse -Filter 'azqr.exe' -ErrorAction SilentlyContinue)) { $need.Add('azqr (winget/GitHub)'); $wingetNeeded = $true }
        }
        if (-not $SkipGovViz) {
            if (-not (Test-Path (Join-Path $GvDir 'pwsh\AzGovVizParallel.ps1'))) { $need.Add("Governance Visualizer $GvVersion (GitHub)") }
            foreach ($m in 'Az.Accounts', 'AzAPICall') { if (-not (Get-Module -ListAvailable -Name $m)) { $need.Add("module $m (PSGallery)") } }
        }
        if (-not $SkipMaester) {
            if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.5.0' })) { $need.Add('module Pester 5.5+ (PSGallery)') }
            if (-not (Get-Module -ListAvailable -Name Maester)) { $need.Add('module Maester (PSGallery)') }
        }
        if (-not $need.Count) { Add-Check 'OK' 'Tools' 'everything needed already exists on the computer' }
        elseif ($NoInstall) { Add-Check 'MISSING' 'Tools' "missing but -NoInstall is set: $($need -join ', ')" }
        elseif ($Offline) {
            if (Test-Path $ToolsDir) { Add-Check 'INFO' 'Tools' "fetched from tools\ (offline): $($need -join ', ')" }
            else { Add-Check 'MISSING' 'Tools' "-Offline is set but the folder tools\ is missing. Needed: $($need -join ', ')" }
        }
        else { Add-Check 'INFO' 'Tools' "will be fetched/installed: $($need -join ', ')" }

        # winget is needed for Azure CLI and azqr (azqr has a fallback via GitHub).
        if ($wingetNeeded -and -not $NoInstall -and -not $Offline) {
            if (Test-Cmd winget) { Add-Check 'OK' 'winget' 'exists' }
            elseif (-not (Test-Cmd az)) { Add-Check 'INFO' 'winget' 'does not exist: Azure CLI is fetched as an installer file (MSI) from Microsoft instead and requires administrator approval (UAC)' }
            else { Add-Check 'INFO' 'winget' 'does not exist (azqr is fetched directly from GitHub instead)' }
        }

        # Network: what is needed for downloading, and what is needed for sign-in and the run.
        $endpoints = @()
        if ($need.Count -and -not $Offline -and -not $NoInstall) {
            if (@($need -match 'GitHub|winget').Count) { $endpoints += , @('github.com', 'https://github.com', 'fetches Governance Visualizer/azqr') }
            if (@($need -match 'MSI').Count -and -not (Test-Cmd winget)) { $endpoints += , @('aka.ms', 'https://aka.ms', 'fetches Azure CLI') }
            if (@($need -match 'PSGallery').Count) { $endpoints += , @('www.powershellgallery.com', 'https://www.powershellgallery.com', 'fetches PowerShell modules') }
        }
        $endpoints += , @('login.microsoftonline.com', 'https://login.microsoftonline.com', 'sign-in')
        if (-not $SkipGovViz -or -not $SkipAzqr) { $endpoints += , @('management.azure.com', 'https://management.azure.com', 'Azure Resource Manager') }
        if (-not $SkipMaester) { $endpoints += , @('graph.microsoft.com', 'https://graph.microsoft.com', 'Microsoft Graph (Maester)') }
        foreach ($e in $endpoints) {
            if (Test-Endpoint $e[1]) { Add-Check 'OK' "Network $($e[0])" $e[2] }
            else { Add-Check 'MISSING' "Network $($e[0])" "cannot be reached ($($e[2])). Check the internet, proxy and firewall." }
        }

        # Disk space, Windows permissions and whether questions can be answered.
        try {
            $drive = Get-PSDrive -Name ($RunDir.Substring(0, 1)) -ErrorAction Stop
            if ($drive.Free -lt 1GB) { Add-Check 'WARNING' 'Disk space' ("only {0:N1} GB left on {1}: (at least 1 GB recommended)" -f ($drive.Free / 1GB), $drive.Name) }
            else { Add-Check 'OK' 'Disk space' ("{0:N1} GB free on {1}:" -f ($drive.Free / 1GB), $drive.Name) }
        }
        catch { }
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Add-Check 'INFO' 'Windows permissions' $(if ($isAdmin) { 'elevated (administrator). Not required.' } else { 'ordinary user. Enough; Windows may ask for approval (UAC) when installing PowerShell 7/Azure CLI.' })
        if ([Console]::IsInputRedirected) { Add-Check 'WARNING' 'Interactive window' 'input is redirected: questions cannot be answered and sign-in may fail' }
        # AppLocker/WDAC puts PowerShell in constrained mode, where the script's .NET calls are blocked and the run breaks halfway.
        $langMode = $ExecutionContext.SessionState.LanguageMode
        if ($langMode -ne 'FullLanguage') { Add-Check 'MISSING' 'PowerShell mode' "constrained mode ($langMode), for example via AppLocker/WDAC. The script uses calls that are blocked. Ask IT for an exception, or run on another computer." }
        else { Add-Check 'OK' 'PowerShell mode' 'FullLanguage' }
        $gpoPolicy = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined' })
        if ($gpoPolicy.Count) { Add-Check 'INFO' 'Execution policy (group policy)' ("controlled by group policy: " + (($gpoPolicy | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', ') + ". -ExecutionPolicy Bypass does not apply then; if this step works the script can run.") }
        Add-Check 'INFO' 'Permissions in Azure' 'checked right after sign-in in step 3 (Reader, Security Reader, Cost Management Reader, Global Reader); if something is missing you can choose to stop'

        foreach ($c in $checks) { Write-Check $c.State $c.Name $c.Detail }
        $problems = @($checks | Where-Object { $_.State -in 'MISSING', 'WARNING' })
        if ($problems.Count) {
            Write-Host ''
            if (-not (Confirm-Continue "$($problems.Count) prerequisite(s) are missing or uncertain (see above). Continue anyway?")) {
                Fail 'Aborted at your request after the pre-flight check.' 'Fix what is marked MISSING/WARNING above and run the script again.'
            }
        }
        else { Write-Ok 'The pre-flight check gave no remarks' }

        # ===================================================================
        # STEP 3: Azure CLI, sign-in and role check. Done before any other fetching so that you find out
        # right away if roles are missing.
        # ===================================================================
        Write-Step 3 'Azure CLI, sign-in and role check' 'Installs Azure CLI if it is missing, signs in (a browser window opens) and checks that the account has the right roles, before the rest is fetched. If you do not have time: press Ctrl+C and run the script again.'
        $azReady = $false
        $subCount = 0
        try {
            if (Test-Cmd az) { Write-Ok 'Azure CLI already exists' }
            elseif ($NoInstall) { Fail 'Azure CLI is missing (-NoInstall is set).' 'Install Azure CLI (https://aka.ms/installazurecliwindows) and run again.' }
            else { Install-AzureCli }

            $cur = az account show --query tenantId -o tsv 2>$null
            $azWasLoggedIn = ($cur -eq $TenantId)        # did the sign-in already exist? Then we do not sign it out at the end.
            if ($cur -eq $TenantId) { Write-Ok 'Azure CLI is already signed in to the right tenant' }
            else {
                Write-Todo 'Sign in in the browser window that opens (Azure CLI)...'
                $loginLines = [System.Collections.Generic.List[string]]::new()
                # The output is shown (the device code with -DeviceLogin must be visible) but also saved.
                if ($DeviceLogin) { az login --tenant $TenantId --use-device-code --allow-no-subscriptions --only-show-errors 2>&1 | ForEach-Object { $loginLines.Add("$_"); $_ } | Out-Host }
                else              { az login --tenant $TenantId --allow-no-subscriptions --only-show-errors 2>&1 | ForEach-Object { $loginLines.Add("$_"); $_ } | Out-Host }
            }
            if ((az account show --query tenantId -o tsv 2>$null) -ne $TenantId) {
                Fail ('The Azure CLI sign-in to the right tenant did not complete.' + (Get-SignInHelp ($loginLines -join ' '))) 'Run the script again and sign in when the browser window opens (or use -DeviceLogin).'
            }
            # (Counted in PowerShell: parentheses in --query are mangled by az.cmd's quoting.)
            # Only active subscriptions are counted (inactive ones only give errors).
            $subCount = @(az account list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' }).Count
            Write-Ok "Azure CLI signed in ($subCount subscription(s) visible)"
            $azReady = $true
        }
        catch {
            $m = Get-ErrorText $_
            Write-Warn2 $m
            foreach ($tool in 'azqr', 'Defender and cost', 'Structure') { Set-Status $tool 'Failed' "Azure CLI sign-in is missing: $m" }
            $SkipAzqr = $true; $SkipPortal = $true
        }
        if ($azReady -and $subCount -lt 1) {
            Write-Warn2 'The account sees no subscription in the tenant, so azqr and Defender/cost cannot be run. Assign the Reader role (see the README).'
            foreach ($tool in 'azqr', 'Defender and cost') { Set-Status $tool 'Failed' 'The account has no access to any subscription in the tenant. Assign the Reader role (see the README).' }
            $SkipAzqr = $true; $SkipPortal = $true
        }

        # Role check: does the account have the roles that the chosen tools need? If something is missing it shows how to add them,
        # and you choose whether to stop (default) or continue anyway.
        if ($azReady) {
            Write-Action 'Checking the roles of the account'
            $roleChecks = @(Get-RoleChecks -Tenant $TenantId -NeedGovViz (-not $SkipGovViz) -NeedPortal (-not $SkipPortal) -NeedMaester (-not $SkipMaester))
            foreach ($c in $roleChecks) { Write-Check $c.State $c.Role $c.Detail }
            $missingRoles = @($roleChecks | Where-Object { $_.State -eq 'MISSING' })
            if ($missingRoles.Count) {
                Write-Host ''
                Write-Line 'ACTION' 'Yellow' 'This is how you add the roles that are missing (done by a Global Administrator):' 'Yellow'
                foreach ($line in (Get-RoleInstructions $missingRoles)) { Write-Host "             $line" -ForegroundColor White; Write-Log 'ACTION' $line }
                Write-Host ''
                if (-not (Confirm-Continue "$($missingRoles.Count) role(s) are missing. Continue anyway (parts of the run may fail)?")) {
                    Fail 'Aborted: required roles are missing.' 'Add the roles as described above (sign out and in afterwards) and run the script again.'
                }
            }
            else { Write-Ok 'The roles look right' }
        }

        # ===================================================================
        # STEP 4: Dependencies. Every tool is fetched on its own; if one fails just that
        # tool is turned off (status "Failed") and the others continue.
        # ===================================================================
        Write-Step 4 'Fetching and installing dependencies' 'Only what is missing on this computer. The first time it takes 5-10 minutes.'
        if ($NoInstall) { Write-Warn2 '-NoInstall: skipping all fetching and installation.' }
        if ($LatestTools) { Write-Warn2 '-LatestTools: the latest versions are used and checksums are skipped. The result is not tested with these.' }
        else { Write-Action ("Tested versions: azqr {0}, Governance Visualizer {1}, Maester {2}, Pester {3}, Az.Accounts {4}" -f $Pins.Azqr, $GvVersion, $Pins.Maester, $Pins.Pester, $Pins.AzAccounts) }

        # (Azure CLI was already installed in step 3.)

        # azqr: first winget (fixed version; winget itself checks the installer file's hash), otherwise the same version is fetched
        # as a zip directly from GitHub and checked against the tested checksum. The zip unpacks azqr.exe in a
        # subfolder (bin\windows_amd64), so we look for it there.
        if (-not $SkipAzqr) {
            try {
                $azqrDir = Join-Path $env:LOCALAPPDATA 'azqr'
                $azqrExe = Get-ChildItem $azqrDir -Recurse -Filter 'azqr.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($azqrExe -and $env:Path -notlike "*$($azqrExe.DirectoryName)*") { $env:Path += ";$($azqrExe.DirectoryName)" }
                if (Test-Cmd azqr) { Write-Ok 'azqr already exists' }
                elseif ($NoInstall) { Fail 'azqr is missing (-NoInstall is set).' 'Install azqr (winget install azqr) and run again.' }
                else {
                    try { Install-WithWinget 'azqr' 'Microsoft.Azure.QuickReview' 'azqr' 'https://github.com/Azure/azqr/releases' $Pins.Azqr }
                    catch {
                        Write-Warn2 "winget gave no result ($($_.Exception.Message)). Fetching azqr directly from GitHub."
                        $zip = Join-Path $env:TEMP 'azqr.zip'
                        if (Test-Path "$ToolsDir\azqr.zip") { Copy-Item "$ToolsDir\azqr.zip" $zip -Force }
                        else {
                            $azqrUrl = $AzqrZipUrl
                            if ($LatestTools) {
                                $rel = Invoke-RestMethod 'https://api.github.com/repos/Azure/azqr/releases/latest' -Headers @{ 'User-Agent' = 'azure-rapportkit' }
                                $asset = $rel.assets | Where-Object name -like 'azqr-win-amd64.zip' | Select-Object -First 1
                                if (-not $asset) { Fail 'Found no Windows zip in the latest azqr release.' 'Fetch azqr manually from https://github.com/Azure/azqr/releases and run again.' }
                                $azqrUrl = $asset.browser_download_url
                            }
                            Get-Download $azqrUrl $zip 1MB
                        }
                        Assert-FileHash $zip $Pins.AzqrSha256 'azqr'
                        if (-not (Test-Zip $zip '*azqr.exe')) { Fail 'The downloaded azqr file is damaged or does not contain azqr.exe.' 'Run the script again to fetch it again.' }
                        Expand-Archive $zip $azqrDir -Force
                        $azqrExe = Get-ChildItem $azqrDir -Recurse -Filter 'azqr.exe' | Select-Object -First 1
                        if (-not $azqrExe) { Fail 'azqr was unpacked but azqr.exe was not found.' "Check the folder $azqrDir, or install azqr manually, and run again." }
                        $env:Path += ";$($azqrExe.DirectoryName)"
                        if (-not (Test-Cmd azqr)) { Fail 'azqr was unpacked but the command cannot be found.' "Check that $($azqrExe.FullName) can be started, or install azqr manually, and run again." }
                        Write-Ok "azqr fetched to $($azqrExe.DirectoryName)"
                    }
                }
            }
            catch { Set-Status 'azqr' 'Failed' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipAzqr = $true }
        }
        # Azure Governance Visualizer: a PowerShell script in a GitHub repo. We fetch a fixed version
        # as a zip (does not require git), check the zip and that the main script exists after unpacking.
        if (-not $SkipGovViz) {
            try {
                $gvMain = Join-Path $GvDir 'pwsh\AzGovVizParallel.ps1'
                if (Test-Path $gvMain) { Write-Ok "Governance Visualizer $GvVersion already exists" }
                elseif ($NoInstall) { Fail 'Governance Visualizer is missing (-NoInstall is set).' 'Run again without -NoInstall.' }
                else {
                    $zip = Join-Path $env:TEMP "azgovviz-$GvVersion.zip"
                    if (Test-Path "$ToolsDir\AzGovViz.zip") { Copy-Item "$ToolsDir\AzGovViz.zip" $zip -Force }
                    else { Get-Download $GvUrl $zip 100KB }
                    Assert-FileHash $zip $Pins.GovVizSha256 'Governance Visualizer'
                    if (-not (Test-Zip $zip '*pwsh/AzGovVizParallel.ps1')) { Fail 'The downloaded Governance Visualizer file is damaged or incomplete.' 'Run the script again to fetch it again.' }
                    $tmp = Join-Path $OutputRoot '_gv_tmp'
                    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
                    Expand-Archive $zip $tmp -Force
                    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
                    if (Test-Path $GvDir) { Remove-Item $GvDir -Recurse -Force }
                    Move-Item $inner.FullName $GvDir
                    Remove-Item $tmp -Recurse -Force
                    if (-not (Test-Path $gvMain)) { Fail "Governance Visualizer was unpacked but $gvMain is missing." 'Delete the folder and run the script again.' }
                    Write-Ok "Governance Visualizer $GvVersion fetched to $GvDir"
                }
                # Az.Accounts = sign-in for Az PowerShell. AzAPICall = helper module that AzGovViz requires (exact version).
                Install-PsModule 'Az.Accounts' -Pin $Pins.AzAccounts -MinVersion $Pins.AzAccounts
                Install-PsModule 'AzAPICall' -Pin $Pins.AzApiCall -MinVersion '1.2.4'
            }
            catch { Set-Status 'Governance Visualizer' 'Failed' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipGovViz = $true }
        }

        # Maester + Pester (the test framework Maester is built on).
        if (-not $SkipMaester) {
            try {
                if ($NoInstall -and -not (Get-Module -ListAvailable -Name Maester)) { Fail 'Maester is missing (-NoInstall is set).' 'Run again without -NoInstall.' }
                # Maester requires Pester 5.5 or later. Pester 6 is kept out because Maester is tested against 5.x.
                Install-PsModule 'Pester' -Pin $Pins.Pester -MinVersion '5.5.0' -MaxVersion '6.0.0'
                Install-PsModule 'Maester' -Pin $Pins.Maester -MinVersion $Pins.Maester
            }
            catch { Set-Status 'Maester' 'Failed' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipMaester = $true }
        }

        # Is there anything left to run? Otherwise there is no point in continuing.
        if ($SkipGovViz -and $SkipAzqr -and $SkipMaester -and $SkipPortal) {
            Fail 'No tool could be prepared, so there is nothing to run.' 'See the errors above, fix them and run the script again.'
        }

        # ===================================================================
        # STEP 5: Sign-in. If a sign-in fails only the tools that need
        # it are turned off; the rest run.
        # ===================================================================
        Write-Step 5 'Sign-in' 'You sign in with an account that has read permissions (see the README). A browser window opens for each sign-in. If you do not have time: press Ctrl+C and run the script again.'

        # (The Azure CLI sign-in and the role check are already done in step 3.)

        # 5a. Az PowerShell (used by Governance Visualizer)
        if (-not $SkipGovViz) {
            try {
                Import-Module Az.Accounts -ErrorAction Stop
                $ctx = Get-AzContext -ErrorAction SilentlyContinue
                # An AccessToken session cannot be renewed, and Governance Visualizer needs that: sign in again.
                if ($ctx -and $ctx.Tenant.Id -eq $TenantId -and $ctx.Account.Type -ne 'AccessToken') { Write-Ok 'Az PowerShell is already signed in' }
                else {
                    Write-Todo 'Sign in again (Az PowerShell)...'
                    $azPsByUs = $true
                    if ($DeviceLogin) { Connect-AzAccount -TenantId $TenantId -UseDeviceAuthentication | Out-Null }
                    else              { Connect-AzAccount -TenantId $TenantId | Out-Null }
                }
                $ctx = Get-AzContext
                if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId) { Fail 'The Az PowerShell sign-in to the right tenant did not complete.' 'Run the script again and sign in when the browser window opens (or use -DeviceLogin).' }
                Write-Ok 'Az PowerShell signed in'
            }
            catch { Set-Status 'Governance Visualizer' 'Failed' (Get-ErrorText $_); Write-Warn2 (Get-ErrorText $_); $SkipGovViz = $true }
        }

        # 3c. Microsoft Graph for Maester (optional; requires admin consent the first time)
        if (-not $SkipMaester) {
            Write-Host '  Maester reads Entra ID via Microsoft Graph. The first time a Global Administrator must approve the permissions.'
            try { $ans = Read-Host '  Sign in to Microsoft Graph for Maester now? (y/N)' } catch { $ans = 'n' }
            if ($ans -notmatch '^[jJyY]') { $SkipMaester = $true; Set-Status 'Maester' 'Skipped' 'Opted out at the sign-in question. Run again and answer y, or use -SkipMaester.' }
            else {
                try { Connect-Maester -TenantId $TenantId | Out-Null; $graphByUs = $true; Write-Ok 'Microsoft Graph signed in' }
                catch {
                    $SkipMaester = $true
                    Set-Status 'Maester' 'Failed' ("Graph sign-in failed: $($_.Exception.Message) A Global Administrator needs to give admin consent for 'Microsoft Graph Command Line Tools'. Then run the script again." + (Get-SignInHelp $_.Exception.Message))
                    Write-Warn2 $Status['Maester'].Note
                }
            }
        }

        # 4d. Permission check: can the account see the management group that Governance Visualizer starts at?
        # If an error is expected you can choose to run anyway or skip the tool.
        if (-not $SkipGovViz) {
            $mgCheck = if ($ManagementGroupId) { $ManagementGroupId } else { $TenantId }
            Write-Action "Checking that the account can read the management group '$mgCheck'"
            $code = $null
            try { $code = (Invoke-AzRestMethod -Method GET -Path "/providers/Microsoft.Management/managementGroups/${mgCheck}?api-version=2021-04-01").StatusCode } catch { }
            if ($code -eq 200) { Write-Ok "The management group '$mgCheck' is readable" }
            else {
                Write-Warn2 "The account cannot read the management group '$mgCheck' (response: $code). Governance Visualizer will probably fail. Reader is needed at tenant root (see the README). If you have elevated access (User Access Administrator) but not yet assigned Reader: do that, or give another group with -ManagementGroupId."
                if (-not (Confirm-Continue 'Run Governance Visualizer anyway?')) {
                    $SkipGovViz = $true
                    Set-Status 'Governance Visualizer' 'Skipped' "Opted out after the permission check: Reader is missing on the management group '$mgCheck'."
                }
            }
        }

        if ($SkipGovViz -and $SkipAzqr -and $SkipMaester -and $SkipPortal) {
            Fail 'No tool is left to run: all are opted out or lack sign-in/permission.' 'See the messages above, fix them (sign in, get the right role) and run the script again. The installation is already done, so it is quick.'
        }

        # ===================================================================
        # STEP 6: Azure Governance Visualizer
        # ===================================================================
        Write-Step 6 'Azure Governance Visualizer' 'Goes through management groups, subscriptions, policies and roles. 10-45 min in large environments, a few minutes in small ones. A lot of text in the window is normal.'
        if ($SkipGovViz) { Write-Action 'Skipped'; Set-SkippedUnlessFailed 'Governance Visualizer' }
        else {
            try {
                $gvScript = Join-Path $GvDir 'pwsh\AzGovVizParallel.ps1'
                # AzGovViz checks its modules with Get-InstalledModule and asks a y/n question if they are
                # missing. That does not work without admin and hangs without a keyboard, so we skip
                # the check for modules that already exist in our module folder (patch of the fetched copy).
                $src = Get-Content $gvScript -Raw
                if ($src -notmatch 'RAPPORTKIT-PATCH') {
                    $marker = '$moduleVersion = $module.ModuleVersion'
                    $patched = $src.Replace($marker, "if (Get-Module -ListAvailable -Name `$module.ModuleName) { Write-Host '  (rapportkit) module exists, skipping verification'; continue } # RAPPORTKIT-PATCH`n        $marker")
                    if ($patched -eq $src) { Add-Warning 'Could not patch the module check in Governance Visualizer (the tool may ask y/n).' }
                    else { Set-Content $gvScript $patched -Encoding utf8 }
                }
                # The tool pauses and waits for a key press at three advisory messages (a newer version exists,
                # PIM tip, "least privilege" recommendation). None of them is an error, and they stop the run, so we
                # comment out every "Pause" in the fetched copy.
                if ($src -notmatch 'RAPPORTKIT-NOPAUSE') {
                    $src2 = Get-Content $gvScript -Raw
                    $noPause = [regex]::Replace($src2, '(?m)^(\s*)Pause\s*$', '$1# Pause (borttagen av rapportkit) RAPPORTKIT-NOPAUSE')
                    if ($noPause -eq $src2) { Add-Warning 'Found no pauses to remove in Governance Visualizer (the tool may wait for a key press).' }
                    else { Set-Content $gvScript $noPause -Encoding utf8 }
                }
                # Classic administrators (classic subscription administrators) is retired in Azure, and the API answers
                # 404 "InvalidResourceType" on for example MSDN subscriptions. The tool is set to STOP on that
                # error, so we skip just that call: the function gets the same response as when the listing failed.
                if ($src -notmatch 'RAPPORTKIT-NOCLASSIC') {
                    $src3 = Get-Content $gvScript -Raw
                    $noClassic = [regex]::Replace($src3, '(?s)(function dataCollectionClassicAdministratorsSub \{.*?)\$AzApiCallResult = AzAPICall @azAPICallPayload', "`$1`$AzApiCallResult = 'ClassicAdministratorListFailed' # RAPPORTKIT-NOCLASSIC (API pensionerat)")
                    if ($noClassic -eq $src3) { Add-Warning 'Could not skip classic administrators in Governance Visualizer (may stop on older subscription types).' }
                    else { Set-Content $gvScript $noClassic -Encoding utf8 }
                }
                $mg = if ($ManagementGroupId) { $ManagementGroupId } else { $TenantId }
                Write-Action "Running AzGovVizParallel.ps1 against the management group '$mg'"
                $gvArgs = @{ ManagementGroupId = $mg; OutputPath = $Dirs.azgovviz }
                # The version check of Azure Landing Zones policies clones a GitHub repo with git (which does not always exist)
                # and is not needed for the report.
                $gvArgs.NoALZPolicyVersionChecker = $true
                # PIM eligibility reporting requires a service account and cannot be run as an ordinary user.
                # Without the flag the tool pauses and waits for a key press, so we turn it off right away.
                $gvArgs.NoPIMEligibility = $true
                # -HidePersonalData: the tool hides names and e-mail addresses in the role assignments in its report.
                if ($HidePersonalData) { $gvArgs.DoNotShowRoleAssignmentsUserData = $true; Write-Action 'User data is hidden in the Governance Visualizer report (-HidePersonalData).' }
                # The output is also saved in $gvLines so that the real cause can be picked out on failure.
                $gvLines = [System.Collections.Generic.List[string]]::new()
                & $gvScript @gvArgs *>&1 | ForEach-Object { $gvLines.Add("$_"); $_ } | Out-Host
                # Verify: the tool can finish without errors but without a result.
                $gvHtmlOut = Get-ChildItem $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue | Where-Object Length -gt 10KB | Select-Object -First 1
                if (-not $gvHtmlOut) { throw "The run finished but no report (AzGovViz*.html) was found in $($Dirs.azgovviz)." }
                Set-Status 'Governance Visualizer' 'OK'
                Write-Ok 'Governance Visualizer done'
            }
            catch {
                $msg = $_.Exception.Message
                # Save the tool's whole output and pick out the lines that explain the error. The patterns are
                # case sensitive (-cmatch) so that for example the parameter "PSRuleFailedOnly" is not counted as an error.
                $consoleFile = Join-Path $Dirs.azgovviz 'azgovviz-console.txt'
                try { $gvLines | Set-Content $consoleFile -Encoding utf8 } catch { }
                $reason = @($gvLines | ForEach-Object { "$_".Trim() } |
                    Where-Object { $_ -cmatch '(^|[\s\[])(ERROR|Error)\b|check FAILED|AuthorizationFailed|not authorized|Forbidden|Exception' } |
                    Select-Object -Last 3) -join ' | '
                # The heading "Permission check results" is written even when the check passes, so the error is recognised from
                # the line "check FAILED" (the account cannot read the management group).
                $permFail = [bool]($gvLines | Where-Object { $_ -clike '*check FAILED*' })
                if ($reason) { $msg = "$reason ($msg)" }
                # Permission error: give the usual explanation. Otherwise: refer to the output.
                $hint = if ($permFail -or $msg -cmatch 'check FAILED|AuthorizationFailed|not authorized|Forbidden') {
                            ' Action: the account cannot read the management group. Assign Reader at tenant root (see "Give yourself read access" in the README and check that the role is on the Tenant Root Group), or give another group with -ManagementGroupId.' }
                        else { " The whole output is in $consoleFile." }
                # Could the report have been created before the error? Then the result is partly usable.
                $partial = Get-ChildItem $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue | Where-Object Length -gt 10KB | Select-Object -First 1
                if ($partial) {
                    Write-Warn2 "Governance Visualizer reported errors but created a report: $msg"
                    Set-Status 'Governance Visualizer' 'Partial' ("The report was created but the tool ended with errors, so it may be missing parts. $msg$hint")
                }
                else {
                    Write-Warn2 $msg
                    Set-Status 'Governance Visualizer' 'Failed' ($msg + $hint)
                }
            }
        }

        # ===================================================================
        # STEP 7: azqr
        # ===================================================================
        Write-Step 7 'Azure Quick Review (azqr)' 'Scans all subscriptions you have read access to. 1-30 min.'
        if ($SkipAzqr) { Write-Action 'Skipped'; Set-SkippedUnlessFailed 'azqr' }
        else {
            try {
                Push-Location $Dirs.azqr
                # Clear old results for the same period so that we do not read mixed runs.
                Get-ChildItem $Dirs.azqr -Filter "azqr_$Period*" -ErrorAction SilentlyContinue | Remove-Item -Force
                # Can azqr be started at all? Antivirus/EDR/AppLocker can block downloaded exe files without a clear error.
                & azqr --help *> $null
                if ($LASTEXITCODE -ne 0) { throw "azqr cannot be run (exit code $LASTEXITCODE). Is it blocked by antivirus/EDR/AppLocker? Ask IT to allow azqr.exe and run again." }
                # --mask=false: azqr masks subscription IDs by default (xxxxxxxx-...-93b8382), which makes its findings impossible to match with the other sources
                # (the other tools write the real IDs anyway) and unreliable as keys when runs are compared. Only passed if this azqr has the option.
                $azqrArgs = @('--json', '--csv', '--xlsx')
                if ((& azqr scan --help 2>&1 | Out-String) -match '--mask') { $azqrArgs = @('--mask=false') + $azqrArgs }
                else { Add-Warning 'This azqr has no --mask option, so subscription IDs in the azqr files may be masked.' }
                Write-Action "Running: azqr scan $($azqrArgs -join ' ')"
                # --json/--csv let us read the result in the HTML report; --xlsx is the full report.
                azqr scan @azqrArgs -o "azqr_$Period" 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "azqr ended with code $LASTEXITCODE." }
                # Verify that the result files exist and are not empty.
                $xlsxOut = Get-ChildItem $Dirs.azqr -Filter '*.xlsx' | Where-Object Length -gt 0 | Select-Object -First 1
                $invOut = Get-ChildItem $Dirs.azqr -Filter '*.inventory.csv' | Where-Object Length -gt 0 | Select-Object -First 1
                if (-not $xlsxOut -or -not $invOut) { throw 'azqr finished but the result files (Excel/CSV) are missing or empty. Check that the account has Reader on at least one subscription.' }
                Set-Status 'azqr' 'OK'
                Write-Ok 'azqr done'
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'azqr' 'Failed' $_.Exception.Message }
            finally { Pop-Location }
        }

        # ===================================================================
        # STEP 8: Maester
        # ===================================================================
        Write-Step 8 'Maester (Entra ID tests)' 'Optional. 10-20 min.'
        if ($SkipMaester) { Write-Action 'Skipped'; Set-SkippedUnlessFailed 'Maester' }
        else {
            try {
                Push-Location $Dirs.maester
                Import-Module Maester -ErrorAction Stop
                $testsDir = Join-Path $Dirs.maester 'maester-tests'
                # -Path is given explicitly: without it the tests end up in the process's working folder (for example C:\Windows\System32 when run as admin).
                if (-not (Test-Path $testsDir)) { Write-Action 'Fetching Maester''s test suite (Install-MaesterTests)'; Install-MaesterTests -Path $testsDir }
                if (-not (Test-Path $testsDir)) { throw 'Maester''s test suite was not fetched (the folder maester-tests is missing). Check the internet connection and run again.' }
                Write-Action 'Running Invoke-Maester'
                $mtOut = Join-Path $Dirs.maester 'test-results'
                $mtJson = Join-Path $mtOut 'maester.json'
                New-Item -ItemType Directory -Force $mtOut | Out-Null      # the folder must exist before Maester writes there
                $res = Invoke-Maester -Path $testsDir -OutputFolder $mtOut -OutputJsonFile $mtJson -NonInteractive -PassThru | Select-Object -Last 1
                if (-not (Test-Path $mtJson)) {
                    # Maester wrote no JSON file. If there is a result object we write a summary of our own from it.
                    if ($res -and (@($res.PSObject.Properties.Name) -contains 'PassedCount')) {
                        Add-Warning 'Maester wrote no maester.json (may be due to blocked writing, see the README). Summarising from the result object instead.'
                        [pscustomobject]@{
                            PassedCount = $res.PassedCount; FailedCount = $res.FailedCount; SkippedCount = $res.SkippedCount
                            Tests = @($res.Tests | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Result = $_.Result } })
                        } | ConvertTo-Json -Depth 4 | Set-Content $mtJson -Encoding utf8
                    }
                    else {
                        $found = (Get-ChildItem $Dirs.maester -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { $_.FullName.Substring($Dirs.maester.Length + 1) }) -join ', '
                        if (-not $found) { $found = '(none)' }
                        throw "Maester finished but maester.json is missing. Files in the maester folder: $found. Is Windows Defender (Controlled folder access) blocking writing? See troubleshooting in the README."
                    }
                }
                Set-Status 'Maester' 'OK'
                Write-Ok 'Maester done'
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'Maester' 'Failed' $_.Exception.Message }
            finally { Pop-Location }
        }

        # ===================================================================
        # STEP 9: Defender and cost. Fetches what is otherwise exported manually from the portal: Defender plans,
        # Secure Score, Defender recommendations and cost for 12 months. Everything is read-only and goes via
        # Azure Resource Manager (az rest), so no extensions are needed. Every source is caught on its own.
        # ===================================================================
        Write-Step 9 'Defender, cost and structure' 'Fetches Defender plans, Secure Score, Defender recommendations, cost for 12 months and management groups and networks (VNets and peerings) directly from Azure (read-only) and saves them as CSV in portal\ and struktur\. 1-5 min.'
        if ($SkipPortal) { Write-Action 'Skipped'; Set-SkippedUnlessFailed 'Defender and cost'; Set-SkippedUnlessFailed 'Structure' }
        else {
            $portalErrors = [System.Collections.Generic.List[string]]::new()
            $portalOk = 0
            $srcFail = @{ plans = 0; secureScore = 0; secureScoreControls = 0; recommendations = 0; cost = 0 }   # failed subscriptions per source (for run-summary.json)
            try {
                $subs = @(az account list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' } | Sort-Object name)
                if ($subs.Count -gt $MaxPortalSubscriptions) {
                    Add-Warning "The account sees $($subs.Count) active subscriptions. Defender and cost are fetched only for the first $MaxPortalSubscriptions (alphabetically): change with -MaxPortalSubscriptions."
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
                    Write-Action "Subscription $subNo/$($subs.Count): $sname"

                    # Defender plans (on/off per service)
                    try {
                        $r = Invoke-ArmRest 'GET' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/pricings?api-version=2024-01-01"
                        foreach ($p in @($r.value)) { $planRows.Add([pscustomobject]@{ PrenumerationId = $sid; Prenumeration = $sname; Plan = $p.name; Niva = $p.properties.pricingTier; Delplan = $p.properties.subPlan }) }
                        $portalOk++
                    }
                    catch { $srcFail.plans++; $portalErrors.Add("Defender plans ($sname): $($_.Exception.Message)") }

                    # Secure Score
                    try {
                        $r = Invoke-ArmRest 'GET' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/secureScores?api-version=2020-01-01"
                        foreach ($sc in @($r.value)) { $scoreRows.Add([pscustomobject]@{ PrenumerationId = $sid; Prenumeration = $sname; Poang = $sc.properties.score.current; Max = $sc.properties.score.max; Andel = $sc.properties.score.percentage }) }
                        $portalOk++
                    }
                    catch { $srcFail.secureScore++; $portalErrors.Add("Secure Score ($sname): $($_.Exception.Message)") }

                    # Secure Score per control (score, number of unhealthy/healthy resources). Needed because Azure's list of
                    # individual recommendations can be incomplete: the controls show how many resources are unhealthy.
                    try {
                        $r = Invoke-ArmRest 'GET' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/secureScoreControls?api-version=2020-01-01"
                        foreach ($c in @($r.value)) { $ctrlRows.Add([pscustomobject]@{ PrenumerationId = $sid; Prenumeration = $sname; KontrollId = $c.name; Kontroll = $c.properties.displayName; Poang = $c.properties.score.current; Max = $c.properties.score.max; Osunda = [int]$c.properties.unhealthyResourceCount; Friska = [int]$c.properties.healthyResourceCount }) }
                        $portalOk++
                    }
                    catch { $srcFail.secureScoreControls++; $portalErrors.Add("Secure Score controls ($sname): $($_.Exception.Message)") }

                    # Defender recommendations (paged; at most 30 pages, and we stop if nextLink repeats)
                    try {
                        $url = "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Security/assessments?api-version=2021-06-01&`$expand=metadata"
                        $pages = 0; $seen = @{}; $seenIds = @{}
                        while ($url -and $pages -lt 30 -and -not $seen.ContainsKey($url)) {
                            $seen[$url] = $true; $pages++
                            $r = Invoke-ArmRest 'GET' $url
                            foreach ($a in @($r.value)) {
                                # Defender can return the same page again via a nextLink that points at itself: skip duplicates.
                                if ($a.id -and $seenIds.ContainsKey($a.id)) { continue }
                                if ($a.id) { $seenIds[$a.id] = $true }
                                $recRows.Add([pscustomobject]@{ PrenumerationId = $sid; Prenumeration = $sname; Nyckel = $a.name; Rekommendation = $a.properties.displayName; Status = $a.properties.status.code; Allvarlighet = $a.properties.metadata.severity; Resurs = $a.properties.resourceDetails.Id })
                            }
                            $url = $r.nextLink
                        }
                        $portalOk++
                    }
                    catch { $srcFail.recommendations++; $portalErrors.Add("Defender recommendations ($sname): $($_.Exception.Message)") }

                    # Cost per month, the last 12 months (Cost Management allows at most one year)
                    try {
                        $from = (Get-Date).AddDays(-364).ToString('yyyy-MM-dd'); $to = (Get-Date).ToString('yyyy-MM-dd')
                        $costBody = @{ type = 'ActualCost'; timeframe = 'Custom'; timePeriod = @{ from = "${from}T00:00:00+00:00"; to = "${to}T23:59:59+00:00" }
                                       dataset = @{ granularity = 'Monthly'; aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } } }
                        $r = Invoke-ArmRest 'POST' "https://management.azure.com/subscriptions/$sid/providers/Microsoft.CostManagement/query?api-version=2023-03-01" $costBody
                        $cols = @($r.properties.columns | ForEach-Object { $_.name })
                        $iCost = [array]::IndexOf($cols, 'Cost'); $iCur = [array]::IndexOf($cols, 'Currency')
                        $iMonth = [array]::IndexOf($cols, 'BillingMonth'); if ($iMonth -lt 0) { $iMonth = [array]::IndexOf($cols, 'UsageDate') }
                        if ($iCost -lt 0 -or $iMonth -lt 0) { throw "unexpected columns in the cost response: $($cols -join ', ')" }
                        foreach ($row in @($r.properties.rows)) {
                            # ConvertFrom-Json turns ISO dates into DateTime, so format them independently of the language setting.
                            $mv = $row[$iMonth]
                            $ms = if ($mv -is [datetime]) { $mv.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$mv }
                            $month = if ($ms -match '^\d{8}$') { $ms.Substring(0, 4) + '-' + $ms.Substring(4, 2) } else { $ms.Substring(0, [Math]::Min(7, $ms.Length)) }
                            $costRows.Add([pscustomobject]@{ PrenumerationId = $sid; Prenumeration = $sname; Manad = $month; Kostnad = [math]::Round([double]$row[$iCost], 2); Valuta = $(if ($iCur -ge 0) { $row[$iCur] } else { '' }) })
                        }
                        $portalOk++
                    }
                    catch { $srcFail.cost++; $portalErrors.Add("Cost ($sname): $($_.Exception.Message)") }
                }

                # Save as CSV (UTF-8 with BOM so that Excel shows å/ä/ö correctly)
                $save = @(@('defender-planer.csv', $planRows), @('secure-score.csv', $scoreRows), @('secure-score-kontroller.csv', $ctrlRows), @('defender-rekommendationer.csv', $recRows), @('kostnad.csv', $costRows))
                foreach ($sv in $save) {
                    if ($sv[1].Count) { $sv[1] | Export-Csv -Path (Join-Path $Dirs.portal $sv[0]) -NoTypeInformation -Encoding utf8BOM; Write-Ok "$($sv[0]): $($sv[1].Count) rows" }
                }
                # Does the recommendation list match the controls? Otherwise Azure's list (a quirk of the API) has lost unhealthy resources.
                $ctrlUnhealthy = [int](($ctrlRows | Measure-Object -Property Osunda -Sum).Sum)
                $recUnhealthy = @($recRows | Where-Object { $_.Status -eq 'Unhealthy' }).Count
                if ($ctrlUnhealthy -gt $recUnhealthy) { Add-Warning "The Secure Score controls show $ctrlUnhealthy unhealthy resources, but the recommendation list contains only $recUnhealthy. Azure's list is probably incomplete; use the table Secure Score per control." }
                # State per source, for run-summary.json: a source that failed for every subscription is Failed, for some Partial.
                # The recommendation list is also Partial when it holds fewer unhealthy resources than the controls report.
                $script:PortalSources = [ordered]@{}
                foreach ($k in 'plans', 'secureScore', 'secureScoreControls', 'recommendations', 'cost') {
                    $st = if ($srcFail[$k] -eq 0) { 'OK' } elseif ($srcFail[$k] -ge $subs.Count) { 'Failed' } else { 'Partial' }
                    $note = if ($srcFail[$k]) { "$($srcFail[$k]) of $($subs.Count) subscriptions failed" } else { '' }
                    if ($k -eq 'recommendations' -and $ctrlUnhealthy -gt $recUnhealthy) { if ($st -eq 'OK') { $st = 'Partial' }; $note = ($note + " The controls report $ctrlUnhealthy unhealthy resources, the list holds $recUnhealthy.").Trim() }
                    $script:PortalSources[$k] = [ordered]@{ state = $st; note = $note }
                }
                if ($portalErrors.Count -eq 0) { Set-Status 'Defender and cost' 'OK' "Saved in $($Dirs.portal)" }
                else {
                    foreach ($e in $portalErrors) { Write-Warn2 $e }
                    $hint = if ($portalErrors -match 'AuthorizationFailed|Forbidden|does not have authorization|403') { ' Common cause: a role is missing (Reader, Security Reader or Cost Management Reader), see the README.' } else { '' }
                    Set-Status 'Defender and cost' $(if ($portalOk -gt 0) { 'Partial' } else { 'Failed' }) (($portalErrors -join ' | ') + $hint)
                }
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'Defender and cost' 'Failed' $_.Exception.Message }

            # Structure: management groups, virtual networks and peerings, network nodes (lib\Structure.ps1). Read-only.
            Write-Action 'Fetching structure: management groups and networks'
            try {
                . (Join-Path $ScriptRoot 'lib\Structure.ps1')
                $structErrors = [System.Collections.Generic.List[string]]::new()
                $subIds = @(az account list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.state -eq 'Enabled' } | ForEach-Object { $_.id })
                $rootMg = if ($ManagementGroupId) { $ManagementGroupId } else { $TenantId }
                $summary = Save-StructureData $Dirs.struktur $rootMg $subIds $structErrors
                if ($structErrors.Count -eq 0) { Set-Status 'Structure' 'OK' $summary }
                else {
                    foreach ($e in $structErrors) { Write-Warn2 $e }
                    Set-Status 'Structure' $(if ($summary) { 'Partial' } else { 'Failed' }) ($structErrors -join ' | ')
                }
            }
            catch { Write-Warn2 $_.Exception.Message; Set-Status 'Structure' 'Failed' $_.Exception.Message }
        }
    }

    # =======================================================================
    # STEP 10: HTML report. Every section is built on its own; if a section cannot be built
    # it becomes a warning in the report, not an abort.
    # =======================================================================
    Write-Step 10 'Building the report' 'Reads the results of the tools and writes a multi-page report in a common style. The look is set by the files in the folder branding\ (see branding\README.md).'
    # The report generator is in lib\Report.ps1: it reads the results and builds the pages with the chosen theme.
    $reportLib = Join-Path $ScriptRoot 'lib\Report.ps1'
    if (-not (Test-Path -LiteralPath $reportLib)) { Fail 'lib\Report.ps1 is missing next to the script, so the report cannot be built.' 'Use the whole kit (the whole zip file, unpacked), not just Run-Rapportkit.ps1.' }
    . $reportLib
    $reportPath = Write-ReportSite
    Write-Ok "Report: $reportPath"
    # =======================================================================
    # Finish: run summary, zip for delivery, summary box, sign-out and cleanup.
    # =======================================================================
    Complete-Step
    $anyFail = @($Status.Values | Where-Object { $_.State -eq 'Failed' }).Count -gt 0
    if ($anyFail) { $ExitCode = 2 }
    Write-RunSummary $ExitCode

    # Zip of the result folder for delivery, with SHA256 so that the recipient can check that the file arrived unchanged.
    # The console log (rapportkit-console.log) is not included: it is a troubleshooting log and is locked while the script runs.
    $zipPath = $null; $zipHash = $null
    if (-not $NoZip) {
        try {
            $zipPath = Join-Path $OutputRoot ('rapportkit_{0}_{1}.zip' -f $TenantId.Substring(0, 8), $Period)
            if ($ZipPassword) { $zipPath += '.rkenc' }
            if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
            if ($ZipPassword) {
                # The zip is created temporarily, encrypted, checked by decrypting it again, and then removed.
                $plainZip = Join-Path ([System.IO.Path]::GetTempPath()) ('rapportkit-' + [guid]::NewGuid().ToString('N') + '.zip')
                $checkZip = "$plainZip.check"
                try {
                    Get-ChildItem -Path $RunDir -Force | Where-Object { $_.Name -ne 'rapportkit-console.log' } | Compress-Archive -DestinationPath $plainZip -Force
                    Write-Action 'Encrypting the zip file (AES-256)'
                    Protect-RapportkitFile -Path $plainZip -Destination $zipPath -Password $ZipPassword
                    Unprotect-RapportkitFile -Path $zipPath -Destination $checkZip -Password $ZipPassword
                    if ((Get-FileHash $checkZip -Algorithm SHA256).Hash -ne (Get-FileHash $plainZip -Algorithm SHA256).Hash) { throw 'The check of the encrypted file failed (the content does not match after decryption).' }
                }
                catch { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue; throw }
                finally { Remove-Item $plainZip, $checkZip -Force -ErrorAction SilentlyContinue }
            }
            else {
                Add-Warning 'The zip file is NOT encrypted (-NoEncrypt). Do not send it by e-mail.'
                Get-ChildItem -Path $RunDir -Force | Where-Object { $_.Name -ne 'rapportkit-console.log' } | Compress-Archive -DestinationPath $zipPath -Force
            }
            $zipHash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
            Set-Content -Path "$zipPath.sha256" -Value ('{0} *{1}' -f $zipHash, (Split-Path $zipPath -Leaf)) -Encoding ascii
            Write-Ok ('Zip created ({0:N1} MB), checksum saved in {1}.sha256' -f ((Get-Item $zipPath).Length / 1MB), (Split-Path $zipPath -Leaf))
        }
        catch { Add-Warning "Could not create the zip file: $($_.Exception.Message)"; $zipPath = $null }
    }

    $facts = [System.Collections.Generic.List[object]]::new()
    $facts.Add(@('Report', $reportPath))
    $facts.Add(@('Result folder', $RunDir))
    if ($Anonymize -and (Test-Path (Join-Path $RunDir 'anonym\rapport.html'))) { $facts.Add(@('Anonymized report', (Join-Path $RunDir 'anonym\rapport.html'))) }
    if ($zipPath) { $facts.Add(@($(if ($ZipPassword) { 'Encrypted zip' } else { 'Zip' }), $zipPath)); $facts.Add(@('SHA256', $zipHash)) }
    $facts.Add(@('Logs', 'rapportkit.log (cleaned), rapportkit-console.log (everything) and run-summary.json in the result folder'))
    $facts.Add(@('Total time', (Format-Duration ((Get-Date) - $script:RunStart).TotalSeconds)))
    if ($anyFail) { $facts.Add(@('Run again', (Get-RerunCommand))) }
    Write-SummaryBox $Status $facts
    if ($anyFail) { Write-Warn2 'A tool failed (see above). The report shows what went well. Fix the problem and run again with the command above.' }
    Write-Host ''
    Write-Action 'Next step: open the report and check the content. The result is confidential: leave it only in an agreed place.'
    if ($zipPath -and $ZipPassword) { Write-Action 'Send the encrypted file (.rkenc) and the .sha256 file, and give the recipient the password by another channel than the file. The folder with unencrypted results stays on the computer: delete it when the assignment is done.' }

    Invoke-SessionCleanup
    foreach ($tmpf in @((Join-Path $env:TEMP 'azqr.zip'), (Join-Path $env:TEMP "azgovviz-$GvVersion.zip"))) { Remove-Item $tmpf -Force -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $env:TEMP 'azrest-*.json') -Force -ErrorAction SilentlyContinue

    $Completed = $true
    Write-Log 'DONE' "The run is complete. Exit code $ExitCode"
    # RAPPORTKIT_NOOPEN is used in automated tests so that no browser is started.
    if (-not $env:RAPPORTKIT_NOOPEN) { try { Start-Process $reportPath } catch { } }
}
catch {
    # Interruption: write what happened, what to do and the exact command to run again.
    $ex = $_.Exception
    # Ctrl+C can arrive here as PipelineStoppedException: let the finally block write the interruption message.
    if ($ex -is [System.Management.Automation.PipelineStoppedException]) { exit 1 }
    $ExitCode = 1
    $AbortShown = $true
    Complete-Step
    Write-Host ''
    Write-Line 'ABORTED' 'Red' 'The run was aborted' 'Red'
    if ($ex.Data -and $ex.Data['Fix']) {
        Write-Log 'ERROR' ('Aborted: ' + $ex.Message)
        Write-Line 'CAUSE' 'Red' $ex.Message 'Red'
        Write-Line 'ACTION' 'Yellow' ([string]$ex.Data['Fix']) 'Yellow'
        Write-Log 'ACTION' ([string]$ex.Data['Fix'])
    }
    else {
        Write-Log 'ERROR' ('Unexpected error: {0} (line {1}: {2})' -f $ex.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
        Write-Line 'ERROR' 'Red' "Unexpected error: $($ex.Message)" 'Red'
        Write-Host ('             Location: line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
        Write-Line 'ACTION' 'Yellow' 'Send rapportkit.log (and rapportkit-console.log) from the result folder to whoever gave you the script.' 'Yellow'
    }
    Write-Line 'RERUN' 'Cyan' 'When it is fixed, run the script again (what is already installed is reused):' 'Gray'
    Write-Host "             $(Get-RerunCommand)" -ForegroundColor White
    Write-RunSummary 1
}
finally {
    # Always runs, also on Ctrl+C or a closed window: explain the interruption, clean up and close the log.
    if (-not $Completed -and -not $AbortShown) {
        Complete-Step
        Write-Host ''
        Write-Line 'ABORTED' 'Yellow' 'The run was aborted (Ctrl+C or closed window). Nothing has been changed in Azure.' 'Yellow'
        Write-Log 'ERROR' 'Aborted by the user (Ctrl+C or closed window)'
        if ($TenantId) {
            Write-Line 'RERUN' 'Cyan' 'Run the script again; what is already installed is reused:' 'Gray'
            Write-Host "             $(Get-RerunCommand)" -ForegroundColor White
        }
        Write-RunSummary 1
    }
    if (-not $Completed -and ($azPsByUs -or $graphByUs -or ($azReady -and -not $azWasLoggedIn))) {
        Write-Host '  Note: sign-ins that the script created may remain. Sign out with: az logout   (and Disconnect-AzAccount and Disconnect-MgGraph)' -ForegroundColor DarkYellow
    }
    foreach ($tmpf in @((Join-Path $env:TEMP 'azqr.zip'), (Join-Path $env:TEMP "azgovviz-$GvVersion.zip"))) { Remove-Item $tmpf -Force -ErrorAction SilentlyContinue }
    if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
exit $ExitCode
