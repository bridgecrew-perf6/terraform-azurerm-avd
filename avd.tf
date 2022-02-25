
# Resource Group

resource "azurerm_resource_group" "avd" {
  name     = "avd-rg"
  location = var.location
}

# Network Resources

resource "azurerm_virtual_network" "avd" {
  name                = "avd-vnet"
  location            = azurerm_resource_group.avd.location
  resource_group_name = azurerm_resource_group.avd.name
  address_space       = ["10.10.0.0/16"]

  # Use AADDS DCs as DNS servers
  dns_servers = azurerm_active_directory_domain_service.aadds.initial_replica_set.0.domain_controller_ip_addresses
}

resource "azurerm_subnet" "avd" {
  name                 = "avd-snet"
  resource_group_name  = azurerm_resource_group.avd.name
  virtual_network_name = azurerm_virtual_network.avd.name
  address_prefixes     = ["10.10.0.0/24"]
}

resource "azurerm_virtual_network_peering" "aadds_to_avd" {
  name                      = "hub-to-avd-peer"
  resource_group_name       = azurerm_resource_group.aadds.name
  virtual_network_name      = azurerm_virtual_network.aadds.name
  remote_virtual_network_id = azurerm_virtual_network.avd.id
}

resource "azurerm_virtual_network_peering" "avd_to_aadds" {
  name                      = "avd-to-aadds-peer"
  resource_group_name       = azurerm_resource_group.avd.name
  virtual_network_name      = azurerm_virtual_network.avd.name
  remote_virtual_network_id = azurerm_virtual_network.aadds.id
}

# Host Pool

locals {
  # Switzerland North is not supported
  avd_location = "West Europe"
}

resource "azurerm_virtual_desktop_host_pool" "avd" {
  name                = "avd-hp"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avd.name

  type                = "Pooled"
  load_balancer_type  = "BreadthFirst"
  friendly_name       = "AVD Host Pool using AADDS"
  start_vm_on_connect = true
}

resource "time_rotating" "avd_registration_expiration" {
  # Must be between 1 hour and 30 days
  rotation_days = 29
}

resource "azurerm_virtual_desktop_host_pool_registration_info" "avd" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.avd.id
  expiration_date = time_rotating.avd_registration_expiration.rotation_rfc3339
}

# Workspace and App Group

resource "azurerm_virtual_desktop_workspace" "avd" {
  name                = "avd-ws"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avd.name
}

resource "azurerm_virtual_desktop_application_group" "avd" {
  name                = "desktop-ag"
  location            = local.avd_location
  resource_group_name = azurerm_resource_group.avd.name

  type          = "Desktop"
  host_pool_id  = azurerm_virtual_desktop_host_pool.avd.id
  friendly_name = "Full Desktop"
}

resource "azurerm_virtual_desktop_workspace_application_group_association" "avd" {
  workspace_id         = azurerm_virtual_desktop_workspace.avd.id
  application_group_id = azurerm_virtual_desktop_application_group.avd.id
}

# Session Host VMs

resource "azurerm_network_interface" "avd" {
  count               = var.avd_host_pool_size
  name                = "avd-nic-${count.index}"
  location            = azurerm_resource_group.avd.location
  resource_group_name = azurerm_resource_group.avd.name

  ip_configuration {
    name                          = "avd-ipconf-${count.index}"
    subnet_id                     = azurerm_subnet.avd.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "random_password" "avd_local_admin" {
  length = 64
}

resource "azurerm_windows_virtual_machine" "avd" {
  count               = length(azurerm_network_interface.avd)
  name                = "avd-vm-${count.index}"
  location            = azurerm_resource_group.avd.location
  resource_group_name = azurerm_resource_group.avd.name

  size                  = "Standard_D4s_v5"
  license_type          = "Windows_Client" # https://docs.microsoft.com/en-us/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment#verify-your-vm-is-utilizing-the-licensing-benefit
  admin_username        = "avd-local-admin"
  admin_password        = random_password.avd_local_admin.result
  network_interface_ids = [azurerm_network_interface.avd[count.index].id]

  os_disk {
    name                 = "avd-osdisk-${count.index}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-21h2-avd"
    version   = "latest"
  }
}
