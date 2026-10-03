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
    from the stack's deny settings, so it may make this change. It then waits until the new revision is ready, and fails
    at once, with the container's last console lines, when the revision cannot start.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$deployable = [string] $OctopusParameters['Deployable.Name']
$port = [string] $OctopusParameters['Deployable.Port']
$registry = [string] $OctopusParameters['Azure.RegistryServer']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$app = "ca-$slug-$environmentName-$deployable"

# Container Apps reports a revision that cannot start long before its URL times out: read the latest revision and its
# replicas, and give the reason with the container's last console lines (the deploy identity may read them; the
# stack's deny settings keep everyone else from streaming logs).
function Get-RevisionProblem {
    # Through the ARM REST API, so it does not depend on the Azure CLI version of the worker image.
    param([Parameter(Mandatory)] [string] $App)
    $api = 'api-version=2024-03-01'
    $PSNativeCommandUseErrorActionPreference = $false
    $subscription = ([string] (az account show --query id --output tsv 2>$null)).Trim()
    $appId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.App/containerApps/$App"
    $appJson = az rest --method get --url "https://management.azure.com${appId}?$api" --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        $PSNativeCommandUseErrorActionPreference = $true
        Write-Warning "Could not read ${App}: $appJson"
        return $null
    }
    $latest = [string] ($appJson | ConvertFrom-Json -AsHashtable).properties.latestRevisionName
    $revisionJson = az rest --method get --url "https://management.azure.com$appId/revisions/${latest}?$api" --output json 2>$null
    $replicasJson = az rest --method get --url "https://management.azure.com$appId/revisions/$latest/replicas?$api" --output json 2>$null
    $PSNativeCommandUseErrorActionPreference = $true
    $revision = if ($revisionJson) { $revisionJson | ConvertFrom-Json -AsHashtable } else { $null }
    $replicas = if ($replicasJson) { @(($replicasJson | ConvertFrom-Json -AsHashtable).value) } else { @() }
    if ($revision -and ($revision.properties.provisioningState -eq 'Failed' -or $revision.properties.runningState -eq 'Failed')) {
        return "revision $latest is $($revision.properties.provisioningState)/$($revision.properties.runningState)"
    }
    foreach ($replica in $replicas) {
        foreach ($container in @($replica.properties.containers)) {
            $detail = [string] $container.runningStateDetails
            if ($detail -match 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError' -or [int] $container.restartCount -ge 3) {
                return "revision ${latest}: container $($container.name) is $($container.runningState) ($detail) after $($container.restartCount) restart(s)"
            }
        }
    }
    return $null
}

function Write-RevisionLog {
    param([Parameter(Mandatory)] [string] $App)
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = az containerapp logs show --name $App --resource-group $resourceGroup --type console --tail 40 --format text 2>&1
    $PSNativeCommandUseErrorActionPreference = $true
    Write-Host "Last console lines of ${App}:"
    @($lines) | ForEach-Object { Write-Host "  $_" }
}
$image = "$registry/$slug/${deployable}:$version"

$PSNativeCommandUseErrorActionPreference = $false
az containerapp show --name $app --resource-group $resourceGroup --output none 2>$null
$exists = $LASTEXITCODE -eq 0
$PSNativeCommandUseErrorActionPreference = $true
if (-not $exists) {
    Fail-Step "Container app $app does not exist: deploy a release of $slug-system to $environmentName first (the environment is created by the system pipeline)."
}

# The Container Apps commands of the Azure CLI draw a console animation on stderr while they wait, whatever the CLI
# settings, which Octopus logs as errors. So the update starts with --no-wait (the ingress port goes through az rest,
# as the same PATCH "az containerapp ingress update" sends) and this script does the waiting, with a readable log.
$current = az containerapp show --name $app --resource-group $resourceGroup --output json |
    ConvertFrom-Json -AsHashtable
$appUri = "https://management.azure.com$($current.id)?api-version=2024-03-01"
$before = [string] $current.properties.latestRevisionName

# The port changes only on the first deployment over the placeholder image.
$currentPort = [string] $current.properties.configuration.ingress.targetPort
if ($currentPort -ne $port) {
    $body = @{ properties = @{ configuration = @{ ingress = @{ targetPort = [int] $port; exposedPort = $null } } } } |
        ConvertTo-Json -Depth 6 -Compress
    az rest --method patch --url $appUri --body $body --headers 'Content-Type=application/json' --output none
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        $provisioning = [string] (az rest --method get --url $appUri --query properties.provisioningState --output tsv)
    } while ($provisioning.Trim() -notin @('Succeeded', 'Failed') -and (Get-Date) -lt $deadline)
    if ($provisioning.Trim() -ne 'Succeeded') {
        Fail-Step "The ingress of $app did not change to port $port (provisioning state $provisioning)."
    }
    Write-Host "Ingress of $app now targets port $port (was $currentPort)"
}

$currentImage = [string] $current.properties.template.containers[0].image
if ($currentImage -eq $image) {
    Write-Host "$app already runs $image"
}
else {
    Write-Host "Updating $app from $currentImage to $image"
    az containerapp update --name $app --resource-group $resourceGroup --image $image --no-wait --output none
}

# Ready when a new revision (or, for an unchanged image, the current one) is the latest and the latest ready one; a
# revision that cannot start fails at once.
$deadline = (Get-Date).AddMinutes(10)
while ($true) {
    $state = az containerapp show --name $app --resource-group $resourceGroup --query '{latest: properties.latestRevisionName, ready: properties.latestReadyRevisionName, provisioning: properties.provisioningState}' --output json | ConvertFrom-Json -AsHashtable
    $isNew = $currentImage -eq $image -or $state.latest -ne $before
    if ($isNew -and $state.provisioning -eq 'Succeeded' -and $state.latest -and $state.latest -eq $state.ready) {
        Write-Host "Revision $($state.latest) is ready"
        break
    }
    if ($state.provisioning -eq 'Failed') {
        Write-RevisionLog -App $app
        Fail-Step "Updating $app to $image failed (provisioning state Failed)."
    }
    $problem = if ($isNew) { Get-RevisionProblem -App $app } else { $null }
    if ($problem) {
        Write-RevisionLog -App $app
        Fail-Step "$deployable $version cannot start in ${environmentName}: $problem"
    }
    if ((Get-Date) -gt $deadline) {
        Write-RevisionLog -App $app
        Fail-Step "Revision $($state.latest) of $app was not ready within 10 minutes."
    }
    Write-Host "Waiting for the new revision (latest $($state.latest), ready $($state.ready), $($state.provisioning))"
    Start-Sleep -Seconds 10
}
Write-Highlight "$deployable $version runs in $environmentName ($app)."
