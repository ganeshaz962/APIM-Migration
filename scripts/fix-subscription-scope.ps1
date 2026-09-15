<#
.SYNOPSIS
    Rewrites the "scope" property inside every extracted subscriptionInformation.json
    so it points at the destination APIM (and workspace, if applicable) instead of the
    source APIM the subscription was extracted from. Required because APIM subscriptions
    must be scoped to a product at the exact same level (service vs. workspace) as the
    subscription itself.
.PARAMETER ArtifactsRootPath
    Root folder containing the extracted APIOps artifacts.
.PARAMETER SubscriptionId
    Destination Azure subscription ID.
.PARAMETER ResourceGroupName
    Destination APIM resource group.
.PARAMETER ApimServiceName
    Destination APIM service name.
.PARAMETER WorkspaceName
    Destination APIM workspace name. Leave empty to scope subscriptions at the service level.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsRootPath,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ApimServiceName,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = ""
)

$ErrorActionPreference = "Stop"

$serviceBaseUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimServiceName"
$scopeBaseUri = if ($WorkspaceName -ne "") { "$serviceBaseUri/workspaces/$WorkspaceName" } else { $serviceBaseUri }

$subscriptionFiles = Get-ChildItem -Path $ArtifactsRootPath -Recurse -Filter "subscriptionInformation.json" -ErrorAction SilentlyContinue

foreach ($file in $subscriptionFiles) {
    $json = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json

    if (-not $json.properties.scope) { continue }

    $productName = ($json.properties.scope -split "/products/")[-1]
    $newScope = "$scopeBaseUri/products/$productName"

    Write-Host "Rewriting scope for $($file.FullName): $($json.properties.scope) -> $newScope"
    $json.properties.scope = $newScope
    $json | ConvertTo-Json -Depth 10 | Set-Content -Path $file.FullName
}
