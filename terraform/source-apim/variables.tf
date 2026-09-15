variable "resource_group_name" {
  type        = string
  description = "Name of the resource group for the source APIM instance"
  default     = "rg-apim-source-migration"
}

variable "location" {
  type        = string
  description = "Azure region where the source APIM instance will be deployed"
  default     = "Central India"
}

variable "apim_name" {
  type        = string
  description = "Name of the source Premium APIM service"
  default     = "apim-source-migration-prem"
}

variable "publisher_name" {
  type        = string
  description = "Name of the publisher organization"
  default     = "Enterprise API Team"
}

variable "publisher_email" {
  type        = string
  description = "Email of the publisher administrator"
  default     = "apim-admin@contoso.com"
}

variable "sku_name" {
  type        = string
  description = "SKU for the APIM instance (Premium_1 for Premium tier)"
  default     = "Premium_1"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to resources"
  default = {
    Environment = "Source"
    Project     = "APIM-Migration"
    ManagedBy   = "Terraform"
  }
}

# API 1 Variables
variable "api1_backend_url" {
  type        = string
  description = "Target backend URL for API 1 (Orders API)"
  default     = "https://orders-service.internal.contoso.com/api"
}

variable "api1_secret_key" {
  type        = string
  description = "Secret API key stored in Named Value for API 1"
  default     = "orders-secret-key-12345"
  sensitive   = true
}

# API 2 Variables
variable "api2_backend_url" {
  type        = string
  description = "Target backend URL for API 2 (Payments API)"
  default     = "https://payments-service.internal.contoso.com/api"
}

variable "api2_secret_key" {
  type        = string
  description = "Secret bearer/token stored in Named Value for API 2"
  default     = "payments-secret-token-67890"
  sensitive   = true
}
