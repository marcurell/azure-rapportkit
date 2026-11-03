<#
  Language packs for the report.

  The report text lives in lang\<code>.psd1 (PowerShell data files: key = text). lang\en.psd1 is the base and is always
  loaded; the chosen language is laid on top of it, so a key that is missing in a translation falls back to English.

  Conventions:
    - T 'key' arg0 arg1 ...   returns the text, filled in with -f ({0}, {1}, ...). Without arguments the text is returned as is.
    - Keys ending in .html hold HTML (tags and entities are allowed). All other texts are plain text and must be
      HTML-encoded (Esc) by the caller. Arguments that come from data must be encoded by the caller in both cases.
    - Literal braces in a text with arguments are written {{ and }}.

  The language is chosen in Write-ReportSite: -ReportLanguage, else "language" in branding\theme.json, else en.
  A code with a region (sv-SE) uses the pack of the language (sv) if there is no pack for the exact code.
#>

$script:Lang = $null
$script:LangCode = 'en'

# The packs to try for a code, best first: sv-se, sv, and then en as the last resort (unless -NoFallback).
function Get-LanguageChain([string]$Code, [switch]$NoFallback) {
    $c = ([string]$Code).Trim().ToLowerInvariant()
    $chain = New-Object System.Collections.Generic.List[string]
    if ($c) { $chain.Add($c); if ($c.Contains('-')) { $chain.Add($c.Split('-')[0]) } }
    if (-not $NoFallback) { $chain.Add('en') }
    @($chain | Select-Object -Unique)
}

# The language packs that are installed (codes), for validation and messages.
function Get-LanguageCodes([string]$Root = $ScriptRoot) {
    @(Get-ChildItem -LiteralPath (Join-Path $Root 'lang') -Filter '*.psd1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
}

# Loads English plus the chosen language. Returns the language that is in use (en if the pack is missing or invalid).
function Initialize-Language([string]$Code) {
    $dir = Join-Path $ScriptRoot 'lang'
    $texts = @{}
    $base = Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'en.psd1')
    foreach ($k in $base.Keys) { $texts[$k] = $base[$k] }
    $used = 'en'
    if ($Code -and -not $Code.ToLowerInvariant().StartsWith('en')) {
        if ($Code -notmatch '^[a-z]{2,3}(-[a-z]{2,4})?$') { Add-Warning "Invalid report language '$Code'. Using English." }
        else {
            $file = $null
            foreach ($c in (Get-LanguageChain $Code -NoFallback)) {
                $f = Join-Path $dir "$c.psd1"
                if (Test-Path -LiteralPath $f) { $file = $f; $used = $c; break }
            }
            if (-not $file) { Add-Warning "No language pack for '$Code' (available: $((Get-LanguageCodes) -join ', ')). Using English." }
            else {
                try {
                    $over = Import-PowerShellDataFile -LiteralPath $file
                    foreach ($k in $over.Keys) { $texts[$k] = $over[$k] }
                }
                catch { $used = 'en'; Add-Warning "The language pack $file could not be read ($($_.Exception.Message)). Using English." }
            }
        }
    }
    $script:Lang = $texts
    $script:LangCode = $used
    $used
}

function T([string]$Key) {
    if ($null -eq $script:Lang) { [void](Initialize-Language 'en') }
    if (-not $script:Lang.ContainsKey($Key)) { return "[$Key]" }
    $s = [string]$script:Lang[$Key]
    if (-not $args.Count) { return $s }
    # A broken placeholder in a translation must not stop the report: show the text as it is and say so once.
    try { $s -f $args }
    catch {
        if (-not $script:BadLangKeys) { $script:BadLangKeys = @{} }
        if (-not $script:BadLangKeys.ContainsKey($Key)) { $script:BadLangKeys[$Key] = $true; Add-Warning "The text '$Key' in the $script:LangCode language pack has a faulty placeholder ($($_.Exception.Message)). It is shown unformatted." }
        $s
    }
}
