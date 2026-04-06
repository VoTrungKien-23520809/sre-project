resource "azurerm_resource_group" "rg_sre_project" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "vn_sre_project" {
  name                = var.virtual_network_name
  address_space       = var.virtual_network_address_space
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_sre_project.name
  tags                = var.tags
}

resource "azurerm_subnet" "subnet_sre_project" {
  name                 = var.subnet_name
  resource_group_name  = azurerm_resource_group.rg_sre_project.name
  virtual_network_name = azurerm_virtual_network.vn_sre_project.name
  address_prefixes     = var.subnet_address_prefixes
}

resource "azurerm_network_security_group" "nsg_sre_project" {
  name                = "nsg-sre-project"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_sre_project.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "allow_ssh" {
  name                        = "allow-ssh"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg_sre_project.name
  network_security_group_name = azurerm_network_security_group.nsg_sre_project.name
}

resource "azurerm_network_security_rule" "allow_icmp" {
  name                        = "allow-icmp"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Icmp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg_sre_project.name
  network_security_group_name = azurerm_network_security_group.nsg_sre_project.name
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet_sre_project.id
  network_security_group_id = azurerm_network_security_group.nsg_sre_project.id
}

resource "azurerm_public_ip" "pip_sre_project" {
  count               = var.vm_count
  name                = format("%s-%02d-pip", var.vm_name_prefix, count.index + 1)
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_sre_project.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "nic_sre_project" {
  count               = var.vm_count
  name                = format("%s-%02d-nic", var.vm_name_prefix, count.index + 1)
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_sre_project.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet_sre_project.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip_sre_project[count.index].id
  }
}

resource "azurerm_linux_virtual_machine" "vm_sre_project" {
  count               = var.vm_count
  name                = format("%s-%02d", var.vm_name_prefix, count.index + 1)
  computer_name       = format("%s-%02d", var.vm_name_prefix, count.index + 1)
  location            = var.location
  resource_group_name = azurerm_resource_group.rg_sre_project.name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  disable_password_authentication = false
  network_interface_ids = [
    azurerm_network_interface.nic_sre_project[count.index].id
  ]

  os_disk {
    name                 = format("%s-%02d-osdisk", var.vm_name_prefix, count.index + 1)
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = var.tags
}