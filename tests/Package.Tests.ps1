#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
  Tests for lib\Package.ps1: a small synthetic result folder is turned into a run package.

  Run:  Invoke-Pester .\tests
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Package.ps1')

    function New-Run([string]$Root, [switch]$OldFormat, [switch]$NoSummary) {
        foreach ($n in 'azqr', 'maester\test-results', 'portal', 'struktur', 'azgovviz') { New-Item -ItemType Directory -Force (Join-Path $Root $n) | Out-Null }
        $sid = '63621c47-1b51-4ac6-b577-9018793b8382'
        "Validated Using,Source,Category,Impact,Resource Type,Recommendation,Recommendation Id,Subscription Id,Subscription Name,Resource Group,Resource Name,Resource Id,Param1`nARG,AZQR,Security,Medium,Microsoft.Web/sites,Use VNET integration,APP-009,$sid,Sub,rg,app1,/subscriptions/$sid/resourceGroups/rg/providers/Microsoft.Web/sites/App1,not configured" | Set-Content (Join-Path $Root 'azqr\azqr_x.impacted.csv') -Encoding utf8
        "Recommendation Id,Recommendation,Impact,Best Practices Guidance,Read More`napp-009,Use VNET integration,Medium,Integrate the app,https://learn.example/vnet" | Set-Content (Join-Path $Root 'azqr\azqr_x.recommendations.csv') -Encoding utf8
        "Subscription Id,Resource Group,Location,Resource Type,Resource Name,Resource Id`n$sid,rg,westeurope,microsoft.web/sites,app1,/subscriptions/$sid/resourceGroups/rg/providers/Microsoft.Web/sites/App1" | Set-Content (Join-Path $Root 'azqr\azqr_x.inventory.csv') -Encoding utf8
        $tests = @(
            @{ Id = 'MT.1'; Title = 'One'; Name = 'MT.1: One'; Severity = 'High'; Block = 'Maester'; Result = 'Failed'; ResultDetail = @{ TestDescription = 'Generic text'; TestResult = 'Tenant specific' } },
            @{ Id = 'MT.2'; Title = 'Two'; Name = 'MT.2: Two'; Severity = ''; Block = 'Maester'; Result = 'Skipped'; ResultDetail = @{ TestDescription = 'More'; SkippedReason = 'NotLicensed' } })
        @{ TenantId = '00000000-0000-0000-0000-000000000001'; ExecutedAt = '2026-10-30T15:00:00+01:00'; PassedCount = 0; FailedCount = 1; SkippedCount = 1; Tests = $tests } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Root 'maester\test-results\maester.json') -Encoding utf8
        # Older, different TestResults file: must lose against maester.json
        @{ Tests = @(@{ Id = 'MT.9'; Title = 'Old'; Name = 'MT.9'; Result = 'Passed' }) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Root 'maester\test-results\TestResults-2026-10-30-100000.json') -Encoding utf8
        if ($OldFormat) {
            "Prenumeration,Poang,Max,Andel`nSub,4,14,""0,2857""" | Set-Content (Join-Path $Root 'portal\secure-score.csv') -Encoding utf8
            "Prenumeration,Rekommendation,Status,Allvarlighet,Resurs`nSub,Enable MFA now,Unhealthy,High,/subscriptions/$sid" | Set-Content (Join-Path $Root 'portal\defender-rekommendationer.csv') -Encoding utf8
            "Prenumeration,Kontroll,Poang,Max,Osunda,Friska`nSub,Enable MFA,0,10,1,0" | Set-Content (Join-Path $Root 'portal\secure-score-kontroller.csv') -Encoding utf8
            "Prenumeration,Manad,Kostnad,Valuta`nSub,2026-09,""1 234,56"",SEK`nSub,2026-10,26.12,SEK" | Set-Content (Join-Path $Root 'portal\kostnad.csv') -Encoding utf8
            "Prenumeration,Plan,Niva,Delplan`nSub,VirtualMachines,Standard," | Set-Content (Join-Path $Root 'portal\defender-planer.csv') -Encoding utf8
            "Subscription;SubscriptionId;ManagementGroupPath`nSub;$sid;root" | Set-Content (Join-Path $Root 'azgovviz\AzGovViz_6_x_SubscriptionDetails.csv') -Encoding utf8
        }
        else {
            "PrenumerationId,Prenumeration,Poang,Max,Andel`n$sid,Sub,4,14,""0,2857""" | Set-Content (Join-Path $Root 'portal\secure-score.csv') -Encoding utf8
            "PrenumerationId,Prenumeration,Nyckel,Rekommendation,Status,Allvarlighet,Resurs`n$sid,Sub,AAA-111,Enable MFA now,Unhealthy,High,/subscriptions/$sid" | Set-Content (Join-Path $Root 'portal\defender-rekommendationer.csv') -Encoding utf8
            "PrenumerationId,Prenumeration,KontrollId,Kontroll,Poang,Max,Osunda,Friska`n$sid,Sub,CTRL-1,Enable MFA,0,10,1,0" | Set-Content (Join-Path $Root 'portal\secure-score-kontroller.csv') -Encoding utf8
            "PrenumerationId,Prenumeration,Manad,Kostnad,Valuta`n$sid,Sub,2026-09,""1 234,56"",SEK`n$sid,Sub,2026-10,26.12,SEK" | Set-Content (Join-Path $Root 'portal\kostnad.csv') -Encoding utf8
            "PrenumerationId,Prenumeration,Plan,Niva,Delplan`n$sid,Sub,VirtualMachines,Standard," | Set-Content (Join-Path $Root 'portal\defender-planer.csv') -Encoding utf8
        }
        "Niva,Id,Namn,Typ,Foralder`n0,root,Tenant Root Group,Managementgrupp,`n1,$sid,Sub,Prenumeration,root" | Set-Content (Join-Path $Root 'struktur\managementgrupper.csv') -Encoding utf8
        "Id,Namn,Prenumeration,Resursgrupp,Plats,Adressrymd,Subnat`n/subscriptions/$sid/vnet-a,vnet-a,$sid,rg,westeurope,10.0.0.0/16,2" | Set-Content (Join-Path $Root 'struktur\natverk-vnet.csv') -Encoding utf8
        if (-not $NoSummary) {
            $sources = if ($OldFormat) { $null } else { [ordered]@{ azqr = @{ state = 'OK'; note = '' }; recommendations = @{ state = 'Partial'; note = 'short list' } } }
            $o = [ordered]@{ kitVersion = '1.4.2'; startedAt = '2026-10-30T15:00:00'; finishedAt = '2026-10-30T15:30:00'; tenantId = '00000000-0000-0000-0000-000000000001'; period = '2026-10'
                             options = @{ maxPortalSubscriptions = 25 }; tools = @{ azqrPinned = '4.3.0'; maester = $null }
                             results = @(@{ name = 'azqr'; state = 'OK'; note = '' }, @{ name = 'Defender and cost'; state = 'Delvis'; note = 'x' }, @{ name = 'Maester'; state = 'Skipped'; note = '' }) }
            if ($sources) { $o.sources = $sources }
            $o | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Root 'run-summary.json') -Encoding utf8
        }
    }
    function Read-Lines([string]$Path) { @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
}

Describe 'ConvertTo-InvariantNumber' {
    It 'läser decimaltecken och tusentalsavgränsare i flera skrivsätt' {
        foreach ($c in @(@('0,2857', 0.2857), @('0.2857', 0.2857), @('236,38', 236.38), @('1 234,56', 1234.56), @('1.234,56', 1234.56), @('1,234.56', 1234.56), @('243', 243))) {
            ConvertTo-InvariantNumber $c[0] | Should -Be $c[1]
        }
        ConvertTo-InvariantNumber '' | Should -BeNullOrEmpty
        ConvertTo-InvariantNumber 'abc' | Should -BeNullOrEmpty
    }
}

Describe 'New-RunPackage med en 1.4.2-körning' {
    BeforeAll {
        $script:Run = Join-Path $TestDrive 'run2026-10'
        New-Run $script:Run
        $script:R = New-RunPackage -RunDir $script:Run
        $script:Data = Join-Path $script:R.OutDir 'data'
        $script:Man = Get-Content (Join-Path $script:R.OutDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    It 'skriver manifest med schema, tider i UTC, tenant och verktyg' {
        $script:Man.schema | Should -Be 'rapportkit.run/1'
        $script:Man.tenantId | Should -Be '00000000-0000-0000-0000-000000000001'
        $script:Man.period | Should -Be '2026-10'
        # PowerShell 7 would turn the timestamp into a DateTime, so check the text in the file
        (Get-Content (Join-Path $script:R.OutDir 'manifest.json') -Raw) | Should -Match '"startedAt":\s+"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        $script:Man.collector.version | Should -Be '1.4.2'
        $script:Man.tools.azqrPinned | Should -Be '4.3.0'
        $script:Man.imported.keyQuality | Should -Be 'exact'
    }
    It 'ger samma runId varje gång för samma körning' {
        $again = New-RunPackage -RunDir $script:Run -OutDir (Join-Path $TestDrive 'again')
        $again.Manifest.runId | Should -Be $script:Man.runId
    }
    It 'har sha256 och radantal som stämmer för varje fil' {
        foreach ($p in $script:Man.files.PSObject.Properties) {
            $path = Join-Path $script:R.OutDir ($p.Name -replace '/', '\')
            (Get-FileSha256 $path) | Should -Be $p.Value.sha256
            @(Get-Content $path | Where-Object { $_ }).Count | Should -Be $p.Value.rows
        }
    }
    It 'skriver JSON Lines utan BOM' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Data 'findings.jsonl'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    }
    It 'gör nycklar av källa, regel och resurs i gemener' {
        $f = Read-Lines (Join-Path $script:Data 'findings.jsonl')
        ($f | Where-Object source -eq 'azqr').key | Should -Be '"azqr:app-009:/subscriptions/63621c47-1b51-4ac6-b577-9018793b8382/resourcegroups/rg/providers/microsoft.web/sites/app1"'.Trim('"')
        ($f | Where-Object ruleId -eq 'mt.1').key | Should -Be 'maester:mt.1:'
        ($f | Where-Object source -eq 'defender').ruleId | Should -Be 'aaa-111'
        @($f.key | Select-Object -Unique).Count | Should -Be @($f).Count
    }
    It 'tar Maester från maester.json, inte från en äldre TestResults-fil' {
        $f = Read-Lines (Join-Path $script:Data 'findings.jsonl')
        ($f | Where-Object ruleId -eq 'mt.9') | Should -BeNullOrEmpty
        ($f | Where-Object ruleId -eq 'mt.1').status | Should -Be 'open'
        ($f | Where-Object ruleId -eq 'mt.2').status | Should -Be 'skipped'
        ($f | Where-Object ruleId -eq 'mt.2').severity | Should -Be 'info'
    }
    It 'lägger den generella texten i rules och det tenantspecifika i findings' {
        $rules = Read-Lines (Join-Path $script:Data 'rules.jsonl')
        ($rules | Where-Object ruleId -eq 'mt.1').description | Should -Be 'Generic text'
        ($rules | Where-Object { $_.source -eq 'azqr' }).learnUrl | Should -Be 'https://learn.example/vnet'
        $f = Read-Lines (Join-Path $script:Data 'findings.jsonl')
        ($f | Where-Object ruleId -eq 'mt.1').detail | Should -Be 'Tenant specific'
        ($f | Where-Object ruleId -eq 'mt.2').detail | Should -Be 'NotLicensed'
    }
    It 'skriver tal med punkt och markerar innevarande kostnadsmånad som ofullständig' {
        $m = Read-Lines (Join-Path $script:Data 'metrics.jsonl')
        ($m | Where-Object { $_.name -eq 'secureScore.percent' }).value | Should -Be 28.57
        $cost = $m | Where-Object { $_.name -eq 'cost.month' }
        ($cost | Where-Object period -eq '2026-09').value | Should -Be 1234.56
        ($cost | Where-Object period -eq '2026-09').partial | Should -BeFalse
        ($cost | Where-Object period -eq '2026-10').value | Should -Be 26.12
        ($cost | Where-Object period -eq '2026-10').partial | Should -BeTrue
        ($m | Where-Object { $_.name -eq 'secureScore.control.unhealthy' }).control | Should -Be 'ctrl-1'
    }
    It 'tar källornas status från run-summary.json (sources)' {
        $script:Man.sources.azqr.state | Should -Be 'OK'
        $script:Man.sources.recommendations.state | Should -Be 'Partial'
        $script:Man.sources.recommendations.rows | Should -Be 1
    }
    It 'ger struktur med engelska typer' {
        $s = Read-Lines (Join-Path $script:Data 'scopes.jsonl')
        ($s | Where-Object id -eq 'root').type | Should -Be 'managementGroup'
        ($s | Where-Object type -eq 'subscription').parentId | Should -Be 'root'
        (Read-Lines (Join-Path $script:Data 'networks.jsonl')).addressSpace | Should -Be '10.0.0.0/16'
    }
}

Describe 'New-RunPackage med en körning från före 1.4.1' {
    BeforeAll {
        $script:Run = Join-Path $TestDrive 'old'
        New-Run $script:Run -OldFormat
        $script:R = New-RunPackage -RunDir $script:Run
        $script:Data = Join-Path $script:R.OutDir 'data'
        $script:Man = Get-Content (Join-Path $script:R.OutDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    It 'mappar prenumerationsnamn till id via AzGovViz och räknar dem' {
        $m = Read-Lines (Join-Path $script:Data 'metrics.jsonl')
        ($m | Where-Object { $_.name -eq 'secureScore.percent' }).scopeId | Should -Be '63621c47-1b51-4ac6-b577-9018793b8382'
        $script:Man.imported.subscriptionsMappedByName | Should -BeGreaterThan 0
        $script:Man.imported.subscriptionsUnmapped | Should -Be 0
    }
    It 'härleder nycklar och markerar det i manifestet' {
        $script:Man.imported.keyQuality | Should -Be 'derived'
        $f = Read-Lines (Join-Path $script:Data 'findings.jsonl')
        ($f | Where-Object source -eq 'defender').ruleId | Should -Be 'name-enable-mfa-now'
        ($f | Where-Object { $_.source -eq 'defender' }).key | Should -Match '^defender:name-enable-mfa-now:'
        ((Read-Lines (Join-Path $script:Data 'metrics.jsonl')) | Where-Object { $_.name -eq 'secureScore.control.unhealthy' }).control | Should -Be 'name-enable-mfa'
    }
    It 'tolkar steg från run-summary.json utan sources (Delvis blir Partial för alla Defender-källor)' {
        $script:Man.sources.azqr.state | Should -Be 'OK'
        $script:Man.sources.cost.state | Should -Be 'Partial'
        $script:Man.sources.recommendations.state | Should -Be 'Partial'
        $script:Man.sources.maester.state | Should -Be 'Skipped'
    }
}

Describe 'ConvertTo-UtcText' {
    It 'ger samma resultat för text, DateTime och i andra språkinställningar' {
        $a = ConvertTo-UtcText '2026-10-30T15:00:00'
        $a | Should -Match '^2026-10-30T\d{2}:00:00Z$'
        ConvertTo-UtcText ([datetime]'2026-10-30T15:00:00') | Should -Be $a
        ConvertTo-UtcText ([datetime]::SpecifyKind([datetime]'2026-10-30T14:00:00', 'Utc')) | Should -Be '2026-10-30T14:00:00Z'
        $old = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-GB')
            ConvertTo-UtcText ([datetime]'2026-10-30T15:00:00') | Should -Be $a
            ConvertTo-UtcText '2026-10-30T15:00:00' | Should -Be $a
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $old }
        ConvertTo-UtcText '' | Should -BeNullOrEmpty
    }
}

Describe 'New-RunPackage utan run-summary.json' {
    It 'går att göra: tenant och tid kommer från Maester och källor utan data blir Skipped' {
        $run = Join-Path $TestDrive 'nosummary'
        New-Run $run -NoSummary
        Remove-Item (Join-Path $run 'portal') -Recurse -Force
        New-Item -ItemType Directory (Join-Path $run 'portal') | Out-Null
        $r = New-RunPackage -RunDir $run
        $r.Manifest.tenantId | Should -Be '00000000-0000-0000-0000-000000000001'
        $r.Manifest.startedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $r.Manifest.sources.azqr.state | Should -Be 'OK'
        $r.Manifest.sources.cost.state | Should -Be 'Skipped'
    }
    It 'ger ett begripligt fel om mappen saknas' {
        { New-RunPackage -RunDir (Join-Path $TestDrive 'finns-inte') } | Should -Throw '*not found*'
    }
}
