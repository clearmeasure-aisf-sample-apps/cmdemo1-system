#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Reports the health of every node of the environment in Octopus: one line per node, and a failed run when one is
    not healthy.

.DESCRIPTION
    Runbook "Health report" of the Octopus project <slug>-system (scheduled hourly in every environment;
    octopus/runbooks.tf inlines this file). Capability CAP-076. Octopus has no page for a system's own health tiles,
    so this puts the answer where Octopus shows it: the runbook's last run per environment is green or red on the
    project's Operations overview, and its highlights name every node (region, role, status, time to answer, version)
    with a link to the health dashboard, the live view.

    Nodes are what the environment's stack reports: every app, its standby in a second region, and the static sites;
    and the environment's public address when it has a Front Door endpoint. Apps are asked for /alive, not for the
    health check: the health check connects to the database, and an hourly question would keep a serverless free-offer
    database awake until its monthly allowance is used up. An app that has no release yet answers on / instead. A
    Free-plan app that idled is given time to start (three attempts).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$edgeGroup = [string] $OctopusParameters['Azure.EdgeResourceGroup']

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs

function Get-Answer {
    # One GET with up to three attempts: the status, the milliseconds of the answering attempt, and 0 when no attempt
    # was answered.
    param([Parameter(Mandatory)] [string] $Uri)
    $status = 0
    $milliseconds = 0
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try { $status = [int] (Invoke-WebRequest -Uri $Uri -Method Get -TimeoutSec 100 -SkipHttpErrorCheck).StatusCode } catch { $status = 0 }
        $milliseconds = [int] $clock.ElapsedMilliseconds
        if ($status -eq 200 -or $status -eq 404) { break }
        Start-Sleep -Seconds 10
    }
    @{ Status = $status; Milliseconds = $milliseconds }
}

function Get-RunningVersion {
    # The version the app reports (the part before "+"), or '' when it reports none.
    param([Parameter(Mandatory)] [string] $Url)
    try {
        $answer = Invoke-RestMethod -Uri "$Url/_version" -TimeoutSec 30
        return ([string] $answer.version -split '\+')[0]
    }
    catch { return '' }
}

$nodes = [Collections.Generic.List[hashtable]]::new()
foreach ($entry in @($outputs.deployables.value)) {
    $nodes.Add(@{ Name = [string] $entry.name; Where = "$($entry['region'] ?? 'home region'), primary"; Url = ([string] $entry.url).TrimEnd('/'); Static = $entry['hosting'] -eq 'staticwebapp' })
}
foreach ($entry in @(if ($outputs.ContainsKey('standby')) { $outputs.standby.value })) {
    $nodes.Add(@{ Name = [string] $entry.name; Where = "$($entry.region), standby"; Url = ([string] $entry.url).TrimEnd('/'); Static = $false })
}
if ($edgeGroup) {
    $PSNativeCommandUseErrorActionPreference = $false
    $edgeJson = az stack group show --name "stack-$slug-$environmentName-edge" --resource-group $edgeGroup --output json 2>$null
    $hasEdge = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    foreach ($endpoint in @(if ($hasEdge) { ($edgeJson | ConvertFrom-Json -AsHashtable).outputs.endpoints.value })) {
        $nodes.Add(@{ Name = [string] $endpoint.name; Where = 'public address (Front Door)'; Url = ([string] $endpoint.url).TrimEnd('/'); Static = $false })
    }
}
if ($nodes.Count -eq 0) {
    Fail-Step "Stack stack-$slug-$environmentName reports no node."
}

$unhealthy = 0
foreach ($node in $nodes) {
    $path = if ($node.Static) { '/' } else { '/alive' }
    $answer = Get-Answer -Uri "$($node.Url)$path"
    $note = ''
    if (-not $node.Static -and $answer.Status -eq 404) {
        # No release yet: the platform's default page answers, and the app's own paths do not exist.
        $answer = Get-Answer -Uri "$($node.Url)/"
        $note = ', no release yet'
    }
    $version = if ($node.Static -or $note) { '' } else { Get-RunningVersion -Url $node.Url }
    $healthy = $answer.Status -eq 200
    if (-not $healthy) { $unhealthy++ }
    $state = if ($healthy) { 'Healthy' } elseif ($answer.Status -eq 0) { 'Unreachable' } else { 'Unhealthy' }
    $line = "$state  $($node.Name) in ${environmentName}, $($node.Where): $(if ($answer.Status) { "HTTP $($answer.Status) in $($answer.Milliseconds) ms" } else { 'no answer' })$(if ($version) { ", version $version" })$note  $($node.Url)"
    if ($healthy) { Write-Highlight $line } else { Write-Warning $line }
}

$dashboard = @($outputs.deployables.value | Where-Object { $_['hosting'] -eq 'staticwebapp' }) | Select-Object -First 1
if ($dashboard) {
    Write-Highlight "Live view of every node of every environment: $($dashboard.url)"
}
if ($unhealthy -gt 0) {
    Fail-Step "$unhealthy of $($nodes.Count) node(s) of $environmentName are not healthy."
}
Write-Highlight "All $($nodes.Count) node(s) of $environmentName are healthy."
