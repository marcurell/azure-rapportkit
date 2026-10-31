<#
  Rapportgenerator för Azure Rapportkit.

  Bygger en flersidig HTML-rapport i en gemensam stil av verktygens resultat (azqr, Governance Visualizer, Maester,
  Defender och kostnad). Verktygens egna rapporter går inte att göra om (Governance Visualizer hämtar sin CSS, sina skript
  och sina ikoner från en server på internet, och Maester har sin egen mall och logga), så rapporten sammanställer datan
  på egna sidor och länkar till verktygens rapporter som fördjupning, i nytt fönster.

  Utseendet styrs av ett tema (branding\<namn>\theme.json, se branding\README.md): färger, typsnitt, logga och sidfot.
  Varje sida är fristående (CSS och logga ligger inbäddade), så den går att öppna utan att resten finns.

  Filen läses in (dot-source) av Run-Rapportkit.ps1 i steg 10 och använder dess variabler ($Dirs, $RunDir, $Status,
  $Warnings, $TenantId, $Period, ...) och funktioner (Import-CsvChecked, Add-Warning, Write-Action). Startpunkt:
  Write-ReportSite.
#>

Add-Type -AssemblyName System.Web

# ===========================================================================
# Hjälpare
# ===========================================================================

# HTML-koda text och attribut. (Får inte heta H: det är ett alias för Get-History.)
function Esc($s) { [System.Web.HttpUtility]::HtmlEncode([string]$s) }

# Gör om JSON-objekt (PSCustomObject) till hashtables, så att de går att slå ihop och indexera.
function ConvertTo-Hashtable($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) { $h = @{}; foreach ($k in $o.Keys) { $h[$k] = ConvertTo-Hashtable $o[$k] }; return $h }
    if ($o -is [System.Management.Automation.PSCustomObject]) { $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }; return $h }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return , @($o | ForEach-Object { ConvertTo-Hashtable $_ }) }
    return $o
}

# Lägger värdena i $Over ovanpå $Base (rekursivt för underhashtables).
function Merge-Hashtable([hashtable]$Base, [hashtable]$Over) {
    foreach ($k in @($Over.Keys)) {
        if ($Base.ContainsKey($k) -and $Base[$k] -is [hashtable] -and $Over[$k] -is [hashtable]) { Merge-Hashtable $Base[$k] $Over[$k] }
        else { $Base[$k] = $Over[$k] }
    }
}

# Godkänner bara färgvärden som inte kan bryta ut ur CSS: #hex, rgb()/hsl() och färgnamn.
function Test-CssColor($v) { ([string]$v) -match '^(#[0-9a-fA-F]{3,8}|(rgb|hsl)a?\([0-9\s,./%-]+\)|[a-zA-Z]{3,20})$' }
# Godkänner bara typsnittslistor med bokstäver, siffror, mellanslag, komma, citattecken, punkt och bindestreck.
function Test-CssFont($v) { ([string]$v) -match '^[\w\s,"''.\-]{1,200}$' }

# Behåller första raden per värde i kolumnen $Key. Governance Visualizers CSV upprepar samma tilldelning på flera nivåer
# (ärvda vyer), så antalet rader blir större än antalet unika tilldelningar.
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

# Tal från CSV (kan ha decimalkomma) till double.
function ConvertTo-Number($v) {
    $s = ([string]$v) -replace ',', '.' -replace '\s', ''
    $d = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $d } else { 0.0 }
}

# ===========================================================================
# Tema
# ===========================================================================

# Inbyggt reservtema: används om temat saknas eller är ogiltigt, och som mall för vilka värden som måste finnas.
$script:DefaultThemeJson = @'
{
  "name": "Neutral",
  "reportTitle": "Azure Rapportkit",
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
  "customCss": ""
}
'@

# Läser temat: -BrandPath (en mapp) eller -Brand (en mapp under branding\). Värden som saknas fylls i från reservtemat, och
# ogiltiga färger och typsnitt byts ut (med varning). Ger @{ Data; Dir; Source }. Ger aldrig fel: i värsta fall används reservtemat.
function Get-BrandTheme([string]$Brand, [string]$BrandPath) {
    $default = { ConvertTo-Hashtable ($script:DefaultThemeJson | ConvertFrom-Json) }
    $theme = & $default
    $dir = $null
    $source = 'inbyggd standard'
    if ($BrandPath) { $dir = $BrandPath }
    elseif ($Brand) {
        if ($Brand -notmatch '^[A-Za-z0-9_-]+$') { Add-Warning "Ogiltigt temanamn '$Brand' (bara bokstäver, siffror, - och _). Använder inbyggd standard." }
        else { $dir = Join-Path (Join-Path $ScriptRoot 'branding') $Brand }
    }
    if ($dir) {
        $file = Join-Path $dir 'theme.json'
        if (Test-Path -LiteralPath $file) {
            try {
                $custom = ConvertTo-Hashtable (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
                Merge-Hashtable $theme $custom
                $source = $dir
            }
            catch { Add-Warning "Temat i $dir kunde inte läsas ($($_.Exception.Message)). Använder inbyggd standard."; $theme = & $default; $dir = $null }
        }
        else { Add-Warning "Hittade inget tema i $dir (theme.json saknas). Använder inbyggd standard."; $dir = $null }
    }

    # Validera färger och typsnitt mot reservtemat. Ogiltigt eller saknat värde byts ut.
    $def = & $default
    try {
        foreach ($mode in 'light', 'dark') {
            foreach ($k in @($def.colors[$mode].Keys)) {
                $v = $theme.colors[$mode][$k]
                if (-not (Test-CssColor $v)) { Add-Warning "Temat: ogiltig färg colors.$mode.$k ('$v'). Använder standardvärdet."; $theme.colors[$mode][$k] = $def.colors[$mode][$k] }
            }
        }
        foreach ($k in @($def.colors.status.Keys)) {
            $v = $theme.colors.status[$k]
            if (-not (Test-CssColor $v)) { Add-Warning "Temat: ogiltig färg colors.status.$k ('$v'). Använder standardvärdet."; $theme.colors.status[$k] = $def.colors.status[$k] }
        }
        foreach ($k in 'body', 'heading') {
            $v = $theme.fonts[$k]
            if ($v -and -not (Test-CssFont $v)) { Add-Warning "Temat: ogiltigt typsnitt fonts.$k. Använder standardvärdet."; $theme.fonts[$k] = $def.fonts[$k] }
        }
    }
    catch {
        Add-Warning "Temat har fel struktur ($($_.Exception.Message)). Använder inbyggd standard."
        $theme = & $default; $dir = $null; $source = 'inbyggd standard'
    }
    @{ Data = $theme; Dir = $dir; Source = $source }
}

# Loggan som HTML: en bildfil från temamappen (inbäddad som data-URI) eller en ordbild av färgade textdelar.
function Get-LogoHtml($Theme) {
    $t = $Theme.Data
    $logo = $t.logo
    if ($logo -is [hashtable] -and $logo.type -eq 'image' -and $logo.file -and $Theme.Dir) {
        try {
            $full = [IO.Path]::GetFullPath((Join-Path $Theme.Dir ([string]$logo.file)))
            $root = [IO.Path]::GetFullPath($Theme.Dir).TrimEnd('\') + '\'
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'filen ligger utanför temamappen' }
            $mime = switch ([IO.Path]::GetExtension($full).ToLower()) { '.svg' { 'image/svg+xml' } '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.gif' { 'image/gif' } '.webp' { 'image/webp' } default { $null } }
            if (-not $mime) { throw 'filtypen stöds inte (använd svg, png, jpg, gif eller webp)' }
            if ((Get-Item -LiteralPath $full).Length -gt 300KB) { throw 'filen är större än 300 KB' }
            $height = 36
            if ($logo.height) { $height = [int][math]::Min([math]::Max([double]$logo.height, 16), 80) }
            return ('<img class="rk-logo-img" src="data:{0};base64,{1}" alt="{2}" style="height:{3}px">' -f $mime, [Convert]::ToBase64String([IO.File]::ReadAllBytes($full)), (Esc $logo.alt), $height)
        }
        catch { Add-Warning "Temats logga kunde inte användas ($($_.Exception.Message)). Visar namnet som ordbild." }
    }
    $parts = @()
    if ($logo -is [hashtable] -and $logo.parts) { $parts = @($logo.parts) }
    if (-not $parts.Count) { $parts = @(@{ text = $t.name; color = 'text' }) }
    # Alla delar i ETT element, så att de hänger ihop utan glapp (loggan är en flex-container).
    '<span class="rk-wm">' + (($parts | ForEach-Object {
                $cls = switch ([string]$_.color) { 'accent' { 'rk-w-accent' } 'accentText' { 'rk-w-accenttext' } 'muted' { 'rk-w-muted' } default { '' } }
                '<span class="{0}">{1}</span>' -f $cls, (Esc $_.text)
            }) -join '') + '</span>'
}

# Grundläggande stil. Alla färger och typsnitt kommer från variablerna som temat sätter (--rk-*).
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
.pill.high,.pill.failed,.pill.fel,.pill.saknas{background:var(--rk-high)}.pill.medium,.pill.delvis{background:var(--rk-medium)}.pill.low{background:var(--rk-low)}.pill.passed,.pill.ok,.pill.klar{background:var(--rk-ok)}
.bar{height:9px;background:var(--rk-surface-alt);border-radius:5px;overflow:hidden;min-width:90px;border:1px solid var(--rk-border)}
.bar span{display:block;height:100%;background:var(--rk-accent)}
.rk-ext{font-size:.85em}
.rk-foot{max-width:1120px;margin:0 auto;padding:16px 20px 40px;color:var(--rk-muted);font-size:12.5px;border-top:1px solid var(--rk-border);display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
@media (max-width:700px){table{display:block;overflow-x:auto}.rk-meta{text-align:left}.rk-top-in{padding:12px 14px}.rk-main{padding:18px 14px 30px}}
.rk-sec{margin-top:36px;padding-top:8px;border-top:1px solid var(--rk-border)}
@media print{.rk-sec{break-before:page;margin-top:0;border-top:0;padding-top:0}.rk-sec:first-of-type{break-before:auto}.rk-nav,.noprint{display:none}body{background:#fff;color:#000}.rk-top{border-top-width:4px}h2,h3{break-after:avoid}table,.tile,.card{break-inside:avoid}a{color:inherit;text-decoration:none}.rk-main{padding-top:10px}}
'@

# Hela CSS-filen för ett tema: variabler för ljust, mörkt (följer läsarens inställning) och utskrift (alltid ljust),
# grundstilen, och sist temats egen custom.css om den finns.
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
    if ($t.customCss -and $Theme.Dir) {
        try {
            $full = [IO.Path]::GetFullPath((Join-Path $Theme.Dir ([string]$t.customCss)))
            $root = [IO.Path]::GetFullPath($Theme.Dir).TrimEnd('\') + '\'
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'filen ligger utanför temamappen' }
            $css += "`n/* custom.css från temat */`n" + (Get-Content -LiteralPath $full -Raw -Encoding UTF8)
        }
        catch { Add-Warning "Temats customCss kunde inte läsas ($($_.Exception.Message))." }
    }
    $css
}

# ===========================================================================
# Byggstenar för innehållet
# ===========================================================================

# Länk som öppnas i nytt fönster (verktygens egna rapporter och externa adresser).
function New-ExtLink([string]$Href, [string]$Text) {
    '<a href="{0}" target="_blank" rel="noopener noreferrer">{1}<span class="rk-ext" aria-hidden="true"> &#8599;</span></a>' -f (Esc $Href), (Esc $Text)
}
# Relativ sökväg från resultatmappen (för länkar till filer under den).
function Get-RelativeLink([string]$Path) { ($Path.Substring($RunDir.Length + 1)) -replace '\\', '/' }

# Nyckeltalskort, valfritt som länk till en annan sida.
function Tile($label, $value, $cls = '', $href = $null) {
    $inner = '<div class="v">{0}</div><div class="l">{1}</div>' -f (Esc $value), (Esc $label)
    if ($href) { '<a class="tile {0}" href="{1}">{2}</a>' -f $cls, (Esc $href), $inner } else { '<div class="tile {0}">{1}</div>' -f $cls, $inner }
}

# En liten förloppsstapel (0-100 %).
function Get-BarHtml([double]$Percent) {
    $p = [math]::Min([math]::Max($Percent, 0), 100)
    '<div class="bar" role="img" aria-label="{0:N0} procent"><span style="width:{1}%"></span></div>' -f $p, ([string]([math]::Round($p, 1)) -replace ',', '.')
}

# HTML-tabell av objekt. $cols = lista med @{Name=<egenskap>; Label=<rubrik>; Num=$true (högerställd)}.
function ConvertTo-HtmlTable($rows, $cols, $max = 25) {
    if (-not $rows) { return '<p class="muted">Inga rader.</p>' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $cols) { [void]$sb.Append(('<th{0}>{1}</th>' -f $(if ($c.Num) { ' class="num"' } else { '' }), (Esc $c.Label))) }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in @($rows) | Select-Object -First $max) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) {
            $v = $r.($c.Name)
            $td = if ($c.Num) { '<td class="num">' } else { '<td>' }
            if ($c.Name -in 'Impact', 'Result', 'Status') { [void]$sb.Append("$td<span class=`"pill $((([string]$v).ToLower()) -replace '[^a-z]', '')`">$(Esc $v)</span></td>") }
            else { [void]$sb.Append("$td$(Esc $v)</td>") }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    $extra = @($rows).Count - $max
    if ($extra -gt 0) { [void]$sb.Append("<p class=`"muted`">…och $extra rader till (se de fullständiga filerna).</p>") }
    $sb.ToString()
}

# Tabell med okända kolumner (verktygens egna CSV): visar de första kolumnerna.
function ConvertTo-GenericTable($rows, [int]$maxCols = 6, [int]$max = 15) {
    $rows = @($rows)
    if (-not $rows.Count) { return '<p class="muted">Inga rader.</p>' }
    $names = @($rows[0].PSObject.Properties.Name | Select-Object -First $maxCols)
    ConvertTo-HtmlTable $rows ($names | ForEach-Object { @{ Name = $_; Label = $_ } }) $max
}

# Ruta med en text (callout). $Warn ger varningsfärg.
function New-Callout([string]$Html, [switch]$Warn) { '<div class="callout{0}">{1}</div>' -f $(if ($Warn) { ' warn' } else { '' }), $Html }

# ===========================================================================
# Data: läs verktygens resultat en gång
# ===========================================================================

function Find-ResultFile([string]$Dir, [string]$Filter) { Get-ChildItem -LiteralPath $Dir -Filter $Filter -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 }

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
    # Huvudrapporten heter AzGovViz_<version>_<datum>_<tid>_<tenant-ID>.html. Övriga (DefinitionInsights, en per prenumeration)
    # är sidorapporter och kan vara mycket stora, så välj inte bara första bästa fil.
    $d.GvMain = $gvAll | Where-Object { $_.Name -match '_\d{8}_\d{6}_[0-9a-fA-F-]{36}\.html$' } | Select-Object -First 1
    if (-not $d.GvMain) { $d.GvMain = $gvAll | Sort-Object Name | Select-Object -First 1 }
    $d.GvOthers = @($gvAll | Where-Object { $d.GvMain -and $_.FullName -ne $d.GvMain.FullName })
    $d.GvPresent = [bool]$d.GvMain
    if ($d.GvPresent) {
        $get = { param($suffix, $req) $f = Find-ResultFile $Dirs.azgovviz "*_$suffix.csv"; if ($f) { Import-CsvChecked $f.FullName $req ';' } else { $null } }
        $d.GvRoles = Get-UniqueRows (& $get 'RoleAssignments' @('RoleClear', 'ObjectType', 'ScopeTenOrMgOrSubOrRGOrRes')) 'RoleAssignmentId'
        $pa = & $get 'PolicyAssignments' @('PolicyAssignmentDisplayName')
        # Raden för tilldelningens eget scope (thisScope) går först, så att den är den som behålls.
        if ($null -ne $pa) { $pa = @($pa | Sort-Object { if ($_.Inheritance -like 'thisScope*') { 0 } else { 1 } }) }
        $d.GvPolicies = Get-UniqueRows $pa 'PolicyAssignmentId'
        $d.GvSubs = & $get 'SubscriptionDetails' @('Subscription', 'ManagementGroupPath')
        $d.GvResources = & $get 'ResourcesAll' @('type', 'name')
        $d.GvCleanup = & $get 'ResourcesCostOptimizationAndCleanup' @()
        $d.GvRoleDefs = & $get 'RoleDefinitions' @('Name', 'Type')
    }

    # Maester
    $d.MaesterPresent = $false
    $mj = Get-ChildItem -LiteralPath $Dirs.maester -Filter '*.json' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*test-results*' } | Select-Object -First 1
    if ($mj) {
        try {
            $m = Get-Content -LiteralPath $mj.FullName -Raw | ConvertFrom-Json
            $props = @($m.PSObject.Properties.Name)
            $missing = @('PassedCount', 'FailedCount', 'SkippedCount', 'Tests') | Where-Object { $props -notcontains $_ }
            if ($missing) { Add-Warning "maester.json saknar fälten: $($missing -join ', '). Filformatet kan ha ändrats; använd Maesters egen HTML-rapport." }
            else { $d.Maester = $m; $d.MaesterPresent = $true }
        }
        catch { Add-Warning "maester.json kunde inte läsas: $($_.Exception.Message)" }
        $d.MaesterHtml = Get-ChildItem -LiteralPath $Dirs.maester -Filter '*.html' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    # Defender och kostnad
    $rd = { param($name, $req) $f = Join-Path $Dirs.portal $name; if (Test-Path -LiteralPath $f) { Import-CsvChecked $f $req } else { $null } }
    $d.Plans = & $rd 'defender-planer.csv' @('Prenumeration', 'Plan', 'Niva')
    $d.Scores = & $rd 'secure-score.csv' @('Prenumeration', 'Poang', 'Max', 'Andel')
    $d.Ctrls = & $rd 'secure-score-kontroller.csv' @('Prenumeration', 'Kontroll', 'Poang', 'Max', 'Osunda', 'Friska')
    $d.Recs = & $rd 'defender-rekommendationer.csv' @('Rekommendation', 'Status', 'Allvarlighet', 'Resurs')
    $d.Costs = & $rd 'kostnad.csv' @('Prenumeration', 'Manad', 'Kostnad', 'Valuta')
    $d.PortalPresent = [bool]($d.Plans -or $d.Scores -or $d.Ctrls -or $d.Recs -or $d.Costs)
    $d
}

# ===========================================================================
# Sidor
# ===========================================================================

# Gemensam rubrik för "inget underlag".
function New-NoDataHtml([string]$What, [string]$Why) {
    New-Callout ("<b>{0}</b><br>{1}" -f (Esc $What), (Esc $Why)) -Warn
}

# --- Resurser (azqr) ---------------------------------------------------------------------------------
function Get-ResourcesPageHtml($d) {
    $sb = [System.Text.StringBuilder]::new()
    if (-not $d.AzqrPresent) { return (New-NoDataHtml 'azqr har inte körts eller gav inget resultat.' 'Se körningsstatus på sidan Om körningen.') }
    $imp = $d.AzqrImp; $inv = $d.AzqrInv
    $xlLink = if ($d.AzqrXlsx) { '<p>Fullständig rapport (Excel): ' + (New-ExtLink (Get-RelativeLink $d.AzqrXlsx.FullName) $d.AzqrXlsx.Name) + '</p>' } else { '' }
    if ($null -eq $imp -or $null -eq $inv) {
        return ((New-Callout 'Kunde inte sammanfatta azqr-resultatet (se varningar). Använd den fullständiga rapporten.' -Warn) + $xlLink)
    }
    $subs = @($inv | Select-Object -ExpandProperty 'Subscription Id' -Unique).Count
    $hi = @($imp | Where-Object Impact -eq 'High').Count
    $me = @($imp | Where-Object Impact -eq 'Medium').Count
    $lo = @($imp | Where-Object Impact -eq 'Low').Count
    [void]$sb.Append('<div class="tiles">' + (Tile 'Resurser' @($inv).Count) + (Tile 'Prenumerationer' $subs) + (Tile 'Hög påverkan' $hi 'high') + (Tile 'Medel' $me 'medium') + (Tile 'Låg' $lo 'low') + '</div>')

    $byType = $inv | Group-Object 'Resource Type' | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Typ = $_.Name; Antal = $_.Count } }
    [void]$sb.Append('<h2>Resurser per typ</h2>' + (ConvertTo-HtmlTable $byType @(@{Name='Typ';Label='Resurstyp'}, @{Name='Antal';Label='Antal';Num=$true}) 15))

    $byCat = $imp | Group-Object Category | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Kategori = $_.Name; Antal = $_.Count } }
    [void]$sb.Append('<h2>Avvikelser per kategori</h2>' + (ConvertTo-HtmlTable $byCat @(@{Name='Kategori';Label='Kategori'}, @{Name='Antal';Label='Antal';Num=$true})))

    $topRec = $imp | Where-Object Impact -eq 'High' | Group-Object Recommendation | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Impact = 'High'; Rekommendation = $_.Name; Resurser = $_.Count; Exempel = ($_.Group | Select-Object -First 3 -ExpandProperty 'Resource Name') -join ', ' } }
    [void]$sb.Append('<h2>Rekommendationer med hög påverkan</h2>' + (ConvertTo-HtmlTable $topRec @(@{Name='Impact';Label='Påverkan'}, @{Name='Rekommendation';Label='Rekommendation'}, @{Name='Resurser';Label='Resurser';Num=$true}, @{Name='Exempel';Label='Exempel'}) 20))

    if ($null -ne $d.AzqrAdv) {
        $adv = $d.AzqrAdv
        $advSorted = $adv | Sort-Object { switch ($_.Impact) { 'High' { 0 } 'Medium' { 1 } default { 2 } } }
        [void]$sb.Append("<h2>Azure Advisor ($(@($adv).Count) rekommendationer)</h2>" + (ConvertTo-HtmlTable $advSorted @(@{Name='Impact';Label='Påverkan'}, @{Name='Category';Label='Kategori'}, @{Name='Resource Name';Label='Resurs'}, @{Name='Description';Label='Beskrivning'}) 15))
    }
    [void]$sb.Append('<h2>Fördjupning</h2>' + $xlLink + '<p class="muted">Excel-filen innehåller alla rekommendationer, inventering, Defender-status och Advisor i fulla tabeller.</p>')
    $sb.ToString()
}

# --- Styrning (Governance Visualizer) -----------------------------------------------------------------
function Get-GovernancePageHtml($d) {
    if (-not $d.GvPresent) { return (New-NoDataHtml 'Governance Visualizer har inte körts eller gav inget resultat.' 'Se körningsstatus på sidan Om körningen. Vanlig orsak: Reader saknas på Tenant Root Group.') }
    $sb = [System.Text.StringBuilder]::new()
    $roles = $d.GvRoles; $pols = $d.GvPolicies; $subs = $d.GvSubs; $res = $d.GvResources
    [void]$sb.Append('<div class="tiles">')
    if ($null -ne $subs) { [void]$sb.Append((Tile 'Prenumerationer' @($subs).Count)) }
    if ($null -ne $roles) { [void]$sb.Append((Tile 'Rolltilldelningar' @($roles).Count)) }
    if ($null -ne $pols) { [void]$sb.Append((Tile 'Policytilldelningar' @($pols).Count)) }
    if ($null -ne $res) { [void]$sb.Append((Tile 'Resurser' @($res).Count)) }
    if ($null -ne $d.GvRoleDefs) { [void]$sb.Append((Tile 'Egna roller' @($d.GvRoleDefs | Where-Object { $_.Type -eq 'CustomRole' }).Count)) }
    [void]$sb.Append('</div>')

    if ($null -ne $subs -and @($subs).Count) {
        $cols = @(@{Name='Subscription';Label='Prenumeration'}, @{Name='ManagementGroupPath';Label='Management group-sökväg'})
        foreach ($opt in @(@('QuotaId', 'Typ (quota)'), @('MDfCScore', 'Defender-poäng'), @('AdvisorScore', 'Advisor-poäng'))) { if ($subs[0].PSObject.Properties.Name -contains $opt[0]) { $cols += @{ Name = $opt[0]; Label = $opt[1] } } }
        [void]$sb.Append('<h2>Prenumerationer</h2>' + (ConvertTo-HtmlTable $subs $cols 25))
    }

    if ($null -ne $roles -and @($roles).Count) {
        $byRole = $roles | Group-Object RoleClear | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Roll = $_.Name; Antal = $_.Count } }
        $byType = $roles | Group-Object ObjectType | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Typ = $_.Name; Antal = $_.Count } }
        [void]$sb.Append('<h2>Rolltilldelningar</h2><div class="cards" style="grid-template-columns:repeat(auto-fit,minmax(320px,1fr))"><div><h3>Per roll</h3>' + (ConvertTo-HtmlTable $byRole @(@{Name='Roll';Label='Roll'}, @{Name='Antal';Label='Antal';Num=$true}) 12) + '</div><div><h3>Per typ av konto</h3>' + (ConvertTo-HtmlTable $byType @(@{Name='Typ';Label='Typ'}, @{Name='Antal';Label='Antal';Num=$true}) 12) + '</div></div>')

        # Privilegierade tilldelningar: de som ger största möjligheten att ändra eller ge andra åtkomst.
        $priv = @($roles | Where-Object { $_.RoleClear -in 'Owner', 'User Access Administrator', 'Contributor' })
        if ($priv.Count) {
            $privView = $priv | ForEach-Object {
                $who = if ($_.ObjectType -eq 'User' -and $HidePersonalData) { '(dolt)' } else { $_.ObjectDisplayName }
                [pscustomobject]@{ Roll = $_.RoleClear; Niva = $_.ScopeTenOrMgOrSubOrRGOrRes; Scope = $_.RoleAssignmentScopeName; Typ = $_.ObjectType; Konto = $who }
            } | Sort-Object @{ Expression = { switch ($_.Roll) { 'Owner' { 0 } 'User Access Administrator' { 1 } default { 2 } } } }, Niva
            [void]$sb.Append("<h3>Privilegierade tilldelningar ($($priv.Count))</h3><p class=`"muted`">Owner, User Access Administrator och Contributor. Granska att varje tilldelning behövs.$(if ($HidePersonalData) { ' Användarnamn är dolda (-HidePersonalData).' })</p>" + (ConvertTo-HtmlTable $privView @(@{Name='Roll';Label='Roll'}, @{Name='Niva';Label='Nivå'}, @{Name='Scope';Label='Scope'}, @{Name='Typ';Label='Typ'}, @{Name='Konto';Label='Konto'}) 25))
        }
    }

    if ($null -ne $pols -and @($pols).Count) {
        $polView = $pols | ForEach-Object {
            [pscustomobject]@{ Namn = $_.PolicyAssignmentDisplayName; Niva = $_.Level; Effekt = $_.Effect; Tvingande = $_.PolicyAssignmentEnforcementMode; Overtradelser = [int](ConvertTo-Number $_.NonCompliantResources) }
        } | Sort-Object Overtradelser -Descending
        [void]$sb.Append('<h2>Policytilldelningar</h2>' + (ConvertTo-HtmlTable $polView @(@{Name='Namn';Label='Policy'}, @{Name='Niva';Label='Nivå'}, @{Name='Effekt';Label='Effekt'}, @{Name='Tvingande';Label='Tvingande'}, @{Name='Overtradelser';Label='Resurser som bryter mot policyn';Num=$true}) 20))
    }

    if ($null -ne $res -and @($res).Count) {
        $byType = $res | Group-Object type | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Typ = $_.Name; Antal = $_.Count } }
        $tagged = @($res | Where-Object { $_.PSObject.Properties.Name -contains 'tags' -and $_.tags -and $_.tags -ne '{}' -and $_.tags -ne 'null' }).Count
        $pct = if (@($res).Count) { 100 * $tagged / @($res).Count } else { 0 }
        [void]$sb.Append('<h2>Resurser och taggning</h2>' + (ConvertTo-HtmlTable $byType @(@{Name='Typ';Label='Resurstyp'}, @{Name='Antal';Label='Antal';Num=$true}) 12))
        [void]$sb.Append(('<h3>Taggade resurser</h3><p>{0} av {1} resurser har minst en tagg ({2:N0} %).</p>' -f $tagged, @($res).Count, $pct) + (Get-BarHtml $pct))
    }

    if ($null -ne $d.GvCleanup -and @($d.GvCleanup).Count) {
        [void]$sb.Append("<h2>Optimering och städning ($(@($d.GvCleanup).Count))</h2><p class=`"muted`">Resurser som verktyget bedömer kan städas bort eller optimeras (till exempel oanvända diskar och nätverkskort).</p>" + (ConvertTo-GenericTable $d.GvCleanup 6 15))
    }

    [void]$sb.Append('<h2>Fördjupning</h2><p>Governance Visualizers egen, interaktiva rapport (hierarkikarta, alla policys och roller):</p><ul><li>' + (New-ExtLink (Get-RelativeLink $d.GvMain.FullName) $d.GvMain.Name) + '</li></ul>')
    [void]$sb.Append((New-Callout '<b>Obs:</b> Governance Visualizers egen rapport är inte fristående. När den öppnas hämtar webbläsaren dess formatmall, skript och ikoner från internet (bland annat <code>www.azadvertizer.net</code>, <code>cdnjs.cloudflare.com</code> och <code>code.jquery.com</code>). Utan internetåtkomst blir den ofullständig. Sammanställningen på den här sidan hämtar ingenting från internet.'))
    if ($d.GvOthers.Count) { [void]$sb.Append("<p class=`"muted`">Verktyget skapade även $($d.GvOthers.Count) sidorapporter (till exempel DefinitionInsights) i mappen azgovviz\.</p>") }
    $sb.ToString()
}

# --- Entra ID (Maester) -------------------------------------------------------------------------------
function Get-EntraPageHtml($d) {
    if (-not $d.MaesterPresent) { return (New-NoDataHtml 'Maester har inte körts eller gav inget resultat.' 'Maester är valfritt och kräver att en administratör godkänt Graph-behörigheterna. Se körningsstatus på sidan Om körningen.') }
    $m = $d.Maester
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<div class="tiles">' + (Tile 'Godkända' $m.PassedCount 'ok') + (Tile 'Underkända' $m.FailedCount 'high') + (Tile 'Överhoppade' $m.SkippedCount) + '</div>')
    $failed = @($m.Tests | Where-Object Result -eq 'Failed' | Select-Object -First 40 | ForEach-Object { [pscustomobject]@{ Result = 'Failed'; Test = $_.Name } })
    [void]$sb.Append('<h2>Underkända tester</h2>' + (ConvertTo-HtmlTable $failed @(@{Name='Result';Label='Resultat'}, @{Name='Test';Label='Test'}) 40))

    # Tester som hoppades över: ange orsaken (oftast licens), så att läsaren vet vad som INTE kontrollerats.
    $skipped = @($m.Tests | Where-Object Result -eq 'Skipped')
    if ($skipped.Count) {
        $labels = @{
            NotLicensedEntraIDP1 = 'Licens saknas: Entra ID P1'; NotLicensedEntraIDP2 = 'Licens saknas: Entra ID P2'
            NotLicensedEntraIDGovernance = 'Licens saknas: Entra ID Governance'; NotLicensedEntraIDP2OrGovernance = 'Licens saknas: Entra ID P2 eller Governance'
            NotLicensedEntraWorkloadID = 'Licens saknas: Entra Workload ID'; NotLicensedIntune = 'Licens saknas: Intune'
            NotLicensedEop = 'Licens saknas: Exchange Online Protection'; NotLicensedMdo = 'Licens saknas: Defender for Office 365'
            NotLicensedMdoP1 = 'Licens saknas: Defender for Office 365 P1'; NotLicensedMdoP2 = 'Licens saknas: Defender for Office 365 P2'
            NotLicensedExoDlp = 'Licens saknas: Exchange DLP'; NotLicensedAdvAudit = 'Licens saknas: Advanced Auditing'
            NotLicensedDefenderXDR = 'Licens saknas: Defender XDR'; NotLicensedCustomerLockbox = 'Licens saknas: Customer Lockbox'
            Error = 'Testet kunde inte köras (fel)'
        }
        $skipRows = $skipped | Group-Object {
            $dd = $_.ResultDetail
            $k = if ($dd -and $dd.TestSkipped) { [string]$dd.TestSkipped } else { 'Okänd orsak' }
            # Fri text från testet ("Custom") används som orsak; markdown-länkar [text](url) kortas till text.
            if ($k -eq 'Custom' -and $dd.SkippedReason) { ([string]$dd.SkippedReason) -replace '\[([^\]]+)\]\([^)]+\)', '$1' } else { $k }
        } | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{ Orsak = $(if ($labels.ContainsKey($_.Name)) { $labels[$_.Name] } else { $_.Name }); Antal = $_.Count; Exempel = ($_.Group | Select-Object -First 2 -ExpandProperty Name) -join '; ' }
        }
        $licSkipped = @($skipped | Where-Object { $_.ResultDetail.TestSkipped -like 'NotLicensed*' }).Count
        [void]$sb.Append("<h2>Tester som inte kunde köras ($($skipped.Count))</h2>" + (New-Callout "Dessa kontroller ingår <b>inte</b> i resultatet. $licSkipped av dem beror på att tenanten saknar en licens (till exempel Entra ID P1/P2) och resten på att funktionen inte är aktiverad eller inte gick att läsa. Det säger alltså inget om huruvida inställningen är bra eller dålig.") + (ConvertTo-HtmlTable $skipRows @(@{Name='Orsak';Label='Orsak'}, @{Name='Antal';Label='Antal';Num=$true}, @{Name='Exempel';Label='Exempel på test'}) 25))
    }
    [void]$sb.Append('<h2>Fördjupning</h2>')
    if ($d.MaesterHtml) { [void]$sb.Append('<p>Maesters egen rapport med alla tester och åtgärdsförslag: ' + (New-ExtLink (Get-RelativeLink $d.MaesterHtml.FullName) $d.MaesterHtml.Name) + '</p>') }
    $sb.ToString()
}

# --- Defender och kostnad -----------------------------------------------------------------------------
function Get-DefenderCostPageHtml($d) {
    if (-not $d.PortalPresent) { return (New-NoDataHtml 'Ingen Defender- eller kostnadsdata hämtades.' 'Rollerna Security Reader och Cost Management Reader behövs. Se körningsstatus på sidan Om körningen.') }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<div class="tiles">')
    foreach ($r in @($d.Scores)) {
        if ($null -eq $r) { continue }
        $pct = [math]::Round((ConvertTo-Number $r.Andel) * 100)
        [void]$sb.Append((Tile "Secure Score ($($r.Prenumeration))" ('{0} % ({1}/{2})' -f $pct, $r.Poang, $r.Max)))
    }
    if ($null -ne $d.Plans) { $on = @($d.Plans | Where-Object Niva -eq 'Standard').Count; [void]$sb.Append((Tile 'Defender-planer påslagna' "$on av $(@($d.Plans).Count)" $(if ($on -eq 0) { 'medium' } else { 'ok' }))) }
    if ($null -ne $d.Recs) {
        $unh = @($d.Recs | Where-Object Status -eq 'Unhealthy')
        [void]$sb.Append((Tile 'Rekommendationer: hög' @($unh | Where-Object Allvarlighet -eq 'High').Count 'high') + (Tile 'Medel' @($unh | Where-Object Allvarlighet -eq 'Medium').Count 'medium') + (Tile 'Låg' @($unh | Where-Object Allvarlighet -eq 'Low').Count 'low'))
    }
    if ($null -ne $d.Costs -and @($d.Costs).Count) {
        foreach ($g in ($d.Costs | Group-Object Valuta)) {
            $tot = ($g.Group | ForEach-Object { ConvertTo-Number $_.Kostnad } | Measure-Object -Sum).Sum
            [void]$sb.Append((Tile "Kostnad senaste 12 mån ($($g.Name))" ('{0:N0}' -f $tot)))
        }
    }
    [void]$sb.Append('</div>')

    if ($null -ne $d.Ctrls -and @($d.Ctrls).Count) {
        $ctrlView = @($d.Ctrls | Where-Object { [int](ConvertTo-Number $_.Max) -gt 0 -or [int](ConvertTo-Number $_.Osunda) -gt 0 } | Sort-Object { -[int](ConvertTo-Number $_.Osunda) }, Kontroll | ForEach-Object {
                [pscustomobject]@{ Kontroll = $_.Kontroll; Poang = ('{0} av {1}' -f $_.Poang, $_.Max); Osunda = $_.Osunda; Friska = $_.Friska } })
        [void]$sb.Append('<h2>Secure Score per kontroll</h2><p class="muted">Poäng och antal osunda respektive friska resurser per kontroll. Tabellen är mer tillförlitlig än listan över enskilda rekommendationer längre ned, som Azures API ibland returnerar ofullständig.</p>' + (ConvertTo-HtmlTable $ctrlView @(@{Name='Kontroll';Label='Kontroll'}, @{Name='Poang';Label='Poäng';Num=$true}, @{Name='Osunda';Label='Osunda resurser';Num=$true}, @{Name='Friska';Label='Friska resurser';Num=$true}) 30))
    }
    if ($null -ne $d.Plans -and @($d.Plans).Count) {
        $planView = $d.Plans | ForEach-Object { [pscustomobject]@{ Prenumeration = $_.Prenumeration; Plan = $_.Plan; Status = $(if ($_.Niva -eq 'Standard') { 'På' } else { 'Av' }) } }
        [void]$sb.Append('<h2>Defender-planer</h2>' + (ConvertTo-HtmlTable $planView @(@{Name='Prenumeration';Label='Prenumeration'}, @{Name='Plan';Label='Plan'}, @{Name='Status';Label='Status'}) 40))
    }
    if ($null -ne $d.Recs -and @($d.Recs | Where-Object Status -eq 'Unhealthy').Count) {
        $sevOrder = @{ High = 0; Medium = 1; Low = 2 }
        $recView = @($d.Recs | Where-Object Status -eq 'Unhealthy' | Sort-Object { if ($sevOrder.ContainsKey($_.Allvarlighet)) { $sevOrder[$_.Allvarlighet] } else { 3 } } |
                ForEach-Object { [pscustomobject]@{ Impact = $_.Allvarlighet; Rekommendation = $_.Rekommendation; Resurs = ($_.Resurs -split '/')[-1] } })
        [void]$sb.Append('<h2>Defender-rekommendationer som inte uppfylls</h2>' + (ConvertTo-HtmlTable $recView @(@{Name='Impact';Label='Allvarlighet'}, @{Name='Rekommendation';Label='Rekommendation'}, @{Name='Resurs';Label='Resurs'}) 25))
    }
    if ($null -ne $d.Costs -and @($d.Costs).Count) {
        [void]$sb.Append('<h2>Kostnad per månad</h2>')
        foreach ($g in ($d.Costs | Group-Object Valuta)) {
            $months = $g.Group | Group-Object Manad | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Manad = $_.Name; Summa = ($_.Group | ForEach-Object { ConvertTo-Number $_.Kostnad } | Measure-Object -Sum).Sum } }
            $max = ($months | Measure-Object Summa -Maximum).Maximum
            $rows = ($months | ForEach-Object { '<tr><td>{0}</td><td class="num">{1:N0}</td><td>{2}</td></tr>' -f (Esc $_.Manad), $_.Summa, (Get-BarHtml $(if ($max) { 100 * $_.Summa / $max } else { 0 })) }) -join ''
            [void]$sb.Append("<table><thead><tr><th>Månad</th><th class=`"num`">Kostnad ($(Esc $g.Name))</th><th>Fördelning</th></tr></thead><tbody>$rows</tbody></table>")
        }
        $multi = @($d.Costs | Select-Object -ExpandProperty Prenumeration -Unique).Count
        if ($multi -gt 1) { [void]$sb.Append("<p class=`"muted`">Summan avser alla $multi prenumerationer. Kostnad per prenumeration finns i filen portal\kostnad.csv.</p>") }
    }
    [void]$sb.Append('<p class="muted">Hämtat automatiskt via Azure (endast läsning). Fullständiga CSV-filer finns i mappen portal\. Azure Advisor-rekommendationer finns på sidan Resurser.</p>')
    $sb.ToString()
}

# --- Om körningen ------------------------------------------------------------------------------------
function Get-AboutPageHtml($d, $Theme) {
    $sb = [System.Text.StringBuilder]::new()
    if ($Status.Count) {
        $rows = $Status.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Steg = $_.Key; Status = $_.Value.State; Notering = $_.Value.Note } }
        [void]$sb.Append('<h2>Körningsstatus</h2>' + (ConvertTo-HtmlTable $rows @(@{Name='Steg';Label='Steg'}, @{Name='Status';Label='Status'}, @{Name='Notering';Label='Notering'})))
    }
    if ($Warnings.Count) { [void]$sb.Append('<h2>Varningar</h2><ul>' + (($Warnings | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul>') }

    [void]$sb.Append('<h2>Begränsningar och avgränsningar</h2>')
    $lim = [System.Collections.Generic.List[string]]::new()
    $lim.Add('Rapporten sammanfattar verktygens resultat och ersätter inte en granskning. Den visar läget vid körningstillfället.')
    foreach ($k in $Status.Keys) {
        $s = $Status[$k]
        if ($s.State -eq 'Hoppad över') { $lim.Add("$k kördes inte (hoppades över).") }
        elseif ($s.State -eq 'Fel') { $lim.Add("$k misslyckades och saknas därför i rapporten: $($s.Note)") }
        elseif ($s.State -eq 'Delvis') { $lim.Add("$k lyckades bara delvis: $($s.Note)") }
    }
    $lim.Add('Governance Visualizer körs som vanlig användare, så roller som bara är tillgängliga via PIM men inte aktiverade ingår inte (kräver servicekonto). Klassiska prenumerationsadministratörer (ett pensionerat API) och kontrollen av Azure Landing Zones-policyversioner ingår inte.')
    $lim.Add('Defender-rekommendationer hämtas från Azures API, som kan returnera en ofullständig lista. Använd Secure Score per kontroll som referens.')
    $lim.Add('Kostnad avser de senaste 12 månaderna per prenumeration. Prognos och kostnad per tagg ingår inte.')
    if ($HidePersonalData) { $lim.Add('Användardata är dolda i Governance Visualizers rapport och på sidan Styrning (-HidePersonalData). Övriga rapporter, bland annat Maesters, kan innehålla namn.') }
    else { $lim.Add('Rapporterna kan innehålla namn och e-postadresser (rolltilldelningar, Maester). Hantera dem som konfidentiella.') }
    [void]$sb.Append('<ul>' + (($lim | ForEach-Object { "<li>$(Esc $_)</li>" }) -join '') + '</ul>')

    $meta = @(
        [pscustomobject]@{ Falt = 'Rapportkit'; Varde = "v$KitVersion" },
        [pscustomobject]@{ Falt = 'Körd'; Varde = $script:RunStart.ToString('yyyy-MM-dd HH:mm') },
        [pscustomobject]@{ Falt = 'Tenant'; Varde = $TenantId },
        [pscustomobject]@{ Falt = 'Verktygsversioner'; Varde = $(if ($LatestTools) { 'senaste (-LatestTools), inte testade med detta kit' } else { "testade: Governance Visualizer $GvVersion, azqr $($Pins.Azqr), Maester $($Pins.Maester), Pester $($Pins.Pester), Az.Accounts $($Pins.AzAccounts)" }) },
        [pscustomobject]@{ Falt = 'Installerat'; Varde = ('Maester {0}, Az.Accounts {1}' -f (Get-ModuleVersionText 'Maester'), (Get-ModuleVersionText 'Az.Accounts')) },
        [pscustomobject]@{ Falt = 'Dator'; Varde = ('PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString) },
        [pscustomobject]@{ Falt = 'Rapportmall'; Varde = ('{0} ({1})' -f $Theme.Data.name, $Theme.Source) }
    )
    [void]$sb.Append('<h2>Om körningen</h2>' + (ConvertTo-HtmlTable $meta @(@{Name='Falt';Label='Fält'}, @{Name='Varde';Label='Värde'}) 20))
    [void]$sb.Append('<div class="callout">Scriptet skriver inget i Azure-resurser eller Entra-konfigurationen. Det installerar verktyg lokalt, skapar inloggningssessioner (som syns i tenantens loggar), och för Maester krävs att en administratör godkänner läsbehörigheter för Microsoft Graph Command Line Tools.</div>')

    [void]$sb.Append('<h2>Filer och loggar</h2><ul><li><code>rapportkit.log</code>: rensad logg med tidsstämpel och nivå</li><li><code>run-summary.json</code>: maskinläsbar sammanfattning (versioner, tid per steg, status, varningar)</li><li><code>azgovviz\</code>, <code>azqr\</code>, <code>maester\</code>: verktygens egna rapporter och data</li><li><code>portal\</code>: Defender- och kostnadsdata som CSV</li></ul>')
    $sb.ToString()
}

# --- Översikt ----------------------------------------------------------------------------------------
function Get-OverviewPageHtml($d, $Pages) {
    $sb = [System.Text.StringBuilder]::new()
    $file = @{}; foreach ($p in $Pages) { $file[$p.Key] = $p.File }

    [void]$sb.Append('<div class="tiles">')
    if ($d.AzqrPresent -and $null -ne $d.AzqrInv -and $null -ne $d.AzqrImp) {
        [void]$sb.Append((Tile 'Resurser' @($d.AzqrInv).Count '' $file.resurser))
        [void]$sb.Append((Tile 'Hög påverkan (azqr)' @($d.AzqrImp | Where-Object Impact -eq 'High').Count 'high' $file.resurser))
        [void]$sb.Append((Tile 'Medel (azqr)' @($d.AzqrImp | Where-Object Impact -eq 'Medium').Count 'medium' $file.resurser))
    }
    if ($d.GvPresent) {
        if ($null -ne $d.GvRoles) { [void]$sb.Append((Tile 'Rolltilldelningar' @($d.GvRoles).Count '' $file.styrning)) }
        if ($null -ne $d.GvPolicies) { [void]$sb.Append((Tile 'Policytilldelningar' @($d.GvPolicies).Count '' $file.styrning)) }
    }
    if ($d.MaesterPresent) {
        [void]$sb.Append((Tile 'Entra-tester godkända' $d.Maester.PassedCount 'ok' $file.entra))
        [void]$sb.Append((Tile 'Entra-tester underkända' $d.Maester.FailedCount 'high' $file.entra))
    }
    $sc = @($d.Scores) | Select-Object -First 1
    if ($sc) { [void]$sb.Append((Tile 'Secure Score' ('{0} %' -f [math]::Round((ConvertTo-Number $sc.Andel) * 100)) '' $file.defender)) }
    if ($null -ne $d.Costs -and @($d.Costs).Count) {
        foreach ($g in ($d.Costs | Group-Object Valuta | Select-Object -First 1)) { [void]$sb.Append((Tile "Kostnad 12 mån ($($g.Name))" ('{0:N0}' -f (($g.Group | ForEach-Object { ConvertTo-Number $_.Kostnad } | Measure-Object -Sum).Sum)) '' $file.defender)) }
    }
    [void]$sb.Append('</div>')

    # Automatiska iakttagelser: ingen bedömning, bara det som syns i siffrorna.
    $obs = [System.Collections.Generic.List[string]]::new()
    if ($d.AzqrPresent -and $null -ne $d.AzqrImp) {
        $hi = @($d.AzqrImp | Where-Object Impact -eq 'High')
        if ($hi.Count) { $top = ($hi | Group-Object Recommendation | Sort-Object Count -Descending | Select-Object -First 1).Name; $obs.Add(('azqr: {0} avvikelser med hög påverkan, till exempel "{1}". <a href="{2}">Se resurser</a>.' -f $hi.Count, (Esc $top), $file.resurser)) }
    }
    if ($d.MaesterPresent -and [int]$d.Maester.FailedCount -gt 0) {
        $first = ($d.Maester.Tests | Where-Object Result -eq 'Failed' | Select-Object -First 1).Name
        $obs.Add(('Entra ID: {0} underkända tester, till exempel "{1}". <a href="{2}">Se Entra ID</a>.' -f $d.Maester.FailedCount, (Esc $first), $file.entra))
    }
    if ($null -ne $d.Ctrls) {
        $worst = $d.Ctrls | Sort-Object { -[int](ConvertTo-Number $_.Osunda) } | Select-Object -First 1
        if ($worst -and [int](ConvertTo-Number $worst.Osunda) -gt 0) { $obs.Add(('Defender: kontrollen "{0}" har {1} osund(a) resurs(er) och {2} av {3} poäng. <a href="{4}">Se Defender och kostnad</a>.' -f (Esc $worst.Kontroll), $worst.Osunda, $worst.Poang, $worst.Max, $file.defender)) }
    }
    if ($null -ne $d.Plans) { $on = @($d.Plans | Where-Object Niva -eq 'Standard').Count; $obs.Add(('Defender: {0} av {1} planer är påslagna.' -f $on, @($d.Plans).Count)) }
    if ($d.GvPresent -and $null -ne $d.GvRoles) {
        $priv = @($d.GvRoles | Where-Object { $_.RoleClear -in 'Owner', 'User Access Administrator' }).Count
        if ($priv) { $obs.Add(('Styrning: {0} tilldelningar av Owner eller User Access Administrator. <a href="{1}">Se Styrning</a>.' -f $priv, $file.styrning)) }
    }
    if ($Warnings.Count) { $obs.Add(('{0} varning(ar) om underlagets kvalitet. <a href="{1}">Se Om körningen</a>.' -f $Warnings.Count, $file.om)) }
    if ($obs.Count) { [void]$sb.Append('<h2>Det som sticker ut</h2><p class="muted">Automatiskt framtagna iakttagelser ur siffrorna. Det är inte en bedömning: de är en startpunkt för genomgången.</p><ul>' + (($obs | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>') }

    [void]$sb.Append('<h2>Sidor i rapporten</h2><div class="cards">')
    $descr = @{
        styrning = 'Prenumerationer, rolltilldelningar, privilegierade konton, policys och taggning (Governance Visualizer).'
        resurser = 'Resurser och rekommendationer per kategori, plus Azure Advisor (azqr).'
        entra    = 'Tester av Entra ID: vad som är godkänt, underkänt och vad som inte kunde kontrolleras (Maester).'
        defender = 'Secure Score, Defender-planer, rekommendationer och kostnad de senaste 12 månaderna.'
        om       = 'Körningsstatus, varningar, begränsningar, versioner och filer.'
    }
    foreach ($p in $Pages) { if ($p.Key -ne 'oversikt') { [void]$sb.Append(('<a class="card" href="{0}"><b>{1}</b><span>{2}</span></a>' -f (Esc $p.File), (Esc $p.Title), (Esc $descr[$p.Key]))) } }
    [void]$sb.Append('</div>')

    if ($Status.Count) {
        $rows = $Status.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Steg = $_.Key; Status = $_.Value.State; Notering = $_.Value.Note } }
        [void]$sb.Append('<h2>Körningsstatus</h2>' + (ConvertTo-HtmlTable $rows @(@{Name='Steg';Label='Steg'}, @{Name='Status';Label='Status'}, @{Name='Notering';Label='Notering'})))
    }
    $sb.ToString()
}

# ===========================================================================
# Sidmall och orkestrering
# ===========================================================================

# Hela HTML-sidan: sidhuvud med logga, navigering, innehåll och sidfot. CSS och logga ligger inbäddade.
function New-ReportPageHtml($Ctx, [string]$ActiveKey, [string]$Title, [string]$Lead, [string]$Content) {
    $nav = (($Ctx.Pages | ForEach-Object { '<a href="{0}"{1}>{2}</a>' -f (Esc $_.File), $(if ($_.Key -eq $ActiveKey) { ' aria-current="page"' } else { '' }), (Esc $_.Title) }) -join '')
    $t = $Ctx.Theme.Data
    $contact = ''
    if ($t.contact -is [hashtable] -and $t.contact.text) {
        $contact = if ($t.contact.url -and ([string]$t.contact.url) -match '^https?://') { New-ExtLink ([string]$t.contact.url) ([string]$t.contact.text) } else { Esc $t.contact.text }
    }
    $footLeft = (@((Esc $t.footer), $contact) | Where-Object { $_ }) -join ' &middot; '
    $sub = if ($t.reportTitle) { '<span class="rk-sub">{0}</span>' -f (Esc $t.reportTitle) } else { '' }
    # Knappen ger alltid hela rapporten: på delsidorna öppnas sammanställningen (alla sidor) i nytt fönster och utskriftsdialogen visas där.
    $printBtn = if ($ActiveKey -eq 'komplett') {
        '<button class="rk-btn noprint" type="button" onclick="window.print()">Skriv ut / spara hela rapporten som PDF</button>'
    } else {
        '<a class="rk-btn noprint" href="rapport-komplett.html#skriv" target="_blank" rel="noopener noreferrer">Spara hela rapporten som PDF</a>'
    }
    $autoPrint = if ($ActiveKey -eq 'komplett') { '<script>if(location.hash==="#skriv"){window.addEventListener("load",function(){setTimeout(function(){window.print()},400)})}</script>' } else { '' }
    @"
<!doctype html>
<html lang="sv"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="robots" content="noindex">
<title>$(Esc $Title) - $(Esc $t.reportTitle) $(Esc $Period)</title>
<style>
$($Ctx.Css)
</style></head><body>
<header class="rk-top"><div class="rk-top-in">
<div class="rk-logo">$($Ctx.LogoHtml)$sub</div>
<div class="rk-meta">Tenant $(Esc $TenantId)<br>Period $(Esc $Period) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm')<br>$printBtn</div>
</div></header>
<nav class="rk-nav" aria-label="Sidor i rapporten"><div class="rk-nav-in">$nav</div></nav>
<main class="rk-main">
<h1>$(Esc $Title)</h1>
<p class="rk-lead">$(Esc $Lead)</p>
$Content
</main>
<footer class="rk-foot"><span>$footLeft</span><span>Konfidentiell information &middot; skapad med Azure Rapportkit v$(Esc $KitVersion)</span></footer>
$autoPrint
</body></html>
"@
}

# Bygger hela rapporten och skriver sidorna i resultatmappen. Ger sökvägen till startsidan (rapport.html).
function Write-ReportSite {
    $theme = Get-BrandTheme $Brand $BrandPath
    $pages = @(
        @{ Key = 'oversikt'; File = 'rapport.html'; Title = 'Översikt'; Lead = 'Läget i miljön, sammanfattat från verktygens resultat.' },
        @{ Key = 'styrning'; File = 'rapport-styrning.html'; Title = 'Styrning'; Lead = 'Prenumerationer, behörigheter och policys. Sammanställt från Azure Governance Visualizer.' },
        @{ Key = 'resurser'; File = 'rapport-resurser.html'; Title = 'Resurser'; Lead = 'Vilka resurser som finns och vad Microsofts rekommendationer säger om dem. Sammanställt från azqr.' },
        @{ Key = 'entra'; File = 'rapport-entra.html'; Title = 'Entra ID'; Lead = 'Tester av inställningarna i Entra ID. Sammanställt från Maester.' },
        @{ Key = 'defender'; File = 'rapport-defender-kostnad.html'; Title = 'Defender & kostnad'; Lead = 'Säkerhetsläge i Defender for Cloud och kostnad de senaste 12 månaderna.' },
        @{ Key = 'om'; File = 'rapport-om.html'; Title = 'Om körningen'; Lead = 'Status, varningar, begränsningar och fakta om hur rapporten togs fram.' }
    )
    $ctx = @{ Theme = $theme; Pages = $pages; Css = (New-ThemeCss $theme); LogoHtml = (Get-LogoHtml $theme) }
    Write-Action ('Rapportmall: {0} ({1})' -f $theme.Data.name, $theme.Source)

    $d = Get-ReportData
    $builders = @{
        oversikt = { Get-OverviewPageHtml $d $pages }
        styrning = { Get-GovernancePageHtml $d }
        resurser = { Get-ResourcesPageHtml $d }
        entra    = { Get-EntraPageHtml $d }
        defender = { Get-DefenderCostPageHtml $d }
        om       = { Get-AboutPageHtml $d $theme }
    }
    # "Om körningen" byggs sist, så att varningar som uppstår när de andra sidorna byggs kommer med.
    $order = 'styrning', 'resurser', 'entra', 'defender', 'oversikt', 'om'
    $content = @{}
    foreach ($key in $order) {
        try { $content[$key] = (& $builders[$key]) -join '' }
        catch { Add-Warning "Sidan '$key' i rapporten kunde inte byggas: $($_.Exception.Message)"; $content[$key] = New-NoDataHtml 'Sidan kunde inte byggas.' $_.Exception.Message }
    }
    $index = $null
    foreach ($p in $pages) {
        $html = New-ReportPageHtml $ctx $p.Key $p.Title $p.Lead $content[$p.Key]
        $path = Join-Path $RunDir $p.File
        Set-Content -LiteralPath $path -Value $html -Encoding utf8
        if ($p.Key -eq 'oversikt') { $index = $path }
    }
    # Sammanställning av alla sidor i ett dokument (för PDF/utskrift). Varje avsnitt börjar på ny sida i utskriften.
    try {
        $all = ($pages | ForEach-Object { '<section class="rk-sec"><h1>{0}</h1><p class="rk-lead">{1}</p>{2}</section>' -f (Esc $_.Title), (Esc $_.Lead), $content[$_.Key] }) -join "`n"
        $full = New-ReportPageHtml $ctx 'komplett' 'Komplett rapport' 'Alla sidor i rapporten i ett dokument, för utskrift eller PDF.' $all
        Set-Content -LiteralPath (Join-Path $RunDir 'rapport-komplett.html') -Value $full -Encoding utf8
    }
    catch { Add-Warning "Den samlade rapporten (PDF-versionen) kunde inte byggas: $($_.Exception.Message)" }
    $index
}
