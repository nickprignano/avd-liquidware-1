#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Guards on the compiled ProfileUnity template (docs/deploy-spec.md section 5). Offline; needs the
# Bicep CLI on PATH. Each guard reads the compiled ARM JSON, so a refactor can't hide a change.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  $bicep = (Get-Command bicep -ErrorAction Stop).Source
  # Warnings go to stderr; keep them out of the JSON (CI's lint step reports them).
  $stderr = Join-Path ([System.IO.Path]::GetTempPath()) "bicep-build-$PID.txt"
  $raw = & $bicep build (Join-Path $script:root 'profileunity/bicep/main.bicep') --stdout 2>$stderr
  if ($LASTEXITCODE -ne 0) { throw "bicep build failed: $(Get-Content $stderr -Raw)" }
  Remove-Item $stderr -ErrorAction SilentlyContinue
  $script:main = ($raw -join "`n") | ConvertFrom-Json -Depth 100 -AsHashtable

  # Every resource in a template and its nested deployments, with the template it sits in.
  function Get-TemplateResource($Template, [string] $Deployment = 'main') {
    $list = $Template['resources']
    $items = $(if ($list -is [System.Collections.IDictionary]) { @($list.GetEnumerator() | ForEach-Object { @{ Key = $_.Key; Value = $_.Value } }) } else { @($list | ForEach-Object { @{ Key = $_['name']; Value = $_ } }) })
    foreach ($i in $items) {
      $r = $i.Value
      [pscustomobject]@{ Deployment = $Deployment; Symbol = $i.Key; Type = $r['type']; Resource = $r; Template = $Template }
      if ($r['type'] -eq 'Microsoft.Resources/deployments' -and -not $r['existing']) {
        Get-TemplateResource $r['properties']['template'] $r['name']
      }
    }
  }
  $script:all = @(Get-TemplateResource $script:main)
  $script:tier = ($script:all | Where-Object { $_.Deployment -eq 'main' -and $_.Resource['name'] -eq 'liquidware-tier' }).Resource['properties']['template']
  $script:spoke = ($script:all | Where-Object { $_.Deployment -eq 'main' -and $_.Resource['name'] -eq 'liquidware-spoke' }).Resource
  function Get-TierResource([string] $Symbol) { $script:tier['resources'][$Symbol] }
  $script:roles = $script:tier['variables']['roles']
  function Get-Module([string] $Name) { ($script:all | Where-Object { $_.Deployment -eq 'main' -and $_.Resource['name'] -eq $Name }).Resource }
  function Get-ModuleResource([string] $Name) { @($script:all | Where-Object { $_.Deployment -eq $Name -and -not $_.Resource['existing'] }) }
  # Built-in role definition IDs, the same in every tenant. Any other role in the template fails a test.
  $script:builtIn = @{
    'aba4ae5f-2193-4029-9191-0cb91df5e314' = 'Storage File Data SMB Share Reader'
    '69566ab7-960f-475b-8e7c-b3118f30c6bd' = 'Storage File Data Privileged Contributor'
    'c12c1c16-33a1-487b-954d-41c89c60f349' = 'Reader and Data Access'
    'ba92f5b4-2d11-453d-a403-e96b0029c9fe' = 'Storage Blob Data Contributor'
    '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' = 'Storage Blob Data Reader'
    '4633458b-17de-408a-b874-0445c86b69e6' = 'Key Vault Secrets User'
  }
  # The role an assignment grants, by name, resolved through its own template's roles variable.
  function Get-RoleName($a) {
    if ($a.Resource['properties']['roleDefinitionId'] -match "variables\('roles'\)\.(\w+)") { $script:builtIn[$a.Template['variables']['roles'][$Matches[1]]] }
  }
}

Describe 'Landing zone writes' {
  It 'deploys to the landing zone only the peering and the DNS links, as child resources' {
    $script:spoke['resourceGroup'] | Should -Match "variables\('spokeResourceGroup'\)"
    $types = @($script:all | Where-Object Deployment -eq 'liquidware-spoke' | Where-Object { -not $_.Resource['existing'] } | ForEach-Object Type | Sort-Object)
    $types | Should -Be @(
      'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
      'Microsoft.Network/privateDnsZones/virtualNetworkLinks'
      'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
    )
  }
  It 'never deploys the profiles account, a DNS zone or a VNet outside the tier' {
    $script:all | Where-Object Type -eq 'Microsoft.Network/privateDnsZones' | Where-Object { -not $_.Resource['existing'] } | Should -BeNullOrEmpty
    @($script:all | Where-Object { $_.Type -eq 'Microsoft.Storage/storageAccounts' -and $_.Deployment -eq 'liquidware-tier' } | ForEach-Object Symbol | Sort-Object) | Should -Be @('configAccount', 'packagesAccount')
    @(Get-ModuleResource 'liquidware-media' | Where-Object Type -eq 'Microsoft.Storage/storageAccounts').Count | Should -Be 1
    @($script:all | Where-Object { $_.Type -eq 'Microsoft.Storage/storageAccounts' -and -not $_.Resource['existing'] }).Count | Should -Be 3
    ($script:all | Where-Object { $_.Type -eq 'Microsoft.Storage/storageAccounts' -and $_.Resource['kind'] -ne 'StorageV2' }) | Should -BeNullOrEmpty
    @($script:all | Where-Object { $_.Type -eq 'Microsoft.Network/virtualNetworks' -and -not $_.Resource['existing'] }).Count | Should -Be 1
  }
  It 'peers without forwarded or gateway traffic, both ways' {
    $peerings = @($script:all | Where-Object Type -eq 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings')
    $peerings.Count | Should -Be 2
    foreach ($p in $peerings) {
      $p.Resource['properties']['allowForwardedTraffic'] | Should -BeFalse
      $p.Resource['properties']['allowGatewayTransit'] | Should -BeFalse
      $p.Resource['properties']['useRemoteGateways'] | Should -BeFalse
    }
  }
}

Describe 'Live config account' {
  It 'has shared key off, Entra Kerberos and no public access' {
    $p = (Get-TierResource 'configAccount')['properties']
    $p['allowSharedKeyAccess'] | Should -BeFalse
    $p['publicNetworkAccess'] | Should -Be 'Disabled'
    $p['azureFilesIdentityBasedAuthentication']['directoryServiceOptions'] | Should -Be 'AADKERB'
    $p['azureFilesIdentityBasedAuthentication']['defaultSharePermission'] | Should -Be 'None'
  }
  It "uses the profiles account's SMB settings, without multichannel" {
    (Get-TierResource 'configFiles')['properties']['protocolSettings']['smb'] | Should -Be "[variables('smbHardened')]"
    $smb = $script:tier['variables']['smbHardened']
    $smb['versions'] | Should -Be 'SMB3.1.1'
    $smb['authenticationMethods'] | Should -Be 'Kerberos'
    $smb['kerberosTicketEncryption'] | Should -Be 'AES-256'
    $smb['channelEncryption'] | Should -Be 'AES-128-GCM;AES-256-GCM'
    $smb.Keys | Should -Not -Contain 'multichannel'
  }
  It 'has one share, lwconfig' {
    @($script:all | Where-Object { $_.Type -eq 'Microsoft.Storage/storageAccounts/fileServices/shares' -and $_.Resource['name'] -match "configAccountName" } | ForEach-Object { $_.Resource['name'] }) |
      Should -Be @("[format('{0}/{1}/{2}', variables('configAccountName'), 'default', 'lwconfig')]")
  }
}

Describe 'Role assignments' {
  BeforeAll {
    $script:assignments = @($script:all | Where-Object Type -eq 'Microsoft.Authorization/roleAssignments')
    function Get-RoleKey($a) { if ($a.Resource['properties']['roleDefinitionId'] -match "variables\('roles'\)\.(\w+)") { $Matches[1] } }
  }
  It 'uses the built-in role IDs the spec names' {
    $script:roles['smbShareReader'] | Should -Be 'aba4ae5f-2193-4029-9191-0cb91df5e314'
    $script:roles['filePrivilegedContributor'] | Should -Be '69566ab7-960f-475b-8e7c-b3118f30c6bd'
    $script:roles['readerAndDataAccess'] | Should -Be 'c12c1c16-33a1-487b-954d-41c89c60f349'
  }
  It 'gives every assignment a known built-in role, so none goes unchecked' {
    foreach ($a in $script:assignments) { Get-RoleName $a | Should -Not -BeNullOrEmpty -Because $a.Symbol }
  }
  It 'gives no assignment to a user other than the operator: media, and the console password secret only' {
    $users = @($script:assignments | Where-Object { $_.Resource['properties']['principalType'] -eq 'User' })
    $users.Count | Should -Be 2
    foreach ($u in $users) { $u.Resource['properties']['principalId'] | Should -Be "[parameters('operatorObjectId')]" }
    $onMedia = @($users | Where-Object Deployment -eq 'liquidware-media')
    $onMedia.Count | Should -Be 1
    $onMedia[0].Resource['scope'] | Should -Match "'media'\)\]$"
    $onSecret = @($users | Where-Object Deployment -eq 'liquidware-console-access')
    $onSecret.Count | Should -Be 1
    Get-RoleName $onSecret[0] | Should -Be 'Key Vault Secrets User'
    $onSecret[0].Resource['scope'] | Should -Match "'lw-console-password'\)\]$"
  }
  It 'gives the users group read on the live config account and nothing else (tier N-C1)' {
    $groups = @($script:assignments | Where-Object { $_.Resource['properties']['principalType'] -eq 'Group' })
    $groups.Count | Should -Be 1
    Get-RoleKey $groups[0] | Should -Be 'smbShareReader'
    $groups[0].Resource['scope'] | Should -Match "variables\('configAccountName'\)"
  }
  It 'lets only the ops runner write the live config account' {
    $writers = @($script:assignments | Where-Object { (Get-RoleKey $_) -eq 'filePrivilegedContributor' })
    $writers.Count | Should -Be 1
    $writers[0].Resource['properties']['principalId'] | Should -Be "[reference('opsIdentity').principalId]"
    (Get-TierResource 'opsIdentity')['type'] | Should -Be 'Microsoft.ManagedIdentity/userAssignedIdentities'
  }
  It 'gives the packages account only Reader and Data Access, only to service principals' {
    $onPackages = @($script:assignments | Where-Object { $_.Resource['scope'] -match "variables\('packagesAccountName'\)" })
    $onPackages.Count | Should -Be 1
    Get-RoleKey $onPackages[0] | Should -Be 'readerAndDataAccess'
    $onPackages[0].Resource['properties']['principalType'] | Should -Be 'ServicePrincipal'
    $onPackages[0].Resource['properties']['principalId'] | Should -Match "parameters\('avdServicePrincipalObjectIds'\)"
  }
}

Describe 'Packages account' {
  It 'has one share, appattach, and no blob container' {
    @($script:all | Where-Object { $_.Type -eq 'Microsoft.Storage/storageAccounts/fileServices/shares' -and $_.Resource['name'] -match 'packagesAccountName' }).Count | Should -Be 1
    (Get-TierResource 'packagesShare')['name'] | Should -Match "'appattach'"
    $script:all | Where-Object { $_.Type -like 'Microsoft.Storage/storageAccounts/blobServices*' -and $_.Deployment -notin 'liquidware-media', 'liquidware-console-access' } | Should -BeNullOrEmpty
  }
  It 'is reached only through its private endpoint' {
    (Get-TierResource 'packagesAccount')['properties']['publicNetworkAccess'] | Should -Be 'Disabled'
    (Get-TierResource 'packagesAccount')['properties']['allowBlobPublicAccess'] | Should -BeFalse
  }
}

Describe 'Media account' {
  BeforeAll { $script:mediaAccount = (Get-ModuleResource 'liquidware-media' | Where-Object Type -eq 'Microsoft.Storage/storageAccounts').Resource }
  It 'has shared key and anonymous access off, and an Entra-only public endpoint (fork F4)' {
    $p = $script:mediaAccount['properties']
    $p['allowSharedKeyAccess'] | Should -BeFalse
    $p['allowBlobPublicAccess'] | Should -BeFalse
    $p['defaultToOAuthAuthentication'] | Should -BeTrue
  }
  It 'has two private containers, media and staging, and no file share' {
    $c = @(Get-ModuleResource 'liquidware-media' | Where-Object Type -eq 'Microsoft.Storage/storageAccounts/blobServices/containers')
    @($c | ForEach-Object { ($_.Resource['name'] -split "'")[-2] } | Sort-Object) | Should -Be @('media', 'staging')
    foreach ($x in $c) { $x.Resource['properties']['publicAccess'] | Should -Be 'None' }
    Get-ModuleResource 'liquidware-media' | Where-Object Type -like '*fileServices*' | Should -BeNullOrEmpty
  }
  It 'lets the ops runner only read staging' {
    $ops = @($script:all | Where-Object { $_.Type -eq 'Microsoft.Authorization/roleAssignments' -and $_.Resource['properties']['principalId'] -eq "[parameters('opsPrincipalId')]" })
    $ops.Count | Should -Be 1
    Get-RoleName $ops[0] | Should -Be 'Storage Blob Data Reader'
    $ops[0].Resource['scope'] | Should -Match "'staging'\)\]$"
  }
}

Describe 'Console' {
  BeforeAll {
    $script:vm = (Get-ModuleResource 'liquidware-console' | Where-Object Type -eq 'Microsoft.Compute/virtualMachines').Resource
    $script:consoleModule = Get-Module 'liquidware-console'
  }
  It 'has Trusted Launch and encryption at host, like every VM in the template' {
    $vms = @($script:all | Where-Object { $_.Type -eq 'Microsoft.Compute/virtualMachines' -and -not $_.Resource['existing'] })
    $vms.Count | Should -Be 2
    foreach ($v in $vms) {
      $sp = $v.Resource['properties']['securityProfile']
      $sp['securityType'] | Should -Be 'TrustedLaunch'
      $sp['uefiSettings']['secureBootEnabled'] | Should -BeTrue
      $sp['uefiSettings']['vTpmEnabled'] | Should -BeTrue
      $sp['encryptionAtHost'] | Should -BeTrue
    }
  }
  It 'is Windows Server 2025 Azure Edition on the smallest size the spec allows, with a static private IP and no public IP' {
    $p = $script:vm['properties']
    $p['storageProfile']['imageReference']['sku'] | Should -Be '2025-datacenter-azure-edition'
    $script:vm['identity']['type'] | Should -Be 'SystemAssigned'
    (Get-ModuleResource 'liquidware-console' | Where-Object Type -eq 'Microsoft.Compute/virtualMachines').Template['parameters']['vmSize']['defaultValue'] | Should -Be 'Standard_D2as_v5'
    $ip = (Get-ModuleResource 'liquidware-console' | Where-Object Type -eq 'Microsoft.Network/networkInterfaces').Resource['properties']['ipConfigurations'][0]['properties']
    $ip['privateIPAllocationMethod'] | Should -Be 'Static'
    $ip.Keys | Should -Not -Contain 'publicIPAddress'
    $script:tier['outputs']['consolePrivateIp']['value'] | Should -Be "[cidrHost(variables('subnets').console, 3)]"
  }
  It 'takes its password as a secure parameter and writes it only to the tier Key Vault' {
    $t = (Get-ModuleResource 'liquidware-console' | Select-Object -First 1).Template
    $t['parameters']['adminPassword']['type'] | Should -Be 'securestring'
    $script:main['parameters']['consoleAdminPassword']['type'] | Should -Be 'securestring'
    $secret = (Get-ModuleResource 'liquidware-console' | Where-Object Type -eq 'Microsoft.KeyVault/vaults/secrets').Resource
    $secret['properties']['value'] | Should -Be "[parameters('adminPassword')]"
    ($t['outputs'].Keys) | Should -Be @('principalId')
    ($script:main['outputs'] | ConvertTo-Json -Depth 20) | Should -Not -Match 'adminPassword|consoleAdminPassword'
  }
  It 'is created only when it does not exist yet, so a rerun keeps its password (lesson 0002)' {
    $script:consoleModule['condition'] | Should -Be "[not(parameters('consoleExists'))]"
  }
  It 'shuts down daily outside prod' {
    $s = (Get-ModuleResource 'liquidware-console' | Where-Object Type -eq 'Microsoft.DevTestLab/schedules').Resource
    $s['condition'] | Should -Be "[not(equals(parameters('environment'), 'prod'))]"
    $s['properties']['taskType'] | Should -Be 'ComputeVmShutdownTask'
  }
}

Describe 'Console identity' {
  BeforeAll {
    $script:consoleRoles = @(Get-ModuleResource 'liquidware-console-access' | Where-Object { $_.Type -eq 'Microsoft.Authorization/roleAssignments' -and $_.Resource['properties']['principalId'] -eq "[parameters('consolePrincipalId')]" })
  }
  It 'reads media, writes staging and reads one secret, and nothing else' {
    $script:consoleRoles.Count | Should -Be 3
    @($script:assignments | Where-Object { $_.Resource['properties']['principalId'] -eq "[parameters('consolePrincipalId')]" }).Count | Should -Be 3
    $byName = @{}
    foreach ($r in $script:consoleRoles) { $byName[(Get-RoleName $r)] = $r.Resource }
    $byName['Storage Blob Data Reader']['scope'] | Should -Match "'media'\)\]$"
    $byName['Storage Blob Data Contributor']['scope'] | Should -Match "'staging'\)\]$"
    $byName['Key Vault Secrets User']['scope'] | Should -Match "'lw-licstr'\)\]$"
    $byName['Key Vault Secrets User']['condition'] | Should -Be "[parameters('licenseStored')]"
  }
  It 'has no role on the live config account' {
    foreach ($r in $script:consoleRoles) { $r.Resource['scope'] | Should -Not -Match 'configAccount|lwc' }
  }
}

Describe 'Key Vault' {
  It 'is RBAC-only, purge protected and private' {
    $p = (Get-TierResource 'keyVault')['properties']
    $p['enableRbacAuthorization'] | Should -BeTrue
    $p['enablePurgeProtection'] | Should -BeTrue
    $p['publicNetworkAccess'] | Should -Be 'Disabled'
  }
}

Describe 'Network' {
  It 'denies outbound to the spoke from the console and packaging subnets, except its private endpoints' {
    $out = $script:tier['variables']['outboundToSpoke']
    $out[0]['properties']['access'] | Should -Be 'Allow'
    $out[0]['properties']['destinationAddressPrefix'] | Should -Be "[parameters('spokePrivateEndpointSubnetPrefix')]"
    $out[1]['properties']['access'] | Should -Be 'Deny'
    $out[1]['properties']['destinationAddressPrefixes'] | Should -Be "[parameters('spokeAddressPrefixes')]"
    foreach ($n in 'consoleNsg', 'packagingNsg') {
      (Get-TierResource $n)['properties']['securityRules'] | Should -Match "variables\('outboundToSpoke'\)\)\]$" -Because $n
    }
  }
  It 'admits 443 to the console only from the session host subnet' {
    $rules = (Get-TierResource 'consoleNsg')['properties']['securityRules']
    $rules | Should -Match "'sourceAddressPrefix', parameters\('sessionHostSubnetPrefix'\)"
    $rules | Should -Match "'destinationPortRange', '443'"
  }
  It 'opens 3389 only from AzureBastionSubnet, and only with Bastion on' {
    $fn = $script:tier['functions'][0]['members']['rdpFromBastion']['output']['value']['properties']
    $fn['destinationPortRange'] | Should -Be '3389'
    $fn['access'] | Should -Be 'Allow'
    $fn['sourceAddressPrefix'] | Should -Be "[parameters('bastionPrefix')]"
    foreach ($n in 'consoleNsg', 'packagingNsg') {
      (Get-TierResource $n)['properties']['securityRules'] | Should -Match "if\(parameters\('deployBastion'\), createArray\(__bicep\.rdpFromBastion\(variables\('subnets'\)\.bastion"
    }
    ($script:tier | ConvertTo-Json -Depth 100 -Compress) -split "rdpFromBastion\(" | Select-Object -Skip 1 | ForEach-Object { $_ | Should -Match "^variables\('subnets'\)\.bastion" }
  }
  It 'has no inbound allow from the Internet or anywhere' {
    $json = $script:main | ConvertTo-Json -Depth 100 -Compress
    $json | Should -Not -Match "'sourceAddressPrefix', '(\*|Internet|0\.0\.0\.0/0)'(?:(?!createObject).)*'access', 'Allow'"
    $json | Should -Not -Match "'access', 'Allow'(?:(?!createObject).)*'sourceAddressPrefix', '(\*|Internet|0\.0\.0\.0/0)'"
  }
  It 'has one public IP, the NAT Gateway' {
    $ips = @($script:all | Where-Object Type -eq 'Microsoft.Network/publicIPAddresses')
    $ips.Count | Should -Be 1
    (Get-TierResource 'nat')['properties']['publicIpAddresses'][0]['id'] | Should -Match 'publicIPAddresses'
  }
  It 'turns default outbound access off on every subnet' {
    $subnets = (Get-TierResource 'vnet')['properties']['subnets']
    ([regex]::Matches($subnets, "createObject\('name', '(snet-lw-[a-z]+)'")).Count | Should -Be 4
    ([regex]::Matches($subnets, "'defaultOutboundAccess', false\(\)")).Count | Should -Be 4
  }
  It 'delegates the ops subnet to Container Instances' {
    (Get-TierResource 'vnet')['properties']['subnets'] | Should -Match "'snet-lw-ops'.*Microsoft\.ContainerInstance/containerGroups"
  }
}

Describe 'Private endpoints' {
  It 'gives the Key Vault and both accounts an endpoint whose zone group uses the landing zone zones' {
    $e = $script:tier['variables']['endpoints']
    @($e | ForEach-Object { $_['groupId'] }) | Should -Be @('vault', 'file', 'file')
    $e[0]['zoneId'] | Should -Be "[parameters('vaultDnsZoneId')]"
    $e[1]['zoneId'] | Should -Be "[parameters('fileDnsZoneId')]"
    $e[2]['zoneId'] | Should -Be "[parameters('fileDnsZoneId')]"
    @($script:all | Where-Object Type -eq 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups').Count | Should -Be 1
  }
}

Describe 'Portability share' {
  BeforeAll {
    $script:portabilityModule = Get-Module 'liquidware-portability'
    $script:portabilityShare = (Get-ModuleResource 'liquidware-portability' | Where-Object Type -eq 'Microsoft.Storage/storageAccounts/fileServices/shares').Resource
  }
  It 'is opt-in and deploys a 100 GiB portability share on the existing profiles storage account' {
    $script:main['parameters']['enablePortability']['defaultValue'] | Should -BeFalse
    $script:portabilityModule['condition'] | Should -Be "[and(parameters('enablePortability'), not(empty(parameters('profilesStorageAccountName'))))]"
    $script:portabilityModule['resourceGroup'] | Should -Be "[parameters('profilesResourceGroupName')]"
    $script:portabilityShare['name'] | Should -Match "'portability'"
    $script:portabilityShare['properties']['shareQuota'] | Should -Be 100
    $script:portabilityShare['properties']['enabledProtocols'] | Should -Be 'SMB'
  }
}

Describe 'Application restrictions DCR' {
  BeforeAll {
    $script:dcrModule = Get-Module 'liquidware-dcr'
    $script:dcr = (Get-ModuleResource 'liquidware-dcr' | Where-Object Type -eq 'Microsoft.Insights/dataCollectionRules').Resource
  }
  It 'is opt-in and collects Windows Event Log application restriction events into Log Analytics' {
    $script:main['parameters']['enableApplicationRestrictions']['defaultValue'] | Should -BeFalse
    $script:dcrModule['condition'] | Should -Be "[and(parameters('enableApplicationRestrictions'), not(empty(parameters('logAnalyticsWorkspaceId'))))]"
    $script:dcrModule['properties']['parameters']['dcrName']['value'] | Should -Be "[format('dcr-{0}-liquidware', variables('base'))]"
    $script:dcr['kind'] | Should -Be 'Windows'
    $script:dcr['properties']['dataSources']['windowsEventLogs'][0]['name'] | Should -Be 'lw-restrictions'
    $script:dcr['properties']['destinations']['logAnalytics'][0]['workspaceResourceId'] | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
  }
}

Describe 'Packaging VM' {
  BeforeAll {
    $script:pkgModule = Get-Module 'liquidware-packaging'
    $script:pkgVm = (Get-ModuleResource 'liquidware-packaging' | Where-Object Type -eq 'Microsoft.Compute/virtualMachines').Resource
    $script:pkgNic = (Get-ModuleResource 'liquidware-packaging' | Where-Object Type -eq 'Microsoft.Network/networkInterfaces').Resource
    $script:pkgRoles = @(Get-ModuleResource 'liquidware-packaging' | Where-Object Type -eq 'Microsoft.Authorization/roleAssignments')
  }
  It 'is opt-in, Windows 11 24H2 Enterprise single-session on Standard_D2as_v5 at static IP 10.61.0.68 with AutomaticByOS patching and no public IP' {
    $script:main['parameters']['deployPackagingVm']['defaultValue'] | Should -BeFalse
    $script:pkgModule['condition'] | Should -Be "[parameters('deployPackagingVm')]"
    $script:pkgModule['properties']['parameters']['vmName']['value'] | Should -Be "[format('vm-{0}lwpkg', variables('clean'))]"
    $script:pkgModule['properties']['parameters']['privateIp']['value'] | Should -Be '10.61.0.68'
    $script:pkgModule['properties']['parameters']['subnetId']['value'] | Should -Match "snet-lw-packaging"
    $img = $script:pkgVm['properties']['storageProfile']['imageReference']
    $img['publisher'] | Should -Be 'MicrosoftWindowsDesktop'
    $img['offer'] | Should -Be 'windows-11'
    $img['sku'] | Should -Be 'win11-24h2-ent'
    $img['version'] | Should -Be 'latest'
    $script:pkgVm['properties']['osProfile']['windowsConfiguration']['patchSettings']['patchMode'] | Should -Be 'AutomaticByOS'
    $script:pkgVm['identity']['type'] | Should -Be 'SystemAssigned'
    $ip = $script:pkgNic['properties']['ipConfigurations'][0]['properties']
    $ip['privateIPAllocationMethod'] | Should -Be 'Static'
    $ip.Keys | Should -Not -Contain 'publicIPAddress'
  }
  It 'grants its managed identity Storage Blob Data Reader on media and Storage File Data Privileged Contributor on appattach' {
    $script:pkgRoles.Count | Should -Be 2
    $byName = @{}
    foreach ($r in $script:pkgRoles) { $byName[(Get-RoleName $r)] = $r.Resource }
    $byName['Storage Blob Data Reader']['scope'] | Should -Match "'media'\)\]$"
    $byName['Storage File Data Privileged Contributor']['scope'] | Should -Match "'appattach'\)\]$"
  }
  It 'shuts down daily outside prod and keeps its password in Key Vault' {
    $s = (Get-ModuleResource 'liquidware-packaging' | Where-Object Type -eq 'Microsoft.DevTestLab/schedules').Resource
    $s['condition'] | Should -Be "[not(equals(parameters('environment'), 'prod'))]"
    $secret = (Get-ModuleResource 'liquidware-packaging' | Where-Object Type -eq 'Microsoft.KeyVault/vaults/secrets').Resource
    $secret['name'] | Should -Match "'lw-packaging-password'"
    $secret['properties']['value'] | Should -Be "[parameters('adminPassword')]"
  }
}

Describe 'Backup vault' {
  BeforeAll {
    $script:backupModule = Get-Module 'liquidware-backup'
    $script:vault = (Get-ModuleResource 'liquidware-backup' | Where-Object Type -eq 'Microsoft.RecoveryServices/vaults').Resource
    $script:policy = (Get-ModuleResource 'liquidware-backup' | Where-Object Type -eq 'Microsoft.RecoveryServices/vaults/backupPolicies').Resource
  }
  It 'is opt-in and creates rsv-<base>-liquidware with an EnhancedPolicy' {
    $script:main['parameters']['enableBackup']['defaultValue'] | Should -BeFalse
    $script:backupModule['condition'] | Should -Be "[parameters('enableBackup')]"
    $script:backupModule['properties']['parameters']['vaultName']['value'] | Should -Be "[format('rsv-{0}-liquidware', variables('base'))]"
    $script:vault['properties']['publicNetworkAccess'] | Should -Be 'Disabled'
    $script:policy['name'] | Should -Match "'EnhancedPolicy'"
    $script:policy['properties']['backupManagementType'] | Should -Be 'AzureIaasVM'
    $script:policy['properties']['policyType'] | Should -Be 'V2'
  }
}

Describe 'Entry point notice' {
  It 'carries the personal-project notice near the top' {
    (Get-Content (Join-Path $script:root 'profileunity/bicep/main.bicep') -TotalCount 6) -join "`n" | Should -Match 'Personal project, not for production use'
  }
}
