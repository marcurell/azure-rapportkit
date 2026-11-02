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
#>

$script:Lang = $null
$script:LangCode = 'en'

# Loads English plus the chosen language. Returns the language that is in use (en if the pack is missing or invalid).
function Initialize-Language([string]$Code) {
    $dir = Join-Path $ScriptRoot 'lang'
    $texts = @{}
    $base = Import-PowerShellDataFile -LiteralPath (Join-Path $dir 'en.psd1')
    foreach ($k in $base.Keys) { $texts[$k] = $base[$k] }
    $used = 'en'
    if ($Code -and $Code -ne 'en') {
        $file = Join-Path $dir "$Code.psd1"
        if ($Code -notmatch '^[a-z]{2,3}(-[A-Za-z]{2,4})?$') { Add-Warning "Invalid report language '$Code'. Using English." }
        elseif (-not (Test-Path -LiteralPath $file)) { Add-Warning "No language pack for '$Code' (expected $file). Using English." }
        else {
            try {
                $over = Import-PowerShellDataFile -LiteralPath $file
                foreach ($k in $over.Keys) { $texts[$k] = $over[$k] }
                $used = $Code
            }
            catch { Add-Warning "The language pack $file could not be read ($($_.Exception.Message)). Using English." }
        }
    }
    $script:Lang = $texts
    $script:LangCode = $used
    $used
}

# The language packs that are installed (codes), for validation and messages.
function Get-LanguageCodes {
    @(Get-ChildItem -LiteralPath (Join-Path $ScriptRoot 'lang') -Filter '*.psd1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
}

function T([string]$Key) {
    if ($null -eq $script:Lang) { [void](Initialize-Language 'en') }
    if (-not $script:Lang.ContainsKey($Key)) { return "[$Key]" }
    $s = [string]$script:Lang[$Key]
    if ($args.Count) { $s -f $args } else { $s }
}
