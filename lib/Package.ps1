<#
  Run package (see docs\design\2.0-data-contract.md): turns a result folder from the collector (1.x layout) into
  manifest.json plus data\*.jsonl, which is what the report engine reads. The tools' own files are left where they are.

  Entry point: New-RunPackage. Everything here is read-only against the result folder and works in Windows PowerShell 5.1
  and PowerShell 7. Column names and file names in the result folder are the collector's (Swedish, historical); the
  package uses English field names and invariant numbers.
#>

$script:PackageSchema = 'rapportkit.run/1'

# Numbers in the collector's CSV files follow the culture of the machine that wrote them: 0,2857, 0.2857, 1 234,56 ...
function ConvertTo-InvariantNumber($Text) {
    $s = ([string]$Text).Trim() -replace '[\s ]', ''
    if (-not $s) { return $null }
    if ($s.Contains(',') -and $s.Contains('.')) {
        $dec = if ($s.LastIndexOf(',') -gt $s.LastIndexOf('.')) { ',' } else { '.' }
        $group = if ($dec -eq ',') { '.' } else { ',' }
        $s = $s.Replace($group, '').Replace($dec, '.')
    }
    else { $s = $s.Replace(',', '.') }
    $n = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    $null
}

function ConvertTo-SeverityCode($Text) {
    $s = ([string]$Text).Trim().ToLowerInvariant()
    if ($s -in 'critical', 'high', 'medium', 'low') { return $s }
    'info'
}

function ConvertTo-RuleSlug([string]$Text) { 'name-' + (([string]$Text).ToLowerInvariant() -replace '[^\p{L}\p{N}]+', '-').Trim('-') }

function Read-PackageCsv([string]$Path, [string]$Delimiter = ',') {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter -Encoding UTF8)
}

function Find-PackageFile([string]$Dir, [string]$Filter) {
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    Get-ChildItem -LiteralPath $Dir -Filter $Filter -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
}

# One JSON object per line, UTF-8 without BOM. Returns the number of rows; writes nothing if there are none.
function Write-JsonLines([string]$Path, $Rows) {
    $list = @($Rows | Where-Object { $null -ne $_ })
    if (-not $list.Count) { return 0 }
    $lines = [string[]]@($list | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
    $list.Count
}

function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() } finally { $fs.Dispose(); $sha.Dispose() }
}

# PowerShell 7 turns ISO timestamps in JSON into DateTime, Windows PowerShell 5.1 leaves strings: accept both. A time without
# a zone (run-summary.json) is the collector machine's local time.
function ConvertTo-UtcText($Value) {
    if (-not $Value) { return $null }
    $d = [datetime]::MinValue
    if ($Value -is [datetime]) { $d = $Value }
    elseif (-not [datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$d)) { return $null }
    if ($d.Kind -eq [System.DateTimeKind]::Unspecified) { $d = [datetime]::SpecifyKind($d, [System.DateTimeKind]::Local) }
    $d.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

# A run id that is the same every time the same run is converted.
function New-StableGuid([string]$Seed) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { (New-Object System.Guid (, $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed)))).ToString() } finally { $md5.Dispose() }
}

# --- Sources -> rows -----------------------------------------------------------------------------------------------

function Get-AzqrRows([string]$Dir) {
    $out = @{ Findings = @(); Rules = @(); Resources = @() }
    $imp = Find-PackageFile $Dir '*.impacted.csv'
    if (-not $imp) { return $out }
    $out.Findings = @(Read-PackageCsv $imp.FullName | ForEach-Object {
        $rule = ([string]$_.'Recommendation Id').ToLowerInvariant(); $res = ([string]$_.'Resource Id').ToLowerInvariant()
        [ordered]@{ key = "azqr:${rule}:$res"; source = 'azqr'; ruleId = $rule; status = 'open'; severity = (ConvertTo-SeverityCode $_.Impact)
                    category = ([string]$_.Category).ToLowerInvariant(); title = [string]$_.Recommendation; subscriptionId = ([string]$_.'Subscription Id').ToLowerInvariant()
                    resourceId = $res; resourceType = ([string]$_.'Resource Type').ToLowerInvariant(); detail = [string]$_.Param1 }
    })
    $rec = Find-PackageFile $Dir '*.recommendations.csv'
    if ($rec) {
        $out.Rules = @(Read-PackageCsv $rec.FullName | ForEach-Object {
            [ordered]@{ source = 'azqr'; ruleId = ([string]$_.'Recommendation Id').ToLowerInvariant(); title = [string]$_.Recommendation
                        description = [string]$_.'Best Practices Guidance'; learnUrl = [string]$_.'Read More'; defaultSeverity = (ConvertTo-SeverityCode $_.Impact) }
        })
    }
    $inv = Find-PackageFile $Dir '*.inventory.csv'
    if ($inv) {
        $out.Resources = @(Read-PackageCsv $inv.FullName | ForEach-Object {
            [ordered]@{ resourceId = ([string]$_.'Resource Id').ToLowerInvariant(); name = [string]$_.'Resource Name'; type = ([string]$_.'Resource Type').ToLowerInvariant()
                        subscriptionId = ([string]$_.'Subscription Id').ToLowerInvariant(); resourceGroup = [string]$_.'Resource Group'; location = [string]$_.Location }
        })
    }
    $out
}

# Maester: the newest TestResults-*.json (the names sort by time). maester.json is only the collector's own summary, used when Maester
# left no TestResults file; it can also be left over from an earlier run in the same folder, so it must never win over a TestResults file.
function Get-MaesterRows([string]$Dir) {
    $out = @{ Findings = @(); Rules = @(); TenantId = ''; ExecutedAt = '' }
    if (-not (Test-Path -LiteralPath $Dir)) { return $out }
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*test-results*' })
    $f = $files | Where-Object Name -like 'TestResults-*.json' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $f) { $f = $files | Where-Object Name -eq 'maester.json' | Select-Object -First 1 }
    if (-not $f) { return $out }
    $m = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($m.PSObject.Properties.Name -contains 'TenantId') { $out.TenantId = [string]$m.TenantId }
    if ($m.PSObject.Properties.Name -contains 'ExecutedAt') { $out.ExecutedAt = $m.ExecutedAt }
    $status = @{ Passed = 'passed'; Failed = 'open'; Investigate = 'open'; Skipped = 'skipped'; NotRun = 'skipped' }
    $findings = New-Object System.Collections.Generic.List[object]; $rules = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($m.Tests)) {
        $props = @($t.PSObject.Properties.Name)
        $id = if ($props -contains 'Id' -and $t.Id) { [string]$t.Id } else { [string]$t.Name }   # the fallback file written by the collector may lack Id in older runs
        $rule = $id.ToLowerInvariant()
        $title = if ($props -contains 'Title' -and $t.Title) { [string]$t.Title } else { [string]$t.Name }
        $rd = if ($props -contains 'ResultDetail') { $t.ResultDetail } else { $null }
        $rdp = if ($rd) { @($rd.PSObject.Properties.Name) } else { @() }
        $val = { param($n) if ($rdp -contains $n -and $rd.$n) { [string]$rd.$n } else { '' } }
        $sevText = if ($props -contains 'Severity') { $t.Severity } else { '' }
        $st = if ($status.ContainsKey([string]$t.Result)) { $status[[string]$t.Result] } else { 'error' }
        $detail = ((& $val 'TestResult') + ' ' + (& $val 'SkippedReason')).Trim(); if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) }
        $findings.Add([ordered]@{ key = "maester:${rule}:"; source = 'maester'; ruleId = $rule; status = $st; severity = (ConvertTo-SeverityCode $sevText)
                                  category = $(if ($props -contains 'Block') { ([string]$t.Block).ToLowerInvariant() } else { '' }); title = $title; resourceId = ''; detail = $detail })
        $rules.Add([ordered]@{ source = 'maester'; ruleId = $rule; title = $title; description = (& $val 'TestDescription'); defaultSeverity = (ConvertTo-SeverityCode $sevText)
                               tags = $(if ($props -contains 'Tag') { [string]$t.Tag } else { '' }) })
    }
    $out.Findings = $findings.ToArray(); $out.Rules = $rules.ToArray()
    $out
}

# Defender, Secure Score, plans and cost (portal\*.csv). $SubIds maps a subscription name to its id for files written before 1.4.1.
function Get-PortalRows([string]$Dir, $SubIds, [string]$RunMonth) {
    $out = @{ Findings = @(); Metrics = @(); Plans = @(); KeyQuality = 'exact'; Mapped = 0; Unmapped = 0 }
    $sub = {
        param($r)
        if ($r.PSObject.Properties.Name -contains 'PrenumerationId' -and $r.PrenumerationId) { return ([string]$r.PrenumerationId).ToLowerInvariant() }
        if ($SubIds.ContainsKey([string]$r.Prenumeration)) { $out.Mapped++; return $SubIds[[string]$r.Prenumeration] }
        $out.Unmapped++; ([string]$r.Prenumeration).ToLowerInvariant()
    }
    $has = { param($r, $n) $r.PSObject.Properties.Name -contains $n -and $r.$n }
    $findings = New-Object System.Collections.Generic.List[object]; $metrics = New-Object System.Collections.Generic.List[object]; $plans = New-Object System.Collections.Generic.List[object]
    foreach ($r in Read-PackageCsv (Join-Path $Dir 'defender-rekommendationer.csv')) {
        $s = & $sub $r
        if (& $has $r 'Nyckel') { $rule = ([string]$r.Nyckel).ToLowerInvariant() } else { $rule = ConvertTo-RuleSlug $r.Rekommendation; $out.KeyQuality = 'derived' }
        $st = switch ([string]$r.Status) { 'Unhealthy' { 'open' } 'Healthy' { 'passed' } default { 'skipped' } }
        $res = ([string]$r.Resurs).ToLowerInvariant()
        $findings.Add([ordered]@{ key = "defender:${rule}:$res"; source = 'defender'; ruleId = $rule; status = $st; severity = (ConvertTo-SeverityCode $r.Allvarlighet)
                                  subscriptionId = $s; resourceId = $res; title = [string]$r.Rekommendation })
    }
    foreach ($r in Read-PackageCsv (Join-Path $Dir 'secure-score.csv')) {
        $s = & $sub $r
        $metrics.Add([ordered]@{ name = 'secureScore.percent'; scopeId = $s; value = [math]::Round((ConvertTo-InvariantNumber $r.Andel) * 100, 2); unit = 'percent' })
        $metrics.Add([ordered]@{ name = 'secureScore.points'; scopeId = $s; value = (ConvertTo-InvariantNumber $r.Poang); unit = 'points' })
    }
    foreach ($r in Read-PackageCsv (Join-Path $Dir 'secure-score-kontroller.csv')) {
        $s = & $sub $r
        $cid = if (& $has $r 'KontrollId') { ([string]$r.KontrollId).ToLowerInvariant() } else { ConvertTo-RuleSlug $r.Kontroll }
        $metrics.Add([ordered]@{ name = 'secureScore.control.unhealthy'; scopeId = $s; control = $cid; title = [string]$r.Kontroll; value = (ConvertTo-InvariantNumber $r.Osunda); unit = 'resources' })
    }
    foreach ($r in Read-PackageCsv (Join-Path $Dir 'kostnad.csv')) {
        $s = & $sub $r
        $metrics.Add([ordered]@{ name = 'cost.month'; scopeId = $s; period = [string]$r.Manad; currency = [string]$r.Valuta; value = (ConvertTo-InvariantNumber $r.Kostnad); partial = ([string]$r.Manad -eq $RunMonth) })
    }
    foreach ($r in Read-PackageCsv (Join-Path $Dir 'defender-planer.csv')) {
        $s = & $sub $r
        $plans.Add([ordered]@{ subscriptionId = $s; plan = ([string]$r.Plan).ToLowerInvariant(); tier = ([string]$r.Niva).ToLowerInvariant(); subPlan = [string]$r.Delplan })
    }
    $out.Findings = $findings.ToArray(); $out.Metrics = $metrics.ToArray(); $out.Plans = $plans.ToArray()
    $out
}

function Get-StructureRows([string]$Dir) {
    $out = @{ Scopes = @(); Networks = @(); Peerings = @() }
    $out.Scopes = @(Read-PackageCsv (Join-Path $Dir 'managementgrupper.csv') | ForEach-Object {
        [ordered]@{ id = ([string]$_.Id).ToLowerInvariant(); type = $(if ($_.Typ -eq 'Prenumeration') { 'subscription' } else { 'managementGroup' }); name = [string]$_.Namn
                    parentId = ([string]$_.Foralder).ToLowerInvariant(); level = [int]$_.Niva }
    })
    $out.Networks = @(Read-PackageCsv (Join-Path $Dir 'natverk-vnet.csv') | ForEach-Object {
        [ordered]@{ id = ([string]$_.Id).ToLowerInvariant(); name = [string]$_.Namn; subscriptionId = ([string]$_.Prenumeration).ToLowerInvariant(); resourceGroup = [string]$_.Resursgrupp
                    location = [string]$_.Plats; addressSpace = @(([string]$_.Adressrymd) -split '[,;\s]+' | Where-Object { $_ }); subnets = [int]$_.Subnat }
    })
    $out.Peerings = @(Read-PackageCsv (Join-Path $Dir 'natverk-peerings.csv') | ForEach-Object {
        [ordered]@{ fromId = ([string]$_.FranId).ToLowerInvariant(); from = [string]$_.Fran; toId = ([string]$_.TillId).ToLowerInvariant(); to = [string]$_.Till; state = [string]$_.Status
                    gatewayTransit = ([string]$_.GatewayTransit -eq 'True'); useRemoteGateways = ([string]$_.AnvandRemoteGateways -eq 'True'); forwardedTraffic = ([string]$_.ForwardedTraffic -eq 'True')
                    toAddressSpace = [string]$_.TillAdressrymd }
    })
    $out
}

# Subscription name -> id, for runs written before the Defender and cost files carried the id (1.4.1). AzGovViz first, then azqr.
function Get-SubscriptionIdMap([string]$RunDir) {
    $map = @{}
    $gv = Find-PackageFile (Join-Path $RunDir 'azgovviz') '*_SubscriptionDetails.csv'
    if ($gv) { foreach ($r in Read-PackageCsv $gv.FullName ';') { if ($r.Subscription -and $r.SubscriptionId) { $map[[string]$r.Subscription] = ([string]$r.SubscriptionId).ToLowerInvariant() } } }
    $imp = Find-PackageFile (Join-Path $RunDir 'azqr') '*.impacted.csv'
    if ($imp) { foreach ($r in Read-PackageCsv $imp.FullName) { $id = [string]$r.'Subscription Id'; $n = [string]$r.'Subscription Name'; if ($n -and $id -and $id -notmatch 'x' -and -not $map.ContainsKey($n)) { $map[$n] = $id.ToLowerInvariant() } } }
    $map
}

# State per source: from run-summary.json "sources" (1.4.2 and later), otherwise from the step results of older runs.
function Get-PackageSourceStates($Summary, $Present) {
    $src = [ordered]@{}
    $fromSummary = $Summary -and ($Summary.PSObject.Properties.Name -contains 'sources') -and $Summary.sources
    if ($fromSummary) { foreach ($p in $Summary.sources.PSObject.Properties) { $src[$p.Name] = [ordered]@{ state = [string]$p.Value.state; note = [string]$p.Value.note } } }
    elseif ($Summary -and $Summary.results) {
        $names = @{ 'Governance Visualizer' = @('azgovviz'); 'azqr' = @('azqr'); 'Maester' = @('maester'); 'Structure' = @('structure'); 'Struktur' = @('structure')
                    'Defender and cost' = @('plans', 'secureScore', 'secureScoreControls', 'recommendations', 'cost'); 'Defender och kostnad' = @('plans', 'secureScore', 'secureScoreControls', 'recommendations', 'cost') }
        $codes = @{ 'Fel' = 'Failed'; 'Delvis' = 'Partial'; 'Hoppad över' = 'Skipped' }
        foreach ($r in @($Summary.results)) {
            if (-not $names.ContainsKey([string]$r.name)) { continue }
            $st = if ($codes.ContainsKey([string]$r.state)) { $codes[[string]$r.state] } else { [string]$r.state }
            foreach ($n in $names[[string]$r.name]) { $src[$n] = [ordered]@{ state = $st; note = [string]$r.note } }
        }
    }
    # No summary, or a source it does not mention: it counts as OK if there is data, otherwise as Skipped.
    foreach ($k in $Present.Keys) { if (-not $src.Contains($k)) { $src[$k] = [ordered]@{ state = $(if ($Present[$k]) { 'OK' } else { 'Skipped' }); note = 'no run-summary entry' } } }
    $src
}

# --- Entry point ---------------------------------------------------------------------------------------------------

function New-RunPackage {
    param([Parameter(Mandatory)][string]$RunDir, [string]$OutDir, [string]$TenantId, [string]$KitVersion = '')
    if (-not (Test-Path -LiteralPath $RunDir)) { throw "Result folder not found: $RunDir" }
    $RunDir = (Resolve-Path -LiteralPath $RunDir).Path
    if (-not $OutDir) { $OutDir = Join-Path $RunDir 'package' }
    $dataDir = Join-Path $OutDir 'data'
    New-Item -ItemType Directory -Force $dataDir | Out-Null
    Get-ChildItem -LiteralPath $dataDir -Filter '*.jsonl' -ErrorAction SilentlyContinue | Remove-Item -Force

    $summary = $null
    $sf = Join-Path $RunDir 'run-summary.json'
    if (Test-Path -LiteralPath $sf) { try { $summary = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $summary = $null } }

    $started = if ($summary) { ConvertTo-UtcText $summary.startedAt } else { $null }
    $finished = if ($summary) { ConvertTo-UtcText $summary.finishedAt } else { $null }
    $period = if ($summary -and $summary.period) { [string]$summary.period } else { Split-Path $RunDir -Leaf }
    $runMonth = if ($finished) { $finished.Substring(0, 7) } else { $period }

    $subIds = Get-SubscriptionIdMap $RunDir
    $az = Get-AzqrRows (Join-Path $RunDir 'azqr')
    $mt = Get-MaesterRows (Join-Path $RunDir 'maester')
    $po = Get-PortalRows (Join-Path $RunDir 'portal') $subIds $runMonth
    $st = Get-StructureRows (Join-Path $RunDir 'struktur')

    if (-not $TenantId) { $TenantId = if ($summary -and $summary.tenantId) { [string]$summary.tenantId } else { $mt.TenantId } }
    if (-not $started -and $mt.ExecutedAt) { $started = ConvertTo-UtcText $mt.ExecutedAt }
    if (-not $finished) { $finished = $started }

    $files = [ordered]@{}
    $write = {
        param($name, $rows)
        $n = Write-JsonLines (Join-Path $dataDir $name) $rows
        if ($n) { $files["data/$name"] = [ordered]@{ rows = $n; sha256 = (Get-FileSha256 (Join-Path $dataDir $name)) } }
        $n
    }
    $counts = [ordered]@{}
    $counts.findings = & $write 'findings.jsonl' (@($az.Findings) + @($mt.Findings) + @($po.Findings))
    $counts.rules = & $write 'rules.jsonl' (@($az.Rules) + @($mt.Rules))
    $counts.resources = & $write 'resources.jsonl' $az.Resources
    $counts.scopes = & $write 'scopes.jsonl' $st.Scopes
    $counts.networks = & $write 'networks.jsonl' $st.Networks
    $counts.peerings = & $write 'peerings.jsonl' $st.Peerings
    $counts.metrics = & $write 'metrics.jsonl' $po.Metrics
    $counts.defenderPlans = & $write 'defender-plans.jsonl' $po.Plans

    $present = [ordered]@{ azqr = [bool]$az.Findings.Count; maester = [bool]$mt.Findings.Count; structure = [bool]$st.Scopes.Count
                           plans = [bool]$po.Plans.Count; secureScore = [bool]($po.Metrics | Where-Object name -eq 'secureScore.percent'); secureScoreControls = [bool]($po.Metrics | Where-Object name -eq 'secureScore.control.unhealthy')
                           recommendations = [bool]$po.Findings.Count; cost = [bool]($po.Metrics | Where-Object name -eq 'cost.month') }
    $sources = Get-PackageSourceStates $summary $present
    $rowsBySource = @{ azqr = $az.Findings.Count; maester = $mt.Findings.Count; structure = $st.Scopes.Count; plans = $po.Plans.Count; recommendations = $po.Findings.Count
                       secureScore = @($po.Metrics | Where-Object name -eq 'secureScore.percent').Count; secureScoreControls = @($po.Metrics | Where-Object name -eq 'secureScore.control.unhealthy').Count
                       cost = @($po.Metrics | Where-Object name -eq 'cost.month').Count }
    foreach ($k in @($sources.Keys)) { if ($rowsBySource.ContainsKey($k)) { $sources[$k]['rows'] = $rowsBySource[$k] } }

    $visible = @($po.Plans | ForEach-Object { $_.subscriptionId } | Select-Object -Unique).Count
    $capped = $false
    if ($summary -and ($summary.PSObject.Properties.Name -contains 'options') -and $summary.options.maxPortalSubscriptions) { $capped = $visible -ge [int]$summary.options.maxPortalSubscriptions }
    $tools = [ordered]@{}
    if ($summary -and ($summary.PSObject.Properties.Name -contains 'tools')) { foreach ($p in $summary.tools.PSObject.Properties) { if ($p.Value) { $tools[$p.Name] = [string]$p.Value } } }
    $ver = if ($KitVersion) { $KitVersion } elseif ($summary -and $summary.kitVersion) { [string]$summary.kitVersion } else { '' }

    $manifest = [ordered]@{
        schema      = $script:PackageSchema
        runId       = (New-StableGuid "$TenantId|$started|$period")
        tenantId    = $TenantId
        startedAt   = $started
        finishedAt  = $finished
        period      = $period
        collector   = [ordered]@{ name = 'azure-rapportkit'; version = $ver }
        tools       = $tools
        coverage    = [ordered]@{ subscriptionsCollected = $visible; capped = $capped }
        sources     = $sources
        files       = $files
        anonymized  = $false
        imported    = [ordered]@{ from = 'result-folder'; keyQuality = $po.KeyQuality; subscriptionsMappedByName = $po.Mapped; subscriptionsUnmapped = $po.Unmapped }
    }
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    [pscustomobject]@{ OutDir = $OutDir; Manifest = $manifest; Counts = $counts }
}
