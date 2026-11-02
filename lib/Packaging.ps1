<#
  Shared helpers for Pack-Kit.ps1 and Build-Bundle.ps1: set the report language in a theme.json and copy the customer
  documents (README, KUNDINFO, guide) in the right language into a package folder.

  The customer documents are in the repo as docs\kund\README.<code>.md, docs\KUNDINFO.<code>.md and
  docs\kund\guide.<code>.docx. In the package they get the names the script and the README refer to: README.md,
  docs\KUNDINFO.md and docs\<guide name>.docx. A document that is missing in the chosen language falls back to English.
#>

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
    else { $json = [regex]::Replace($json, '^(\s*\{)', ('$1' + [Environment]::NewLine + '  "language": "' + $Language + '",'), 1) }
    try { [void]($json | ConvertFrom-Json) } catch { throw "theme.json became invalid when the language was set: $($_.Exception.Message)" }
    [System.IO.File]::WriteAllText($ThemeFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Copies README.md, docs\KUNDINFO.md and the guide into $Stage in the language $Language (default: the language in the
# theme.json of $Stage, else English). Returns the language that was used for the README.
function Copy-CustomerDocs([string]$Root, [string]$Stage, [string]$Language) {
    if (-not $Language) { $Language = Get-ThemeLanguage (Join-Path $Stage 'branding\theme.json') }
    if (-not $Language) { $Language = 'en' }
    $pick = {
        param($dir, $pattern, $what)
        foreach ($code in $Language, 'en') {
            $f = Join-Path $dir ($pattern -f $code)
            if (Test-Path -LiteralPath $f) { return $f }
        }
        $null
    }
    $kund = Join-Path $Root 'docs\kund'
    $readme = & $pick $kund 'README.{0}.md'
    if (-not $readme) { throw "Cannot find the customer README ($kund\README.$Language.md or README.en.md)." }
    Copy-Item -LiteralPath $readme -Destination (Join-Path $Stage 'README.md')
    New-Item -ItemType Directory -Force (Join-Path $Stage 'docs') | Out-Null
    $info = & $pick (Join-Path $Root 'docs') 'KUNDINFO.{0}.md'
    if ($info) { Copy-Item -LiteralPath $info -Destination (Join-Path $Stage 'docs\KUNDINFO.md') }
    foreach ($code in $Language, 'en') {
        $g = Join-Path $kund "guide.$code.docx"
        if (Test-Path -LiteralPath $g) {
            $name = if ($script:GuideNames.ContainsKey($code)) { $script:GuideNames[$code] } else { "guide.$code.docx" }
            Copy-Item -LiteralPath $g -Destination (Join-Path $Stage "docs\$name")
            break
        }
    }
    $Language
}
