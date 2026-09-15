<#
.SYNOPSIS
    Prunes extracted APIOps artifacts down to only the target API's own definition
    (apis/<api>/), removing every other resource kind (backends, named values,
    products, subscriptions, groups, etc.) since those are migrated separately via
    the scripts in apim-migrations-scripts/.
.PARAMETER ArtifactsRootPath
    Root folder containing the extracted APIOps artifacts.
.PARAMETER TargetApiName
    The API to keep (e.g. "orders-api" or "payments-api").
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsRootPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("orders-api", "payments-api")]
    [string]$TargetApiName
)

$ErrorActionPreference = "Stop"

# Resource kinds handled by apim-migrations-scripts, not by this publish pipeline.
$foldersToRemoveEntirely = @(
    "backends", "named values", "products", "subscriptions",
    "groups", "tags", "policy fragments", "diagnostics", "version sets", "loggers", "gateways"
)

foreach ($folderName in $foldersToRemoveEntirely) {
    $folderPath = Join-Path $ArtifactsRootPath $folderName
    if (Test-Path $folderPath) {
        Write-Host "Removing '$folderName' (handled separately via apim-migrations-scripts)"
        Remove-Item -Path $folderPath -Recurse -Force
    }
}

$apisFolderPath = Join-Path $ArtifactsRootPath "apis"
if (Test-Path $apisFolderPath) {
    Get-ChildItem -Path $apisFolderPath -Directory | ForEach-Object {
        if ($_.Name -ne $TargetApiName) {
            Write-Host "Removing 'apis/$($_.Name)' (not the target API)"
            Remove-Item -Path $_.FullName -Recurse -Force
        }
    }
}

Write-Host "Artifacts pruned to only the '$TargetApiName' definition."
