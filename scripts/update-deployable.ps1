#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Points the deployable's container app at the release's image.

.DESCRIPTION
    Step "Update deployable" of the Octopus project <slug>-<deployable>; octopus/projects.tf inlines this file. The
    fast path of a deployment: the image tag <registry>/<slug>/<deployable>:<release> and the app's port, on the
    container app the stack created. The pin step already wrote the same version to Git, so the next apply of the
    stack (an environment release, or the nightly drift check) agrees with what runs. The deploy identity is excluded
    from the stack's deny settings, so it may make this change.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$deployable = [string] $OctopusParameters['Deployable.Name']
$port = [string] $OctopusParameters['Deployable.Port']
$registry = [string] $OctopusParameters['Azure.RegistryServer']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$app = "ca-$slug-$environmentName-$deployable"
$image = "$registry/$slug/${deployable}:$version"

$PSNativeCommandUseErrorActionPreference = $false
az containerapp show --name $app --resource-group $resourceGroup --output none 2>$null
$exists = $LASTEXITCODE -eq 0
$PSNativeCommandUseErrorActionPreference = $true
if (-not $exists) {
    Fail-Step "Container app $app does not exist: deploy a release of $slug-system to $environmentName first (the environment is created by the system pipeline)."
}

Write-Host "Updating $app to $image"
az containerapp update --name $app --resource-group $resourceGroup --image $image --output none
az containerapp ingress update --name $app --resource-group $resourceGroup --target-port $port --output none
Write-Highlight "$deployable $version runs in $environmentName ($app)."
