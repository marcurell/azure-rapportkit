#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests for the language packs (lib\Lang.ps1, lang\*.psd1) and for the language handling when a kit is packed (lib\Packaging.ps1).

  Run:  Invoke-Pester .\tests
#>

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ScriptRoot = $script:Repo
    $script:Warnings = [System.Collections.Generic.List[string]]::new()
    function Add-Warning([string]$msg) { $script:Warnings.Add($msg) }
    . (Join-Path $script:Repo 'lib\Lang.ps1')
    . (Join-Path $script:Repo 'lib\Packaging.ps1')

    function Get-Placeholders([string]$Text) {
        $t = $Text.Replace('{{', '').Replace('}}', '')
        @([regex]::Matches($t, '\{(\d+)(?::[^}]*)?\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    }
}

Describe 'Språkpaketen' {
    BeforeAll {
        $script:Packs = @{}
        foreach ($f in Get-ChildItem (Join-Path $script:Repo 'lang') -Filter '*.psd1') { $script:Packs[$f.BaseName] = Import-PowerShellDataFile $f.FullName }
    }
    It 'alla paket har samma nycklar som engelskan' {
        foreach ($code in $script:Packs.Keys | Where-Object { $_ -ne 'en' }) {
            @($script:Packs['en'].Keys | Where-Object { -not $script:Packs[$code].ContainsKey($_) }) | Should -BeNullOrEmpty
            @($script:Packs[$code].Keys | Where-Object { -not $script:Packs['en'].ContainsKey($_) }) | Should -BeNullOrEmpty
        }
    }
    It 'alla paket har samma platshållare ({0}, {1} ...) som engelskan, och inga lösa klammrar' {
        foreach ($code in $script:Packs.Keys) {
            foreach ($k in $script:Packs[$code].Keys) {
                $text = [string]$script:Packs[$code][$k]
                $stray = $text.Replace('{{', '').Replace('}}', '') -replace '\{\d+(?::[^}]*)?\}', ''
                ($stray -match '[{}]') | Should -BeFalse -Because "$code/$k has a stray brace"
                (Get-Placeholders $text) -join ',' | Should -Be ((Get-Placeholders ([string]$script:Packs['en'][$k])) -join ',') -Because "$code/$k"
            }
        }
    }
}

Describe 'Get-LanguageChain' {
    It 'går från kod med region till språket och sist engelska' {
        (Get-LanguageChain 'sv-SE') -join ',' | Should -Be 'sv-se,sv,en'
        (Get-LanguageChain 'sv') -join ',' | Should -Be 'sv,en'
        (Get-LanguageChain 'en') -join ',' | Should -Be 'en'
        (Get-LanguageChain 'sv-SE' -NoFallback) -join ',' | Should -Be 'sv-se,sv'
        (Get-LanguageChain '') -join ',' | Should -Be 'en'
    }
}

Describe 'Initialize-Language' {
    BeforeEach { $script:Warnings.Clear() }
    It 'laddar svenska för sv, SV och sv-SE (språket utan region används när koden med region saknas)' {
        foreach ($c in 'sv', 'SV', 'sv-SE') {
            Initialize-Language $c | Should -Be 'sv'
            (T 'state.on') | Should -Be 'På'
        }
        $script:Warnings.Count | Should -Be 0
    }
    It 'ger engelska för en och en-GB utan varning' {
        foreach ($c in 'en', 'EN', 'en-GB', '') { Initialize-Language $c | Should -Be 'en' }
        (T 'state.on') | Should -Be 'On'
        $script:Warnings.Count | Should -Be 0
    }
    It 'varnar och ger engelska för språk som saknas eller är ogiltiga, och räknar upp paketen' {
        Initialize-Language 'xx' | Should -Be 'en'
        $script:Warnings[0] | Should -Match "No language pack for 'xx' \(available: en, sv\)"
        $script:Warnings.Clear()
        Initialize-Language '../x' | Should -Be 'en'
        $script:Warnings[0] | Should -Match 'Invalid report language'
    }
}

Describe 'T' {
    BeforeAll {
        $script:Fake = Join-Path $TestDrive 'fake'
        New-Item -ItemType Directory (Join-Path $script:Fake 'lang') | Out-Null
        "@{ 'ok' = 'a {0}'; 'bad' = 'a {0} {1}'; 'plain' = 'no args'; 'braces' = 'x {{y}} {0}' }" | Set-Content (Join-Path $script:Fake 'lang\en.psd1') -Encoding utf8
    }
    BeforeEach { $script:Warnings.Clear(); $script:BadLangKeys = $null; $real = $script:ScriptRoot; $script:ScriptRoot = $script:Fake; [void](Initialize-Language 'en'); $script:ScriptRoot = $real }
    AfterAll { $script:ScriptRoot = $script:Repo; $script:BadLangKeys = $null; [void](Initialize-Language 'en') }
    It 'fyller i argument och låter {{ }} bli klammrar' {
        T 'ok' 'x' | Should -Be 'a x'
        T 'braces' 'z' | Should -Be 'x {y} z'
        T 'plain' | Should -Be 'no args'
    }
    It 'visar [nyckel] för text som saknas' {
        T 'finns-inte' | Should -Be '[finns-inte]'
    }
    It 'stoppar inte rapporten vid trasig platshållare: ger texten som den är och varnar en gång' {
        T 'bad' 'x' | Should -Be 'a {0} {1}'
        T 'bad' 'y' | Should -Be 'a {0} {1}'
        $script:Warnings.Count | Should -Be 1
        $script:Warnings[0] | Should -Match "'bad'.*faulty placeholder"
    }
}

Describe 'Set-ThemeLanguage' {
    It 'lägger till language i ett tema, byter det som finns, och klarar ett tomt tema {}' {
        $f = Join-Path $TestDrive 't1.json'
        '{ "name": "A" }' | Set-Content $f -Encoding utf8
        Set-ThemeLanguage $f 'sv'
        (Get-Content $f -Raw | ConvertFrom-Json).language | Should -Be 'sv'
        (Get-Content $f -Raw | ConvertFrom-Json).name | Should -Be 'A'
        Set-ThemeLanguage $f 'en'
        (Get-Content $f -Raw | ConvertFrom-Json).language | Should -Be 'en'
        '{}' | Set-Content $f -Encoding utf8
        Set-ThemeLanguage $f 'sv'
        (Get-Content $f -Raw | ConvertFrom-Json).language | Should -Be 'sv'
        "{`n}" | Set-Content $f -Encoding utf8
        Set-ThemeLanguage $f 'sv'
        (Get-Content $f -Raw | ConvertFrom-Json).language | Should -Be 'sv'
    }
}

Describe 'Copy-CustomerDocs' {
    It 'väljer svenska dokument för sv-SE, och engelska för språk utan dokument' {
        foreach ($case in @(@('sv-SE', 'sv', 'Extrahera alla'), @('sv', 'sv', 'Extrahera alla'), @('en', 'en', 'Extract All'), @('de', 'en', 'Extract All'))) {
            $stage = Join-Path $TestDrive ('stage-' + $case[0]); New-Item -ItemType Directory $stage | Out-Null
            Copy-CustomerDocs $script:Repo $stage $case[0] | Should -Be $case[1]
            (Get-Content (Join-Path $stage 'README.md') -Raw -Encoding UTF8) | Should -Match $case[2]
        }
        Test-Path (Join-Path $TestDrive 'stage-sv-SE\docs\Azure-Rapportkit-Kundguide.docx') | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'stage-de\docs\Azure-Rapportkit-Customer-guide.docx') | Should -BeTrue
    }
}
