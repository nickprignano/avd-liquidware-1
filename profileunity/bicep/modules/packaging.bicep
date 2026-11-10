// On-demand FlexApp packaging VM (deploy-spec section 8.1, DN-M8): Windows 11 Enterprise single-session
// (win11-24h2-ent), Standard_D2as_v5, Trusted Launch with SecureBoot and vTPM, encryption at host,
// no public IP, static IP 10.61.0.68 in snet-lw-packaging, system-assigned managed identity, daily
// shutdown schedule outside prod, and least-privilege roles to read media and write appattach.

param location string
param tags object
param environment string
param vmName string
param computerName string
param subnetId string
param privateIp string = '10.61.0.68'
param keyVaultName string
param mediaAccountName string
param packagesAccountName string

@description('Generated in memory by Deploy-LiquidwareTier.ps1 for this deployment only.')
@secure()
param adminPassword string

param adminUsername string = 'lwadmin'
param vmSize string = 'Standard_D2as_v5'
param autoShutdownTime string = '1900'
param autoShutdownTimeZone string = 'UTC'

var roles = {
  blobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  appAttachFileContributor: '69566ab7-960f-475b-8e7c-b3118f30c6bd'
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource mediaAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: mediaAccountName
}

resource mediaBlobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: mediaAccount
  name: 'default'
}

resource mediaContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: mediaBlobs
  name: 'media'
}

resource packagesAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: packagesAccountName
}

resource packagesFiles 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: packagesAccount
  name: 'default'
}

resource appAttachShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' existing = {
  parent: packagesFiles
  name: 'appattach'
}

resource adminSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'lw-packaging-password'
  properties: {
    value: adminPassword
    contentType: 'Local administrator ${adminUsername} on ${vmName}'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIp
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: union(tags, { 'liquidware-role': 'packaging' })
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
      encryptionAtHost: true
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: { patchMode: 'AutomaticByOS' }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-ent'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id, properties: { deleteOption: 'Delete' } }]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

resource shutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (environment != 'prod') {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: { time: autoShutdownTime }
    timeZoneId: autoShutdownTimeZone
    targetResourceId: vm.id
    notificationSettings: { status: 'Disabled' }
  }
}

resource packagingMediaRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(mediaContainer.id, vm.id, roles.blobDataReader)
  scope: mediaContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.blobDataReader)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource packagingAppAttachWrite 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appAttachShare.id, vm.id, roles.appAttachFileContributor)
  scope: appAttachShare
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.appAttachFileContributor)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output principalId string = vm.identity.principalId
