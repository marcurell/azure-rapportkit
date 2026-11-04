<#
.SYNOPSIS
  Sets the version number on the cover page of the guides (docs\kund\guide.*.docx and the operator guide in docs\).
.DESCRIPTION
  The guides are Word files with "Version x.y.z" on the cover. Run this at every release, with the version of the kit:
    .\docs\Set-GuideVersion.ps1 -Version 1.4.5
  The test tests\Guides.Tests.ps1 fails if the version in the guides differs from $KitVersion in Run-Rapportkit.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$GuideDir = (Join-Path $PSScriptRoot 'kund')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$files = @(Get-ChildItem -LiteralPath $GuideDir -Filter 'guide.*.docx') + @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Anvandarguide-*.docx')
foreach ($file in $files) {
    $zip = [System.IO.Compression.ZipFile]::Open($file.FullName, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.GetEntry('word/document.xml')
        if (-not $entry) { throw "$($file.Name) has no word/document.xml." }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $new = [regex]::Replace($xml, 'Version \d+\.\d+\.\d+', "Version $Version")
        if ($new -eq $xml) { Write-Host "$($file.Name): already version $Version (or no version text found)"; continue }
        $entry.Delete()
        $entry = $zip.CreateEntry('word/document.xml', [System.IO.Compression.CompressionLevel]::Optimal)
        $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($new) } finally { $writer.Dispose() }
        Write-Host "$($file.Name): version set to $Version"
    }
    finally { $zip.Dispose() }
}
