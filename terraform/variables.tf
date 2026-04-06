variable "resource_group_name" {
  type    = string
  default = "rg-sre-project"
}

variable "location" {
  type    = string
  default = "centralindia"
}

variable "virtual_network_name" {
  type    = string
  default = "vn-sre-project"
}

variable "virtual_network_address_space" {
  type    = list(string)
  default = ["10.0.0.0/16"]
}

variable "subnet_name" {
  type    = string
  default = "kubernetes-subnet"
}

variable "subnet_address_prefixes" {
  type    = list(string)
  default = ["10.0.1.0/24"]
}

variable "vm_name_prefix" {
  type    = string
  default = "node"
}

variable "vm_count" {
  type    = number
  default = 3
}

variable "vm_size" {
  type    = string
  default = "Standard_B2as_v2"
}

variable "admin_username" {
  type    = string
  default = "ubuntu"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "tags" {
  type = map(string)
  default = {
    project = "sre-project"
  }
}
