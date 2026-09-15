# ==============================================================================
# Backend Configuration for API 1 (Orders API)
# ==============================================================================
resource "azurerm_api_management_backend" "backend_orders" {
  name                = "backend-orders-api"
  resource_group_name = azurerm_resource_group.source_rg.name
  api_management_name = azurerm_api_management.source_apim.name
  protocol            = "http"
  url                 = var.api1_backend_url
  description         = "Dedicated Backend for Orders Service API"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  depends_on = [
    azurerm_api_management_named_value.nv_api1_backend_url
  ]
}

# ==============================================================================
# Backend Configuration for API 2 (Payments API)
# ==============================================================================
resource "azurerm_api_management_backend" "backend_payments" {
  name                = "backend-payments-api"
  resource_group_name = azurerm_resource_group.source_rg.name
  api_management_name = azurerm_api_management.source_apim.name
  protocol            = "http"
  url                 = var.api2_backend_url
  description         = "Dedicated Backend for Payments Service API"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  depends_on = [
    azurerm_api_management_named_value.nv_api2_backend_url
  ]
}
