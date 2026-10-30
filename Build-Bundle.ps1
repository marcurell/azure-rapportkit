<#
.SYNOPSIS
  Laddar ner alla verktyg till tools\ och packar scriptet + verktygen i en zip som kan skickas till kunden.
  Kunden kör sedan: .\Run-Rapportkit.ps1 -Offline

.DESCRIPTION
  Versioner och kontrollsummor läses ur Run-Rapportkit.ps1 ($Pins), så att bundlen alltid innehåller exakt de
  testade versionerna. Nedladdade zip-filer kontrolleras mot kontrollsumman innan paketet byggs.

.PARAMETER Out
  Sökväg till zipfilen som skapas.
.PARAMETER SkipInstallers
  Hoppa över de stora installationsfilerna (PowerShell 7, Azure CLI, Git) om kunden redan har dem.
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot 'rapportkit-bundle.zip'),
    [switch]$SkipInstallers
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Läs pinnade versioner och kontrollsummor ur huvudscriptet (en enda källa)
$src = Get-Content (Join-Path $PSScriptRoot 'Run-Rapportkit.ps1') -Raw
function Get-Pin([string]$Pattern) {
    $m = [regex]::Match($src, $Pattern)
    if (-not $m.Success) { throw "Hittade inte '$Pattern' i Run-Rapportkit.ps1" }
    $m.Groups[1].Value
}
$GvVersion = Get-Pin "\`$GvVersion\s*=\s*'([0-9.]+)'"
$AzqrVersion = Get-Pin "Azqr\s*=\s*'([0-9.]+)'"
$AzqrSha = Get-Pin "AzqrSha256\s*=\s*'([0-9A-F]{64})'"
$GvSha = Get-Pin "GovVizSha256\s*=\s*'([0-9A-F]{64})'"
$modules = @(
    @{ N = 'Az.Accounts'; V = (Get-Pin "AzAccounts\s*=\s*'([0-9.]+)'") },
    @{ N = 'AzAPICall'; V = (Get-Pin "AzApiCall\s*=\s*'([0-9.]+)'") },
    @{ N = 'Pester'; V = (Get-Pin "Pester\s*=\s*'([0-9.]+)'") },
    @{ N = 'Maester'; V = (Get-Pin "Maester\s*=\s*'([0-9.]+)'") }
)

$tools = Join-Path $PSScriptRoot 'tools'
New-Item -ItemType Directory -Force "$tools\installers", "$tools\modules" | Out-Null
$h = @{ 'User-Agent' = 'azure-rapportkit' }

function Get-GhAsset($repo, $pattern) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers $h
    $a = $rel.assets | Where-Object name -like $pattern | Select-Object -First 1
    if (-not $a) { throw "Hittade ingen fil som matchar '$pattern' i senaste releasen av $repo." }
    $a
}

# Laddar ner med 3 försök och kontrollerar att filen inte är för liten.
function Get-File($url, $dest, [long]$minBytes = 1024) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Write-Host "  $url (försök $i/3)"
            Invoke-WebRequest $url -OutFile $dest -Headers $h -UseBasicParsing
            if ((Get-Item $dest).Length -lt $minBytes) { throw 'filen är för liten' }
            return
        }
        catch { Remove-Item $dest -Force -ErrorAction SilentlyContinue; if ($i -eq 3) { throw "Nedladdning misslyckades: $url ($($_.Exception.Message))" }; Start-Sleep (2 * $i) }
    }
}

# Kontrollerar att en zip är hel och innehåller en förväntad post.
function Assert-Zip($path, $mustContain) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($path)
    try { if (-not ($z.Entries | Where-Object { $_.FullName -like $mustContain })) { throw "$path saknar $mustContain" } }
    finally { $z.Dispose() }
}

# Kontrollerar SHA256 mot den testade kontrollsumman.
function Assert-Sha($path, $expected, $what) {
    $actual = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "${what}: kontrollsumman stämmer inte (väntade $expected, fick $actual). Uppströmsfilen kan ha ändrats: kontrollera och uppdatera `$Pins i Run-Rapportkit.ps1." }
    Write-Host "  ${what}: SHA256 stämmer"
}

Write-Host "azqr $AzqrVersion" -ForegroundColor Cyan
Get-File "https://github.com/Azure/azqr/releases/download/v.$AzqrVersion/azqr-win-amd64.zip" "$tools\azqr.zip" 1MB
Assert-Zip "$tools\azqr.zip" '*azqr.exe'
Assert-Sha "$tools\azqr.zip" $AzqrSha 'azqr'

Write-Host "Azure Governance Visualizer $GvVersion" -ForegroundColor Cyan
Get-File "https://github.com/Azure/Azure-Governance-Visualizer/archive/refs/tags/$GvVersion.zip" "$tools\AzGovViz.zip" 100KB
Assert-Zip "$tools\AzGovViz.zip" '*pwsh/AzGovVizParallel.ps1'
Assert-Sha "$tools\AzGovViz.zip" $GvSha 'Governance Visualizer'

Write-Host 'PowerShell-moduler (fasta versioner)' -ForegroundColor Cyan
foreach ($m in $modules) {
    $dest = Join-Path $tools "modules\$($m.N)"
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Write-Host "  $($m.N) $($m.V)"
    if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
        Save-PSResource -Name $m.N -Version $m.V -Path "$tools\modules" -TrustRepository -Quiet
    }
    else {
        Save-Module -Name $m.N -RequiredVersion $m.V -Path "$tools\modules" -Force
    }
    if (-not (Test-Path $dest)) { throw "Modulen $($m.N) hämtades inte till $dest" }
}
# Beroenden till modulerna hamnar som egna mappar i tools\modules och följer med i zippen.

if (-not $SkipInstallers) {
    Write-Host 'Installers' -ForegroundColor Cyan
    $a = Get-GhAsset 'PowerShell/PowerShell' 'PowerShell-*-win-x64.msi'
    Get-File $a.browser_download_url "$tools\installers\$($a.name)" 10MB
    $a = Get-GhAsset 'git-for-windows/git' 'Git-*-64-bit.exe'
    Get-File $a.browser_download_url "$tools\installers\$($a.name)" 10MB
    Get-File 'https://aka.ms/installazurecliwindowsx64' "$tools\installers\azure-cli-latest.msi" 10MB
}

Write-Host 'Packar zip' -ForegroundColor Cyan
if (Test-Path $Out) { Remove-Item $Out -Force }
$stage = Join-Path $env:TEMP 'rapportkit-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
foreach ($file in 'Run-Rapportkit.ps1', 'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md') { Copy-Item (Join-Path $PSScriptRoot $file) $stage }
New-Item -ItemType Directory "$stage\docs" | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'docs\KUNDINFO.md') "$stage\docs"
Copy-Item $tools "$stage\tools" -Recurse
Compress-Archive "$stage\*" $Out
Remove-Item $stage -Recurse -Force
Assert-Zip $Out '*Run-Rapportkit.ps1'
$bundleHash = (Get-FileHash $Out -Algorithm SHA256).Hash
Set-Content -Path "$Out.sha256" -Value ('{0} *{1}' -f $bundleHash, (Split-Path $Out -Leaf)) -Encoding ascii
Write-Host ("Klart: {0} ({1:N0} MB)" -f $Out, ((Get-Item $Out).Length / 1MB)) -ForegroundColor Green
Write-Host "SHA256: $bundleHash (sparad i $(Split-Path $Out -Leaf).sha256)"
