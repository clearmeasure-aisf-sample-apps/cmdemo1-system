#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Verifies the deployables of one environment answer over HTTPS.

.DESCRIPTION
    Steps "Verify environment" (<slug>-system), "Verify deployable" and "Verify revert" (<slug>-<deployable>);
    octopus/projects.tf inlines this file. Reads the stack outputs of stack-<slug>-<env> and polls each deployable's
    URL (its health path once a version runs, / for a placeholder) until it answers 200. Deployable.Name limits the
    check to one deployable. The deadline covers a scale-from-zero start and a SQL database resuming from auto-pause;
    a revision that cannot start (crash loop, image pull failure, failed provisioning) fails the step at once, with
    the container's last console lines. A static site (hosting "staticwebapp" or "storagewebsite") has no revision to
    ask: only its URL is polled. A storage website serves nothing before its first release, so "Verify environment"
    passes over one the stack knows no version of.

    "Verify revert" runs only after a failed step, right after "Revert deployable" for a container deployable: it
    asks whether the previous image serves again. "Revert deployable" must have set Reverted (otherwise a healthy
    failed release would pass a health-only check). No version before, or nothing pinned: nothing was put back, the
    step says so and runs no check. In every case the deployment stays failed.

    A deployable that brings its own runtime (hosting "own") is not in the stack and verifies itself, in its own
    project (scripts/invoke-application.ps1). "Verify environment" therefore passes over a stack that lists no
    deployable where the system has such an application (variable System.OwnDeployables) and the stack is to create
    none in this environment (System.StackDeployables); a stack that lists none anywhere else fails the step.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# An Azure step can drop the result message of Fail-Step (exit code 255, no reason): the reason is a plain line too.
$octopusFailStep = if (Test-Path -LiteralPath function:Fail-Step) { ${function:Fail-Step} } else { $null }
function Fail-Step {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
    param([string] $Message)
    Write-Host $Message
    if ($octopusFailStep) { & $octopusFailStep $Message }
    exit -1
}

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$only = [string] $OctopusParameters['Deployable.Name']
$deadlineMinutes = 10
$step = [string] $OctopusParameters['Octopus.Step.Name']
$afterRevert = $step -eq 'Verify revert'
$release = [string] $OctopusParameters['Octopus.Release.Number']
$previous = ''
if ($afterRevert) {
    $previous = [string] $OctopusParameters['Octopus.Action[Pin version].Output.PreviousVersion']
    if ([string] $OctopusParameters['Octopus.Action[Pin version].Output.Pinned'] -ne 'True') {
        Write-Highlight "The deployment of $only $release to $environmentName failed, and it had not pinned the version (it failed before the pin, or the version was pinned already): nothing was put back, so there is no revert to verify. $environmentName keeps what the failed deployment left."
        exit 0
    }
    if (-not $previous) {
        Write-Highlight "The deployment of $only $release to $environmentName failed, and $environmentName ran no version before it: nothing was put back, so there is no revert to verify. $environmentName keeps what the failed deployment left."
        exit 0
    }
    if ([string] $OctopusParameters['Octopus.Action[Revert deployable].Output.Reverted'] -ne 'True') {
        $differs = "The deployment of $release failed, and versions.json names $previous once 'Revert pin' has run: what runs and what is recorded differ until a deployment succeeds."
        Write-Highlight "The deployment of $only $release to $environmentName failed, and the revert failed too: 'Revert deployable' did not put $previous back. The revert is not verified."
        Fail-Step "The revert is not verified: 'Revert deployable' did not put $only $previous back in $environmentName (its step is above). $environmentName may be down, or still run what the failed deployment left. $differs"
    }
    Write-Host "Asking whether $only $previous serves in $environmentName again after the container revert."
}

$stack = az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable
$deployables = @($stack.outputs.deployables.value | Where-Object { -not $only -or $_.name -eq $only })
if ($deployables.Count -eq 0) {
    # A deployable that brings its own runtime (hosting "own") is not in the stack: infra/ creates nothing for it, and
    # it verifies itself in its own project. Only a system that has one has these two variables (octopus/variables.tf):
    # the names of those applications, and the names of the deployables this environment's stack creates. An empty
    # stack is right only where the first names an application and the second names none.
    $own = @(([string] $OctopusParameters['System.OwnDeployables']) -split ',' | Where-Object { $_ })
    $expected = @(([string] $OctopusParameters['System.StackDeployables']) -split ',' | Where-Object { $_ })
    if (-not $only -and $own.Count -gt 0 -and $expected.Count -eq 0) {
        Write-Highlight "Stack stack-$slug-$environmentName creates no deployable: what runs in $environmentName brings its own runtime ($($own -join ', ')), and step 'Verify deployable' of each one's own project verifies it."
        return
    }
    Fail-Step "Stack stack-$slug-$environmentName lists no deployable$(if ($only) { " named $only" })."
}

# A deployable project verifies right after its update step, before the stack is applied again: the health path of
# the running version applies even when the stack output still describes the placeholder.
$healthPath = [string] $OctopusParameters['Deployable.HealthPath']

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

$failed = 0
foreach ($deployable in $deployables) {
    if (-not $only -and $deployable['hosting'] -eq 'storagewebsite' -and -not $deployable['version']) {
        Write-Highlight "SKIP $($deployable.name) in ${environmentName}: no release of it here yet, and a storage website serves nothing before the first ($($deployable.url))"
        continue
    }
    # Only a container app has one: empty for a static site.
    $app = [string] $deployable['containerApp']
    $path = if ($only -and $healthPath) { $healthPath } else { [string] $deployable.healthPath }
    $uri = "$($deployable.url.TrimEnd('/'))$path"
    $deadline = (Get-Date).AddMinutes($deadlineMinutes)
    $status = 0
    while ((Get-Date) -lt $deadline) {
        try {
            $status = [int] (Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 60 -SkipHttpErrorCheck).StatusCode
        }
        catch {
            $status = 0
        }
        if ($status -eq 200) {
            break
        }
        # What the platform says about an app that does not answer: the revision for a container app. A static site
        # (hosting "staticwebapp") has none: its URL is all there is to ask.
        $problem = switch ([string] $deployable['hosting']) {
            'staticwebapp' { $null }
            'storagewebsite' { $null }
            default { Get-RevisionProblem -App $app }
        }
        if ($problem) {
            Write-Warning "FAIL $($deployable.name) in ${environmentName}: $problem"
            if ($app) { Write-RevisionLog -App $app }
            $status = -1
            break
        }
        Write-Host "$uri answered $status; retrying"
        Start-Sleep -Seconds 15
    }
    if ($status -eq 200) {
        # After a container revert, health alone is not enough: the failed release may still answer 200. The image
        # tag must be the version before (Revert deployable set it; this proves it stayed).
        if ($afterRevert -and $app -and [string] $deployable['hosting'] -notin 'staticwebapp', 'storagewebsite') {
            $image = [string] (az containerapp show --name $app --resource-group $resourceGroup --query 'properties.template.containers[0].image' --output tsv)
            if (-not $image.EndsWith(":$previous")) {
                Write-Warning "FAIL $($deployable.name) in ${environmentName}: expected image tag :$previous after revert, got $image"
                $failed++
                continue
            }
            Write-Highlight "PASS $($deployable.name) in ${environmentName}: $uri (image $image)"
        }
        else {
            Write-Highlight "PASS $($deployable.name) in ${environmentName}: $uri"
        }
    }
    elseif ($status -eq -1) {
        $failed++
    }
    else {
        Write-Warning "FAIL $($deployable.name) in ${environmentName}: $uri did not answer 200 within $deadlineMinutes minutes (last $status)"
        if ($app) { Write-RevisionLog -App $app }
        $failed++
    }
}

# Capability "frontdoor": the environment's public address answers too. The endpoints are in stack-<slug>-<env>-edge
# in the Front Door profile's resource group (variable Azure.EdgeResourceGroup, empty without a profile). A new endpoint
# or route takes Front Door several minutes to reach every edge location, so this waits longer than for an app.
$edgeGroup = [string] $OctopusParameters['Azure.EdgeResourceGroup']
if ($edgeGroup) {
    $PSNativeCommandUseErrorActionPreference = $false
    $edgeJson = az stack group show --name "stack-$slug-$environmentName-edge" --resource-group $edgeGroup --output json 2>$null
    $hasEdge = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    $endpoints = if ($hasEdge) { @(($edgeJson | ConvertFrom-Json -AsHashtable).outputs.endpoints.value | Where-Object { -not $only -or $_.name -eq $only }) } else { @() }
    foreach ($endpoint in $endpoints) {
        $deployable = @($stack.outputs.deployables.value | Where-Object { $_.name -eq $endpoint.name })[0]
        $path = if ($only -and $healthPath) { $healthPath } else { [string] $deployable.healthPath }
        $uri = "$(([string] $endpoint.url).TrimEnd('/'))$path"
        $deadline = (Get-Date).AddMinutes(30)
        $status = 0
        while ((Get-Date) -lt $deadline) {
            try { $status = [int] (Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 60 -SkipHttpErrorCheck).StatusCode } catch { $status = 0 }
            if ($status -eq 200) { break }
            Write-Host "$uri answered $status; retrying"
            Start-Sleep -Seconds 30
        }
        if ($status -eq 200) {
            Write-Highlight "PASS $($endpoint.name) in ${environmentName} behind Front Door: $uri"
        }
        else {
            Write-Warning "FAIL $($endpoint.name) in ${environmentName}: the Front Door endpoint $uri did not answer 200 within 30 minutes (last $status)"
            $failed++
        }
    }
}

if ($failed -gt 0) {
    if ($afterRevert) {
        Fail-Step "The revert is not verified: $failed deployable(s) of $environmentName did not answer as $previous after 'Revert deployable'."
    }
    Fail-Step "$failed deployable(s) of $environmentName did not answer."
}

if ($afterRevert) {
    Write-Highlight "The deployment of $only $release to $environmentName failed. The revert is verified: $previous serves in $environmentName again."
}

# Said as an exit code: Octopus ends a step with the exit code of the last program its script ran, which may be one
# whose refusal was expected and handled (a dormant system's resources that are gone: cmdemo2, 2026-10-15).
exit 0
