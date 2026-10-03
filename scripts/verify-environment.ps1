#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Verifies the deployables of one environment answer over HTTPS.

.DESCRIPTION
    Last step of every Octopus project of the system ("Verify environment" in <slug>-system, "Verify deployable" in
    <slug>-<deployable>); octopus/projects.tf inlines this file. Reads the stack outputs of stack-<slug>-<env> and
    polls each deployable's URL (its health path once a version runs, / for a placeholder) until it answers 200.
    Deployable.Name limits the check to one deployable. The deadline covers a scale-from-zero start and a SQL
    database resuming from auto-pause; a revision that cannot start (crash loop, image pull failure, failed
    provisioning) fails the step at once, with the container's last console lines.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$only = [string] $OctopusParameters['Deployable.Name']
$deadlineMinutes = 10

$stack = az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable
$deployables = @($stack.outputs.deployables.value | Where-Object { -not $only -or $_.name -eq $only })
if ($deployables.Count -eq 0) {
    Fail-Step "Stack stack-$slug-$environmentName lists no deployable$(if ($only) { " named $only" })."
}

# A deployable project verifies right after its update step, before the stack is applied again: the health path of
# the running version applies even when the stack output still describes the placeholder.
$healthPath = [string] $OctopusParameters['Deployable.HealthPath']

# Container Apps reports a revision that cannot start long before its URL times out: read the latest revision and its
# replicas, and give the reason with the container's last console lines (the deploy identity may read them; the
# stack's deny settings keep everyone else from streaming logs).
function Get-RevisionProblem {
    param([Parameter(Mandatory)] [string] $App)
    $PSNativeCommandUseErrorActionPreference = $false
    $latest = ([string] (az containerapp show --name $App --resource-group $resourceGroup --query properties.latestRevisionName --output tsv 2>$null)).Trim()
    if (-not $latest) { return $null }
    $revision = az containerapp revision show --name $App --resource-group $resourceGroup --revision $latest --output json 2>$null | ConvertFrom-Json -AsHashtable
    $replicas = @(az containerapp replica list --name $App --resource-group $resourceGroup --revision $latest --output json 2>$null | ConvertFrom-Json -AsHashtable)
    $PSNativeCommandUseErrorActionPreference = $true
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
    $app = "ca-$slug-$environmentName-$($deployable.name)"
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
        $problem = Get-RevisionProblem -App $app
        if ($problem) {
            Write-Warning "FAIL $($deployable.name) in ${environmentName}: $problem"
            Write-RevisionLog -App $app
            $status = -1
            break
        }
        Write-Host "$uri answered $status; retrying"
        Start-Sleep -Seconds 15
    }
    if ($status -eq 200) {
        Write-Highlight "PASS $($deployable.name) in ${environmentName}: $uri"
    }
    elseif ($status -eq -1) {
        $failed++
    }
    else {
        Write-Warning "FAIL $($deployable.name) in ${environmentName}: $uri did not answer 200 within $deadlineMinutes minutes (last $status)"
        Write-RevisionLog -App $app
        $failed++
    }
}

if ($failed -gt 0) {
    Fail-Step "$failed deployable(s) of $environmentName did not answer."
}
