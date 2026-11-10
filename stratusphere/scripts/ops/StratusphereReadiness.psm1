# Checks behind Test-StratusphereReadiness.ps1. The Get-Ssux*Check functions take
# data already read from Azure and return results, so they are tested offline.
# Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE at the repo root). Not affiliated with the author's employer, with Liquidware or with Microsoft.

function Get-SsuxCheckResult {
  # One check result. FIXED means -Fix changed something; INFO records state; SKIP means an
  # input was missing. Category groups the report.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL', 'FIXED', 'INFO', 'SKIP')] [string] $Status,
    [Parameter(Mandatory)] [string] $Check,
    [Parameter(Mandatory)] [string] $Detail,
    [string] $Recommendation = '',
    [string] $Category = ''
  )
  [pscustomobject]@{ Category = $Category; Status = $Status; Check = $Check; Detail = $Detail; Recommendation = $Recommendation }
}

function Get-SsuxPlanCheck {
  # Is the chosen Marketplace plan offered in the region? Without one, list what is.
  [CmdletBinding()]
  param(
    [AllowEmptyCollection()] [string[]] $AvailablePlans = @(),
    [string] $Plan,
    [Parameter(Mandatory)] [string] $Location
  )
  $plans = @($AvailablePlans | Where-Object { $_ })
  if ($plans.Count -eq 0) {
    return Get-SsuxCheckResult FAIL 'marketplace-plan' "No Stratusphere plans are offered in $Location under this publisher and offer. Check the publisher and offer names, or try another region." -Category Marketplace
  }
  $list = $plans -join ', '
  if (-not $Plan) {
    return Get-SsuxCheckResult FAIL 'marketplace-plan' "Choose a plan (-HubPlan, -DatabasePlan, -CollectorPlan). Offered in ${Location}: $list" -Category Marketplace
  }
  if ($plans -notcontains $Plan) {
    return Get-SsuxCheckResult FAIL 'marketplace-plan' "Plan '$Plan' is not offered in $Location. Offered: $list" -Category Marketplace
  }
  Get-SsuxCheckResult PASS 'marketplace-plan' "Plan '$Plan' is offered in $Location" -Category Marketplace
}

function Get-SsuxImagePlanCheck {
  # A Marketplace image without a purchase plan must be deployed without a plan block,
  # and one with a plan must match it. appliance.bicep always sends a plan block.
  [CmdletBinding()]
  param(
    $PurchasePlan,
    [Parameter(Mandatory)] [string] $Version
  )
  if (-not $PurchasePlan) {
    return Get-SsuxCheckResult FAIL 'image-purchase-plan' "Image version $Version has no purchase plan, so the plan block in appliance.bicep would be rejected. Report this: the template needs a no-plan path." -Category Marketplace
  }
  Get-SsuxCheckResult PASS 'image-purchase-plan' "Image version $Version carries purchase plan '$($PurchasePlan.Name)'" -Category Marketplace
}

function Get-SsuxQuotaCheck {
  # vCPU quota for everything the deployment needs: each VM family, then the regional total.
  # When a family is short, names the families that already have room (a size change takes
  # one parameter; a quota request takes days).
  [CmdletBinding()]
  param(
    # Rows of Family and VCpus, one per appliance (or already summed).
    [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Need,
    [AllowEmptyCollection()] [object[]] $Usage = @()
  )
  function Get-Free($row) { [int]$row.Limit - [int]$row.CurrentValue }
  $total = 0
  foreach ($g in @($Need | Group-Object Family)) {
    $needed = [int]($g.Group | Measure-Object VCpus -Sum).Sum
    $total += $needed
    $row = @($Usage | Where-Object { $_.Name.Value -eq $g.Name }) | Select-Object -First 1
    if (-not $row) {
      Get-SsuxCheckResult WARN "quota-$($g.Name)" "No usage row for $($g.Name); could not check quota" -Recommendation 'Check Subscription > Usage + quotas in the portal.' -Category Capacity
      continue
    }
    $free = Get-Free $row
    if ($free -ge $needed) {
      Get-SsuxCheckResult PASS "quota-$($g.Name)" "$free of $($row.Limit) vCPUs free in $($g.Name), $needed needed" -Category Capacity
      continue
    }
    $zero = $(if ([int]$row.Limit -eq 0) { ' This family has no quota at all here, common on trial and Visual Studio subscriptions.' } else { '' })
    Get-SsuxCheckResult FAIL "quota-$($g.Name)" "$free of $($row.Limit) vCPUs free in $($g.Name), $needed needed.$zero" -Recommendation "Request at least $($needed - $free) more vCPUs for $($g.Name), or pick a size in a family with room." -Category Capacity
    $alt = @($Usage | Where-Object { $_.Name.Value -like '*Family' -and $_.Name.Value -ne $g.Name -and (Get-Free $_) -ge $needed } |
        Sort-Object { Get-Free $_ } -Descending | Select-Object -First 6 | ForEach-Object { '{0} ({1} free)' -f $_.Name.Value, (Get-Free $_) })
    if ($alt.Count -gt 0) {
      Get-SsuxCheckResult INFO 'quota-alternatives' "Families with $needed or more vCPUs free: $($alt -join '; ')" -Recommendation 'Pick a VM size in one of these families (-HubVmSize and friends) to avoid waiting on a quota request.' -Category Capacity
    }
  }
  $cores = @($Usage | Where-Object { $_.Name.Value -eq 'cores' }) | Select-Object -First 1
  if (-not $cores) {
    Get-SsuxCheckResult WARN 'quota-cores' 'No usage row for total regional vCPUs; could not check quota' -Category Capacity
  }
  elseif ((Get-Free $cores) -ge $total) {
    Get-SsuxCheckResult PASS 'quota-cores' "$(Get-Free $cores) of $($cores.Limit) regional vCPUs free, $total needed" -Category Capacity
  }
  else {
    Get-SsuxCheckResult FAIL 'quota-cores' "$(Get-Free $cores) of $($cores.Limit) regional vCPUs free, $total needed" -Recommendation 'Request an increase to Total Regional vCPUs.' -Category Capacity
  }
}

function Get-SsuxNetworkQuotaCheck {
  # The environment needs one NIC per appliance and two Standard public IPs (NAT Gateway, Bastion).
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [int] $Nics,
    [Parameter(Mandatory)] [int] $PublicIps,
    [AllowEmptyCollection()] [object[]] $Usage = @()
  )
  foreach ($item in @(@{ Name = 'NetworkInterfaces'; Need = $Nics }, @{ Name = 'PublicIPAddresses'; Need = $PublicIps })) {
    $row = @($Usage | Where-Object { $_.Name.Value -eq $item.Name }) | Select-Object -First 1
    if (-not $row) { Get-SsuxCheckResult INFO "quota-$($item.Name)" "No usage row for $($item.Name)" -Category Capacity; continue }
    $free = [int]$row.Limit - [int]$row.CurrentValue
    if ($free -ge $item.Need) { Get-SsuxCheckResult PASS "quota-$($item.Name)" "$free of $($row.Limit) free, $($item.Need) needed" -Category Capacity }
    else { Get-SsuxCheckResult FAIL "quota-$($item.Name)" "$free of $($row.Limit) free, $($item.Need) needed" -Recommendation "Request a $($item.Name) quota increase." -Category Capacity }
  }
}

function Get-SsuxRoleCoverageCheck {
  # The deployment creates a resource group and grants Key Vault Secrets User, so it needs
  # Owner, or Contributor plus a role that can write role assignments.
  [CmdletBinding()]
  param([AllowEmptyCollection()] [string[]] $RoleName = @(), [bool] $CouldRead = $true)
  if (-not $CouldRead) {
    return Get-SsuxCheckResult INFO 'deploy-role' 'Could not read your role assignments' -Recommendation 'Confirm you have Owner, or Contributor plus User Access Administrator, on the subscription.' -Category Identity
  }
  $grant = @('User Access Administrator', 'Role Based Access Control Administrator') | Where-Object { $RoleName -contains $_ }
  if ($RoleName -contains 'Owner') { return Get-SsuxCheckResult PASS 'deploy-role' 'Owner on the subscription' -Category Identity }
  if ($RoleName -contains 'Contributor' -and $grant) { return Get-SsuxCheckResult PASS 'deploy-role' "Contributor and $($grant -join ', ')" -Category Identity }
  if ($RoleName -contains 'Contributor') {
    return Get-SsuxCheckResult FAIL 'deploy-role' 'Contributor only: the deployment fails when it grants you read access to the Key Vault' -Recommendation 'Add User Access Administrator (or Role Based Access Control Administrator), or deploy as Owner.' -Category Identity
  }
  $list = $(if ($RoleName) { $RoleName -join ', ' } else { 'none' })
  Get-SsuxCheckResult FAIL 'deploy-role' "Roles on the subscription: $list" -Recommendation 'Deploying needs Owner, or Contributor plus User Access Administrator.' -Category Identity
}

function Get-SsuxPolicyCheck {
  # Built-in allowed-locations and allowed-VM-SKU policies compared with the plan, and a list
  # of other deny assignments, which most often stop a deployment halfway.
  [CmdletBinding()]
  param(
    # DisplayName, DefinitionId, AllowedLocations, AllowedSkus, IsDeny
    [AllowEmptyCollection()] [object[]] $Assignment = @(),
    [Parameter(Mandatory)] [string] $Location,
    [AllowEmptyCollection()] [string[]] $VmSize = @()
  )
  $locationDefs = 'e56962a6-4747-49cd-b67b-bf8b01975c4c', 'e765b5de-1225-4ba3-bd56-1ac6695af988'
  $skuDef = 'cccc23c7-8427-4f53-ad12-b6a63eb452b3'
  $checked = @()
  foreach ($a in $Assignment) {
    $def = ($a.DefinitionId -split '/')[-1]
    if ($locationDefs -contains $def) {
      $checked += $a.DisplayName
      $allowed = @($a.AllowedLocations)
      if ($allowed.Count -eq 0) { Get-SsuxCheckResult WARN 'policy-locations' "'$($a.DisplayName)' restricts locations; its list could not be read" -Category Policy }
      elseif ($allowed -contains $Location) { Get-SsuxCheckResult PASS 'policy-locations' "'$($a.DisplayName)' allows $Location" -Category Policy }
      else { Get-SsuxCheckResult FAIL 'policy-locations' "'$($a.DisplayName)' does not allow $Location (allows $($allowed -join ', '))" -Recommendation 'Pick an allowed region, or ask for an exemption on the assessment resource group.' -Category Policy }
    }
    elseif ($def -eq $skuDef) {
      $checked += $a.DisplayName
      $missing = @($VmSize | Where-Object { @($a.AllowedSkus) -notcontains $_ })
      if ($missing.Count -eq 0) { Get-SsuxCheckResult PASS 'policy-vm-sizes' "'$($a.DisplayName)' allows $($VmSize -join ', ')" -Category Policy }
      else { Get-SsuxCheckResult FAIL 'policy-vm-sizes' "'$($a.DisplayName)' does not allow $($missing -join ', ')" -Recommendation 'Pick allowed sizes for the appliances, or ask for an exemption.' -Category Policy }
    }
  }
  $deny = @($Assignment | Where-Object { $_.IsDeny -and $checked -notcontains $_.DisplayName } | ForEach-Object DisplayName)
  if ($deny.Count -gt 0) {
    Get-SsuxCheckResult WARN 'policy-deny' "$($deny.Count) other deny assignment(s): $(($deny | Select-Object -First 10) -join ', ')" -Recommendation 'Check them against the deployment: Marketplace images, public IPs (NAT Gateway, Bastion), required tags and Key Vault settings are common blockers. -Action Plan (what-if) shows most of them.' -Category Policy
  }
  elseif ($checked.Count -eq 0) {
    Get-SsuxCheckResult PASS 'policy-deny' 'No deny policies found' -Category Policy
  }
}

function Get-SsuxLockCheck {
  # ReadOnly blocks the deployment; CanNotDelete blocks only cleanup.
  [CmdletBinding()]
  param([AllowEmptyCollection()] [object[]] $Lock = @())
  $ro = @($Lock | Where-Object Level -eq 'ReadOnly')
  $nd = @($Lock | Where-Object Level -eq 'CanNotDelete')
  if ($ro.Count) { Get-SsuxCheckResult FAIL 'locks' "ReadOnly lock(s): $(($ro | ForEach-Object Name) -join ', ')" -Recommendation 'A ReadOnly lock on the subscription or the resource group blocks every write. Remove it for the deployment.' -Category Subscription }
  if ($nd.Count) { Get-SsuxCheckResult INFO 'locks' "CanNotDelete lock(s): $(($nd | ForEach-Object Name) -join ', '); cleanup will be blocked" -Category Subscription }
  if (-not $ro.Count -and -not $nd.Count) { Get-SsuxCheckResult PASS 'locks' 'No locks' -Category Subscription }
}

function ConvertTo-SsuxIpNumber([string] $Ip) {
  $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
  [uint32](([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3])
}

function Get-SsuxCidrRange {
  # First and last address of an IPv4 CIDR, as numbers. $null for anything else (tags, IPv6).
  [CmdletBinding()]
  param([string] $Cidr)
  if ($Cidr -notmatch '^(\d{1,3}(\.\d{1,3}){3})(/(\d{1,2}))?$') { return $null }
  $len = $(if ($Matches[4]) { [int]$Matches[4] } else { 32 })
  $start = ConvertTo-SsuxIpNumber $Matches[1]
  $size = [uint64][Math]::Pow(2, 32 - $len)
  $first = [uint64]([uint64]$start - ([uint64]$start % $size))
  [pscustomobject]@{ First = $first; Last = $first + $size - 1; Length = $len }
}

function Test-SsuxCidrOverlap {
  [CmdletBinding()]
  param([string] $A, [string] $B)
  $x = Get-SsuxCidrRange $A; $y = Get-SsuxCidrRange $B
  if (-not $x -or -not $y) { return $false }
  $x.First -le $y.Last -and $y.First -le $x.Last
}

function Get-SsuxAddressOverlapCheck {
  # The assessment VNet must not overlap the VNet it peers with (Azure refuses the peering),
  # and should not overlap anything else the endpoints route to.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $AddressPrefix,
    # Source, Prefix, Blocking (true for the peer VNet itself)
    [AllowEmptyCollection()] [object[]] $Other = @()
  )
  $hits = @($Other | Where-Object { Test-SsuxCidrOverlap $AddressPrefix $_.Prefix })
  foreach ($h in $hits) {
    $status = $(if ($h.Blocking) { 'FAIL' } else { 'WARN' })
    Get-SsuxCheckResult $status 'address-space' "$AddressPrefix overlaps $($h.Prefix) ($($h.Source))" -Recommendation 'Pick a free range for the assessment VNet (addressPrefix and the subnet prefixes in the parameter file).' -Category Network
  }
  if ($hits.Count -eq 0) {
    $n = @($Other | ForEach-Object Prefix | Sort-Object -Unique).Count
    Get-SsuxCheckResult PASS 'address-space' "$AddressPrefix overlaps none of the $n address range(s) checked" -Category Network
  }
}

function Test-SsuxPortCovered([string[]] $Range, [int] $Port) {
  foreach ($r in $Range) {
    if ($r -eq '*' -or $r -eq "$Port") { return $true }
    if ($r -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le $Port -and $Port -le [int]$Matches[2]) { return $true }
  }
  $false
}

function Get-SsuxEndpointNsgCheck {
  # Would the endpoint subnet's NSG let a Connector ID Key call back to the Hub on TCP 443?
  # Rules are evaluated like Azure does: outbound, by priority, first match wins.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $SubnetName,
    # Name, Priority, Direction, Access, Protocol, DestinationAddressPrefix (array), DestinationPortRange (array)
    [AllowEmptyCollection()] [object[]] $Rule = @(),
    [Parameter(Mandatory)] [string] $HubIp,
    [int] $Port = 443
  )
  if (@($Rule).Count -eq 0) { return Get-SsuxCheckResult PASS "nsg-egress $SubnetName" 'No NSG on the subnet' -Category Endpoints }
  $hub = ConvertTo-SsuxIpNumber $HubIp
  $unknown = @()
  foreach ($r in @($Rule | Where-Object Direction -eq 'Outbound' | Sort-Object { [int]$_.Priority })) {
    if ($r.Protocol -notin '*', 'Tcp') { continue }
    if (-not (Test-SsuxPortCovered @($r.DestinationPortRange) $Port)) { continue }
    $match = $false
    foreach ($d in @($r.DestinationAddressPrefix)) {
      if ($d -in '*', 'VirtualNetwork') { $match = $true; break }
      $range = Get-SsuxCidrRange $d
      if ($range) { if ($range.First -le $hub -and $hub -le $range.Last) { $match = $true; break } }
      elseif ($d -ne 'Internet') { $unknown += "$($r.Name) ($d)" }
    }
    if (-not $match) { continue }
    if ($r.Access -eq 'Allow') { return Get-SsuxCheckResult PASS "nsg-egress $SubnetName" "Rule '$($r.Name)' allows TCP $Port to $HubIp" -Category Endpoints }
    return Get-SsuxCheckResult FAIL "nsg-egress $SubnetName" "Rule '$($r.Name)' (priority $($r.Priority)) denies TCP $Port to $HubIp" -Recommendation "Add an outbound allow for TCP $Port to $HubIp (or the assessment VNet) above it, or the Connector ID Keys can't call back." -Category Endpoints
  }
  $note = $(if ($unknown) { " Rules with service tags were not evaluated: $($unknown -join ', ')." } else { '' })
  Get-SsuxCheckResult WARN "nsg-egress $SubnetName" "No outbound rule matched TCP $Port to $HubIp.$note" -Recommendation 'Include the default rules in the input, or confirm the path by hand.' -Category Endpoints
}

function Get-SsuxEndpointRouteCheck {
  # Where callbacks from an endpoint subnet to the Hub go. With direct peering, Azure adds a
  # system route for the assessment VNet; a user route wins only if it is at least as specific.
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $SubnetName,
    # Name, AddressPrefix, NextHopType, NextHopIpAddress
    [AllowEmptyCollection()] [object[]] $Route = @(),
    [Parameter(Mandatory)] [string] $HubIp,
    [Parameter(Mandatory)] [string] $AssessmentPrefix,
    [bool] $DirectlyPeered
  )
  $hub = ConvertTo-SsuxIpNumber $HubIp
  $minLen = $(if ($DirectlyPeered) { (Get-SsuxCidrRange $AssessmentPrefix).Length } else { 0 })
  $best = @($Route | ForEach-Object {
      $r = Get-SsuxCidrRange $_.AddressPrefix
      if ($r -and $r.First -le $hub -and $hub -le $r.Last -and $r.Length -ge $minLen) { [pscustomobject]@{ Route = $_; Length = $r.Length } }
    } | Sort-Object Length -Descending) | Select-Object -First 1
  if (-not $best) {
    if ($DirectlyPeered) { return Get-SsuxCheckResult PASS "route $SubnetName" "Callbacks to $HubIp take the peering" -Category Endpoints }
    return Get-SsuxCheckResult FAIL "route $SubnetName" "No route to ${HubIp}: the endpoint VNet is not peered with the assessment VNet and no user route covers it" -Recommendation 'Peer the assessment VNet with this VNet (-PeerVnetId), or route the range through your hub.' -Category Endpoints
  }
  $r = $best.Route
  switch ($r.NextHopType) {
    'VirtualAppliance' { Get-SsuxCheckResult WARN "route $SubnetName" "Route '$($r.Name)' ($($r.AddressPrefix)) sends callbacks to $HubIp through the appliance at $($r.NextHopIpAddress)" -Recommendation "Allow TCP 443 from the endpoints to $HubIp on that firewall." -Category Endpoints }
    'VirtualNetworkGateway' { Get-SsuxCheckResult WARN "route $SubnetName" "Route '$($r.Name)' sends callbacks to $HubIp to the VPN/ExpressRoute gateway" -Recommendation 'Confirm the gateway path reaches the assessment VNet.' -Category Endpoints }
    'None' { Get-SsuxCheckResult FAIL "route $SubnetName" "Route '$($r.Name)' ($($r.AddressPrefix)) drops traffic to $HubIp" -Recommendation 'Remove or narrow that route.' -Category Endpoints }
    'Internet' { Get-SsuxCheckResult FAIL "route $SubnetName" "Route '$($r.Name)' sends traffic for $HubIp to the internet" -Recommendation 'Remove or narrow that route.' -Category Endpoints }
    default { Get-SsuxCheckResult PASS "route $SubnetName" "Route '$($r.Name)' ($($r.NextHopType)) reaches $HubIp" -Category Endpoints }
  }
}

function Get-SsuxEndpointSizingCheck {
  # Liquidware advises a Database appliance above 1,000 Connector ID Keys.
  [CmdletBinding()]
  param([int] $EndpointCount = 0, [AllowEmptyCollection()] [string[]] $Role = @(), [string] $Source = '')
  if ($EndpointCount -le 0) {
    return Get-SsuxCheckResult SKIP 'endpoint-count' 'Number of endpoints unknown' -Recommendation 'Pass -EndpointCount, -HostPoolName or -AvdCurrentStatePath to size the appliances.' -Category Endpoints
  }
  $from = $(if ($Source) { " ($Source)" } else { '' })
  if ($EndpointCount -gt 1000 -and $Role -notcontains 'Database') {
    return Get-SsuxCheckResult WARN 'endpoint-count' "$EndpointCount endpoints$from; Liquidware advises a Database appliance above 1,000" -Recommendation 'Add -Role Database (and -DatabasePlan).' -Category Endpoints
  }
  Get-SsuxCheckResult PASS 'endpoint-count' "$EndpointCount endpoints$from; the roles planned fit" -Category Endpoints
}

function Get-SsuxAvdCurrentStateSummary {
  # Reads what a preflight needs from an avd-current-state collector package
  # (github.com/avd-ops/avd-current-state): session hosts and VNet address spaces.
  [CmdletBinding()]
  param(
    [AllowEmptyCollection()] [object[]] $SessionHost = @(),
    # VNet rows: Name, AddressSpace ("10.0.0.0/16, 10.1.0.0/16")
    [AllowEmptyCollection()] [object[]] $VirtualNetwork = @()
  )
  $prefixes = foreach ($v in $VirtualNetwork) {
    foreach ($p in ("$($v.AddressSpace)" -split '[,; ]+' | Where-Object { $_ })) { [pscustomobject]@{ Source = "VNet $($v.Name)"; Prefix = $p; Blocking = $false } }
  }
  [pscustomobject]@{
    EndpointCount = @($SessionHost).Count
    HostPools     = @($SessionHost | ForEach-Object HostPool | Where-Object { $_ } | Sort-Object -Unique)
    Prefixes      = @($prefixes)
  }
}

function Get-SsuxVmSizeCheck {
  # Is the size offered in the region and not restricted for this subscription?
  [CmdletBinding()]
  param(
    $Sku,
    [Parameter(Mandatory)] [string] $VmSize,
    [Parameter(Mandatory)] [string] $Location
  )
  if (-not $Sku) {
    return Get-SsuxCheckResult FAIL 'vm-size' "$VmSize is not offered in $Location" -Category Capacity
  }
  $blocked = @($Sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' -and $_.Type -eq 'Location' })
  if ($blocked.Count -gt 0) {
    return Get-SsuxCheckResult FAIL 'vm-size' "$VmSize is restricted for this subscription in $Location" -Category Capacity
  }
  if ($Sku.PSObject.Properties['Capabilities'] -and $Sku.Capabilities) {
    $genCap = @($Sku.Capabilities | Where-Object Name -eq 'HyperVGenerations') | Select-Object -First 1
    if ($genCap -and $genCap.Value -notmatch '(^|,)V1(,|$)') {
      return Get-SsuxCheckResult FAIL 'vm-size' "$VmSize supports Hyper-V generation '$($genCap.Value)' only; Stratusphere Marketplace images require V1 (Gen1)" -Recommendation 'Pick a Gen1-capable VM size such as Standard_D4s_v4 or Standard_D4as_v4.' -Category Capacity
    }
  }
  Get-SsuxCheckResult PASS 'vm-size' "$VmSize is available in $Location" -Category Capacity
}

Export-ModuleMember -Function Get-SsuxCheckResult, Get-SsuxPlanCheck, Get-SsuxImagePlanCheck, Get-SsuxQuotaCheck, Get-SsuxVmSizeCheck,
Get-SsuxNetworkQuotaCheck, Get-SsuxRoleCoverageCheck, Get-SsuxPolicyCheck, Get-SsuxLockCheck, Get-SsuxCidrRange, Test-SsuxCidrOverlap,
Get-SsuxAddressOverlapCheck, Get-SsuxEndpointNsgCheck, Get-SsuxEndpointRouteCheck, Get-SsuxEndpointSizingCheck, Get-SsuxAvdCurrentStateSummary
