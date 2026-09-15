terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 1.13"
    }
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

provider "azapi" {}

variable "resource_group_name" {
  type    = string
  default = "rg-apim-dest-migration"
}

variable "location" {
  type    = string
  default = "Central India"
}

variable "dest_apim_name" {
  type    = string
  default = "apim-dest-migration-prem"
}

variable "workspace_name" {
  type    = string
  default = "workspace-core-services"
}

resource "azurerm_resource_group" "dest_rg" {
  name     = var.resource_group_name
  location = var.location
}

# Destination APIM (Premium Tier with Workspaces capability)
resource "azurerm_api_management" "dest_apim" {
  name                = var.dest_apim_name
  location            = azurerm_resource_group.dest_rg.location
  resource_group_name = azurerm_resource_group.dest_rg.name
  publisher_name      = "Enterprise Target Team"
  publisher_email     = "apim-dest-admin@contoso.com"
  sku_name            = "Premium_1"

  identity {
    type = "SystemAssigned"
  }
}

# Target Workspace in Destination APIM
resource "azapi_resource" "apim_workspace" {
  type      = "Microsoft.ApiManagement/service/workspaces@2023-05-01-preview"
  name      = var.workspace_name
  parent_id = azurerm_api_management.dest_apim.id
  body = jsonencode({
    properties = {
      displayName = "Core Services Workspace"
      description = "Workspace hosting migrated Orders and Payments APIs"
    }
  })
}

output "dest_apim_id" {
  value = azurerm_api_management.dest_apim.id
}

output "workspace_id" {
  value = azapi_resource.apim_workspace.id
}
