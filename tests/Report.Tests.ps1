#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests for the report generator (lib\Report.ps1): theme, validation, links and page building. The generator is
  dot-sourced and gets stubs for what it otherwise takes from the main script. No sign-ins or downloads.

  Most page tests build the report in Swedish and check the Swedish texts (that is the language pack that differs from
  the base), so the expected strings in them are Swedish on purpose.

  Run:  Invoke-Pester .\tests
#>

BeforeAll {
    $script:Root = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:ScriptRoot = $script:Root.Path

    # Functions that the generator uses from the main script: read out with the parser, or replaced by stubs.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'Run-Rapportkit.ps1'), [ref]$null, [ref]$null)
    foreach ($d in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Import-CsvChecked' }, $true)) { . ([scriptblock]::Create($d.Extent.Text)) }
    $script:Warnings = [System.Collections.Generic.List[string]]::new()
    function Add-Warning([string]$msg) { $script:Warnings.Add($msg) }
    function Write-Action($m) { }
    function Get-ModuleVersionText($n) { '1.0' }

    . (Join-Path $script:Root 'lib\Report.ps1')
    # The existing page tests check the Swedish texts: the language is chosen by -ReportLanguage (here the script variable).
    $script:ReportLanguage = 'sv'
    [void](Initialize-Language 'sv')
    # The pages HTML-encode non-ASCII characters (ö becomes &#246;): decode before the text is compared.
    function Get-PageText([string]$File) { [System.Web.HttpUtility]::HtmlDecode((Get-Content (Join-Path $script:RunDir $File) -Raw)) }
}

Describe 'Test-CssColor and Test-CssFont' {
    It 'accepts ordinary colour values' -ForEach @(
        @{ V = '#f97316' }, @{ V = '#fff' }, @{ V = 'rgb(1, 2, 3)' }, @{ V = 'rgba(0,0,0,.5)' }, @{ V = 'hsl(120, 50%, 40%)' }, @{ V = 'tomato' }
    ) { Test-CssColor $V | Should -BeTrue }
    It 'rejects values that could break out of the CSS' -ForEach @(
        @{ V = 'red; } body { display:none' }, @{ V = 'url(http://x)' }, @{ V = '#zzz' }, @{ V = '' }, @{ V = 'red}</style><script>' }
    ) { Test-CssColor $V | Should -BeFalse }
    It 'accepts font lists and rejects dangerous ones' {
        Test-CssFont 'Inter, "Segoe UI", system-ui, sans-serif' | Should -BeTrue
        Test-CssFont 'x; } body{display:none' | Should -BeFalse
        Test-CssFont 'a</style>' | Should -BeFalse
    }
}

Describe 'Get-BrandTheme' {
    BeforeEach { $script:Warnings.Clear() }
    It 'reads the theme in branding\ (Moln på svenska)' {
        $t = Get-BrandTheme
        $t.Data.name | Should -Be 'Moln på svenska'
        $t.Data.colors.light.accent | Should -Be '#f97316'
        $t.Data.colors.dark.bg | Should -Be '#060f09'
        $script:Warnings.Count | Should -Be 0
    }
    It 'reads the neutral theme' {
        (Get-BrandTheme (Join-Path $script:ScriptRoot 'branding-exempel\neutral')).Data.name | Should -Be 'Neutral'
    }
    It 'falls back on the built-in default and warns when the theme is missing' {
        $t = Get-BrandTheme (Join-Path $TestDrive 'finns-inte')
        $t.Data.name | Should -Be 'Neutral'
        $t.Source | Should -Be 'built-in default'
        $script:Warnings.Count | Should -Be 1
    }
    It 'replaces invalid colours by the default value and warns' {
        $dir = Join-Path $TestDrive 'bad'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Dåligt", "colors": { "light": { "accent": "red; } body{display:none" } } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $t = Get-BrandTheme $dir
        $t.Data.name | Should -Be 'Dåligt'
        $t.Data.colors.light.accent | Should -Be '#0969da'
        ($script:Warnings -join ' ') | Should -Match 'colors.light.accent'
    }
    It 'fills in the values that are missing in an incomplete theme' {
        $dir = Join-Path $TestDrive 'partial'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Delvis", "colors": { "light": { "accent": "#ff00aa" } } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $t = Get-BrandTheme $dir
        $t.Data.colors.light.accent | Should -Be '#ff00aa'
        $t.Data.colors.light.bg | Should -Be '#f6f8fa'
        $t.Data.colors.dark.text | Should -Be '#e6edf3'
    }
    It 'survives broken JSON' {
        $dir = Join-Path $TestDrive 'broken'; New-Item -ItemType Directory $dir | Out-Null
        '{ inte json' | Set-Content (Join-Path $dir 'theme.json')
        (Get-BrandTheme $dir).Source | Should -Be 'built-in default'
        $script:Warnings.Count | Should -BeGreaterThan 0
    }
}

Describe 'New-ThemeCss' {
    BeforeEach { $script:Warnings.Clear() }
    It 'contains the variables of the theme for light, dark and print' {
        $css = New-ThemeCss (Get-BrandTheme)
        $css | Should -Match '--rk-accent:#f97316'
        $css | Should -Match '@media \(prefers-color-scheme:dark\)\{:root\{--rk-bg:#060f09'
        $css | Should -Match '@media print\{:root\{--rk-bg:#f0f5f1'
    }
    It 'adds the custom.css of the theme last, but only from inside the theme folder' {
        $dir = Join-Path $TestDrive 'css'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Css", "customCss": "custom.css" }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        '.rk-top{outline:2px solid hotpink}' | Set-Content (Join-Path $dir 'custom.css')
        (New-ThemeCss (Get-BrandTheme $dir)) | Should -Match 'hotpink'
        $dir2 = Join-Path $TestDrive 'css2'; New-Item -ItemType Directory $dir2 | Out-Null
        '{ "name": "Ute", "customCss": "..\\css\\custom.css" }' | Set-Content (Join-Path $dir2 'theme.json') -Encoding utf8
        (New-ThemeCss (Get-BrandTheme $dir2)) | Should -Not -Match 'hotpink'
        ($script:Warnings -join ' ') | Should -Match 'outside the theme folder'
    }
}

Describe 'Get-LogoHtml' {
    BeforeEach { $script:Warnings.Clear() }
    It 'builds the wordmark as ONE element with coloured parts' {
        $html = Get-LogoHtml (Get-BrandTheme)
        $html | Should -Match '^<span class="rk-wm">'
        $html | Should -Match 'rk-w-accent">svenska'
        ([regex]::Matches($html, '<span class="rk-wm">')).Count | Should -Be 1
    }
    It 'embeds an image logo as a data URI' {
        $dir = Join-Path $TestDrive 'logo'; New-Item -ItemType Directory $dir | Out-Null
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' | Set-Content (Join-Path $dir 'logo.svg')
        '{ "name": "Bild", "logo": { "type": "image", "file": "logo.svg", "alt": "Min <logga>" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $html = Get-LogoHtml (Get-BrandTheme $dir)
        $html | Should -Match 'src="data:image/svg\+xml;base64,'
        $html | Should -Match 'alt="Min &lt;logga&gt;"'
    }
    It 'falls back on the wordmark when the logo is missing or outside the theme folder' {
        $dir = Join-Path $TestDrive 'logo2'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Saknas", "logo": { "type": "image", "file": "..\\..\\x.png" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        (Get-LogoHtml (Get-BrandTheme $dir)) | Should -Match 'rk-wm'
        $script:Warnings.Count | Should -BeGreaterThan 0
    }
}

Describe 'Links and HTML building blocks' {
    It 'New-ExtLink opens in a new window with noopener and encodes the text and the address' {
        $a = New-ExtLink 'https://example.com/?a=1&b="2"' '<Rapport>'
        $a | Should -Match 'target="_blank"'
        $a | Should -Match 'rel="noopener noreferrer"'
        $a | Should -Not -Match '<Rapport>'
        $a | Should -Match '&amp;b=&quot;2&quot;'
    }
    It 'ConvertTo-HtmlTable encodes the cells and shows Status as a label' {
        $rows = @([pscustomobject]@{ Namn = '<script>x</script>'; Status = 'Fel' })
        $html = ConvertTo-HtmlTable $rows @(@{ Name = 'Namn'; Label = 'Namn' }, @{ Name = 'Status'; Label = 'Status' })
        $html | Should -Not -Match '<script>'
        $html | Should -Match 'class="pill fel"'
    }
    It 'Tile becomes a link only when an address is given' {
        (Tile 'A' 1 '' 'sida.html') | Should -Match '^<a class="tile'
        (Tile 'A' 1) | Should -Match '^<div class="tile'
    }
    It 'Get-UniqueRows keeps the first row per key' {
        $rows = @([pscustomobject]@{ Id = 'a'; V = 1 }, [pscustomobject]@{ Id = 'a'; V = 2 }, [pscustomobject]@{ Id = 'b'; V = 3 })
        $u = Get-UniqueRows $rows 'Id'
        $u.Count | Should -Be 2
        $u[0].V | Should -Be 1
        Get-UniqueRows $null 'Id' | Should -BeNullOrEmpty
    }
    It 'ConvertTo-Number handles decimal comma and decimal point' {
        ConvertTo-Number '272,99' | Should -Be 272.99
        ConvertTo-Number '1.5' | Should -Be 1.5
        ConvertTo-Number 'abc' | Should -Be 0
    }
}

Describe 'Write-ReportSite (page building)' {
    BeforeAll {
        # A small result tree with synthetic data for azqr, Defender and Maester
        $script:RunDir = Join-Path $TestDrive 'run'
        $script:Dirs = @{}
        foreach ($n in 'azqr', 'azgovviz', 'maester', 'portal') { $script:Dirs[$n] = Join-Path $script:RunDir $n; New-Item -ItemType Directory -Force $script:Dirs[$n] | Out-Null }
        "Validated Using,Source,Category,Impact,Resource Type,Recommendation,Recommendation Id,Subscription Id,Subscription Name,Resource Group,Resource Name`nARG,APRL,Security,High,Microsoft.Web/sites,Använd HTTPS,r1,s1,Sub,rg,app1" | Set-Content (Join-Path $script:Dirs.azqr 'azqr_x.impacted.csv') -Encoding utf8
        "Subscription Id,Resource Group,Location,Resource Type,Resource Name`ns1,rg,westeurope,microsoft.web/sites,app1" | Set-Content (Join-Path $script:Dirs.azqr 'azqr_x.inventory.csv') -Encoding utf8
        "Prenumeration,Plan,Niva,Delplan`nSub,VirtualMachines,Free," | Set-Content (Join-Path $script:Dirs.portal 'defender-planer.csv') -Encoding utf8
        "PrenumerationId,Prenumeration,Poang,Max,Andel`ns1,Sub,4,14,0.2857" | Set-Content (Join-Path $script:Dirs.portal 'secure-score.csv') -Encoding utf8
        "Prenumeration,Manad,Kostnad,Valuta`nSub,2026-09,100,SEK`nSub,2026-10,150,SEK" | Set-Content (Join-Path $script:Dirs.portal 'kostnad.csv') -Encoding utf8
        $mt = Join-Path $script:Dirs.maester 'test-results'; New-Item -ItemType Directory $mt | Out-Null
        @{ PassedCount = 1; FailedCount = 1; SkippedCount = 1; Tests = @(@{ Name = 'MT.1'; Result = 'Failed'; ResultDetail = @{ TestSkipped = $null } }, @{ Name = 'MT.2'; Result = 'Skipped'; ResultDetail = @{ TestSkipped = 'NotLicensedEntraIDP1' } }, @{ Name = 'MT.3'; Result = 'Passed'; ResultDetail = @{ TestSkipped = $null } }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $mt 'maester.json') -Encoding utf8
        # Every Maester run leaves a timestamped HTML file of its own; the report must link to the newest.
        foreach ($t in '2026-10-30-151835', '2026-10-30-162523') { '<html></html>' | Set-Content (Join-Path $mt "TestResults-$t.html") -Encoding utf8 }

        $script:TenantId = '00000000-0000-0000-0000-000000000000'; $script:Period = '2026-10'
        $script:KitVersion = 'test'; $script:Pins = @{ Azqr = '1'; Maester = '1'; Pester = '1'; AzAccounts = '1' }; $script:GvVersion = '6'
        $script:HidePersonalData = $false; $script:LatestTools = $false
        $script:Status = [ordered]@{ azqr = @{ State = 'OK'; Note = '' }; Maester = @{ State = 'OK'; Note = '' } }
        $script:RunStart = Get-Date
        $script:BrandingDir = $null
        $script:Warnings.Clear()
        $script:Index = Write-ReportSite
    }
    It 'writes all seven pages and returns the start page' {
        $script:Index | Should -Match 'rapport\.html$'
        foreach ($f in 'rapport.html', 'rapport-struktur.html', 'rapport-styrning.html', 'rapport-resurser.html', 'rapport-entra.html', 'rapport-defender-kostnad.html', 'rapport-om.html') {
            Test-Path (Join-Path $script:RunDir $f) | Should -BeTrue
        }
    }
    It 'shows which result files the report was built from, without the folder names of the user' {
        $h = Get-PageText 'rapport-om.html'
        $h | Should -Match 'Resultatfiler som användes'
        $h | Should -Match 'azqr\\azqr_x\.impacted\.csv'
        $h | Should -Match 'maester\\test-results\\maester\.json'
        $h | Should -Match 'maester\\test-results\\TestResults-2026-10-30-162523\.html'
        $h | Should -Not -Match ([regex]::Escape($TestDrive))
        $h | Should -Not -Match 'tidigare körningar'      # one run of each tool: nothing older to mention
    }
    It 'shows the report theme without a path' {
        $h = Get-PageText 'rapport-om.html'
        $h | Should -Match 'Moln på svenska'
        $h | Should -Not -Match 'branding'
    }
    It 'has the same navigation and the theme on every page' {
        foreach ($f in Get-ChildItem $script:RunDir -Filter 'rapport*.html') {
            $h = Get-Content $f.FullName -Raw
            $h | Should -Match 'class="rk-nav"'
            $h | Should -Match '--rk-accent:#f97316'
            # The combined PDF page (rapport-komplett.html) marks no single tab.
            ([regex]::Matches($h, 'aria-current="page"')).Count | Should -Be $(if ($f.Name -eq 'rapport-komplett.html') { 0 } else { 1 })
        }
    }
    It 'the PDF button opens the combined report with all seven pages' {
        $full = Get-Content (Join-Path $script:RunDir 'rapport-komplett.html') -Raw
        ([regex]::Matches($full, '<section class="rk-sec">')).Count | Should -Be 7
        (Get-Content (Join-Path $script:RunDir 'rapport.html') -Raw) | Should -Match 'href="rapport-komplett\.html#skriv" target="_blank"'
    }
    It 'fetches nothing from the internet (no src/href to external addresses except the contact link)' {
        foreach ($f in Get-ChildItem $script:RunDir -Filter 'rapport*.html') {
            $h = Get-Content $f.FullName -Raw
            $ext = [regex]::Matches($h, '(?:src|href)="(https?://[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            @($ext | Where-Object { $_ -ne 'https://molnpasvenska.se' }).Count | Should -Be 0
            $h | Should -Not -Match '<script\s+src='
        }
    }
    It 'shows azqr, Maester and cost on the right pages' {
        (Get-PageText 'rapport-resurser.html') | Should -Match 'Använd HTTPS'
        (Get-PageText 'rapport-entra.html') | Should -Match 'Licens saknas: Entra ID P1'
        (Get-PageText 'rapport-defender-kostnad.html') | Should -Match '2026-10'
    }
    It 'reads Defender files with the newer id columns and links to the newest Maester report' {
        (Get-PageText 'rapport-defender-kostnad.html') | Should -Match '4/14'
        $h = Get-Content (Join-Path $script:RunDir 'rapport-entra.html') -Raw
        $h | Should -Match 'TestResults-2026-10-30-162523\.html'
        $h | Should -Not -Match 'TestResults-2026-10-30-151835\.html'
    }
    It 'gives understandable empty pages when the data is missing (Governance without Governance Visualizer)' {
        (Get-PageText 'rapport-styrning.html') | Should -Match 'Governance Visualizer har inte körts'
    }
    It 'can be built with another theme' {
        $script:BrandingDir = Join-Path $script:ScriptRoot 'branding-exempel\neutral'
        Write-ReportSite | Out-Null
        (Get-Content (Join-Path $script:RunDir 'rapport.html') -Raw) | Should -Match '--rk-accent:#0969da'
        $script:BrandingDir = $null
    }
}

Describe 'Choice of result files when a folder holds several runs' {
    BeforeAll {
        $script:RunDir = Join-Path $TestDrive 'multi'
        $script:Dirs = @{}
        foreach ($n in 'azqr', 'azgovviz', 'maester', 'portal', 'struktur') { $script:Dirs[$n] = Join-Path $script:RunDir $n; New-Item -ItemType Directory -Force $script:Dirs[$n] | Out-Null }
    }
    BeforeEach { $script:Warnings.Clear() }
    It 'Find-ResultFile takes the newest file, and at the same time the one with the last name' {
        $d = Join-Path $TestDrive 'ff'; New-Item -ItemType Directory $d | Out-Null
        foreach ($n in 'A_20261030_153226_x.csv', 'A_20261030_162235_x.csv', 'A_20261030_154908_x.csv') { 'x' | Set-Content (Join-Path $d $n) }
        $t = Get-Date
        foreach ($f in Get-ChildItem $d) { $f.LastWriteTime = $t }
        (Find-ResultFile $d '*_x.csv').Name | Should -Be 'A_20261030_162235_x.csv'
        (Get-Item (Join-Path $d 'A_20261030_153226_x.csv')).LastWriteTime = $t.AddMinutes(5)
        (Find-ResultFile $d '*_x.csv').Name | Should -Be 'A_20261030_153226_x.csv'
        Find-ResultFile (Join-Path $d 'finns-inte') '*.csv' | Should -BeNullOrEmpty
    }
    It 'reads the newest TestResults file, and maester.json only if there is none' {
        $mt = Join-Path $script:Dirs.maester 'test-results'; New-Item -ItemType Directory $mt | Out-Null
        $mk = { param($name, $passed, $time) $p = Join-Path $mt $name; @{ PassedCount = $passed; FailedCount = 0; SkippedCount = 0; Tests = @() } | ConvertTo-Json | Set-Content $p -Encoding utf8; (Get-Item $p).LastWriteTime = $time }
        & $mk 'maester.json' 7 (Get-Date).AddHours(-1)             # left over from an earlier run, written last of all
        (Get-ReportData).Maester.PassedCount | Should -Be 7        # nothing else: the fallback is used
        & $mk 'TestResults-2026-10-30-100000.json' 1 (Get-Date).AddHours(-3)
        & $mk 'TestResults-2026-10-30-120000.json' 2 (Get-Date).AddHours(-2)
        (Get-ReportData).Maester.PassedCount | Should -Be 2        # the newest TestResults file wins over maester.json
    }
    It 'lists the files that were used and counts the older runs' {
        $guid = '11111111-2222-3333-4444-555555555555'
        foreach ($t in '20261030_100000', '20261031_100000') { '<html></html>' | Set-Content (Join-Path $script:Dirs.azgovviz "AzGovViz_6.7.2_${t}_$guid.html") -Encoding utf8 }
        $mt = Join-Path $script:Dirs.maester 'test-results'
        foreach ($t in '2026-10-30-100000', '2026-10-30-120000') { '<html></html>' | Set-Content (Join-Path $mt "TestResults-$t.html") -Encoding utf8 }
        $d = Get-ReportData
        $files = @($d.Used | ForEach-Object File)
        $files | Should -Contain "azgovviz\AzGovViz_6.7.2_20261031_100000_$guid.html"
        $files | Should -Not -Contain "azgovviz\AzGovViz_6.7.2_20261030_100000_$guid.html"
        $files | Should -Contain 'maester\test-results\TestResults-2026-10-30-120000.json'
        $files | Should -Contain 'maester\test-results\TestResults-2026-10-30-120000.html'
        $d.OlderGvRuns | Should -Be 1
        $d.OlderMaesterRuns | Should -Be 1
        ($d.Used | Where-Object Tool -eq 'Maester').Modified | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
    }
    It 'reads the data files of the same Governance Visualizer run as the main report, even if an older one was written later' {
        $gv = Join-Path $TestDrive 'samerun'; New-Item -ItemType Directory $gv | Out-Null
        $keepDirs = $script:Dirs; $script:Dirs = @{ azqr = 'none'; azgovviz = $gv; maester = 'none'; portal = 'none'; struktur = 'none' }
        try {
            $guid = '11111111-2222-3333-4444-555555555555'
            $hdr = 'RoleAssignmentId;RoleClear;ObjectType;ScopeTenOrMgOrSubOrRGOrRes'
            foreach ($run in @(@('20261030_100000', 'Reader'), @('20261031_100000', 'Owner'))) {
                $base = "AzGovViz_6.7.2_$($run[0])_$guid"
                '<html></html>' | Set-Content (Join-Path $gv "$base.html")
                "$hdr`n1;$($run[1]);User;Sub" | Set-Content (Join-Path $gv "${base}_RoleAssignments.csv")
            }
            # The older run's file is the most recently written one (for example after a copy)
            (Get-Item (Join-Path $gv "AzGovViz_6.7.2_20261030_100000_${guid}_RoleAssignments.csv")).LastWriteTime = (Get-Date).AddMinutes(5)
            $d = Get-ReportData
            @($d.GvRoles).RoleClear | Should -Be 'Owner'
        }
        finally { $script:Dirs = $keepDirs }
    }
}

Describe 'The Entra page with tests that ended with an error' {
    BeforeAll { $script:Warnings.Clear(); [void](Initialize-Language 'sv') }
    It 'shows the errors in a tile and a note of their own' {
        $m = [pscustomobject]@{ PassedCount = 5; FailedCount = 2; SkippedCount = 1; ErrorCount = 3; Tests = @() }
        $h = [System.Web.HttpUtility]::HtmlDecode((Get-EntraPageHtml @{ MaesterPresent = $true; Maester = $m }))
        $h | Should -Match '<div class="v">3</div><div class="l">Fel</div>'
        $h | Should -Match '3 test\(er\) slutade med fel'
    }
    It 'shows no error tile when there were no errors, or in an older file without ErrorCount' {
        foreach ($m in @([pscustomobject]@{ PassedCount = 5; FailedCount = 2; SkippedCount = 1; ErrorCount = 0; Tests = @() }, [pscustomobject]@{ PassedCount = 5; FailedCount = 2; SkippedCount = 1; Tests = @() })) {
            $h = [System.Web.HttpUtility]::HtmlDecode((Get-EntraPageHtml @{ MaesterPresent = $true; Maester = $m }))
            $h | Should -Not -Match 'slutade med fel'
        }
    }
}

Describe 'Dark logo and background' {
    BeforeEach { $script:Warnings.Clear() }
    It 'embeds a separate logo for dark mode' {
        $dir = Join-Path $TestDrive 'darklogo'; New-Item -ItemType Directory $dir | Out-Null
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' | Set-Content (Join-Path $dir 'l.svg')
        '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12"/>' | Set-Content (Join-Path $dir 'd.svg')
        '{ "name": "Mörk", "logo": { "type": "image", "file": "l.svg", "fileDark": "d.svg", "alt": "X" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $html = Get-LogoHtml (Get-BrandTheme $dir)
        $html | Should -Match 'rk-l-light'
        $html | Should -Match 'rk-l-dark'
        $script:Warnings.Count | Should -Be 0
    }
    It 'puts a background image in the CSS and warns if the file is missing' {
        $dir = Join-Path $TestDrive 'bg'; New-Item -ItemType Directory $dir | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'b.png'), [byte[]](1..50))
        '{ "name": "Bg", "background": { "file": "b.png", "opacity": 0.2 } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        (New-ThemeCss (Get-BrandTheme $dir)) | Should -Match 'body::before\{content:"";position:fixed.*data:image/png;base64,.*opacity:0\.2'
        '{ "name": "Bg2", "background": { "file": "finns-inte.png" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $script:Warnings.Clear()
        (New-ThemeCss (Get-BrandTheme $dir)) | Should -Not -Match 'body::before'
        ($script:Warnings -join ' ') | Should -Match 'background image'
    }
}

Describe 'Anonymization' {
    BeforeAll {
        $script:RunDir = Join-Path $TestDrive 'anon'
        $script:Dirs = @{}
        foreach ($n in 'azqr', 'azgovviz', 'maester', 'portal') { $script:Dirs[$n] = Join-Path $script:RunDir $n; New-Item -ItemType Directory -Force $script:Dirs[$n] | Out-Null }
        "Validated Using,Source,Category,Impact,Resource Type,Recommendation,Recommendation Id,Subscription Id,Subscription Name,Resource Group,Resource Name`nARG,APRL,Security,High,Microsoft.Web/sites,Använd HTTPS,r1,11111111-2222-3333-4444-555555555555,Kundbolaget Produktion,rg-hemlig,app-kundnamn-01" | Set-Content (Join-Path $script:Dirs.azqr 'azqr_x.impacted.csv') -Encoding utf8
        "Subscription Id,Resource Group,Location,Resource Type,Resource Name`n11111111-2222-3333-4444-555555555555,rg-hemlig,westeurope,microsoft.web/sites,app-kundnamn-01" | Set-Content (Join-Path $script:Dirs.azqr 'azqr_x.inventory.csv') -Encoding utf8
        "Prenumeration,Manad,Kostnad,Valuta`nKundbolaget Produktion,2026-10,150,SEK" | Set-Content (Join-Path $script:Dirs.portal 'kostnad.csv') -Encoding utf8
        $script:TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; $script:Period = '2026-10'
        $script:KitVersion = 'test'; $script:Pins = @{ Azqr = '1'; Maester = '1'; Pester = '1'; AzAccounts = '1' }; $script:GvVersion = '6'
        $script:HidePersonalData = $false; $script:LatestTools = $false
        $script:Status = [ordered]@{ azqr = @{ State = 'OK'; Note = '' } }
        $script:RunStart = Get-Date
        $script:BrandingDir = Join-Path $script:ScriptRoot 'branding-exempel\neutral'
        $script:Warnings.Clear()
        $script:Anonymize = $false; Write-ReportSite | Out-Null     # the plain report, to compare with
        $script:Anonymize = $true; Write-ReportSite | Out-Null      # the anonymized pages (anonym\ when $AnonOutDir is not set)
    }
    AfterAll { $script:Anonymize = $false; $script:BrandingDir = $null }

    It 'builds anonymized pages in anonym\ and leaves the plain report untouched' {
        foreach ($f in 'rapport.html', 'rapport-resurser.html', 'rapport-komplett.html') { Test-Path (Join-Path $script:RunDir "anonym\$f") | Should -BeTrue }
        (Get-PageText 'rapport-resurser.html') | Should -Match 'app-kundnamn-01'
    }
    It 'replaces the names of resources, resource groups and subscriptions, and the IDs' {
        $all = ''
        foreach ($f in Get-ChildItem (Join-Path $script:RunDir 'anonym') -Filter '*.html') { $all += [System.Web.HttpUtility]::HtmlDecode((Get-Content $f.FullName -Raw)) }
        $all | Should -Not -Match 'app-kundnamn-01'
        $all | Should -Not -Match 'rg-hemlig'
        $all | Should -Not -Match 'Kundbolaget'
        $all | Should -Not -Match 'aaaaaaaa-bbbb'
        $all | Should -Not -Match '11111111-2222'
        $all | Should -Match 'Resurs 1'
        $all | Should -Match 'anonymiserad'
    }
    It 'the same name always gets the same alias, and different names different aliases' {
        Register-AnonData @{ GvRoles = @([pscustomobject]@{ ObjectType = 'User'; ObjectDisplayName = 'Kalle Testsson'; ObjectSignInName = 'kalle@kund.se' }, [pscustomobject]@{ ObjectType = 'User'; ObjectDisplayName = 'Lisa Provsson'; ObjectSignInName = 'lisa@kund.se' }) }
        $a = [System.Web.HttpUtility]::HtmlDecode((ConvertTo-AnonymousHtml '<td>Kalle Testsson</td><td>kalle@kund.se</td><td>Lisa Provsson</td><td>Kalle Testsson</td>'))
        $a | Should -Not -Match 'Kalle|Lisa|kund\.se'
        ([regex]::Matches($a, 'Användare 1')).Count | Should -Be 2
        $a | Should -Match 'Användare 2'
        $a | Should -Match 'anvandare1@exempel\.invalid'
    }
    It 'replaces e-mail addresses, GUIDs and onmicrosoft addresses that were not collected, but does not touch tags' {
        Register-AnonData @{}
        $a = ConvertTo-AnonymousHtml '<a class="pill high" href="x.html">okänd@firma.com, 12345678-1234-1234-1234-123456789abc, bolag.onmicrosoft.com</a>'
        $a | Should -Match '<a class="pill high" href="x\.html">'
        $a | Should -Not -Match 'firma\.com|12345678-1234|bolag\.onmicrosoft'
        $a | Should -Match 'exempel\.invalid'
    }
    It 'replaces links to the reports of the tools by text' {
        Register-AnonData @{}
        $a = [System.Web.HttpUtility]::HtmlDecode((ConvertTo-AnonymousHtml (New-ExtLink 'azgovviz/AzGovViz_x.html' 'Governance Visualizer')))
        $a | Should -Not -Match 'href='
        $a | Should -Match 'ingår inte i den anonyma versionen'
        (ConvertTo-AnonymousHtml (New-ExtLink 'https://learn.microsoft.com/x' 'Docs')) | Should -Match 'href="https://learn.microsoft.com/x"'
    }
}

Describe 'Anonymized mode: only anonymized pages' {
    BeforeAll {
        $script:RunDir = Join-Path $TestDrive 'anonmode'
        $script:AnonOutDir = Join-Path $TestDrive 'anonmode-ut'
        $script:Dirs = @{}
        foreach ($n in 'azqr', 'azgovviz', 'maester', 'portal') { $script:Dirs[$n] = Join-Path $script:RunDir $n; New-Item -ItemType Directory -Force $script:Dirs[$n] | Out-Null }
        "Validated Using,Source,Category,Impact,Resource Type,Recommendation,Recommendation Id,Subscription Id,Subscription Name,Resource Group,Resource Name`
ARG,APRL,Security,High,Microsoft.Web/sites,Använd HTTPS,r1,11111111-2222-3333-4444-555555555555,Kundbolaget Produktion,rg-hemlig,app-kundnamn-01" | Set-Content (Join-Path $script:Dirs.azqr 'azqr_x.impacted.csv') -Encoding utf8
        "Subscription Id,Resource Group,Location,Resource Type,Resource Name`
11111111-2222-3333-4444-555555555555,rg-hemlig,westeurope,microsoft.web/sites,app-kundnamn-01" | Set-Content (Join-Path $script:Dirs.azqr 'azqr_x.inventory.csv') -Encoding utf8
        $script:TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; $script:Period = '2026-10'
        $script:KitVersion = 'test'; $script:Pins = @{ Azqr = '1'; Maester = '1'; Pester = '1'; AzAccounts = '1' }; $script:GvVersion = '6'
        $script:HidePersonalData = $false; $script:LatestTools = $false
        $script:Status = [ordered]@{ azqr = @{ State = 'OK'; Note = '' } }
        $script:RunStart = Get-Date
        $script:BrandingDir = Join-Path $script:ScriptRoot 'branding-exempel\neutral'
        # An anonymized run from earlier in the same folder must not leave pages behind
        New-Item -ItemType Directory -Force $script:AnonOutDir | Out-Null
        'OLD PAGE with Kundbolaget' | Set-Content (Join-Path $script:AnonOutDir 'rapport-gammal.html') -Encoding utf8
        $script:Anonymize = $true
        $script:Warnings.Clear()
        $script:Index = Write-ReportSite
    }
    AfterAll { $script:Anonymize = $false; $script:AnonOutDir = $null; $script:BrandingDir = $null }

    It 'writes only the anonymized pages, in the anonymized folder, and returns the start page from there' {
        $script:Index | Should -Be (Join-Path $script:AnonOutDir 'rapport.html')
        foreach ($f in 'rapport.html', 'rapport-struktur.html', 'rapport-styrning.html', 'rapport-resurser.html', 'rapport-entra.html', 'rapport-defender-kostnad.html', 'rapport-om.html', 'rapport-komplett.html') {
            Test-Path (Join-Path $script:AnonOutDir $f) | Should -BeTrue -Because $f
        }
    }
    It 'writes no plain report and no anonym folder in the working folder' {
        @(Get-ChildItem $script:RunDir -Filter 'rapport*.html' -ErrorAction SilentlyContinue).Count | Should -Be 0
        Test-Path (Join-Path $script:RunDir 'anonym') | Should -BeFalse
    }
    It 'removes pages from an earlier anonymized run' {
        Test-Path (Join-Path $script:AnonOutDir 'rapport-gammal.html') | Should -BeFalse
    }
    It 'has no names or IDs on any page' {
        foreach ($f in Get-ChildItem $script:AnonOutDir -File) {
            $h = [System.Web.HttpUtility]::HtmlDecode((Get-Content $f.FullName -Raw))
            $h | Should -Not -Match 'app-kundnamn-01|rg-hemlig|Kundbolaget|aaaaaaaa-bbbb|11111111-2222' -Because $f.Name
        }
    }
}

Describe 'Anonymization of policy names' {
    BeforeAll {
        $script:Warnings.Clear()
        [void](Initialize-Language 'sv')
        $script:GvPol = @(
            [pscustomobject]@{ PolicyAssignmentDisplayName = 'Kundbolaget: kräv taggar'; PolicyNameClear = 'Require a tag on resource groups'; PolicyType = 'BuiltIn' },
            [pscustomobject]@{ PolicyAssignmentDisplayName = 'Kundbolaget: egen policy'; PolicyNameClear = 'Kundbolaget egen definition'; PolicyType = 'Custom' },
            [pscustomobject]@{ PolicyAssignmentDisplayName = 'Allowed locations'; PolicyNameClear = 'Allowed locations'; PolicyType = 'BuiltIn' }
        )
        Register-AnonData @{ GvPolicies = $script:GvPol }
        $script:A = [System.Web.HttpUtility]::HtmlDecode((ConvertTo-AnonymousHtml '<td>Kundbolaget: kräv taggar</td><td>Kundbolaget: egen policy</td><td>Kundbolaget egen definition</td><td>Allowed locations</td>'))
    }
    It 'replaces a name that someone chose by the name of the definition (public text) for built-in policies' {
        $script:A | Should -Match 'Require a tag on resource groups'
        $script:A | Should -Not -Match 'kräv taggar'
    }
    It 'gives custom policies an alias and leaves unchanged built-in names alone' {
        $script:A | Should -Not -Match 'Kundbolaget|egen definition'
        $script:A | Should -Match 'Egen policy 1'
        $script:A | Should -Match 'Allowed locations'
    }
}

Describe 'The Structure page' {
    BeforeAll {
        $script:RunDir = Join-Path $TestDrive 'struk'
        $script:Dirs = @{}
        foreach ($n in 'azqr', 'azgovviz', 'maester', 'portal', 'struktur') { $script:Dirs[$n] = Join-Path $script:RunDir $n; New-Item -ItemType Directory -Force $script:Dirs[$n] | Out-Null }
        $s = $script:Dirs.struktur
        @(
            [pscustomobject]@{ Niva = 0; Id = 'root-tenant'; Namn = 'Tenant Root Group'; Typ = 'Managementgrupp'; Foralder = '' }
            [pscustomobject]@{ Niva = 1; Id = 'mg-plattform'; Namn = 'Plattform'; Typ = 'Managementgrupp'; Foralder = 'root-tenant' }
            [pscustomobject]@{ Niva = 2; Id = 'mg-connectivity'; Namn = 'Connectivity'; Typ = 'Managementgrupp'; Foralder = 'mg-plattform' }
            [pscustomobject]@{ Niva = 3; Id = '11111111-1111-1111-1111-111111111111'; Namn = 'Kundbolaget Hub'; Typ = 'Prenumeration'; Foralder = 'mg-connectivity' }
            [pscustomobject]@{ Niva = 1; Id = '22222222-2222-2222-2222-222222222222'; Namn = 'Kundbolaget Prod'; Typ = 'Prenumeration'; Foralder = 'root-tenant' }
        ) | Export-Csv (Join-Path $s 'managementgrupper.csv') -NoTypeInformation -Encoding utf8
        $hub = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-nat/providers/Microsoft.Network/virtualNetworks/vnet-hubben'
        $a = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-a/providers/Microsoft.Network/virtualNetworks/vnet-spoke-a'
        $b = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-b/providers/Microsoft.Network/virtualNetworks/vnet-spoke-b'
        $iso = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-c/providers/Microsoft.Network/virtualNetworks/vnet-ensam'
        @(
            [pscustomobject]@{ Id = $hub; Namn = 'vnet-hubben'; Prenumeration = '11111111-1111-1111-1111-111111111111'; Resursgrupp = 'rg-nat'; Plats = 'northeurope'; Adressrymd = '10.0.0.0/16'; Subnat = 2 }
            [pscustomobject]@{ Id = $a; Namn = 'vnet-spoke-a'; Prenumeration = '22222222-2222-2222-2222-222222222222'; Resursgrupp = 'rg-a'; Plats = 'northeurope'; Adressrymd = '10.1.0.0/16'; Subnat = 1 }
            [pscustomobject]@{ Id = $b; Namn = 'vnet-spoke-b'; Prenumeration = '22222222-2222-2222-2222-222222222222'; Resursgrupp = 'rg-b'; Plats = 'northeurope'; Adressrymd = '10.2.0.0/16'; Subnat = 1 }
            [pscustomobject]@{ Id = $iso; Namn = 'vnet-ensam'; Prenumeration = '22222222-2222-2222-2222-222222222222'; Resursgrupp = 'rg-c'; Plats = 'westeurope'; Adressrymd = '10.1.5.0/24'; Subnat = 1 }
        ) | Export-Csv (Join-Path $s 'natverk-vnet.csv') -NoTypeInformation -Encoding utf8
        $pe = { param($fi, $f, $ti, $t, $transit) [pscustomobject]@{ FranId = $fi; Fran = $f; TillId = $ti; Till = $t; Status = 'Connected'; GatewayTransit = $transit; AnvandRemoteGateways = $false; ForwardedTraffic = $true; TillAdressrymd = '' } }
        @(
            (& $pe $hub 'vnet-hubben' $a 'vnet-spoke-a' $true), (& $pe $a 'vnet-spoke-a' $hub 'vnet-hubben' $false),
            (& $pe $hub 'vnet-hubben' $b 'vnet-spoke-b' $true)     # has no peering back from spoke-b: one-way
        ) | Export-Csv (Join-Path $s 'natverk-peerings.csv') -NoTypeInformation -Encoding utf8
        @([pscustomobject]@{ Typ = 'azurefirewalls'; Namn = 'fw-hubben'; Prenumeration = '11111111-1111-1111-1111-111111111111'; Resursgrupp = 'rg-nat'; Plats = 'northeurope'; Extra = 'AZFW_VNet'; VnetId = $hub }) | Export-Csv (Join-Path $s 'natverk-noder.csv') -NoTypeInformation -Encoding utf8
        @([pscustomobject]@{ Prenumeration = '11111111-1111-1111-1111-111111111111'; Resurser = 42 }) | Export-Csv (Join-Path $s 'resurser-per-prenumeration.csv') -NoTypeInformation -Encoding utf8

        $script:TenantId = '99999999-8888-7777-6666-555555555555'; $script:Period = '2026-10'
        $script:KitVersion = 'test'; $script:Pins = @{ Azqr = '1'; Maester = '1'; Pester = '1'; AzAccounts = '1' }; $script:GvVersion = '6'
        $script:HidePersonalData = $false; $script:LatestTools = $false
        $script:Status = [ordered]@{}
        $script:RunStart = Get-Date
        $script:BrandingDir = Join-Path $script:ScriptRoot 'branding-exempel\neutral'
        $script:Warnings.Clear()
        $script:Anonymize = $false; Write-ReportSite | Out-Null     # the plain report, to compare with
        $script:Anonymize = $true; Write-ReportSite | Out-Null      # the anonymized pages (anonym\ when $AnonOutDir is not set)
    }
    AfterAll { $script:Anonymize = $false; $script:BrandingDir = $null }

    It 'ConvertTo-CidrRange handles IPv4 and ignores anything else' {
        $r = ConvertTo-CidrRange '10.0.0.0/16'
        ($r[1] - $r[0] + 1) | Should -Be 65536
        ConvertTo-CidrRange 'fd00::/8' | Should -BeNullOrEmpty
        ConvertTo-CidrRange '10.0.0.999/16' | Should -BeNullOrEmpty
    }
    It 'builds the page with the tree, the diagram and the tables' {
        $h = Get-PageText 'rapport-struktur.html'
        $h | Should -Match '<svg class="net-svg"'
        $h | Should -Match 'Plattform'
        $h | Should -Match 'Kundbolaget Hub'
        $h | Should -Match '42 resurser'
        $h | Should -Match 'fw-hubben'
    }
    It 'sets the roles: hub, spoke and isolated' {
        $m = Get-NetworkModel @{ Vnets = @(Import-Csv (Join-Path $script:Dirs.struktur 'natverk-vnet.csv')); Peerings = @(Import-Csv (Join-Path $script:Dirs.struktur 'natverk-peerings.csv')); NetNodes = @(Import-Csv (Join-Path $script:Dirs.struktur 'natverk-noder.csv')); MgRows = @() }
        $role = @{}; foreach ($v in $m.Vnets) { $role[$v.Namn] = $m.Role[([string]$v.Id).ToLower()] }
        $role['vnet-hubben'] | Should -Be 'Hub'
        $role['vnet-spoke-a'] | Should -Be 'Spoke'
        $role['vnet-ensam'] | Should -Be 'Isolated'
    }
    It 'flags isolated networks, one-way peering and overlapping address spaces' {
        $h = Get-PageText 'rapport-struktur.html'
        $h | Should -Match 'Isolerade virtuella nät utan peering \(1\):</b> vnet-ensam'
        $h | Should -Match 'Ensidiga peerings \(1\):</b>'
        $h | Should -Match 'Överlappande adressrymder mellan olika nät \(1\):</b>'
        $h | Should -Match 'Hub-and-spoke'
    }
    It 'the anonymized version has no names, IDs or IP addresses but keeps the structure' {
        $h = [System.Web.HttpUtility]::HtmlDecode((Get-Content (Join-Path $script:RunDir 'anonym\rapport-struktur.html') -Raw))
        $h | Should -Not -Match 'vnet-hubben|vnet-spoke|vnet-ensam|fw-hubben|Kundbolaget|Plattform|rg-nat|11111111-1111|22222222-2222|99999999-8888'
        $h | Should -Not -Match '10\.0\.0\.0|10\.1\.0\.0|10\.2\.0\.0|10\.1\.5\.0'
        $h | Should -Match '<svg class="net-svg"'
        $h | Should -Match 'VNet 1'
        $h | Should -Match '/16'
    }
    It 'falls back on the data of Governance Visualizer when struktur\ is missing' {
        $d = @{ GvPresent = $true; GvRoles = @([pscustomobject]@{ Level = 0; MgId = 'root'; MgName = 'Tenant Root Group'; MgParentId = '__TenantRoot' }, [pscustomobject]@{ Level = 1; MgId = 'mg1'; MgName = 'Plattform'; MgParentId = 'root' }); GvPolicies = $null; GvSubs = @([pscustomobject]@{ SubscriptionId = 's1'; Subscription = 'Min sub'; ManagementGroupPath = 'root/mg1' }) }
        $rows = Get-MgRowsFromGovViz $d
        @($rows | Where-Object Typ -eq 'Managementgrupp').Count | Should -Be 2
        ($rows | Where-Object Id -eq 's1').Foralder | Should -Be 'mg1'
    }
}


Describe 'Language packs (lang\)' {
    BeforeAll {
        $script:LangDir = Join-Path $script:ScriptRoot 'lang'
        $script:Packs = @{}
        foreach ($f in Get-ChildItem $script:LangDir -Filter '*.psd1') { $script:Packs[$f.BaseName] = Import-PowerShellDataFile $f.FullName }
        function Get-Placeholders([string]$Text) { @([regex]::Matches($Text, '\{(\d+)(?::[^}]*)?\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',' }
    }
    It 'has English as the base, and Swedish' {
        $script:Packs.Keys | Should -Contain 'en'
        $script:Packs.Keys | Should -Contain 'sv'
    }
    It 'has the same keys in every language as in English' {
        foreach ($code in $script:Packs.Keys) {
            $missing = @($script:Packs['en'].Keys | Where-Object { -not $script:Packs[$code].ContainsKey($_) })
            $extra = @($script:Packs[$code].Keys | Where-Object { -not $script:Packs['en'].ContainsKey($_) })
            "${code}: saknar [$($missing -join ', ')]" | Should -Be "${code}: saknar []"
            "${code}: extra [$($extra -join ', ')]" | Should -Be "${code}: extra []"
        }
    }
    It 'uses the same placeholders in every language as in English' {
        foreach ($code in $script:Packs.Keys) {
            foreach ($k in $script:Packs['en'].Keys) {
                if (-not $script:Packs[$code].ContainsKey($k)) { continue }
                "${code}/${k}: $(Get-Placeholders $script:Packs[$code][$k])" | Should -Be "${code}/${k}: $(Get-Placeholders $script:Packs['en'][$k])"
            }
        }
    }
    It 'has no empty texts, and HTML only in keys that end in .html' {
        foreach ($code in $script:Packs.Keys) {
            foreach ($k in $script:Packs[$code].Keys) {
                [string]$script:Packs[$code][$k] | Should -Not -BeNullOrEmpty -Because "${code}/${k}"
                if ($k -notlike '*.html') { [string]$script:Packs[$code][$k] | Should -Not -Match '<[a-z/]' -Because "${code}/${k} är vanlig text och HTML-kodas av anroparen" }
            }
        }
    }
    It 'has every key that the code uses' {
        $used = foreach ($f in Get-ChildItem (Join-Path $script:ScriptRoot 'lib') -Filter '*.ps1') {
            [regex]::Matches((Get-Content $f.FullName -Raw), "\bT '([A-Za-z0-9_.]+)'") | ForEach-Object { $_.Groups[1].Value }
        }
        $used = @($used | Sort-Object -Unique | Where-Object { $_ -ne 'key' })
        $used.Count | Should -BeGreaterThan 100
        @($used | Where-Object { -not $script:Packs['en'].ContainsKey($_) }) | Should -BeNullOrEmpty
    }
    It 'T fills in the placeholders and gives the key in square brackets when it is missing' {
        [void](Initialize-Language 'sv')
        (T 'fmt.xOfY' 3 5) | Should -Be '3 av 5'
        (T 'finns.inte') | Should -Be '[finns.inte]'
    }
    It 'a key that is missing in a language falls back on English' {
        $dir = Join-Path $script:ScriptRoot 'lang'
        $tmp = Join-Path $dir 'zz.psd1'
        try {
            "@{ 'tile.low' = 'Lågt' }" | Set-Content $tmp -Encoding utf8
            Initialize-Language 'zz' | Should -Be 'zz'
            (T 'tile.low') | Should -Be 'Lågt'
            (T 'tile.medium') | Should -Be 'Medium'
        }
        finally { Remove-Item $tmp -ErrorAction SilentlyContinue; [void](Initialize-Language 'sv') }
    }
    It 'Initialize-Language warns and uses English for an unknown or invalid language' {
        $script:Warnings.Clear()
        Initialize-Language 'xx' | Should -Be 'en'
        Initialize-Language '..\x' | Should -Be 'en'
        $script:Warnings.Count | Should -Be 2
        Initialize-Language 'sv' | Should -Be 'sv'
    }
}

Describe 'The report in English' {
    BeforeAll {
        $script:RunDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory $script:RunDir | Out-Null
        $script:Dirs = @{ azqr = (Join-Path $script:RunDir 'azqr'); azgovviz = (Join-Path $script:RunDir 'azgovviz'); maester = (Join-Path $script:RunDir 'maester'); portal = (Join-Path $script:RunDir 'portal'); struktur = (Join-Path $script:RunDir 'struktur') }
        foreach ($d in $script:Dirs.Values) { New-Item -ItemType Directory $d | Out-Null }
        'Prenumeration,Plan,Niva', 'Prod,VirtualMachines,Standard', 'Prod,Containers,Free' | Set-Content (Join-Path $script:Dirs.portal 'defender-planer.csv') -Encoding utf8
        'Id,Namn,Typ,Foralder', 'mg-a,Plattform,Managementgrupp,', 's1,Prod,Prenumeration,mg-a' | Set-Content (Join-Path $script:Dirs.struktur 'managementgrupper.csv') -Encoding utf8
        $script:Status = [ordered]@{ azqr = @{ State = 'Fel'; Note = 'x' }; 'Defender och kostnad' = @{ State = 'OK'; Note = '' }; Struktur = @{ State = 'Partial'; Note = 'y' } }
        $script:ReportLanguage = 'en'
        $script:Index = Write-ReportSite
    }
    AfterAll { $script:ReportLanguage = 'sv'; [void](Initialize-Language 'sv'); Remove-Item $script:RunDir -Recurse -Force -ErrorAction SilentlyContinue }
    It 'writes the pages with English text and lang="en"' {
        $html = Get-PageText 'rapport.html'
        $html | Should -Match '<html lang="en">'
        $html | Should -Match 'Pages in the report'
        $html | Should -Match 'Save the whole report as PDF'
        $html | Should -Not -Match 'Sidor i rapporten'
        (Get-PageText 'rapport-defender-kostnad.html') | Should -Match 'Defender plans'
        (Get-PageText 'rapport-struktur.html') | Should -Match 'Management groups and subscriptions'
    }
    It 'shows steps and states in English (old Swedish values are understood too)' {
        $html = Get-PageText 'rapport-om.html'
        $html | Should -Match 'Run status'
        $html | Should -Match '<span class="pill failed">Failed</span>'
        $html | Should -Match '<span class="pill partial">Partial</span>'
        $html | Should -Match '<span class="pill ok">OK</span>'
        $html | Should -Match 'Defender and cost'
    }
    It 'has no missing keys on any page' {
        foreach ($f in Get-ChildItem $script:RunDir -Filter '*.html') { (Get-PageText $f.Name) | Should -Not -Match '\[[a-z]+\.[A-Za-z0-9_.]+\]' -Because $f.Name }
    }
    It 'takes the language from the theme when -ReportLanguage is not given' {
        $script:ReportLanguage = $null
        Resolve-ReportLanguage @{ Data = @{ language = 'sv' } } | Should -Be 'sv'
        Resolve-ReportLanguage @{ Data = @{ language = '' } } | Should -Be 'en'
        $script:ReportLanguage = 'sv'
        Resolve-ReportLanguage @{ Data = @{ language = 'en' } } | Should -Be 'sv'
        $script:ReportLanguage = 'en'
    }
}
