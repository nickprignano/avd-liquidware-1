# Opt-in tier resources (deploy-spec sections 4, 5 and 8.1):
# - Portability share on the existing landing zone profiles storage account
# - Data collection rule for ProfileUnity application restriction events
# - On-demand FlexApp packaging VM in snet-lw-packaging
# - Recovery Services vault with Enhanced backup policy

# ---------- Portability share ----------

data "azurerm_storage_account" "profiles" {
  count               = (var.enablePortability && var.profilesStorageAccountName != "") ? 1 : 0
  name                = var.profilesStorageAccountName
  resource_group_name = var.profilesResourceGroupName
}

resource "azurerm_storage_share" "portability" {
  count              = (var.enablePortability && var.profilesStorageAccountName != "") ? 1 : 0
  name               = "portability"
  storage_account_id = data.azurerm_storage_account.profiles[0].id
  quota              = 100
  enabled_protocol   = "SMB"
}

# ---------- Application restrictions DCR ----------

resource "azurerm_monitor_data_collection_rule" "restrictions" {
  count               = (var.enableApplicationRestrictions && var.logAnalyticsWorkspaceId != "") ? 1 : 0
  name                = "dcr-${local.base}-liquidware"
  location            = var.location
  resource_group_name = azurerm_resource_group.tier.name
  kind                = "Windows"
  tags                = local.all_tags

  destinations {
    log_analytics {
      workspace_resource_id = var.logAnalyticsWorkspaceId
      name                  = "law"
    }
  }

  data_flow {
    streams      = ["Microsoft-Event"]
    destinations = ["law"]
  }

  data_sources {
    windows_event_log {
      name    = "lw-restrictions"
      streams = ["Microsoft-Event"]
      x_path_queries = [
        "Application!*[System[(Provider[@Name='ProfileUnity'] or Provider[@Name='Liquidware'])]]",
        "Microsoft-Windows-AppLocker/EXE and DLL!*[System[(EventID=8002 or EventID=8003 or EventID=8004)]]"
      ]
    }
  }
}

# ---------- On-demand FlexApp packaging VM ----------

resource "azurerm_key_vault_secret" "packaging_admin_password" {
  count        = var.deployPackagingVm ? 1 : 0
  name         = "lw-packaging-password"
  value        = var.packagingAdminPassword
  content_type = "Local administrator lwadmin on ${local.packaging_vm_name}"
  key_vault_id = azurerm_key_vault.tier.id
}

resource "azurerm_network_interface" "packaging" {
  count               = var.deployPackagingVm ? 1 : 0
  name                = "nic-${local.packaging_vm_name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.tier.name
  tags                = local.all_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.packaging.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.61.0.68"
  }
}

resource "azurerm_windows_virtual_machine" "packaging" {
  count                      = var.deployPackagingVm ? 1 : 0
  name                       = local.packaging_vm_name
  computer_name              = local.packaging_computer
  location                   = var.location
  resource_group_name        = azurerm_resource_group.tier.name
  size                       = "Standard_D2as_v5"
  admin_username             = "lwadmin"
  admin_password             = var.packagingAdminPassword
  network_interface_ids      = [azurerm_network_interface.packaging[0].id]
  secure_boot_enabled        = true
  vtpm_enabled               = true
  encryption_at_host_enabled = true
  provision_vm_agent         = true
  enable_automatic_updates   = true
  patch_mode                 = "AutomaticByOS"
  tags                       = merge(local.all_tags, { "liquidware-role" = "packaging" })

  identity {
    type = "SystemAssigned"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-24h2-ent"
    version   = "latest"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  boot_diagnostics {}
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "packaging" {
  count                 = (var.deployPackagingVm && var.environment != "prod") ? 1 : 0
  virtual_machine_id    = azurerm_windows_virtual_machine.packaging[0].id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.autoShutdownTime
  timezone              = "UTC"
  tags                  = local.all_tags

  notification_settings {
    enabled = false
  }
}

resource "azurerm_role_assignment" "packaging_media_read" {
  count              = var.deployPackagingVm ? 1 : 0
  scope              = azurerm_storage_container.media.resource_manager_id
  role_definition_id = local.role_definition_ids.blobDataReader
  principal_id       = azurerm_windows_virtual_machine.packaging[0].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "packaging_appattach_write" {
  count              = var.deployPackagingVm ? 1 : 0
  scope              = azurerm_storage_share.appattach.resource_manager_id
  role_definition_id = local.role_definition_ids.filePrivilegedContributor
  principal_id       = azurerm_windows_virtual_machine.packaging[0].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# ---------- Backup vault ----------

resource "azurerm_recovery_services_vault" "tier" {
  count                         = var.enableBackup ? 1 : 0
  name                          = "rsv-${local.base}-liquidware"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.tier.name
  sku                           = "Standard"
  public_network_access_enabled = false
  tags                          = local.all_tags
}

resource "azurerm_backup_policy_vm" "enhanced" {
  count                          = var.enableBackup ? 1 : 0
  name                           = "EnhancedPolicy"
  resource_group_name            = azurerm_resource_group.tier.name
  recovery_vault_name            = azurerm_recovery_services_vault.tier[0].name
  policy_type                    = "V2"
  timezone                       = "UTC"
  instant_restore_retention_days = 2

  backup {
    frequency = "Daily"
    time      = "02:00"
  }

  retention_daily {
    count = 14
  }
}
