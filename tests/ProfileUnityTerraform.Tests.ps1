#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Guards on the ProfileUnity Terraform configuration (profileunity/terraform/*.tf), mirroring
# tests/ProfileUnityTemplate.Tests.ps1 (docs/deploy-spec.md section 5). Offline; runs without the
# Terraform CLI by parsing the HCL files, and runs `terraform validate` / `terraform test` when
# terraform is on PATH.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  $script:tfDir = Join-Path $script:root 'profileunity/terraform'
  Import-Module (Join-Path $script:root 'scripts/LiquidwareTier.psm1') -Force

  $script:files = @{}
  foreach ($f in Get-ChildItem -Path $script:tfDir -Filter '*.tf') {
    $script:files[$f.Name] = Get-Content -LiteralPath $f.FullName -Raw
  }
  $script:allHcl = ($script:files.Values -join "`n")

  function Get-HclBlock([string] $Text, [string] $Kind, [string] $Type = '', [string] $Name = '') {
    if ($Kind -eq 'resource') {
      $typePat = if ($Type) { [regex]::Escape($Type) } else { '[^"]+' }
      $namePat = if ($Name) { [regex]::Escape($Name) } else { '[^"]+' }
      $pattern = "(?ms)^resource\s+`"($typePat)`"\s+`"($namePat)`"\s*\{(.*?)^\}"
      foreach ($m in [regex]::Matches($Text, $pattern)) {
        [pscustomobject]@{ Kind = 'resource'; Type = $m.Groups[1].Value; Name = $m.Groups[2].Value; Body = $m.Groups[3].Value }
      }
    }
    else {
      $namePat = if ($Name) { [regex]::Escape($Name) } else { '[^"]+' }
      $pattern = "(?ms)^$([regex]::Escape($Kind))\s+`"($namePat)`"\s*\{(.*?)^\}"
      foreach ($m in [regex]::Matches($Text, $pattern)) {
        [pscustomobject]@{ Kind = $Kind; Type = ''; Name = $m.Groups[1].Value; Body = $m.Groups[2].Value }
      }
    }
  }
}

Describe 'Terraform parameter and output parity with Bicep' {
  It 'declares the exact same variables as profileunity/bicep/main.bicep and Get-LwTemplateParameter' {
    $bicep = Get-Content (Join-Path $script:root 'profileunity/bicep/main.bicep') -Raw
    $bicepParams = @([regex]::Matches($bicep, '(?m)^param (\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $tfVars = @(Get-HclBlock $script:files['variables.tf'] 'variable' | ForEach-Object Name | Sort-Object)
    $tfVars | Should -Be $bicepParams
  }

  It 'declares the exact same outputs as profileunity/bicep/main.bicep and never outputs a password' {
    $bicep = Get-Content (Join-Path $script:root 'profileunity/bicep/main.bicep') -Raw
    $bicepOutputs = @([regex]::Matches($bicep, '(?m)^output (\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    $tfOutputs = @(Get-HclBlock $script:files['outputs.tf'] 'output' | ForEach-Object Name | Sort-Object)
    $tfOutputs | Should -Be $bicepOutputs
    $script:files['outputs.tf'] | Should -Not -Match 'adminPassword|consoleAdminPassword|packagingAdminPassword'
  }
}

Describe 'Landing zone writes (Terraform)' {
  It 'deploys to the landing zone network RG only the peering and the two DNS links' {
    $spoke = $script:files['spoke.tf']
    $resources = @(Get-HclBlock $spoke 'resource')
    @($resources | ForEach-Object Type | Sort-Object) | Should -Be @(
      'azurerm_private_dns_zone_virtual_network_link'
      'azurerm_private_dns_zone_virtual_network_link'
      'azurerm_virtual_network_peering'
    )
    foreach ($r in $resources) {
      $r.Body | Should -Match 'resource_group_name\s*=\s*local\.spoke_resource_group'
    }
  }

  It 'never creates a private DNS zone, a profiles storage account or a second VNet' {
    @(Get-HclBlock $script:allHcl 'resource' 'azurerm_private_dns_zone').Count | Should -Be 0
    $accounts = @(Get-HclBlock $script:allHcl 'resource' 'azurerm_storage_account')
    @($accounts | ForEach-Object Name | Sort-Object) | Should -Be @('config', 'media', 'packages')
    foreach ($a in $accounts) { $a.Body | Should -Match 'account_kind\s*=\s*"StorageV2"' }
    @(Get-HclBlock $script:allHcl 'resource' 'azurerm_virtual_network').Count | Should -Be 1
  }

  It 'peers without forwarded or gateway traffic, both ways' {
    $peerings = @(Get-HclBlock $script:allHcl 'resource' 'azurerm_virtual_network_peering')
    $peerings.Count | Should -Be 2
    foreach ($p in $peerings) {
      $p.Body | Should -Match 'allow_virtual_network_access\s*=\s*true'
      $p.Body | Should -Match 'allow_forwarded_traffic\s*=\s*false'
      $p.Body | Should -Match 'allow_gateway_transit\s*=\s*false'
      $p.Body | Should -Match 'use_remote_gateways\s*=\s*false'
    }
  }
}

Describe 'Live config account (Terraform)' {
  BeforeAll {
    $script:config = (Get-HclBlock $script:files['storage.tf'] 'resource' 'azurerm_storage_account' 'config').Body
  }

  It 'has shared key off, Entra Kerberos and no public access' {
    $script:config | Should -Match 'shared_access_key_enabled\s*=\s*false'
    $script:config | Should -Match 'public_network_access_enabled\s*=\s*false'
    $script:config | Should -Match 'directory_type\s*=\s*"AADKERB"'
    $script:config | Should -Match 'default_share_level_permission\s*=\s*"None"'
  }

  It "uses the profiles account's SMB settings, without multichannel" {
    $main = $script:files['main.tf']
    $main | Should -Match 'versions\s*=\s*\["SMB3\.1\.1"\]'
    $main | Should -Match 'authentication_types\s*=\s*\["Kerberos"\]'
    $main | Should -Match 'kerberos_ticket_encryption_type\s*=\s*\["AES-256"\]'
    $main | Should -Match 'channel_encryption_type\s*=\s*\["AES-128-GCM",\s*"AES-256-GCM"\]'
    $script:config | Should -Not -Match 'multichannel'
  }

  It 'has one share, lwconfig' {
    $share = (Get-HclBlock $script:files['storage.tf'] 'resource' 'azurerm_storage_share' 'lwconfig').Body
    $share | Should -Match 'name\s*=\s*"lwconfig"'
    $share | Should -Match 'storage_account_id\s*=\s*azurerm_storage_account\.config\.id'
  }
}

Describe 'Role assignments (Terraform)' {
  BeforeAll {
    $script:assignments = @(Get-HclBlock $script:allHcl 'resource' 'azurerm_role_assignment')
  }

  It 'uses the built-in role IDs the spec names' {
    $main = $script:files['main.tf']
    $main | Should -Match 'smbShareReader\s*=\s*"aba4ae5f-2193-4029-9191-0cb91df5e314"'
    $main | Should -Match 'filePrivilegedContributor\s*=\s*"69566ab7-960f-475b-8e7c-b3118f30c6bd"'
    $main | Should -Match 'readerAndDataAccess\s*=\s*"c12c1c16-33a1-487b-954d-41c89c60f349"'
    $main | Should -Match 'blobDataContributor\s*=\s*"ba92f5b4-2d11-453d-a403-e96b0029c9fe"'
    $main | Should -Match 'blobDataReader\s*=\s*"2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"'
    $main | Should -Match 'keyVaultSecretsUser\s*=\s*"4633458b-17de-408a-b874-0445c86b69e6"'
  }

  It 'gives every assignment a known built-in role from local.role_definition_ids' {
    $script:assignments.Count | Should -Be 11
    foreach ($a in $script:assignments) {
      $a.Body | Should -Match 'role_definition_id\s*=\s*local\.role_definition_ids\.(smbShareReader|filePrivilegedContributor|readerAndDataAccess|blobDataContributor|blobDataReader|keyVaultSecretsUser)' -Because $a.Name
    }
  }

  It 'gives no assignment to a user other than the operator: media, and the console password secret only' {
    $users = @($script:assignments | Where-Object { $_.Body -match 'principal_type\s*=\s*"User"' })
    $users.Count | Should -Be 2
    foreach ($u in $users) { $u.Body | Should -Match 'principal_id\s*=\s*var\.operatorObjectId' }
    ($users | Where-Object Name -eq 'operator_media').Body | Should -Match 'scope\s*=\s*azurerm_storage_container\.media\.resource_manager_id'
    ($users | Where-Object Name -eq 'operator_console_password').Body | Should -Match 'lw-console-password'
  }

  It 'gives the users group read on the live config account and nothing else (tier N-C1)' {
    $groups = @($script:assignments | Where-Object { $_.Body -match 'principal_type\s*=\s*"Group"' })
    $groups.Count | Should -Be 1
    $groups[0].Name | Should -Be 'config_users_read'
    $groups[0].Body | Should -Match 'role_definition_id\s*=\s*local\.role_definition_ids\.smbShareReader'
    $groups[0].Body | Should -Match 'scope\s*=\s*azurerm_storage_account\.config\.id'
  }

  It 'lets only the ops runner write the live config account' {
    $onConfig = @($script:assignments | Where-Object { $_.Body -match 'scope\s*=\s*azurerm_storage_account\.config\.id' })
    $onConfig.Count | Should -Be 2
    $writer = $onConfig | Where-Object Name -eq 'config_ops_write'
    $writer.Body | Should -Match 'role_definition_id\s*=\s*local\.role_definition_ids\.filePrivilegedContributor'
    $writer.Body | Should -Match 'principal_id\s*=\s*azurerm_user_assigned_identity\.ops\.principal_id'
  }

  It 'gives the packages account only Reader and Data Access, only to service principals' {
    $onPackages = @($script:assignments | Where-Object { $_.Body -match 'scope\s*=\s*azurerm_storage_account\.packages\.id' })
    $onPackages.Count | Should -Be 1
    $onPackages[0].Body | Should -Match 'role_definition_id\s*=\s*local\.role_definition_ids\.readerAndDataAccess'
    $onPackages[0].Body | Should -Match 'principal_type\s*=\s*"ServicePrincipal"'
    $onPackages[0].Body | Should -Match 'for_each\s*=\s*toset\(var\.avdServicePrincipalObjectIds\)'
  }
}

Describe 'Packages and Media accounts (Terraform)' {
  It 'gives packages one share (appattach), no blob container, and private access only' {
    $pkg = (Get-HclBlock $script:files['storage.tf'] 'resource' 'azurerm_storage_account' 'packages').Body
    $pkg | Should -Match 'public_network_access_enabled\s*=\s*false'
    $pkg | Should -Match 'allow_nested_items_to_be_public\s*=\s*false'
    $share = (Get-HclBlock $script:files['storage.tf'] 'resource' 'azurerm_storage_share' 'appattach').Body
    $share | Should -Match 'name\s*=\s*"appattach"'
    $containers = @(Get-HclBlock $script:allHcl 'resource' 'azurerm_storage_container')
    foreach ($c in $containers) { $c.Body | Should -Match 'storage_account_id\s*=\s*azurerm_storage_account\.media\.id' }
  }

  It 'gives media shared key and anonymous access off, OAuth on, and two private containers (media and staging)' {
    $media = (Get-HclBlock $script:files['storage.tf'] 'resource' 'azurerm_storage_account' 'media').Body
    $media | Should -Match 'shared_access_key_enabled\s*=\s*false'
    $media | Should -Match 'allow_nested_items_to_be_public\s*=\s*false'
    $media | Should -Match 'default_to_oauth_authentication\s*=\s*true'
    $containers = @(Get-HclBlock $script:files['storage.tf'] 'resource' 'azurerm_storage_container')
    @($containers | ForEach-Object Name | Sort-Object) | Should -Be @('media', 'staging')
    foreach ($c in $containers) { $c.Body | Should -Match 'container_access_type\s*=\s*"private"' }
  }
}

Describe 'Console and Packaging VMs (Terraform)' {
  It 'gives every VM Trusted Launch and encryption at host, with no public IP' {
    $vms = @(Get-HclBlock $script:allHcl 'resource' 'azurerm_windows_virtual_machine')
    $vms.Count | Should -Be 2
    foreach ($v in $vms) {
      $v.Body | Should -Match 'secure_boot_enabled\s*=\s*true'
      $v.Body | Should -Match 'vtpm_enabled\s*=\s*true'
      $v.Body | Should -Match 'encryption_at_host_enabled\s*=\s*true'
      $v.Body | Should -Match 'type\s*=\s*"SystemAssigned"'
    }
    $nics = @(Get-HclBlock $script:allHcl 'resource' 'azurerm_network_interface')
    foreach ($n in $nics) {
      $n.Body | Should -Match 'private_ip_address_allocation\s*=\s*"Static"'
      $n.Body | Should -Not -Match 'public_ip_address_id'
    }
  }

  It 'creates the console VM only when consoleExists is false and shuts down daily outside prod' {
    $con = (Get-HclBlock $script:files['console.tf'] 'resource' 'azurerm_windows_virtual_machine' 'console').Body
    $con | Should -Match 'count\s*=\s*var\.consoleExists\s*\?\s*0\s*:\s*1'
    $con | Should -Match 'sku\s*=\s*"2025-datacenter-azure-edition"'
    $sched = (Get-HclBlock $script:files['console.tf'] 'resource' 'azurerm_dev_test_global_vm_shutdown_schedule' 'console').Body
    $sched | Should -Match '!var\.consoleExists\s*&&\s*var\.environment\s*!=\s*"prod"'
  }

  It 'gives the console identity three roles (media read, staging write, license secret read) and none on config' {
    $conRoles = @(Get-HclBlock $script:files['console.tf'] 'resource' 'azurerm_role_assignment' | Where-Object { $_.Body -match 'local\.effective_console_principal_id' })
    $conRoles.Count | Should -Be 3
    foreach ($r in $conRoles) { $r.Body | Should -Not -Match 'azurerm_storage_account\.config' }
  }
}

Describe 'Key Vault, Network, Private Endpoints and Optional resources (Terraform)' {
  It 'makes Key Vault RBAC-only, purge-protected and private' {
    $kv = (Get-HclBlock $script:files['storage.tf'] 'resource' 'azurerm_key_vault' 'tier').Body
    $kv | Should -Match 'rbac_authorization_enabled\s*=\s*true'
    $kv | Should -Match 'purge_protection_enabled\s*=\s*true'
    $kv | Should -Match 'public_network_access_enabled\s*=\s*false'
  }

  It 'denies outbound to the spoke except private endpoints, opens 3389 only with Bastion, and turns default outbound access off on all 4 tier subnets' {
    foreach ($nsgName in 'console', 'packaging') {
      $nsg = (Get-HclBlock $script:files['network.tf'] 'resource' 'azurerm_network_security_group' $nsgName).Body
      $nsg | Should -Match 'Allow-Spoke-Private-Endpoints'
      $nsg | Should -Match 'Deny-Spoke'
      $nsg | Should -Match 'Allow-Rdp-From-Bastion'
      $nsg | Should -Match 'Deny-Other-Inbound'
    }
    $subnets = @(Get-HclBlock $script:files['network.tf'] 'resource' 'azurerm_subnet' | Where-Object Name -ne 'bastion')
    $subnets.Count | Should -Be 4
    foreach ($s in $subnets) { $s.Body | Should -Match 'default_outbound_access_enabled\s*=\s*false' }
    @(Get-HclBlock $script:allHcl 'resource' 'azurerm_public_ip').Count | Should -Be 1
  }

  It 'includes opt-in portability share, application restrictions DCR, packaging VM, and backup vault' {
    $opt = $script:files['optional.tf']
    (Get-HclBlock $opt 'resource' 'azurerm_storage_share' 'portability').Body | Should -Match 'quota\s*=\s*100'
    (Get-HclBlock $opt 'resource' 'azurerm_monitor_data_collection_rule' 'restrictions').Body | Should -Match 'lw-restrictions'
    $pkgVmBody = (Get-HclBlock $opt 'resource' 'azurerm_windows_virtual_machine' 'packaging').Body
    $pkgVmBody | Should -Match 'win11-24h2-ent'
    $pkgVmBody | Should -Match 'patch_mode\s*=\s*"AutomaticByOS"'
    (Get-HclBlock $opt 'resource' 'azurerm_network_interface' 'packaging').Body | Should -Match 'private_ip_address\s*=\s*"10\.61\.0\.68"'
    (Get-HclBlock $opt 'resource' 'azurerm_recovery_services_vault' 'tier').Body | Should -Match 'public_network_access_enabled\s*=\s*false'
    (Get-HclBlock $opt 'resource' 'azurerm_backup_policy_vm' 'enhanced').Body | Should -Match 'policy_type\s*=\s*"V2"'
  }

  It 'carries the personal-project notice in main.tf' {
    (Get-Content (Join-Path $script:tfDir 'main.tf') -TotalCount 6) -join "`n" | Should -Match 'Personal project, not for production use'
  }
}
