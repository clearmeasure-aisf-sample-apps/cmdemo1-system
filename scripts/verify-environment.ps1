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
    database resuming from auto-pause.
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

$failed = 0
foreach ($deployable in $deployables) {
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
        Write-Host "$uri answered $status; retrying"
        Start-Sleep -Seconds 15
    }
    if ($status -eq 200) {
        Write-Highlight "PASS $($deployable.name) in ${environmentName}: $uri"
    }
    else {
        Write-Warning "FAIL $($deployable.name) in ${environmentName}: $uri did not answer 200 within $deadlineMinutes minutes (last $status)"
        $failed++
    }
}

if ($failed -gt 0) {
    Fail-Step "$failed deployable(s) of $environmentName did not answer."
}
