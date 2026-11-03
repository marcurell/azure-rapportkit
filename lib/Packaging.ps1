<#
  Shared helpers for Pack-Kit.ps1 and Build-Bundle.ps1: set the report language in a theme.json and copy the customer
  documents (README, KUNDINFO, guide) in the right language into a package folder.

  The customer documents are in the repo as docs\kund\README.<code>.md, docs\KUNDINFO.<code>.md and
  docs\kund\guide.<code>.docx. In the package they get the names the script and the README refer to: README.md,
  docs\KUNDINFO.md and docs\<guide name>.docx. A document that is missing in the chosen language falls back to English.
#>

# Get-LanguageChain: a code with a region (sv-SE) uses the documents of the language (sv).
. (Join-Path $PSScriptRoot 'Lang.ps1')

# File name of the customer guide in the package, per language (other languages keep guide.<code>.docx).
$script:GuideNames = @{ en = 'Azure-Rapportkit-Customer-guide.docx'; sv = 'Azure-Rapportkit-Kundguide.docx' }

# The "language" of a theme.json, or '' if it has none.
function Get-ThemeLanguage([string]$ThemeFile) {
    if (-not (Test-Path -LiteralPath $ThemeFile)) { return '' }
    try { $t = Get-Content -LiteralPath $ThemeFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return '' }
    if ($t.PSObject.Properties.Name -contains 'language' -and $t.language) { return [string]$t.language }
    ''
}

# Writes "language" into a theme.json (replaces the value, or adds the field). The file must stay valid JSON.
function Set-ThemeLanguage([string]$ThemeFile, [string]$Language) {
    $json = [System.IO.File]::ReadAllText($ThemeFile, [System.Text.Encoding]::UTF8)
    if ($json -match '"language"\s*:\s*"[^"]*"') { $json = [regex]::Replace($json, '"language"\s*:\s*"[^"]*"', ('"language": "' + $Language + '"'), 1) }
    elseif ($json -match '^\s*\{\s*\}\s*$') { $json = '{' + [Environment]::NewLine + '  "language": "' + $Language + '"' + [Environment]::NewLine + '}' }   # an empty object takes no trailing comma
    else { $json = [regex]::Replace($json, '^(\s*\{)', ('$1' + [Environment]::NewLine + '  "language": "' + $Language + '",'), 1) }
    try { [void]($json | ConvertFrom-Json) } catch { throw "theme.json became invalid when the language was set: $($_.Exception.Message)" }
    [System.IO.File]::WriteAllText($ThemeFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Copies README.md, docs\KUNDINFO.md and the guide into $Stage in the language $Language (default: the language in the
# theme.json of $Stage, else English). A document that is missing in the chosen language falls back to the language without
# region, then English. Returns the language that was used for the README.
function Copy-CustomerDocs([string]$Root, [string]$Stage, [string]$Language) {
    if (-not $Language) { $Language = Get-ThemeLanguage (Join-Path $Stage 'branding\theme.json') }
    $chain = Get-LanguageChain $Language
    $pick = {
        param($dir, $pattern)
        foreach ($code in $chain) {
            $f = Join-Path $dir ($pattern -f $code)
            if (Test-Path -LiteralPath $f) { return @{ File = $f; Code = $code } }
        }
        $null
    }
    $kund = Join-Path $Root 'docs\kund'
    $readme = & $pick $kund 'README.{0}.md'
    if (-not $readme) { throw "Cannot find the customer README ($kund\README.$Language.md or README.en.md)." }
    Copy-Item -LiteralPath $readme.File -Destination (Join-Path $Stage 'README.md')
    New-Item -ItemType Directory -Force (Join-Path $Stage 'docs') | Out-Null
    $info = & $pick (Join-Path $Root 'docs') 'KUNDINFO.{0}.md'
    if ($info) { Copy-Item -LiteralPath $info.File -Destination (Join-Path $Stage 'docs\KUNDINFO.md') }
    $guide = & $pick $kund 'guide.{0}.docx'
    if ($guide) {
        $name = if ($script:GuideNames.ContainsKey($guide.Code)) { $script:GuideNames[$guide.Code] } else { "guide.$($guide.Code).docx" }
        Copy-Item -LiteralPath $guide.File -Destination (Join-Path $Stage "docs\$name")
    }
    $readme.Code
}
