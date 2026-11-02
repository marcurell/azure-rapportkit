<#
  Insamling av miljöns struktur: managementgrupper, virtuella nätverk (VNet) med peerings, nätverksnoder (brandväggar,
  gateways m.m.) och antal resurser per prenumeration. Allt är read-only och kräver bara Reader på Tenant Root Group.

  Resultatet sparas som CSV i struktur\ och läses av rapportsidan Struktur (lib\Report.ps1).

  Filen läses in (dot-source) av Run-Rapportkit.ps1 i steg 9 och använder dess funktioner (Invoke-ArmRest, Write-Ok,
  Add-Warning). Startpunkt: Save-StructureData.
#>

# Lägger till en nod (managementgrupp eller prenumeration) och dess barn i listan $Rows.
function Add-StructureNode($Node, [string]$ParentId, [int]$Level, $Rows) {
    $p = if ($Node.properties) { $Node.properties } else { $Node }
    $isSub = ([string]$Node.type) -match 'subscriptions$'
    $id = [string]$Node.name
    $Rows.Add([pscustomobject]@{ Niva = $Level; Id = $id; Namn = [string]$p.displayName; Typ = $(if ($isSub) { 'Prenumeration' } else { 'Managementgrupp' }); Foralder = $ParentId })
    foreach ($c in @($p.children)) { if ($c) { Add-StructureNode $c $id ($Level + 1) $Rows } }
}

# Kör en Azure Resource Graph-fråga över hela tenanten (eller vald managementgrupp) och ger alla rader (sidindelat).
# Kan managementgruppen inte frågas (saknad läsrätt) används de prenumerationer kontot ser.
function Invoke-ResourceGraph([string]$Query, [string]$RootMg, [string[]]$SubscriptionIds) {
    $scope = @{ managementGroups = @($RootMg) }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $all = [System.Collections.Generic.List[object]]::new()
            $skip = $null
            do {
                $body = @{ query = $Query; options = @{ '$top' = 1000; resultFormat = 'objectArray' } }
                foreach ($k in $scope.Keys) { $body[$k] = $scope[$k] }
                if ($skip) { $body.options['$skipToken'] = $skip }
                $r = Invoke-ArmRest 'POST' 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' $body
                foreach ($row in @($r.data)) { if ($row) { $all.Add($row) } }
                $skip = $r.'$skipToken'
            } while ($skip)
            return , $all.ToArray()
        }
        catch {
            if ($attempt -eq 1 -and $SubscriptionIds.Count) { $scope = @{ subscriptions = @($SubscriptionIds | Select-Object -First 1000) }; continue }
            throw
        }
    }
}

# Sista delen av ett resurs-ID (namnet).
function Get-IdLeaf([string]$Id) { if ($Id) { ($Id.TrimEnd('/') -split '/')[-1] } else { '' } }

# Hämtar och sparar strukturen i $OutDir. Ger en kort text med antal. Varje del fångas för sig; felen samlas i $Errors.
function Save-StructureData([string]$OutDir, [string]$RootMg, [string[]]$SubscriptionIds, $Errors) {
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $save = { param($name, $rows) $list = @($rows | Where-Object { $_ }); if ($list.Count) { $list | Export-Csv -Path (Join-Path $OutDir $name) -NoTypeInformation -Encoding utf8BOM; Write-Ok "$name`: $($list.Count) rader" } }
    $counts = [ordered]@{}

    # Managementgrupper och prenumerationer som träd
    try {
        $r = Invoke-ArmRest 'GET' ("https://management.azure.com/providers/Microsoft.Management/managementGroups/{0}?`$expand=children&`$recurse=true&api-version=2021-04-01" -f $RootMg)
        $rows = [System.Collections.Generic.List[object]]::new()
        Add-StructureNode $r '' 0 $rows
        & $save 'managementgrupper.csv' $rows
        $counts['managementgrupper'] = @($rows | Where-Object Typ -eq 'Managementgrupp').Count
    }
    catch { $Errors.Add("Managementgrupper: $($_.Exception.Message)") }

    # Virtuella nätverk och deras peerings
    try {
        $vn = Invoke-ResourceGraph "resources | where type =~ 'microsoft.network/virtualnetworks' | project id, name, subscriptionId, resourceGroup, location, prefixes = properties.addressSpace.addressPrefixes, subnets = array_length(properties.subnets), peerings = properties.virtualNetworkPeerings" $RootMg $SubscriptionIds
        $vrows = [System.Collections.Generic.List[object]]::new(); $prows = [System.Collections.Generic.List[object]]::new()
        foreach ($v in $vn) {
            $vrows.Add([pscustomobject]@{ Id = $v.id; Namn = $v.name; Prenumeration = $v.subscriptionId; Resursgrupp = $v.resourceGroup; Plats = $v.location; Adressrymd = (@($v.prefixes) -join ' '); Subnat = [int]$v.subnets })
            foreach ($p in @($v.peerings)) {
                if (-not $p) { continue }
                $pp = $p.properties
                $prows.Add([pscustomobject]@{
                        FranId = $v.id; Fran = $v.name; TillId = [string]$pp.remoteVirtualNetwork.id; Till = (Get-IdLeaf $pp.remoteVirtualNetwork.id)
                        Status = [string]$pp.peeringState; GatewayTransit = [bool]$pp.allowGatewayTransit; AnvandRemoteGateways = [bool]$pp.useRemoteGateways
                        ForwardedTraffic = [bool]$pp.allowForwardedTraffic; TillAdressrymd = (@($pp.remoteAddressSpace.addressPrefixes) -join ' ')
                    })
            }
        }
        & $save 'natverk-vnet.csv' $vrows
        & $save 'natverk-peerings.csv' $prows
        $counts['vnet'] = $vrows.Count; $counts['peerings'] = $prows.Count
    }
    catch { $Errors.Add("Virtuella nätverk: $($_.Exception.Message)") }

    # Nätverksnoder: brandväggar, gateways, ExpressRoute, Virtual WAN, Bastion, Application Gateway
    try {
        $q = "resources | where type in~ ('microsoft.network/azurefirewalls','microsoft.network/virtualnetworkgateways','microsoft.network/expressroutecircuits','microsoft.network/virtualwans','microsoft.network/virtualhubs','microsoft.network/bastionhosts','microsoft.network/applicationgateways') | project type, name, subscriptionId, resourceGroup, location, extra = tostring(coalesce(properties.gatewayType, sku.name, properties.sku.name)), subnetId = tostring(coalesce(properties.ipConfigurations[0].properties.subnet.id, properties.gatewayIPConfigurations[0].properties.subnet.id))"
        $nodes = Invoke-ResourceGraph $q $RootMg $SubscriptionIds
        $nrows = foreach ($n in $nodes) {
            $vid = if ($n.subnetId -and $n.subnetId -match '(?i)^(.*)/subnets/') { $Matches[1] } else { '' }
            [pscustomobject]@{ Typ = ([string]$n.type -replace '(?i)^microsoft\.network/', ''); Namn = $n.name; Prenumeration = $n.subscriptionId; Resursgrupp = $n.resourceGroup; Plats = $n.location; Extra = $n.extra; VnetId = $vid }
        }
        & $save 'natverk-noder.csv' $nrows
        $counts['noder'] = @($nrows).Count
    }
    catch { $Errors.Add("Nätverksnoder: $($_.Exception.Message)") }

    # Antal resurser per prenumeration (för trädet)
    try {
        $cnt = Invoke-ResourceGraph 'resources | summarize antal = count() by subscriptionId' $RootMg $SubscriptionIds
        & $save 'resurser-per-prenumeration.csv' @($cnt | ForEach-Object { [pscustomobject]@{ Prenumeration = $_.subscriptionId; Resurser = [int]$_.antal } })
    }
    catch { $Errors.Add("Resurser per prenumeration: $($_.Exception.Message)") }

    ($counts.GetEnumerator() | ForEach-Object { '{0} {1}' -f $_.Value, $_.Key }) -join ', '
}
