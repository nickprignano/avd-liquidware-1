#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for the preflight checks: each takes data shaped like the Az cmdlet output.

BeforeAll {
  Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ops/StratusphereReadiness.psm1') -Force
}

Describe 'Get-SsuxPlanCheck' {
  It 'fails and lists the plans when none is chosen' {
    $r = Get-SsuxPlanCheck -AvailablePlans 'plan-a', 'plan-b' -Location eastus2
    $r.Status | Should -Be 'FAIL'
    $r.Detail | Should -Match 'plan-a, plan-b'
  }
  It 'fails when the chosen plan is not offered' {
    (Get-SsuxPlanCheck -AvailablePlans 'plan-a' -Plan 'plan-z' -Location eastus2).Status | Should -Be 'FAIL'
  }
  It 'fails clearly when nothing is offered in the region' {
    $r = Get-SsuxPlanCheck -AvailablePlans @() -Plan 'plan-a' -Location eastus2
    $r.Status | Should -Be 'FAIL'
    $r.Detail | Should -Match 'No Stratusphere plans'
  }
  It 'passes for an offered plan' {
    (Get-SsuxPlanCheck -AvailablePlans 'plan-a', 'plan-b' -Plan 'plan-b' -Location eastus2).Status | Should -Be 'PASS'
  }
}

Describe 'Get-SsuxImagePlanCheck' {
  It 'fails when the image has no purchase plan' {
    (Get-SsuxImagePlanCheck -PurchasePlan $null -Version '1.0.0').Status | Should -Be 'FAIL'
  }
  It 'passes when it has one' {
    (Get-SsuxImagePlanCheck -PurchasePlan ([pscustomobject]@{ Name = 'plan-a' }) -Version '1.0.0').Status | Should -Be 'PASS'
  }
}

Describe 'Get-SsuxQuotaCheck' {
  BeforeAll {
    function New-Usage($name, $current, $limit) { [pscustomobject]@{ Name = [pscustomobject]@{ Value = $name }; CurrentValue = $current; Limit = $limit } }
    $script:need = @(
      [pscustomobject]@{ Family = 'standardDSv5Family'; VCpus = 4 }
      [pscustomobject]@{ Family = 'standardDSv5Family'; VCpus = 4 }
      [pscustomobject]@{ Family = 'standardDSv5Family'; VCpus = 4 }
    )
  }
  It 'sums every appliance in a family and the region' {
    $u = @((New-Usage 'cores' 10 100), (New-Usage 'standardDSv5Family' 0 20))
    $r = @(Get-SsuxQuotaCheck -Need $script:need -Usage $u)
    $r.Status | Should -Be @('PASS', 'PASS')
    $r[0].Detail | Should -Match '12 needed'
  }
  It 'fails a full family and names the families with room' {
    $u = @((New-Usage 'cores' 10 100), (New-Usage 'standardDSv5Family' 10 20), (New-Usage 'standardDASv5Family' 0 50), (New-Usage 'standardBSFamily' 0 4))
    $r = @(Get-SsuxQuotaCheck -Need $script:need -Usage $u)
    ($r | Where-Object Check -eq 'quota-standardDSv5Family').Status | Should -Be 'FAIL'
    ($r | Where-Object Check -eq 'quota-alternatives').Detail | Should -Match 'standardDASv5Family \(50 free\)'
    ($r | Where-Object Check -eq 'quota-alternatives').Detail | Should -Not -Match 'standardBSFamily'
  }
  It 'says so when a family has no quota at all' {
    $u = @((New-Usage 'cores' 0 100), (New-Usage 'standardDSv5Family' 0 0))
    (@(Get-SsuxQuotaCheck -Need $script:need -Usage $u) | Where-Object Status -eq 'FAIL').Detail | Should -Match 'no quota at all'
  }
  It 'fails on the regional total even when the family has room' {
    $u = @((New-Usage 'cores' 95 100), (New-Usage 'standardDSv5Family' 0 50))
    (@(Get-SsuxQuotaCheck -Need $script:need -Usage $u) | Where-Object Check -eq 'quota-cores').Status | Should -Be 'FAIL'
  }
  It 'warns when a usage row is missing' {
    (@(Get-SsuxQuotaCheck -Need $script:need -Usage @()) | Select-Object -First 1).Status | Should -Be 'WARN'
  }
}

Describe 'Get-SsuxNetworkQuotaCheck' {
  It 'needs a NIC per appliance and the public IPs' {
    $u = @(
      [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'NetworkInterfaces' }; CurrentValue = 10; Limit = 65536 }
      [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'PublicIPAddresses' }; CurrentValue = 9; Limit = 10 }
    )
    (Get-SsuxNetworkQuotaCheck -Nics 3 -PublicIps 2 -Usage $u).Status | Should -Be @('PASS', 'FAIL')
  }
}

Describe 'Get-SsuxRoleCoverageCheck' {
  It 'passes Owner, or Contributor with a role that can grant access' {
    (Get-SsuxRoleCoverageCheck -RoleName 'Owner').Status | Should -Be 'PASS'
    (Get-SsuxRoleCoverageCheck -RoleName 'Contributor', 'User Access Administrator').Status | Should -Be 'PASS'
  }
  It 'fails Contributor alone, because the Key Vault role assignment would fail' {
    (Get-SsuxRoleCoverageCheck -RoleName 'Contributor').Detail | Should -Match 'Key Vault'
    (Get-SsuxRoleCoverageCheck -RoleName 'Reader').Status | Should -Be 'FAIL'
  }
  It 'says when it could not read the assignments' {
    (Get-SsuxRoleCoverageCheck -CouldRead $false).Status | Should -Be 'INFO'
  }
}

Describe 'Get-SsuxPolicyCheck' {
  It 'compares allowed locations and sizes with the plan, and lists other denies' {
    $a = @(
      [pscustomobject]@{ DisplayName = 'Regions'; DefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'; AllowedLocations = @('westus3'); AllowedSkus = @(); IsDeny = $true }
      [pscustomobject]@{ DisplayName = 'Sizes'; DefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/cccc23c7-8427-4f53-ad12-b6a63eb452b3'; AllowedLocations = @(); AllowedSkus = @('Standard_D4s_v5'); IsDeny = $true }
      [pscustomobject]@{ DisplayName = 'No public IPs'; DefinitionId = '/subscriptions/x/providers/Microsoft.Authorization/policyDefinitions/custom'; AllowedLocations = @(); AllowedSkus = @(); IsDeny = $true }
    )
    $r = @(Get-SsuxPolicyCheck -Assignment $a -Location eastus2 -VmSize 'Standard_D4s_v5', 'Standard_D2s_v5')
    $r.Status | Should -Be @('FAIL', 'FAIL', 'WARN')
    $r[1].Detail | Should -Match 'Standard_D2s_v5'
    $r[2].Detail | Should -Match 'No public IPs'
  }
  It 'passes with no deny policies' {
    (Get-SsuxPolicyCheck -Assignment @() -Location eastus2).Status | Should -Be 'PASS'
  }
}

Describe 'Get-SsuxLockCheck' {
  It 'fails ReadOnly and notes CanNotDelete' {
    (Get-SsuxLockCheck -Lock @([pscustomobject]@{ Name = 'freeze'; Level = 'ReadOnly' }, [pscustomobject]@{ Name = 'keep'; Level = 'CanNotDelete' })).Status | Should -Be @('FAIL', 'INFO')
    (Get-SsuxLockCheck -Lock @()).Status | Should -Be 'PASS'
  }
}

Describe 'Address math and overlap' {
  It 'computes ranges and overlaps' {
    (Get-SsuxCidrRange '10.60.0.0/24').Length | Should -Be 24
    Get-SsuxCidrRange 'VirtualNetwork' | Should -BeNullOrEmpty
    Test-SsuxCidrOverlap '10.60.0.0/24' '10.0.0.0/8' | Should -BeTrue
    Test-SsuxCidrOverlap '10.60.0.0/24' '10.60.1.0/24' | Should -BeFalse
    Test-SsuxCidrOverlap '10.60.0.0/24' '10.60.0.128/25' | Should -BeTrue
  }
  It 'fails an overlap with the peer VNet and warns on others' {
    $o = @(
      [pscustomobject]@{ Source = 'peer VNet spoke'; Prefix = '10.60.0.0/22'; Blocking = $true }
      [pscustomobject]@{ Source = 'VNet hub'; Prefix = '10.0.0.0/8'; Blocking = $false }
      [pscustomobject]@{ Source = 'VNet other'; Prefix = '192.168.0.0/16'; Blocking = $false }
    )
    (Get-SsuxAddressOverlapCheck -AddressPrefix '10.60.0.0/24' -Other $o).Status | Should -Be @('FAIL', 'WARN')
    (Get-SsuxAddressOverlapCheck -AddressPrefix '172.16.0.0/24' -Other $o).Status | Should -Be 'PASS'
  }
}

Describe 'Get-SsuxEndpointNsgCheck' {
  BeforeAll {
    function New-Rule($name, $priority, $access, $dest, $port = '*', $protocol = '*', $direction = 'Outbound') {
      [pscustomobject]@{ Name = $name; Priority = $priority; Direction = $direction; Access = $access; Protocol = $protocol; DestinationAddressPrefix = @($dest); DestinationPortRange = @($port) }
    }
    $script:defaults = @(
      New-Rule 'AllowVnetOutBound' 65000 'Allow' 'VirtualNetwork'
      New-Rule 'AllowInternetOutBound' 65001 'Allow' 'Internet'
      New-Rule 'DenyAllOutBound' 65500 'Deny' '*'
    )
  }
  It 'passes on the default rules (the peered VNet is in VirtualNetwork)' {
    (Get-SsuxEndpointNsgCheck -SubnetName s -Rule $script:defaults -HubIp 10.60.0.4).Detail | Should -Match 'AllowVnetOutBound'
  }
  It 'fails when a higher-priority rule denies 443 to the Hub' {
    $r = @(New-Rule 'Deny-Private' 200 'Deny' '10.0.0.0/8' '400-500' 'Tcp') + $script:defaults
    $res = Get-SsuxEndpointNsgCheck -SubnetName s -Rule $r -HubIp 10.60.0.4
    $res.Status | Should -Be 'FAIL'
    $res.Detail | Should -Match 'Deny-Private'
  }
  It 'ignores rules for other ports, protocols and destinations' {
    $r = @(
      New-Rule 'Deny-Udp' 100 'Deny' '*' '*' 'Udp'
      New-Rule 'Deny-80' 110 'Deny' '*' '80'
      New-Rule 'Deny-Other' 120 'Deny' '10.70.0.0/16'
    ) + $script:defaults
    (Get-SsuxEndpointNsgCheck -SubnetName s -Rule $r -HubIp 10.60.0.4).Status | Should -Be 'PASS'
  }
  It 'passes a subnet with no NSG' {
    (Get-SsuxEndpointNsgCheck -SubnetName s -Rule @() -HubIp 10.60.0.4).Status | Should -Be 'PASS'
  }
}

Describe 'Get-SsuxEndpointRouteCheck' {
  BeforeAll {
    function New-Route($prefix, $hop, $ip = '') { [pscustomobject]@{ Name = "to-$prefix"; AddressPrefix = $prefix; NextHopType = $hop; NextHopIpAddress = $ip } }
  }
  It 'lets the peering win over a broader forced-tunnel route' {
    $r = @((New-Route '0.0.0.0/0' 'VirtualAppliance' '10.0.0.4'), (New-Route '10.0.0.0/8' 'VirtualAppliance' '10.0.0.4'))
    (Get-SsuxEndpointRouteCheck -SubnetName s -Route $r -HubIp 10.60.0.4 -AssessmentPrefix 10.60.0.0/24 -DirectlyPeered $true).Status | Should -Be 'PASS'
  }
  It 'warns when a route at least as specific sends callbacks through a firewall' {
    $r = @(New-Route '10.60.0.0/24' 'VirtualAppliance' '10.0.0.4')
    (Get-SsuxEndpointRouteCheck -SubnetName s -Route $r -HubIp 10.60.0.4 -AssessmentPrefix 10.60.0.0/24 -DirectlyPeered $true).Detail | Should -Match '10.0.0.4'
  }
  It 'without direct peering, follows the covering route or fails' {
    $r = @(New-Route '0.0.0.0/0' 'VirtualAppliance' '10.0.0.4')
    (Get-SsuxEndpointRouteCheck -SubnetName s -Route $r -HubIp 10.60.0.4 -AssessmentPrefix 10.60.0.0/24 -DirectlyPeered $false).Status | Should -Be 'WARN'
    (Get-SsuxEndpointRouteCheck -SubnetName s -Route @() -HubIp 10.60.0.4 -AssessmentPrefix 10.60.0.0/24 -DirectlyPeered $false).Status | Should -Be 'FAIL'
  }
  It 'fails a black hole' {
    (Get-SsuxEndpointRouteCheck -SubnetName s -Route @(New-Route '10.60.0.0/26' 'None') -HubIp 10.60.0.4 -AssessmentPrefix 10.60.0.0/24 -DirectlyPeered $true).Status | Should -Be 'FAIL'
  }
}

Describe 'Endpoint sizing and the avd-current-state package' {
  It 'advises a Database above 1,000 endpoints' {
    (Get-SsuxEndpointSizingCheck -EndpointCount 1500 -Role Hub).Status | Should -Be 'WARN'
    (Get-SsuxEndpointSizingCheck -EndpointCount 1500 -Role Hub, Database).Status | Should -Be 'PASS'
    (Get-SsuxEndpointSizingCheck -EndpointCount 0 -Role Hub).Status | Should -Be 'SKIP'
  }
  It 'reads session hosts and VNet address spaces from the collector datasets' {
    $sh = @([pscustomobject]@{ HostPool = 'hp1'; Name = 'a' }, [pscustomobject]@{ HostPool = 'hp1'; Name = 'b' }, [pscustomobject]@{ HostPool = 'hp2'; Name = 'c' })
    $vn = @([pscustomobject]@{ Name = 'vnet-spoke'; AddressSpace = '10.100.0.0/22, 10.101.0.0/24' })
    $s = Get-SsuxAvdCurrentStateSummary -SessionHost $sh -VirtualNetwork $vn
    $s.EndpointCount | Should -Be 3
    $s.HostPools | Should -Be @('hp1', 'hp2')
    $s.Prefixes.Prefix | Should -Be @('10.100.0.0/22', '10.101.0.0/24')
  }
}

Describe 'Get-SsuxVmSizeCheck' {
  It 'fails when the size is not offered' {
    (Get-SsuxVmSizeCheck -Sku $null -VmSize Standard_D4s_v5 -Location eastus2).Status | Should -Be 'FAIL'
  }
  It 'fails when the size is restricted for the subscription' {
    $sku = [pscustomobject]@{ Restrictions = @([pscustomobject]@{ ReasonCode = 'NotAvailableForSubscription'; Type = 'Location' }) }
    (Get-SsuxVmSizeCheck -Sku $sku -VmSize Standard_D4s_v5 -Location eastus2).Status | Should -Be 'FAIL'
  }
  It 'fails when the size supports V2 only (Gen2-only SKU for Gen1 Marketplace image)' {
    $v2Only = [pscustomobject]@{
      Restrictions = @()
      Capabilities = @([pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' })
    }
    $res = Get-SsuxVmSizeCheck -Sku $v2Only -VmSize Standard_D4as_v6 -Location centralus
    $res.Status | Should -Be 'FAIL'
    $res.Detail | Should -Match 'require V1 \(Gen1\)'
  }
  It 'passes when available' {
    (Get-SsuxVmSizeCheck -Sku ([pscustomobject]@{ Restrictions = @() }) -VmSize Standard_D4s_v5 -Location eastus2).Status | Should -Be 'PASS'
    $v1v2 = [pscustomobject]@{
      Restrictions = @()
      Capabilities = @([pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' })
    }
    (Get-SsuxVmSizeCheck -Sku $v1v2 -VmSize Standard_D4s_v4 -Location centralus).Status | Should -Be 'PASS'
  }
}
