// One Stratusphere appliance (Hub, Database or Collector) from Azure Marketplace.
// A Marketplace image needs a `plan` block that matches its imageReference;
// leaving it out is the most common Marketplace deployment failure. The terms
// for the plan must be accepted in the subscription first (the deploy scripts do it).
// The private IP is static: Liquidware requires a fixed address and DNS name for
// each appliance, and the Connector ID Keys and Collectors call back to it.

@description('Role, used to name the nested deployment: hub, database, collector-1 ...')
param role string
param location string
param tags object
param name string
param vmSize string
param osDiskSizeGB int
param subnetResourceId string
param privateIp string
param imagePublisher string
param imageOffer string
param imagePlan string
param imageVersion string
param adminUsername string

@secure()
param adminPassword string

@description('Daily auto-shutdown time in HHmm (24-hour), or empty to skip the DevTestLab schedule.')
param autoShutdownTime string = '2000'

@description('Windows time zone ID for the daily auto-shutdown schedule.')
param autoShutdownTimeZone string = 'Central Standard Time'

@description('LUNs of data disks included in the Marketplace image (Stratusphere 6.7 images carry LUN 0 and LUN 1).')
param dataDiskLuns array = [
  0
  1
]

module vm 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'vm-${role}'
  params: {
    name: name
    location: location
    tags: union(tags, { 'stratusphere-role': role })
    vmSize: vmSize
    osType: 'Linux'
    // The appliance's image decides its own zone support; keep it regional.
    availabilityZone: -1
    imageReference: {
      publisher: imagePublisher
      offer: imageOffer
      sku: imagePlan
      version: imageVersion
    }
    plan: {
      name: imagePlan
      publisher: imagePublisher
      product: imageOffer
    }
    osDisk: {
      caching: 'ReadWrite'
      deleteOption: 'Delete'
      diskSizeGB: osDiskSizeGB
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
    }
    dataDisks: [
      for lun in dataDiskLuns: {
        lun: lun
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    ]
    adminUsername: adminUsername
    adminPassword: adminPassword
    disablePasswordAuthentication: false
    nicConfigurations: [
      {
        nicSuffix: '-nic'
        deleteOption: 'Delete'
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: subnetResourceId
            privateIPAllocationMethod: 'Static'
            privateIPAddress: privateIp
          }
        ]
      }
    ]
    bootDiagnostics: true
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (!empty(autoShutdownTime)) {
  name: 'shutdown-computevm-${name}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    notificationSettings: {
      status: 'Disabled'
    }
    targetResourceId: vm.outputs.resourceId
  }
}

output name string = vm.outputs.name
output privateIp string = privateIp
