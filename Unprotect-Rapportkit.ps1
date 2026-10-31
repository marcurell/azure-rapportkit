<#
.SYNOPSIS
  Packar upp ett lösenordsskyddat rapportpaket (.rkenc) från Azure Rapportkit.
.DESCRIPTION
  Frågar efter lösenordet, kontrollerar att filen är oskadd och packar upp rapporten i en mapp bredvid filen.
  Fungerar i både Windows PowerShell 5.1 och PowerShell 7. Inget skickas någonstans.
.PARAMETER Path
  Den krypterade filen, till exempel rapportkit_a6017aee_2026-10.zip.rkenc.
.PARAMETER Destination
  Mapp att packa upp i. Standard: en mapp med filens namn bredvid filen.
.PARAMETER KeepZip
  Spara även den dekrypterade zip-filen.
.EXAMPLE
  .\Unprotect-Rapportkit.ps1 -Path C:\Temp\rapportkit_a6017aee_2026-10.zip.rkenc
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Path,
    [string]$Destination,
    [System.Security.SecureString]$Password,
    [switch]$KeepZip
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'lib\Crypto.ps1')

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Hittar inte filen: $Path" }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $sha = Join-Path (Split-Path $Path -Parent) ((Split-Path $Path -Leaf) + '.sha256')
    if (Test-Path -LiteralPath $sha) {
        $expected = ((Get-Content -LiteralPath $sha -Raw).Trim() -split '\s+')[0]
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($expected -ne $actual) { throw 'Kontrollsumman (SHA256) stämmer inte med .sha256-filen: filen har ändrats eller skadats under överföringen.' }
        Write-Host 'Kontrollsumman stämmer.' -ForegroundColor Green
    }
    if (-not $Password) { $Password = Read-Host 'Lösenord' -AsSecureString }
    if (-not $Destination) { $Destination = Join-Path (Split-Path $Path -Parent) ((Split-Path $Path -Leaf) -replace '\.zip\.rkenc$|\.rkenc$', '') }
    if ((Test-Path -LiteralPath $Destination) -and (Get-ChildItem -LiteralPath $Destination -Force | Select-Object -First 1)) { throw "Målmappen finns redan och är inte tom: $Destination (välj en annan med -Destination)." }

    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('rapportkit-' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Unprotect-RapportkitFile -Path $Path -Destination $zip -Password $Password
        New-Item -ItemType Directory -Force $Destination | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $Destination -Force
        if ($KeepZip) { Copy-Item -LiteralPath $zip -Destination ($Destination.TrimEnd('\') + '.zip') -Force }
    }
    finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }

    Write-Host "Uppackat i: $Destination" -ForegroundColor Green
    Write-Host 'Öppna rapport.html i mappen.'
}
catch {
    Write-Host "FEL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
