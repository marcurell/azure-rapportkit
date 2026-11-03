<#
.SYNOPSIS
  Turns a result folder from the collector into a run package (manifest.json + data\*.jsonl) for the report engine.
.DESCRIPTION
  Read-only against the result folder. The package is written to <RunDir>\package unless -OutDir is given. Works for
  runs from any 1.x version: older runs get derived keys where the stable ones are missing (see manifest "imported").
.EXAMPLE
  .\Export-RunPackage.ps1 -RunDir C:\rapportkit\2026-10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDir,
    [string]$OutDir,
    [string]$TenantId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Package.ps1')
$r = New-RunPackage -RunDir $RunDir -OutDir $OutDir -TenantId $TenantId
Write-Host "Package written to $($r.OutDir)"
foreach ($k in $r.Counts.Keys) { if ($r.Counts[$k]) { Write-Host ("  {0,-14} {1} rows" -f $k, $r.Counts[$k]) } }
$r.Manifest.sources.GetEnumerator() | ForEach-Object { Write-Host ("  source {0,-20} {1}" -f $_.Key, $_.Value.state) }
if ($r.Manifest.imported.keyQuality -ne 'exact') { Write-Host "  note: some keys are derived (run written before 1.4.1)" }
