<#
.SYNOPSIS
  Laddar ner alla verktyg till tools\ och packar scriptet + verktygen i en zip som kan skickas till kunden.
  Kunden kör sedan: .\Run-Rapportkit.ps1 -Offline

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

# Samma fasta version som Run-Rapportkit.ps1 använder.
$GvVersion = '6.7.2'
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

Write-Host 'azqr' -ForegroundColor Cyan
$a = Get-GhAsset 'Azure/azqr' 'azqr-win-amd64.zip'
Get-File $a.browser_download_url "$tools\azqr.zip" 1MB
Assert-Zip "$tools\azqr.zip" '*azqr*.exe'

Write-Host "Azure Governance Visualizer $GvVersion" -ForegroundColor Cyan
Get-File "https://github.com/Azure/Azure-Governance-Visualizer/archive/refs/tags/$GvVersion.zip" "$tools\AzGovViz.zip" 100KB
Assert-Zip "$tools\AzGovViz.zip" '*pwsh/AzGovVizParallel.ps1'

Write-Host 'PowerShell-moduler' -ForegroundColor Cyan
$modules = @(@{ N = 'Az.Accounts' }, @{ N = 'AzAPICall'; V = '1.4.1' }, @{ N = 'Pester' }, @{ N = 'Maester' })
foreach ($m in $modules) {
    $dest = Join-Path $tools "modules\$($m.N)"
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Write-Host "  $($m.N) $($m.V)"
    if (Get-Command Save-PSResource -ErrorAction SilentlyContinue) {
        $p = @{ Name = $m.N; Path = "$tools\modules"; TrustRepository = $true; Quiet = $true }
        if ($m.V) { $p.Version = $m.V }
        Save-PSResource @p
    }
    else {
        $p = @{ Name = $m.N; Path = "$tools\modules"; Force = $true }
        if ($m.V) { $p.RequiredVersion = $m.V }
        Save-Module @p
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
Copy-Item "$PSScriptRoot\Run-Rapportkit.ps1", "$PSScriptRoot\README.md", "$PSScriptRoot\LICENSE" $stage
Copy-Item $tools "$stage\tools" -Recurse
Compress-Archive "$stage\*" $Out
Remove-Item $stage -Recurse -Force
Assert-Zip $Out '*Run-Rapportkit.ps1'
Write-Host ("Klart: {0} ({1:N0} MB)" -f $Out, ((Get-Item $Out).Length / 1MB)) -ForegroundColor Green
