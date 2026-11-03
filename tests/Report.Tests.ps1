#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tester för rapportgeneratorn (lib\Report.ps1): tema, validering, länkar och sidbygge. Generatorn läses in med
  dot-source och får stubbar för det den annars hämtar från huvudscriptet. Inga inloggningar eller nedladdningar.

  Kör:  Invoke-Pester .\tests
#>

BeforeAll {
    $script:Root = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:ScriptRoot = $script:Root.Path

    # Funktioner som generatorn använder från huvudscriptet: läses ut med parsern, eller ersätts av stubbar.
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
    # Sidorna HTML-kodar svenska tecken (ö blir &#246;): avkoda innan texten jämförs.
    function Get-PageText([string]$File) { [System.Web.HttpUtility]::HtmlDecode((Get-Content (Join-Path $script:RunDir $File) -Raw)) }
}

Describe 'Test-CssColor och Test-CssFont' {
    It 'godkänner vanliga färgvärden' -ForEach @(
        @{ V = '#f97316' }, @{ V = '#fff' }, @{ V = 'rgb(1, 2, 3)' }, @{ V = 'rgba(0,0,0,.5)' }, @{ V = 'hsl(120, 50%, 40%)' }, @{ V = 'tomato' }
    ) { Test-CssColor $V | Should -BeTrue }
    It 'nekar värden som kan bryta ut ur CSS' -ForEach @(
        @{ V = 'red; } body { display:none' }, @{ V = 'url(http://x)' }, @{ V = '#zzz' }, @{ V = '' }, @{ V = 'red}</style><script>' }
    ) { Test-CssColor $V | Should -BeFalse }
    It 'godkänner typsnittslistor och nekar farliga' {
        Test-CssFont 'Inter, "Segoe UI", system-ui, sans-serif' | Should -BeTrue
        Test-CssFont 'x; } body{display:none' | Should -BeFalse
        Test-CssFont 'a</style>' | Should -BeFalse
    }
}

Describe 'Get-BrandTheme' {
    BeforeEach { $script:Warnings.Clear() }
    It 'läser temat i branding\ (Moln på svenska)' {
        $t = Get-BrandTheme
        $t.Data.name | Should -Be 'Moln på svenska'
        $t.Data.colors.light.accent | Should -Be '#f97316'
        $t.Data.colors.dark.bg | Should -Be '#060f09'
        $script:Warnings.Count | Should -Be 0
    }
    It 'läser det neutrala temat' {
        (Get-BrandTheme (Join-Path $script:ScriptRoot 'branding-exempel\neutral')).Data.name | Should -Be 'Neutral'
    }
    It 'faller tillbaka på inbyggd standard och varnar när temat saknas' {
        $t = Get-BrandTheme (Join-Path $TestDrive 'finns-inte')
        $t.Data.name | Should -Be 'Neutral'
        $t.Source | Should -Be 'built-in default'
        $script:Warnings.Count | Should -Be 1
    }
    It 'byter ut ogiltiga färger mot standardvärdet och varnar' {
        $dir = Join-Path $TestDrive 'bad'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Dåligt", "colors": { "light": { "accent": "red; } body{display:none" } } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $t = Get-BrandTheme $dir
        $t.Data.name | Should -Be 'Dåligt'
        $t.Data.colors.light.accent | Should -Be '#0969da'
        ($script:Warnings -join ' ') | Should -Match 'colors.light.accent'
    }
    It 'fyller i värden som saknas i ett ofullständigt tema' {
        $dir = Join-Path $TestDrive 'partial'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Delvis", "colors": { "light": { "accent": "#ff00aa" } } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $t = Get-BrandTheme $dir
        $t.Data.colors.light.accent | Should -Be '#ff00aa'
        $t.Data.colors.light.bg | Should -Be '#f6f8fa'
        $t.Data.colors.dark.text | Should -Be '#e6edf3'
    }
    It 'tål trasig JSON' {
        $dir = Join-Path $TestDrive 'broken'; New-Item -ItemType Directory $dir | Out-Null
        '{ inte json' | Set-Content (Join-Path $dir 'theme.json')
        (Get-BrandTheme $dir).Source | Should -Be 'built-in default'
        $script:Warnings.Count | Should -BeGreaterThan 0
    }
}

Describe 'New-ThemeCss' {
    BeforeEach { $script:Warnings.Clear() }
    It 'innehåller temats variabler för ljust, mörkt och utskrift' {
        $css = New-ThemeCss (Get-BrandTheme)
        $css | Should -Match '--rk-accent:#f97316'
        $css | Should -Match '@media \(prefers-color-scheme:dark\)\{:root\{--rk-bg:#060f09'
        $css | Should -Match '@media print\{:root\{--rk-bg:#f0f5f1'
    }
    It 'lägger till temats custom.css sist, men bara inifrån temamappen' {
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
    It 'bygger ordbilden som ETT element med färgade delar' {
        $html = Get-LogoHtml (Get-BrandTheme)
        $html | Should -Match '^<span class="rk-wm">'
        $html | Should -Match 'rk-w-accent">svenska'
        ([regex]::Matches($html, '<span class="rk-wm">')).Count | Should -Be 1
    }
    It 'bäddar in en bildlogga som data-URI' {
        $dir = Join-Path $TestDrive 'logo'; New-Item -ItemType Directory $dir | Out-Null
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' | Set-Content (Join-Path $dir 'logo.svg')
        '{ "name": "Bild", "logo": { "type": "image", "file": "logo.svg", "alt": "Min <logga>" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $html = Get-LogoHtml (Get-BrandTheme $dir)
        $html | Should -Match 'src="data:image/svg\+xml;base64,'
        $html | Should -Match 'alt="Min &lt;logga&gt;"'
    }
    It 'faller tillbaka på ordbild när loggan saknas eller ligger utanför temamappen' {
        $dir = Join-Path $TestDrive 'logo2'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Saknas", "logo": { "type": "image", "file": "..\\..\\x.png" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        (Get-LogoHtml (Get-BrandTheme $dir)) | Should -Match 'rk-wm'
        $script:Warnings.Count | Should -BeGreaterThan 0
    }
}

Describe 'Länkar och HTML-byggstenar' {
    It 'New-ExtLink öppnar i nytt fönster med noopener och kodar text och adress' {
        $a = New-ExtLink 'https://example.com/?a=1&b="2"' '<Rapport>'
        $a | Should -Match 'target="_blank"'
        $a | Should -Match 'rel="noopener noreferrer"'
        $a | Should -Not -Match '<Rapport>'
        $a | Should -Match '&amp;b=&quot;2&quot;'
    }
    It 'ConvertTo-HtmlTable kodar celler och visar Status som märke' {
        $rows = @([pscustomobject]@{ Namn = '<script>x</script>'; Status = 'Fel' })
        $html = ConvertTo-HtmlTable $rows @(@{ Name = 'Namn'; Label = 'Namn' }, @{ Name = 'Status'; Label = 'Status' })
        $html | Should -Not -Match '<script>'
        $html | Should -Match 'class="pill fel"'
    }
    It 'Tile blir en länk bara när adress anges' {
        (Tile 'A' 1 '' 'sida.html') | Should -Match '^<a class="tile'
        (Tile 'A' 1) | Should -Match '^<div class="tile'
    }
    It 'Get-UniqueRows behåller första raden per nyckel' {
        $rows = @([pscustomobject]@{ Id = 'a'; V = 1 }, [pscustomobject]@{ Id = 'a'; V = 2 }, [pscustomobject]@{ Id = 'b'; V = 3 })
        $u = Get-UniqueRows $rows 'Id'
        $u.Count | Should -Be 2
        $u[0].V | Should -Be 1
        Get-UniqueRows $null 'Id' | Should -BeNullOrEmpty
    }
    It 'ConvertTo-Number hanterar decimalkomma och punkt' {
        ConvertTo-Number '272,99' | Should -Be 272.99
        ConvertTo-Number '1.5' | Should -Be 1.5
        ConvertTo-Number 'abc' | Should -Be 0
    }
}

Describe 'Write-ReportSite (sidbygge)' {
    BeforeAll {
        # Ett litet resultatträd med syntetiska data för azqr, Defender och Maester
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
        # Varje Maester-körning lämnar en egen tidsstämplad HTML; rapporten ska länka till den senaste.
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
    It 'skriver alla sju sidorna och ger startsidan' {
        $script:Index | Should -Match 'rapport\.html$'
        foreach ($f in 'rapport.html', 'rapport-struktur.html', 'rapport-styrning.html', 'rapport-resurser.html', 'rapport-entra.html', 'rapport-defender-kostnad.html', 'rapport-om.html') {
            Test-Path (Join-Path $script:RunDir $f) | Should -BeTrue
        }
    }
    It 'har samma navigering och temat på varje sida' {
        foreach ($f in Get-ChildItem $script:RunDir -Filter 'rapport*.html') {
            $h = Get-Content $f.FullName -Raw
            $h | Should -Match 'class="rk-nav"'
            $h | Should -Match '--rk-accent:#f97316'
            # Den samlade PDF-sidan (rapport-komplett.html) markerar ingen enskild flik.
            ([regex]::Matches($h, 'aria-current="page"')).Count | Should -Be $(if ($f.Name -eq 'rapport-komplett.html') { 0 } else { 1 })
        }
    }
    It 'PDF-knappen öppnar den samlade rapporten med alla sju sidor' {
        $full = Get-Content (Join-Path $script:RunDir 'rapport-komplett.html') -Raw
        ([regex]::Matches($full, '<section class="rk-sec">')).Count | Should -Be 7
        (Get-Content (Join-Path $script:RunDir 'rapport.html') -Raw) | Should -Match 'href="rapport-komplett\.html#skriv" target="_blank"'
    }
    It 'hämtar inget från internet (inga src/href mot externa adresser utom kontaktlänken)' {
        foreach ($f in Get-ChildItem $script:RunDir -Filter 'rapport*.html') {
            $h = Get-Content $f.FullName -Raw
            $ext = [regex]::Matches($h, '(?:src|href)="(https?://[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            @($ext | Where-Object { $_ -ne 'https://molnpasvenska.se' }).Count | Should -Be 0
            $h | Should -Not -Match '<script\s+src='
        }
    }
    It 'visar azqr, Maester och kostnad på rätt sidor' {
        (Get-PageText 'rapport-resurser.html') | Should -Match 'Använd HTTPS'
        (Get-PageText 'rapport-entra.html') | Should -Match 'Licens saknas: Entra ID P1'
        (Get-PageText 'rapport-defender-kostnad.html') | Should -Match '2026-10'
    }
    It 'läser Defender-filer med de nya id-kolumnerna och länkar till senaste Maester-rapporten' {
        (Get-PageText 'rapport-defender-kostnad.html') | Should -Match '4/14'
        $h = Get-Content (Join-Path $script:RunDir 'rapport-entra.html') -Raw
        $h | Should -Match 'TestResults-2026-10-30-162523\.html'
        $h | Should -Not -Match 'TestResults-2026-10-30-151835\.html'
    }
    It 'ger begripliga tomsidor när underlag saknas (Styrning utan Governance Visualizer)' {
        (Get-PageText 'rapport-styrning.html') | Should -Match 'Governance Visualizer har inte körts'
    }
    It 'kan byggas med ett annat tema' {
        $script:BrandingDir = Join-Path $script:ScriptRoot 'branding-exempel\neutral'
        Write-ReportSite | Out-Null
        (Get-Content (Join-Path $script:RunDir 'rapport.html') -Raw) | Should -Match '--rk-accent:#0969da'
        $script:BrandingDir = $null
    }
}

Describe 'Val av resultatfiler när en mapp har flera körningar' {
    BeforeAll {
        $script:RunDir = Join-Path $TestDrive 'multi'
        $script:Dirs = @{}
        foreach ($n in 'azqr', 'azgovviz', 'maester', 'portal', 'struktur') { $script:Dirs[$n] = Join-Path $script:RunDir $n; New-Item -ItemType Directory -Force $script:Dirs[$n] | Out-Null }
    }
    BeforeEach { $script:Warnings.Clear() }
    It 'Find-ResultFile tar den senaste filen, och vid samma tid den med senast namn' {
        $d = Join-Path $TestDrive 'ff'; New-Item -ItemType Directory $d | Out-Null
        foreach ($n in 'A_20261030_153226_x.csv', 'A_20261030_162235_x.csv', 'A_20261030_154908_x.csv') { 'x' | Set-Content (Join-Path $d $n) }
        $t = Get-Date
        foreach ($f in Get-ChildItem $d) { $f.LastWriteTime = $t }
        (Find-ResultFile $d '*_x.csv').Name | Should -Be 'A_20261030_162235_x.csv'
        (Get-Item (Join-Path $d 'A_20261030_153226_x.csv')).LastWriteTime = $t.AddMinutes(5)
        (Find-ResultFile $d '*_x.csv').Name | Should -Be 'A_20261030_153226_x.csv'
        Find-ResultFile (Join-Path $d 'finns-inte') '*.csv' | Should -BeNullOrEmpty
    }
    It 'läser den senaste TestResults-filen, och maester.json bara om det inte finns någon' {
        $mt = Join-Path $script:Dirs.maester 'test-results'; New-Item -ItemType Directory $mt | Out-Null
        $mk = { param($name, $passed, $time) $p = Join-Path $mt $name; @{ PassedCount = $passed; FailedCount = 0; SkippedCount = 0; Tests = @() } | ConvertTo-Json | Set-Content $p -Encoding utf8; (Get-Item $p).LastWriteTime = $time }
        & $mk 'maester.json' 7 (Get-Date).AddHours(-1)             # left over from an earlier run, written last of all
        (Get-ReportData).Maester.PassedCount | Should -Be 7        # nothing else: the fallback is used
        & $mk 'TestResults-2026-10-30-100000.json' 1 (Get-Date).AddHours(-3)
        & $mk 'TestResults-2026-10-30-120000.json' 2 (Get-Date).AddHours(-2)
        (Get-ReportData).Maester.PassedCount | Should -Be 2        # the newest TestResults file wins over maester.json
    }
}

Describe 'Mörk logga och bakgrund' {
    BeforeEach { $script:Warnings.Clear() }
    It 'bäddar in en separat logga för mörkt läge' {
        $dir = Join-Path $TestDrive 'darklogo'; New-Item -ItemType Directory $dir | Out-Null
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' | Set-Content (Join-Path $dir 'l.svg')
        '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12"/>' | Set-Content (Join-Path $dir 'd.svg')
        '{ "name": "Mörk", "logo": { "type": "image", "file": "l.svg", "fileDark": "d.svg", "alt": "X" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $html = Get-LogoHtml (Get-BrandTheme $dir)
        $html | Should -Match 'rk-l-light'
        $html | Should -Match 'rk-l-dark'
        $script:Warnings.Count | Should -Be 0
    }
    It 'lägger in en bakgrundsbild i CSS och varnar om filen saknas' {
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

Describe 'Anonymisering' {
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
        $script:Anonymize = $true
        $script:Warnings.Clear()
        Write-ReportSite | Out-Null
    }
    AfterAll { $script:Anonymize = $false; $script:BrandingDir = $null }

    It 'bygger anonyma sidor i anonym\ och låter den vanliga rapporten vara orörd' {
        foreach ($f in 'rapport.html', 'rapport-resurser.html', 'rapport-komplett.html') { Test-Path (Join-Path $script:RunDir "anonym\$f") | Should -BeTrue }
        (Get-PageText 'rapport-resurser.html') | Should -Match 'app-kundnamn-01'
    }
    It 'byter ut resurs-, resursgrupps- och prenumerationsnamn samt ID:n' {
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
    It 'samma namn ger alltid samma alias, och olika namn olika alias' {
        Register-AnonData @{ GvRoles = @([pscustomobject]@{ ObjectType = 'User'; ObjectDisplayName = 'Kalle Testsson'; ObjectSignInName = 'kalle@kund.se' }, [pscustomobject]@{ ObjectType = 'User'; ObjectDisplayName = 'Lisa Provsson'; ObjectSignInName = 'lisa@kund.se' }) }
        $a = [System.Web.HttpUtility]::HtmlDecode((ConvertTo-AnonymousHtml '<td>Kalle Testsson</td><td>kalle@kund.se</td><td>Lisa Provsson</td><td>Kalle Testsson</td>'))
        $a | Should -Not -Match 'Kalle|Lisa|kund\.se'
        ([regex]::Matches($a, 'Användare 1')).Count | Should -Be 2
        $a | Should -Match 'Användare 2'
        $a | Should -Match 'anvandare1@exempel\.invalid'
    }
    It 'byter ut e-post, GUID och onmicrosoft-adresser som inte samlats in, men rör inte taggar' {
        Register-AnonData @{}
        $a = ConvertTo-AnonymousHtml '<a class="pill high" href="x.html">okänd@firma.com, 12345678-1234-1234-1234-123456789abc, bolag.onmicrosoft.com</a>'
        $a | Should -Match '<a class="pill high" href="x\.html">'
        $a | Should -Not -Match 'firma\.com|12345678-1234|bolag\.onmicrosoft'
        $a | Should -Match 'exempel\.invalid'
    }
    It 'ersätter länkar till verktygens egna rapporter med text' {
        Register-AnonData @{}
        $a = [System.Web.HttpUtility]::HtmlDecode((ConvertTo-AnonymousHtml (New-ExtLink 'azgovviz/AzGovViz_x.html' 'Governance Visualizer')))
        $a | Should -Not -Match 'href='
        $a | Should -Match 'ingår inte i den anonyma versionen'
        (ConvertTo-AnonymousHtml (New-ExtLink 'https://learn.microsoft.com/x' 'Docs')) | Should -Match 'href="https://learn.microsoft.com/x"'
    }
}

Describe 'Sidan Struktur' {
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
            (& $pe $hub 'vnet-hubben' $b 'vnet-spoke-b' $true)     # saknar motsvarande peering från spoke-b: ensidig
        ) | Export-Csv (Join-Path $s 'natverk-peerings.csv') -NoTypeInformation -Encoding utf8
        @([pscustomobject]@{ Typ = 'azurefirewalls'; Namn = 'fw-hubben'; Prenumeration = '11111111-1111-1111-1111-111111111111'; Resursgrupp = 'rg-nat'; Plats = 'northeurope'; Extra = 'AZFW_VNet'; VnetId = $hub }) | Export-Csv (Join-Path $s 'natverk-noder.csv') -NoTypeInformation -Encoding utf8
        @([pscustomobject]@{ Prenumeration = '11111111-1111-1111-1111-111111111111'; Resurser = 42 }) | Export-Csv (Join-Path $s 'resurser-per-prenumeration.csv') -NoTypeInformation -Encoding utf8

        $script:TenantId = '99999999-8888-7777-6666-555555555555'; $script:Period = '2026-10'
        $script:KitVersion = 'test'; $script:Pins = @{ Azqr = '1'; Maester = '1'; Pester = '1'; AzAccounts = '1' }; $script:GvVersion = '6'
        $script:HidePersonalData = $false; $script:LatestTools = $false
        $script:Status = [ordered]@{}
        $script:RunStart = Get-Date
        $script:BrandingDir = Join-Path $script:ScriptRoot 'branding-exempel\neutral'
        $script:Anonymize = $true
        $script:Warnings.Clear()
        Write-ReportSite | Out-Null
    }
    AfterAll { $script:Anonymize = $false; $script:BrandingDir = $null }

    It 'ConvertTo-CidrRange hanterar IPv4 och ignorerar annat' {
        $r = ConvertTo-CidrRange '10.0.0.0/16'
        ($r[1] - $r[0] + 1) | Should -Be 65536
        ConvertTo-CidrRange 'fd00::/8' | Should -BeNullOrEmpty
        ConvertTo-CidrRange '10.0.0.999/16' | Should -BeNullOrEmpty
    }
    It 'bygger sidan med träd, bild och tabeller' {
        $h = Get-PageText 'rapport-struktur.html'
        $h | Should -Match '<svg class="net-svg"'
        $h | Should -Match 'Plattform'
        $h | Should -Match 'Kundbolaget Hub'
        $h | Should -Match '42 resurser'
        $h | Should -Match 'fw-hubben'
    }
    It 'sätter roller: hub, spoke och isolerat' {
        $m = Get-NetworkModel @{ Vnets = @(Import-Csv (Join-Path $script:Dirs.struktur 'natverk-vnet.csv')); Peerings = @(Import-Csv (Join-Path $script:Dirs.struktur 'natverk-peerings.csv')); NetNodes = @(Import-Csv (Join-Path $script:Dirs.struktur 'natverk-noder.csv')); MgRows = @() }
        $role = @{}; foreach ($v in $m.Vnets) { $role[$v.Namn] = $m.Role[([string]$v.Id).ToLower()] }
        $role['vnet-hubben'] | Should -Be 'Hub'
        $role['vnet-spoke-a'] | Should -Be 'Spoke'
        $role['vnet-ensam'] | Should -Be 'Isolated'
    }
    It 'flaggar isolerade nät, ensidig peering och överlappande adressrymder' {
        $h = Get-PageText 'rapport-struktur.html'
        $h | Should -Match 'Isolerade virtuella nät utan peering \(1\):</b> vnet-ensam'
        $h | Should -Match 'Ensidiga peerings \(1\):</b>'
        $h | Should -Match 'Överlappande adressrymder mellan olika nät \(1\):</b>'
        $h | Should -Match 'Hub-and-spoke'
    }
    It 'den anonyma versionen saknar namn, ID:n och IP-adresser men behåller strukturen' {
        $h = [System.Web.HttpUtility]::HtmlDecode((Get-Content (Join-Path $script:RunDir 'anonym\rapport-struktur.html') -Raw))
        $h | Should -Not -Match 'vnet-hubben|vnet-spoke|vnet-ensam|fw-hubben|Kundbolaget|Plattform|rg-nat|11111111-1111|22222222-2222|99999999-8888'
        $h | Should -Not -Match '10\.0\.0\.0|10\.1\.0\.0|10\.2\.0\.0|10\.1\.5\.0'
        $h | Should -Match '<svg class="net-svg"'
        $h | Should -Match 'VNet 1'
        $h | Should -Match '/16'
    }
    It 'faller tillbaka på Governance Visualizers uppgifter när struktur\ saknas' {
        $d = @{ GvPresent = $true; GvRoles = @([pscustomobject]@{ Level = 0; MgId = 'root'; MgName = 'Tenant Root Group'; MgParentId = '__TenantRoot' }, [pscustomobject]@{ Level = 1; MgId = 'mg1'; MgName = 'Plattform'; MgParentId = 'root' }); GvPolicies = $null; GvSubs = @([pscustomobject]@{ SubscriptionId = 's1'; Subscription = 'Min sub'; ManagementGroupPath = 'root/mg1' }) }
        $rows = Get-MgRowsFromGovViz $d
        @($rows | Where-Object Typ -eq 'Managementgrupp').Count | Should -Be 2
        ($rows | Where-Object Id -eq 's1').Foralder | Should -Be 'mg1'
    }
}


Describe 'Språkpaket (lang\)' {
    BeforeAll {
        $script:LangDir = Join-Path $script:ScriptRoot 'lang'
        $script:Packs = @{}
        foreach ($f in Get-ChildItem $script:LangDir -Filter '*.psd1') { $script:Packs[$f.BaseName] = Import-PowerShellDataFile $f.FullName }
        function Get-Placeholders([string]$Text) { @([regex]::Matches($Text, '\{(\d+)(?::[^}]*)?\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',' }
    }
    It 'har engelska som bas och svenska' {
        $script:Packs.Keys | Should -Contain 'en'
        $script:Packs.Keys | Should -Contain 'sv'
    }
    It 'har samma nycklar i varje språk som i engelskan' {
        foreach ($code in $script:Packs.Keys) {
            $missing = @($script:Packs['en'].Keys | Where-Object { -not $script:Packs[$code].ContainsKey($_) })
            $extra = @($script:Packs[$code].Keys | Where-Object { -not $script:Packs['en'].ContainsKey($_) })
            "${code}: saknar [$($missing -join ', ')]" | Should -Be "${code}: saknar []"
            "${code}: extra [$($extra -join ', ')]" | Should -Be "${code}: extra []"
        }
    }
    It 'använder samma platshållare i varje språk som i engelskan' {
        foreach ($code in $script:Packs.Keys) {
            foreach ($k in $script:Packs['en'].Keys) {
                if (-not $script:Packs[$code].ContainsKey($k)) { continue }
                "${code}/${k}: $(Get-Placeholders $script:Packs[$code][$k])" | Should -Be "${code}/${k}: $(Get-Placeholders $script:Packs['en'][$k])"
            }
        }
    }
    It 'har inga tomma texter, och HTML bara i nycklar som slutar på .html' {
        foreach ($code in $script:Packs.Keys) {
            foreach ($k in $script:Packs[$code].Keys) {
                [string]$script:Packs[$code][$k] | Should -Not -BeNullOrEmpty -Because "${code}/${k}"
                if ($k -notlike '*.html') { [string]$script:Packs[$code][$k] | Should -Not -Match '<[a-z/]' -Because "${code}/${k} är vanlig text och HTML-kodas av anroparen" }
            }
        }
    }
    It 'har alla nycklar som koden använder' {
        $used = foreach ($f in Get-ChildItem (Join-Path $script:ScriptRoot 'lib') -Filter '*.ps1') {
            [regex]::Matches((Get-Content $f.FullName -Raw), "\bT '([A-Za-z0-9_.]+)'") | ForEach-Object { $_.Groups[1].Value }
        }
        $used = @($used | Sort-Object -Unique | Where-Object { $_ -ne 'key' })
        $used.Count | Should -BeGreaterThan 100
        @($used | Where-Object { -not $script:Packs['en'].ContainsKey($_) }) | Should -BeNullOrEmpty
    }
    It 'T fyller i platshållare och ger nyckeln i hakparenteser när den saknas' {
        [void](Initialize-Language 'sv')
        (T 'fmt.xOfY' 3 5) | Should -Be '3 av 5'
        (T 'finns.inte') | Should -Be '[finns.inte]'
    }
    It 'en nyckel som saknas i ett språk faller tillbaka på engelska' {
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
    It 'Initialize-Language varnar och använder engelska för okänt eller ogiltigt språk' {
        $script:Warnings.Clear()
        Initialize-Language 'xx' | Should -Be 'en'
        Initialize-Language '..\x' | Should -Be 'en'
        $script:Warnings.Count | Should -Be 2
        Initialize-Language 'sv' | Should -Be 'sv'
    }
}

Describe 'Rapporten på engelska' {
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
    It 'skriver sidorna med engelsk text och lang="en"' {
        $html = Get-PageText 'rapport.html'
        $html | Should -Match '<html lang="en">'
        $html | Should -Match 'Pages in the report'
        $html | Should -Match 'Save the whole report as PDF'
        $html | Should -Not -Match 'Sidor i rapporten'
        (Get-PageText 'rapport-defender-kostnad.html') | Should -Match 'Defender plans'
        (Get-PageText 'rapport-struktur.html') | Should -Match 'Management groups and subscriptions'
    }
    It 'visar steg och status på engelska (gamla svenska värden förstås också)' {
        $html = Get-PageText 'rapport-om.html'
        $html | Should -Match 'Run status'
        $html | Should -Match '<span class="pill failed">Failed</span>'
        $html | Should -Match '<span class="pill partial">Partial</span>'
        $html | Should -Match '<span class="pill ok">OK</span>'
        $html | Should -Match 'Defender and cost'
    }
    It 'har inga nycklar som saknas på någon sida' {
        foreach ($f in Get-ChildItem $script:RunDir -Filter '*.html') { (Get-PageText $f.Name) | Should -Not -Match '\[[a-z]+\.[A-Za-z0-9_.]+\]' -Because $f.Name }
    }
    It 'tar språket från temat när -ReportLanguage saknas' {
        $script:ReportLanguage = $null
        Resolve-ReportLanguage @{ Data = @{ language = 'sv' } } | Should -Be 'sv'
        Resolve-ReportLanguage @{ Data = @{ language = '' } } | Should -Be 'en'
        $script:ReportLanguage = 'sv'
        Resolve-ReportLanguage @{ Data = @{ language = 'en' } } | Should -Be 'sv'
        $script:ReportLanguage = 'en'
    }
}
