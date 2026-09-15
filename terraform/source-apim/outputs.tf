output "source_apim_id" {
  description = "The ID of the Source APIM service"
  value       = azurerm_api_management.source_apim.id
}

output "source_apim_name" {
  description = "The Name of the Source APIM service"
  value       = azurerm_api_management.source_apim.name
}

output "source_apim_gateway_url" {
  description = "The Gateway URL of the Source APIM service"
  value       = azurerm_api_management.source_apim.gateway_url
}

output "source_apim_portal_url" {
  description = "The Developer Portal URL of the Source APIM service"
  value       = azurerm_api_management.source_apim.developer_portal_url
}

output "api1_orders_url" {
  description = "Base invocation URL for Orders API"
  value       = "${azurerm_api_management.source_apim.gateway_url}/${azurerm_api_management_api.api_orders.path}"
}

output "api2_payments_url" {
  description = "Base invocation URL for Payments API"
  value       = "${azurerm_api_management.source_apim.gateway_url}/${azurerm_api_management_api.api_payments.path}"
}

output "sub_orders_primary_key" {
  description = "Primary key for Orders subscription"
  value       = azurerm_api_management_subscription.sub_orders.primary_key
  sensitive   = true
}

output "sub_payments_primary_key" {
  description = "Primary key for Payments subscription"
  value       = azurerm_api_management_subscription.sub_payments.primary_key
  sensitive   = true
}
