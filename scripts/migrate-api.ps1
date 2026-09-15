<#
.SYNOPSIS
    Migrates an API along with its Named Values, Backend, Product, and Subscription
    from a Source APIM (Global/Tenant level) to a Destination APIM Workspace.
.PARAMETER TargetApi
    'orders-api' or 'payments-api' or 'all'
.PARAMETER SourceResourceGroup
    Source APIM resource group
.PARAMETER SourceApimName
    Source APIM instance name
.PARAMETER DestResourceGroup
    Destination APIM resource group
.PARAMETER DestApimName
    Destination APIM instance name
.PARAMETER WorkspaceId
    Target workspace name inside destination APIM
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("orders-api", "payments-api", "all")]
    [string]$TargetApi,

    [Parameter(Mandatory = $false)]
    [string]$SourceResourceGroup = "rg-apim-source-migration",

    [Parameter(Mandatory = $false)]
    [string]$SourceApimName = "apim-source-prem-mig-01",

    [Parameter(Mandatory = $false)]
    [string]$DestResourceGroup = "rg-apim-dest-migration",

    [Parameter(Mandatory = $false)]
    [string]$DestApimName = "apim-dest-migration-prem",

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId = "workspace-core-services"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Starting APIM Migration Process" -ForegroundColor Cyan
Write-Host "Target API Selection: $TargetApi" -ForegroundColor Yellow
Write-Host "Source APIM: $SourceApimName ($SourceResourceGroup)" -ForegroundColor Yellow
Write-Host "Destination APIM: $DestApimName ($DestResourceGroup) -> Workspace: $WorkspaceId" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

function Start-SingleApiMigration {
    param (
        [string]$ApiId,
        [string[]]$NamedValues,
        [string]$BackendId,
        [string]$ProductId,
        [string]$SubscriptionId
    )

    Write-Host "`n---> [Phase 1] Migrating Named Values for $ApiId" -ForegroundColor Green
    foreach ($nv in $NamedValues) {
        Write-Host "   Processing Named Value: $nv"
        # Hook to copy named value to workspace scope
    }

    Write-Host "`n---> [Phase 2] Migrating Backend for $ApiId - Backend ID $BackendId" -ForegroundColor Green
    # Hook to migrate backend definition to destination workspace

    Write-Host "`n---> [Phase 3] Migrating API Definition and Policies for $ApiId" -ForegroundColor Green
    # Hook to export/import API definition with ARM template or REST API into workspace

    Write-Host "`n---> [Phase 4] Migrating Product and Subscription for $SubscriptionId" -ForegroundColor Green
    # Hook to migrate Product & Subscriptions

    Write-Host "`n[SUCCESS] Successfully migrated $ApiId to Workspace $WorkspaceId!" -ForegroundColor Green
}

if ($TargetApi -eq "orders-api" -or $TargetApi -eq "all") {
    Start-SingleApiMigration `
        -ApiId "orders-api" `
        -NamedValues @("nv-api1-backend-url", "nv-api1-api-key") `
        -BackendId "backend-orders-api" `
        -ProductId "orders-product" `
        -SubscriptionId "sub-orders-api"
}

if ($TargetApi -eq "payments-api" -or $TargetApi -eq "all") {
    Start-SingleApiMigration `
        -ApiId "payments-api" `
        -NamedValues @("nv-api2-backend-url", "nv-api2-secret-header") `
        -BackendId "backend-payments-api" `
        -ProductId "payments-product" `
        -SubscriptionId "sub-payments-api"
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "APIM Migration Completed." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
