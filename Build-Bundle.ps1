<#
.SYNOPSIS
  Downloads all the tools to tools\ and packs the script + the tools in a zip for a computer without internet access.
  On that computer, run: .\Run-Rapportkit.ps1 -Offline

.DESCRIPTION
  Versions and checksums are read from Run-Rapportkit.ps1 ($Pins), so that the bundle always contains exactly the
  tested versions. Downloaded zip files are checked against the checksum before the package is built.

.PARAMETER Out
  Path of the zip file that is created.
.PARAMETER Language
  Language of the report text in the bundle (en, sv). Written as "language" in branding\theme.json in the bundle. Default: the language in branding\theme.json, else English.
.PARAMETER SkipInstallers
  Skip the large installer files (PowerShell 7, Azure CLI, Git) if the computer already has them.
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $PSScriptRoot 'rapportkit-bundle.zip'),
    [ValidatePattern('^[a-z]{2,3}(-[A-Za-z]{2,4})?$')]
    [string]$Language,
    [switch]$SkipInstallers
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Read pinned versions and checksums from the main script (a single source)
$src = Get-Content (Join-Path $PSScriptRoot 'Run-Rapportkit.ps1') -Raw
function Get-Pin([string]$Pattern) {
    $m = [regex]::Match($src, $Pattern)
    if (-not $m.Success) { throw "Did not find '$Pattern' in Run-Rapportkit.ps1" }
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
    if (-not $a) { throw "Found no file that matches '$pattern' in the latest release of $repo." }
    $a
}

# Downloads with 3 attempts and checks that the file is not too small.
function Get-File($url, $dest, [long]$minBytes = 1024) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            Write-Host "  $url (attempt $i/3)"
            Invoke-WebRequest $url -OutFile $dest -Headers $h -UseBasicParsing
            if ((Get-Item $dest).Length -lt $minBytes) { throw 'the file is too small' }
            return
        }
        catch { Remove-Item $dest -Force -ErrorAction SilentlyContinue; if ($i -eq 3) { throw "Download failed: $url ($($_.Exception.Message))" }; Start-Sleep (2 * $i) }
    }
}

# Checks that a zip is intact and contains an expected entry.
function Assert-Zip($path, $mustContain) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($path)
    try { if (-not ($z.Entries | Where-Object { $_.FullName -like $mustContain })) { throw "$path saknar $mustContain" } }
    finally { $z.Dispose() }
}

# Checks SHA256 against the tested checksum.
function Assert-Sha($path, $expected, $what) {
    $actual = (Get-FileHash $path -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "${what}: the checksum does not match (expected $expected, got $actual). The upstream file may have changed: check and update `$Pins in Run-Rapportkit.ps1." }
    Write-Host "  ${what}: SHA256 matches"
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
    if (-not (Test-Path $dest)) { throw "The module $($m.N) was not fetched to $dest" }
}
# Dependencies of the modules end up as folders of their own in tools\modules and are included in the zip.

if (-not $SkipInstallers) {
    Write-Host 'Installers' -ForegroundColor Cyan
    $a = Get-GhAsset 'PowerShell/PowerShell' 'PowerShell-*-win-x64.msi'
    Get-File $a.browser_download_url "$tools\installers\$($a.name)" 10MB
    $a = Get-GhAsset 'git-for-windows/git' 'Git-*-64-bit.exe'
    Get-File $a.browser_download_url "$tools\installers\$($a.name)" 10MB
    Get-File 'https://aka.ms/installazurecliwindowsx64' "$tools\installers\azure-cli-latest.msi" 10MB
}

Write-Host 'Packing the zip' -ForegroundColor Cyan
if (Test-Path $Out) { Remove-Item $Out -Force }
$stage = Join-Path $env:TEMP 'rapportkit-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory $stage | Out-Null
foreach ($file in 'Run-Rapportkit.ps1', 'LICENSE', 'THIRD-PARTY-NOTICES.md') { Copy-Item (Join-Path $PSScriptRoot $file) $stage }
foreach ($dir in 'lib', 'lang', 'branding', 'branding-exempel') { Copy-Item (Join-Path $PSScriptRoot $dir) "$stage\$dir" -Recurse }
foreach ($doc in 'README.md', 'README.sv.md') { Copy-Item (Join-Path $PSScriptRoot $doc) $stage }
. (Join-Path $PSScriptRoot 'lib\Packaging.ps1')
if ($Language) { Set-ThemeLanguage "$stage\branding\theme.json" $Language }
Copy-Item $tools "$stage\tools" -Recurse
Compress-Archive "$stage\*" $Out
Remove-Item $stage -Recurse -Force
Assert-Zip $Out '*Run-Rapportkit.ps1'
$bundleHash = (Get-FileHash $Out -Algorithm SHA256).Hash
Set-Content -Path "$Out.sha256" -Value ('{0} *{1}' -f $bundleHash, (Split-Path $Out -Leaf)) -Encoding ascii
Write-Host ("Done: {0} ({1:N0} MB)" -f $Out, ((Get-Item $Out).Length / 1MB)) -ForegroundColor Green
Write-Host "SHA256: $bundleHash (saved in $(Split-Path $Out -Leaf).sha256)"
