# ==============================================================================
# Named Values for API 1 (Orders API)
# ==============================================================================
resource "azurerm_api_management_named_value" "nv_api1_backend_url" {
  name                = "nv-api1-backend-url"
  resource_group_name = azurerm_resource_group.source_rg.name
  api_management_name = azurerm_api_management.source_apim.name
  display_name        = "nv-api1-backend-url"
  value               = var.api1_backend_url
  secret              = false
  tags                = ["api1", "orders", "backend"]
}

resource "azurerm_api_management_named_value" "nv_api1_api_key" {
  name                = "nv-api1-api-key"
  resource_group_name = azurerm_resource_group.source_rg.name
  api_management_name = azurerm_api_management.source_apim.name
  display_name        = "nv-api1-api-key"
  value               = var.api1_secret_key
  secret              = true
  tags                = ["api1", "orders", "security"]
}

# ==============================================================================
# Named Values for API 2 (Payments API)
# ==============================================================================
resource "azurerm_api_management_named_value" "nv_api2_backend_url" {
  name                = "nv-api2-backend-url"
  resource_group_name = azurerm_resource_group.source_rg.name
  api_management_name = azurerm_api_management.source_apim.name
  display_name        = "nv-api2-backend-url"
  value               = var.api2_backend_url
  secret              = false
  tags                = ["api2", "payments", "backend"]
}

resource "azurerm_api_management_named_value" "nv_api2_secret_header" {
  name                = "nv-api2-secret-header"
  resource_group_name = azurerm_resource_group.source_rg.name
  api_management_name = azurerm_api_management.source_apim.name
  display_name        = "nv-api2-secret-header"
  value               = var.api2_secret_key
  secret              = true
  tags                = ["api2", "payments", "security"]
}
