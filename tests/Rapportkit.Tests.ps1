#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Enhetstester för de rena hjälpfunktionerna i Run-Rapportkit.ps1. Funktionerna läses ut ur scriptet med parsern (AST),
  så scriptet körs inte (inga inloggningar eller nedladdningar).

  Kör:  Invoke-Pester .\tests
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Run-Rapportkit.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
    $wanted = 'Fail', 'Get-ErrorText', 'Get-SignInHelp', 'Test-ActionAllowed', 'Format-Wrap', 'Format-Duration',
              'Import-CsvChecked', 'Get-OutputRootWarnings', 'Assert-FileHash', 'Get-RoleInstructions', 'Test-Zip', 'Get-SourceStates',
              'Get-GraphThrottleGiveUps', 'Get-ZipFiles', 'New-ResultZip'
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

    # Stubbar för det funktionerna anropar i scriptet
    $script:Warnings = [System.Collections.Generic.List[string]]::new()
    function Add-Warning([string]$msg) { $script:Warnings.Add($msg) }
    function Write-Ok($m) { }
    function Write-Warn2($m) { }
    function Write-Log($l, $m) { }
    $script:AllowUnverified = $false
}

Describe 'Funktionerna hittas i scriptet' {
    It 'alla förväntade funktioner finns' {
        foreach ($n in 'Fail', 'Get-SignInHelp', 'Test-ActionAllowed', 'Format-Wrap', 'Import-CsvChecked', 'Assert-FileHash', 'Get-RoleInstructions') {
            Get-Command $n -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Fail' {
    It 'kastar ett fel med åtgärdstext i Data["Fix"]' {
        $err = $null
        try { Fail 'Något gick fel.' 'Gör så här.' } catch { $err = $_.Exception }
        $err.Message | Should -Be 'Något gick fel.'
        $err.Data['Fix'] | Should -Be 'Gör så här.'
    }
}

Describe 'Get-SignInHelp' {
    It 'känner igen Conditional Access och consent-fel' -ForEach @(
        @{ Text = 'AADSTS53003: Access has been blocked by Conditional Access policies' }
        @{ Text = 'AADSTS50076: you must use multi-factor authentication' }
        @{ Text = 'AADSTS65001: The user has not consented to use the application' }
        @{ Text = 'AADSTS530003: device is not compliant' }
    ) {
        Get-SignInHelp $Text | Should -Match 'Conditional Access|villkorsstyrda'
    }
    It 'ger ingen text för vanliga fel' {
        Get-SignInHelp 'The term foo is not recognized' | Should -BeNullOrEmpty
    }
    It 'läggs till av Get-ErrorText' {
        $e = [System.Exception]::new('AADSTS53003 blockerad')
        Get-ErrorText $e | Should -Match 'Microsoft Azure CLI'
    }
}

Describe 'Test-ActionAllowed' {
    BeforeAll {
        $script:reader = @([pscustomobject]@{ actions = @('*/read'); notActions = @() })
        $script:custom = @([pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Delete') })
    }
    It 'tillåter läsning via */read' { Test-ActionAllowed $script:reader 'Microsoft.Security/assessments/read' | Should -BeTrue }
    It 'nekar skrivning med enbart */read' { Test-ActionAllowed $script:reader 'Microsoft.Storage/storageAccounts/write' | Should -BeFalse }
    It 'respekterar notActions' {
        Test-ActionAllowed $script:custom 'Microsoft.Authorization/roleAssignments/Delete' | Should -BeFalse
        Test-ActionAllowed $script:custom 'Microsoft.Compute/virtualMachines/read' | Should -BeTrue
    }
    It 'nekar när behörigheter saknas' { Test-ActionAllowed $null 'Microsoft.Security/assessments/read' | Should -BeFalse }
}

Describe 'Format-Wrap och Format-Duration' {
    It 'radbryter vid ord utan att överskrida bredden' {
        $lines = Format-Wrap 'en två tre fyra fem sex sju åtta nio tio elva tolv' 20
        $lines.Count | Should -BeGreaterThan 2
        ($lines | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessOrEqual 20
    }
    It 'ger inga rader för tom text' { (Format-Wrap '' 20).Count | Should -Be 0 }
    It 'formaterar tid' {
        Format-Duration 42 | Should -Match '^42 s$'
        Format-Duration 125 | Should -Match '^2 min 05 s$'
    }
}

Describe 'Import-CsvChecked' {
    BeforeEach { $script:Warnings.Clear() }
    It 'läser en giltig fil' {
        $p = Join-Path $TestDrive 'ok.csv'
        "Impact,Category`nHigh,Security`nLow,Cost" | Set-Content $p
        (Import-CsvChecked $p @('Impact', 'Category')).Count | Should -Be 2
        $script:Warnings.Count | Should -Be 0
    }
    It 'varnar och ger $null när kolumner saknas' {
        $p = Join-Path $TestDrive 'bad.csv'
        "Pakt,Category`nHigh,Security" | Set-Content $p
        Import-CsvChecked $p @('Impact', 'Category') | Should -BeNullOrEmpty
        $script:Warnings.Count | Should -Be 1
        $script:Warnings[0] | Should -Match 'missing the columns: Impact'
    }
    It 'varnar för en tom fil' {
        $p = Join-Path $TestDrive 'empty.csv'
        '' | Set-Content $p -NoNewline
        Import-CsvChecked $p @('Impact') | Should -BeNullOrEmpty
        $script:Warnings.Count | Should -Be 1
    }
}

Describe 'Get-OutputRootWarnings' {
    It 'varnar för OneDrive' {
        $old = $env:OneDrive; $env:OneDrive = 'C:\Users\test\OneDrive'
        try { (Get-OutputRootWarnings 'C:\Users\test\OneDrive\rapportkit') -join ' ' | Should -Match 'OneDrive' } finally { $env:OneDrive = $old }
    }
    It 'varnar för långa sökvägar' {
        (Get-OutputRootWarnings ('C:\' + ('a' * 100))) -join ' ' | Should -Match 'is long'
    }
    It 'varnar inte för en vanlig kort mapp' {
        (Get-OutputRootWarnings 'C:\rapportkit').Count | Should -Be 0
    }
}

Describe 'Assert-FileHash' {
    BeforeAll {
        $script:f = Join-Path $TestDrive 'data.bin'
        [IO.File]::WriteAllBytes($script:f, [byte[]](1..50))
        $script:hash = (Get-FileHash $script:f -Algorithm SHA256).Hash
    }
    BeforeEach { $script:Warnings.Clear(); $script:AllowUnverified = $false }
    It 'godkänner rätt kontrollsumma' { { Assert-FileHash $script:f $script:hash 'test' } | Should -Not -Throw }
    It 'gör inget när ingen kontrollsumma är angiven' { { Assert-FileHash $script:f '' 'test' } | Should -Not -Throw }
    It 'avbryter med åtgärd när kontrollsumman inte stämmer' {
        $err = $null
        try { Assert-FileHash $script:f ('0' * 64) 'test' } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.Data['Fix'] | Should -Match 'run the script again|Run the script again'
    }
    It 'varnar men fortsätter med -AllowUnverified' {
        $script:AllowUnverified = $true
        { Assert-FileHash $script:f ('0' * 64) 'test' } | Should -Not -Throw
        $script:Warnings.Count | Should -Be 1
    }
}

Describe 'Get-RoleInstructions' {
    It 'nämner PIM och ger kommandon för varje saknad Azure-roll' {
        $missing = @(
            [pscustomobject]@{ Kind = 'Azure'; Role = 'Reader' },
            [pscustomobject]@{ Kind = 'Azure'; Role = 'Security Reader' }
        )
        $text = (Get-RoleInstructions $missing) -join "`n"
        $text | Should -Match 'Privileged Identity Management'
        $text | Should -Match 'az role assignment create .*"Reader"'
        $text | Should -Match 'az role assignment create .*"Security Reader"'
    }
    It 'nämner Global Reader för Entra-rollen' {
        ((Get-RoleInstructions @([pscustomobject]@{ Kind = 'Entra'; Role = 'Global Reader' })) -join "`n") | Should -Match 'Global Reader'
    }
}

Describe 'Test-Zip' {
    It 'känner igen en hel zip med rätt innehåll och en trasig fil' {
        $dir = Join-Path $TestDrive 'z'; New-Item -ItemType Directory $dir | Out-Null
        Set-Content (Join-Path $dir 'azqr.exe') 'x'
        $zip = Join-Path $TestDrive 'ok.zip'
        Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip
        Test-Zip $zip '*azqr.exe' | Should -BeTrue
        Test-Zip $zip '*finns-inte*' | Should -BeFalse
        $bad = Join-Path $TestDrive 'bad.zip'; Set-Content $bad 'inte en zip'
        Test-Zip $bad '*' | Should -BeFalse
    }
}

Describe 'Get-SourceStates (run-summary.json)' {
    BeforeEach { $script:PortalSources = $null }
    It 'delar steget Defender och kostnad i källor när steg 9 körde' {
        $script:Status = [ordered]@{ azqr = @{ State = 'OK'; Note = '' }; 'Defender and cost' = @{ State = 'Partial'; Note = 'x' } }
        $script:PortalSources = [ordered]@{ plans = @{ state = 'OK'; note = '' }; recommendations = @{ state = 'Partial'; note = 'list is short' }; cost = @{ state = 'OK'; note = '' } }
        $r = Get-SourceStates
        $r['azqr'].state | Should -Be 'OK'
        $r['recommendations'].state | Should -Be 'Partial'
        $r['cost'].state | Should -Be 'OK'
        $r.Contains('Defender and cost') | Should -BeFalse
    }
    It 'ger alla Defender- och kostnadskällor stegets status när steg 9 hoppades över eller föll' {
        $script:Status = [ordered]@{ 'Defender and cost' = @{ State = 'Skipped'; Note = '' } }
        $r = Get-SourceStates
        foreach ($k in 'plans', 'secureScore', 'secureScoreControls', 'recommendations', 'cost') { $r[$k].state | Should -Be 'Skipped' }
        $r.Contains('azqr') | Should -BeFalse
    }
}

Describe 'Get-GraphThrottleGiveUps' {
    BeforeAll {
        # How Graph throttling looks in the console log: the same failure is logged once per layer.
        $script:Fail = 'PS>TerminatingError(Invoke-MgGraphRequest): "Too many retries performed. More than 3 retries encountered while sending the request."' + "`n" +
                       '>> TerminatingError(Invoke-MtGraphRequestCache): "Too many retries performed."' + "`n" +
                       '>> TerminatingError(Invoke-MtGraphRequestCache): "Too many retries performed."' + "`n"
        $script:Retry = '{"error":{"code":"TooManyRequests","message":"Too many requests. Please retry."}}' + "`n"
    }
    It 'räknar varje misslyckat anrop en gång, inte en gång per loggat lager' {
        $log = Join-Path $TestDrive 'c1.log'
        Set-Content $log ($script:Fail * 3) -NoNewline
        Get-GraphThrottleGiveUps $log | Should -Be 3
    }
    It 'räknar bara från där steget började (loggen får text från tidigare körningar)' {
        $log = Join-Path $TestDrive 'c2.log'
        Set-Content $log ($script:Fail * 5) -NoNewline
        $from = (Get-Item $log).Length
        Add-Content $log ($script:Fail * 2) -NoNewline
        Get-GraphThrottleGiveUps $log $from | Should -Be 2
        Get-GraphThrottleGiveUps $log 0 | Should -Be 7
    }
    It 'ger 0 när anropen bara fick försöka igen, eller när loggen saknas' {
        $log = Join-Path $TestDrive 'c3.log'
        Set-Content $log ($script:Retry * 20) -NoNewline
        Get-GraphThrottleGiveUps $log | Should -Be 0
        Get-GraphThrottleGiveUps (Join-Path $TestDrive 'finns-inte.log') | Should -Be 0
    }
    It 'läser en logg som skripten fortfarande skriver i' {
        $log = Join-Path $TestDrive 'c4.log'
        $w = [System.IO.File]::Open($log, 'Create', 'Write', 'Read')
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:Fail); $w.Write($bytes, 0, $bytes.Length); $w.Flush()
            Get-GraphThrottleGiveUps $log | Should -Be 1
        }
        finally { $w.Dispose() }
    }
    It 'sätter Maester till Partial och varnar när något gav upp' {
        $code = Get-Content $script:ScriptPath -Raw -Encoding UTF8
        $code | Should -Match 'Set-Status ''Maester'' ''Partial'' \$note'
        $code | Should -Match 'Get-GraphThrottleGiveUps \$consoleLog \$consoleFrom'
    }
}

Describe 'Zip av resultatmappen' {
    BeforeAll {
        $script:Run = Join-Path $TestDrive 'run'
        $files = @(
            'rapportkit.log', 'rapportkit-console.log', 'run-summary.json', 'rapport.html',
            'azqr/azqr_2026-11.json',
            'portal/kostnad.csv',
            'maester/maester-tests/ad/computer/Test-One.Tests.ps1', 'maester/maester-tests/maester-config.json',
            'maester/test-results/maester.json',
            'maester/test-results/TestResults-2026-11-02-084920.json', 'maester/test-results/TestResults-2026-11-02-084920.html', 'maester/test-results/TestResults-2026-11-02-084920-summary.md',
            'maester/test-results/TestResults-2026-11-03-135205.json', 'maester/test-results/TestResults-2026-11-03-135205.html', 'maester/test-results/TestResults-2026-11-03-135205-summary.md',
            'azgovviz/AzGovViz_6.7.2_20261102_084514_g_Roles.csv',
            'azgovviz/AzGovViz_6.7.2_20261103_114034_g_Roles.csv',
            'azgovviz/AzGovViz_6.7.2_20261103_114034_g.html',
            'azgovviz/HTML-Subscriptions_g_20261102_084514/s1.html',
            'azgovviz/HTML-Subscriptions_g_20261103_114034/s1.html',
            'azgovviz/JSON_g_20261102_084514/a.json',
            'azgovviz/JSON_g_20261103_114034/a.json')
        foreach ($f in $files) {
            $p = Join-Path $script:Run $f; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
            Set-Content $p "innehåll $f" -Encoding utf8
        }
        $script:Entries = @(Get-ZipFiles $script:Run | ForEach-Object { $_.Entry })
    }
    It 'tar med den senaste körningen av AzGovViz och Maester och lämnar de äldre' {
        $script:Entries | Should -Contain 'azgovviz/AzGovViz_6.7.2_20261103_114034_g_Roles.csv'
        $script:Entries | Should -Contain 'azgovviz/AzGovViz_6.7.2_20261103_114034_g.html'
        $script:Entries | Should -Contain 'azgovviz/HTML-Subscriptions_g_20261103_114034/s1.html'
        $script:Entries | Should -Contain 'azgovviz/JSON_g_20261103_114034/a.json'
        $script:Entries | Should -Contain 'maester/test-results/TestResults-2026-11-03-135205.json'
        $script:Entries | Should -Contain 'maester/test-results/TestResults-2026-11-03-135205-summary.md'
        @($script:Entries | Where-Object { $_ -like '*20261102*' -or $_ -like '*2026-11-02-*' }).Count | Should -Be 0
    }
    It 'tar med resten, men inte konsolloggen eller Maesters testsvit' {
        foreach ($e in 'rapportkit.log', 'run-summary.json', 'rapport.html', 'azqr/azqr_2026-11.json', 'portal/kostnad.csv', 'maester/test-results/maester.json') { $script:Entries | Should -Contain $e }
        $script:Entries | Should -Not -Contain 'rapportkit-console.log'
        @($script:Entries | Where-Object { $_ -like 'maester/maester-tests/*' }).Count | Should -Be 0
    }
    It 'New-ResultZip skriver en zip med snedstreck i namnen och orört innehåll' {
        $zip = Join-Path $TestDrive 'out.zip'
        New-ResultZip $script:Run $zip
        Test-Zip $zip '*rapport.html' | Should -BeTrue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $names = @($z.Entries | ForEach-Object FullName)
            $names.Count | Should -Be $script:Entries.Count
            @($names | Where-Object { $_ -match '\\' }).Count | Should -Be 0
            $e = $z.GetEntry('azqr/azqr_2026-11.json')
            $r = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8); $txt = $r.ReadToEnd(); $r.Dispose()
            $txt.Trim() | Should -Be 'innehåll azqr/azqr_2026-11.json'
        }
        finally { $z.Dispose() }
    }
    It 'läser en fil som något annat håller öppen för skrivning' {
        $busy = Join-Path $script:Run 'rapportkit.log'
        $h = [System.IO.File]::Open($busy, 'Open', 'Write', 'ReadWrite')
        try {
            $zip = Join-Path $TestDrive 'busy.zip'
            { New-ResultZip $script:Run $zip } | Should -Not -Throw
            Test-Zip $zip 'rapportkit.log' | Should -BeTrue
        }
        finally { $h.Dispose() }
    }
}

Describe 'azqr körs utan maskning av prenumerations-id' {
    It 'anropet har --mask=false när azqr har flaggan' {
        $code = Get-Content $script:ScriptPath -Raw -Encoding UTF8
        $code | Should -Match '@\(''--mask=false''\) \+ \$azqrArgs'
        $code | Should -Match 'azqr scan @azqrArgs'
        $code | Should -Match "azqr scan --help"
        $code | Should -Not -Match 'azqr scan --json'
    }
}

Describe 'Pinnade versioner i scriptet' {
    It 'har kontrollsummor i rätt format' {
        $src = Get-Content $script:ScriptPath -Raw
        $src | Should -Match "AzqrSha256\s*=\s*'[0-9A-F]{64}'"
        $src | Should -Match "GovVizSha256\s*=\s*'[0-9A-F]{64}'"
    }
}

Describe 'Azure CLI utan winget och valfri kryptering' {
    BeforeAll { $script:Src = Get-Content $script:ScriptPath -Raw }
    It 'installerar Azure CLI via signerad MSI när winget saknas eller misslyckas' {
        $script:Src | Should -Match 'function Install-AzureCli'
        $script:Src | Should -Match 'Get-AuthenticodeSignature'
        $script:Src | Should -Match "O=Microsoft Corporation"
        $script:Src | Should -Match "else \{ Install-AzureCli \}"
    }
    It 'förkontrollen kallar inte saknat winget för ett fel (Azure CLI kan hämtas ändå)' {
        $script:Src | Should -Not -Match "Add-Check 'SAKNAS' 'winget'"
    }
    It 'frågar om kryptering innan lösenordet, och -Yes betyder ja' {
        $script:Src | Should -Match 'Do you want to encrypt the result package'
        $script:Src | Should -Match '-not \$NoEncrypt -and -not \$ZipPassword -and -not \$Yes'
    }
}

Describe 'Branding: en mapp, ingen flagga' {
    It 'scriptet har varken -Brand eller -BrandPath' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $names = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Not -Contain 'Brand'
        $names | Should -Not -Contain 'BrandPath'
    }
    It 'Pack-Kit.ps1 byter ut branding\ i zippen och tar inte med tests eller .git' {
        $b = Join-Path $TestDrive 'minprofil\branding'; New-Item -ItemType Directory -Force $b | Out-Null
        '{ "name": "Min profil" }' | Set-Content (Join-Path $b 'theme.json') -Encoding utf8
        $zip = Join-Path $TestDrive 'kit.zip'
        & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Out $zip | Out-Null
        $dest = Join-Path $TestDrive 'kit'; Expand-Archive $zip $dest
        $kit = Get-ChildItem $dest -Directory | Select-Object -First 1
        (Get-Content (Join-Path $kit.FullName 'branding\theme.json') -Raw) | Should -Match 'Min profil'
        Test-Path (Join-Path $kit.FullName 'Run-Rapportkit.ps1') | Should -BeTrue
        Test-Path (Join-Path $kit.FullName 'lib\Report.ps1') | Should -BeTrue
        Test-Path (Join-Path $kit.FullName 'tests') | Should -BeFalse
        Test-Path (Join-Path $kit.FullName '.git') | Should -BeFalse
    }
    It 'Pack-Kit.ps1 -Language skriver rapportspråket i theme.json i zippen (men inte i källmappen) och tar med lang' {
        $b = Join-Path $TestDrive 'sprakprofil\branding'; New-Item -ItemType Directory -Force $b | Out-Null
        '{ "name": "Språkprofil", "language": "en" }' | Set-Content (Join-Path $b 'theme.json') -Encoding utf8
        $zip = Join-Path $TestDrive 'sprak.zip'
        & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Language sv -Out $zip | Out-Null
        $dest = Join-Path $TestDrive 'sprak'; Expand-Archive $zip $dest
        $kit = (Get-ChildItem $dest -Directory | Select-Object -First 1).FullName
        $theme = Get-Content (Join-Path $kit 'branding\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $theme.language | Should -Be 'sv'
        $theme.name | Should -Be 'Språkprofil'
        (Get-Content (Join-Path $b 'theme.json') -Raw) | Should -Match '"language": "en"'
        Test-Path (Join-Path $kit 'lang\sv.psd1') | Should -BeTrue
        Test-Path (Join-Path $kit 'lang\en.psd1') | Should -BeTrue
    }
    It 'Pack-Kit.ps1 -Language lägger till språket i en theme.json som saknar det, och avvisar okänt språk' {
        $b = Join-Path $TestDrive 'utansprak\branding'; New-Item -ItemType Directory -Force $b | Out-Null
        '{ "name": "Utan språk" }' | Set-Content (Join-Path $b 'theme.json') -Encoding utf8
        $zip = Join-Path $TestDrive 'utansprak.zip'
        & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Language en -Out $zip | Out-Null
        $dest = Join-Path $TestDrive 'utansprak'; Expand-Archive $zip $dest
        $kit = (Get-ChildItem $dest -Directory | Select-Object -First 1).FullName
        (Get-Content (Join-Path $kit 'branding\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json).language | Should -Be 'en'
        { & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Language xx -Out (Join-Path $TestDrive 'y.zip') } | Should -Throw '*xx*'
    }
    It 'Run-Rapportkit.ps1 har parametern -ReportLanguage' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'ReportLanguage'
    }
    It 'Pack-Kit.ps1 avvisar en mapp utan theme.json' {
        $b = Join-Path $TestDrive 'tom'; New-Item -ItemType Directory $b | Out-Null
        { & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Out (Join-Path $TestDrive 'x.zip') } | Should -Throw '*theme.json*'
    }
}

Describe 'Kundversion av kitet' {
    BeforeAll {
        $b = Join-Path $TestDrive 'kundprofil\branding'; New-Item -ItemType Directory -Force $b | Out-Null
        '{ "name": "Kundprofil" }' | Set-Content (Join-Path $b 'theme.json') -Encoding utf8
        $zip = Join-Path $TestDrive 'kund.zip'
        & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Out $zip | Out-Null
        $script:KundDir = Join-Path $TestDrive 'kundkit'; Expand-Archive $zip $script:KundDir
        $script:Kit = (Get-ChildItem $script:KundDir -Directory | Select-Object -First 1).FullName
    }
    It 'innehåller kundens README och guide på engelska som standard, inte repots' {
        (Get-Content (Join-Path $script:Kit 'README.md') -Raw) | Should -Match 'Extract All'
        (Get-Content (Join-Path $script:Kit 'README.md') -Raw) | Should -Not -Match 'Quick start|Pack-Kit'
        Test-Path (Join-Path $script:Kit 'docs\Azure-Rapportkit-Customer-guide.docx') | Should -BeTrue
        Test-Path (Join-Path $script:Kit 'docs\Azure-Rapportkit-Kundguide.docx') | Should -BeFalse
        Test-Path (Join-Path $script:Kit 'docs\Anvandarguide-Azure-Rapportkit.docx') | Should -BeFalse
        (Get-Content (Join-Path $script:Kit 'docs\KUNDINFO.md') -Raw) | Should -Match 'information for the customer'
    }
    It 'ger svenska kunddokument med Pack-Kit -Language sv, och rapportspråket i theme.json' {
        $b = Join-Path $TestDrive 'svprofil\branding'; New-Item -ItemType Directory -Force $b | Out-Null
        '{ "name": "Svprofil" }' | Set-Content (Join-Path $b 'theme.json') -Encoding utf8
        $zip = Join-Path $TestDrive 'sv.zip'
        & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Language sv -Out $zip | Out-Null
        $dest = Join-Path $TestDrive 'svkit'; Expand-Archive $zip $dest
        $kit = (Get-ChildItem $dest -Directory | Select-Object -First 1).FullName
        (Get-Content (Join-Path $kit 'README.md') -Raw -Encoding UTF8) | Should -Match 'Extrahera alla'
        (Get-Content (Join-Path $kit 'docs\KUNDINFO.md') -Raw -Encoding UTF8) | Should -Match 'information till kunden'
        Test-Path (Join-Path $kit 'docs\Azure-Rapportkit-Kundguide.docx') | Should -BeTrue
        Test-Path (Join-Path $kit 'docs\Azure-Rapportkit-Customer-guide.docx') | Should -BeFalse
        (Get-Content (Join-Path $kit 'branding\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json).language | Should -Be 'sv'
    }
    It 'väljer dokumentspråk efter language i theme.json när -Language saknas' {
        $b = Join-Path $TestDrive 'svtema\branding'; New-Item -ItemType Directory -Force $b | Out-Null
        '{ "name": "Svtema", "language": "sv" }' | Set-Content (Join-Path $b 'theme.json') -Encoding utf8
        $zip = Join-Path $TestDrive 'svtema.zip'
        & (Join-Path $PSScriptRoot '..\Pack-Kit.ps1') -Branding $b -Out $zip | Out-Null
        $dest = Join-Path $TestDrive 'svtemakit'; Expand-Archive $zip $dest
        $kit = (Get-ChildItem $dest -Directory | Select-Object -First 1).FullName
        (Get-Content (Join-Path $kit 'README.md') -Raw -Encoding UTF8) | Should -Match 'Extrahera alla'
    }
    It 'har inga länkar till repot och inga utvecklarverktyg i zippen' {
        foreach ($f in Get-ChildItem $script:Kit -Recurse -File -Include *.md, *.ps1, *.json, *.txt) {
            (Get-Content $f.FullName -Raw) | Should -Not -Match 'marcurell/azure-rapportkit' -Because $f.Name
        }
        foreach ($n in 'Pack-Kit.ps1', 'Unprotect-Rapportkit.ps1', 'Build-Bundle.ps1') { Test-Path (Join-Path $script:Kit $n) | Should -BeFalse -Because $n }
        Test-Path (Join-Path $script:Kit 'tests') | Should -BeFalse
    }
    It 'kunddokumenten i repot nämner inte repot eller Moln på svenska' {
        foreach ($f in 'docs\kund\README.sv.md', 'docs\kund\README.en.md', 'docs\KUNDINFO.sv.md', 'docs\KUNDINFO.en.md') {
            $t = Get-Content (Join-Path $PSScriptRoot "..\$f") -Raw
            $t | Should -Not -Match 'marcurell|github\.com/marcurell|Moln på svenska|molnpasvenska' -Because $f
        }
    }
}
