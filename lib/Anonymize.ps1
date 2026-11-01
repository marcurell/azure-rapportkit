<#
  Anonymisering av rapportsidorna (för demo, utbildning eller delning).

  Den vanliga rapporten ändras aldrig. Med -Anonymize (eller svaret "ja" på frågan i början) byggs dessutom en andra
  uppsättning sidor i mappen anonym\ där namn, e-postadresser och ID:n har bytts ut mot alias.

  Så här går det till:
    1. Namn samlas in från verktygens resultat (användare, grupper, tjänsteprinciper, prenumerationer, management groups,
       resursgrupper, resurser) och får alias som "Användare 3" eller "Prenumeration 1". Samma namn får alltid samma alias.
    2. I varje sida byts de insamlade namnen ut, men bara i sidans text (aldrig i HTML-taggar eller attribut).
    3. Därefter byts alla GUID, e-postadresser och *.onmicrosoft.com-adresser ut, även sådana som inte samlats in.
    4. Länkar till verktygens egna rapporter tas bort (de innehåller riktiga namn och ingår inte i den anonyma versionen).

  Begränsningar (tas upp i rapporten): fritext som inte ligger i de insamlade kolumnerna, till exempel egna policynamn,
  taggvärden och namn som är kortare än 4 tecken, byts inte ut. Titta igenom den anonyma versionen innan den delas.
#>

$script:Anon = $null

# Nollställer och förbereder aliasuppslag.
function Initialize-Anonymizer {
    $script:Anon = @{
        Tokens   = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        Multi    = [System.Collections.Generic.List[object]]::new()
        Counters = @{}
        Guids    = @{}
        Emails   = @{}
    }
}

function Get-AnonNumber([string]$Category) {
    if (-not $script:Anon.Counters.ContainsKey($Category)) { $script:Anon.Counters[$Category] = 0 }
    $script:Anon.Counters[$Category]++
    $script:Anon.Counters[$Category]
}

# Registrerar ett namn och ger dess alias (samma alias om namnet redan finns). Ger $null om värdet är för kort eller allmänt.
function Add-AnonValue([string]$Category, [string]$Label, $Value, [string]$Alias) {
    $v = ([string]$Value).Trim()
    if ($v.Length -lt 4) { return $null }
    # Allmänna ord som också används i rapportens egen text byts inte ut, så att rubriker och förklaringar inte förstörs.
    if ($v -in 'Tenant Root Group', 'Unknown', 'None', 'True', 'False', 'Microsoft', 'Reader', 'Owner', 'Contributor', 'Default', 'Azure', 'Security', 'Standard', 'Free', 'Basic', 'High', 'Medium', 'Low') { return $null }
    if ($v -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return $null }   # GUID hanteras separat
    $existing = $null
    if ($script:Anon.Tokens.TryGetValue($v, [ref]$existing)) { return $existing }
    foreach ($m in $script:Anon.Multi) { if ($m.Value -eq $v) { return $m.Alias } }
    if (-not $Alias) { $Alias = '{0} {1}' -f $Label, (Get-AnonNumber $Category) }
    if ($v -match '^[\p{L}\p{N}][\p{L}\p{N}._@\-]*$') { $script:Anon.Tokens[$v] = $Alias }
    else { $script:Anon.Multi.Add(@{ Value = $v; Alias = $Alias }) }
    $Alias
}

# Samlar in det som ska bytas ut ur verktygens resultat ($d från Get-ReportData) och ur miljön.
function Register-AnonData($d) {
    Initialize-Anonymizer
    $col = {
        param($rows, $names, $category, $label)
        foreach ($r in @($rows)) { foreach ($n in $names) { if ($null -ne $r -and $r.PSObject.Properties.Name -contains $n) { [void](Add-AnonValue $category $label $r.$n) } } }
    }

    # Rolltilldelningar: användare, grupper och tjänsteprinciper får var sin räknare, och inloggningsnamnet får samma nummer.
    foreach ($r in @($d.GvRoles)) {
        if ($null -eq $r) { continue }
        $cat, $label, $mail = switch -Wildcard ([string]$r.ObjectType) {
            'User' { 'user', 'Användare', 'användare' }
            'Group' { 'group', 'Grupp', 'grupp' }
            'ServicePrincipal*' { 'sp', 'Tjänsteprincipal', 'tjansteprincipal' }
            default { 'obj', 'Objekt', 'objekt' }
        }
        $alias = Add-AnonValue $cat $label $r.ObjectDisplayName
        if ($alias) {
            $n = ($alias -split ' ')[-1]
            [void](Add-AnonValue $cat $label $r.ObjectSignInName ('{0}{1}@exempel.invalid' -f $mail, $n))
        }
        else { [void](Add-AnonValue $cat $label $r.ObjectSignInName) }
    }
    & $col $d.GvRoles @('MgName', 'MgParentName') 'mg' 'Management group'
    & $col $d.GvRoles @('SubscriptionName') 'sub' 'Prenumeration'
    & $col $d.GvRoles @('RoleAssignmentScopeRG') 'rg' 'Resursgrupp'
    & $col $d.GvRoles @('RoleAssignmentScopeRes') 'res' 'Resurs'
    & $col $d.GvPolicies @('MgName', 'MgParentName') 'mg' 'Management group'
    & $col $d.GvPolicies @('subscriptionName') 'sub' 'Prenumeration'
    & $col $d.GvSubs @('Subscription') 'sub' 'Prenumeration'
    foreach ($r in @($d.GvSubs)) { if ($r -and $r.ManagementGroupPath) { foreach ($seg in ([string]$r.ManagementGroupPath -split '[/>|]')) { [void](Add-AnonValue 'mg' 'Management group' $seg) } } }
    & $col $d.GvResources @('subscriptionName') 'sub' 'Prenumeration'
    & $col $d.GvResources @('name') 'res' 'Resurs'
    & $col $d.AzqrImp @('Subscription Name') 'sub' 'Prenumeration'
    & $col $d.AzqrImp @('Resource Group') 'rg' 'Resursgrupp'
    & $col $d.AzqrImp @('Resource Name') 'res' 'Resurs'
    & $col $d.AzqrInv @('Resource Group') 'rg' 'Resursgrupp'
    & $col $d.AzqrInv @('Resource Name') 'res' 'Resurs'
    & $col $d.AzqrAdv @('Subscription Name') 'sub' 'Prenumeration'
    & $col $d.AzqrAdv @('Resource Name') 'res' 'Resurs'
    foreach ($rows in @($d.Plans, $d.Scores, $d.Ctrls, $d.Recs, $d.Costs)) { & $col $rows @('Prenumeration') 'sub' 'Prenumeration' }
    foreach ($r in @($d.Recs)) { if ($r -and $r.Resurs) { [void](Add-AnonValue 'res' 'Resurs' (([string]$r.Resurs -split '/')[-1])) } }

    # Miljön: dator, konto och sökvägar syns på sidan Om körningen.
    [void](Add-AnonValue 'host' 'Dator' $env:COMPUTERNAME)
    [void](Add-AnonValue 'acct' 'Konto' $env:USERNAME)
    foreach ($p in @($RunDir, $OutputRoot, $ScriptRoot, $env:USERPROFILE)) { if ($p) { [void](Add-AnonValue 'path' 'Sökväg' $p '[sökväg]') } }
    $script:Anon.Multi = [System.Collections.Generic.List[object]]@($script:Anon.Multi | Sort-Object { $_.Value.Length } -Descending)
}

# Byter ut innehållet i en textbit (redan avkodad från HTML).
function Invoke-AnonText([string]$Text) {
    if ($Text.Length -lt 4) { return $Text }
    # Resurs-ID:n (/resourceGroups/<namn>, /providers/<leverantör>/<typ>/<namn>) kan innehålla namn som inte samlats in
    # från någon kolumn: de registreras och byts ut här.
    $Text = [regex]::Replace($Text, '(?i)(/resourcegroups/)([^/\s<>"]+)', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $a = Add-AnonValue 'rg' 'Resursgrupp' $m.Groups[2].Value
            if ($a) { $m.Groups[1].Value + $a } else { $m.Value }
        })
    $Text = [regex]::Replace($Text, '(?i)(/providers/[^/\s<>"]+/[^/\s<>"]+/)([^/\s<>"]+)', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $a = Add-AnonValue 'res' 'Resurs' $m.Groups[2].Value
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
    # E-postadresser som inte samlats in (men inte de alias som redan satts).
    $Text = [regex]::Replace($Text, '[\p{L}\p{N}._%+#\-]+@[\p{L}\p{N}.\-]+\.[A-Za-z]{2,}', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            if ($m.Value -like '*@exempel.invalid') { return $m.Value }
            $k = $m.Value.ToLower()
            if (-not $script:Anon.Emails.ContainsKey($k)) { $script:Anon.Emails[$k] = 'person{0}@exempel.invalid' -f ($script:Anon.Emails.Count + 1) }
            $script:Anon.Emails[$k]
        })
    $Text = [regex]::Replace($Text, '(?i)\b[A-Za-z0-9\-]+\.onmicrosoft\.com\b', 'exempel.onmicrosoft.com')
    $Text = [regex]::Replace($Text, '(?<![0-9A-Za-z])[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}(?![0-9A-Za-z])', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $k = $m.Value.ToLower()
            if (-not $script:Anon.Guids.ContainsKey($k)) { $script:Anon.Guids[$k] = '00000000-0000-4000-8000-{0:D12}' -f ($script:Anon.Guids.Count + 1) }
            $script:Anon.Guids[$k]
        })
    $Text
}

# Anonymiserar ett HTML-stycke: bara textnoder bearbetas, taggar och attribut lämnas orörda. Länkar till filer från
# verktygen (relativa länkar som öppnas i nytt fönster) ersätts av vanlig text.
function ConvertTo-AnonymousHtml([string]$Html) {
    $Html = [regex]::Replace($Html, '<a href="(?!https?:|#)[^"]*" target="_blank"[^>]*>(.*?)</a>', {
            param($m)
            $inner = [regex]::Replace($m.Groups[1].Value, '<span class="rk-ext"[^>]*>.*?</span>', '')
            '<span class="muted">{0} (ingår inte i den anonyma versionen)</span>' -f $inner
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
