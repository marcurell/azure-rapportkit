<#
  The Structure report page: management group tree, virtual networks (VNets) with peerings (diagram and tables), network
  nodes, and automatic observations (isolated networks, one-way or broken peerings, overlapping address spaces).

  Reads the CSV files that lib\Structure.ps1 saved in struktur\, and falls back on Governance Visualizer's data for the
  management groups if they are missing. Dot-sourced by lib\Report.ps1. All texts come from the language packs (T).

  The CSV files keep their Swedish column names and values (Namn, Typ = 'Managementgrupp' / 'Prenumeration', ...): they
  are a data format shared with older runs, not report text.
#>

# Last part of a resource ID (the name). Also in lib\Structure.ps1 (which is not always loaded when the report is built).
function Get-IdLeaf([string]$Id) { if ($Id) { ($Id.TrimEnd('/') -split '/')[-1] } else { '' } }

# Reads the structure CSV files into $d (the values are $null if they are missing).
function Read-StructureData($d) {
    $dir = $null
    if ($Dirs -and $Dirs.ContainsKey('struktur')) { $dir = $Dirs['struktur'] }
    $rs = {
        param($name, $req)
        if ($dir) { $f = Join-Path $dir $name; if (Test-Path -LiteralPath $f) { Import-CsvChecked $f $req } }
    }
    $d.MgRows = & $rs 'managementgrupper.csv' @('Id', 'Namn', 'Typ', 'Foralder')
    $d.Vnets = & $rs 'natverk-vnet.csv' @('Id', 'Namn', 'Adressrymd')
    $d.Peerings = & $rs 'natverk-peerings.csv' @('FranId', 'TillId', 'Status')
    $d.NetNodes = & $rs 'natverk-noder.csv' @('Typ', 'Namn')
    $d.SubRes = & $rs 'resurser-per-prenumeration.csv' @('Prenumeration', 'Resurser')
    $d.StructurePresent = [bool]($d.MgRows -or $d.Vnets -or $d.GvSubs)
}

# Management groups and subscriptions from Governance Visualizer's CSV files, if struktur\ is missing (older runs).
function Get-MgRowsFromGovViz($d) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($r in @($d.GvRoles) + @($d.GvPolicies)) {
        if ($null -eq $r -or -not $r.MgId) { continue }
        $k = ([string]$r.MgId).ToLower()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $parent = [string]$r.MgParentId
        if ($parent -match '^_*TenantRoot$') { $parent = '' }
        $rows.Add([pscustomobject]@{ Niva = [int]$r.Level; Id = $r.MgId; Namn = $r.MgName; Typ = 'Managementgrupp'; Foralder = $parent })
    }
    foreach ($s in @($d.GvSubs)) {
        if ($null -eq $s -or -not $s.SubscriptionId) { continue }
        $path = @(([string]$s.ManagementGroupPath) -split '[/>|]' | Where-Object { $_ })
        $rows.Add([pscustomobject]@{ Niva = $path.Count; Id = $s.SubscriptionId; Namn = $s.Subscription; Typ = 'Prenumeration'; Foralder = $(if ($path.Count) { $path[-1] } else { '' }) })
    }
    , $rows.ToArray()
}

# --- The tree ------------------------------------------------------------------------------------------

function Get-MgNodeHtml($Row, $ByParent, $SubRes, [int]$Depth) {
    $id = [string]$Row.Id
    $isSub = $Row.Typ -eq 'Prenumeration'
    $name = if ($Row.Namn) { $Row.Namn } else { $id }
    if ($isSub) {
        $cnt = ''
        $k = $id.ToLower()
        if ($SubRes.ContainsKey($k)) { $cnt = ' &middot; ' + (Esc (T 'tree.resources' $SubRes[$k])) }
        return ('<li class="sub"><span class="nm">{0}</span><span class="tag">{1}{2}</span></li>' -f (Esc $name), (Esc (T 'tree.subscription')), $cnt)
    }
    $kids = @()
    $key = $id.ToLower()
    if ($Depth -lt 12 -and $ByParent.ContainsKey($key)) { $kids = @($ByParent[$key]) }
    $mgs = @($kids | Where-Object Typ -ne 'Prenumeration' | Sort-Object Namn)
    $subs = @($kids | Where-Object Typ -eq 'Prenumeration' | Sort-Object Namn)
    $inner = (($mgs + $subs) | ForEach-Object { Get-MgNodeHtml $_ $ByParent $SubRes ($Depth + 1) }) -join ''
    $idTag = if ($id -and (($id -replace '[^A-Za-z0-9]', '') -ne ($name -replace '[^A-Za-z0-9]', ''))) { ' &middot; ' + (Esc $id) } else { '' }
    $ul = if ($inner) { '<ul>' + $inner + '</ul>' } else { '' }
    '<li class="mg"><span class="nm">{0}</span><span class="tag">{1}{2}</span>{3}</li>' -f (Esc $name), (Esc (T 'tree.mg')), $idTag, $ul
}

function Get-MgTreeHtml($Rows, $SubRes) {
    $rows = @($Rows)
    $ids = @{}
    foreach ($r in $rows) { $ids[([string]$r.Id).ToLower()] = $true }
    $byParent = @{}
    foreach ($r in $rows) {
        $p = ([string]$r.Foralder).ToLower()
        if (-not $byParent.ContainsKey($p)) { $byParent[$p] = [System.Collections.Generic.List[object]]::new() }
        $byParent[$p].Add($r)
    }
    $roots = @($rows | Where-Object { -not $_.Foralder -or -not $ids.ContainsKey(([string]$_.Foralder).ToLower()) } | Sort-Object { if ($_.Typ -eq 'Prenumeration') { 1 } else { 0 } }, Namn)
    '<ul class="tree">' + (($roots | ForEach-Object { Get-MgNodeHtml $_ $byParent $SubRes 0 }) -join '') + '</ul>'
}

# --- Network model -------------------------------------------------------------------------------------

# IPv4 range (start, end as integers) of a CIDR. $null for anything else (for example IPv6).
function ConvertTo-CidrRange([string]$Cidr) {
    if ($Cidr -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') { return $null }
    $o = @($Matches[1], $Matches[2], $Matches[3], $Matches[4]) | ForEach-Object { [long]$_ }
    $len = [int]$Matches[5]
    if (($o | Where-Object { $_ -gt 255 }) -or $len -gt 32) { return $null }
    $ip = ($o[0] * 16777216) + ($o[1] * 65536) + ($o[2] * 256) + $o[3]
    $size = [long][math]::Pow(2, 32 - $len)
    $start = [long]([math]::Floor($ip / $size) * $size)
    @($start, ($start + $size - 1))
}

# Builds the model: networks with a role, peerings per pair, neighbours and observations.
# Roles are the codes 'Hub', 'Spoke' and 'Isolated' (shown through T 'role.<code>').
function Get-NetworkModel($d) {
    $vn = @($d.Vnets | Where-Object { $_ })
    $subName = @{}
    foreach ($r in @($d.MgRows | Where-Object { $_.Typ -eq 'Prenumeration' })) { $subName[([string]$r.Id).ToLower()] = $r.Namn }
    $byId = @{}
    foreach ($v in $vn) { $byId[([string]$v.Id).ToLower()] = $v }

    # Nodes inside a network (firewalls, gateways) and peerings with gateway transit show that the network is a hub.
    $nodesIn = @{}
    foreach ($n in @($d.NetNodes | Where-Object { $_ -and $_.VnetId })) { $nodesIn[([string]$n.VnetId).ToLower()] = $true }

    $pairs = @{}
    foreach ($p in @($d.Peerings | Where-Object { $_ })) {
        $a = ([string]$p.FranId).ToLower(); $b = ([string]$p.TillId).ToLower()
        if (-not $a -or -not $b) { continue }
        $key = if ($a -lt $b) { "$a|$b" } else { "$b|$a" }
        if (-not $pairs.ContainsKey($key)) { $pairs[$key] = @{ A = $(if ($a -lt $b) { $a } else { $b }); B = $(if ($a -lt $b) { $b } else { $a }); Dirs = [System.Collections.Generic.List[object]]::new() } }
        $pairs[$key].Dirs.Add($p)
    }
    $edges = foreach ($k in $pairs.Keys) {
        $e = $pairs[$k]
        $states = @($e.Dirs | ForEach-Object { [string]$_.Status })
        $state = 'ok'
        if ($states | Where-Object { $_ -ne 'Connected' }) { $state = 'bad' }
        elseif ($e.Dirs.Count -lt 2 -and $byId.ContainsKey($e.A) -and $byId.ContainsKey($e.B)) { $state = 'oneway' }
        [pscustomobject]@{ A = $e.A; B = $e.B; State = $state; Dirs = $e.Dirs; Transit = [bool]@($e.Dirs | Where-Object { $_.GatewayTransit -eq 'True' }).Count }
    }
    $edges = @($edges)

    $degree = @{}
    foreach ($e in $edges) { foreach ($x in $e.A, $e.B) { if (-not $degree.ContainsKey($x)) { $degree[$x] = 0 }; $degree[$x]++ } }

    # Connected groups of networks (components)
    $adj = @{}
    foreach ($e in $edges) {
        foreach ($pair in @(@($e.A, $e.B), @($e.B, $e.A))) {
            if (-not $adj.ContainsKey($pair[0])) { $adj[$pair[0]] = [System.Collections.Generic.List[string]]::new() }
            $adj[$pair[0]].Add($pair[1])
        }
    }
    $comp = @{}; $components = [System.Collections.Generic.List[object]]::new()
    foreach ($start in @($adj.Keys | Sort-Object)) {
        if ($comp.ContainsKey($start)) { continue }
        $members = [System.Collections.Generic.List[string]]::new()
        $queue = [System.Collections.Generic.Queue[string]]::new(); $queue.Enqueue($start); $comp[$start] = $true
        while ($queue.Count) { $x = $queue.Dequeue(); $members.Add($x); foreach ($y in $adj[$x]) { if (-not $comp.ContainsKey($y)) { $comp[$y] = $true; $queue.Enqueue($y) } } }
        $components.Add($members.ToArray())
    }

    # Roles
    $maxDeg = @{}
    foreach ($c in $components) { $m = ($c | ForEach-Object { $degree[$_] } | Measure-Object -Maximum).Maximum; foreach ($x in $c) { $maxDeg[$x] = $m } }
    # A hub has a firewall/gateway in the network, or hands out gateway transit to other networks (that side of the
    # peering has "allow gateway transit"), or is the most connected network in a group of at least three networks.
    $transitFrom = @{}
    foreach ($p in @($d.Peerings | Where-Object { $_ -and $_.GatewayTransit -eq 'True' })) { $transitFrom[([string]$p.FranId).ToLower()] = $true }
    $role = @{}
    foreach ($v in $vn) {
        $id = ([string]$v.Id).ToLower()
        $deg = 0; if ($degree.ContainsKey($id)) { $deg = $degree[$id] }
        $r = 'Isolated'
        if ($deg -ge 1) { $r = 'Spoke' }
        if ($deg -ge 1 -and ($nodesIn.ContainsKey($id) -or $transitFrom.ContainsKey($id))) { $r = 'Hub' }
        elseif ($deg -ge 2 -and $deg -eq $maxDeg[$id]) { $r = 'Hub' }
        $role[$id] = $r
    }

    # Overlapping address spaces between networks (at most 400 networks, otherwise the check is skipped)
    $overlaps = [System.Collections.Generic.List[object]]::new()
    $overlapSkipped = $false
    if ($vn.Count -le 400) {
        $ranges = foreach ($v in $vn) { foreach ($c in @(([string]$v.Adressrymd) -split '\s+' | Where-Object { $_ })) { $r = ConvertTo-CidrRange $c; if ($r) { [pscustomobject]@{ V = $v; Cidr = $c; S = $r[0]; E = $r[1] } } } }
        $ranges = @($ranges)
        for ($i = 0; $i -lt $ranges.Count; $i++) {
            for ($j = $i + 1; $j -lt $ranges.Count; $j++) {
                if ($ranges[$i].V.Id -eq $ranges[$j].V.Id) { continue }
                if ($ranges[$i].S -le $ranges[$j].E -and $ranges[$j].S -le $ranges[$i].E) { $overlaps.Add([pscustomobject]@{ A = $ranges[$i].V; ACidr = $ranges[$i].Cidr; B = $ranges[$j].V; BCidr = $ranges[$j].Cidr }) }
            }
        }
    }
    else { $overlapSkipped = $true }

    @{ Vnets = $vn; ById = $byId; Edges = $edges; Degree = $degree; Components = @($components); Role = $role; Overlaps = @($overlaps); OverlapSkipped = $overlapSkipped; SubName = $subName; NodesIn = $nodesIn }
}

# --- Diagram: peerings as a network diagram (SVG) --------------------------------------------------------

function Get-ShortText([string]$Text, [int]$Max) { if ($Text.Length -gt $Max) { $Text.Substring(0, $Max - 1) + [string][char]0x2026 } else { $Text } }

# One component (a list of network IDs) as SVG: the network with most peerings in the middle, the others in a ring. At most 13 networks.
function Get-PeeringSvg($Members, $Model) {
    $ids = @($Members | Sort-Object { -[int]$Model.Degree[$_] }, { $_ })
    $n = $ids.Count
    $w = 900; $h = if ($n -le 3) { 360 } else { 540 }
    $cx = $w / 2; $cy = $h / 2
    $pos = @{}
    $pos[$ids[0]] = @($cx, $cy)
    $sat = $n - 1
    $rx = 320; $ry = ($h / 2) - 60
    for ($i = 0; $i -lt $sat; $i++) {
        $ang = (-90 + (360.0 * $i / [math]::Max($sat, 1))) * [math]::PI / 180
        $pos[$ids[$i + 1]] = @(($cx + $rx * [math]::Cos($ang)), ($cy + $ry * [math]::Sin($ang)))
    }
    $set = @{}; foreach ($x in $ids) { $set[$x] = $true }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(('<svg class="net-svg" viewBox="0 0 {0} {1}" role="img" aria-label="{2}" xmlns="http://www.w3.org/2000/svg">' -f $w, $h, (Esc (T 'net.svgLabel'))))
    foreach ($e in $Model.Edges) {
        if (-not ($set.ContainsKey($e.A) -and $set.ContainsKey($e.B))) { continue }
        $cls = switch ($e.State) { 'bad' { 'net-edge bad' } 'oneway' { 'net-edge warn' } default { 'net-edge' } }
        [void]$sb.Append(('<line class="{0}" x1="{1:N0}" y1="{2:N0}" x2="{3:N0}" y2="{4:N0}"/>' -f $cls, $pos[$e.A][0], $pos[$e.A][1], $pos[$e.B][0], $pos[$e.B][1]))
    }
    foreach ($x in $ids) {
        $v = $Model.ById[$x]
        $known = $null -ne $v
        $name = if ($known) { $v.Namn } else { Get-IdLeaf $x }
        $addr = if ($known) { (([string]$v.Adressrymd) -split '\s+')[0] } else { T 'net.unknown' }
        $cls = 'net-node'
        if ($known -and $Model.Role[$x] -eq 'Hub') { $cls += ' hub' }
        if (-not $known) { $cls += ' ext' }
        $px = $pos[$x][0]; $py = $pos[$x][1]
        [void]$sb.Append(('<g><rect class="{0}" x="{1:N0}" y="{2:N0}" width="180" height="52" rx="8"/><text class="net-t" x="{3:N0}" y="{4:N0}" text-anchor="middle">{5}</text><text class="net-s" x="{3:N0}" y="{6:N0}" text-anchor="middle">{7}</text></g>' -f $cls, ($px - 90), ($py - 26), $px, ($py - 4), (Esc (Get-ShortText $name 22)), ($py + 16), (Esc (Get-ShortText $addr 26))))
    }
    [void]$sb.Append('</svg>')
    $sb.ToString()
}

# --- The page ------------------------------------------------------------------------------------------

# Type name of a network node as shown in the table: from the language pack (nodetype.<type>), else the type as it is.
function Get-NodeTypeName([string]$Type) {
    $key = 'nodetype.' + $Type.ToLower()
    if ($script:Lang -and $script:Lang.ContainsKey($key)) { T $key } else { $Type }
}

function Get-StructurePageHtml($d) {
    if (-not $d.StructurePresent) { return (New-NoDataHtml (T 'str.none.what') (T 'str.none.why')) }
    $sb = [System.Text.StringBuilder]::new()
    $yes = T 'fmt.yes'; $no = T 'fmt.no'

    $mgRows = $d.MgRows
    $fromGv = $false
    if (-not $mgRows -and $d.GvPresent) { $mgRows = Get-MgRowsFromGovViz $d; $fromGv = $true }
    $subRes = @{}
    foreach ($r in @($d.SubRes | Where-Object { $_ })) { $subRes[([string]$r.Prenumeration).ToLower()] = $r.Resurser }

    $model = $null
    if ($d.Vnets) { $model = Get-NetworkModel $d }

    # Key figures
    [void]$sb.Append('<div class="tiles">')
    if ($mgRows) {
        [void]$sb.Append((Tile (T 'tile.mgs') @($mgRows | Where-Object Typ -eq 'Managementgrupp').Count))
        [void]$sb.Append((Tile (T 'tile.subscriptions') @($mgRows | Where-Object Typ -eq 'Prenumeration').Count))
    }
    if ($model) {
        [void]$sb.Append((Tile (T 'tile.vnets') @($model.Vnets).Count))
        [void]$sb.Append((Tile (T 'tile.peerings') @($d.Peerings | Where-Object { $_ }).Count))
        $iso = @($model.Vnets | Where-Object { $model.Role[([string]$_.Id).ToLower()] -eq 'Isolated' }).Count
        if ($iso) { [void]$sb.Append((Tile (T 'tile.isolated') $iso 'medium')) }
    }
    [void]$sb.Append('</div>')

    # Management group tree
    [void]$sb.Append('<h2>' + (Esc (T 'str.mgHeading')) + '</h2>')
    if ($mgRows) {
        $src = if ($fromGv) { T 'str.srcGovViz' } else { T 'str.srcAzure' }
        [void]$sb.Append('<p class="muted">' + (Esc ((T 'str.treeIntro') + ' ' + $src)) + '</p>' + (Get-MgTreeHtml $mgRows $subRes))
    }
    else { [void]$sb.Append((New-NoDataHtml (T 'str.noMg.what') (T 'str.noMg.why'))) }

    # Network
    [void]$sb.Append('<h2>' + (Esc (T 'str.netHeading')) + '</h2>')
    if (-not $model) {
        [void]$sb.Append((New-Callout (Esc (T 'str.noVnets'))))
    }
    else {
        # Observations
        $findings = [System.Collections.Generic.List[string]]::new()
        $isoNames = @($model.Vnets | Where-Object { $model.Role[([string]$_.Id).ToLower()] -eq 'Isolated' } | ForEach-Object { $_.Namn })
        if ($isoNames.Count) { $findings.Add((T 'find.isolated.html' $isoNames.Count (Esc (($isoNames | Select-Object -First 8) -join ', ')))) }
        $bad = @($model.Edges | Where-Object State -eq 'bad')
        if ($bad.Count) { $findings.Add((T 'find.notConnected.html' $bad.Count)) }
        $one = @($model.Edges | Where-Object State -eq 'oneway')
        if ($one.Count) {
            $names = @($one | ForEach-Object { T 'find.pairNames' $(if ($model.ById.ContainsKey($_.A)) { $model.ById[$_.A].Namn } else { Get-IdLeaf $_.A }) $(if ($model.ById.ContainsKey($_.B)) { $model.ById[$_.B].Namn } else { Get-IdLeaf $_.B }) })
            $findings.Add((T 'find.oneWay.html' $one.Count (Esc (($names | Select-Object -First 5) -join '; '))))
        }
        if ($model.Overlaps.Count) {
            $ov = @($model.Overlaps | Select-Object -First 6 | ForEach-Object { T 'find.overlapPair' $_.A.Namn $_.ACidr $_.B.Namn $_.BCidr })
            $findings.Add((T 'find.overlap.html' $model.Overlaps.Count (Esc ($ov -join '; '))))
        }
        if ($model.OverlapSkipped) { $findings.Add((Esc (T 'find.overlapSkipped'))) }
        $hubs = @($model.Vnets | Where-Object { $model.Role[([string]$_.Id).ToLower()] -eq 'Hub' })
        if ($hubs.Count) { $findings.Add((T 'find.hubSpoke.html' $hubs.Count (Esc (($hubs | ForEach-Object { T 'find.hubItem' $_.Namn $model.Degree[([string]$_.Id).ToLower()] } | Select-Object -First 5) -join ', ')))) }
        elseif (@($model.Edges).Count -eq 0) { $findings.Add((Esc (T 'find.noPeerings'))) }
        if ($findings.Count) { [void]$sb.Append('<h3>' + (Esc (T 'str.findings')) + '</h3><ul>' + (($findings | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>') }

        # Diagrams
        $diagrams = 0
        foreach ($c in $model.Components) {
            if ($diagrams -ge 4) { break }
            if (@($c).Count -gt 13) { [void]$sb.Append((New-Callout (Esc (T 'str.tooBig' @($c).Count)))); continue }
            [void]$sb.Append('<div class="card net-card">' + (Get-PeeringSvg $c $model) + '</div>')
            $diagrams++
        }
        if ($diagrams) { [void]$sb.Append('<p class="muted">' + (T 'str.legend.html') + '</p>') }

        # Tables
        $rows = foreach ($v in $model.Vnets) {
            $id = ([string]$v.Id).ToLower()
            $sn = if ($model.SubName.ContainsKey(([string]$v.Prenumeration).ToLower())) { $model.SubName[([string]$v.Prenumeration).ToLower()] } else { $v.Prenumeration }
            $deg = 0; if ($model.Degree.ContainsKey($id)) { $deg = $model.Degree[$id] }
            [pscustomobject]@{ Namn = $v.Namn; Prenumeration = $sn; Plats = $v.Plats; Adressrymd = $v.Adressrymd; Subnat = $v.Subnat; Peerings = $deg; Roll = (T "role.$($model.Role[$id])"); RollSort = $model.Role[$id] }
        }
        $rows = @($rows | Sort-Object @{ Expression = { switch ($_.RollSort) { 'Hub' { 0 } 'Spoke' { 1 } default { 2 } } } }, Namn)
        [void]$sb.Append('<h3>' + (Esc (T 'str.vnets')) + '</h3>' + (ConvertTo-HtmlTable $rows @(@{Name='Namn';Label=(T 'col.network')}, @{Name='Roll';Label=(T 'col.role')}, @{Name='Prenumeration';Label=(T 'col.subscription')}, @{Name='Plats';Label=(T 'col.location')}, @{Name='Adressrymd';Label=(T 'col.addressSpace')}, @{Name='Subnat';Label=(T 'col.subnets');Num=$true}, @{Name='Peerings';Label=(T 'col.peerings');Num=$true}) 40))

        if ($d.Peerings) {
            $pr = foreach ($p in @($d.Peerings | Where-Object { $_ })) {
                [pscustomobject]@{ Fran = $p.Fran; Till = $p.Till; Status = $p.Status; Transit = $(if ($p.GatewayTransit -eq 'True') { $yes } else { $no }); Remote = $(if ($p.AnvandRemoteGateways -eq 'True') { $yes } else { $no }); Fwd = $(if ($p.ForwardedTraffic -eq 'True') { $yes } else { $no }) }
            }
            [void]$sb.Append('<h3>' + (Esc (T 'str.peerings')) + '</h3>' + (ConvertTo-HtmlTable @($pr) @(@{Name='Fran';Label=(T 'col.from')}, @{Name='Till';Label=(T 'col.to')}, @{Name='Status';Label=(T 'col.status')}, @{Name='Transit';Label=(T 'col.gatewayTransit')}, @{Name='Remote';Label=(T 'col.remoteGateway')}, @{Name='Fwd';Label=(T 'col.forwarded')}) 40))
        }
        if ($d.NetNodes) {
            $nr = foreach ($n in @($d.NetNodes | Where-Object { $_ })) {
                $vname = ''
                if ($n.VnetId -and $model.ById.ContainsKey(([string]$n.VnetId).ToLower())) { $vname = $model.ById[([string]$n.VnetId).ToLower()].Namn }
                [pscustomobject]@{ Typ = (Get-NodeTypeName $n.Typ); Namn = $n.Namn; Plats = $n.Plats; Extra = $n.Extra; Vnet = $vname }
            }
            [void]$sb.Append('<h3>' + (Esc (T 'str.nodes')) + '</h3><p class="muted">' + (Esc (T 'str.nodesText')) + '</p>' + (ConvertTo-HtmlTable @($nr) @(@{Name='Typ';Label=(T 'col.type')}, @{Name='Namn';Label=(T 'col.name')}, @{Name='Vnet';Label=(T 'col.inNetwork')}, @{Name='Plats';Label=(T 'col.location')}, @{Name='Extra';Label=(T 'col.skuType')}) 40))
        }
    }
    [void]$sb.Append('<p class="muted">' + (Esc (T 'str.footer')) + '</p>')
    $sb.ToString()
}
