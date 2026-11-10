<#
.SYNOPSIS
  Preflight for the Stratusphere UX assessment environment: is this subscription, region and
  network ready for the appliances, and will the Connector ID Keys be able to call back?
  Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE at the repo root). Not affiliated with the author's employer, with Liquidware or with Microsoft.

.DESCRIPTION
  Read-only unless -Fix. Reports PASS, WARN, FAIL, INFO or SKIP per check, by category:

    Tooling       PowerShell, Az modules, Bicep CLI (Deploy-Stratusphere.ps1 needs it)
    Identity      subscription state; Owner, or Contributor plus User Access Administrator
                  (the deployment grants you read access to the Key Vault)
    Providers     Compute, Network, KeyVault, MarketplaceOrdering
    Marketplace   each role's plan offered in the region, its image purchase plan, its terms
    Capacity      each role's VM size offered and not restricted; vCPU quota per family and
                  regional, summed over every appliance, with families that have room when one
                  is short; network interface and public IP quota
    Policy        allowed locations and allowed VM sizes against the plan; other deny policies
    Subscription  ReadOnly locks; an existing environment (roles found); a soft-deleted Key Vault
    Network       the assessment address space against the peer VNet, its peers and the AVD
                  estate; the peer VNet's region and DNS
    Endpoints     for each subnet the Connector ID Keys run in: the NSG lets TCP 443 out to the
                  Hub, and the route to the Hub (peering, firewall, black hole); the number of
                  endpoints against Liquidware's Database advice (above 1,000 keys)

  Endpoints come from -EndpointSubnetId, from an AVD host pool (-HostPoolName, the session
  hosts' subnets and count), and from an avd-current-state collector package
  (-AvdCurrentStatePath, github.com/avd-ops/avd-current-state: session host count and
  every VNet's address space).

  Everything it read is captured with the results in output/preflight-<time>/: report.md,
  results.csv and .json, current-state.json, manifest.json. That folder holds machine names;
  it is git-ignored.

  -Fix registers providers, accepts the Marketplace terms for the plans given and installs
  the Bicep CLI. Nothing else is changed.

  Every parameter can come from -ConfigPath (a JSON file; keys starting with _ are comments).
  Explicit parameters win. Exit code 0: no FAIL. 1: a FAIL. 2: could not run.

.EXAMPLE
  ./scripts/ops/Test-StratusphereReadiness.ps1 -Location eastus2
.EXAMPLE
  ./scripts/ops/Test-StratusphereReadiness.ps1 -Location eastus2 -HubPlan <plan> -Fix `
    -PeerVnetId <spoke-vnet-id> -HostPoolName hp-avdlz-dev -HostPoolResourceGroup rg-avdlz-dev-avd
.EXAMPLE
  ./scripts/ops/Test-StratusphereReadiness.ps1 -ConfigPath ./preflight.json -AvdCurrentStatePath ~/clouddrive/avd-current-state-20261015T101500.zip
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $Location = '',
  [ValidateSet('Hub', 'Database', 'Collector')] [string[]] $Role = @('Hub'),
  [Alias('Plan')] [string] $HubPlan = '',
  [string] $DatabasePlan = '',
  [string] $CollectorPlan = '',
  [ValidateRange(1, 4)] [int] $CollectorCount = 1,
  [Alias('VmSize')] [string] $HubVmSize = 'Standard_D4s_v5',
  [string] $DatabaseVmSize = 'Standard_D4s_v5',
  [string] $CollectorVmSize = 'Standard_D2s_v5',
  [string] $NamePrefix = 'ssux',
  [ValidateSet('', 'dev', 'test', 'prod')] [string] $Environment = '',
  [string] $AddressPrefix = '10.60.0.0/24',
  [string] $PeerVnetId = '',
  [string[]] $EndpointSubnetId = @(),
  [string] $HostPoolName = '',
  [string] $HostPoolResourceGroup = '',
  [string] $AvdCurrentStatePath = '',
  [int] $EndpointCount = 0,
  [switch] $NoBastion,
  [string] $Publisher = 'liquidware',
  [string] $Offer = 'stratusphere',
  [string] $ConfigPath = '',
  [string] $OutputPath = '',
  [switch] $Fix,
  [ValidateSet('Bicep', 'Terraform')] [string] $Engine = 'Bicep'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $PSScriptRoot 'StratusphereReadiness.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StratusphereAppliance.psm1') -Force

# ---------- Inputs ----------
if ($ConfigPath) {
  $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
  foreach ($p in $config.PSObject.Properties) {
    if ($p.Name -like '_*' -or $PSBoundParameters.ContainsKey($p.Name)) { continue }
    if (-not $MyInvocation.MyCommand.Parameters.ContainsKey($p.Name)) { Write-Host "Ignoring unknown config key '$($p.Name)'"; continue }
    Set-Variable -Name $p.Name -Value $p.Value
  }
}
if ($Role -notcontains 'Hub') { $Role = @('Hub') + $Role }
if (-not $Location) { Write-Host 'Pass -Location (or Location in -ConfigPath).'; Write-Host 'RESULT FAIL could not run'; exit 2 }
$argErrors = @(Get-SsuxApplianceArgumentError -Action Plan -Role $Role -NamePrefix $NamePrefix -PeerVnetId $PeerVnetId -Plan @{ Hub = $HubPlan; Database = $DatabasePlan; Collector = $CollectorPlan })
if (-not (Get-SsuxCidrRange $AddressPrefix)) { $argErrors += "AddressPrefix '$AddressPrefix' is not an IPv4 CIDR." }
foreach ($s in $EndpointSubnetId) { if ($s -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$') { $argErrors += "Not a subnet resource ID: '$s'" } }
if ($argErrors.Count) { $argErrors | ForEach-Object { Write-Host "FAIL   $_" }; Write-Host 'RESULT FAIL could not run'; exit 2 }

$plans = [ordered]@{ Hub = $HubPlan }
if ($Role -contains 'Database') { $plans.Database = $DatabasePlan }
if ($Role -contains 'Collector') { $plans.Collector = $CollectorPlan }
$sizes = @{ Hub = $HubVmSize; Database = $DatabaseVmSize; Collector = $CollectorVmSize }
$counts = @{ Hub = 1; Database = 1; Collector = $CollectorCount }
$hubIp = (Get-SsuxApplianceDefault).Ip.Hub
$rgName = Get-SsuxResourceGroupName -NamePrefix $NamePrefix -Environment $Environment

$results = [System.Collections.Generic.List[object]]::new()
$state = [ordered]@{ capturedAt = (Get-Date).ToUniversalTime().ToString('o') }
$section = ''
function Add-Result($r) {
  foreach ($x in @($r)) {
    if (-not $x.Category) { $x.Category = $section }
    $results.Add($x)
    Write-Host ("  {0,-6} {1,-34} {2}" -f $x.Status, $x.Check, $x.Detail)
    if ($x.Recommendation -and $x.Status -in 'FAIL', 'WARN', 'SKIP') { Write-Host "         -> $($x.Recommendation)" }
  }
}
function Write-Section([string] $Name) { $script:section = $Name; Write-Host ''; Write-Host $Name }
function Get-Prop($Object, [string[]] $Path) {
  # Az modules move properties between versions (Properties.X vs X); take the first that exists.
  foreach ($p in $Path) {
    $v = $Object
    foreach ($part in ($p -split '\.')) {
      if ($null -eq $v) { break }
      $prop = $v.PSObject.Properties[$part]
      $v = $(if ($prop) { $prop.Value } else { $null })
    }
    if ($null -ne $v) { return $v }
  }
}

# ---------- Tooling ----------
Write-Section 'Tooling'
Add-Result (Get-SsuxCheckResult INFO 'powershell' "PowerShell $($PSVersionTable.PSVersion)")
$azModules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.KeyVault', 'Az.MarketplaceOrdering', 'Az.PrivateDns')
if ($HostPoolName) { $azModules += 'Az.DesktopVirtualization' }
foreach ($m in $azModules) {
  if (-not (Get-Module -ListAvailable -Name $m)) {
    Write-Host "  Installing $m from the PowerShell Gallery ..."
    Install-Module $m -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $m
}
if (-not (Get-Command bicep -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $HOME '.azure/bin/bicep'))) {
  $env:PATH = (Join-Path $HOME '.azure/bin') + [IO.Path]::PathSeparator + $env:PATH
}
if (Get-Command bicep -ErrorAction SilentlyContinue) {
  Add-Result (Get-SsuxCheckResult PASS 'bicep' 'Bicep CLI on PATH')
}
elseif ($Fix -and (Get-Command az -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess('bicep', 'az bicep install')) {
  az bicep install | Out-Null
  $env:PATH = (Join-Path $HOME '.azure/bin') + [IO.Path]::PathSeparator + $env:PATH
  Add-Result (Get-SsuxCheckResult FIXED 'bicep' 'Installed Bicep CLI via az bicep install')
}
else {
  Add-Result (Get-SsuxCheckResult WARN 'bicep' 'Bicep CLI not on PATH (Deploy-Stratusphere.ps1 installs it automatically)' -Recommendation 'Run with -Fix, or: az bicep install')
}

# ---------- Identity ----------
Write-Section 'Identity'
$context = Get-AzContext
if (-not $context) { Write-Host '  Not signed in. Run Connect-AzAccount.'; Write-Host 'RESULT FAIL could not run'; exit 2 }
$sub = Get-AzSubscription -SubscriptionId $context.Subscription.Id
$state.subscription = [ordered]@{ id = $sub.Id; name = $sub.Name; state = $sub.State; tenantId = $sub.TenantId; account = $context.Account.Id }
if ($sub.State -eq 'Enabled') { Add-Result (Get-SsuxCheckResult PASS 'subscription' "$($sub.Name) is enabled") }
else { Add-Result (Get-SsuxCheckResult FAIL 'subscription' "$($sub.Name) is $($sub.State)" -Recommendation 'Switch to an enabled subscription with Set-AzContext.') }

try {
  $roles = @(Get-AzRoleAssignment -SignInName $context.Account.Id -Scope "/subscriptions/$($sub.Id)" -ErrorAction Stop | ForEach-Object RoleDefinitionName | Sort-Object -Unique)
  $state.roles = $roles
  Add-Result (Get-SsuxRoleCheck -Role $roles)
}
catch { Add-Result (Get-SsuxCheckResult SKIP 'deploy-role' "Could not read role assignments ($($_.Exception.Message))" -Recommendation 'Owner, or Contributor plus User Access Administrator, is needed.') }

# ---------- Providers ----------
Write-Section 'Providers'
foreach ($ns in 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.MarketplaceOrdering') {
  $st = (Get-AzResourceProvider -ProviderNamespace $ns | Select-Object -First 1).RegistrationState
  if ($st -eq 'Registered') { Add-Result (Get-SsuxCheckResult PASS 'provider' "$ns registered") }
  elseif ($Fix -and $PSCmdlet.ShouldProcess($ns, 'Register resource provider')) {
    Register-AzResourceProvider -ProviderNamespace $ns | Out-Null
    Add-Result (Get-SsuxCheckResult FIXED 'provider' "$ns registration started")
  }
  else { Add-Result (Get-SsuxCheckResult FAIL 'provider' "$ns is $st" -Recommendation "Run with -Fix, or: Register-AzResourceProvider -ProviderNamespace $ns") }
}

# ---------- Marketplace ----------
Write-Section 'Marketplace'
$offered = @()
try { $offered = @(Get-AzVMImageSku -Location $Location -PublisherName $Publisher -Offer $Offer | ForEach-Object Skus) }
catch { Add-Result (Get-SsuxCheckResult WARN 'marketplace-skus' "Could not list plans for $Publisher/$Offer in ${Location}: $($_.Exception.Message)") }
$state.marketplace = [ordered]@{ publisher = $Publisher; offer = $Offer; offeredPlans = $offered; roles = [ordered]@{} }

foreach ($r in $plans.Keys) {
  Write-Host "  $r"
  $plan = $plans[$r]
  $planCheck = Get-SsuxPlanCheck -AvailablePlans $offered -Plan $plan -Location $Location -Check "plan $($r.ToLower())"
  Add-Result $planCheck
  if ($planCheck.Status -ne 'PASS') { continue }

  try {
    $ver = @(Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer -Skus $plan | Sort-Object Version -Descending | Select-Object -First 1)
    if (-not $ver) { Add-Result (Get-SsuxCheckResult FAIL "image $($r.ToLower())" "No image versions under plan '$plan' in $Location"); continue }
    $detail = Get-AzVMImage -Location $Location -PublisherName $Publisher -Offer $Offer -Skus $plan -Version $ver[0].Version
    $pp = Get-Prop $detail 'PurchasePlan.Name', 'Plan.Name'
    Add-Result (Get-SsuxImagePlanCheck -Plan $plan -Version $ver[0].Version -PurchasePlanName "$pp")
    $state.marketplace.roles[$r] = [ordered]@{ plan = $plan; latestVersion = $ver[0].Version; purchasePlan = "$pp" }
  }
  catch { Add-Result (Get-SsuxCheckResult WARN "image $($r.ToLower())" "Could not inspect image for '$plan': $($_.Exception.Message)") }

  try {
    $terms = Get-AzMarketplaceTerms -Publisher $Publisher -Product $Offer -Name $plan -OfferType 'virtualmachine'
    if ($terms.Accepted) { Add-Result (Get-SsuxCheckResult PASS 'marketplace-terms' "Accepted for $plan") }
    elseif ($Fix -and $PSCmdlet.ShouldProcess("$Publisher/$Offer/$plan", 'Accept Marketplace terms')) {
      $terms | Set-AzMarketplaceTerms -Accept | Out-Null
      Add-Result (Get-SsuxCheckResult FIXED 'marketplace-terms' "Accepted for $plan")
    }
    else { Add-Result (Get-SsuxCheckResult FAIL 'marketplace-terms' "Not accepted for $plan" -Recommendation 'Run with -Fix; Deploy-Stratusphere.ps1 also accepts them.') }
  }
  catch { Add-Result (Get-SsuxCheckResult WARN 'marketplace-terms' "Could not check terms for '$plan': $($_.Exception.Message)") }
}

# ---------- Capacity ----------
Write-Section 'Capacity'
$skus = @(Get-AzComputeResourceSku -Location $Location | Where-Object ResourceType -eq 'virtualMachines')
$need = @()
foreach ($r in $plans.Keys) {
  $size = $sizes[$r]
  $hit = $skus | Where-Object Name -eq $size | Select-Object -First 1
  $zones = @(); $rest = @(); $vcpus = 4; $family = ''
  if ($hit) {
    $zones = @($hit.LocationInfo | ForEach-Object Zones | Where-Object { $_ })
    $rest = @($hit.Restrictions | ForEach-Object { if ($_.Type) { "$($_.Type) ($($_.ReasonCode))" } else { "$($_.ReasonCode)" } })
    $family = $hit.Family
    $cap = $hit.Capabilities | Where-Object Name -eq 'vCPUs' | Select-Object -First 1
    if ($cap) { $vcpus = [int]$cap.Value }
  }
  Add-Result (Get-SsuxSkuCheck -VmSize $size -Found ([bool]$hit) -Restriction $rest -Zone $zones -Location $Location -Check "vm-size $($r.ToLower())")
  for ($i = 0; $i -lt $counts[$r]; $i++) { $need += [pscustomobject]@{ Role = $r; Size = $size; Family = $family; Vcpus = $vcpus } }
}
$usage = @(Get-AzVMUsage -Location $Location) + @(Get-AzNetworkUsage -Location $Location) | ForEach-Object {
  [pscustomobject]@{ Name = "$(Get-Prop $_ 'Name.Value', 'ResourceType')"; Localized = "$(Get-Prop $_ 'Name.LocalizedValue', 'Name')"; Current = [int]$_.CurrentValue; Limit = [int]$_.Limit }
}
$state.usage = $usage
Add-Result (Get-SsuxQuotaCheck -Appliance $need -Usage $usage -DeployBastion:(-not $NoBastion))

# ---------- Policy ----------
Write-Section 'Policy'
try {
  $rows = @()
  $assignments = @(Get-AzPolicyAssignment -Scope "/subscriptions/$($sub.Id)")
  $inspected = 0
  foreach ($a in $assignments) {
    $defId = [string](Get-Prop $a 'PolicyDefinitionId', 'Properties.PolicyDefinitionId')
    $params = Get-Prop $a 'Parameter', 'Properties.Parameters'
    $isDeny = $false
    if ($defId -like '*/policyDefinitions/*' -and $inspected -lt 60) {
      $inspected++
      try {
        $def = Get-AzPolicyDefinition -Id $defId
        $effect = [string](Get-Prop $def 'PolicyRule.then.effect', 'Properties.PolicyRule.then.effect')
        if ($effect -match "parameters\('(\w+)'\)") {
          $name = $Matches[1]
          $effect = [string]$(if ($params.$name) { $params.$name.value } else { Get-Prop $def "Parameter.$name.defaultValue", "Properties.Parameters.$name.defaultValue" })
        }
        $isDeny = $effect -match 'deny'
      }
      catch { Write-Verbose $_.Exception.Message }
    }
    $rows += [pscustomobject]@{
      DisplayName      = [string](Get-Prop $a 'DisplayName', 'Properties.DisplayName', 'Name')
      DefinitionId     = $defId
      AllowedLocations = @($params.listOfAllowedLocations.value | Where-Object { $_ })
      AllowedSkus      = @($params.listOfAllowedSKUs.value | Where-Object { $_ })
      IsDeny           = $isDeny
    }
  }
  $state.policyAssignments = $rows
  Add-Result (Get-SsuxPolicyCheck -Assignment $rows -Location $Location -VmSize @($need | ForEach-Object Size | Sort-Object -Unique))
  if (@($rows | Where-Object { $_.DefinitionId -like '*/policySetDefinitions/*' }).Count) {
    Add-Result (Get-SsuxCheckResult INFO 'policy-initiatives' "$(@($rows | Where-Object { $_.DefinitionId -like '*/policySetDefinitions/*' }).Count) initiative(s) assigned; their deny effects are not expanded" -Recommendation 'Run Deploy-Stratusphere.ps1 -Action Plan (what-if) to surface them.')
  }
}
catch { Add-Result (Get-SsuxCheckResult SKIP 'policy' "Could not read policy assignments: $($_.Exception.Message)") }

# ---------- Subscription state ----------
Write-Section 'Subscription'
$locks = @(Get-AzResourceLock -ErrorAction SilentlyContinue | Where-Object {
    $_.ResourceId -match '^/subscriptions/[^/]+/providers/Microsoft\.Authorization/locks/' -or $_.ResourceGroupName -eq $rgName })
Add-Result (Get-SsuxLockCheck -Lock @($locks | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Level = "$(Get-Prop $_ 'Properties.level', 'Properties.Level')" } }))
$state.locks = @($locks | Select-Object Name, ResourceGroupName, ResourceId)
$existing = @()
if (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue) {
  $existing = @(Get-AzVM -ResourceGroupName $rgName | ForEach-Object {
      $tag = $(if ($_.Tags) { [string]$_.Tags['stratusphere-role'] } else { '' })
      $rn = Get-SsuxApplianceRole -Tag $tag
      if ($rn) { [pscustomobject]@{ Role = $rn; Name = $_.Name; PlanName = $(if ($_.Plan) { $_.Plan.Name } else { '' }); VmSize = $_.HardwareProfile.VmSize } }
    })
  $found = $(if ($existing) { ($existing | ForEach-Object { "$($_.Role) $($_.Name)" }) -join ', ' } else { 'no appliances' })
  Add-Result (Get-SsuxCheckResult INFO 'environment' "$rgName exists with $found; Deploy updates it in place" -Recommendation 'Deploy-Stratusphere.ps1 -Action Check reports its health.')
}
else { Add-Result (Get-SsuxCheckResult PASS 'environment' "$rgName does not exist yet") }
$state.existingAppliances = $existing
$removed = @(Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue | Where-Object { $_.VaultName -like "kv-$NamePrefix-ss-*" })
if ($removed) { Add-Result (Get-SsuxCheckResult INFO 'key-vault' "$($removed[0].VaultName) is soft-deleted; Deploy recovers it with its password") }

# ---------- Network ----------
Write-Section 'Network'
$state.network = [ordered]@{ assessmentPrefix = $AddressPrefix; hubIp = $hubIp }
$other = @()
$peerVnet = $null
if ($PeerVnetId) {
  $parts = $PeerVnetId -split '/'
  $peerVnet = Get-AzVirtualNetwork -ResourceGroupName $parts[4] -Name $parts[8] -ErrorAction SilentlyContinue
  if (-not $peerVnet) {
    Add-Result (Get-SsuxCheckResult FAIL 'peer-vnet' "$($parts[8]) not found (or no read access)" -Recommendation 'Check -PeerVnetId; the deployment also needs write access to it for the peering.')
  }
  else {
    Add-Result (Get-SsuxCheckResult PASS 'peer-vnet' "$($peerVnet.Name) in $($peerVnet.Location), $(@($peerVnet.VirtualNetworkPeerings).Count) peering(s)")
    if ($peerVnet.Location -ne $Location) { Add-Result (Get-SsuxCheckResult INFO 'peer-region' "$($peerVnet.Name) is in $($peerVnet.Location): global peering, billed per GB both ways") }
    $dns = @($peerVnet.DhcpOptions.DnsServers)
    if ($dns.Count) { Add-Result (Get-SsuxCheckResult INFO 'dns' "$($peerVnet.Name) uses custom DNS ($($dns -join ', '))" -Recommendation "Add an A record for the Hub ($hubIp) if the Connector ID Keys should use a name.") }
    else { Add-Result (Get-SsuxCheckResult INFO 'dns' "$($peerVnet.Name) uses Azure DNS; the Connector ID Keys can use the Hub's IP ($hubIp)") }
    foreach ($p in @($peerVnet.AddressSpace.AddressPrefixes)) { $other += [pscustomobject]@{ Source = "peer VNet $($peerVnet.Name)"; Prefix = $p; Blocking = $true } }
    foreach ($pe in @($peerVnet.VirtualNetworkPeerings)) {
      if ($pe.RemoteVirtualNetwork.Id -like "*/virtualNetworks/vnet-$NamePrefix-stratusphere") { continue }
      foreach ($p in @($pe.RemoteVirtualNetworkAddressSpace.AddressPrefixes)) { $other += [pscustomobject]@{ Source = "VNet peered with $($peerVnet.Name) ($(($pe.RemoteVirtualNetwork.Id -split '/')[-1]))"; Prefix = $p; Blocking = $false } }
    }
    $state.network.peerVnet = [ordered]@{
      id = $peerVnet.Id; location = $peerVnet.Location; addressSpace = @($peerVnet.AddressSpace.AddressPrefixes); dnsServers = $dns
      peerings = @($peerVnet.VirtualNetworkPeerings | ForEach-Object { [ordered]@{ name = $_.Name; remote = $_.RemoteVirtualNetwork.Id; state = "$($_.PeeringState)"; useRemoteGateways = $_.UseRemoteGateways } })
    }
  }
}
else { Add-Result (Get-SsuxCheckResult INFO 'peer-vnet' 'No -PeerVnetId: the assessment VNet will not be peered' -Recommendation 'Pass the VNet the endpoints are on (for example an avd-landing-zone spoke), or route to 10.60.0.0/24 yourself.') }

$avd = $null
if ($AvdCurrentStatePath) {
  $root = $AvdCurrentStatePath
  if ($root -like '*.zip') {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ssux-acs-" + [guid]::NewGuid())
    Expand-Archive -Path $AvdCurrentStatePath -DestinationPath $root
  }
  function Read-Dataset([string] $Name) { @(Get-ChildItem $root -Recurse -Filter "$Name.json" | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | ForEach-Object { $_ }) }
  $avd = Get-SsuxAvdCurrentStateSummary -SessionHost (Read-Dataset 'avd-session-hosts') -VirtualNetwork (Read-Dataset 'virtual-networks')
  Add-Result (Get-SsuxCheckResult INFO 'avd-current-state' "Package: $($avd.EndpointCount) session host(s) in $($avd.HostPools.Count) host pool(s), $($avd.Prefixes.Count) VNet address range(s)")
  $other += $avd.Prefixes
  $state.avdCurrentState = [ordered]@{ path = $AvdCurrentStatePath; sessionHosts = $avd.EndpointCount; hostPools = $avd.HostPools }
}

# ---------- Endpoints ----------
Write-Section 'Endpoints'
$subnetIds = @($EndpointSubnetId)
$poolCount = 0
if ($HostPoolName) {
  $hosts = @(Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $HostPoolResourceGroup)
  $poolCount = $hosts.Count
  foreach ($h in ($hosts | Select-Object -First 200)) {
    if (-not $h.ResourceId) { continue }
    $vm = Get-AzVM -ResourceId $h.ResourceId -ErrorAction SilentlyContinue
    $nicId = @($vm.NetworkProfile.NetworkInterfaces)[0].Id
    if ($nicId) { $subnetIds += @((Get-AzNetworkInterface -ResourceId $nicId).IpConfigurations)[0].Subnet.Id }
  }
  Add-Result (Get-SsuxCheckResult INFO 'host-pool' "$HostPoolName has $poolCount session host(s)")
}
$subnetIds = @($subnetIds | Where-Object { $_ } | Sort-Object -Unique)
$state.endpoints = [ordered]@{ subnets = @() }
foreach ($id in $subnetIds) {
  $parts = $id -split '/'
  $vnet = Get-AzVirtualNetwork -ResourceGroupName $parts[4] -Name $parts[8] -ErrorAction SilentlyContinue
  $subnet = $vnet.Subnets | Where-Object Name -eq $parts[10] | Select-Object -First 1
  if (-not $subnet) { Add-Result (Get-SsuxCheckResult FAIL "subnet $($parts[10])" "Subnet not found: $id"); continue }
  $label = "$($parts[8])/$($parts[10])"
  foreach ($p in @($vnet.AddressSpace.AddressPrefixes)) { $other += [pscustomobject]@{ Source = "endpoint VNet $($vnet.Name)"; Prefix = $p; Blocking = ($vnet.Id -eq $PeerVnetId) } }
  $rules = @()
  if ($subnet.NetworkSecurityGroup) {
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName ($subnet.NetworkSecurityGroup.Id -split '/')[4] -Name ($subnet.NetworkSecurityGroup.Id -split '/')[8]
    $rules = @(@($nsg.SecurityRules) + @($nsg.DefaultSecurityRules) | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Priority = $_.Priority; Direction = $_.Direction; Access = $_.Access; Protocol = $_.Protocol; DestinationAddressPrefix = @($_.DestinationAddressPrefix); DestinationPortRange = @($_.DestinationPortRange) }
      })
  }
  Add-Result (Get-SsuxEndpointNsgCheck -SubnetName $label -Rule $rules -HubIp $hubIp)
  $routes = @()
  if ($subnet.RouteTable) {
    $rt = Get-AzRouteTable -ResourceGroupName ($subnet.RouteTable.Id -split '/')[4] -Name ($subnet.RouteTable.Id -split '/')[8]
    $routes = @($rt.Routes | ForEach-Object { [pscustomobject]@{ Name = $_.Name; AddressPrefix = $_.AddressPrefix; NextHopType = "$($_.NextHopType)"; NextHopIpAddress = $_.NextHopIpAddress } })
  }
  Add-Result (Get-SsuxEndpointRouteCheck -SubnetName $label -Route $routes -HubIp $hubIp -AssessmentPrefix $AddressPrefix -DirectlyPeered ([bool]$PeerVnetId -and $vnet.Id -eq $PeerVnetId))
  $state.endpoints.subnets += [ordered]@{ id = $id; addressPrefix = @($subnet.AddressPrefix); nsgRules = $rules; routes = $routes }
}
if (-not $subnetIds.Count) {
  Add-Result (Get-SsuxCheckResult SKIP 'endpoint-network' 'No endpoint subnets to check' -Recommendation 'Pass -HostPoolName and -HostPoolResourceGroup, or -EndpointSubnetId, to check the callback path from the endpoints.')
}

$count = $EndpointCount; $source = '-EndpointCount'
if ($count -le 0 -and $poolCount) { $count = $poolCount; $source = "host pool $HostPoolName" }
if ($count -le 0 -and $avd) { $count = $avd.EndpointCount; $source = 'avd-current-state package' }
Add-Result (Get-SsuxEndpointSizingCheck -EndpointCount $count -Role $Role -Source $source)
$state.endpoints.count = $count

Write-Section 'Network'
Add-Result (Get-SsuxAddressOverlapCheck -AddressPrefix $AddressPrefix -Other $other)
$state.network.rangesChecked = $other

# ---------- Report ----------
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'output' }
$dir = Join-Path $OutputPath ("preflight-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$failed = @($results | Where-Object Status -eq 'FAIL').Count
$verdict = $(if ($failed) { 'FAIL' } else { 'PASS' })
$results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'results.json')
$results | Export-Csv (Join-Path $dir 'results.csv') -NoTypeInformation
$state | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'current-state.json')
$inputs = [ordered]@{}
foreach ($k in 'Location', 'Role', 'HubPlan', 'DatabasePlan', 'CollectorPlan', 'CollectorCount', 'HubVmSize', 'DatabaseVmSize', 'CollectorVmSize', 'NamePrefix', 'Environment', 'AddressPrefix', 'PeerVnetId', 'EndpointSubnetId', 'HostPoolName', 'HostPoolResourceGroup', 'AvdCurrentStatePath', 'EndpointCount', 'NoBastion', 'Fix') {
  $inputs[$k] = (Get-Variable $k).Value
}
$tally = [ordered]@{}
foreach ($st in 'FAIL', 'WARN', 'FIXED', 'PASS', 'INFO', 'SKIP') { $tally[$st] = @($results | Where-Object Status -eq $st).Count }
[ordered]@{ schemaVersion = 'stratusphere-instrument/v1'; reportKind = 'preflight-manifest'; tool = 'Test-StratusphereReadiness.ps1'; verdict = $verdict; counts = $tally; inputs = $inputs; files = @('report.md', 'results.csv', 'results.json', 'current-state.json') } |
  ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dir 'manifest.json')

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# Stratusphere preflight: $verdict")
[void]$md.AppendLine('')
[void]$md.AppendLine("$($sub.Name), $Location, roles $($Role -join ', '). $(($tally.Keys | ForEach-Object { "$($tally[$_]) $_" }) -join ', ').")
foreach ($group in @(@{ T = 'To fix before deploying'; S = 'FAIL' }, @{ T = 'Worth a look'; S = 'WARN' })) {
  $rowsOut = @($results | Where-Object Status -eq $group.S)
  if (-not $rowsOut.Count) { continue }
  [void]$md.AppendLine(''); [void]$md.AppendLine("## $($group.T)"); [void]$md.AppendLine('')
  foreach ($x in $rowsOut) { [void]$md.AppendLine("- **$($x.Category) / $($x.Check)**: $($x.Detail)$(if ($x.Recommendation) { " $($x.Recommendation)" })") }
}
[void]$md.AppendLine(''); [void]$md.AppendLine('## All checks'); [void]$md.AppendLine('')
[void]$md.AppendLine('| Category | Status | Check | Detail |'); [void]$md.AppendLine('|---|---|---|---|')
foreach ($x in $results) { [void]$md.AppendLine("| $($x.Category) | $($x.Status) | $($x.Check) | $($x.Detail -replace '\|', '/') |") }
$md.ToString() | Set-Content (Join-Path $dir 'report.md')

Write-Host ''
Write-Host "Report: $dir"
if ($failed) { Write-Host "RESULT FAIL $failed check(s) failed"; exit 1 }
Write-Host 'RESULT PASS ready to deploy'
