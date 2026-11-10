#requires -Version 7.4
<#
.SYNOPSIS
  Deploys ProfileUnity, FlexApp, Stratusphere and CommandCTRL against an existing avd-landing-zone landing zone.
  Personal project, not for production use. Provided as is, without warranty of any kind. Not affiliated with the author's employer, with Liquidware or with Microsoft.

.DESCRIPTION
  One entry point for the whole tier (docs/deploy-spec.md). -Component picks what, -Action what to do:
    Plan       (default) what would change. Changes nothing.
    Check      what exists and whether it is healthy. Ends with RESULT PASS or FAIL.
    Deploy     ProfileUnity and FlexApp: Plan, then (after you confirm) the template, then the console
               download and hash check by Run Command when output/media.lock.json has the console.
    Configure  session hosts via drained Run Command (Sync-LiquidwareHosts.ps1).
    Promote    staged ProfileUnity configuration or FlexApp assignment on -Ring QA|All.
    Fix        Check, then repairs what it can.
    Cleanup    removes the tier peering and DNS links on the landing zone, then the tier resource group;
               then teardown evidence. Asks first; -Force skips; -WhatIf lists.

  Plan and Check are read-only. Every action writes a JSON report to output/ (git-ignored).
  What-if needs the Bicep CLI (Cloud Shell has it).

.EXAMPLE
  ./scripts/Deploy-LiquidwareTier.ps1 -NamePrefix avdlz -Environment dev -Component ProfileUnity,FlexApp,Stratusphere
.EXAMPLE
  ./scripts/Deploy-LiquidwareTier.ps1 -NamePrefix avdlz -Environment dev -Component ProfileUnity -Action Deploy
.EXAMPLE
  ./scripts/Deploy-LiquidwareTier.ps1 -NamePrefix avdlz -Environment dev -Component ProfileUnity -Action Cleanup -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)] [string] $NamePrefix,
  [Parameter(Mandatory)] [string] $Environment,
  [Parameter(Mandatory)] [string[]] $Component,
  [ValidateSet('Plan', 'Check', 'Deploy', 'Configure', 'Promote', 'Fix', 'Cleanup')] [string] $Action = 'Plan',
  [string] $TierAddressPrefix = '10.61.0.0/24',
  [string] $SubscriptionId = '',
  # Object ID of the landing zone users group, when discovery finds none or several. Never commit it.
  [string] $UsersGroupId = '',
  # The media lock Publish-LiquidwareMedia.ps1 writes (default output/media.lock.json).
  [string] $MediaLockPath = '',
  # Where the JSON report goes (default output/, git-ignored).
  [string] $ReportDirectory = '',
  # Deploy and Cleanup without asking.
  [switch] $Force,
  # Cleanup: remove the tier resource group although it holds the only copy of the tier's data
  # (decision 0016 in avd-second-brain). -Force never implies it.
  [switch] $DiscardLastCopy,
  [switch] $Bastion,
  [switch] $Portability,
  [switch] $ApplicationRestrictions,
  [switch] $Packaging,
  [ValidateSet('QA', 'All')] [string] $Ring = 'QA',
  [string] $WindowEnd = '',
  [ValidateSet('Bicep', 'Terraform')] [string] $Engine = 'Bicep',
  [switch] $RemoveUserData,
  [string] $ConfigName = 'default',
  [string] $PromoteTimestamp = '',
  [string] $StagedIniSha256 = '',
  [string] $ExportPath = '',
  [string] $App = '',
  [string] $Version = '',
  [string] $HubAddress = '10.60.0.4',
  [string] $InstallerUrl = '',
  [string] $InstallerSha256 = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LiquidwareTier.psm1') -Force
$reportDir = $(if ($ReportDirectory) { $ReportDirectory } else { Join-Path $PSScriptRoot '../output' })
$ssuxOpsDir = Join-Path $PSScriptRoot '../stratusphere/scripts/ops'
foreach ($dir in @($PSScriptRoot, $ssuxOpsDir)) {
  if (($env:PATH -split [System.IO.Path]::PathSeparator) -notcontains $dir) {
    $env:PATH = $dir + [System.IO.Path]::PathSeparator + $env:PATH
  }
}

$argErrors = @(Get-LwArgumentError -NamePrefix $NamePrefix -Environment $Environment -Component $Component -TierAddressPrefix $TierAddressPrefix)
if ($argErrors.Count -gt 0) {
  $argErrors | ForEach-Object { Write-Host "FAIL   $_" }
  Write-Host 'RESULT FAIL invalid arguments'
  exit 1
}

foreach ($m in 'Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Compute', 'Az.KeyVault', 'Az.PrivateDns') {
  if (-not (Get-Module -ListAvailable -Name $m)) {
    Write-Host "Installing $m from the PowerShell Gallery ..."
    Install-Module $m -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $m
}
if ($SubscriptionId) { $null = Set-AzContext -SubscriptionId $SubscriptionId }
$context = Get-AzContext
if (-not $context) { Write-Host 'Not signed in. Run Connect-AzAccount (Cloud Shell is already signed in).'; exit 2 }

$names = Get-LwName -NamePrefix $NamePrefix -Environment $Environment
Write-Host "Subscription: $($context.Subscription.Name)   Landing zone: $($names.Base)   Components: $($Component -join ', ')   Action: $Action   Ring: $Ring"

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result($r) {
  foreach ($x in @($r)) {
    if (-not $x) { continue }
    $results.Add($x)
    $hint = $(if ($x.Recommendation -and $x.Status -in 'FAIL', 'WARN') { "  [fix: $($x.Recommendation)]" } else { '' })
    Write-Host ("{0,-6} {1,-26} {2}{3}" -f $x.Status, $x.Check, $x.Detail, $hint)
  }
}
# The JSON report every action leaves in output/ (git-ignored: it holds names from the tenant), then the result line.
function Complete-Run {
  $out = $reportDir
  # Written under -WhatIf too: the report is the record of what was listed.
  if (-not (Test-Path $out)) { $null = New-Item -ItemType Directory -Path $out -Force -WhatIf:$false }
  $file = Join-Path $out ("{0}-{1}-{2}.json" -f $Action.ToLower(), $names.Base, (Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ'))
  [pscustomobject]@{ action = $Action; landingZone = $names.Base; components = $Component; ring = $Ring; at = (Get-Date -AsUTC -Format o); results = $results } |
    ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8NoBOM -WhatIf:$false
  Write-Host "Report: $file"
  $fails = @($results | Where-Object Status -eq 'FAIL')
  if ($fails.Count -gt 0) { Write-Host "RESULT FAIL $($fails.Count) check(s) failed"; exit 1 }
  Write-Host 'RESULT PASS'
  exit 0
}
function Confirm-Step {
  # -WhatIf lists and does nothing; -Force skips the question; otherwise the operator types the name.
  [CmdletBinding(SupportsShouldProcess)]
  param([string] $Target, [string] $What, [switch] $Force)
  if (-not $PSCmdlet.ShouldProcess($Target, $What)) { return $false }
  if ($Force) { return $true }
  (Read-Host "$What on $Target. Type $Target to go ahead") -ceq $Target
}

# Actions not applicable to a component fail before anything is read or changed.
$summary = @(Get-LwPlanSummary -Component $Component -Action $Action)
if (@($summary | Where-Object Status -eq 'FAIL').Count -gt 0) {
  Add-Result $summary
  Complete-Run
}

# ---------- Reading the landing zone ----------
Write-Host 'Reading the landing zone (resource groups, resources, spoke VNet) ...'
$groups = @(Get-AzResourceGroup | Select-Object -ExpandProperty ResourceGroupName)
$resources = @()
foreach ($g in $names.ResourceGroups.Values) {
  if ($groups -contains $g) { $resources += @(Get-AzResource -ResourceGroupName $g) }
}
$vnet = $null
$az = Get-AzVirtualNetwork -ResourceGroupName $names.ResourceGroups.Network -Name $names.Vnet -ErrorAction SilentlyContinue
if ($az) {
  $vnet = [pscustomobject]@{
    Id              = $az.Id
    Location        = $az.Location
    AddressPrefixes = @($az.AddressSpace.AddressPrefixes)
    Subnets         = @($az.Subnets | ForEach-Object {
        [pscustomobject]@{
          Name          = $_.Name
          AddressPrefix = @($_.AddressPrefix)[0]
          NatGatewayId  = $(if ($_.NatGateway) { $_.NatGateway.Id } else { $null })
          RouteTableId  = $(if ($_.RouteTable) { $_.RouteTable.Id } else { $null })
        }
      })
    Peerings        = @($az.VirtualNetworkPeerings | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; RemoteVnetId = $_.RemoteVirtualNetwork.Id; RemoteAddressPrefixes = @($_.RemoteVirtualNetworkAddressSpace.AddressPrefixes) }
      })
  }
}
$lz = Get-LwLandingZone -NamePrefix $NamePrefix -Environment $Environment -ResourceGroup $groups -Resource $resources -Vnet $vnet

# ---------- Cleanup: only the tier's own names, even when the landing zone is half gone ----------
function Read-TierLeftover {
  $allGroups = @(Get-AzResourceGroup | Select-Object -ExpandProperty ResourceGroupName)
  $tierExists = $allGroups -contains $names.TierGroup
  $links = @()
  if ($allGroups -contains $names.ResourceGroups.Network) {
    foreach ($z in @(Get-AzPrivateDnsZone -ResourceGroupName $names.ResourceGroups.Network)) {
      $links += @(Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $names.ResourceGroups.Network -ZoneName $z.Name | ForEach-Object {
          [pscustomobject]@{ Name = $_.Name; ZoneName = $z.Name; VirtualNetworkId = $_.VirtualNetworkId; ResourceId = $_.ResourceId }
        })
    }
  }
  $spoke = Get-AzVirtualNetwork -ResourceGroupName $names.ResourceGroups.Network -Name $names.Vnet -ErrorAction SilentlyContinue
  $hostRcs = @()
  $dcrAssocs = @()
  if ($allGroups -contains $names.ResourceGroups.Hosts) {
    $hostRes = @(Get-AzResource -ResourceGroupName $names.ResourceGroups.Hosts)
    $hostRcs = @($hostRes | Where-Object { $_ -and $_.ResourceType -eq 'Microsoft.Compute/virtualMachines/runCommands' -and ($_.Name -split '/')[-1] -eq 'lw-profileunity-client' } | ForEach-Object {
        [pscustomobject]@{ Name = 'lw-profileunity-client'; VmName = ($_.Name -split '/')[0]; ResourceGroup = $names.ResourceGroups.Hosts; ResourceId = $_.ResourceId }
      })
    $dcrAssocs = @($hostRes | Where-Object { $_ -and $_.ResourceType -eq 'Microsoft.Insights/dataCollectionRuleAssociations' -and ($_.Name -split '/')[-1] -eq 'lw-restrictions' } | ForEach-Object {
        [pscustomobject]@{ Name = 'lw-restrictions'; VmName = ($_.Name -split '/')[0]; ResourceGroup = $names.ResourceGroups.Hosts; ResourceId = $_.ResourceId }
      })
  }
  $hostRas = @()
  if ($tierExists) {
    $subId = $(if ($context.Subscription -and $context.Subscription.PSObject.Properties['Id'] -and $context.Subscription.Id) { $context.Subscription.Id } else { '00000000-0000-0000-0000-000000000000' })
    $tierScope = "/subscriptions/$subId/resourceGroups/$($names.TierGroup)"
    $hostRas = @(Get-AzRoleAssignment -Scope $tierScope -ErrorAction SilentlyContinue | Where-Object {
        $_ -and $_.ObjectType -eq 'ServicePrincipal' -and $_.RoleDefinitionName -in 'Storage File Data SMB Share Reader', 'Storage File Data SMB Share Contributor'
      } | ForEach-Object {
        [pscustomobject]@{ RoleDefinitionName = $_.RoleDefinitionName; ObjectId = $_.ObjectId; RoleAssignmentId = $_.RoleAssignmentId; Scope = $_.Scope }
      })
  }
  $portShare = $null
  if ($allGroups -contains $names.ResourceGroups.Storage) {
    $stgRes = @(Get-AzResource -ResourceGroupName $names.ResourceGroups.Storage)
    $hitShare = @($stgRes | Where-Object { $_ -and $_.ResourceType -eq 'Microsoft.Storage/storageAccounts/fileServices/shares' -and ($_.Name -split '/')[-1] -eq 'portability' }) | Select-Object -First 1
    if ($hitShare) {
      $portShare = [pscustomobject]@{ Name = 'portability'; StorageAccountName = ($hitShare.Name -split '/')[0]; ResourceGroup = $names.ResourceGroups.Storage; ResourceId = $hitShare.ResourceId }
    }
  }
  [pscustomobject]@{
    TierGroupExists    = $tierExists
    Peering            = @($(if ($spoke) { @($spoke.VirtualNetworkPeerings | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; RemoteVnetId = $_.RemoteVirtualNetwork.Id } }) }))
    DnsLink            = $links
    HostRunCommand     = $hostRcs
    DcrAssociation     = $dcrAssocs
    HostRoleAssignment = $hostRas
    PortabilityShare   = $portShare
  }
}

$profileUnity = @($Component | Where-Object { $_ -in 'ProfileUnity', 'FlexApp' }).Count -gt 0

if ($Action -eq 'Cleanup') {
  if ($Component -contains 'Stratusphere') {
    $ssux = Get-LwStratusphereArgument -LandingZone $lz -Engine $Engine -Bastion:$Bastion
    if ($ssux.HostPoolName) {
      $global:LASTEXITCODE = 0
      Deploy-CidKey.ps1 -HostPoolName $ssux.HostPoolName -HostPoolResourceGroup $ssux.HostPoolResourceGroup -Action Cleanup -Force:$Force -OutputPath $reportDir
    }
    $deploySsux = @{}
    foreach ($k in $ssux.Keys) { if ($k -notin 'HostPoolName', 'HostPoolResourceGroup') { $deploySsux[$k] = $ssux[$k] } }
    $global:LASTEXITCODE = 0
    Deploy-Stratusphere.ps1 @deploySsux -Action Cleanup -Force:$Force -DiscardLastCopy:$DiscardLastCopy -OutputPath $reportDir -WhatIf:$WhatIfPreference
    Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'stratusphere-cleanup' 'Stratusphere CID key and appliance cleanup completed.' -Category Stratusphere)
  }
  if ($Component -contains 'CommandCTRL') {
    $global:LASTEXITCODE = 0
    Sync-LiquidwareHosts.ps1 -NamePrefix $NamePrefix -Environment $Environment -Component CommandCTRL -Action Cleanup -SubscriptionId $SubscriptionId -ReportDirectory $reportDir -Force:$Force -WhatIf:$WhatIfPreference
    Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'commandctrl-cleanup' 'CommandCTRL host cleanup completed.' -Category CommandCTRL)
  }
  if ($profileUnity) {
    $before = Read-TierLeftover
    $steps = @(Get-LwCleanupPlan -Names $names -TierGroupExists $before.TierGroupExists -Peering $before.Peering -DnsLink $before.DnsLink `
        -HostRunCommand $before.HostRunCommand -DcrAssociation $before.DcrAssociation -HostRoleAssignment $before.HostRoleAssignment `
        -PortabilityShare $before.PortabilityShare -RemoveUserData:$RemoveUserData)
    if ($steps.Count -eq 0) { Add-Result (Get-LwCheckResult PASS 'cleanup' 'Nothing of the tier is left to remove.' -Category Cleanup) }
    foreach ($st in $steps) { Add-Result (Get-LwCheckResult INFO 'cleanup-step' "$($st.Kind) $($st.Name)$(if ($st.Parent) { " on $($st.Parent)" })" -Category Cleanup) }
    if ($before.PortabilityShare -and -not $RemoveUserData) {
      Add-Result (Get-LwCheckResult INFO 'portability-retained' "Share portability on $($before.PortabilityShare.StorageAccountName) preserved (pass -RemoveUserData -DiscardLastCopy to delete user portability archives)." -Category Cleanup)
    }
    $lastCopy = Get-LwLastCopyCheck -Steps $steps -DiscardLastCopy:$DiscardLastCopy
    if ($lastCopy) { Add-Result $lastCopy }
    # -WhatIf still lists the steps; a real run stops here.
    if ($lastCopy.Status -eq 'FAIL' -and -not $WhatIfPreference) { Complete-Run }
    if ($steps.Count -gt 0 -and (Confirm-Step -Target $names.TierGroup -What "Remove the $($steps.Count) items above" -Force:$Force)) {
      if (@($steps | Where-Object Kind -eq 'HostRunCommand').Count -gt 0) {
        $global:LASTEXITCODE = 0
        Sync-LiquidwareHosts.ps1 -NamePrefix $NamePrefix -Environment $Environment -Component ProfileUnity -Action Cleanup -SubscriptionId $SubscriptionId -ReportDirectory $reportDir -Force:$Force
      }
      foreach ($st in $steps) {
        try {
          switch ($st.Kind) {
            'HostRunCommand' { Remove-AzVMRunCommand -ResourceGroupName $st.ResourceGroup -VMName $st.Parent -RunCommandName $st.Name }
            'DcrAssociation' { Remove-AzResource -ResourceId $st.ResourceId -Force }
            'HostRoleAssignment' { Remove-AzRoleAssignment -ObjectId $st.Parent -RoleDefinitionName $st.Name -Scope $st.Scope }
            'Peering' { Remove-AzVirtualNetworkPeering -Name $st.Name -VirtualNetworkName $st.Parent -ResourceGroupName $st.ResourceGroup -Force }
            'DnsLink' { Remove-AzPrivateDnsVirtualNetworkLink -ResourceId $st.ResourceId }
            'PortabilityShare' { Remove-AzResource -ResourceId $st.ResourceId -Force }
            'ResourceGroup' {
              Write-Host "Removing $($st.Name) (this takes several minutes) ..."
              $null = Remove-AzResourceGroup -Name $st.Name -Force
            }
          }
          Add-Result (Get-LwCheckResult PASS 'cleanup-step' "Removed $($st.Kind) $($st.Name)" -Category Cleanup)
        }
        catch {
          Add-Result (Get-LwCheckResult FAIL 'cleanup-step' "$($st.Kind) $($st.Name): $($_.Exception.Message)" -Recommendation 'Run Cleanup again.' -Category Cleanup)
        }
      }
      $after = Read-TierLeftover
      Add-Result (Get-LwTeardownCheck -Names $names -TierGroupExists $after.TierGroupExists -Peering $after.Peering -DnsLink $after.DnsLink `
          -HostRunCommand $after.HostRunCommand -DcrAssociation $after.DcrAssociation -HostRoleAssignment $after.HostRoleAssignment `
          -PortabilityShare $after.PortabilityShare -RemoveUserData:$RemoveUserData)
      Add-Result (Get-LwCheckResult INFO 'key-vault' 'The tier Key Vault stays soft-deleted for 7 days (purge protection); a Deploy in that time recovers it.' -Category Cleanup)
      Add-Result (Get-LwCheckResult WARN 'entra-kerberos-app' 'Entra Kerberos may leave an app registration named [Storage Account] <config account>.file.core.windows.net (unconfirmed).' -Recommendation 'Look for it in Entra app registrations and delete it if it outlived the account.' -Category Cleanup)
    }
  }
  Complete-Run
}

Add-Result (Get-LwLandingZoneCheck -LandingZone $lz)
if (@($lz.VnetAddressPrefixes).Count -gt 0) {
  Add-Result (Get-LwAddressCheck -TierAddressPrefix $TierAddressPrefix -LandingZone $lz)
}

if ($Action -eq 'Plan') {
  $enableBackupCost = ($Environment -in 'test', 'prod')
  $costEst = Get-LwCostEstimate -Location $(if ($lz.Location) { $lz.Location } else { 'centralus' }) -QueryRetailApi `
    -Component $Component -Portability:$Portability -Packaging:$Packaging -Backup:$enableBackupCost
  foreach ($cl in $costEst.Lines) {
    Add-Result (Get-LwCheckResult INFO 'cost-estimate' $cl.Detail -Category Cost)
  }
}

if ($Component -contains 'Stratusphere' -and @($lz.Missing).Count -eq 0) {
  $ssux = Get-LwStratusphereArgument -LandingZone $lz -Engine $Engine -Bastion:$Bastion
  $line = ($ssux.GetEnumerator() | ForEach-Object { if ($_.Value -is [bool]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $($_.Value)" } }) -join ' '
  Add-Result (Get-LwCheckResult INFO 'stratusphere-arguments' "stratusphere/scripts/ops/Test-StratusphereReadiness.ps1 $line" -Category Stratusphere)
  Add-Result (Get-LwStratusphereWindowCheck -WindowEnd $WindowEnd)
  $deploySsux = @{}
  foreach ($k in $ssux.Keys) { if ($k -notin 'HostPoolName', 'HostPoolResourceGroup') { $deploySsux[$k] = $ssux[$k] } }
  switch ($Action) {
    'Plan' {
      $global:LASTEXITCODE = 0
      Test-StratusphereReadiness.ps1 @ssux -OutputPath $reportDir
      $readinessCode = $LASTEXITCODE
      $global:LASTEXITCODE = 0
      Deploy-Stratusphere.ps1 @deploySsux -Action Plan -OutputPath $reportDir -WhatIf:$WhatIfPreference
      $status = $(if ($readinessCode -eq 0 -and $LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })
      Add-Result (Get-LwCheckResult $status 'stratusphere-plan' 'Test-StratusphereReadiness.ps1 and Deploy-Stratusphere.ps1 -Action Plan completed.' -Category Stratusphere)
    }
    'Check' {
      $global:LASTEXITCODE = 0
      Test-StratusphereReadiness.ps1 @ssux -OutputPath $reportDir
      $readinessCode = $LASTEXITCODE
      $global:LASTEXITCODE = 0
      Deploy-Stratusphere.ps1 @deploySsux -Action Check -OutputPath $reportDir
      $status = $(if ($readinessCode -eq 0 -and $LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })
      Add-Result (Get-LwCheckResult $status 'stratusphere-check' 'Test-StratusphereReadiness.ps1 and Deploy-Stratusphere.ps1 -Action Check completed.' -Category Stratusphere)
    }
    'Deploy' {
      $global:LASTEXITCODE = 0
      Test-StratusphereReadiness.ps1 @ssux -OutputPath $reportDir
      if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Deploy-Stratusphere.ps1 @deploySsux -Action Deploy -Force:$Force -OutputPath $reportDir -WhatIf:$WhatIfPreference
      }
      Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'stratusphere-deploy' 'Test-StratusphereReadiness.ps1 and Deploy-Stratusphere.ps1 -Action Deploy completed.' -Category Stratusphere)
    }
    'Configure' {
      $global:LASTEXITCODE = 0
      Deploy-CidKey.ps1 -HostPoolName $ssux.HostPoolName -HostPoolResourceGroup $ssux.HostPoolResourceGroup -Action Install -HubAddress $HubAddress -InstallerUrl $InstallerUrl -InstallerSha256 $InstallerSha256 -Force:$Force -OutputPath $reportDir
      Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'stratusphere-configure' "Deploy-CidKey.ps1 -Action Install on $($ssux.HostPoolName) completed." -Category Stratusphere)
    }
    'Fix' {
      $global:LASTEXITCODE = 0
      Test-StratusphereReadiness.ps1 @ssux -Fix -OutputPath $reportDir
      $readinessCode = $LASTEXITCODE
      $global:LASTEXITCODE = 0
      Deploy-Stratusphere.ps1 @deploySsux -Action Fix -Force:$Force -OutputPath $reportDir -WhatIf:$WhatIfPreference
      $status = $(if ($readinessCode -eq 0 -and $LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' })
      Add-Result (Get-LwCheckResult $status 'stratusphere-fix' 'Test-StratusphereReadiness.ps1 -Fix and Deploy-Stratusphere.ps1 -Action Fix completed.' -Category Stratusphere)
    }
  }
}

if ($Component -contains 'CommandCTRL' -and @($lz.Missing).Count -eq 0 -and $Action -in 'Check', 'Configure') {
  $global:LASTEXITCODE = 0
  Sync-LiquidwareHosts.ps1 -NamePrefix $NamePrefix -Environment $Environment -Component CommandCTRL -Action $Action -SubscriptionId $SubscriptionId -ReportDirectory $reportDir -Force:$Force -WhatIf:$WhatIfPreference
  Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) "commandctrl-$($Action.ToLower())" "Sync-LiquidwareHosts.ps1 -Component CommandCTRL -Action $Action completed." -Category CommandCTRL)
}

if ($profileUnity -and $Action -eq 'Configure' -and @($results | Where-Object Status -eq 'FAIL').Count -eq 0) {
  $global:LASTEXITCODE = 0
  Sync-LiquidwareHosts.ps1 -NamePrefix $NamePrefix -Environment $Environment -Component ProfileUnity -Action Configure -SubscriptionId $SubscriptionId -ReportDirectory $reportDir -Force:$Force -WhatIf:$WhatIfPreference
  Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'host-configure' 'Sync-LiquidwareHosts.ps1 -Component ProfileUnity -Action Configure completed.' -Category ProfileUnity)
}

if ($profileUnity -and $Action -eq 'Promote' -and @($results | Where-Object Status -eq 'FAIL').Count -eq 0) {
  if ($Component -contains 'ProfileUnity') {
    $ts = $(if ($PromoteTimestamp) { $PromoteTimestamp } else { (Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ') })
    $global:LASTEXITCODE = 0
    Publish-ProfileUnityConfig.ps1 -NamePrefix $NamePrefix -Environment $Environment -ConfigName $ConfigName -Promote $ts -Ring $Ring -StagedIniSha256 $StagedIniSha256 -ExportPath $ExportPath -SubscriptionId $SubscriptionId -ReportDirectory $reportDir -Force:$Force -WhatIf:$WhatIfPreference
    Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'promote-config' "Publish-ProfileUnityConfig.ps1 ($ConfigName -> $Ring) completed." -Category Promote)
  }
  if ($Component -contains 'FlexApp') {
    $appName = $(if ($App) { $App } else { 'default' })
    $appVer = $(if ($Version) { $Version } else { '1.0.0' })
    $global:LASTEXITCODE = 0
    Set-FlexAppAssignment.ps1 -NamePrefix $NamePrefix -Environment $Environment -App $appName -Version $appVer -Ring $Ring -SubscriptionId $SubscriptionId -ReportDirectory $reportDir -WhatIf:$WhatIfPreference
    Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'promote-flexapp' "Set-FlexAppAssignment.ps1 ($appName $appVer -> $Ring) completed." -Category FlexApp)
  }
}

if ($profileUnity -and $Action -in 'Check', 'Fix' -and @($results | Where-Object Status -eq 'FAIL').Count -eq 0) {
  if ($groups -notcontains $names.TierGroup) {
    if ($Action -eq 'Check') {
      Add-Result (Get-LwCheckResult FAIL 'tier-group' "Resource group $($names.TierGroup) not found." -Recommendation 'Run Deploy-LiquidwareTier.ps1 -Action Deploy or Fix.' -Category ProfileUnity)
    }
    else {
      Add-Result (Get-LwCheckResult WARN 'tier-group' "Resource group $($names.TierGroup) not found; Fix will deploy the tier template." -Category ProfileUnity)
    }
  }
  else {
    $vmStatus = $(try { Get-AzVM -ResourceGroupName $names.TierGroup -Name $names.ConsoleVm -Status -ErrorAction Stop } catch { $null })
    if (-not $vmStatus) {
      if ($Action -eq 'Check') {
        Add-Result (Get-LwCheckResult FAIL 'console-vm' "Console VM $($names.ConsoleVm) not found in $($names.TierGroup)." -Recommendation 'Run Deploy-LiquidwareTier.ps1 -Action Fix or Deploy.' -Category ProfileUnity)
      }
      else {
        Add-Result (Get-LwCheckResult WARN 'console-vm' "Console VM $($names.ConsoleVm) not found; Fix will redeploy the tier template." -Category ProfileUnity)
      }
    }
    else {
      $power = @($vmStatus.Statuses | Where-Object Code -like 'PowerState/*').Code
      if ($power -ne 'PowerState/running') {
        if ($Action -eq 'Check') {
          Add-Result (Get-LwCheckResult WARN 'console-power' "$($names.ConsoleVm) is $power." -Recommendation 'Start the console VM or run Deploy-LiquidwareTier.ps1 -Action Fix.' -Category ProfileUnity)
        }
        elseif (Confirm-Step -Target $names.ConsoleVm -What 'Start stopped console VM' -Force:$Force) {
          $null = Start-AzVM -ResourceGroupName $names.TierGroup -Name $names.ConsoleVm
          Add-Result (Get-LwCheckResult PASS 'console-fix' "Started $($names.ConsoleVm)." -Category ProfileUnity)
        }
      }
      else {
        Add-Result (Get-LwCheckResult PASS 'console-power' "$($names.ConsoleVm) is running." -Category ProfileUnity)
      }
    }
  }
  $global:LASTEXITCODE = 0
  Sync-LiquidwareHosts.ps1 -NamePrefix $NamePrefix -Environment $Environment -Component ProfileUnity -Action Check -SubscriptionId $SubscriptionId -ReportDirectory $reportDir
  if ($LASTEXITCODE -ne 0) {
    if ($Action -eq 'Check') {
      Add-Result (Get-LwCheckResult FAIL 'host-check' 'One or more session hosts are unconfigured or unhealthy.' -Recommendation 'Run Deploy-LiquidwareTier.ps1 -Action Fix or Configure.' -Category ProfileUnity)
    }
    else {
      Add-Result (Get-LwCheckResult WARN 'host-check' 'Session hosts need repair; running Sync-LiquidwareHosts.ps1 -Action Configure ...' -Category ProfileUnity)
      $global:LASTEXITCODE = 0
      Sync-LiquidwareHosts.ps1 -NamePrefix $NamePrefix -Environment $Environment -Component ProfileUnity -Action Configure -SubscriptionId $SubscriptionId -ReportDirectory $reportDir -Force:$Force -WhatIf:$WhatIfPreference
      Add-Result (Get-LwCheckResult $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }) 'host-fix' 'Sync-LiquidwareHosts.ps1 -Action Configure completed.' -Category ProfileUnity)
    }
  }
  else {
    Add-Result (Get-LwCheckResult PASS 'host-check' 'Session hosts passed Sync-LiquidwareHosts.ps1 -Action Check.' -Category ProfileUnity)
  }
}

if ($profileUnity -and $Action -in 'Plan', 'Deploy', 'Fix' -and @($results | Where-Object Status -eq 'FAIL').Count -eq 0) {
  Write-Host 'Reading the users group and the Azure Virtual Desktop service principals ...'
  $assignments = @(Get-AzRoleAssignment -Scope $lz.ProfilesAccountId | ForEach-Object {
      [pscustomobject]@{ ObjectId = $_.ObjectId; ObjectType = $_.ObjectType; RoleDefinitionName = $_.RoleDefinitionName }
    })
  $users = Get-LwUsersGroup -RoleAssignment $assignments -Override $UsersGroupId
  Add-Result $users.Result
  # Azure Virtual Desktop and Azure Virtual Desktop ARM Provider: Microsoft's application IDs, the same in every tenant.
  $avd = @('9cdead84-a844-4324-93f2-b2e6bb768d07', '50e95039-b200-4007-bc97-8d5790743a63' | ForEach-Object {
      (Get-AzADServicePrincipal -ApplicationId $_ -ErrorAction SilentlyContinue).Id
    } | Where-Object { $_ })
  if ($avd.Count -ne 2) {
    Add-Result (Get-LwCheckResult FAIL 'avd-service-principals' "Found $($avd.Count) of the 2 Azure Virtual Desktop service principals." -Recommendation 'Register Microsoft.DesktopVirtualization; the landing zone deploy normally has.' -Category 'Landing zone')
  }
  # The operator uploads installers to media (Storage Blob Data Contributor there, for them only).
  $operator = Get-AzADUser -SignedIn -ErrorAction SilentlyContinue
  if (-not $operator -and $env:LW_OPERATOR_OBJECT_ID) {
    $operator = [pscustomobject]@{ Id = $env:LW_OPERATOR_OBJECT_ID }
  }
  if (-not $operator) {
    Add-Result (Get-LwCheckResult FAIL 'operator' 'The signed-in account is not a user, so it cannot be the media operator.' -Recommendation 'Run from Cloud Shell signed in as yourself, or set LW_OPERATOR_OBJECT_ID.' -Category 'ProfileUnity')
  }
  Write-Host 'Reading the console VM and the license secret (management plane) ...'
  $consoleVm = $null
  $licenseSecret = $null
  if ($groups -contains $names.TierGroup) {
    $vm = $(try { Get-AzVM -ResourceGroupName $names.TierGroup -Name $names.ConsoleVm -ErrorAction Stop } catch { $null })
    if ($vm) { $consoleVm = [pscustomobject]@{ Name = $vm.Name; PrincipalId = $(if ($vm.Identity) { $vm.Identity.PrincipalId } else { '' }) } }
    $vault = @(Get-AzResource -ResourceGroupName $names.TierGroup -ResourceType 'Microsoft.KeyVault/vaults') | Select-Object -First 1
    if ($vault) { $licenseSecret = $(try { Get-AzResource -ResourceId "$($vault.ResourceId)/secrets/lw-licstr" -ErrorAction Stop } catch { $null }) }
  }
  $removed = @(Get-AzKeyVault -InRemovedState -ErrorAction SilentlyContinue | ForEach-Object {
      [pscustomobject]@{ VaultName = $_.VaultName; Location = $_.Location; ScheduledPurgeDate = $_.ScheduledPurgeDate }
    })
  $deleted = Get-LwDeletedVault -Names $names -Removed $removed
  Add-Result $deleted.Result
  $state = Get-LwTierState -Console $consoleVm -LicenseSecret $licenseSecret
  Add-Result $state.Result
  if ($operator -and $users.ObjectId -and $avd.Count -eq 2 -and @($results | Where-Object Status -eq 'FAIL').Count -eq 0) {
    $password = $(if (-not $state.ConsoleExists) { Get-LwGeneratedPassword } else { $null })
    $pkgPassword = $(if ($Packaging) { Get-LwGeneratedPassword } else { $null })
    $enableBackup = ($Environment -in 'test', 'prod')
    $params = Get-LwTemplateParameter -LandingZone $lz -TierAddressPrefix $TierAddressPrefix -UsersGroupObjectId $users.ObjectId -AvdServicePrincipalObjectId $avd `
      -OperatorObjectId $operator.Id -TierState $state -ConsoleAdminPassword $password -Bastion:$Bastion `
      -Portability:$Portability -ApplicationRestrictions:$ApplicationRestrictions -Packaging:$Packaging -PackagingAdminPassword $pkgPassword -Backup:$enableBackup
    $templateParams = @{}
    foreach ($k in $params.Keys) {
      $v = $params[$k]
      if ($v -is [securestring]) { $v = [System.Net.NetworkCredential]::new('', $v).Password }
      elseif ($null -eq $v) { $v = '' }
      $templateParams[$k] = $v
    }
    $deployment = $null
    $mediaAccountOut = ''
    if ($Engine -eq 'Terraform') {
      if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        Add-Result (Get-LwCheckResult FAIL 'terraform-cli' 'The Terraform CLI is not on PATH.' -Recommendation 'Install Terraform (>= 1.9) or use -Engine Bicep.' -Category ProfileUnity)
      }
      else {
        $tfDir = Join-Path $PSScriptRoot '../profileunity/terraform'
        $tfVars = @{}
        foreach ($k in $templateParams.Keys) {
          if ($k -in 'consoleAdminPassword', 'packagingAdminPassword') { continue }
          $tfVars[$k] = $templateParams[$k]
        }
        $varFile = Join-Path ([System.IO.Path]::GetTempPath()) "lw-tf-$PID.tfvars.json"
        $tfVars | ConvertTo-Json -Depth 5 | Set-Content -Path $varFile -Encoding utf8NoBOM -WhatIf:$false
        try {
          $env:TF_VAR_consoleAdminPassword = [string]$templateParams['consoleAdminPassword']
          $env:TF_VAR_packagingAdminPassword = [string]$templateParams['packagingAdminPassword']
          Write-Host 'Running terraform init and plan on profileunity/terraform (read-only) ...'
          & terraform "-chdir=$tfDir" init -input=false | Out-Null
          if ($LASTEXITCODE -ne 0) {
            Add-Result (Get-LwCheckResult FAIL 'terraform-init' 'terraform init failed in profileunity/terraform.' -Recommendation 'Check network access to registry.terraform.io.' -Category 'Plan')
          }
          else {
            & terraform "-chdir=$tfDir" plan -input=false "-var-file=$varFile"
            if ($LASTEXITCODE -ne 0) {
              Add-Result (Get-LwCheckResult FAIL 'terraform-plan' 'terraform plan failed on profileunity/terraform.' -Recommendation 'Review the Terraform plan output above.' -Category 'Plan')
            }
            else {
              Add-Result (Get-LwCheckResult INFO 'terraform-plan' 'terraform plan succeeded on profileunity/terraform.' -Category 'Plan')
            }
          }
          if ($Action -in 'Deploy', 'Fix' -and @($results | Where-Object Status -eq 'FAIL').Count -eq 0 -and
            (Confirm-Step -Target $names.TierGroup -What 'Deploy the changes above (Terraform)' -Force:$Force)) {
            if ($deleted.Vault) {
              if ($groups -notcontains $names.TierGroup) { $null = New-AzResourceGroup -Name $names.TierGroup -Location $lz.Location }
              Write-Host "Recovering $($deleted.Vault.VaultName) ..."
              $null = Undo-AzKeyVaultRemoval -VaultName $deleted.Vault.VaultName -ResourceGroupName $names.TierGroup -Location $deleted.Vault.Location
            }
            Write-Host 'Applying profileunity/terraform (several minutes) ...'
            & terraform "-chdir=$tfDir" apply -auto-approve -input=false "-var-file=$varFile"
            if ($LASTEXITCODE -eq 0) {
              $deployment = [pscustomobject]@{ ProvisioningState = 'Succeeded' }
              $mediaAccountOut = (& terraform "-chdir=$tfDir" output -raw mediaAccountName 2>$null)
              Add-Result (Get-LwCheckResult PASS 'deploy' "liquidware-$($names.Base) (Terraform) succeeded." -Category ProfileUnity)
            }
            else {
              Add-Result (Get-LwCheckResult FAIL 'deploy' "liquidware-$($names.Base) (Terraform) failed." -Recommendation 'Review the Terraform apply output above, fix, then Deploy again.' -Category ProfileUnity)
            }
          }
        }
        finally {
          Remove-Item "env:TF_VAR_consoleAdminPassword" -ErrorAction SilentlyContinue
          Remove-Item "env:TF_VAR_packagingAdminPassword" -ErrorAction SilentlyContinue
          Remove-Item -LiteralPath $varFile -Force -ErrorAction SilentlyContinue
        }
      }
    }
    else {
      Write-Host 'Running what-if on profileunity/bicep/main.bicep (read-only) ...'
      $whatIf = Get-AzSubscriptionDeploymentWhatIfResult -Name "liquidware-$($names.Base)" -Location $lz.Location `
        -TemplateFile (Join-Path $PSScriptRoot '../profileunity/bicep/main.bicep') -TemplateParameterObject $templateParams
      $changes = @($whatIf.Changes | ForEach-Object { [pscustomobject]@{ ChangeType = "$($_.ChangeType)"; ResourceId = $_.FullyQualifiedResourceId } })
      $whatIfResults = @(Get-LwWhatIfSummary -Change $changes -LandingZone $lz)
      Add-Result $whatIfResults
      $hasDrift = (@($whatIfResults | Where-Object Status -eq 'INFO').Count -gt 0) -or ($groups -notcontains $names.TierGroup)

      if (($Action -eq 'Deploy' -or ($Action -eq 'Fix' -and $hasDrift)) -and @($results | Where-Object Status -eq 'FAIL').Count -eq 0 -and
        (Confirm-Step -Target $names.TierGroup -What 'Deploy the changes above' -Force:$Force)) {
        if ($deleted.Vault) {
          if ($groups -notcontains $names.TierGroup) { $null = New-AzResourceGroup -Name $names.TierGroup -Location $lz.Location }
          Write-Host "Recovering $($deleted.Vault.VaultName) ..."
          $null = Undo-AzKeyVaultRemoval -VaultName $deleted.Vault.VaultName -ResourceGroupName $names.TierGroup -Location $deleted.Vault.Location
        }
        Write-Host 'Deploying profileunity/bicep/main.bicep (several minutes) ...'
        try {
          $deployment = New-AzSubscriptionDeployment -Name "liquidware-$($names.Base)" -Location $lz.Location `
            -TemplateFile (Join-Path $PSScriptRoot '../profileunity/bicep/main.bicep') -TemplateParameterObject $templateParams
        }
        catch { Add-Result (Get-LwCheckResult FAIL 'deploy' $_.Exception.Message -Recommendation 'Read the deployment in the portal (subscription, Deployments), fix, then Deploy again.' -Category ProfileUnity) }
        if ($deployment -and $deployment.ProvisioningState -eq 'Succeeded') {
          $mediaAccountOut = $deployment.Outputs['mediaAccountName'].Value
          Add-Result (Get-LwCheckResult PASS 'deploy' "liquidware-$($names.Base) succeeded." -Category ProfileUnity)
        }
        elseif ($deployment) {
          Add-Result (Get-LwCheckResult FAIL 'deploy' "liquidware-$($names.Base) ended $($deployment.ProvisioningState)." -Recommendation 'Read the deployment in the portal, fix, then Deploy again.' -Category ProfileUnity)
        }
      }
    }
    $templateParams.Remove('consoleAdminPassword')
    $templateParams.Remove('packagingAdminPassword')
    $password = $null
    $pkgPassword = $null

    if ($deployment -and $deployment.ProvisioningState -eq 'Succeeded') {
      if (-not $MediaLockPath) { $MediaLockPath = Join-Path $PSScriptRoot '../output/media.lock.json' }
      $lock = $(if (Test-Path -LiteralPath $MediaLockPath) { Get-Content -LiteralPath $MediaLockPath -Raw | ConvertFrom-Json } else { $null })
      $entry = Get-LwMediaLockEntry -Lock $lock -Component ProfileUnityConsole
      $vmStatus = Get-AzVM -ResourceGroupName $names.TierGroup -Name $names.ConsoleVm -Status
      $power = @($vmStatus.Statuses | Where-Object Code -like 'PowerState/*').Code
      if (-not $entry) {
        Add-Result (Get-LwCheckResult WARN 'console-install' "No ProfileUnityConsole entry in $MediaLockPath." -Recommendation 'Publish the installer with Publish-LiquidwareMedia.ps1, then Deploy again.' -Category ProfileUnity)
      }
      elseif ($power -ne 'PowerState/running') {
        Add-Result (Get-LwCheckResult WARN 'console-install' "$($names.ConsoleVm) is $power; a Run Command needs it running." -Recommendation 'Start it, then Deploy again.' -Category ProfileUnity)
      }
      else {
        Write-Host "Downloading and checking $($entry.blob) on $($names.ConsoleVm) by Run Command ..."
        $rcArgs = @{ ResourceGroupName = $names.TierGroup; VMName = $names.ConsoleVm; RunCommandName = 'lw-profileunity-console' }
        try {
          $null = Set-AzVMRunCommand @rcArgs -Location $lz.Location -ScriptLocalPath (Join-Path $PSScriptRoot 'host/Install-ProfileUnityConsole.ps1') `
            -Parameter @(@{ Name = 'MediaAccountName'; Value = $mediaAccountOut }, @{ Name = 'Blob'; Value = $entry.blob }, @{ Name = 'Sha256'; Value = $entry.sha256 })
          $view = (Get-AzVMRunCommand @rcArgs -Expand InstanceView).InstanceView
          Add-Result (Get-LwRunCommandResult -Output "$($view.Output)`n$($view.Error)" -Check 'console-install')
        }
        catch { Add-Result (Get-LwCheckResult FAIL 'console-install' $_.Exception.Message -Recommendation 'Read the Run Command instance view on the console, then Deploy again.' -Category ProfileUnity) }
      }
    }
  }
}

Add-Result @($summary | Where-Object Status -ne 'FAIL')
Complete-Run
