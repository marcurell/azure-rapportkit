<#
  Helpers for Build-Bundle.ps1 (and for tools that pack the kit): read and set the report language in a theme.json.
#>

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
