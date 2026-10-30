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
              'Import-CsvChecked', 'Get-OutputRootWarnings', 'Assert-FileHash', 'Get-RoleInstructions', 'Test-Zip'
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
        $script:Warnings[0] | Should -Match 'saknar kolumnerna: Impact'
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
        (Get-OutputRootWarnings ('C:\' + ('a' * 100))) -join ' ' | Should -Match 'lång'
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
        $err.Data['Fix'] | Should -Match 'kör om|Kör om'
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

Describe 'Pinnade versioner i scriptet' {
    It 'har kontrollsummor i rätt format' {
        $src = Get-Content $script:ScriptPath -Raw
        $src | Should -Match "AzqrSha256\s*=\s*'[0-9A-F]{64}'"
        $src | Should -Match "GovVizSha256\s*=\s*'[0-9A-F]{64}'"
    }
}
