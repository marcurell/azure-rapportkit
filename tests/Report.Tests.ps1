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
    It 'läser temat molnpasvenska ur branding\' {
        $t = Get-BrandTheme 'molnpasvenska' $null
        $t.Data.name | Should -Be 'Moln på svenska'
        $t.Data.colors.light.accent | Should -Be '#f97316'
        $t.Data.colors.dark.bg | Should -Be '#060f09'
        $script:Warnings.Count | Should -Be 0
    }
    It 'läser det neutrala temat' {
        (Get-BrandTheme 'neutral' $null).Data.name | Should -Be 'Neutral'
    }
    It 'faller tillbaka på inbyggd standard och varnar när temat saknas' {
        $t = Get-BrandTheme 'finns-inte' $null
        $t.Data.name | Should -Be 'Neutral'
        $t.Source | Should -Be 'inbyggd standard'
        $script:Warnings.Count | Should -Be 1
    }
    It 'nekar temanamn med sökvägstecken (ingen path traversal)' {
        $t = Get-BrandTheme '..\..\Windows' $null
        $t.Source | Should -Be 'inbyggd standard'
        $script:Warnings[0] | Should -Match 'Ogiltigt temanamn'
    }
    It 'byter ut ogiltiga färger mot standardvärdet och varnar' {
        $dir = Join-Path $TestDrive 'bad'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Dåligt", "colors": { "light": { "accent": "red; } body{display:none" } } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $t = Get-BrandTheme $null $dir
        $t.Data.name | Should -Be 'Dåligt'
        $t.Data.colors.light.accent | Should -Be '#0969da'
        ($script:Warnings -join ' ') | Should -Match 'colors.light.accent'
    }
    It 'fyller i värden som saknas i ett ofullständigt tema' {
        $dir = Join-Path $TestDrive 'partial'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Delvis", "colors": { "light": { "accent": "#ff00aa" } } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $t = Get-BrandTheme $null $dir
        $t.Data.colors.light.accent | Should -Be '#ff00aa'
        $t.Data.colors.light.bg | Should -Be '#f6f8fa'
        $t.Data.colors.dark.text | Should -Be '#e6edf3'
    }
    It 'tål trasig JSON' {
        $dir = Join-Path $TestDrive 'broken'; New-Item -ItemType Directory $dir | Out-Null
        '{ inte json' | Set-Content (Join-Path $dir 'theme.json')
        (Get-BrandTheme $null $dir).Source | Should -Be 'inbyggd standard'
        $script:Warnings.Count | Should -BeGreaterThan 0
    }
}

Describe 'New-ThemeCss' {
    BeforeEach { $script:Warnings.Clear() }
    It 'innehåller temats variabler för ljust, mörkt och utskrift' {
        $css = New-ThemeCss (Get-BrandTheme 'molnpasvenska' $null)
        $css | Should -Match '--rk-accent:#f97316'
        $css | Should -Match '@media \(prefers-color-scheme:dark\)\{:root\{--rk-bg:#060f09'
        $css | Should -Match '@media print\{:root\{--rk-bg:#f0f5f1'
    }
    It 'lägger till temats custom.css sist, men bara inifrån temamappen' {
        $dir = Join-Path $TestDrive 'css'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Css", "customCss": "custom.css" }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        '.rk-top{outline:2px solid hotpink}' | Set-Content (Join-Path $dir 'custom.css')
        (New-ThemeCss (Get-BrandTheme $null $dir)) | Should -Match 'hotpink'
        $dir2 = Join-Path $TestDrive 'css2'; New-Item -ItemType Directory $dir2 | Out-Null
        '{ "name": "Ute", "customCss": "..\\css\\custom.css" }' | Set-Content (Join-Path $dir2 'theme.json') -Encoding utf8
        (New-ThemeCss (Get-BrandTheme $null $dir2)) | Should -Not -Match 'hotpink'
        ($script:Warnings -join ' ') | Should -Match 'utanför temamappen'
    }
}

Describe 'Get-LogoHtml' {
    BeforeEach { $script:Warnings.Clear() }
    It 'bygger ordbilden som ETT element med färgade delar' {
        $html = Get-LogoHtml (Get-BrandTheme 'molnpasvenska' $null)
        $html | Should -Match '^<span class="rk-wm">'
        $html | Should -Match 'rk-w-accent">svenska'
        ([regex]::Matches($html, '<span class="rk-wm">')).Count | Should -Be 1
    }
    It 'bäddar in en bildlogga som data-URI' {
        $dir = Join-Path $TestDrive 'logo'; New-Item -ItemType Directory $dir | Out-Null
        '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' | Set-Content (Join-Path $dir 'logo.svg')
        '{ "name": "Bild", "logo": { "type": "image", "file": "logo.svg", "alt": "Min <logga>" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        $html = Get-LogoHtml (Get-BrandTheme $null $dir)
        $html | Should -Match 'src="data:image/svg\+xml;base64,'
        $html | Should -Match 'alt="Min &lt;logga&gt;"'
    }
    It 'faller tillbaka på ordbild när loggan saknas eller ligger utanför temamappen' {
        $dir = Join-Path $TestDrive 'logo2'; New-Item -ItemType Directory $dir | Out-Null
        '{ "name": "Saknas", "logo": { "type": "image", "file": "..\\..\\x.png" } }' | Set-Content (Join-Path $dir 'theme.json') -Encoding utf8
        (Get-LogoHtml (Get-BrandTheme $null $dir)) | Should -Match 'rk-wm'
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
        "Prenumeration,Poang,Max,Andel`nSub,4,14,0.2857" | Set-Content (Join-Path $script:Dirs.portal 'secure-score.csv') -Encoding utf8
        "Prenumeration,Manad,Kostnad,Valuta`nSub,2026-09,100,SEK`nSub,2026-10,150,SEK" | Set-Content (Join-Path $script:Dirs.portal 'kostnad.csv') -Encoding utf8
        $mt = Join-Path $script:Dirs.maester 'test-results'; New-Item -ItemType Directory $mt | Out-Null
        @{ PassedCount = 1; FailedCount = 1; SkippedCount = 1; Tests = @(@{ Name = 'MT.1'; Result = 'Failed'; ResultDetail = @{ TestSkipped = $null } }, @{ Name = 'MT.2'; Result = 'Skipped'; ResultDetail = @{ TestSkipped = 'NotLicensedEntraIDP1' } }, @{ Name = 'MT.3'; Result = 'Passed'; ResultDetail = @{ TestSkipped = $null } }) } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $mt 'maester.json') -Encoding utf8

        $script:TenantId = '00000000-0000-0000-0000-000000000000'; $script:Period = '2026-10'
        $script:KitVersion = 'test'; $script:Pins = @{ Azqr = '1'; Maester = '1'; Pester = '1'; AzAccounts = '1' }; $script:GvVersion = '6'
        $script:HidePersonalData = $false; $script:LatestTools = $false
        $script:Status = [ordered]@{ azqr = @{ State = 'OK'; Note = '' }; Maester = @{ State = 'OK'; Note = '' } }
        $script:RunStart = Get-Date
        $script:Brand = 'molnpasvenska'; $script:BrandPath = $null
        $script:Warnings.Clear()
        $script:Index = Write-ReportSite
    }
    It 'skriver alla sex sidorna och ger startsidan' {
        $script:Index | Should -Match 'rapport\.html$'
        foreach ($f in 'rapport.html', 'rapport-styrning.html', 'rapport-resurser.html', 'rapport-entra.html', 'rapport-defender-kostnad.html', 'rapport-om.html') {
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
    It 'PDF-knappen öppnar den samlade rapporten med alla sex sidor' {
        $full = Get-Content (Join-Path $script:RunDir 'rapport-komplett.html') -Raw
        ([regex]::Matches($full, '<section class="rk-sec">')).Count | Should -Be 6
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
    It 'ger begripliga tomsidor när underlag saknas (Styrning utan Governance Visualizer)' {
        (Get-PageText 'rapport-styrning.html') | Should -Match 'Governance Visualizer har inte körts'
    }
    It 'kan byggas med ett annat tema' {
        $script:Brand = 'neutral'
        Write-ReportSite | Out-Null
        (Get-Content (Join-Path $script:RunDir 'rapport.html') -Raw) | Should -Match '--rk-accent:#0969da'
    }
}
