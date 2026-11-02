<#
  Anonymization of the report pages (for demos, training or sharing).

  The normal report is never changed. With -Anonymize (or the answer "yes" to the question at the start) a second set of
  pages is built in the folder anonym\ where names, e-mail addresses and IDs are replaced by aliases.

  How it works:
    1. Names are collected from the tool results (users, groups, service principals, subscriptions, management groups,
       resource groups, resources) and get aliases such as "User 3" or "Subscription 1" (the words come from the language
       pack). The same name always gets the same alias.
    2. In every page the collected names are replaced, but only in the text of the page (never in HTML tags or attributes).
    3. After that all GUIDs, e-mail addresses and *.onmicrosoft.com addresses are replaced, also those that were not collected.
    4. Links to the tools' own reports are removed (they contain real names and are not part of the anonymous version).

  Limitations (stated in the report): free text outside the collected columns, for example custom policy names, tag
  values and names shorter than 4 characters, is not replaced. Read through the anonymous version before sharing it.
#>

$script:Anon = $null

# Resets and prepares the alias lookup.
function Initialize-Anonymizer {
    $script:Anon = @{
        Tokens   = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        Multi    = [System.Collections.Generic.List[object]]::new()
        Counters = @{}
        Guids    = @{}
        Emails   = @{}
        Ips      = @{}
    }
}

function Get-AnonNumber([string]$Category) {
    if (-not $script:Anon.Counters.ContainsKey($Category)) { $script:Anon.Counters[$Category] = 0 }
    $script:Anon.Counters[$Category]++
    $script:Anon.Counters[$Category]
}

# Registers a name and returns its alias (the same alias if the name already exists). Returns $null if the value is too short or too common.
function Add-AnonValue([string]$Category, [string]$Label, $Value, [string]$Alias) {
    $v = ([string]$Value).Trim()
    if ($v.Length -lt 4) { return $null }
    # Common words that are also used in the report's own text are not replaced, so headings and explanations are not damaged.
    if ($v -in 'Tenant Root Group', 'Unknown', 'None', 'True', 'False', 'Microsoft', 'Reader', 'Owner', 'Contributor', 'Default', 'Azure', 'Security', 'Standard', 'Free', 'Basic', 'High', 'Medium', 'Low') { return $null }
    if ($v -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return $null }   # GUIDs are handled separately
    $existing = $null
    if ($script:Anon.Tokens.TryGetValue($v, [ref]$existing)) { return $existing }
    foreach ($m in $script:Anon.Multi) { if ($m.Value -eq $v) { return $m.Alias } }
    if (-not $Alias) { $Alias = '{0} {1}' -f $Label, (Get-AnonNumber $Category) }
    if ($v -match '^[\p{L}\p{N}][\p{L}\p{N}._@\-]*$') { $script:Anon.Tokens[$v] = $Alias }
    else { $script:Anon.Multi.Add(@{ Value = $v; Alias = $Alias }) }
    $Alias
}

# Collects what is to be replaced from the tool results ($d from Get-ReportData) and from the environment.
function Register-AnonData($d) {
    Initialize-Anonymizer
    $col = {
        param($rows, $names, $category, $label)
        foreach ($r in @($rows)) { foreach ($n in $names) { if ($null -ne $r -and $r.PSObject.Properties.Name -contains $n) { [void](Add-AnonValue $category $label $r.$n) } } }
    }

    # Role assignments: users, groups and service principals each get their own counter, and the sign-in name gets the same number.
    foreach ($r in @($d.GvRoles)) {
        if ($null -eq $r) { continue }
        $cat, $label, $mail = switch -Wildcard ([string]$r.ObjectType) {
            'User' { 'user', (T 'anon.user'), (T 'anon.mailUser') }
            'Group' { 'group', (T 'anon.group'), (T 'anon.mailGroup') }
            'ServicePrincipal*' { 'sp', (T 'anon.sp'), (T 'anon.mailSp') }
            default { 'obj', (T 'anon.object'), (T 'anon.mailObject') }
        }
        $alias = Add-AnonValue $cat $label $r.ObjectDisplayName
        if ($alias) {
            $n = ($alias -split ' ')[-1]
            [void](Add-AnonValue $cat $label $r.ObjectSignInName ('{0}{1}@{2}' -f $mail, $n, (T 'anon.mailDomain')))
        }
        else { [void](Add-AnonValue $cat $label $r.ObjectSignInName) }
    }
    & $col $d.GvRoles @('MgName', 'MgParentName') 'mg' (T 'anon.mg')
    & $col $d.GvRoles @('SubscriptionName') 'sub' (T 'anon.subscription')
    & $col $d.GvRoles @('RoleAssignmentScopeRG') 'rg' (T 'anon.rg')
    & $col $d.GvRoles @('RoleAssignmentScopeRes') 'res' (T 'anon.resource')
    & $col $d.GvPolicies @('MgName', 'MgParentName') 'mg' (T 'anon.mg')
    & $col $d.GvPolicies @('subscriptionName') 'sub' (T 'anon.subscription')
    & $col $d.GvSubs @('Subscription') 'sub' (T 'anon.subscription')
    foreach ($r in @($d.GvSubs)) { if ($r -and $r.ManagementGroupPath) { foreach ($seg in ([string]$r.ManagementGroupPath -split '[/>|]')) { [void](Add-AnonValue 'mg' (T 'anon.mg') $seg) } } }
    & $col $d.GvResources @('subscriptionName') 'sub' (T 'anon.subscription')
    & $col $d.GvResources @('name') 'res' (T 'anon.resource')
    & $col $d.AzqrImp @('Subscription Name') 'sub' (T 'anon.subscription')
    & $col $d.AzqrImp @('Resource Group') 'rg' (T 'anon.rg')
    & $col $d.AzqrImp @('Resource Name') 'res' (T 'anon.resource')
    & $col $d.AzqrInv @('Resource Group') 'rg' (T 'anon.rg')
    & $col $d.AzqrInv @('Resource Name') 'res' (T 'anon.resource')
    & $col $d.AzqrAdv @('Subscription Name') 'sub' (T 'anon.subscription')
    & $col $d.AzqrAdv @('Resource Name') 'res' (T 'anon.resource')
    foreach ($rows in @($d.Plans, $d.Scores, $d.Ctrls, $d.Recs, $d.Costs)) { & $col $rows @('Prenumeration') 'sub' (T 'anon.subscription') }
    foreach ($r in @($d.Recs)) { if ($r -and $r.Resurs) { [void](Add-AnonValue 'res' (T 'anon.resource') (([string]$r.Resurs -split '/')[-1])) } }

    # Structure: management groups, subscriptions, networks and nodes
    foreach ($r in @($d.MgRows)) {
        if ($null -eq $r) { continue }
        if ($r.Typ -eq 'Prenumeration') { [void](Add-AnonValue 'sub' (T 'anon.subscription') $r.Namn) }
        else { $a = Add-AnonValue 'mg' (T 'anon.mg') $r.Namn; [void](Add-AnonValue 'mg' (T 'anon.mg') $r.Id $a) }
    }
    & $col $d.Vnets @('Namn') 'vnet' (T 'anon.vnet')
    & $col $d.Vnets @('Resursgrupp') 'rg' (T 'anon.rg')
    & $col $d.Peerings @('Fran', 'Till') 'vnet' (T 'anon.vnet')
    & $col $d.NetNodes @('Namn') 'node' (T 'anon.node')
    & $col $d.NetNodes @('Resursgrupp') 'rg' (T 'anon.rg')

    # The environment: computer, account and paths show on the About page.
    [void](Add-AnonValue 'host' (T 'anon.host') $env:COMPUTERNAME)
    [void](Add-AnonValue 'acct' (T 'anon.account') $env:USERNAME)
    foreach ($p in @($RunDir, $OutputRoot, $ScriptRoot, $env:USERPROFILE)) { if ($p) { [void](Add-AnonValue 'path' (T 'anon.pathLabel') $p (T 'anon.pathAlias')) } }
    $script:Anon.Multi = [System.Collections.Generic.List[object]]@($script:Anon.Multi | Sort-Object { $_.Value.Length } -Descending)
}

# Replaces the content of a piece of text (already decoded from HTML).
function Invoke-AnonText([string]$Text) {
    if ($Text.Length -lt 4) { return $Text }
    # Resource IDs (/resourceGroups/<name>, /providers/<provider>/<type>/<name>) can contain names that were not collected
    # from any column: they are registered and replaced here.
    $Text = [regex]::Replace($Text, '(?i)(/resourcegroups/)([^/\s<>"]+)', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $a = Add-AnonValue 'rg' (T 'anon.rg') $m.Groups[2].Value
            if ($a) { $m.Groups[1].Value + $a } else { $m.Value }
        })
    $Text = [regex]::Replace($Text, '(?i)(/providers/[^/\s<>"]+/[^/\s<>"]+/)([^/\s<>"]+)', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $a = Add-AnonValue 'res' (T 'anon.resource') $m.Groups[2].Value
            if ($a) { $m.Groups[1].Value + $a } else { $m.Value }
        })
    foreach ($m in $script:Anon.Multi) {
        $Text = [regex]::Replace($Text, '(?<![\p{L}\p{N}])' + [regex]::Escape($m.Value) + '(?![\p{L}\p{N}])', $m.Alias.Replace('$', '$$'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $Text = [regex]::Replace($Text, '[\p{L}\p{N}][\p{L}\p{N}._@\-]*', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $core = $m.Value; $trail = ''
            while ($core.Length -gt 1 -and $core[-1] -in '.', '_', '-') { $trail = $core[-1] + $trail; $core = $core.Substring(0, $core.Length - 1) }
            $alias = $null
            if ($script:Anon.Tokens.TryGetValue($core, [ref]$alias)) { $alias + $trail } else { $m.Value }
        })
    # E-mail addresses that were not collected (but not the aliases that were already set).
    $Text = [regex]::Replace($Text, '[\p{L}\p{N}._%+#\-]+@[\p{L}\p{N}.\-]+\.[A-Za-z]{2,}', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            if ($m.Value -like ('*@' + (T 'anon.mailDomain'))) { return $m.Value }
            $k = $m.Value.ToLower()
            if (-not $script:Anon.Emails.ContainsKey($k)) { $script:Anon.Emails[$k] = '{0}{1}@{2}' -f (T 'anon.person'), ($script:Anon.Emails.Count + 1), (T 'anon.mailDomain') }
            $script:Anon.Emails[$k]
        })
    $Text = [regex]::Replace($Text, '(?i)\b[A-Za-z0-9\-]+\.onmicrosoft\.com\b', (T 'anon.onmicrosoft'))
    # IPv4 addresses and address spaces (10.0.0.0/16): every address gets its own replacement address, the prefix length is kept.
    $Text = [regex]::Replace($Text, '(?<![0-9.])(\d{1,3}(?:\.\d{1,3}){3})(/\d{1,2})?(?![0-9.])', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $ip = $m.Groups[1].Value
            if (-not $script:Anon.Ips.ContainsKey($ip)) { $n = $script:Anon.Ips.Count + 1; $script:Anon.Ips[$ip] = '10.{0}.{1}.0' -f (99 + [math]::Floor($n / 250)), ($n % 250) }
            $script:Anon.Ips[$ip] + $m.Groups[2].Value
        })
    $Text = [regex]::Replace($Text, '(?<![0-9A-Za-z])[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}(?![0-9A-Za-z])', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $k = $m.Value.ToLower()
            if (-not $script:Anon.Guids.ContainsKey($k)) { $script:Anon.Guids[$k] = '00000000-0000-4000-8000-{0:D12}' -f ($script:Anon.Guids.Count + 1) }
            $script:Anon.Guids[$k]
        })
    $Text
}

# Anonymizes a piece of HTML: only text nodes are processed, tags and attributes are left alone. Links to files from the
# tools (relative links that open in a new window) are replaced by plain text.
function ConvertTo-AnonymousHtml([string]$Html) {
    $Html = [regex]::Replace($Html, '<a href="(?!https?:|#)[^"]*" target="_blank"[^>]*>(.*?)</a>', {
            param($m)
            $inner = [regex]::Replace($m.Groups[1].Value, '<span class="rk-ext"[^>]*>.*?</span>', '')
            '<span class="muted">{0} ({1})</span>' -f $inner, (Esc (T 'anon.notIncluded'))
        })
    $parts = [regex]::Split($Html, '(<[^>]*>)')
    $sb = [System.Text.StringBuilder]::new()
    foreach ($p in $parts) {
        if ($p.StartsWith('<') -and $p.EndsWith('>')) { [void]$sb.Append($p); continue }
        if ($p.Trim().Length -lt 4) { [void]$sb.Append($p); continue }
        [void]$sb.Append((Esc (Invoke-AnonText ([System.Web.HttpUtility]::HtmlDecode($p)))))
    }
    $sb.ToString()
}
