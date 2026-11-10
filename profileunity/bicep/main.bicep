// The Liquidware tier's network and storage against an existing avd-landing-zone landing zone
// (docs/deploy-spec.md sections 4 and 5, slice B2). Deploy-LiquidwareTier.ps1 discovers the
// landing zone and passes what it found; nothing here reads the landing zone by itself.
// Personal project, not for production use. Provided as is, without warranty of any kind. Not affiliated with the author's employer, with Liquidware or with Microsoft.
//
// Native resources rather than Azure Verified Modules: the template tests check every role
// assignment's scope and principal in the compiled template, which module wrappers hide.

targetScope = 'subscription'

@description('Region of the landing zone (Deploy-LiquidwareTier.ps1 passes the spoke VNet location).')
param location string

@description('The landing zone prefix (2-8 lowercase letters, digits or hyphens).')
@minLength(2)
@maxLength(8)
param namePrefix string

@allowed(['dev', 'test', 'prod'])
param environment string

@description('The tier VNet. /24 or larger; must not overlap the spoke, its peers or the Stratusphere VNet.')
param tierAddressPrefix string = '10.61.0.0/24'

@description('Resource ID of the landing zone spoke VNet (vnet-<base>).')
param spokeVnetId string

@description('The spoke address space. The tier NSGs deny outbound to it.')
param spokeAddressPrefixes array

@description('Prefix of snet-session-hosts: the only source allowed to reach the console (443, licensing).')
param sessionHostSubnetPrefix string

@description('Prefix of the spoke private endpoint subnet: the one part of the spoke the tier may reach (the profiles account).')
param spokePrivateEndpointSubnetPrefix string

@description('Resource ID of the landing zone privatelink.file zone (Standalone mode).')
param fileDnsZoneId string

@description('Resource ID of the landing zone privatelink.vaultcore zone (Standalone mode).')
param vaultDnsZoneId string

@description('Object ID of the landing zone users group (the group with SMB Share Contributor on the profiles account).')
param usersGroupObjectId string

@description('Object IDs of the Azure Virtual Desktop and Azure Virtual Desktop ARM Provider service principals in this tenant.')
param avdServicePrincipalObjectIds array

@description('Add AzureBastionSubnet and allow 3389 from it to the console and packaging subnets.')
param deployBastion bool = false

@description('Object ID of the operator running the deploy: uploads installers to media and may read the console password.')
param operatorObjectId string

@description('True when the console VM already exists: the deploy then leaves the VM and its password alone (lesson 0002).')
param consoleExists bool = false

@description('The existing console VM identity, when consoleExists.')
param consolePrincipalId string = ''

@description('Generated in memory by Deploy-LiquidwareTier.ps1 for a new console only; written to the tier Key Vault, never output.')
@secure()
param consoleAdminPassword string = ''

@description('True once Set-LiquidwareSecret.ps1 has stored lw-licstr in the tier Key Vault.')
param licenseStored bool = false

@description('Daily console shutdown in dev and test, HHmm.')
param autoShutdownTime string = '1900'

@description('Create the portability share on the existing landing zone profiles storage account.')
param enablePortability bool = false

@description('Name of the existing landing zone profiles storage account (when enablePortability is true).')
param profilesStorageAccountName string = ''

@description('Resource group of the existing landing zone profiles storage account (when enablePortability is true).')
param profilesResourceGroupName string = ''

@description('Create the tier data collection rule for ProfileUnity application restriction events.')
param enableApplicationRestrictions bool = false

@description('Resource ID of the landing zone Log Analytics workspace (when enableApplicationRestrictions is true).')
param logAnalyticsWorkspaceId string = ''

@description('Deploy the on-demand FlexApp packaging VM in snet-lw-packaging.')
param deployPackagingVm bool = false

@description('Generated in memory by Deploy-LiquidwareTier.ps1 for the packaging VM only; written to the tier Key Vault.')
@secure()
param packagingAdminPassword string = ''

@description('Create the tier Recovery Services vault with an Enhanced backup policy.')
param enableBackup bool = false

param tags object = {}

var clean = replace(toLower(namePrefix), '-', '')
var base = '${clean}-${environment}'
var uniq = take(uniqueString(subscription().id, base, 'liquidware'), 5)
var allTags = union(tags, { workload: 'liquidware', 'landing-zone': base, 'avdlz-power-managed': base })
var spokeParts = split(spokeVnetId, '/')
var spokeResourceGroup = spokeParts[4]
var spokeVnetName = spokeParts[8]

resource tierGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${base}-liquidware'
  location: location
  tags: allTags
}

module tier 'modules/tier.bicep' = {
  name: 'liquidware-tier'
  scope: tierGroup
  params: {
    location: location
    tags: allTags
    base: base
    clean: clean
    environment: environment
    uniq: uniq
    tierAddressPrefix: tierAddressPrefix
    spokeVnetId: spokeVnetId
    spokeAddressPrefixes: spokeAddressPrefixes
    sessionHostSubnetPrefix: sessionHostSubnetPrefix
    spokePrivateEndpointSubnetPrefix: spokePrivateEndpointSubnetPrefix
    fileDnsZoneId: fileDnsZoneId
    vaultDnsZoneId: vaultDnsZoneId
    usersGroupObjectId: usersGroupObjectId
    avdServicePrincipalObjectIds: avdServicePrincipalObjectIds
    deployBastion: deployBastion
  }
}

module media 'modules/media.bicep' = {
  name: 'liquidware-media'
  scope: tierGroup
  params: {
    location: location
    tags: allTags
    accountName: take('st${clean}${environment}lwm${uniq}', 24)
    operatorObjectId: operatorObjectId
    opsPrincipalId: tier.outputs.opsPrincipalId
  }
}

module console 'modules/console.bicep' = if (!consoleExists) {
  name: 'liquidware-console'
  scope: tierGroup
  params: {
    location: location
    tags: allTags
    environment: environment
    vmName: 'vm-${clean}lwcon'
    computerName: take('${clean}lwcon', 15)
    subnetId: tier.outputs.consoleSubnetId
    privateIp: tier.outputs.consolePrivateIp
    keyVaultName: tier.outputs.keyVaultName
    adminPassword: consoleAdminPassword
    autoShutdownTime: autoShutdownTime
  }
}

module consoleAccess 'modules/consoleAccess.bicep' = {
  name: 'liquidware-console-access'
  scope: tierGroup
  params: {
    mediaAccountName: media.outputs.accountName
    keyVaultName: tier.outputs.keyVaultName
    consolePrincipalId: consoleExists ? consolePrincipalId : console!.outputs.principalId
    operatorObjectId: operatorObjectId
    licenseStored: licenseStored
  }
}

// The only writes to landing zone resources: child resources, each removed by Cleanup
// (deploy-spec section 4).
module spoke 'modules/spoke.bicep' = {
  name: 'liquidware-spoke'
  scope: resourceGroup(spokeResourceGroup)
  params: {
    base: base
    spokeVnetName: spokeVnetName
    tierVnetId: tier.outputs.vnetId
    fileDnsZoneName: last(split(fileDnsZoneId, '/'))
    vaultDnsZoneName: last(split(vaultDnsZoneId, '/'))
  }
}

module portability 'modules/portability.bicep' = if (enablePortability && !empty(profilesStorageAccountName)) {
  name: 'liquidware-portability'
  scope: resourceGroup(profilesResourceGroupName)
  params: {
    profilesStorageAccountName: profilesStorageAccountName
  }
}

module dcr 'modules/dcr.bicep' = if (enableApplicationRestrictions && !empty(logAnalyticsWorkspaceId)) {
  name: 'liquidware-dcr'
  scope: tierGroup
  params: {
    location: location
    tags: allTags
    dcrName: 'dcr-${base}-liquidware'
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
  }
}

module packaging 'modules/packaging.bicep' = if (deployPackagingVm) {
  name: 'liquidware-packaging'
  scope: tierGroup
  params: {
    location: location
    tags: allTags
    environment: environment
    vmName: 'vm-${clean}lwpkg'
    computerName: take('${clean}lwpkg', 15)
    subnetId: '${tier.outputs.vnetId}/subnets/snet-lw-packaging'
    privateIp: '10.61.0.68'
    keyVaultName: tier.outputs.keyVaultName
    mediaAccountName: media.outputs.accountName
    packagesAccountName: tier.outputs.packagesAccountName
    adminPassword: packagingAdminPassword
    autoShutdownTime: autoShutdownTime
  }
}

module backup 'modules/backup.bicep' = if (enableBackup) {
  name: 'liquidware-backup'
  scope: tierGroup
  params: {
    location: location
    tags: allTags
    vaultName: 'rsv-${base}-liquidware'
  }
}

output resourceGroupName string = tierGroup.name
output vnetId string = tier.outputs.vnetId
output keyVaultName string = tier.outputs.keyVaultName
output configAccountName string = tier.outputs.configAccountName
output packagesAccountName string = tier.outputs.packagesAccountName
output opsIdentityId string = tier.outputs.opsIdentityId
output mediaAccountName string = media.outputs.accountName
output mediaBlobEndpoint string = media.outputs.blobEndpoint
output consoleVmName string = 'vm-${clean}lwcon'
output packagingVmName string = 'vm-${clean}lwpkg'
