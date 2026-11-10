<#
.SYNOPSIS
  Deploys, checks, fixes and cleans up the Stratusphere appliances in Azure: Hub, Database, Collectors.
  Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE at the repo root). Not affiliated with the author's employer, with Liquidware or with Microsoft.

.DESCRIPTION
  One entry point for every role. -Role picks the appliances; -Action what to do with them:
    Plan     (default) what Deploy would change (what-if), plus the plan and terms checks. Changes nothing.
    Check    resource group, each appliance (exists, running, static IP), NSG rules, egress,
             Key Vault and its credential, Marketplace terms. Ends with RESULT PASS or FAIL.
    Deploy   registers providers, accepts the terms, recovers a soft-deleted Key Vault, and
             deploys the template with the appliances asked for plus the ones that already exist.
             The appliance password is generated once, kept in Key Vault and reused on later runs.
    Fix      runs Check, then only what repairs it: accept terms, recover the vault, redeploy
             (puts back a missing VM, a dynamic IP, a failed provisioning, NSG rules), start
             stopped VMs. Then checks again. Anything it can't repair safely is listed.
    Cleanup  -Role Collector or Database removes those VMs (disks and NICs go with them).
             -Role Hub removes the whole environment, including the peering on the other VNet.
             Asks for confirmation (-Force skips it); -WhatIf lists what would go.

  Liquidware advises a Database appliance above 1,000 Connector ID Keys. Collectors are optional.
  After deploying a Database or Collectors, point them at the Hub in their consoles (docs/appliances.md).

  The Marketplace plan (SKU) of each role comes from -HubPlan, -DatabasePlan and -CollectorPlan;
  for roles already deployed it is read from the VM. List the plans offered in a region with:
    ./scripts/ops/Test-StratusphereReadiness.ps1 -Location eastus2

.EXAMPLE
  ./scripts/ops/Deploy-Stratusphere.ps1 -Action Deploy -HubPlan <plan>
.EXAMPLE
  ./scripts/ops/Deploy-Stratusphere.ps1 -Action Deploy -Role Database,Collector -DatabasePlan <plan> -CollectorPlan <plan> -CollectorCount 2
.EXAMPLE
  ./scripts/ops/Deploy-Stratusphere.ps1 -Action Check
  ./scripts/ops/Deploy-Stratusphere.ps1 -Action Fix
.EXAMPLE
  ./scripts/ops/Deploy-Stratusphere.ps1 -Action Cleanup -Role Collector
  ./scripts/ops/Deploy-Stratusphere.ps1 -Action Cleanup -Role Hub -WhatIf
  (a real Cleanup of the Hub or Database also needs -DiscardLastCopy, once the assessment data is exported)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateSet('Plan', 'Check', 'Deploy', 'Fix', 'Cleanup')] [string] $Action = 'Plan',
  [ValidateSet('Hub', 'Database', 'Collector')] [string[]] $Role = @(),
  [string] $Location = 'eastus2',
  [string] $NamePrefix = 'ssux',
  [ValidateSet('', 'dev', 'test', 'prod')] [string] $Environment = '',
  [string] $HubPlan = '',
  [string] $DatabasePlan = '',
  [string] $CollectorPlan = '',
  [ValidateRange(1, 4)] [int] $CollectorCount = 1,
  [string] $ImageVersion = '',
  [string] $HubVmSize = '',
  [string] $PeerVnetId = '',
  [switch] $NoBastion,
  [string] $AutoShutdownTime = '2000',
  # Optional deadline auto-shutdown (G1 Deallocate) and auto-teardown (G2 Delete) in aa-avdlz-runs.
  [ValidateRange(0, 1440)] [int] $ShutdownAfterMinutes = 0,
  [ValidateRange(0, 1440)] [int] $TeardownAfterMinutes = 0,
  [string] $BatchId = '',
  # On Cleanup: deallocate VMs to stop the compute meter while keeping disks, VNet and Key Vault.
  [switch] $DeallocateOnly,
  [string] $ParameterFile = '',
  # Cleanup without asking.
  [switch] $Force,
  # Cleanup of the Hub or Database: remove them although they hold the only copy of the assessment
  # data (decision 0016 in avd-second-brain). -Force never implies it.
  [switch] $DiscardLastCopy,
  [string] $OutputPath = '',
  [ValidateSet('Bicep', 'Terraform')] [string] $Engine = 'Bicep'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $ParameterFile) { $ParameterFile = Join-Path $repoRoot 'parameters/lab.bicepparam' }
Import-Module (Join-Path $PSScriptRoot 'StratusphereReadiness.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StratusphereAppliance.psm1') -Force

$publisher = 'liquidware'
$offer = 'stratusphere'
$rgName = Get-SsuxResourceGroupName -NamePrefix $NamePrefix -Environment $Environment
$askedPlan = @{ Hub = $HubPlan; Database = $DatabasePlan; Collector = $CollectorPlan }
$peerGiven = $PSBoundParameters.ContainsKey('PeerVnetId')
$useDeadline = ($ShutdownAfterMinutes -gt 0 -or $TeardownAfterMinutes -gt 0)

$argErrors = @(Get-SsuxApplianceArgumentError -Action $Action -Role $Role -NamePrefix $NamePrefix -Plan $askedPlan -PeerVnetId $PeerVnetId)
if ($HubVmSize -and $HubVmSize -notmatch '^Standard_[A-Za-z0-9_]+$') { $argErrors += "Not a VM size: '$HubVmSize'" }
if ($ImageVersion -and $ImageVersion -notmatch '^(latest|[0-9.]+)$') { $argErrors += "Not an image version: '$ImageVersion'" }
if ($useDeadline -and -not $Environment) {
  $argErrors += 'Pass -Environment (dev, test or prod) when using -ShutdownAfterMinutes or -TeardownAfterMinutes so Invoke-AvdSandboxDeadline matches rg-<prefix>-<env>-*.'
}
if ($BatchId -and $BatchId -notmatch '^b[0-9]{8}-[0-9]{4}$') {
  $argErrors += "BatchId '$BatchId' must match bYYYYMMDD-HHmm."
}
if ($argErrors.Count -gt 0) {
  $argErrors | ForEach-Object { Write-Host "FAIL   $_" }
  Write-Host 'RESULT FAIL invalid arguments'
  exit 1
}

foreach ($m in 'Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network', 'Az.KeyVault', 'Az.MarketplaceOrdering') {
  if (-not (Get-Module -ListAvailable -Name $m)) {
    Write-Host "Installing $m from the PowerShell Gallery ..."
    Install-Module $m -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $m
}
$context = Get-AzContext
if (-not $context) { Write-Host 'Not signed in. Run Connect-AzAccount (Cloud Shell is already signed in).'; exit 1 }
Write-Host "Subscription: $($context.Subscription.Name)   Environment: $rgName   Action: $Action"

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result($r) {
  foreach ($x in @($r)) {
    $results.Add($x)
    $hint = $(if ($x.PSObject.Properties['Remedy'] -and $x.Remedy -and $x.Status -eq 'FAIL') { "  [fix: $($x.Remedy)]" } else { '' })
    Write-Host ("{0,-6} {1,-30} {2}{3}" -f $x.Status, $x.Check, $x.Detail, $hint)
  }
}

# ---------- Reading what exists ----------
function Get-ApplianceInventory {
  $rows = @()
  if (-not (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue)) { return $rows }
  foreach ($vm in @(Get-AzVM -ResourceGroupName $rgName -Status)) {
    $roleName = Get-SsuxApplianceRole -Tag $(if ($vm.Tags) { [string]$vm.Tags['stratusphere-role'] } else { '' })
    if (-not $roleName) { continue }
    $ip = ''; $allocation = ''
    $nicId = @($vm.NetworkProfile.NetworkInterfaces)[0].Id
    if ($nicId) {
      $ipc = @((Get-AzNetworkInterface -ResourceId $nicId).IpConfigurations)[0]
      $ip = $ipc.PrivateIpAddress; $allocation = $ipc.PrivateIpAllocationMethod
    }
    $rows += [pscustomobject]@{
      Role = $roleName; Name = $vm.Name; ProvisioningState = $vm.ProvisioningState; PowerState = $vm.PowerState
      PlanName = $(if ($vm.Plan) { $vm.Plan.Name } else { '' }); PrivateIp = $ip; IpAllocation = $allocation
    }
  }
  $rows
}

function Get-VaultState {
  $live = @(Get-AzKeyVault -ResourceGroupName $rgName -ErrorAction SilentlyContinue | Where-Object VaultName -like "kv-$NamePrefix-ss-*") | Select-Object -First 1
  $removed = $null
  if (-not $live) {
    $removed = @(Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue | Where-Object { $_.VaultName -like "kv-$NamePrefix-ss-*" }) | Select-Object -First 1
  }
  [pscustomobject]@{ Live = $live; Removed = $removed }
}

function Get-NetworkState {
  $vnet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name "vnet-$NamePrefix-stratusphere" -ErrorAction SilentlyContinue
  if (-not $vnet) { return $null }
  $subnet = $vnet.Subnets | Where-Object Name -eq 'snet-stratusphere' | Select-Object -First 1
  $nsg = $null
  if ($subnet.NetworkSecurityGroup) { $nsg = Get-AzResource -ResourceId $subnet.NetworkSecurityGroup.Id -ExpandProperties }
  [pscustomobject]@{
    Vnet                  = $vnet
    RuleNames             = @($nsg.Properties.securityRules | ForEach-Object name)
    HasNatGateway         = [bool]$subnet.NatGateway
    DefaultOutboundAccess = $subnet.DefaultOutboundAccess
    PeerVnetId            = @($vnet.VirtualNetworkPeerings | ForEach-Object { $_.RemoteVirtualNetwork.Id }) | Select-Object -First 1
    HasBastion            = @($vnet.Subnets | Where-Object Name -eq 'AzureBastionSubnet').Count -gt 0
  }
}

# ---------- Sandbox deadline schedules (aa-avdlz-runs) ----------
function Register-SandboxDeadline {
  [CmdletBinding(SupportsShouldProcess)]
  param([switch] $WhatIfOnly)
  if (-not $useDeadline) { return $null }
  $shutMin = $(if ($ShutdownAfterMinutes -gt 0) { $ShutdownAfterMinutes } else { 120 })
  $tearMin = $(if ($TeardownAfterMinutes -gt 0) { $TeardownAfterMinutes } else { 240 })
  $cfg = Get-SsuxSandboxDeadlineConfig -SubscriptionId $context.Subscription.Id -NamePrefix $NamePrefix -Environment $Environment `
    -BatchId $BatchId -ShutdownAfterMinutes $shutMin -TeardownAfterMinutes $tearMin
  $aaBase = "/subscriptions/$($cfg.SubscriptionId)/resourceGroups/$($cfg.AutomationRg)/providers/Microsoft.Automation/automationAccounts/$($cfg.AutomationAccount)"
  $rbResp = Invoke-AzRestMethod -Method GET -Path "$aaBase/runbooks/$($cfg.RunbookName)?api-version=2023-11-01"
  if ($rbResp.StatusCode -ne 200) {
    Add-Result (Get-SsuxCheckResult FAIL 'sandbox-deadline' "Runbook $($cfg.AutomationAccount)/$($cfg.RunbookName) not found in $($cfg.AutomationRg) (HTTP $($rbResp.StatusCode))")
    return $null
  }
  $rb = $rbResp.Content | ConvertFrom-Json
  if ($rb.properties.state -ne 'Published') {
    Add-Result (Get-SsuxCheckResult FAIL 'sandbox-deadline' "Runbook $($cfg.RunbookName) state is '$($rb.properties.state)', expected 'Published'")
    return $null
  }
  if ($WhatIfOnly) {
    Add-Result (Get-SsuxCheckResult PASS 'sandbox-deadline' "Would arm $($cfg.ShutdownScheduleName) ($($cfg.ShutdownUtc)) and $($cfg.TeardownScheduleName) ($($cfg.TeardownUtc)) in $($cfg.AutomationAccount)")
    return $cfg
  }
  if (-not $PSCmdlet.ShouldProcess($cfg.AutomationAccount, "Arm deadline schedules for $($cfg.ResourceGroupPrefix)")) { return $cfg }

  $specs = @()
  if ($ShutdownAfterMinutes -gt 0) {
    $specs += [pscustomobject]@{
      ScheduleName = $cfg.ShutdownScheduleName; StartTime = $cfg.ShutdownUtc; Group = 'G1'
      Action = 'Deallocate'; ResultsBlob = $cfg.ShutdownResultsBlob; Description = "Auto-deallocate $($cfg.ResourceGroupPrefix)*"
    }
  }
  if ($TeardownAfterMinutes -gt 0) {
    $specs += [pscustomobject]@{
      ScheduleName = $cfg.TeardownScheduleName; StartTime = $cfg.TeardownUtc; Group = 'G2'
      Action = 'Delete'; ResultsBlob = $cfg.TeardownResultsBlob; Description = "Auto-delete $($cfg.ResourceGroupPrefix)*"
    }
  }
  foreach ($s in $specs) {
    $schedBody = @{
      properties = @{
        description = $s.Description
        startTime   = $s.StartTime
        frequency   = 'OneTime'
        timeZone    = 'UTC'
      }
    } | ConvertTo-Json -Depth 5
    $sResp = Invoke-AzRestMethod -Method PUT -Path "$aaBase/schedules/$($s.ScheduleName)?api-version=2023-11-01" -Payload $schedBody
    if ($sResp.StatusCode -notin 200, 201) {
      throw "Failed to create schedule $($s.ScheduleName) (HTTP $($sResp.StatusCode)): $($sResp.Content)"
    }
    $jsId = [guid]::NewGuid().ToString()
    $jsBody = @{
      properties = @{
        schedule   = @{ name = $s.ScheduleName }
        runbook    = @{ name = $cfg.RunbookName }
        parameters = @{
          SubscriptionId      = $cfg.SubscriptionId
          StorageAccount      = $cfg.StorageAccount
          ResultsBlob         = $s.ResultsBlob
          BatchId             = $cfg.BatchId
          Group               = $s.Group
          ResourceGroupPrefix = $cfg.ResourceGroupPrefix
          Action              = $s.Action
        }
      }
    } | ConvertTo-Json -Depth 6
    $jResp = Invoke-AzRestMethod -Method PUT -Path "$aaBase/jobSchedules/${jsId}?api-version=2023-11-01" -Payload $jsBody
    if ($jResp.StatusCode -notin 200, 201) {
      throw "Failed to link jobSchedule for $($s.ScheduleName) (HTTP $($jResp.StatusCode)): $($jResp.Content)"
    }
    Add-Result (Get-SsuxCheckResult FIXED 'sandbox-deadline' "Armed $($s.ScheduleName) ($($s.Action) at $($s.StartTime))")
  }
  $cfg
}

function Unregister-SandboxDeadline {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  $subId = $context.Subscription.Id
  $aaBase = "/subscriptions/$subId/resourceGroups/avdlz-runs-rg/providers/Microsoft.Automation/automationAccounts/aa-avdlz-runs"
  $jsResp = Invoke-AzRestMethod -Method GET -Path "$aaBase/jobSchedules?api-version=2023-11-01"
  $pattern = "^ssux-(shutdown|teardown)-$([regex]::Escape($NamePrefix))-"
  $disarmed = @()
  if ($jsResp.StatusCode -eq 200) {
    $jsList = @(($jsResp.Content | ConvertFrom-Json).value)
    foreach ($js in $jsList) {
      $sName = [string]$js.properties.schedule.name
      if ($sName -match $pattern) {
        $jsId = $js.properties.jobScheduleId
        if (-not $jsId) { $jsId = ($js.id -split '/')[-1] }
        if ($PSCmdlet.ShouldProcess("jobSchedule/$jsId ($sName)", 'Remove Automation jobSchedule')) {
          Invoke-AzRestMethod -Method DELETE -Path "$aaBase/jobSchedules/${jsId}?api-version=2023-11-01" | Out-Null
        }
      }
    }
  }
  $sResp = Invoke-AzRestMethod -Method GET -Path "$aaBase/schedules?api-version=2023-11-01"
  if ($sResp.StatusCode -eq 200) {
    $sList = @(($sResp.Content | ConvertFrom-Json).value)
    foreach ($s in $sList) {
      if ($s.name -match $pattern) {
        if ($PSCmdlet.ShouldProcess($s.name, 'Remove Automation schedule')) {
          Invoke-AzRestMethod -Method DELETE -Path "$aaBase/schedules/$($s.name)?api-version=2023-11-01" | Out-Null
          $disarmed += $s.name
        }
      }
    }
  }
  if ($disarmed.Count -gt 0) {
    Add-Result (Get-SsuxCheckResult FIXED 'sandbox-deadline' "Disarmed $($disarmed -join ', ') in aa-avdlz-runs")
  }
}

function Invoke-Check([object[]] $Existing) {
  if (-not (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue)) {
    Add-Result ([pscustomobject]@{ Status = 'FAIL'; Check = 'resource-group'; Detail = "$rgName does not exist"; Remedy = 'deploy'; Name = '' })
    $vault = Get-VaultState
    if ($vault.Removed) { Add-Result (Get-SsuxVaultHealth -RemovedVaultName $vault.Removed.VaultName -AppliancesExist $false) }
    return
  }
  Add-Result ([pscustomobject]@{ Status = 'PASS'; Check = 'resource-group'; Detail = $rgName; Remedy = ''; Name = '' })

  $target = Get-SsuxDeployTarget -Role $(if ($Role) { $Role } else { @('Hub') }) -CollectorCount $CollectorCount -Existing $Existing
  $spec = @(Get-SsuxApplianceSpec -NamePrefix $NamePrefix -Hub:$target.DeployHub -Database:$target.DeployDatabase -CollectorCount $target.CollectorCount)
  Add-Result (Get-SsuxApplianceHealth -Spec $spec -Vm $Existing)

  $net = Get-NetworkState
  if (-not $net) {
    Add-Result ([pscustomobject]@{ Status = 'FAIL'; Check = 'vnet'; Detail = "vnet-$NamePrefix-stratusphere not found"; Remedy = 'deploy'; Name = '' })
  }
  else {
    $needPostgres = $target.DeployDatabase -or $target.CollectorCount -gt 0
    Add-Result (Get-SsuxNetworkHealth -RuleName $net.RuleNames -NeedPostgres $needPostgres -HasNatGateway $net.HasNatGateway -DefaultOutboundAccess $net.DefaultOutboundAccess)
  }

  $vault = Get-VaultState
  $secretNames = @()
  if ($vault.Live) {
    try { $secretNames = @(Get-AzKeyVaultSecret -VaultName $vault.Live.VaultName | ForEach-Object Name) }
    catch { Add-Result ([pscustomobject]@{ Status = 'WARN'; Check = 'key-vault'; Detail = "Can't list secrets in $($vault.Live.VaultName): $($_.Exception.Message)"; Remedy = ''; Name = '' }); $secretNames = $null }
  }
  if ($null -ne $secretNames) {
    Add-Result (Get-SsuxVaultHealth -VaultName $vault.Live.VaultName -RemovedVaultName $vault.Removed.VaultName -SecretName $secretNames -AppliancesExist ($Existing.Count -gt 0))
  }

  $terms = foreach ($p in @($Existing | ForEach-Object PlanName | Where-Object { $_ } | Sort-Object -Unique)) {
    [pscustomobject]@{ Plan = $p; Accepted = [bool](Get-AzMarketplaceTerms -Publisher $publisher -Product $offer -Name $p -OfferType 'virtualmachine').Accepted }
  }
  Add-Result (Get-SsuxTermsHealth -Terms @($terms))
}

# ---------- Changing things ----------
function Use-BicepCli {
  if (Get-Command bicep -ErrorAction SilentlyContinue) { return }
  $azBicep = Join-Path $HOME '.azure/bin/bicep'
  if (-not (Test-Path $azBicep) -and (Get-Command az -ErrorAction SilentlyContinue)) { az bicep install | Out-Null }
  if (-not (Test-Path $azBicep)) { throw 'The Bicep CLI is needed to read the .bicepparam file. Run: az bicep install' }
  $env:PATH = $env:PATH + [IO.Path]::PathSeparator + (Split-Path $azBicep)
}

function Confirm-Plan([hashtable] $Plans) {
  # Each plan offered in the region, and its terms accepted (Deploy) or reported (Plan).
  $ok = $true
  $offered = @()
  try { $offered = @(Get-AzVMImageSku -Location $Location -PublisherName $publisher -Offer $offer | ForEach-Object Skus) } catch { Write-Host "  Get-AzVMImageSku: $($_.Exception.Message)" }
  foreach ($p in @($Plans.Values | Where-Object { $_ } | Sort-Object -Unique)) {
    $r = Get-SsuxPlanCheck -AvailablePlans $offered -Plan $p -Location $Location
    Add-Result $r
    if ($r.Status -ne 'PASS') { $ok = $false; continue }
    $terms = Get-AzMarketplaceTerms -Publisher $publisher -Product $offer -Name $p -OfferType 'virtualmachine'
    if ($terms.Accepted) { Add-Result (Get-SsuxCheckResult PASS 'marketplace-terms' "Accepted for $p") }
    elseif ($Action -eq 'Plan') { Add-Result (Get-SsuxCheckResult WARN 'marketplace-terms' "Not accepted for $p yet; Deploy accepts them") }
    else {
      $terms | Set-AzMarketplaceTerms -Accept | Out-Null
      Add-Result (Get-SsuxCheckResult FIXED 'marketplace-terms' "Accepted for $p")
    }
  }
  $ok
}

function Resolve-AdminPassword([object[]] $Existing, [switch] $ForWhatIf) {
  # What-if only needs a value; it never reaches an appliance.
  if ($ForWhatIf) { try { return Resolve-AdminPassword $Existing } catch { return Get-SsuxRandomPassword } }
  # Reuse the password in Key Vault: the appliances keep the one they were created with.
  $vault = Get-VaultState
  if ($vault.Live) {
    try {
      $secret = Get-AzKeyVaultSecret -VaultName $vault.Live.VaultName -Name 'appliance-admin-password' -AsPlainText
      if ($secret) { Write-Host "Reusing the appliance password in $($vault.Live.VaultName)."; return $secret }
    }
    catch {
      if ($Existing.Count -gt 0) { throw "Can't read appliance-admin-password from $($vault.Live.VaultName) ($($_.Exception.Message)). You need Key Vault Secrets User on it; a new password would not match the appliances." }
    }
  }
  if ($Existing.Count -gt 0) { throw 'Appliances exist but their password is not in Key Vault. Reset it from the appliance console and store it as appliance-admin-password, then rerun.' }
  Write-Host 'Generated a random appliance password (stored in Key Vault as appliance-admin-password).'
  Get-SsuxRandomPassword
}

function Restore-Vault {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  $vault = Get-VaultState
  if ($vault.Live -or -not $vault.Removed) { return }
  if ($PSCmdlet.ShouldProcess($vault.Removed.VaultName, 'Recover soft-deleted Key Vault')) {
    if (-not (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue)) { New-AzResourceGroup -Name $rgName -Location $Location | Out-Null }
    Undo-AzKeyVaultRemoval -VaultName $vault.Removed.VaultName -ResourceGroupName $rgName -Location $vault.Removed.Location | Out-Null
    Add-Result (Get-SsuxCheckResult FIXED 'key-vault' "Recovered $($vault.Removed.VaultName) with its secrets")
  }
}

function Invoke-Deployment {
  [CmdletBinding(SupportsShouldProcess)]
  param([object[]] $Existing = @(), [switch] $WhatIfOnly)
  $target = Get-SsuxDeployTarget -Role $(if ($Role) { $Role } else { @('Hub') }) -CollectorCount $CollectorCount -Plan $askedPlan -Existing $Existing
  $target.Notes | ForEach-Object { Write-Host "NOTE   $_" }
  if ($target.Errors.Count -gt 0) { $target.Errors | ForEach-Object { Add-Result (Get-SsuxCheckResult FAIL 'roles' $_) }; return $null }
  $roles = @('Hub')
  if ($target.DeployDatabase) { $roles += 'Database' }
  if ($target.CollectorCount) { $roles += "$($target.CollectorCount) Collector(s)" }
  Write-Host "Template: $($roles -join ', ')"
  if (-not $WhatIfOnly) {
    foreach ($ns in 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.MarketplaceOrdering') {
      if ((Get-AzResourceProvider -ProviderNamespace $ns | Select-Object -First 1).RegistrationState -ne 'Registered') {
        Register-AzResourceProvider -ProviderNamespace $ns | Out-Null
        Add-Result (Get-SsuxCheckResult FIXED 'provider' "$ns registration started")
      }
    }
  }
  if (-not (Confirm-Plan $target.Plan)) { return $null }

  $deadlineCfg = $null
  if ($useDeadline) {
    $deadlineCfg = Register-SandboxDeadline -WhatIfOnly:$WhatIfOnly
    if (-not $deadlineCfg) { return $null }
  }

  # Keep what the environment already has unless asked otherwise: dropping the Bastion
  # subnet under a running Bastion, or the peering, would fail or disconnect the endpoints.
  $net = Get-NetworkState
  $peer = $(if ($peerGiven) { $PeerVnetId } elseif ($net) { [string]$net.PeerVnetId } else { '' })
  $bastion = $(if ($NoBastion) { 'false' } elseif ($net) { ([string]$net.HasBastion).ToLower() } else { 'true' })

  $reader = $null
  try { $reader = (Get-AzADUser -SignedIn).Id } catch { Write-Verbose $_.Exception.Message }
  if (-not $reader) { $reader = $env:SSUX_KV_READER_ID }
  if (-not $reader) { throw 'Could not read the signed-in user (a service principal?). Set SSUX_KV_READER_ID to the object ID that should read the appliance password.' }

  if (-not $WhatIfOnly) { Restore-Vault }
  $password = Resolve-AdminPassword $Existing -ForWhatIf:$WhatIfOnly
  if ($Engine -eq 'Terraform') {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { throw 'The Terraform CLI is needed for -Engine Terraform. Install terraform (>= 1.9) or use -Engine Bicep.' }
    $tfDir = Join-Path $repoRoot 'terraform'
    $tfVars = Get-SsuxTerraformVariable -NamePrefix $NamePrefix -Environment $Environment -Location $Location -Target $target -KeyVaultReaderObjectId $reader `
      -ImageVersion $ImageVersion -HubVmSize $HubVmSize -AutoShutdownTime $AutoShutdownTime -PeerVnetId $peer -DeployBastion ($bastion -eq 'true') -DeadlineConfig $deadlineCfg
    $varFile = Join-Path ([System.IO.Path]::GetTempPath()) "ssux-tf-$PID.tfvars.json"
    $tfVars | ConvertTo-Json -Depth 5 | Set-Content -Path $varFile -Encoding utf8NoBOM -WhatIf:$false
    try {
      $env:TF_VAR_adminPassword = $password
      & terraform "-chdir=$tfDir" init -input=false | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'terraform init failed in stratusphere/terraform.' }
      if ($WhatIfOnly) {
        & terraform "-chdir=$tfDir" plan -input=false "-var-file=$varFile"
        if ($LASTEXITCODE -ne 0) { throw 'terraform plan failed in stratusphere/terraform.' }
        return $null
      }
      if (-not $PSCmdlet.ShouldProcess($rgName, "Deploy $($roles -join ', ') (Terraform)")) { return $null }
      Write-Host 'Deploying with Terraform (Bastion takes several minutes the first time) ...'
      & terraform "-chdir=$tfDir" apply -auto-approve -input=false "-var-file=$varFile"
      if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed in stratusphere/terraform.' }
      Add-Result (Get-SsuxCheckResult FIXED 'deployment' 'terraform apply succeeded')
      return (& terraform "-chdir=$tfDir" output -json | ConvertFrom-Json)
    }
    finally {
      Remove-Item 'env:TF_VAR_adminPassword' -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $varFile -Force -ErrorAction SilentlyContinue
    }
  }
  $vars = @{
    SSUX_NAME_PREFIX = $NamePrefix; SSUX_ENVIRONMENT = $Environment; SSUX_LOCATION = $Location; SSUX_IMAGE_VERSION = $ImageVersion; SSUX_HUB_VM_SIZE = $HubVmSize
    SSUX_DEPLOY_HUB = ([string]$target.DeployHub).ToLower(); SSUX_HUB_PLAN = $target.Plan['Hub']
    SSUX_DEPLOY_DATABASE = ([string]$target.DeployDatabase).ToLower(); SSUX_DATABASE_PLAN = [string]$target.Plan['Database']
    SSUX_COLLECTOR_COUNT = [string]$target.CollectorCount; SSUX_COLLECTOR_PLAN = [string]$target.Plan['Collector']
    SSUX_AUTO_SHUTDOWN_TIME = $AutoShutdownTime
    SSUX_SHUTDOWN_UTC = $(if ($deadlineCfg) { $deadlineCfg.ShutdownUtc } else { '' })
    SSUX_TEARDOWN_UTC = $(if ($deadlineCfg) { $deadlineCfg.TeardownUtc } else { '' })
    SSUX_SHUTDOWN_SCHEDULE = $(if ($deadlineCfg) { $deadlineCfg.ShutdownScheduleName } else { '' })
    SSUX_TEARDOWN_SCHEDULE = $(if ($deadlineCfg) { $deadlineCfg.TeardownScheduleName } else { '' })
    SSUX_PEER_VNET_ID = $peer; SSUX_DEPLOY_BASTION = $bastion; SSUX_KV_READER_ID = $reader; SSUX_ADMIN_PASSWORD = $password
  }
  Use-BicepCli
  try {
    foreach ($k in $vars.Keys) { Set-Item "env:$k" -Value ([string]$vars[$k]) }
    $name = "ssux-{0:yyyyMMddHHmmss}" -f (Get-Date)
    if ($WhatIfOnly) {
      New-AzSubscriptionDeployment -Name $name -Location $Location -TemplateParameterFile $ParameterFile -WhatIf
      return $null
    }
    if (-not $PSCmdlet.ShouldProcess($rgName, "Deploy $($roles -join ', ')")) { return $null }
    Write-Host 'Deploying (Bastion takes several minutes the first time) ...'
    $d = New-AzSubscriptionDeployment -Name $name -Location $Location -TemplateParameterFile $ParameterFile
    if ($d.ProvisioningState -ne 'Succeeded') { throw "Deployment $name ended $($d.ProvisioningState)" }
    Add-Result (Get-SsuxCheckResult FIXED 'deployment' "$name succeeded")
    $d.Outputs
  }
  finally {
    foreach ($k in $vars.Keys) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
  }
}

function Remove-RemotePeering {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  # Step 1 of peered teardown: remove the peering link on the remote VNet
  # before deleting the Stratusphere resource group so no Disconnected peering is left behind.
  $targetVnetSuffix = "/resourceGroups/$rgName/providers/Microsoft.Network/virtualNetworks/vnet-$NamePrefix-stratusphere"
  $candidateVnets = [System.Collections.Generic.List[object]]::new()
  $net = Get-NetworkState
  if ($net) {
    foreach ($p in @($net.Vnet.VirtualNetworkPeerings)) {
      $parts = $p.RemoteVirtualNetwork.Id -split '/'
      $rv = Get-AzVirtualNetwork -ResourceGroupName $parts[4] -Name $parts[8] -ErrorAction SilentlyContinue
      if ($rv) { $candidateVnets.Add($rv) }
    }
  }
  if ($PeerVnetId) {
    $parts = $PeerVnetId -split '/'
    $rv = Get-AzVirtualNetwork -ResourceGroupName $parts[4] -Name $parts[8] -ErrorAction SilentlyContinue
    if ($rv -and @($candidateVnets | Where-Object Id -eq $rv.Id).Count -eq 0) { $candidateVnets.Add($rv) }
  }
  foreach ($rv in $candidateVnets) {
    $remote = @(Get-AzVirtualNetworkPeering -VirtualNetworkName $rv.Name -ResourceGroupName $rv.ResourceGroupName -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteVirtualNetwork.Id -like "*$targetVnetSuffix" })
    foreach ($r in $remote) {
      if (-not $PSCmdlet.ShouldProcess("$($rv.Name)/$($r.Name)", 'Remove peering')) { continue }
      Remove-AzVirtualNetworkPeering -VirtualNetworkName $rv.Name -ResourceGroupName $rv.ResourceGroupName -Name $r.Name -Force
      Write-Host "Removed peering $($r.Name) from $($rv.Name)"
    }
  }
}

function Write-NextStep([object[]] $Existing) {
  $kv = (Get-VaultState).Live.VaultName
  Write-Host ''
  Write-Host 'Next:'
  Write-Host "  Password: Get-AzKeyVaultSecret -VaultName $kv -Name appliance-admin-password -AsPlainText"
  foreach ($a in $Existing) {
    switch ($a.Role) {
      'Hub' { Write-Host "  Hub $($a.PrivateIp): console through Bastion or https://$($a.PrivateIp); apply the license, create the API user, whitelist API callers." }
      'Database' { Write-Host "  Database $($a.PrivateIp): in the Hub console, point the Hub at it (Hub Administration > Database)." }
      'Collector' { Write-Host "  Collector $($a.PrivateIp): in its console, register it with the Hub; it picks up the database and reboots." }
    }
  }
}

# ---------- Actions ----------
$existing = @(Get-ApplianceInventory)
switch ($Action) {
  'Plan' {
    Invoke-Deployment -Existing $existing -WhatIfOnly | Out-Null
  }
  'Check' {
    Invoke-Check -Existing $existing
  }
  'Deploy' {
    $out = Invoke-Deployment -Existing $existing
    if ($out) {
      $results.Clear()
      Write-Host ''
      Write-Host 'Checking the result ...'
      $existing = @(Get-ApplianceInventory)
      Invoke-Check -Existing $existing
      Write-NextStep -Existing $existing
    }
  }
  'Fix' {
    Invoke-Check -Existing $existing
    $steps = @(Get-SsuxFixPlan -Result $results)
    if ($steps.Count -eq 0) { Write-Host ''; Write-Host 'Nothing to fix.' }
    else {
      Write-Host ''
      Write-Host 'Fix plan:'
      $steps | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Step, $_.Target) }
      $results.Clear()
      foreach ($s in $steps) {
        switch ($s.Step) {
          'accept-terms' {
            if ($PSCmdlet.ShouldProcess($s.Target, 'Accept Marketplace terms')) {
              $t = Get-AzMarketplaceTerms -Publisher $publisher -Product $offer -Name $s.Target -OfferType 'virtualmachine'
              $t | Set-AzMarketplaceTerms -Accept | Out-Null
              Add-Result (Get-SsuxCheckResult FIXED 'marketplace-terms' "Accepted for $($s.Target)")
            }
          }
          'recover-vault' { Restore-Vault }
          'deploy' { Invoke-Deployment -Existing $existing | Out-Null }
          'start' {
            if ($PSCmdlet.ShouldProcess($s.Target, 'Start VM')) {
              Start-AzVM -ResourceGroupName $rgName -Name $s.Target | Out-Null
              Add-Result (Get-SsuxCheckResult FIXED 'start' "Started $($s.Target)")
            }
          }
          'manual' { Add-Result (Get-SsuxCheckResult FAIL 'manual' $s.Target) }
        }
      }
      if (-not $WhatIfPreference) {
        $manual = @($results | Where-Object Check -eq 'manual')
        $results.Clear()
        Write-Host ''
        Write-Host 'Checking again ...'
        $existing = @(Get-ApplianceInventory)
        Invoke-Check -Existing $existing
        $manual | ForEach-Object { Add-Result $_ }
      }
    }
  }
  'Cleanup' {
    if ($DeallocateOnly) {
      if ($existing.Count -eq 0) { Add-Result (Get-SsuxCheckResult PASS 'deallocate' "No appliances in $rgName") }
      else {
        foreach ($vm in $existing) {
          if ($PSCmdlet.ShouldProcess($vm.Name, 'Deallocate VM (stop compute meter)')) {
            Stop-AzVM -ResourceGroupName $rgName -Name $vm.Name -Force | Out-Null
            Add-Result (Get-SsuxCheckResult FIXED 'deallocate' "Deallocated $($vm.Name)")
          }
        }
      }
    }
    else {
      $plan = Get-SsuxCleanupPlan -Role $Role -Existing $existing -ResourceGroupName $rgName -DiscardLastCopy:$DiscardLastCopy
      $plan.Notes | ForEach-Object { Write-Host "NOTE   $_" }
      if ($plan.Blocked) { Add-Result (Get-SsuxCheckResult FAIL 'last-copy' "$($plan.Blocked) Nothing was removed.") }
      elseif ($plan.Scope -eq 'ResourceGroup') {
        if (-not (Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue)) {
          Remove-RemotePeering
          Unregister-SandboxDeadline
          Add-Result (Get-SsuxCheckResult PASS 'cleanup' "$rgName does not exist")
        }
        elseif ($PSCmdlet.ShouldProcess($rgName, 'Remove the resource group and everything in it') -and
          ($Force -or $PSCmdlet.ShouldContinue("Remove $rgName and every appliance, disk and secret in it?", 'Cleanup'))) {
          Remove-RemotePeering
          Remove-AzResourceGroup -Name $rgName -Force | Out-Null
          Unregister-SandboxDeadline
          Add-Result (Get-SsuxCheckResult FIXED 'cleanup' "Removed $rgName")
        }
      }
      elseif ($plan.Target.Count -eq 0) { Add-Result (Get-SsuxCheckResult PASS 'cleanup' "No $($Role -join ' or ') appliances to remove") }
      elseif ($Force -or $WhatIfPreference -or $PSCmdlet.ShouldContinue("Remove $($plan.Target -join ', ') with their disks and NICs?", 'Cleanup')) {
        foreach ($vm in $plan.Target) {
          if ($PSCmdlet.ShouldProcess($vm, 'Remove VM with its disk and NIC')) {
            Remove-AzVM -ResourceGroupName $rgName -Name $vm -Force | Out-Null
            Add-Result (Get-SsuxCheckResult FIXED 'cleanup' "Removed $vm")
          }
        }
        Write-Host 'Run -Action Fix (or Deploy) afterwards to drop NSG rules the remaining roles no longer need.'
      }
    }
  }
}

$outDir = $(if ($OutputPath) { $OutputPath } else { Join-Path $repoRoot 'output' })
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$report = Join-Path $outDir ("stratusphere-{0}-{1:yyyyMMdd-HHmmss}.json" -f $Action.ToLower(), (Get-Date))
[pscustomobject]@{ schemaVersion = 'stratusphere-instrument/v1'; reportKind = 'appliance'; action = $Action; resourceGroup = $rgName; roles = $Role; results = $results } | ConvertTo-Json -Depth 5 | Set-Content -Path $report

$summary = Get-SsuxApplianceSummary -Result $results
Write-Host ''
if ($summary.Result -eq 'FAIL') {
  $hint = $(if ($Action -in 'Check', 'Plan') { '; -Action Fix repairs what it can' } else { '' })
  Write-Host "RESULT FAIL $($summary.Failed) check(s) failed$hint"
  exit 1
}
Write-Host "RESULT PASS $Action"
