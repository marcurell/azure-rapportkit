<#
.SYNOPSIS
  Unpacks a password-protected report package (.rkenc) from Azure Rapportkit.
.DESCRIPTION
  Asks for the password, checks that the file is intact and unpacks the report in a folder next to the file.
  Works in both Windows PowerShell 5.1 and PowerShell 7. Nothing is sent anywhere.
.PARAMETER Path
  The encrypted file, for example rapportkit_00000000_2026-10.zip.rkenc.
.PARAMETER Destination
  Folder to unpack into. Default: a folder named after the file, next to the file.
.PARAMETER KeepZip
  Also keep the decrypted zip file.
.EXAMPLE
  .\Unprotect-Rapportkit.ps1 -Path C:\Temp\rapportkit_00000000_2026-10.zip.rkenc
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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Cannot find the file: $Path" }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $sha = Join-Path (Split-Path $Path -Parent) ((Split-Path $Path -Leaf) + '.sha256')
    if (Test-Path -LiteralPath $sha) {
        $expected = ((Get-Content -LiteralPath $sha -Raw).Trim() -split '\s+')[0]
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($expected -ne $actual) { throw 'The checksum (SHA256) does not match the .sha256 file: the file has been modified or damaged in transfer.' }
        Write-Host 'The checksum matches.' -ForegroundColor Green
    }
    if (-not $Password) { $Password = Read-Host 'Password' -AsSecureString }
    if (-not $Destination) { $Destination = Join-Path (Split-Path $Path -Parent) ((Split-Path $Path -Leaf) -replace '\.zip\.rkenc$|\.rkenc$', '') }
    if ((Test-Path -LiteralPath $Destination) -and (Get-ChildItem -LiteralPath $Destination -Force | Select-Object -First 1)) { throw "The destination folder already exists and is not empty: $Destination (choose another with -Destination)." }

    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('rapportkit-' + [guid]::NewGuid().ToString('N') + '.zip')
    try {
        Unprotect-RapportkitFile -Path $Path -Destination $zip -Password $Password
        New-Item -ItemType Directory -Force $Destination | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $Destination -Force
        if ($KeepZip) { Copy-Item -LiteralPath $zip -Destination ($Destination.TrimEnd('\') + '.zip') -Force }
    }
    finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }

    Write-Host "Unpacked in: $Destination" -ForegroundColor Green
    Write-Host 'Open rapport.html in the folder.'
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
