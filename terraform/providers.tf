terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}
provider "azurerm" {
  subscription_id = "1664c3de-3bce-4896-b6f1-03cafbcb25d9"
  features {
  }
}