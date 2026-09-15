<#
.SYNOPSIS
    Prunes extracted APIOps artifacts down to only the resources belonging to a
    single target API, so the publisher never pushes an unrelated API into the
    destination workspace (needed because the extractor's configuration.extractor.yaml
    API filter is not being honored on the current APIOps release).
.PARAMETER ArtifactsRootPath
    Root folder containing the extracted APIOps artifacts.
.PARAMETER TargetApiName
    The API to keep (e.g. "orders-api" or "payments-api"). All other APIs, and
    their linked backends/named values/products/subscriptions, are removed.
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

# Maps each API to the sibling resources that belong exclusively to it.
$apiResourceMap = @{
    "orders-api" = @{
        Backends      = @("backend-orders-api")
        NamedValues   = @("nv-api1-backend-url", "nv-api1-api-key")
        Products      = @("orders-product")
        Subscriptions = @("sub-orders-api")
    }
    "payments-api" = @{
        Backends      = @("backend-payments-api")
        NamedValues   = @("nv-api2-backend-url", "nv-api2-secret-header")
        Products      = @("payments-product")
        Subscriptions = @("sub-payments-api")
    }
}

$keep = $apiResourceMap[$TargetApiName]

function Remove-UnrelatedChildren {
    param (
        [string]$FolderName,
        [string[]]$NamesToKeep
    )

    $folderPath = Join-Path $ArtifactsRootPath $FolderName
    if (-not (Test-Path $folderPath)) { return }

    Get-ChildItem -Path $folderPath -Directory | ForEach-Object {
        if ($NamesToKeep -notcontains $_.Name) {
            Write-Host "Removing '$FolderName/$($_.Name)' (not part of $TargetApiName)"
            Remove-Item -Path $_.FullName -Recurse -Force
        }
    }
}

Remove-UnrelatedChildren -FolderName "apis" -NamesToKeep @($TargetApiName)
Remove-UnrelatedChildren -FolderName "backends" -NamesToKeep $keep.Backends
Remove-UnrelatedChildren -FolderName "named values" -NamesToKeep $keep.NamedValues
Remove-UnrelatedChildren -FolderName "products" -NamesToKeep $keep.Products
Remove-UnrelatedChildren -FolderName "subscriptions" -NamesToKeep $keep.Subscriptions

Write-Host "Artifacts pruned to only '$TargetApiName' and its linked resources."
