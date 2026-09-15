<#
.SYNOPSIS
    Removes built-in APIM system groups (administrators, developers, guests) from
    extracted artifacts. These groups are auto-provisioned by Azure in every APIM
    service/workspace and the publisher fails with "Creating system groups is not
    allowed" if it tries to PUT them.
.PARAMETER ArtifactsRootPath
    Root folder containing the extracted APIOps artifacts.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsRootPath
)

$ErrorActionPreference = "Stop"

$systemGroupNames = @("administrators", "developers", "guests")

# Built-in groups can appear at the global scope (groups/) or nested under any workspace (workspaces/*/groups/).
$groupFolders = Get-ChildItem -Path $ArtifactsRootPath -Directory -Recurse -Filter "groups" -ErrorAction SilentlyContinue

foreach ($groupFolder in $groupFolders) {
    foreach ($systemGroupName in $systemGroupNames) {
        $systemGroupPath = Join-Path $groupFolder.FullName $systemGroupName
        if (Test-Path $systemGroupPath) {
            Write-Host "Removing built-in system group: $systemGroupPath"
            Remove-Item -Path $systemGroupPath -Recurse -Force
        }
    }
}
