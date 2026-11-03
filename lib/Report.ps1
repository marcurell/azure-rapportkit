<#
  Report generator for Azure Rapportkit.

  Builds a multi-page HTML report in one common style from the tool results (azqr, Governance Visualizer, Maester,
  Defender and cost). The tools' own reports cannot be restyled (Governance Visualizer fetches its CSS, scripts and icons
  from a server on the internet, and Maester has its own template and logo), so the report summarises the data on its own
  pages and links to the tools' reports for more detail, in a new window.

  The look is set by the files in the folder branding\ (theme.json etc., see branding\README.md): colours, fonts, logo and
  footer. The language of the report text is set by the language packs in lang\ (see lib\Lang.ps1). Every page is
  self-contained (CSS and logo are embedded), so it can be opened without the rest.

  The file is dot-sourced by Run-Rapportkit.ps1 in step 10 and uses its variables ($Dirs, $RunDir, $Status, $Warnings,
  $TenantId, $Period, ...) and functions (Import-CsvChecked, Add-Warning, Write-Action). Entry point: Write-ReportSite.
#>

Add-Type -AssemblyName System.Web
. (Join-Path $ScriptRoot 'lib\Anonymize.ps1')
. (Join-Path $ScriptRoot 'lib\Lang.ps1')
. (Join-Path $ScriptRoot 'lib\StructurePage.ps1')

# ===========================================================================
# Helpers
# ===========================================================================

# HTML-encodes text and attributes. (Must not be called H: that is an alias for Get-History.)
function Esc($s) { [System.Web.HttpUtility]::HtmlEncode([string]$s) }

# Turns JSON objects (PSCustomObject) into hashtables, so that they can be merged and indexed.
function ConvertTo-Hashtable($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) { $h = @{}; foreach ($k in $o.Keys) { $h[$k] = ConvertTo-Hashtable $o[$k] }; return $h }
    if ($o -is [System.Management.Automation.PSCustomObject]) { $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }; return $h }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return , @($o | ForEach-Object { ConvertTo-Hashtable $_ }) }
    return $o
}

# Lays the values in $Over on top of $Base (recursively for sub-hashtables).
function Merge-Hashtable([hashtable]$Base, [hashtable]$Over) {
    foreach ($k in @($Over.Keys)) {
        if ($Base.ContainsKey($k) -and $Base[$k] -is [hashtable] -and $Over[$k] -is [hashtable]) { Merge-Hashtable $Base[$k] $Over[$k] }
        else { $Base[$k] = $Over[$k] }
    }
}

# Accepts only colour values that cannot break out of CSS: #hex, rgb()/hsl() and colour names.
function Test-CssColor($v) { ([string]$v) -match '^(#[0-9a-fA-F]{3,8}|(rgb|hsl)a?\([0-9\s,./%-]+\)|[a-zA-Z]{3,20})$' }
# Accepts only font lists with letters, digits, spaces, comma, quotes, full stop and hyphen.
function Test-CssFont($v) { ([string]$v) -match '^[\w\s,"''.\-]{1,200}$' }

# Keeps the first row per value in the column $Key. Governance Visualizer's CSV repeats the same assignment on several levels
# (inherited views), so the number of rows is larger than the number of unique assignments.
function Get-UniqueRows($Rows, [string]$Key) {
    if ($null -eq $Rows) { return $null }
    $seen = @{}
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Rows)) {
        $k = [string]$r.$Key
        if ($k -and $seen.ContainsKey($k)) { continue }
        if ($k) { $seen[$k] = $true }
        $out.Add($r)
    }
    , $out.ToArray()
}

# Number from CSV (may have a decimal comma) to double.
function ConvertTo-Number($v) {
    $s = ([string]$v) -replace ',', '.' -replace '\s', ''
    $d = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $d } else { 0.0 }
}

# ===========================================================================
# Tema
# ===========================================================================

# Built-in fallback theme: used if the theme is missing or invalid, and as a template for which values must exist.
$script:DefaultThemeJson = @'
{
  "name": "Neutral",
  "reportTitle": "Azure Rapportkit",
  "language": "",
  "tagline": "",
  "logo": { "type": "wordmark", "parts": [ { "text": "Azure", "color": "text" }, { "text": "Rapportkit", "color": "accent" } ] },
  "colors": {
    "light": { "bg": "#f6f8fa", "surface": "#ffffff", "surfaceAlt": "#eef2f6", "border": "#d0d7de", "text": "#1f2328", "muted": "#59636e", "accent": "#0969da", "accentText": "#0550ae", "onAccent": "#ffffff" },
    "dark":  { "bg": "#0d1117", "surface": "#161b22", "surfaceAlt": "#1c2128", "border": "#30363d", "text": "#e6edf3", "muted": "#8b949e", "accent": "#2f81f7", "accentText": "#79c0ff", "onAccent": "#ffffff" },
    "status": { "high": "#cf222e", "medium": "#bf8700", "low": "#0969da", "ok": "#1a7f37" }
  },
  "fonts": { "body": "system-ui, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif", "heading": "" },
  "footer": "",
  "contact": { "text": "", "url": "" },
  "background": { "file": "", "opacity": 0.08 },
  "customCss": ""
}
'@

# Reads the theme in the folder $Dir (default: branding\ next to the script). The theme is the files in that folder: theme.json plus optional
# images and custom.css. If the files are replaced it becomes a new theme. Values that are missing are filled in from the fallback theme, and invalid
# colours and fonts are replaced (with a warning). Gives @{ Data; Dir; Source }. Never fails: in the worst case the fallback theme is used.
function Get-BrandTheme([string]$Dir) {
    $default = { ConvertTo-Hashtable ($script:DefaultThemeJson | ConvertFrom-Json) }
    $theme = & $default
    $dir = if ($Dir) { $Dir } else { Join-Path $ScriptRoot 'branding' }
    $source = 'built-in default'
    if ($dir) {
        $file = Join-Path $dir 'theme.json'
        if (Test-Path -LiteralPath $file) {
            try {
                $custom = ConvertTo-Hashtable (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
                Merge-Hashtable $theme $custom
                $source = $dir
            }
            catch { Add-Warning "The theme in $dir could not be read ($($_.Exception.Message)). Using the built-in default."; $theme = & $default; $dir = $null }
        }
        else { Add-Warning "No theme found in $dir (theme.json is missing). Using the built-in default."; $dir = $null }
    }

    # Validate colours and fonts against the fallback theme. An invalid or missing value is replaced.
    $def = & $default
    try {
        foreach ($mode in 'light', 'dark') {
            foreach ($k in @($def.colors[$mode].Keys)) {
                $v = $theme.colors[$mode][$k]
                if (-not (Test-CssColor $v)) { Add-Warning "Theme: invalid colour colors.$mode.$k ('$v'). Using the default value."; $theme.colors[$mode][$k] = $def.colors[$mode][$k] }
            }
        }
        foreach ($k in @($def.colors.status.Keys)) {
            $v = $theme.colors.status[$k]
            if (-not (Test-CssColor $v)) { Add-Warning "Theme: invalid colour colors.status.$k ('$v'). Using the default value."; $theme.colors.status[$k] = $def.colors.status[$k] }
        }
        foreach ($k in 'body', 'heading') {
            $v = $theme.fonts[$k]
            if ($v -and -not (Test-CssFont $v)) { Add-Warning "Theme: invalid font fonts.$k. Using the default value."; $theme.fonts[$k] = $def.fonts[$k] }
        }
    }
    catch {
        Add-Warning "The theme has the wrong structure ($($_.Exception.Message)). Using the built-in default."
        $theme = & $default; $dir = $null; $source = 'built-in default'
    }
    @{ Data = $theme; Dir = $dir; Source = $source }
}

# The logo as HTML: an image file from the theme folder (embedded as a data URI) or a wordmark of coloured text parts.
function Get-ThemeImageUri($Theme, [string]$File, [int]$MaxKB = 300) {
    if (-not $Theme.Dir) { throw 'the theme has no folder' }
    $full = [IO.Path]::GetFullPath((Join-Path $Theme.Dir $File))
    $root = [IO.Path]::GetFullPath($Theme.Dir).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'the file is outside the theme folder' }
    $mime = switch ([IO.Path]::GetExtension($full).ToLower()) { '.svg' { 'image/svg+xml' } '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.gif' { 'image/gif' } '.webp' { 'image/webp' } default { $null } }
    if (-not $mime) { throw 'the file type is not supported (use svg, png, jpg, gif or webp)' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "the file $File does not exist in the theme folder" }
    if ((Get-Item -LiteralPath $full).Length -gt ($MaxKB * 1KB)) { throw "the file is larger than $MaxKB KB" }
    'data:{0};base64,{1}' -f $mime, [Convert]::ToBase64String([IO.File]::ReadAllBytes($full))
}

function Get-LogoHtml($Theme) {
    $t = $Theme.Data
    $logo = $t.logo
    if ($logo -is [hashtable] -and $logo.type -eq 'image' -and $logo.file -and $Theme.Dir) {
        try {
            $height = 36
            if ($logo.height) { $height = [int][math]::Min([math]::Max([double]$logo.height, 16), 80) }
            $light = Get-ThemeImageUri $Theme ([string]$logo.file)
            $img = { param($uri, $cls) '<img class="rk-logo-img{0}" src="{1}" alt="{2}" style="height:{3}px">' -f $cls, $uri, (Esc $logo.alt), $height }
            # Optional logo for dark mode (logo.fileDark): shown instead of the light one when the reader uses dark mode.
            if ($logo.fileDark) {
                try { return ((& $img $light ' rk-l-light') + (& $img (Get-ThemeImageUri $Theme ([string]$logo.fileDark)) ' rk-l-dark')) }
                catch { Add-Warning "The dark logo of the theme (fileDark) could not be used ($($_.Exception.Message)). The light one is used in both modes." }
            }
            return (& $img $light '')
        }
        catch { Add-Warning "The logo of the theme could not be used ($($_.Exception.Message)). Showing the name as a wordmark." }
    }
    $parts = @()
    if ($logo -is [hashtable] -and $logo.parts) { $parts = @($logo.parts) }
    if (-not $parts.Count) { $parts = @(@{ text = $t.name; color = 'text' }) }
    # All parts in ONE element, so that they stay together without a gap (the logo is a flex container).
    '<span class="rk-wm">' + (($parts | ForEach-Object {
                $cls = switch ([string]$_.color) { 'accent' { 'rk-w-accent' } 'accentText' { 'rk-w-accenttext' } 'muted' { 'rk-w-muted' } default { '' } }
                '<span class="{0}">{1}</span>' -f $cls, (Esc $_.text)
            }) -join '') + '</span>'
}

# Base style. All colours and fonts come from the variables that the theme sets (--rk-*).
$script:BaseCss = @'
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--rk-bg);color:var(--rk-text);font:15px/1.55 var(--rk-font)}
h1,h2,h3{font-family:var(--rk-heading-font);line-height:1.25;color:var(--rk-text)}
a{color:var(--rk-accent-text)}
.rk-top{background:var(--rk-surface);border-bottom:1px solid var(--rk-border);border-top:4px solid var(--rk-accent)}
.rk-top-in{max-width:1120px;margin:0 auto;padding:14px 20px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}
.rk-logo{display:flex;align-items:center;gap:12px;font-weight:700;font-size:21px;letter-spacing:-.01em;color:var(--rk-text);text-decoration:none}
.rk-logo .rk-w-accent{color:var(--rk-accent)}.rk-logo .rk-w-accenttext{color:var(--rk-accent-text)}.rk-logo .rk-w-muted{color:var(--rk-muted)}
.rk-logo-img{width:auto;max-width:260px}
.rk-l-dark{display:none}
@media (prefers-color-scheme:dark){.rk-l-light{display:none}.rk-l-dark{display:inline}}
@media print{.rk-l-dark{display:none}.rk-l-light{display:inline}}
.rk-sub{font-weight:500;font-size:13px;color:var(--rk-muted);letter-spacing:0;border-left:1px solid var(--rk-border);padding-left:12px}
.rk-meta{color:var(--rk-muted);font-size:13px;text-align:right}
.rk-btn{font:inherit;font-size:13px;font-weight:600;border:1px solid var(--rk-border);background:var(--rk-surface-alt);color:var(--rk-text);border-radius:6px;padding:5px 10px;cursor:pointer;margin-top:6px}
.rk-btn:hover{border-color:var(--rk-accent)}
a.rk-btn{display:inline-block;text-decoration:none}
.rk-nav{background:var(--rk-surface-alt);border-bottom:1px solid var(--rk-border)}
.rk-nav-in{max-width:1120px;margin:0 auto;padding:0 20px;display:flex;gap:2px;flex-wrap:wrap}
.rk-nav a{padding:11px 14px;text-decoration:none;color:var(--rk-muted);font-weight:600;font-size:14px;border-bottom:3px solid transparent}
.rk-nav a:hover{color:var(--rk-text)}
.rk-nav a[aria-current=page]{color:var(--rk-accent-text);border-bottom-color:var(--rk-accent)}
.rk-main{max-width:1120px;margin:0 auto;padding:26px 20px 40px}
h1{font-size:27px;margin:.1em 0 .15em}
.rk-lead{color:var(--rk-muted);margin:0 0 20px;max-width:760px}
h2{font-size:19px;margin:36px 0 10px;padding-bottom:7px;border-bottom:1px solid var(--rk-border)}
h3{font-size:16px;margin:24px 0 8px}
.muted{color:var(--rk-muted)}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin:12px 0}
.tile{display:block;background:var(--rk-surface);border:1px solid var(--rk-border);border-top:3px solid var(--rk-border);border-radius:8px;padding:12px 14px;text-decoration:none;color:inherit}
a.tile:hover{border-color:var(--rk-accent)}
.tile .v{font-size:25px;font-weight:700;line-height:1.2}
.tile .l{color:var(--rk-muted);font-size:12.5px}
.tile.high{border-top-color:var(--rk-high)}.tile.medium{border-top-color:var(--rk-medium)}.tile.low{border-top-color:var(--rk-low)}.tile.ok{border-top-color:var(--rk-ok)}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px;margin:12px 0}
.card{display:block;background:var(--rk-surface);border:1px solid var(--rk-border);border-radius:8px;padding:14px 16px;text-decoration:none;color:inherit}
a.card:hover{border-color:var(--rk-accent)}
.card b{display:block;color:var(--rk-accent-text);margin-bottom:3px}
.card span{color:var(--rk-muted);font-size:13.5px}
.callout{border-left:4px solid var(--rk-accent);background:var(--rk-surface-alt);padding:10px 14px;border-radius:0 6px 6px 0;margin:14px 0}
.callout.warn{border-left-color:var(--rk-medium)}
.callout ul,.rk-main ul{margin:6px 0;padding-left:20px}
table{border-collapse:collapse;width:100%;font-size:13.5px;background:var(--rk-surface);border:1px solid var(--rk-border)}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--rk-border);vertical-align:top}
th{background:var(--rk-surface-alt);color:var(--rk-muted);font-weight:600;font-size:12.5px}
tr:last-child td{border-bottom:0}
td.num,th.num{text-align:right;white-space:nowrap}
.pill{display:inline-block;padding:1px 9px;border-radius:10px;font-size:12px;font-weight:600;color:#fff;background:var(--rk-muted)}
.pill.high,.pill.failed{background:var(--rk-high)}.pill.medium,.pill.partial{background:var(--rk-medium)}.pill.low{background:var(--rk-low)}.pill.passed,.pill.ok{background:var(--rk-ok)}
.bar{height:9px;background:var(--rk-surface-alt);border-radius:5px;overflow:hidden;min-width:90px;border:1px solid var(--rk-border)}
.bar span{display:block;height:100%;background:var(--rk-accent)}
.rk-ext{font-size:.85em}
.rk-foot{max-width:1120px;margin:0 auto;padding:16px 20px 40px;color:var(--rk-muted);font-size:12.5px;border-top:1px solid var(--rk-border);display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
@media (max-width:700px){table{display:block;overflow-x:auto}.rk-meta{text-align:left}.rk-top-in{padding:12px 14px}.rk-main{padding:18px 14px 30px}}
.tree,.tree ul{list-style:none;margin:0;padding-left:24px;border-left:1px solid var(--rk-border)}
.tree{padding-left:0;border-left:0}
.tree li{margin:8px 0}
.tree .nm{font-weight:600}
.tree .sub .nm{font-weight:500}
.tree .tag{font-size:12.5px;color:var(--rk-muted);margin-left:10px}
.net-card{padding:8px;overflow-x:auto}
.net-svg{width:100%;height:auto;min-width:640px;display:block}
.net-edge{stroke:var(--rk-muted);stroke-width:2.5}
.net-edge.warn{stroke:var(--rk-medium);stroke-dasharray:8 6}
.net-edge.bad{stroke:var(--rk-high);stroke-dasharray:8 6}
.net-node{fill:var(--rk-surface);stroke:var(--rk-border);stroke-width:1.5}
.net-node.hub{stroke:var(--rk-accent);stroke-width:3.5}
.net-node.ext{stroke-dasharray:5 4}
.net-t{fill:var(--rk-text);font:600 15px var(--rk-font)}
.net-s{fill:var(--rk-muted);font:13px var(--rk-font)}
.net-key.warn{color:var(--rk-medium);font-weight:700}
.net-key.bad{color:var(--rk-high);font-weight:700}
.rk-sec{margin-top:36px;padding-top:8px;border-top:1px solid var(--rk-border)}
@media print{.rk-sec{break-before:page;margin-top:0;border-top:0;padding-top:0}.rk-sec:first-of-type{break-before:auto}.rk-nav,.noprint{display:none}body{background:#fff;color:#000}.rk-top{border-top-width:4px}h2,h3{break-after:avoid}table,.tile,.card{break-inside:avoid}a{color:inherit;text-decoration:none}.rk-main{padding-top:10px}}
'@

# The whole CSS file for a theme: variables for light, dark (follows the reader's setting) and print (always light),
# the base style, and last the theme's own custom.css if it exists.
function New-ThemeCss($Theme) {
    $t = $Theme.Data
    $map = [ordered]@{ bg = 'bg'; surface = 'surface'; surfaceAlt = 'surface-alt'; border = 'border'; text = 'text'; muted = 'muted'; accent = 'accent'; accentText = 'accent-text'; onAccent = 'on-accent' }
    $colorVars = { param($c) (($map.Keys | ForEach-Object { '--rk-{0}:{1};' -f $map[$_], $c[$_] }) -join '') }
    $status = (('high', 'medium', 'low', 'ok' | ForEach-Object { '--rk-{0}:{1};' -f $_, $t.colors.status[$_] }) -join '')
    $body = $t.fonts.body
    $heading = if ($t.fonts.heading) { $t.fonts.heading } else { $body }
    $css = ':root{' + (& $colorVars $t.colors.light) + $status + '--rk-font:' + $body + ';--rk-heading-font:' + $heading + ";}`n"
    $css += '@media (prefers-color-scheme:dark){:root{' + (& $colorVars $t.colors.dark) + "}}`n"
    $css += '@media print{:root{' + (& $colorVars $t.colors.light) + "}}`n"
    $css += $script:BaseCss
    # Optional background image (background.file), fixed behind the content with low opacity so that the text stays readable. Not shown when printing.
    if ($t.background -is [hashtable] -and $t.background.file -and $Theme.Dir) {
        try {
            $uri = Get-ThemeImageUri $Theme ([string]$t.background.file) 500
            $op = 0.08
            if ($null -ne $t.background.opacity) { $op = [math]::Min([math]::Max((ConvertTo-Number $t.background.opacity), 0), 1) }
            $css += ("`nbody::before{{content:`"`";position:fixed;inset:0;z-index:-1;pointer-events:none;background:url(`"{0}`") center/cover no-repeat;opacity:{1}}}@media print{{body::before{{display:none}}}}" -f $uri, ([string]$op -replace ',', '.'))
        }
        catch { Add-Warning "The background image of the theme could not be used ($($_.Exception.Message))." }
    }
    if ($t.customCss -and $Theme.Dir) {
        try {
            $full = [IO.Path]::GetFullPath((Join-Path $Theme.Dir ([string]$t.customCss)))
            $root = [IO.Path]::GetFullPath($Theme.Dir).TrimEnd('\') + '\'
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'the file is outside the theme folder' }
            $css += "`n/* custom.css from the theme */`n" + (Get-Content -LiteralPath $full -Raw -Encoding UTF8)
        }
        catch { Add-Warning "The customCss of the theme could not be read ($($_.Exception.Message))." }
    }
    $css
}

# ===========================================================================
# Building blocks for the content
# ===========================================================================

# Link that opens in a new window (the tools' own reports and external addresses).
function New-ExtLink([string]$Href, [string]$Text) {
    '<a href="{0}" target="_blank" rel="noopener noreferrer">{1}<span class="rk-ext" aria-hidden="true"> &#8599;</span></a>' -f (Esc $Href), (Esc $Text)
}
# Relative path from the result folder (for links to files under it).
function Get-RelativeLink([string]$Path) { ($Path.Substring($RunDir.Length + 1)) -replace '\\', '/' }

# Key figure card, optionally as a link to another page.
function Tile($label, $value, $cls = '', $href = $null) {
    $inner = '<div class="v">{0}</div><div class="l">{1}</div>' -f (Esc $value), (Esc $label)
    if ($href) { '<a class="tile {0}" href="{1}">{2}</a>' -f $cls, (Esc $href), $inner } else { '<div class="tile {0}">{1}</div>' -f $cls, $inner }
}

# A small progress bar (0-100 %).
function Get-BarHtml([double]$Percent) {
    $p = [math]::Min([math]::Max($Percent, 0), 100)
    '<div class="bar" role="img" aria-label="{0}"><span style="width:{1}%"></span></div>' -f (Esc (T 'bar.aria' $p)), ([string]([math]::Round($p, 1)) -replace ',', '.')
}

# HTML table of objects. $cols = list of @{Name=<property>; Label=<heading>; Num=$true (right-aligned)}.
function ConvertTo-HtmlTable($rows, $cols, $max = 25) {
    if (-not $rows) { return ('<p class="muted">' + (Esc (T 'table.noRows')) + '</p>') }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $cols) { [void]$sb.Append(('<th{0}>{1}</th>' -f $(if ($c.Num) { ' class="num"' } else { '' }), (Esc $c.Label))) }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in @($rows) | Select-Object -First $max) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) {
            $v = $r.($c.Name)
            $td = if ($c.Num) { '<td class="num">' } else { '<td>' }
            if ($c.ClsFrom) { [void]$sb.Append("$td<span class=`"pill $($r.($c.ClsFrom))`">$(Esc $v)</span></td>") }
            elseif ($c.Name -in 'Impact', 'Result', 'Status') { [void]$sb.Append("$td<span class=`"pill $((([string]$v).ToLower()) -replace '[^a-z]', '')`">$(Esc $v)</span></td>") }
            else { [void]$sb.Append("$td$(Esc $v)</td>") }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    $extra = @($rows).Count - $max
    if ($extra -gt 0) { [void]$sb.Append('<p class="muted">' + (Esc (T 'table.more' $extra)) + '</p>') }
    $sb.ToString()
}

# Table with unknown columns (the tools' own CSV): shows the first columns.
function ConvertTo-GenericTable($rows, [int]$maxCols = 6, [int]$max = 15) {
    $rows = @($rows)
    if (-not $rows.Count) { return ('<p class="muted">' + (Esc (T 'table.noRows')) + '</p>') }
    $names = @($rows[0].PSObject.Properties.Name | Select-Object -First $maxCols)
    ConvertTo-HtmlTable $rows ($names | ForEach-Object { @{ Name = $_; Label = $_ } }) $max
}

# Box with a text (callout). $Warn gives the warning colour.
function New-Callout([string]$Html, [switch]$Warn) { '<div class="callout{0}">{1}</div>' -f $(if ($Warn) { ' warn' } else { '' }), $Html }

# ===========================================================================
# Data: read the tool results once
# ===========================================================================

# A rerun in the same folder leaves the earlier runs' files next to the new ones (AzGovViz and Maester put the time in the file name), so the newest wins.
function Find-ResultFile([string]$Dir, [string]$Filter) { Get-ChildItem -LiteralPath $Dir -Filter $Filter -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime, Name -Descending | Select-Object -First 1 }

function Get-ReportData {
    $d = @{}

    # azqr
    $imp = Find-ResultFile $Dirs.azqr '*.impacted.csv'
    $d.AzqrPresent = [bool]$imp
    if ($imp) {
        $d.AzqrImp = Import-CsvChecked $imp.FullName @('Impact', 'Category', 'Recommendation', 'Resource Name')
        $f = Find-ResultFile $Dirs.azqr '*.inventory.csv'
        $d.AzqrInv = if ($f) { Import-CsvChecked $f.FullName @('Resource Type', 'Subscription Id') } else { $null }
        $f = Find-ResultFile $Dirs.azqr '*.advisor.csv'
        $d.AzqrAdv = if ($f) { Import-CsvChecked $f.FullName @('Impact', 'Category', 'Resource Name', 'Description') } else { $null }
        $d.AzqrXlsx = Find-ResultFile $Dirs.azqr '*.xlsx'
    }

    # Governance Visualizer
    $gvAll = @(Get-ChildItem -LiteralPath $Dirs.azgovviz -Filter 'AzGovViz*.html' -Recurse -ErrorAction SilentlyContinue)
    # The main report is called AzGovViz_<version>_<date>_<time>_<tenant ID>.html. The others (DefinitionInsights, one per subscription)
    # are page reports and can be very large, so do not just pick the first file.
    $d.GvMain = $gvAll | Where-Object { $_.Name -match '_\d{8}_\d{6}_[0-9a-fA-F-]{36}\.html$' } | Sort-Object LastWriteTime, Name -Descending | Select-Object -First 1
    if (-not $d.GvMain) { $d.GvMain = $gvAll | Sort-Object Name | Select-Object -First 1 }
    $d.GvOthers = @($gvAll | Where-Object { $d.GvMain -and $_.FullName -ne $d.GvMain.FullName })
    $d.GvPresent = [bool]$d.GvMain
    if ($d.GvPresent) {
        $get = { param($suffix, $req) $f = Find-ResultFile $Dirs.azgovviz "*_$suffix.csv"; if ($f) { Import-CsvChecked $f.FullName $req ';' } else { $null } }
        $d.GvRoles = Get-UniqueRows (& $get 'RoleAssignments' @('RoleClear', 'ObjectType', 'ScopeTenOrMgOrSubOrRGOrRes')) 'RoleAssignmentId'
        $pa = & $get 'PolicyAssignments' @('PolicyAssignmentDisplayName')
        # The row for the assignment's own scope (thisScope) comes first, so that it is the one that is kept.
        if ($null -ne $pa) { $pa = @($pa | Sort-Object { if ($_.Inheritance -like 'thisScope*') { 0 } else { 1 } }) }
        $d.GvPolicies = Get-UniqueRows $pa 'PolicyAssignmentId'
        $d.GvSubs = & $get 'SubscriptionDetails' @('Subscription', 'ManagementGroupPath')
        $d.GvResources = & $get 'ResourcesAll' @('type', 'name')
        $d.GvCleanup = & $get 'ResourcesCostOptimizationAndCleanup' @()
        $d.GvRoleDefs = & $get 'RoleDefinitions' @('Name', 'Type')
    }

    # Maester
    $d.MaesterPresent = $false
    # The newest TestResults-<time>.json is used (the names sort by time). maester.json is the collector's own summary: it is only a fallback,
    # because it can be left over from an earlier run in the same folder.
    $mFiles = @(Get-ChildItem -LiteralPath $Dirs.maester -Filter '*.json' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*test-results*' })
    $mj = $mFiles | Where-Object Name -like 'TestResults-*.json' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $mj) { $mj = $mFiles | Where-Object Name -eq 'maester.json' | Select-Object -First 1 }
    if ($mj) {
        try {
            $m = Get-Content -LiteralPath $mj.FullName -Raw | ConvertFrom-Json
            $props = @($m.PSObject.Properties.Name)
            $missing = @('PassedCount', 'FailedCount', 'SkippedCount', 'Tests') | Where-Object { $props -notcontains $_ }
            if ($missing) { Add-Warning "maester.json is missing the fields: $($missing -join ', '). The file format may have changed; use Maester's own HTML report." }
            else { $d.Maester = $m; $d.MaesterPresent = $true }
        }
        catch { Add-Warning "maester.json could not be read: $($_.Exception.Message)" }
        # Every Maester run in the same folder leaves its own timestamped TestResults-<time>.html; the name sorts by time, so link to the newest.
        $d.MaesterHtml = Get-ChildItem -LiteralPath $Dirs.maester -Filter '*.html' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*test-results*' } | Sort-Object LastWriteTime, Name -Descending | Select-Object -First 1
    }

    # Defender and cost
    $rd = { param($name, $req) $f = Join-Path $Dirs.portal $name; if (Test-Path -LiteralPath $f) { Import-CsvChecked $f $req } else { $null } }
    $d.Plans = & $rd 'defender-planer.csv' @('Prenumeration', 'Plan', 'Niva')
    $d.Scores = & $rd 'secure-score.csv' @('Prenumeration', 'Poang', 'Max', 'Andel')
    $d.Ctrls = & $rd 'secure-score-kontroller.csv' @('Prenumeration', 'Kontroll', 'Poang', 'Max', 'Osunda', 'Friska')
    $d.Recs = & $rd 'defender-rekommendationer.csv' @('Rekommendation', 'Status', 'Allvarlighet', 'Resurs')
    $d.Costs = & $rd 'kostnad.csv' @('Prenumeration', 'Manad', 'Kostnad', 'Valuta')
    $d.PortalPresent = [bool]($d.Plans -or $d.Scores -or $d.Ctrls -or $d.Recs -or $d.Costs)

    # Structure: management groups and networks (lib\StructurePage.ps1)
    Read-StructureData $d
    $d
}

# ===========================================================================
# Pages
# ===========================================================================

# Shared box for "no data". Both texts are plain text (already translated by the caller).
function New-NoDataHtml([string]$What, [string]$Why) {
    New-Callout ("<b>{0}</b><br>{1}" -f (Esc $What), (Esc $Why)) -Warn
}

# Step states and step names are set by Run-Rapportkit.ps1. Older runs stored Swedish values, so both are mapped to codes.
function Get-StateCode([string]$State) {
    if ($State -in 'Fel', 'Failed') { return 'Failed' }
    if ($State -in 'Delvis', 'Partial') { return 'Partial' }
    if ($State -in 'Hoppad över', 'Skipped') { return 'Skipped' }
    'OK'
}
function Get-StepLabel([string]$Step) {
    if ($Step -in 'Defender och kostnad', 'Defender and cost') { return (T 'step.defender') }
    if ($Step -in 'Struktur', 'Structure') { return (T 'step.structure') }
    $Step
}

# Table with the status of every step of the run.
function Get-StatusTableHtml {
    if (-not $Status.Count) { return '' }
    $cls = @{ OK = 'ok'; Failed = 'failed'; Partial = 'partial'; Skipped = '' }
    $rows = $Status.GetEnumerator() | ForEach-Object {
        $code = Get-StateCode $_.Value.State
        [pscustomobject]@{ Step = Get-StepLabel $_.Key; Status = (T "state.$code"); StatusCls = $cls[$code]; Note = $_.Value.Note }
    }
    '<h2>' + (Esc (T 'status.heading')) + '</h2>' + (ConvertTo-HtmlTable $rows @(@{Name='Step';Label=(T 'col.step')}, @{Name='Status';Label=(T 'col.status');ClsFrom='StatusCls'}, @{Name='Note';Label=(T 'col.note')}))
}

# --- Resources (azqr) --------------------------------------------------------------------------------
function Get-ResourcesPageHtml($d) {
    $sb = [System.Text.StringBuilder]::new()
    if (-not $d.AzqrPresent) { return (New-NoDataHtml (T 'res.none.what') (T 'res.none.why')) }
    $imp = $d.AzqrImp; $inv = $d.AzqrInv
    $xlLink = if ($d.AzqrXlsx) { '<p>' + (Esc (T 'res.fullExcel')) + ' ' + (New-ExtLink (Get-RelativeLink $d.AzqrXlsx.FullName) $d.AzqrXlsx.Name) + '</p>' } else { '' }
    if ($null -eq $imp -or $null -eq $inv) {
        return ((New-Callout (Esc (T 'res.summaryFailed')) -Warn) + $xlLink)
    }
    $subs = @($inv | Select-Object -ExpandProperty 'Subscription Id' -Unique).Count
    $hi = @($imp | Where-Object Impact -eq 'High').Count
    $me = @($imp | Where-Object Impact -eq 'Medium').Count
    $lo = @($imp | Where-Object Impact -eq 'Low').Count
    [void]$sb.Append('<div class="tiles">' + (Tile (T 'tile.resources') @($inv).Count) + (Tile (T 'tile.subscriptions') $subs) + (Tile (T 'tile.highImpact') $hi 'high') + (Tile (T 'tile.medium') $me 'medium') + (Tile (T 'tile.low') $lo 'low') + '</div>')

    $byType = $inv | Group-Object 'Resource Type' | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Typ = $_.Name; Antal = $_.Count } }
    [void]$sb.Append('<h2>' + (Esc (T 'res.byType')) + '</h2>' + (ConvertTo-HtmlTable $byType @(@{Name='Typ';Label=(T 'col.resourceType')}, @{Name='Antal';Label=(T 'col.count');Num=$true}) 15))

    $byCat = $imp | Group-Object Category | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Kategori = $_.Name; Antal = $_.Count } }
    [void]$sb.Append('<h2>' + (Esc (T 'res.byCategory')) + '</h2>' + (ConvertTo-HtmlTable $byCat @(@{Name='Kategori';Label=(T 'col.category')}, @{Name='Antal';Label=(T 'col.count');Num=$true})))

    $topRec = $imp | Where-Object Impact -eq 'High' | Group-Object Recommendation | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Impact = 'High'; Rekommendation = $_.Name; Resurser = $_.Count; Exempel = ($_.Group | Select-Object -First 3 -ExpandProperty 'Resource Name') -join ', ' } }
    [void]$sb.Append('<h2>' + (Esc (T 'res.highRecs')) + '</h2>' + (ConvertTo-HtmlTable $topRec @(@{Name='Impact';Label=(T 'col.impact')}, @{Name='Rekommendation';Label=(T 'col.recommendation')}, @{Name='Resurser';Label=(T 'col.resources');Num=$true}, @{Name='Exempel';Label=(T 'col.example')}) 20))

    if ($null -ne $d.AzqrAdv) {
        $adv = $d.AzqrAdv
        $advSorted = $adv | Sort-Object { switch ($_.Impact) { 'High' { 0 } 'Medium' { 1 } default { 2 } } }
        [void]$sb.Append('<h2>' + (Esc (T 'res.advisor' @($adv).Count)) + '</h2>' + (ConvertTo-HtmlTable $advSorted @(@{Name='Impact';Label=(T 'col.impact')}, @{Name='Category';Label=(T 'col.category')}, @{Name='Resource Name';Label=(T 'col.resource')}, @{Name='Description';Label=(T 'col.description')}) 15))
    }
    [void]$sb.Append('<h2>' + (Esc (T 'heading.deepDive')) + '</h2>' + $xlLink + '<p class="muted">' + (Esc (T 'res.excelNote')) + '</p>')
    $sb.ToString()
}

# --- Governance (Governance Visualizer) --------------------------------------------------------------
function Get-GovernancePageHtml($d) {
    if (-not $d.GvPresent) { return (New-NoDataHtml (T 'gov.none.what') (T 'gov.none.why')) }
    $sb = [System.Text.StringBuilder]::new()
    $roles = $d.GvRoles; $pols = $d.GvPolicies; $subs = $d.GvSubs; $res = $d.GvResources
    [void]$sb.Append('<div class="tiles">')
    if ($null -ne $subs) { [void]$sb.Append((Tile (T 'tile.subscriptions') @($subs).Count)) }
    if ($null -ne $roles) { [void]$sb.Append((Tile (T 'tile.roleAssignments') @($roles).Count)) }
    if ($null -ne $pols) { [void]$sb.Append((Tile (T 'tile.policyAssignments') @($pols).Count)) }
    if ($null -ne $res) { [void]$sb.Append((Tile (T 'tile.resources') @($res).Count)) }
    if ($null -ne $d.GvRoleDefs) { [void]$sb.Append((Tile (T 'tile.customRoles') @($d.GvRoleDefs | Where-Object { $_.Type -eq 'CustomRole' }).Count)) }
    [void]$sb.Append('</div>')

    if ($null -ne $subs -and @($subs).Count) {
        $cols = @(@{Name='Subscription';Label=(T 'col.subscription')}, @{Name='ManagementGroupPath';Label=(T 'col.mgPath')})
        foreach ($opt in @(@('QuotaId', (T 'col.quota')), @('MDfCScore', (T 'col.defenderScore')), @('AdvisorScore', (T 'col.advisorScore')))) { if ($subs[0].PSObject.Properties.Name -contains $opt[0]) { $cols += @{ Name = $opt[0]; Label = $opt[1] } } }
        [void]$sb.Append('<h2>' + (Esc (T 'heading.subscriptions')) + '</h2>' + (ConvertTo-HtmlTable $subs $cols 25))
    }

    if ($null -ne $roles -and @($roles).Count) {
        $byRole = $roles | Group-Object RoleClear | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Roll = $_.Name; Antal = $_.Count } }
        $byType = $roles | Group-Object ObjectType | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Typ = $_.Name; Antal = $_.Count } }
        [void]$sb.Append('<h2>' + (Esc (T 'gov.roleAssignments')) + '</h2><div class="cards" style="grid-template-columns:repeat(auto-fit,minmax(320px,1fr))"><div><h3>' + (Esc (T 'gov.perRole')) + '</h3>' + (ConvertTo-HtmlTable $byRole @(@{Name='Roll';Label=(T 'col.role')}, @{Name='Antal';Label=(T 'col.count');Num=$true}) 12) + '</div><div><h3>' + (Esc (T 'gov.perAccountType')) + '</h3>' + (ConvertTo-HtmlTable $byType @(@{Name='Typ';Label=(T 'col.type')}, @{Name='Antal';Label=(T 'col.count');Num=$true}) 12) + '</div></div>')

        # Privileged assignments: the ones that give the greatest ability to change things or give others access.
        $priv = @($roles | Where-Object { $_.RoleClear -in 'Owner', 'User Access Administrator', 'Contributor' })
        if ($priv.Count) {
            $privView = $priv | ForEach-Object {
                $who = if ($_.ObjectType -eq 'User' -and $HidePersonalData) { (T 'gov.hidden') } else { $_.ObjectDisplayName }
                [pscustomobject]@{ Roll = $_.RoleClear; Niva = $_.ScopeTenOrMgOrSubOrRGOrRes; Scope = $_.RoleAssignmentScopeName; Typ = $_.ObjectType; Konto = $who }
            } | Sort-Object @{ Expression = { switch ($_.Roll) { 'Owner' { 0 } 'User Access Administrator' { 1 } default { 2 } } } }, Niva
            $hiddenNote = if ($HidePersonalData) { ' ' + (T 'gov.priv.hiddenNote') } else { '' }
            [void]$sb.Append('<h3>' + (Esc (T 'gov.priv.heading' $priv.Count)) + '</h3><p class="muted">' + (Esc ((T 'gov.priv.text') + $hiddenNote)) + '</p>' + (ConvertTo-HtmlTable $privView @(@{Name='Roll';Label=(T 'col.role')}, @{Name='Niva';Label=(T 'col.level')}, @{Name='Scope';Label=(T 'col.scope')}, @{Name='Typ';Label=(T 'col.type')}, @{Name='Konto';Label=(T 'col.account')}) 25))
        }
    }

    if ($null -ne $pols -and @($pols).Count) {
        $polView = $pols | ForEach-Object {
            [pscustomobject]@{ Namn = $_.PolicyAssignmentDisplayName; Niva = $_.Level; Effekt = $_.Effect; Tvingande = $_.PolicyAssignmentEnforcementMode; Overtradelser = [int](ConvertTo-Number $_.NonCompliantResources) }
        } | Sort-Object Overtradelser -Descending
        [void]$sb.Append('<h2>' + (Esc (T 'gov.policyAssignments')) + '</h2>' + (ConvertTo-HtmlTable $polView @(@{Name='Namn';Label=(T 'col.policy')}, @{Name='Niva';Label=(T 'col.level')}, @{Name='Effekt';Label=(T 'col.effect')}, @{Name='Tvingande';Label=(T 'col.enforcement')}, @{Name='Overtradelser';Label=(T 'col.nonCompliant');Num=$true}) 20))
    }

    if ($null -ne $res -and @($res).Count) {
        $byType = $res | Group-Object type | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Typ = $_.Name; Antal = $_.Count } }
        $tagged = @($res | Where-Object { $_.PSObject.Properties.Name -contains 'tags' -and $_.tags -and $_.tags -ne '{}' -and $_.tags -ne 'null' }).Count
        $pct = if (@($res).Count) { 100 * $tagged / @($res).Count } else { 0 }
        [void]$sb.Append('<h2>' + (Esc (T 'gov.resourcesTagging')) + '</h2>' + (ConvertTo-HtmlTable $byType @(@{Name='Typ';Label=(T 'col.resourceType')}, @{Name='Antal';Label=(T 'col.count');Num=$true}) 12))
        [void]$sb.Append('<h3>' + (Esc (T 'gov.taggedResources')) + '</h3><p>' + (Esc (T 'gov.taggedText' $tagged @($res).Count ('{0:N0}' -f $pct))) + '</p>' + (Get-BarHtml $pct))
    }

    if ($null -ne $d.GvCleanup -and @($d.GvCleanup).Count) {
        [void]$sb.Append('<h2>' + (Esc (T 'gov.cleanup' @($d.GvCleanup).Count)) + '</h2><p class="muted">' + (Esc (T 'gov.cleanupText')) + '</p>' + (ConvertTo-GenericTable $d.GvCleanup 6 15))
    }

    [void]$sb.Append('<h2>' + (Esc (T 'heading.deepDive')) + '</h2><p>' + (Esc (T 'gov.deepDiveText')) + '</p><ul><li>' + (New-ExtLink (Get-RelativeLink $d.GvMain.FullName) $d.GvMain.Name) + '</li></ul>')
    [void]$sb.Append((New-Callout (T 'gov.note.html')))
    if ($d.GvOthers.Count) { [void]$sb.Append('<p class="muted">' + (Esc (T 'gov.otherPages' $d.GvOthers.Count)) + '</p>') }
    $sb.ToString()
}

# --- Entra ID (Maester) ------------------------------------------------------------------------------
function Get-EntraPageHtml($d) {
    if (-not $d.MaesterPresent) { return (New-NoDataHtml (T 'entra.none.what') (T 'entra.none.why')) }
    $m = $d.Maester
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<div class="tiles">' + (Tile (T 'tile.passed') $m.PassedCount 'ok') + (Tile (T 'tile.failed') $m.FailedCount 'high') + (Tile (T 'tile.skipped') $m.SkippedCount) + '</div>')
    $failed = @($m.Tests | Where-Object Result -eq 'Failed' | Select-Object -First 40 | ForEach-Object { [pscustomobject]@{ Result = 'Failed'; Test = $_.Name } })
    [void]$sb.Append('<h2>' + (Esc (T 'entra.failedTests')) + '</h2>' + (ConvertTo-HtmlTable $failed @(@{Name='Result';Label=(T 'col.result')}, @{Name='Test';Label=(T 'col.test')}) 40))

    # Tests that were skipped: give the reason (usually licensing), so the reader knows what was NOT checked.
    $skipped = @($m.Tests | Where-Object Result -eq 'Skipped')
    if ($skipped.Count) {
        $products = @{
            NotLicensedEntraIDP1 = 'Entra ID P1'; NotLicensedEntraIDP2 = 'Entra ID P2'
            NotLicensedEntraIDGovernance = 'Entra ID Governance'; NotLicensedEntraIDP2OrGovernance = (T 'entra.p2OrGovernance')
            NotLicensedEntraWorkloadID = 'Entra Workload ID'; NotLicensedIntune = 'Intune'
            NotLicensedEop = 'Exchange Online Protection'; NotLicensedMdo = 'Defender for Office 365'
            NotLicensedMdoP1 = 'Defender for Office 365 P1'; NotLicensedMdoP2 = 'Defender for Office 365 P2'
            NotLicensedExoDlp = 'Exchange DLP'; NotLicensedAdvAudit = 'Advanced Auditing'
            NotLicensedDefenderXDR = 'Defender XDR'; NotLicensedCustomerLockbox = 'Customer Lockbox'
        }
        $unknown = T 'entra.unknownReason'
        $skipRows = $skipped | Group-Object {
            $dd = $_.ResultDetail
            $k = if ($dd -and $dd.TestSkipped) { [string]$dd.TestSkipped } else { $unknown }
            # Free text from the test ("Custom") is used as the reason; markdown links [text](url) are shortened to text.
            if ($k -eq 'Custom' -and $dd.SkippedReason) { ([string]$dd.SkippedReason) -replace '\[([^\]]+)\]\([^)]+\)', '$1' } else { $k }
        } | Sort-Object Count -Descending | ForEach-Object {
            $reason = if ($products.ContainsKey($_.Name)) { T 'entra.notLicensed' $products[$_.Name] } elseif ($_.Name -eq 'Error') { T 'entra.testError' } else { $_.Name }
            [pscustomobject]@{ Orsak = $reason; Antal = $_.Count; Exempel = ($_.Group | Select-Object -First 2 -ExpandProperty Name) -join '; ' }
        }
        $licSkipped = @($skipped | Where-Object { $_.ResultDetail.TestSkipped -like 'NotLicensed*' }).Count
        [void]$sb.Append('<h2>' + (Esc (T 'entra.skippedHeading' $skipped.Count)) + '</h2>' + (New-Callout (T 'entra.skippedNote.html' $licSkipped)) + (ConvertTo-HtmlTable $skipRows @(@{Name='Orsak';Label=(T 'col.reason')}, @{Name='Antal';Label=(T 'col.count');Num=$true}, @{Name='Exempel';Label=(T 'col.exampleTest')}) 25))
    }
    [void]$sb.Append('<h2>' + (Esc (T 'heading.deepDive')) + '</h2>')
    if ($d.MaesterHtml) { [void]$sb.Append('<p>' + (Esc (T 'entra.deepDiveText')) + ' ' + (New-ExtLink (Get-RelativeLink $d.MaesterHtml.FullName) $d.MaesterHtml.Name) + '</p>') }
    $sb.ToString()
}

# --- Defender and cost -------------------------------------------------------------------------------
function Get-DefenderCostPageHtml($d) {
    if (-not $d.PortalPresent) { return (New-NoDataHtml (T 'def.none.what') (T 'def.none.why')) }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<div class="tiles">')
    foreach ($r in @($d.Scores)) {
        if ($null -eq $r) { continue }
        $pct = [math]::Round((ConvertTo-Number $r.Andel) * 100)
        [void]$sb.Append((Tile (T 'tile.secureScoreFor' $r.Prenumeration) ('{0} % ({1}/{2})' -f $pct, $r.Poang, $r.Max)))
    }
    if ($null -ne $d.Plans) { $on = @($d.Plans | Where-Object Niva -eq 'Standard').Count; [void]$sb.Append((Tile (T 'tile.plansOn') (T 'fmt.xOfY' $on @($d.Plans).Count) $(if ($on -eq 0) { 'medium' } else { 'ok' }))) }
    if ($null -ne $d.Recs) {
        $unh = @($d.Recs | Where-Object Status -eq 'Unhealthy')
        [void]$sb.Append((Tile (T 'tile.recsHigh') @($unh | Where-Object Allvarlighet -eq 'High').Count 'high') + (Tile (T 'tile.medium') @($unh | Where-Object Allvarlighet -eq 'Medium').Count 'medium') + (Tile (T 'tile.low') @($unh | Where-Object Allvarlighet -eq 'Low').Count 'low'))
    }
    if ($null -ne $d.Costs -and @($d.Costs).Count) {
        foreach ($g in ($d.Costs | Group-Object Valuta)) {
            $tot = ($g.Group | ForEach-Object { ConvertTo-Number $_.Kostnad } | Measure-Object -Sum).Sum
            [void]$sb.Append((Tile (T 'tile.cost12' $g.Name) ('{0:N0}' -f $tot)))
        }
    }
    [void]$sb.Append('</div>')

    if ($null -ne $d.Ctrls -and @($d.Ctrls).Count) {
        $ctrlView = @($d.Ctrls | Where-Object { [int](ConvertTo-Number $_.Max) -gt 0 -or [int](ConvertTo-Number $_.Osunda) -gt 0 } | Sort-Object { -[int](ConvertTo-Number $_.Osunda) }, Kontroll | ForEach-Object {
                [pscustomobject]@{ Kontroll = $_.Kontroll; Poang = (T 'fmt.xOfY' $_.Poang $_.Max); Osunda = $_.Osunda; Friska = $_.Friska } })
        [void]$sb.Append('<h2>' + (Esc (T 'def.controls')) + '</h2><p class="muted">' + (Esc (T 'def.controlsText')) + '</p>' + (ConvertTo-HtmlTable $ctrlView @(@{Name='Kontroll';Label=(T 'col.control')}, @{Name='Poang';Label=(T 'col.score');Num=$true}, @{Name='Osunda';Label=(T 'col.unhealthy');Num=$true}, @{Name='Friska';Label=(T 'col.healthy');Num=$true}) 30))
    }
    if ($null -ne $d.Plans -and @($d.Plans).Count) {
        $planView = $d.Plans | ForEach-Object { [pscustomobject]@{ Prenumeration = $_.Prenumeration; Plan = $_.Plan; Status = $(if ($_.Niva -eq 'Standard') { T 'state.on' } else { T 'state.off' }) } }
        [void]$sb.Append('<h2>' + (Esc (T 'def.plans')) + '</h2>' + (ConvertTo-HtmlTable $planView @(@{Name='Prenumeration';Label=(T 'col.subscription')}, @{Name='Plan';Label=(T 'col.plan')}, @{Name='Status';Label=(T 'col.status')}) 40))
    }
    if ($null -ne $d.Recs -and @($d.Recs | Where-Object Status -eq 'Unhealthy').Count) {
        $sevOrder = @{ High = 0; Medium = 1; Low = 2 }
        $recView = @($d.Recs | Where-Object Status -eq 'Unhealthy' | Sort-Object { if ($sevOrder.ContainsKey($_.Allvarlighet)) { $sevOrder[$_.Allvarlighet] } else { 3 } } |
                ForEach-Object { [pscustomobject]@{ Impact = $_.Allvarlighet; Rekommendation = $_.Rekommendation; Resurs = ($_.Resurs -split '/')[-1] } })
        [void]$sb.Append('<h2>' + (Esc (T 'def.recs')) + '</h2>' + (ConvertTo-HtmlTable $recView @(@{Name='Impact';Label=(T 'col.severity')}, @{Name='Rekommendation';Label=(T 'col.recommendation')}, @{Name='Resurs';Label=(T 'col.resource')}) 25))
    }
    if ($null -ne $d.Costs -and @($d.Costs).Count) {
        [void]$sb.Append('<h2>' + (Esc (T 'def.costPerMonth')) + '</h2>')
        foreach ($g in ($d.Costs | Group-Object Valuta)) {
            $months = $g.Group | Group-Object Manad | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Manad = $_.Name; Summa = ($_.Group | ForEach-Object { ConvertTo-Number $_.Kostnad } | Measure-Object -Sum).Sum } }
            $max = ($months | Measure-Object Summa -Maximum).Maximum
            $rows = ($months | ForEach-Object { '<tr><td>{0}</td><td class="num">{1:N0}</td><td>{2}</td></tr>' -f (Esc $_.Manad), $_.Summa, (Get-BarHtml $(if ($max) { 100 * $_.Summa / $max } else { 0 })) }) -join ''
            [void]$sb.Append(('<table><thead><tr><th>{0}</th><th class="num">{1}</th><th>{2}</th></tr></thead><tbody>{3}</tbody></table>' -f (Esc (T 'col.month')), (Esc (T 'col.costIn' $g.Name)), (Esc (T 'col.distribution')), $rows))
        }
        $multi = @($d.Costs | Select-Object -ExpandProperty Prenumeration -Unique).Count
        if ($multi -gt 1) { [void]$sb.Append('<p class="muted">' + (Esc (T 'def.costAllSubs' $multi)) + '</p>') }
    }
    [void]$sb.Append('<p class="muted">' + (Esc (T 'def.footer')) + '</p>')
    $sb.ToString()
}

# --- About the run -----------------------------------------------------------------------------------
function Get-AboutPageHtml($d, $Theme) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((Get-StatusTableHtml))
    if ($Warnings.Count) { [void]$sb.Append('<h2>' + (Esc (T 'about.warnings')) + '</h2><ul>' + (($Warnings | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul>') }

    [void]$sb.Append('<h2>' + (Esc (T 'about.limits')) + '</h2>')
    $lim = [System.Collections.Generic.List[string]]::new()
    $lim.Add((T 'limit.summary'))
    foreach ($k in $Status.Keys) {
        $s = $Status[$k]
        $label = Get-StepLabel $k
        switch (Get-StateCode $s.State) {
            'Skipped' { $lim.Add((T 'limit.skipped' $label)) }
            'Failed' { $lim.Add((T 'limit.failed' $label $s.Note)) }
            'Partial' { $lim.Add((T 'limit.partial' $label $s.Note)) }
        }
    }
    $lim.Add((T 'limit.govviz'))
    $lim.Add((T 'limit.defenderRecs'))
    $lim.Add((T 'limit.cost'))
    if ($HidePersonalData) { $lim.Add((T 'limit.hidePersonal')) }
    else { $lim.Add((T 'limit.personal')) }
    [void]$sb.Append('<ul>' + (($lim | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul>')

    $toolVersions = if ($LatestTools) { T 'about.toolsLatest' } else { T 'about.toolsTested' $GvVersion $Pins.Azqr $Pins.Maester $Pins.Pester $Pins.AzAccounts }
    $meta = @(
        [pscustomobject]@{ Falt = (T 'about.kit'); Varde = "v$KitVersion" },
        [pscustomobject]@{ Falt = (T 'about.ran'); Varde = $script:RunStart.ToString('yyyy-MM-dd HH:mm') },
        [pscustomobject]@{ Falt = 'Tenant'; Varde = $TenantId },
        [pscustomobject]@{ Falt = (T 'about.toolVersions'); Varde = $toolVersions },
        [pscustomobject]@{ Falt = (T 'about.installed'); Varde = ('Maester {0}, Az.Accounts {1}' -f (Get-ModuleVersionText 'Maester'), (Get-ModuleVersionText 'Az.Accounts')) },
        [pscustomobject]@{ Falt = (T 'about.computer'); Varde = ('PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString) },
        [pscustomobject]@{ Falt = (T 'about.theme'); Varde = ('{0} ({1})' -f $Theme.Data.name, $Theme.Source) }
    )
    [void]$sb.Append('<h2>' + (Esc (T 'about.heading')) + '</h2>' + (ConvertTo-HtmlTable $meta @(@{Name='Falt';Label=(T 'col.field')}, @{Name='Varde';Label=(T 'col.value')}) 20))
    [void]$sb.Append((New-Callout (Esc (T 'about.readOnly'))))

    [void]$sb.Append('<h2>' + (Esc (T 'about.files')) + '</h2>' + (T 'about.files.html'))
    $sb.ToString()
}

# --- Overview ----------------------------------------------------------------------------------------
function Get-OverviewPageHtml($d, $Pages) {
    $sb = [System.Text.StringBuilder]::new()
    $file = @{}; foreach ($p in $Pages) { $file[$p.Key] = $p.File }

    [void]$sb.Append('<div class="tiles">')
    if ($d.AzqrPresent -and $null -ne $d.AzqrInv -and $null -ne $d.AzqrImp) {
        [void]$sb.Append((Tile (T 'tile.resources') @($d.AzqrInv).Count '' $file.resurser))
        [void]$sb.Append((Tile (T 'tile.highImpactAzqr') @($d.AzqrImp | Where-Object Impact -eq 'High').Count 'high' $file.resurser))
        [void]$sb.Append((Tile (T 'tile.mediumAzqr') @($d.AzqrImp | Where-Object Impact -eq 'Medium').Count 'medium' $file.resurser))
    }
    if ($d.GvPresent) {
        if ($null -ne $d.GvRoles) { [void]$sb.Append((Tile (T 'tile.roleAssignments') @($d.GvRoles).Count '' $file.styrning)) }
        if ($null -ne $d.GvPolicies) { [void]$sb.Append((Tile (T 'tile.policyAssignments') @($d.GvPolicies).Count '' $file.styrning)) }
    }
    if ($d.Vnets) {
        [void]$sb.Append((Tile (T 'tile.vnets') @($d.Vnets | Where-Object { $_ }).Count '' $file.struktur))
    }
    if ($d.MaesterPresent) {
        [void]$sb.Append((Tile (T 'tile.entraPassed') $d.Maester.PassedCount 'ok' $file.entra))
        [void]$sb.Append((Tile (T 'tile.entraFailed') $d.Maester.FailedCount 'high' $file.entra))
    }
    $sc = @($d.Scores) | Select-Object -First 1
    if ($sc) { [void]$sb.Append((Tile (T 'tile.secureScore') ('{0} %' -f [math]::Round((ConvertTo-Number $sc.Andel) * 100)) '' $file.defender)) }
    if ($null -ne $d.Costs -and @($d.Costs).Count) {
        foreach ($g in ($d.Costs | Group-Object Valuta | Select-Object -First 1)) { [void]$sb.Append((Tile (T 'tile.cost12short' $g.Name) ('{0:N0}' -f (($g.Group | ForEach-Object { ConvertTo-Number $_.Kostnad } | Measure-Object -Sum).Sum)) '' $file.defender)) }
    }
    [void]$sb.Append('</div>')

    # Automatic observations: no judgement, only what shows in the numbers.
    $obs = [System.Collections.Generic.List[string]]::new()
    if ($d.AzqrPresent -and $null -ne $d.AzqrImp) {
        $hi = @($d.AzqrImp | Where-Object Impact -eq 'High')
        if ($hi.Count) { $top = ($hi | Group-Object Recommendation | Sort-Object Count -Descending | Select-Object -First 1).Name; $obs.Add((T 'obs.azqr.html' $hi.Count (Esc $top) $file.resurser)) }
    }
    if ($d.MaesterPresent -and [int]$d.Maester.FailedCount -gt 0) {
        $first = ($d.Maester.Tests | Where-Object Result -eq 'Failed' | Select-Object -First 1).Name
        $obs.Add((T 'obs.entra.html' $d.Maester.FailedCount (Esc $first) $file.entra))
    }
    if ($null -ne $d.Ctrls) {
        $worst = $d.Ctrls | Sort-Object { -[int](ConvertTo-Number $_.Osunda) } | Select-Object -First 1
        if ($worst -and [int](ConvertTo-Number $worst.Osunda) -gt 0) { $obs.Add((T 'obs.defenderControl.html' (Esc $worst.Kontroll) $worst.Osunda $worst.Poang $worst.Max $file.defender)) }
    }
    if ($null -ne $d.Plans) { $on = @($d.Plans | Where-Object Niva -eq 'Standard').Count; $obs.Add((T 'obs.defenderPlans.html' $on @($d.Plans).Count)) }
    if ($d.GvPresent -and $null -ne $d.GvRoles) {
        $priv = @($d.GvRoles | Where-Object { $_.RoleClear -in 'Owner', 'User Access Administrator' }).Count
        if ($priv) { $obs.Add((T 'obs.governance.html' $priv $file.styrning)) }
    }
    if ($d.Vnets) {
        $m = Get-NetworkModel $d
        $iso = @($m.Vnets | Where-Object { $m.Role[([string]$_.Id).ToLower()] -eq 'Isolated' }).Count
        $notConn = @($m.Edges | Where-Object State -eq 'bad').Count
        if ($iso -or $notConn -or $m.Overlaps.Count) { $obs.Add((T 'obs.network.html' $iso $notConn $m.Overlaps.Count $file.struktur)) }
    }
    if ($Warnings.Count) { $obs.Add((T 'obs.warnings.html' $Warnings.Count $file.om)) }
    if ($obs.Count) { [void]$sb.Append('<h2>' + (Esc (T 'overview.standsOut')) + '</h2><p class="muted">' + (Esc (T 'overview.standsOutText')) + '</p><ul>' + (($obs | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>') }

    [void]$sb.Append('<h2>' + (Esc (T 'overview.pages')) + '</h2><div class="cards">')
    foreach ($p in $Pages) { if ($p.Key -ne 'oversikt') { [void]$sb.Append(('<a class="card" href="{0}"><b>{1}</b><span>{2}</span></a>' -f (Esc $p.File), (Esc $p.Title), (Esc (T "desc.$($p.Key)")))) } }
    [void]$sb.Append('</div>')

    [void]$sb.Append((Get-StatusTableHtml))
    $sb.ToString()
}

# ===========================================================================
# Page template and orchestration
# ===========================================================================

# A complete HTML page: header with logo, navigation, content and footer. CSS and logo are embedded.
function New-ReportPageHtml($Ctx, [string]$ActiveKey, [string]$Title, [string]$Lead, [string]$Content) {
    $nav = (($Ctx.Pages | ForEach-Object { '<a href="{0}"{1}>{2}</a>' -f (Esc $_.File), $(if ($_.Key -eq $ActiveKey) { ' aria-current="page"' } else { '' }), (Esc $_.Title) }) -join '')
    $t = $Ctx.Theme.Data
    $contact = ''
    if ($t.contact -is [hashtable] -and $t.contact.text) {
        $contact = if ($t.contact.url -and ([string]$t.contact.url) -match '^https?://') { New-ExtLink ([string]$t.contact.url) ([string]$t.contact.text) } else { Esc $t.contact.text }
    }
    $footLeft = (@((Esc $t.footer), $contact) | Where-Object { $_ }) -join ' &middot; '
    $sub = if ($t.reportTitle) { '<span class="rk-sub">{0}</span>' -f (Esc $t.reportTitle) } else { '' }
    # The button always gives the whole report: on the single pages the combined document opens in a new window and the print dialog is shown there.
    $printBtn = if ($ActiveKey -eq 'komplett') {
        '<button class="rk-btn noprint" type="button" onclick="window.print()">' + (Esc (T 'btn.printAll')) + '</button>'
    } else {
        '<a class="rk-btn noprint" href="rapport-komplett.html#skriv" target="_blank" rel="noopener noreferrer">' + (Esc (T 'btn.saveAll')) + '</a>'
    }
    $tenantShown = if ($Ctx.Anon) { T 'page.anonymized' } else { $TenantId }
    $banner = if ($Ctx.Banner) { $Ctx.Banner } else { '' }
    $autoPrint = if ($ActiveKey -eq 'komplett') { '<script>if(location.hash==="#skriv"){window.addEventListener("load",function(){setTimeout(function(){window.print()},400)})}</script>' } else { '' }
    @"
<!doctype html>
<html lang="$(Esc $script:LangCode)"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="robots" content="noindex">
<title>$(Esc $Title) - $(Esc $t.reportTitle) $(Esc $Period)</title>
<style>
$($Ctx.Css)
</style></head><body>
<header class="rk-top"><div class="rk-top-in">
<div class="rk-logo">$($Ctx.LogoHtml)$sub</div>
<div class="rk-meta">Tenant $(Esc $tenantShown)<br>$(Esc (T 'page.period')) $(Esc $Period) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm')<br>$printBtn</div>
</div></header>
<nav class="rk-nav" aria-label="$(Esc (T 'page.navLabel'))"><div class="rk-nav-in">$nav</div></nav>
<main class="rk-main">
<h1>$(Esc $Title)</h1>
<p class="rk-lead">$(Esc $Lead)</p>
$banner
$Content
</main>
<footer class="rk-foot"><span>$footLeft</span><span>$(Esc (T 'page.footer' $KitVersion))</span></footer>
$autoPrint
</body></html>
"@
}

# Chooses the report language: -ReportLanguage, else "language" in the theme, else English.
function Resolve-ReportLanguage($Theme) {
    $code = ''
    if ($ReportLanguage) { $code = [string]$ReportLanguage }
    elseif ($Theme.Data.language) { $code = [string]$Theme.Data.language }
    if (-not $code) { $code = 'en' }
    $code
}

# Builds the whole report and writes the pages in the result folder. Returns the path of the start page (rapport.html).
function Write-ReportSite {
    $theme = Get-BrandTheme $BrandingDir     # $BrandingDir is only set by the tests; otherwise branding\ is used
    $lang = Initialize-Language (Resolve-ReportLanguage $theme)
    $pages = @(
        @{ Key = 'oversikt'; File = 'rapport.html' },
        @{ Key = 'struktur'; File = 'rapport-struktur.html' },
        @{ Key = 'styrning'; File = 'rapport-styrning.html' },
        @{ Key = 'resurser'; File = 'rapport-resurser.html' },
        @{ Key = 'entra'; File = 'rapport-entra.html' },
        @{ Key = 'defender'; File = 'rapport-defender-kostnad.html' },
        @{ Key = 'om'; File = 'rapport-om.html' }
    ) | ForEach-Object { $_.Title = T "page.$($_.Key).title"; $_.Lead = T "page.$($_.Key).lead"; $_ }
    $ctx = @{ Theme = $theme; Pages = $pages; Css = (New-ThemeCss $theme); LogoHtml = (Get-LogoHtml $theme) }
    Write-Action ('Report theme: {0} ({1}), language: {2}' -f $theme.Data.name, $theme.Source, $lang)

    $d = Get-ReportData
    $builders = @{
        oversikt = { Get-OverviewPageHtml $d $pages }
        struktur = { Get-StructurePageHtml $d }
        styrning = { Get-GovernancePageHtml $d }
        resurser = { Get-ResourcesPageHtml $d }
        entra    = { Get-EntraPageHtml $d }
        defender = { Get-DefenderCostPageHtml $d }
        om       = { Get-AboutPageHtml $d $theme }
    }
    # "About the run" is built last, so that warnings raised while the other pages are built are included.
    $order = 'struktur', 'styrning', 'resurser', 'entra', 'defender', 'oversikt', 'om'
    $content = @{}
    foreach ($key in $order) {
        try { $content[$key] = (& $builders[$key]) -join '' }
        catch { Add-Warning "The report page '$key' could not be built: $($_.Exception.Message)"; $content[$key] = New-NoDataHtml (T 'page.buildFailed') $_.Exception.Message }
    }
    $index = $null
    foreach ($p in $pages) {
        $html = New-ReportPageHtml $ctx $p.Key $p.Title $p.Lead $content[$p.Key]
        $path = Join-Path $RunDir $p.File
        Set-Content -LiteralPath $path -Value $html -Encoding utf8
        if ($p.Key -eq 'oversikt') { $index = $path }
    }
    # All pages in one document (for PDF/print). Every section starts on a new page when printed.
    try {
        $all = ($pages | ForEach-Object { '<section class="rk-sec"><h1>{0}</h1><p class="rk-lead">{1}</p>{2}</section>' -f (Esc $_.Title), (Esc $_.Lead), $content[$_.Key] }) -join "`n"
        $full = New-ReportPageHtml $ctx 'komplett' (T 'page.complete.title') (T 'page.complete.lead') $all
        Set-Content -LiteralPath (Join-Path $RunDir 'rapport-komplett.html') -Value $full -Encoding utf8
    }
    catch { Add-Warning "The combined report (PDF version) could not be built: $($_.Exception.Message)" }

    # Anonymized version: separate pages in anonym\ where names, e-mail addresses and IDs are replaced by aliases.
    if ($Anonymize) {
        try {
            Write-Action 'Building the anonymized version (anonym\)'
            Register-AnonData $d
            $anonDir = Join-Path $RunDir 'anonym'
            New-Item -ItemType Directory -Force $anonDir | Out-Null
            $ctxA = @{ Theme = $theme; Pages = $pages; Css = $ctx.Css; LogoHtml = $ctx.LogoHtml; Anon = $true
                Banner = (New-Callout (T 'anon.banner.html' ((Esc (T 'anon.user')) + ' 3'))) }
            $contentA = @{}
            foreach ($p in $pages) { $contentA[$p.Key] = ConvertTo-AnonymousHtml $content[$p.Key] }
            foreach ($p in $pages) {
                Set-Content -LiteralPath (Join-Path $anonDir $p.File) -Value (New-ReportPageHtml $ctxA $p.Key $p.Title $p.Lead $contentA[$p.Key]) -Encoding utf8
            }
            $allA = ($pages | ForEach-Object { '<section class="rk-sec"><h1>{0}</h1><p class="rk-lead">{1}</p>{2}</section>' -f (Esc $_.Title), (Esc $_.Lead), $contentA[$_.Key] }) -join "`n"
            Set-Content -LiteralPath (Join-Path $anonDir 'rapport-komplett.html') -Value (New-ReportPageHtml $ctxA 'komplett' (T 'page.complete.title') (T 'page.complete.lead') $allA) -Encoding utf8
            Write-Ok ('Anonymized report: {0}' -f (Join-Path $anonDir 'rapport.html'))
        }
        catch { Add-Warning "The anonymized version could not be built: $($_.Exception.Message)" }
    }
    $index
}
