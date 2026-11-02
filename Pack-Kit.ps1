<#
.SYNOPSIS
  Packar kitet i en zip-fil att ge till en kund, med valfri egen branding.
.DESCRIPTION
  Rapportens utseende är filerna i mappen branding\ (theme.json, logga, bakgrund, custom.css). Det finns ingen flagga för
  att välja tema: det som ligger i branding\ i zippen är det som används. Pack-Kit.ps1 gör en zip av kitet där branding\
  ersatts av innehållet i en annan mapp, så att kundens rapport får din profil utan att du ändrar något i repot.

  Kör från en uppackad version av kitet (eller en klon av repot). Zippen innehåller scriptet, lib\, docs\, README och
  licensfilerna, men aldrig tests\, .git\ eller några resultat.
.PARAMETER Branding
  Mapp vars innehåll blir branding\ i zippen. Måste innehålla theme.json. Utan den används kitets egen branding\.
.PARAMETER Out
  Zip-fil att skapa. Standard: azure-rapportkit-<version>[-<mappnamn>].zip i aktuell mapp.
.EXAMPLE
  .\Pack-Kit.ps1 -Branding D:\profiler\orange\branding
#>
[CmdletBinding()]
param(
    [string]$Branding,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSCommandPath
$main = Join-Path $root 'Run-Rapportkit.ps1'
if (-not (Test-Path -LiteralPath $main)) { throw "Hittar inte Run-Rapportkit.ps1 i $root. Kör Pack-Kit.ps1 från kitets mapp." }
$version = ([regex]::Match((Get-Content -LiteralPath $main -Raw -Encoding UTF8), "\`$KitVersion\s*=\s*'([^']+)'")).Groups[1].Value
if (-not $version) { throw 'Hittar inte versionsnumret i Run-Rapportkit.ps1.' }

$brandSource = Join-Path $root 'branding'
$suffix = ''
if ($Branding) {
    $brandSource = (Resolve-Path -LiteralPath $Branding).Path
    if (-not (Test-Path -LiteralPath (Join-Path $brandSource 'theme.json'))) { throw "$brandSource innehåller ingen theme.json." }
    try { [void](Get-Content -LiteralPath (Join-Path $brandSource 'theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "theme.json i $brandSource är inte giltig JSON: $($_.Exception.Message)" }
    $leaf = Split-Path (Split-Path $brandSource -Parent) -Leaf
    if ($leaf -match '^[A-Za-z0-9_-]+$') { $suffix = "-$leaf" }
}
if (-not $Out) { $Out = Join-Path (Get-Location) "azure-rapportkit-$version$suffix.zip" }

$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rk-pack-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $stageRoot "azure-rapportkit-$version"
try {
    New-Item -ItemType Directory -Force $stage | Out-Null
    foreach ($f in 'Run-Rapportkit.ps1', 'Unprotect-Rapportkit.ps1', 'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md') {
        if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) $stage }
    }
    foreach ($d in 'lib', 'docs') { if (Test-Path -LiteralPath (Join-Path $root $d)) { Copy-Item -LiteralPath (Join-Path $root $d) (Join-Path $stage $d) -Recurse } }
    Copy-Item -LiteralPath $brandSource -Destination (Join-Path $stage 'branding') -Recurse
    if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $Out)
}
finally { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }

$mb = (Get-Item -LiteralPath $Out).Length / 1MB
Write-Host ('Skapade {0} ({1:N1} MB), version {2}, branding från: {3}' -f $Out, $mb, $version, $brandSource) -ForegroundColor Green
Write-Host 'Mottagaren packar upp zippen, högerklickar på Run-Rapportkit.ps1 > Egenskaper > Avblockera (eller kör Get-ChildItem -Recurse | Unblock-File) och kör scriptet.'
