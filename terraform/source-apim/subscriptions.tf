# ==============================================================================
# Products & Subscriptions for API 1 (Orders API)
# ==============================================================================
resource "azurerm_api_management_product" "product_orders" {
  product_id            = "orders-product"
  api_management_name   = azurerm_api_management.source_apim.name
  resource_group_name   = azurerm_resource_group.source_rg.name
  display_name          = "Orders Product"
  subscription_required = true
  approval_required     = false
  published             = true
  description           = "Product containing Orders Service API"
}

resource "azurerm_api_management_product_api" "product_orders_api_link" {
  api_name            = azurerm_api_management_api.api_orders.name
  product_id          = azurerm_api_management_product.product_orders.product_id
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
}

resource "azurerm_api_management_subscription" "sub_orders" {
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  subscription_id     = "sub-orders-api"
  display_name        = "Orders API Client Subscription"
  product_id          = azurerm_api_management_product.product_orders.id
  state               = "active"
  allow_tracing       = true
}

# ==============================================================================
# Products & Subscriptions for API 2 (Payments API)
# ==============================================================================
resource "azurerm_api_management_product" "product_payments" {
  product_id            = "payments-product"
  api_management_name   = azurerm_api_management.source_apim.name
  resource_group_name   = azurerm_resource_group.source_rg.name
  display_name          = "Payments Product"
  subscription_required = true
  approval_required     = false
  published             = true
  description           = "Product containing Payments Gateway API"
}

resource "azurerm_api_management_product_api" "product_payments_api_link" {
  api_name            = azurerm_api_management_api.api_payments.name
  product_id          = azurerm_api_management_product.product_payments.product_id
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
}

resource "azurerm_api_management_subscription" "sub_payments" {
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  subscription_id     = "sub-payments-api"
  display_name        = "Payments API Client Subscription"
  product_id          = azurerm_api_management_product.product_payments.id
  state               = "active"
  allow_tracing       = true
}
