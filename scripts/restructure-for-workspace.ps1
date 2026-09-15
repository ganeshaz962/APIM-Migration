<#
.SYNOPSIS
    Re-nests APIOps-extracted artifacts (apis, backends, named values, products, subscriptions, etc.)
    under a "workspaces/<workspace-name>/" folder so the APIOps publisher deploys them into the
    destination APIM workspace instead of the global (non-workspace) scope.
.PARAMETER ArtifactsRootPath
    Root folder containing the extracted APIOps artifacts (e.g. apis/, backends/, named values/).
.PARAMETER WorkspaceName
    Name of the destination APIM workspace the artifacts should be nested under.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsRootPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName
)

$ErrorActionPreference = "Stop"

# Top-level resource folders APIOps extracts at the global (non-workspace) scope.
$resourceFolderNames = @(
    "apis", "backends", "named values", "products", "subscriptions",
    "tags", "policy fragments", "diagnostics", "groups", "loggers", "version sets"
)

if (-not (Test-Path $ArtifactsRootPath)) {
    throw "Artifacts root path '$ArtifactsRootPath' does not exist."
}

$workspaceRoot = Join-Path $ArtifactsRootPath "workspaces\$WorkspaceName"
New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null

foreach ($folderName in $resourceFolderNames) {
    $sourcePath = Join-Path $ArtifactsRootPath $folderName
    if (Test-Path $sourcePath) {
        $destinationPath = Join-Path $workspaceRoot $folderName
        Write-Host "Moving '$folderName' -> workspaces/$WorkspaceName/$folderName"
        Move-Item -Path $sourcePath -Destination $destinationPath -Force
    }
}

Write-Host "Artifacts nested under workspace '$WorkspaceName' at: $workspaceRoot"
