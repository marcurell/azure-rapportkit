#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Unit tests for the pure helper functions in Run-Rapportkit.ps1. The functions are read out of the script with the parser
  (AST), so the script itself does not run (no sign-ins or downloads).

  Run:  Invoke-Pester .\tests
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Run-Rapportkit.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
    $wanted = 'Fail', 'Get-ErrorText', 'Get-SignInHelp', 'Test-ActionAllowed', 'Format-Wrap', 'Format-Duration',
              'Import-CsvChecked', 'Get-OutputRootWarnings', 'Assert-FileHash', 'Get-RoleInstructions', 'Test-Zip', 'Get-SourceStates',
              'Get-GraphThrottleGiveUps', 'Get-ZipFiles', 'New-ResultZip', 'ConvertTo-InvariantText'
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

    # Stubs for what the functions call in the script
    $script:Warnings = [System.Collections.Generic.List[string]]::new()
    function Add-Warning([string]$msg) { $script:Warnings.Add($msg) }
    function Write-Ok($m) { }
    function Write-Warn2($m) { }
    function Write-Log($l, $m) { }
    $script:AllowUnverified = $false
}

Describe 'The functions are found in the script' {
    It 'has all the expected functions' {
        foreach ($n in 'Fail', 'Get-SignInHelp', 'Test-ActionAllowed', 'Format-Wrap', 'Import-CsvChecked', 'Assert-FileHash', 'Get-RoleInstructions') {
            Get-Command $n -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Fail' {
    It 'throws an error with the action text in Data["Fix"]' {
        $err = $null
        try { Fail 'Something went wrong.' 'Do this.' } catch { $err = $_.Exception }
        $err.Message | Should -Be 'Something went wrong.'
        $err.Data['Fix'] | Should -Be 'Do this.'
    }
}

Describe 'Get-SignInHelp' {
    It 'recognises Conditional Access and consent errors' -ForEach @(
        @{ Text = 'AADSTS53003: Access has been blocked by Conditional Access policies' }
        @{ Text = 'AADSTS50076: you must use multi-factor authentication' }
        @{ Text = 'AADSTS65001: The user has not consented to use the application' }
        @{ Text = 'AADSTS530003: device is not compliant' }
    ) {
        Get-SignInHelp $Text | Should -Match 'Conditional Access|villkorsstyrda'
    }
    It 'gives no text for ordinary errors' {
        Get-SignInHelp 'The term foo is not recognized' | Should -BeNullOrEmpty
    }
    It 'is added by Get-ErrorText' {
        $e = [System.Exception]::new('AADSTS53003 blockerad')
        Get-ErrorText $e | Should -Match 'Microsoft Azure CLI'
    }
}

Describe 'Test-ActionAllowed' {
    BeforeAll {
        $script:reader = @([pscustomobject]@{ actions = @('*/read'); notActions = @() })
        $script:custom = @([pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Delete') })
    }
    It 'allows reading through */read' { Test-ActionAllowed $script:reader 'Microsoft.Security/assessments/read' | Should -BeTrue }
    It 'denies writing with only */read' { Test-ActionAllowed $script:reader 'Microsoft.Storage/storageAccounts/write' | Should -BeFalse }
    It 'respects notActions' {
        Test-ActionAllowed $script:custom 'Microsoft.Authorization/roleAssignments/Delete' | Should -BeFalse
        Test-ActionAllowed $script:custom 'Microsoft.Compute/virtualMachines/read' | Should -BeTrue
    }
    It 'denies when there are no permissions' { Test-ActionAllowed $null 'Microsoft.Security/assessments/read' | Should -BeFalse }
}

Describe 'Format-Wrap and Format-Duration' {
    It 'wraps at words without exceeding the width' {
        $lines = Format-Wrap 'one two three four five six seven eight nine ten eleven twelve' 20
        $lines.Count | Should -BeGreaterThan 2
        ($lines | Measure-Object -Property Length -Maximum).Maximum | Should -BeLessOrEqual 20
    }
    It 'gives no lines for empty text' { (Format-Wrap '' 20).Count | Should -Be 0 }
    It 'formats a duration' {
        Format-Duration 42 | Should -Match '^42 s$'
        Format-Duration 125 | Should -Match '^2 min 05 s$'
    }
    It 'rounds the seconds down, so that it never shows 60 s' {
        Format-Duration 59.9 | Should -Be '59 s'
        Format-Duration 119.7 | Should -Be '1 min 59 s'
        Format-Duration 3600 | Should -Be '60 min 00 s'
    }
}

Describe 'ConvertTo-InvariantText' {
    It 'writes a decimal point whatever the language setting of the computer' {
        $keep = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('sv-SE')
            ConvertTo-InvariantText 258.26 | Should -Be '258.26'
            ConvertTo-InvariantText 0.2857 | Should -Be '0.2857'
            ConvertTo-InvariantText 4 | Should -Be '4'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $keep }
    }
    It 'gives an empty text for no value' {
        ConvertTo-InvariantText $null | Should -Be ''
        ConvertTo-InvariantText '' | Should -Be ''
    }
}

Describe 'Import-CsvChecked' {
    BeforeEach { $script:Warnings.Clear() }
    It 'reads a valid file' {
        $p = Join-Path $TestDrive 'ok.csv'
        "Impact,Category`nHigh,Security`nLow,Cost" | Set-Content $p
        (Import-CsvChecked $p @('Impact', 'Category')).Count | Should -Be 2
        $script:Warnings.Count | Should -Be 0
    }
    It 'warns and gives $null when columns are missing' {
        $p = Join-Path $TestDrive 'bad.csv'
        "Pakt,Category`nHigh,Security" | Set-Content $p
        Import-CsvChecked $p @('Impact', 'Category') | Should -BeNullOrEmpty
        $script:Warnings.Count | Should -Be 1
        $script:Warnings[0] | Should -Match 'missing the columns: Impact'
    }
    It 'warns about an empty file' {
        $p = Join-Path $TestDrive 'empty.csv'
        '' | Set-Content $p -NoNewline
        Import-CsvChecked $p @('Impact') | Should -BeNullOrEmpty
        $script:Warnings.Count | Should -Be 1
    }
}

Describe 'Get-OutputRootWarnings' {
    It 'warns about OneDrive' {
        $old = $env:OneDrive; $env:OneDrive = 'C:\Users\test\OneDrive'
        try { (Get-OutputRootWarnings 'C:\Users\test\OneDrive\rapportkit') -join ' ' | Should -Match 'OneDrive' } finally { $env:OneDrive = $old }
    }
    It 'warns about long paths' {
        (Get-OutputRootWarnings ('C:\' + ('a' * 100))) -join ' ' | Should -Match 'is long'
    }
    It 'does not warn about an ordinary short folder' {
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
    It 'accepts the right checksum' { { Assert-FileHash $script:f $script:hash 'test' } | Should -Not -Throw }
    It 'does nothing when no checksum is given' { { Assert-FileHash $script:f '' 'test' } | Should -Not -Throw }
    It 'aborts with an action when the checksum does not match' {
        $err = $null
        try { Assert-FileHash $script:f ('0' * 64) 'test' } catch { $err = $_.Exception }
        $err | Should -Not -BeNullOrEmpty
        $err.Data['Fix'] | Should -Match 'run the script again|Run the script again'
    }
    It 'warns but continues with -AllowUnverified' {
        $script:AllowUnverified = $true
        { Assert-FileHash $script:f ('0' * 64) 'test' } | Should -Not -Throw
        $script:Warnings.Count | Should -Be 1
    }
}

Describe 'Get-RoleInstructions' {
    It 'mentions PIM and gives a command for every missing Azure role' {
        $missing = @(
            [pscustomobject]@{ Kind = 'Azure'; Role = 'Reader' },
            [pscustomobject]@{ Kind = 'Azure'; Role = 'Security Reader' }
        )
        $text = (Get-RoleInstructions $missing) -join "`n"
        $text | Should -Match 'Privileged Identity Management'
        $text | Should -Match 'az role assignment create .*"Reader"'
        $text | Should -Match 'az role assignment create .*"Security Reader"'
    }
    It 'mentions Global Reader for the Entra role' {
        ((Get-RoleInstructions @([pscustomobject]@{ Kind = 'Entra'; Role = 'Global Reader' })) -join "`n") | Should -Match 'Global Reader'
    }
}

Describe 'Test-Zip' {
    It 'recognises a complete zip with the right content, and a broken file' {
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
    It 'splits the step Defender and cost into sources when step 9 ran' {
        $script:Status = [ordered]@{ azqr = @{ State = 'OK'; Note = '' }; 'Defender and cost' = @{ State = 'Partial'; Note = 'x' } }
        $script:PortalSources = [ordered]@{ plans = @{ state = 'OK'; note = '' }; recommendations = @{ state = 'Partial'; note = 'list is short' }; cost = @{ state = 'OK'; note = '' } }
        $r = Get-SourceStates
        $r['azqr'].state | Should -Be 'OK'
        $r['recommendations'].state | Should -Be 'Partial'
        $r['cost'].state | Should -Be 'OK'
        $r.Contains('Defender and cost') | Should -BeFalse
    }
    It 'gives every Defender and cost source the state of the step when step 9 was skipped or failed' {
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
    It 'counts every failed request once, not once per logged layer' {
        $log = Join-Path $TestDrive 'c1.log'
        Set-Content $log ($script:Fail * 3) -NoNewline
        Get-GraphThrottleGiveUps $log | Should -Be 3
    }
    It 'counts only from where the step began (the log also holds text from earlier runs)' {
        $log = Join-Path $TestDrive 'c2.log'
        Set-Content $log ($script:Fail * 5) -NoNewline
        $from = (Get-Item $log).Length
        Add-Content $log ($script:Fail * 2) -NoNewline
        Get-GraphThrottleGiveUps $log $from | Should -Be 2
        Get-GraphThrottleGiveUps $log 0 | Should -Be 7
    }
    It 'gives 0 when the requests only had to be retried, or when there is no log' {
        $log = Join-Path $TestDrive 'c3.log'
        Set-Content $log ($script:Retry * 20) -NoNewline
        Get-GraphThrottleGiveUps $log | Should -Be 0
        Get-GraphThrottleGiveUps (Join-Path $TestDrive 'finns-inte.log') | Should -Be 0
    }
    It 'reads a log that the script is still writing to' {
        $log = Join-Path $TestDrive 'c4.log'
        $w = [System.IO.File]::Open($log, 'Create', 'Write', 'Read')
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:Fail); $w.Write($bytes, 0, $bytes.Length); $w.Flush()
            Get-GraphThrottleGiveUps $log | Should -Be 1
        }
        finally { $w.Dispose() }
    }
    It 'sets Maester to Partial and warns when a request gave up' {
        $code = Get-Content $script:ScriptPath -Raw -Encoding UTF8
        $code | Should -Match 'Set-Status ''Maester'' ''Partial'' \$note'
        $code | Should -Match 'Get-GraphThrottleGiveUps \$consoleLog \$consoleFrom'
    }
}

Describe 'The zip of the result folder' {
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
            Set-Content $p "content of $f" -Encoding utf8
        }
        $script:Entries = @(Get-ZipFiles $script:Run | ForEach-Object { $_.Entry })
    }
    It 'includes the newest run of AzGovViz and Maester and leaves out the older ones' {
        $script:Entries | Should -Contain 'azgovviz/AzGovViz_6.7.2_20261103_114034_g_Roles.csv'
        $script:Entries | Should -Contain 'azgovviz/AzGovViz_6.7.2_20261103_114034_g.html'
        $script:Entries | Should -Contain 'azgovviz/HTML-Subscriptions_g_20261103_114034/s1.html'
        $script:Entries | Should -Contain 'azgovviz/JSON_g_20261103_114034/a.json'
        $script:Entries | Should -Contain 'maester/test-results/TestResults-2026-11-03-135205.json'
        $script:Entries | Should -Contain 'maester/test-results/TestResults-2026-11-03-135205-summary.md'
        @($script:Entries | Where-Object { $_ -like '*20261102*' -or $_ -like '*2026-11-02-*' }).Count | Should -Be 0
    }
    It 'includes the rest, but not the console log or the test suite of Maester' {
        foreach ($e in 'rapportkit.log', 'run-summary.json', 'rapport.html', 'azqr/azqr_2026-11.json', 'portal/kostnad.csv', 'maester/test-results/maester.json') { $script:Entries | Should -Contain $e }
        $script:Entries | Should -Not -Contain 'rapportkit-console.log'
        @($script:Entries | Where-Object { $_ -like 'maester/maester-tests/*' }).Count | Should -Be 0
    }
    It 'New-ResultZip writes a zip with forward slashes in the names and the content untouched' {
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
            $txt.Trim() | Should -Be 'content of azqr/azqr_2026-11.json'
        }
        finally { $z.Dispose() }
    }
    It 'reports progress: first the number of files, then how far it has come' {
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
    It 'does not report progress more often than the given interval' {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $zip = Join-Path $TestDrive 'quiet.zip'
        New-ResultZip $script:Run $zip { param($done, $total) $script:Calls.Add(@($done, $total)) } 3600
        $script:Calls.Count | Should -Be 1                      # only the starting message
    }
    It 'opens the report before the zip is created, and the zip reports progress' {
        $code = Get-Content $script:ScriptPath -Raw -Encoding UTF8
        $open = $code.IndexOf('Start-Process $reportPath')
        $zipStart = $code.IndexOf('$zipProgress = {')
        $open | Should -BeGreaterThan 0
        $open | Should -BeLessThan $zipStart
        ([regex]::Matches($code, 'Start-Process \$reportPath')).Count | Should -Be 1
        ([regex]::Matches($code, 'New-ResultZip \$zipSource \S+ \$zipProgress')).Count | Should -Be 2
    }
    It 'reads a file that something else holds open for writing' {
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

Describe 'An anonymized run (-Anonymize) leaves only the anonymized report' {
    BeforeAll { $script:Src = Get-Content $script:ScriptPath -Raw -Encoding UTF8 }
    It 'asks about anonymization before the result folder is chosen, so that the working folder can be temporary' {
        $ask = $script:Src.IndexOf('Do you want an ANONYMIZED report')
        $run = $script:Src.IndexOf('$RunDir = Join-Path $OutputRoot $Period')
        $ask | Should -BeGreaterThan 0
        $run | Should -BeGreaterThan $ask
        $script:Src | Should -Not -Match 'Do you also want to create an anonymized version'
    }
    It 'runs the tools in a temporary folder and keeps only the anonymized folder (but does not touch an earlier run with -ReportOnly)' {
        $script:Src | Should -Match '\$AnonOutDir = Join-Path \$OutputRoot "\$Period-anonym"'
        $script:Src | Should -Match 'if \(-not \$ReportOnly\) \{ \$RunDir = Join-Path \(\[System\.IO\.Path\]::GetTempPath\(\)\)'
    }
    It 'deletes the working folder only after the anonymized report and the zip exist, and only if the report was built' {
        $zip = $script:Src.IndexOf('New-ResultZip $zipSource $zipPath $zipProgress')
        $del = $script:Src.IndexOf('Remove-Item -LiteralPath $RunDir -Recurse -Force -ErrorAction Stop')
        $zip | Should -BeGreaterThan 0
        $del | Should -BeGreaterThan $zip
        $script:Src | Should -Match 'if \(\$Anonymize -and \$WorkDirIsTemp -and -not \$anonFailed\)'
    }
    It 'zips the anonymized folder, with no part of the tenant ID in the file name and no warning about an unencrypted zip' {
        $script:Src | Should -Match '\$zipSource = if \(\$Anonymize\) \{ \$AnonOutDir \} else \{ \$RunDir \}'
        $script:Src | Should -Match "rapportkit_anonym_\{0\}\.zip"
        $script:Src | Should -Match 'if \(-not \$Anonymize\) \{ Add-Warning ''The zip file is NOT encrypted'
        $script:Src | Should -Match 'if \(\$Anonymize -and -not \$ZipPassword\) \{ \$NoEncrypt'
    }
    It 'says where the working folder is if the run was aborted or the report could not be built' {
        ([regex]::Matches($script:Src, 'Write-WorkDirNote')).Count | Should -BeGreaterOrEqual 3
    }
}

Describe 'Governance Visualizer telemetry' {
    It 'always runs Governance Visualizer with -StatsOptOut, so that no usage statistics are sent' {
        $src = Get-Content $script:ScriptPath -Raw -Encoding UTF8
        $set = $src.IndexOf('$gvArgs.StatsOptOut = $true')
        $set | Should -BeGreaterThan 0
        $set | Should -BeLessThan $src.IndexOf('& $gvScript @gvArgs')
    }
}

Describe 'Fixes from the code review of 1.5.1' {
    BeforeAll { $script:Src = Get-Content $script:ScriptPath -Raw -Encoding UTF8 }
    It 'removes the Defender and cost files of an earlier run before step 9 writes new ones' {
        $clear = $script:Src.IndexOf('foreach ($old in ''defender-planer.csv'', ''secure-score.csv'', ''secure-score-kontroller.csv'', ''defender-rekommendationer.csv'', ''kostnad.csv'')')
        $write = $script:Src.IndexOf('$sv[1] | Export-Csv -Path (Join-Path $Dirs.portal $sv[0])')
        $clear | Should -BeGreaterThan 0
        $write | Should -BeGreaterThan $clear
    }
    It 'asks Cost Management for whole months: from the first of the month eleven months back' {
        $script:Src | Should -Match '\(Get-Date -Year \$today\.Year -Month \$today\.Month -Day 1\)\.AddMonths\(-11\)'
        $script:Src | Should -Not -Match 'AddDays\(-364\)'
    }
    It 'writes the numbers of the Defender and cost files with a decimal point' {
        $script:Src | Should -Match 'Kostnad = \(ConvertTo-InvariantText'
        $script:Src | Should -Match 'Andel = \(ConvertTo-InvariantText'
    }
    It 'sends a failed ARM request only once (the error text is read from the same call)' {
        $script:Src | Should -Match '& az @azArgs 2>\$errFile'
        $script:Src | Should -Not -Match '& az @azArgs 2>&1'
    }
    It 'checks that Azure Resource Manager can be reached also when only step 9 runs' {
        $script:Src | Should -Match 'if \(-not \$SkipGovViz -or -not \$SkipAzqr -or -not \$SkipPortal\) \{ \$endpoints \+= , @\(''management\.azure\.com'''
    }
    It 'stops with a clear error when -ReportOnly has no earlier run to read' {
        $script:Src | Should -Match 'if \(\$ReportOnly -and -not \(Test-Path -LiteralPath \$RunDir\)\)'
    }
    It 'does not pass the obsolete -NoTypeInformation to Export-Csv' {
        $script:Src | Should -Not -Match 'Export-Csv[^\r\n]*-NoTypeInformation'
        (Get-Content (Join-Path $PSScriptRoot '..\lib\Structure.ps1') -Raw) | Should -Not -Match 'Export-Csv[^\r\n]*-NoTypeInformation'
    }
}

Describe 'Save-StructureData' {
    BeforeAll {
        $script:ScriptRoot = Join-Path $PSScriptRoot '..'
        . (Join-Path $PSScriptRoot '..\lib\Structure.ps1')
    }
    It 'removes the files of an earlier run, so that nothing old is left when a part fails' {
        $dir = Join-Path $TestDrive 'struktur'; New-Item -ItemType Directory $dir | Out-Null
        foreach ($f in 'managementgrupper.csv', 'natverk-vnet.csv', 'natverk-peerings.csv', 'natverk-noder.csv', 'resurser-per-prenumeration.csv') { 'old' | Set-Content (Join-Path $dir $f) }
        function Invoke-ArmRest { throw 'no access' }
        $errors = [System.Collections.Generic.List[string]]::new()
        $summary = Save-StructureData $dir 'root' @('s1') $errors
        @(Get-ChildItem $dir -File).Count | Should -Be 0
        $errors.Count | Should -Be 4
        $summary | Should -BeNullOrEmpty
    }
}

Describe 'azqr runs without masking subscription IDs' {
    It 'passes --mask=false when azqr has the option' {
        $code = Get-Content $script:ScriptPath -Raw -Encoding UTF8
        $code | Should -Match '@\(''--mask=false''\) \+ \$azqrArgs'
        $code | Should -Match 'azqr scan @azqrArgs'
        $code | Should -Match "azqr scan --help"
        $code | Should -Not -Match 'azqr scan --json'
    }
}

Describe 'Pinned versions in the script' {
    It 'has checksums in the right format' {
        $src = Get-Content $script:ScriptPath -Raw
        $src | Should -Match "AzqrSha256\s*=\s*'[0-9A-F]{64}'"
        $src | Should -Match "GovVizSha256\s*=\s*'[0-9A-F]{64}'"
    }
}

Describe 'Azure CLI without winget, and optional encryption' {
    BeforeAll { $script:Src = Get-Content $script:ScriptPath -Raw }
    It 'installs Azure CLI from the signed MSI when winget is missing or fails' {
        $script:Src | Should -Match 'function Install-AzureCli'
        $script:Src | Should -Match 'Get-AuthenticodeSignature'
        $script:Src | Should -Match "O=Microsoft Corporation"
        $script:Src | Should -Match "else \{ Install-AzureCli \}"
    }
    It 'the pre-flight check does not call a missing winget an error (Azure CLI can be fetched anyway)' {
        $script:Src | Should -Not -Match "Add-Check 'SAKNAS' 'winget'"
    }
    It 'asks about encryption before the password, and -Yes means yes' {
        $script:Src | Should -Match 'Do you want to encrypt the result package'
        $script:Src | Should -Match '-not \$NoEncrypt -and -not \$ZipPassword -and -not \$Yes'
    }
}

Describe 'Branding: a folder, no switch' {
    It 'the script has neither -Brand nor -BrandPath' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $names = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Not -Contain 'Brand'
        $names | Should -Not -Contain 'BrandPath'
    }
    It 'the public repo is for people who run it themselves: no customer packages, customer guides or customer documents' {
        $root = Join-Path $PSScriptRoot '..'
        foreach ($p in 'Pack-Kit.ps1', 'docs\kund', 'docs\KUNDINFO.en.md', 'docs\KUNDINFO.sv.md', 'docs\Anvandarguide-Azure-Rapportkit.docx') { Test-Path (Join-Path $root $p) | Should -BeFalse -Because $p }
        foreach ($f in 'README.md', 'README.sv.md', 'branding\README.md', 'branding\README.sv.md') {
            (Get-Content (Join-Path $root $f) -Raw -Encoding UTF8) | Should -Not -Match 'Pack-Kit|KUNDINFO|docs\\kund|Anvandarguide' -Because $f
        }
    }
    It 'Run-Rapportkit.ps1 has the parameter -ReportLanguage' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'ReportLanguage'
    }
}
