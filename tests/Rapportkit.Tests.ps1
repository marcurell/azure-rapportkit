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
    It 'rapporterar framsteg: först antalet filer, sedan hur långt den har kommit' {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $zip = Join-Path $TestDrive 'progress.zip'
        New-ResultZip $script:Run $zip { param($done, $total) $script:Calls.Add(@($done, $total)) } 0
        $script:Calls[0][0] | Should -Be 0
        $script:Calls[0][1] | Should -Be $script:Entries.Count
        $script:Calls.Count | Should -BeGreaterThan 2
        foreach ($c in $script:Calls) { $c[1] | Should -Be $script:Entries.Count }
        $done = @($script:Calls | ForEach-Object { $_[0] })
        $done | Should -Be @($done | Sort-Object)             # never backwards
        $done[-1] | Should -BeLessOrEqual ($script:Entries.Count - 1)
    }
    It 'rapporterar inte framsteg oftare än med det angivna intervallet' {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $zip = Join-Path $TestDrive 'quiet.zip'
        New-ResultZip $script:Run $zip { param($done, $total) $script:Calls.Add(@($done, $total)) } 3600
        $script:Calls.Count | Should -Be 1                      # only the starting message
    }
    It 'öppnar rapporten innan zippen skapas, och zippen skriver framsteg' {
        $code = Get-Content $script:ScriptPath -Raw -Encoding UTF8
        $open = $code.IndexOf('Start-Process $reportPath')
        $zipStart = $code.IndexOf('$zipProgress = {')
        $open | Should -BeGreaterThan 0
        $open | Should -BeLessThan $zipStart
        ([regex]::Matches($code, 'Start-Process \$reportPath')).Count | Should -Be 1
        ([regex]::Matches($code, 'New-ResultZip \$zipSource \S+ \$zipProgress')).Count | Should -Be 2
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

Describe 'Anonymiserad körning (-Anonymize) lämnar bara den anonyma rapporten' {
    BeforeAll { $script:Src = Get-Content $script:ScriptPath -Raw -Encoding UTF8 }
    It 'frågar efter anonymisering innan resultatmappen väljs, så att arbetsmappen kan vara tillfällig' {
        $ask = $script:Src.IndexOf('Do you want an ANONYMIZED report')
        $run = $script:Src.IndexOf('$RunDir = Join-Path $OutputRoot $Period')
        $ask | Should -BeGreaterThan 0
        $run | Should -BeGreaterThan $ask
        $script:Src | Should -Not -Match 'Do you also want to create an anonymized version'
    }
    It 'kör verktygen i en tillfällig mapp och sparar bara den anonyma mappen (men rör inte en tidigare körning med -ReportOnly)' {
        $script:Src | Should -Match '\$AnonOutDir = Join-Path \$OutputRoot "\$Period-anonym"'
        $script:Src | Should -Match 'if \(-not \$ReportOnly\) \{ \$RunDir = Join-Path \(\[System\.IO\.Path\]::GetTempPath\(\)\)'
    }
    It 'tar bort arbetsmappen först efter att den anonyma rapporten och zippen finns, och bara om rapporten byggdes' {
        $zip = $script:Src.IndexOf('New-ResultZip $zipSource $zipPath $zipProgress')
        $del = $script:Src.IndexOf('Remove-Item -LiteralPath $RunDir -Recurse -Force -ErrorAction Stop')
        $zip | Should -BeGreaterThan 0
        $del | Should -BeGreaterThan $zip
        $script:Src | Should -Match 'if \(\$Anonymize -and \$WorkDirIsTemp -and -not \$anonFailed\)'
    }
    It 'zippar den anonyma mappen, utan någon del av tenant-ID i filnamnet och utan varning om okrypterad zip' {
        $script:Src | Should -Match '\$zipSource = if \(\$Anonymize\) \{ \$AnonOutDir \} else \{ \$RunDir \}'
        $script:Src | Should -Match "rapportkit_anonym_\{0\}\.zip"
        $script:Src | Should -Match 'if \(-not \$Anonymize\) \{ Add-Warning ''The zip file is NOT encrypted'
        $script:Src | Should -Match 'if \(\$Anonymize -and -not \$ZipPassword\) \{ \$NoEncrypt'
    }
    It 'säger var arbetsmappen finns om körningen avbröts eller byggdes fel' {
        ([regex]::Matches($script:Src, 'Write-WorkDirNote')).Count | Should -BeGreaterOrEqual 3
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
    It 'det publika repot är för den som kör själv: inga kundpaket, kundguider eller kunddokument' {
        $root = Join-Path $PSScriptRoot '..'
        foreach ($p in 'Pack-Kit.ps1', 'docs\kund', 'docs\KUNDINFO.en.md', 'docs\KUNDINFO.sv.md', 'docs\Anvandarguide-Azure-Rapportkit.docx') { Test-Path (Join-Path $root $p) | Should -BeFalse -Because $p }
        foreach ($f in 'README.md', 'README.sv.md', 'branding\README.md', 'branding\README.sv.md') {
            (Get-Content (Join-Path $root $f) -Raw -Encoding UTF8) | Should -Not -Match 'Pack-Kit|KUNDINFO|docs\\kund|Anvandarguide' -Because $f
        }
    }
    It 'Run-Rapportkit.ps1 har parametern -ReportLanguage' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'ReportLanguage'
    }
}
