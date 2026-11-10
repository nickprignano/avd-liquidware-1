#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Guards on the compiled template. Needs the Bicep CLI on PATH.

BeforeAll {
  $script:bicep = (Get-Command bicep -ErrorAction Stop).Source
  $script:root = Split-Path $PSScriptRoot -Parent
  $env:SSUX_ADMIN_PASSWORD = 'Placeholder-only-for-build-1!'
  $env:SSUX_KV_READER_ID = '00000000-0000-0000-0000-000000000001'
  function Get-Compiled {
    $raw = & $script:bicep build-params (Join-Path $script:root 'parameters/lab.bicepparam') --stdout 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bicep build-params failed: $raw" }
    ($raw -join "`n") | ConvertFrom-Json -Depth 100
  }
  function Find-Deployment($Template, [string] $Name) {
    foreach ($r in @($Template.resources.Values) + @($Template.resources)) {
      if ($r -is [System.Collections.IDictionary] -and $r['type'] -eq 'Microsoft.Resources/deployments') {
        if ($r['name'] -eq $Name) { return $r }
        $inner = $r['properties']['template']
        if ($inner) { $hit = Find-Deployment $inner $Name; if ($hit) { return $hit } }
      }
    }
  }
  $script:main = Get-Content (Join-Path $script:root 'bicep/main.bicep') -Raw
  $script:compiled = Get-Compiled
  $script:template = $script:compiled.templateJson | ConvertFrom-Json -Depth 100 -AsHashtable
}

Describe 'Marketplace image' {
  It 'sends a plan block that matches the image reference and attaches FromImage data disks' {
    $hub = Find-Deployment $script:template "[format('vm-{0}', parameters('role'))]"
    $p = $hub['properties']['parameters']
    $p['plan']['value']['name'] | Should -Be "[parameters('imagePlan')]"
    $p['imageReference']['value']['sku'] | Should -Be "[parameters('imagePlan')]"
    $p['plan']['value']['publisher'] | Should -Be "[parameters('imagePublisher')]"
    $p['imageReference']['value']['publisher'] | Should -Be "[parameters('imagePublisher')]"
    $p['plan']['value']['product'] | Should -Be "[parameters('imageOffer')]"
    $p['imageReference']['value']['offer'] | Should -Be "[parameters('imageOffer')]"
    $app = Get-Content (Join-Path $script:root 'bicep/modules/appliance.bicep') -Raw
    $app | Should -Match "createOption:\s*'FromImage'"
    (Get-Content (Join-Path $script:root 'scripts/ops/Deploy-Stratusphere.ps1') -Raw) | Should -Match '\$terms\s*\|\s*Set-AzMarketplaceTerms\s+-Accept'
  }
}

Describe 'Roles' {
  BeforeAll {
    $env:SSUX_DEPLOY_DATABASE = 'true'; $env:SSUX_COLLECTOR_COUNT = '2'
    $env:SSUX_DATABASE_PLAN = 'db-plan'; $env:SSUX_COLLECTOR_PLAN = 'col-plan'
    try { $c = Get-Compiled }
    finally { $env:SSUX_DEPLOY_DATABASE = ''; $env:SSUX_COLLECTOR_COUNT = ''; $env:SSUX_DATABASE_PLAN = ''; $env:SSUX_COLLECTOR_PLAN = '' }
    $script:rolesParams = ($c.parametersJson | ConvertFrom-Json).parameters
  }
  It 'takes the Database and Collectors from the environment, off by default' {
    $script:rolesParams.deployDatabase.value | Should -BeTrue
    $script:rolesParams.collectorCount.value | Should -Be 2
    $script:rolesParams.databaseImagePlan.value | Should -Be 'db-plan'
    $p = ((Get-Compiled).parametersJson | ConvertFrom-Json).parameters
    $p.deployDatabase.value | Should -BeFalse
    $p.collectorCount.value | Should -Be 0
  }
  It 'deploys every role through the one appliance module, so each gets the plan block' {
    $script:main | Should -Match "module hub 'modules/appliance.bicep'"
    $script:main | Should -Match "module database 'modules/appliance.bicep'"
    $script:main | Should -Match "module collectors 'modules/appliance.bicep'"
    $script:main | Should -Match 'imagePlan: databaseImagePlan'
    $script:main | Should -Match 'imagePlan: collectorImagePlan'
  }
  It 'uses the names, IPs and address space the scripts expect' {
    Import-Module (Join-Path $script:root 'scripts/ops/StratusphereAppliance.psm1') -Force
    $d = Get-SsuxApplianceDefault
    $t = $script:template
    $t.parameters.hubPrivateIp.defaultValue | Should -Be $d.Ip.Hub
    $t.parameters.databasePrivateIp.defaultValue | Should -Be $d.Ip.Database
    $t.parameters.collectorPrivateIps.defaultValue | Should -Be $d.CollectorIps
    (Get-Content (Join-Path $script:root 'scripts/ops/Test-StratusphereReadiness.ps1') -Raw) | Should -Match ([regex]::Escape("[string] `$AddressPrefix = '$($t.parameters.addressPrefix.defaultValue)'"))
    $script:main | Should -Match ([regex]::Escape("'vm-`${namePrefix}-hub'"))
    $script:main | Should -Match ([regex]::Escape("'vm-`${namePrefix}-db'"))
    $script:main | Should -Match ([regex]::Escape("'vm-`${namePrefix}-col`${i + 1}'"))
    (Get-Content (Join-Path $script:root 'bicep/modules/appliance.bicep') -Raw) | Should -Match ([regex]::Escape("'stratusphere-role': role"))
  }
  It 'configures a daily Microsoft.DevTestLab/schedules shutdown task on each appliance VM' {
    $app = Get-Content (Join-Path $script:root 'bicep/modules/appliance.bicep') -Raw
    $app | Should -Match "resource autoShutdown 'Microsoft\.DevTestLab/schedules@2018-09-15'"
    $app | Should -Match "name: 'shutdown-computevm-\$\{name\}'"
    $app | Should -Match "taskType: 'ComputeVmShutdownTask'"
  }
}

Describe 'Parameter file' {
  It 'takes the plan and region from the environment and defaults when empty' {
    $env:SSUX_HUB_PLAN = 'example-plan'; $env:SSUX_LOCATION = 'westus3'
    try { $p = ((Get-Compiled).parametersJson | ConvertFrom-Json).parameters }
    finally { $env:SSUX_HUB_PLAN = ''; $env:SSUX_LOCATION = '' }
    $p.hubImagePlan.value | Should -Be 'example-plan'
    $p.location.value | Should -Be 'westus3'
    $p = ((Get-Compiled).parametersJson | ConvertFrom-Json).parameters
    $p.location.value | Should -Be 'eastus2'
    $p.hubVmSize.value | Should -Be 'Standard_D4s_v5'
  }
  It 'stamps deadline tags and environment when SSUX_ENVIRONMENT and SSUX_SHUTDOWN_UTC are set' {
    $env:SSUX_ENVIRONMENT = 'dev'
    $env:SSUX_SHUTDOWN_UTC = '2026-11-03T20:00:00Z'
    $env:SSUX_TEARDOWN_UTC = '2026-11-03T22:00:00Z'
    $env:SSUX_SHUTDOWN_SCHEDULE = 'ssux-shutdown-ssux-b20261103-1800-G1'
    $env:SSUX_TEARDOWN_SCHEDULE = 'ssux-teardown-ssux-b20261103-1800-G2'
    try { $p = ((Get-Compiled).parametersJson | ConvertFrom-Json).parameters }
    finally {
      $env:SSUX_ENVIRONMENT = ''; $env:SSUX_SHUTDOWN_UTC = ''; $env:SSUX_TEARDOWN_UTC = ''
      $env:SSUX_SHUTDOWN_SCHEDULE = ''; $env:SSUX_TEARDOWN_SCHEDULE = ''
    }
    $p.environment.value | Should -Be 'dev'
    $p.tags.value.'avdlz-component' | Should -Be 'stratusphere-ux'
    $p.tags.value.'avdlz-shutdown-schedule' | Should -Be 'ssux-shutdown-ssux-b20261103-1800-G1'
    $p.tags.value.'avdlz-teardown-schedule' | Should -Be 'ssux-teardown-ssux-b20261103-1800-G2'
  }
}

Describe 'Hub network exposure' {
  It 'admits only TCP 443 and SSH from Bastion, then denies' {
    $nsg = Find-Deployment $script:template 'nsg-hub'
    $rules = $nsg['properties']['parameters']['securityRules']['value']
    $rules | Should -Match '443'
    $text = $rules | ConvertTo-Json -Depth 20 -Compress
    $text | Should -Match "Deny-Other-Inbound"
    $text | Should -Not -Match "Internet"
  }
  It 'opens TCP 5432 only between appliances, and only with a Database or Collectors' {
    $net = Get-Content (Join-Path $script:root 'bicep/modules/network.bicep') -Raw
    $net | Should -Match "(?s)allowPostgres\s*\?\s*\[.*?Allow-Postgres-Between-Appliances.*?sourceAddressPrefix: hubSubnetPrefix.*?destinationAddressPrefix: hubSubnetPrefix.*?destinationPortRange: '5432'"
    $script:main | Should -Match 'allowPostgres: deployDatabase \|\| collectorCount > 0'
  }
  It 'uses singular sourceAddressPrefix when callbackSourcePrefixes has one entry so VirtualNetwork service tag passes ARM preflight' {
    $net = Get-Content (Join-Path $script:root 'bicep/modules/network.bicep') -Raw
    $net | Should -Match 'sourceAddressPrefix: length\(callbackSourcePrefixes\) == 1 \? callbackSourcePrefixes\[0\] : null'
    $net | Should -Match 'sourceAddressPrefixes: length\(callbackSourcePrefixes\) > 1 \? callbackSourcePrefixes : null'
  }
}

Describe 'Egress' {
  It 'turns default outbound access off and sends the Hub subnet through a regional NAT Gateway' {
    $vnet = Find-Deployment $script:template 'vnet'
    $subnets = $vnet['properties']['parameters']['subnets']['value'] | ConvertTo-Json -Depth 20 -Compress
    $subnets | Should -Match "'defaultOutboundAccess', false\(\)"
    $subnets | Should -Match 'natGatewayResourceId'
    $nat = Find-Deployment $script:template 'nat-gateway'
    $nat['properties']['parameters']['publicIPAddresses']['value'][0]['availabilityZones'] | Should -BeNullOrEmpty
  }
}

Describe 'Disclaimer' {
  It 'is at the top of every entry point' {
    $files = @(
      'bicep/main.bicep'
      'scripts/deploy/deploy.sh'
      'scripts/ops/Test-StratusphereReadiness.ps1'
      'scripts/ops/StratusphereReadiness.psm1'
      'scripts/ops/StratusphereAppliance.psm1'
      'scripts/ops/Deploy-Stratusphere.ps1'
      'scripts/ops/New-SandboxStratusphere.ps1'
      'scripts/ops/Remove-SandboxStratusphere.ps1'
      'scripts/ops/CidKeyRollout.psm1'
      'scripts/ops/Deploy-CidKey.ps1'
      'scripts/agent/Invoke-CidKeyAction.ps1'
    )
    foreach ($f in $files) {
      (Get-Content (Join-Path $script:root $f) -TotalCount 8) -join "`n" | Should -Match 'Personal project, not for production use' -Because $f
      (Get-Content (Join-Path $script:root $f) -TotalCount 8) -join "`n" | Should -Match 'Not affiliated with .*Liquidware' -Because $f
    }
  }
}
