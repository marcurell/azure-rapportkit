<#
.SYNOPSIS
  Laddar ner alla verktyg till tools\ och packar scriptet + verktygen i en zip som kan skickas till kunden.
  Kunden kör sedan: .\Run-Rapportkit.ps1 -Offline
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot 'rapportkit-bundle.zip'),
    [switch]$SkipInstallers   # hoppa över stora MSI/EXE (PowerShell, Azure CLI, Git) om kunden har dem
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$tools = Join-Path $PSScriptRoot 'tools'
New-Item -ItemType Directory -Force "$tools\installers", "$tools\modules" | Out-Null
$h = @{ 'User-Agent' = 'rapportkit' }

function Get-GhAsset($repo, $pattern) {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers $h
    $rel.assets | Where-Object name -like $pattern | Select-Object -First 1
}
function Get-File($url, $dest) {
    Write-Host "  $url"
    Invoke-WebRequest $url -OutFile $dest -Headers $h
}

Write-Host 'azqr' -ForegroundColor Cyan
$a = Get-GhAsset 'Azure/azqr' 'azqr-win-amd64.zip'
Get-File $a.browser_download_url "$tools\azqr.zip"

Write-Host 'Azure Governance Visualizer' -ForegroundColor Cyan
Get-File 'https://github.com/Azure/Azure-Governance-Visualizer/archive/refs/heads/main.zip' "$tools\AzGovViz.zip"

Write-Host 'PowerShell-moduler' -ForegroundColor Cyan
foreach ($m in 'Az.Accounts', 'Pester', 'Maester') {
    Save-Module $m -Path "$tools\modules\_nupkg" -Force
}
# Save-Module lägger en undermapp per modul/version; flytta upp till tools\modules\<modul>
Get-ChildItem "$tools\modules\_nupkg" -Directory | ForEach-Object {
    $dest = Join-Path "$tools\modules" $_.Name
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item $_.FullName $dest
}
Remove-Item "$tools\modules\_nupkg" -Recurse -Force -ErrorAction SilentlyContinue

if (-not $SkipInstallers) {
    Write-Host 'Installers' -ForegroundColor Cyan
    $a = Get-GhAsset 'PowerShell/PowerShell' 'PowerShell-*-win-x64.msi'
    Get-File $a.browser_download_url "$tools\installers\$($a.name)"
    $a = Get-GhAsset 'git-for-windows/git' 'Git-*-64-bit.exe'
    Get-File $a.browser_download_url "$tools\installers\$($a.name)"
    Get-File 'https://aka.ms/installazurecliwindowsx64' "$tools\installers\azure-cli-latest.msi"
}

Write-Host 'Packar zip' -ForegroundColor Cyan
if (Test-Path $Out) { Remove-Item $Out -Force }
$stage = Join-Path $env:TEMP 'rapportkit-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item "$PSScriptRoot\Run-Rapportkit.ps1", "$PSScriptRoot\README.md" $stage -ErrorAction SilentlyContinue
Copy-Item $tools "$stage\tools" -Recurse
Compress-Archive "$stage\*" $Out
Remove-Item $stage -Recurse -Force
Write-Host ("Klart: {0} ({1:N0} MB)" -f $Out, ((Get-Item $Out).Length / 1MB)) -ForegroundColor Green
