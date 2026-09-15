targetScope = 'resourceGroup'

@description('Azure region for resources')
param location string = resourceGroup().location

@description('Name of the APIM instance')
param apimName string = 'apim-source-prem-mig-01'

@description('Publisher Organization Name')
param publisherName string = 'Contoso Global Tech'

@description('Publisher Email')
param publisherEmail string = 'apim-admin@contoso.com'

@description('APIM SKU (Premium for workspace compatibility)')
param skuName string = 'Premium'

@description('APIM Unit Capacity')
param skuCapacity int = 1

@description('API 1 Backend URL')
param api1BackendUrl string = 'https://orders-service.internal.contoso.com/api'

@secure()
@description('API 1 Secret Key')
param api1SecretKey string = 'orders-super-secret-key-12345'

@description('API 2 Backend URL')
param api2BackendUrl string = 'https://payments-service.internal.contoso.com/api'

@secure()
@description('API 2 Secret Key')
param api2SecretKey string = 'payments-super-secret-token-67890'

// 1. APIM Instance
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
  identity: {
    type: 'SystemAssigned'
  }
  tags: {
    Environment: 'Source'
    Project: 'APIM-Migration'
    Tier: 'Premium'
  }
}

// 2. Named Values
resource nvApi1BackendUrl 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'nv-api1-backend-url'
  properties: {
    displayName: 'nv-api1-backend-url'
    value: api1BackendUrl
    secret: false
    tags: ['api1', 'orders', 'backend']
  }
}

resource nvApi1SecretKey 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'nv-api1-api-key'
  properties: {
    displayName: 'nv-api1-api-key'
    value: api1SecretKey
    secret: true
    tags: ['api1', 'orders', 'security']
  }
}

resource nvApi2BackendUrl 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'nv-api2-backend-url'
  properties: {
    displayName: 'nv-api2-backend-url'
    value: api2BackendUrl
    secret: false
    tags: ['api2', 'payments', 'backend']
  }
}

resource nvApi2SecretKey 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'nv-api2-secret-header'
  properties: {
    displayName: 'nv-api2-secret-header'
    value: api2SecretKey
    secret: true
    tags: ['api2', 'payments', 'security']
  }
}

// 3. Backends
resource backendOrders 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'backend-orders-api'
  properties: {
    description: 'Dedicated Backend for Orders Service API'
    protocol: 'http'
    url: api1BackendUrl
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [nvApi1BackendUrl]
}

resource backendPayments 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'backend-payments-api'
  properties: {
    description: 'Dedicated Backend for Payments Service API'
    protocol: 'http'
    url: api2BackendUrl
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
  dependsOn: [nvApi2BackendUrl]
}

// 4. Products
resource productOrders 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'orders-product'
  properties: {
    displayName: 'Orders Product'
    description: 'Product containing Orders Service API'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource productPayments 'Microsoft.ApiManagement/service/products@2023-05-01-preview' = {
  parent: apim
  name: 'payments-product'
  properties: {
    displayName: 'Payments Product'
    description: 'Product containing Payments Gateway API'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// 5. API 1 (Orders)
resource apiOrders 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'orders-api'
  properties: {
    displayName: 'Orders Service API'
    path: 'orders'
    protocols: ['https']
    serviceUrl: api1BackendUrl
    subscriptionRequired: true
  }
}

resource apiOrdersPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: apiOrders
  name: 'policy'
  properties: {
    value: '<policies><inbound><base /><set-backend-service backend-id="backend-orders-api" /><set-header name="X-Api-Key" exists-action="override"><value>{{nv-api1-api-key}}</value></set-header></inbound><backend><base /></backend><outbound><base /><set-header name="X-Powered-By" exists-action="delete" /></outbound><on-error><base /></on-error></policies>'
    format: 'xml'
  }
  dependsOn: [backendOrders, nvApi1SecretKey]
}

resource productOrdersLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: productOrders
  name: apiOrders.name
}

resource subOrders 'Microsoft.ApiManagement/service/subscriptions@2023-05-01-preview' = {
  parent: apim
  name: 'sub-orders-api'
  properties: {
    displayName: 'Orders API Client Subscription'
    scope: productOrders.id
    state: 'active'
    allowTracing: true
  }
}

// 6. API 2 (Payments)
resource apiPayments 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'payments-api'
  properties: {
    displayName: 'Payments Gateway API'
    path: 'payments'
    protocols: ['https']
    serviceUrl: api2BackendUrl
    subscriptionRequired: true
  }
}

resource apiPaymentsPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: apiPayments
  name: 'policy'
  properties: {
    value: '<policies><inbound><base /><set-backend-service backend-id="backend-payments-api" /><set-header name="Authorization" exists-action="override"><value>Bearer {{nv-api2-secret-header}}</value></set-header></inbound><backend><base /></backend><outbound><base /><set-header name="X-Payments-Gateway" exists-action="override"><value>Source-APIM</value></set-header></outbound><on-error><base /></on-error></policies>'
    format: 'xml'
  }
  dependsOn: [backendPayments, nvApi2SecretKey]
}

resource productPaymentsLink 'Microsoft.ApiManagement/service/products/apis@2023-05-01-preview' = {
  parent: productPayments
  name: apiPayments.name
}

resource subPayments 'Microsoft.ApiManagement/service/subscriptions@2023-05-01-preview' = {
  parent: apim
  name: 'sub-payments-api'
  properties: {
    displayName: 'Payments API Client Subscription'
    scope: productPayments.id
    state: 'active'
    allowTracing: true
  }
}

output apimId string = apim.id
output gatewayUrl string = apim.properties.gatewayUrl
output ordersApiUrl string = '${apim.properties.gatewayUrl}/orders'
output paymentsApiUrl string = '${apim.properties.gatewayUrl}/payments'
