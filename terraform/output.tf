output "vm_names" {
  description = "Names of the created Ubuntu VMs"
  value       = azurerm_linux_virtual_machine.vm_sre_project[*].name
}

output "vm_public_ips" {
  description = "Public IP addresses of the Ubuntu VMs"
  value       = azurerm_public_ip.pip_sre_project[*].ip_address
}

output "vm_private_ips" {
  description = "Private IP addresses of the Ubuntu VMs"
  value       = azurerm_network_interface.nic_sre_project[*].private_ip_address
}
