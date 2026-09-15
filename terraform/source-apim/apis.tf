# ==============================================================================
# API 1: Orders API (Global / Non-workspace)
# ==============================================================================
resource "azurerm_api_management_api" "api_orders" {
  name                  = "orders-api"
  resource_group_name   = azurerm_resource_group.source_rg.name
  api_management_name   = azurerm_api_management.source_apim.name
  revision              = "1"
  display_name          = "Orders Service API"
  path                  = "orders"
  protocols             = ["https"]
  service_url           = var.api1_backend_url
  subscription_required = true

  description = "Orders management API service"
}

# Operations for API 1
resource "azurerm_api_management_api_operation" "get_orders" {
  operation_id        = "get-orders"
  api_name            = azurerm_api_management_api.api_orders.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  display_name        = "Get All Orders"
  method              = "GET"
  url_template        = "/"
  description         = "Retrieve all orders"

  response {
    status_code = 200
    description = "Successful list of orders"
  }
}

resource "azurerm_api_management_api_operation" "create_order" {
  operation_id        = "create-order"
  api_name            = azurerm_api_management_api.api_orders.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  display_name        = "Create Order"
  method              = "POST"
  url_template        = "/"
  description         = "Create a new order record"

  response {
    status_code = 201
    description = "Order created successfully"
  }
}

resource "azurerm_api_management_api_operation" "get_order_by_id" {
  operation_id        = "get-order-by-id"
  api_name            = azurerm_api_management_api.api_orders.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  display_name        = "Get Order By ID"
  method              = "GET"
  url_template        = "/{orderId}"
  description         = "Fetch order details by order ID"

  template_parameter {
    name     = "orderId"
    type     = "string"
    required = true
  }

  response {
    status_code = 200
    description = "Order details returned"
  }
}

# Policy for API 1
resource "azurerm_api_management_api_policy" "api_orders_policy" {
  api_name            = azurerm_api_management_api.api_orders.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name

  xml_content = file("${path.module}/policies/api1-orders-policy.xml")

  depends_on = [
    azurerm_api_management_backend.backend_orders,
    azurerm_api_management_named_value.nv_api1_api_key
  ]
}

# ==============================================================================
# API 2: Payments API (Global / Non-workspace)
# ==============================================================================
resource "azurerm_api_management_api" "api_payments" {
  name                  = "payments-api"
  resource_group_name   = azurerm_resource_group.source_rg.name
  api_management_name   = azurerm_api_management.source_apim.name
  revision              = "1"
  display_name          = "Payments Gateway API"
  path                  = "payments"
  protocols             = ["https"]
  service_url           = var.api2_backend_url
  subscription_required = true

  description = "Payments transaction API service"
}

# Operations for API 2
resource "azurerm_api_management_api_operation" "get_payments" {
  operation_id        = "get-payments"
  api_name            = azurerm_api_management_api.api_payments.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  display_name        = "Get Payments History"
  method              = "GET"
  url_template        = "/"
  description         = "Retrieve transaction payments"

  response {
    status_code = 200
    description = "Payment history retrieved"
  }
}

resource "azurerm_api_management_api_operation" "process_payment" {
  operation_id        = "process-payment"
  api_name            = azurerm_api_management_api.api_payments.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  display_name        = "Process Payment"
  method              = "POST"
  url_template        = "/process"
  description         = "Submit a payment charge"

  response {
    status_code = 200
    description = "Payment processed successfully"
  }
}

resource "azurerm_api_management_api_operation" "get_payment_by_id" {
  operation_id        = "get-payment-by-id"
  api_name            = azurerm_api_management_api.api_payments.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name
  display_name        = "Get Payment By ID"
  method              = "GET"
  url_template        = "/{paymentId}"
  description         = "Fetch payment status by transaction ID"

  template_parameter {
    name     = "paymentId"
    type     = "string"
    required = true
  }

  response {
    status_code = 200
    description = "Payment transaction status"
  }
}

# Policy for API 2
resource "azurerm_api_management_api_policy" "api_payments_policy" {
  api_name            = azurerm_api_management_api.api_payments.name
  api_management_name = azurerm_api_management.source_apim.name
  resource_group_name = azurerm_resource_group.source_rg.name

  xml_content = file("${path.module}/policies/api2-payments-policy.xml")

  depends_on = [
    azurerm_api_management_backend.backend_payments,
    azurerm_api_management_named_value.nv_api2_secret_header
  ]
}
