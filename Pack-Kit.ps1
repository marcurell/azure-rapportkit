<#
.SYNOPSIS
  Packs the kit in a zip file to give to a customer, with optional branding of your own.
.DESCRIPTION
  The look of the report is the files in the folder branding\ (theme.json, logo, background, custom.css). There is no switch
  for choosing a theme: what is in branding\ in the zip is what is used. Pack-Kit.ps1 makes a zip of the kit where branding\
  is replaced by the content of another folder, so that the customer's report gets your profile without you changing anything in the repo.

  Run it from an unpacked version of the kit (or a clone of the repo). The zip is a CUSTOMER VERSION: it contains the script,
  lib\, lang\, branding\, the customer README (docs\kund\README.md, as README.md), the customer guide (Word), docs\KUNDINFO.md and
  the licence files, but nothing that points to the repo (the repo README, Unprotect-Rapportkit.ps1, Pack-Kit.ps1) and never tests\,
  .git\ or any results. The customer thus gets a package that can be unpacked and run without anything being fetched from your repo.
.PARAMETER Branding
  Folder whose content becomes branding\ in the zip. Must contain theme.json. Without it the kit's own branding\ is used.
.PARAMETER Language
  Language of the report text in the zip: the code of a language pack in lang\ (en, sv). Written as "language" in theme.json in
  the zip, so the customer gets the report in that language without choosing anything. It also picks the language of the
  customer README, KUNDINFO and guide. Without it what is already in theme.json applies (and otherwise English). The customer
  can still change the report language with -ReportLanguage.
.PARAMETER Out
  Zip file to create. Default: azure-rapportkit-<version>[-<folder name>].zip in the current folder.
.EXAMPLE
  .\Pack-Kit.ps1 -Branding D:\profiler\orange\branding
.EXAMPLE
  .\Pack-Kit.ps1 -Branding D:\profiler\orange\branding -Language sv
#>
[CmdletBinding()]
param(
    [string]$Branding,
    [ValidatePattern('^[a-z]{2,3}(-[A-Za-z]{2,4})?$')]
    [string]$Language,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSCommandPath
. (Join-Path $root 'lib\Packaging.ps1')
$main = Join-Path $root 'Run-Rapportkit.ps1'
if (-not (Test-Path -LiteralPath $main)) { throw "Cannot find Run-Rapportkit.ps1 in $root. Run Pack-Kit.ps1 from the kit folder." }
$version = ([regex]::Match((Get-Content -LiteralPath $main -Raw -Encoding UTF8), "\`$KitVersion\s*=\s*'([^']+)'")).Groups[1].Value
if (-not $version) { throw 'Cannot find the version number in Run-Rapportkit.ps1.' }

$brandSource = Join-Path $root 'branding'
$suffix = ''
if ($Branding) {
    $brandSource = (Resolve-Path -LiteralPath $Branding).Path
    if (-not (Test-Path -LiteralPath (Join-Path $brandSource 'theme.json'))) { throw "$brandSource contains no theme.json." }
    try { [void](Get-Content -LiteralPath (Join-Path $brandSource 'theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "theme.json in $brandSource is not valid JSON: $($_.Exception.Message)" }
    $leaf = Split-Path (Split-Path $brandSource -Parent) -Leaf
    if ($leaf -match '^[A-Za-z0-9_-]+$') { $suffix = "-$leaf" }
}
if ($Language -and -not @(Get-LanguageChain $Language -NoFallback | Where-Object { Test-Path -LiteralPath (Join-Path $root "lang\$_.psd1") }).Count) {
    throw "There is no language pack '$Language' in lang\ (available: $((Get-LanguageCodes $root) -join ', '))."
}
if (-not $Out) { $Out = Join-Path (Get-Location) "azure-rapportkit-$version$suffix.zip" }

$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('rk-pack-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $stageRoot "azure-rapportkit-$version"
try {
    New-Item -ItemType Directory -Force $stage | Out-Null
    foreach ($f in 'Run-Rapportkit.ps1', 'LICENSE', 'THIRD-PARTY-NOTICES.md') {
        if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) $stage }
    }
    Copy-Item -LiteralPath (Join-Path $root 'lib') (Join-Path $stage 'lib') -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'lang') (Join-Path $stage 'lang') -Recurse
    Copy-Item -LiteralPath $brandSource -Destination (Join-Path $stage 'branding') -Recurse
    # Sets "language" in the theme.json of the zip (the source folder is not touched).
    if ($Language) { Set-ThemeLanguage (Join-Path $stage 'branding\theme.json') $Language }
    # The customer's documents: README.md in the zip is the customer version (the script's error messages refer to the README), not the repo's.
    $docLanguage = Copy-CustomerDocs $root $stage $Language
    if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $Out)
}
finally { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }

$mb = (Get-Item -LiteralPath $Out).Length / 1MB
$langText = ", documents: $docLanguage" + $(if ($Language) { ", report language: $Language" } else { '' })
Write-Host ('Created {0} ({1:N1} MB), version {2}, branding from: {3}{4}' -f $Out, $mb, $version, $brandSource, $langText) -ForegroundColor Green
Write-Host 'The recipient unpacks the zip, right-clicks Run-Rapportkit.ps1 > Properties > Unblock (or runs Get-ChildItem -Recurse | Unblock-File) and runs the script.'
