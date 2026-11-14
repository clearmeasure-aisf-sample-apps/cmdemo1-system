#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Proves scripts/pin-version.ps1 treats a handled versions.json 409 as information, not a warning.

.DESCRIPTION
    A concurrent pin that changes versions.json is retried (up to four attempts). While attempts remain, that
    conflict must not write the warning stream: Octopus then ends the deployment with warnings, and health
    treats those as failure (CAP-011/CAP-071, #722). Exhausting all four attempts still throws.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-pin-version.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 6
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 6
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

function New-HttpStatusException([int] $StatusCode) {
    $exception = [System.Exception]::new("HTTP $StatusCode")
    Add-Member -InputObject $exception -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $StatusCode })
    return $exception
}

function Invoke-PinVersionWithPuts {
    # Runs pin-version.ps1 with GitHub contents calls mocked. Each entry of PutStatuses is the HTTP status of one
    # write (200: commit succeeds; 409: conflict). Reads always return a versions.json that still needs the pin.
    param([Parameter(Mandatory)] [int[]] $PutStatuses)

    $pinScript = Join-Path $PSScriptRoot 'pin-version.ps1'
    # Hashtable so nested mocks mutate one object (PowerShell would otherwise localize $putIndex++).
    $state = @{
        PutIndex     = 0
        WarningLines = [System.Collections.Generic.List[string]]::new()
        HostLines    = [System.Collections.Generic.List[string]]::new()
        Variables    = @{}
        Threw        = $false
        ThrowMessage = ''
    }

    $OctopusParameters = @{
        'Octopus.Environment.Name' = 'uat'
        'System.Repository'        = 'clearmeasure-aisf-sample-apps/cmdemo1-system'
        'Deployable.Name'          = 'ui'
        'Octopus.Release.Number'   = '2.4.2381'
        'Octopus.Deployment.Id'    = 'Deployments-test'
    }

    function Get-SystemGitHubToken {
        param($Permission)
        return 'test-token'
    }
    function Set-OctopusVariable {
        param([string] $name, [string] $value)
        $state.Variables[$name] = $value
    }
    function Write-Highlight {
        param([Parameter(Position = 0)] [object] $Object)
    }
    function Start-Sleep {
        param([int] $Seconds)
    }
    function Write-Warning {
        param([Parameter(Position = 0)] [object] $Object)
        $state.WarningLines.Add([string] $Object)
    }
    function Write-Host {
        param([Parameter(Position = 0)] [object] $Object)
        $state.HostLines.Add([string] $Object)
    }
    function Invoke-RestMethod {
        param(
            $Uri,
            $Method = 'Get',
            $Headers,
            $Body,
            $ContentType
        )
        $verb = if ($null -eq $Method -or [string] $Method -eq '') { 'Get' } else { [string] $Method }
        if ($verb -ceq 'Put') {
            if ($state.PutIndex -ge $PutStatuses.Count) {
                throw "Unexpected Put after $($PutStatuses.Count) mocked write(s)"
            }
            $status = $PutStatuses[$state.PutIndex]
            $state.PutIndex++
            if ($status -eq 200) {
                return [pscustomobject]@{ commit = [pscustomobject]@{ html_url = 'https://example.test/commit/1' } }
            }
            throw (New-HttpStatusException -StatusCode $status)
        }
        $json = "{`"ui`":`"2.4.2357`"}`n"
        $content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        return [pscustomobject]@{ sha = "sha-$($state.PutIndex)"; content = $content }
    }

    try {
        & $pinScript
    }
    catch {
        $state.Threw = $true
        $state.ThrowMessage = [string] $_.Exception.Message
    }

    return [pscustomobject]@{
        Threw        = $state.Threw
        ThrowMessage = $state.ThrowMessage
        Warnings     = @($state.WarningLines)
        HostLines    = @($state.HostLines)
        Variables    = $state.Variables
        PutsConsumed = $state.PutIndex
    }
}

$retry = Invoke-PinVersionWithPuts -PutStatuses @(409, 200)
Test-Case '409 then success does not throw' $retry.Threw $false
Test-Case '409 then success pins' $retry.Variables['Pinned'] 'True'
Test-Case '409 then success emits no warning stream' @($retry.Warnings) @()
Test-Case '409 then success logs the retry as host information' (
    @($retry.HostLines | Where-Object { $_ -like 'versions.json changed while pinning (attempt 1 of 4); reading it again.' }).Count -eq 1
) $true
Test-Case '409 then success consumed two writes' $retry.PutsConsumed 2

$exhausted = Invoke-PinVersionWithPuts -PutStatuses @(409, 409, 409, 409)
Test-Case '409 on all four attempts throws' $exhausted.Threw $true
Test-Case '409 on all four attempts message names HTTP 409' ($exhausted.ThrowMessage -match '409') $true
Test-Case '409 on all four attempts consumed four writes' $exhausted.PutsConsumed 4
Test-Case '409 on all four attempts logged three informational retries' (
    @($exhausted.HostLines | Where-Object { $_ -like 'versions.json changed while pinning (attempt * of 4); reading it again.' }).Count
) 3

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pin-version.ps1') -Raw
Test-Case 'script logs handled 409 with Write-Host' (
    $source -match 'Write-Host "versions\.json changed while pinning \(attempt \$attempt of 4\); reading it again\."'
) $true
Test-Case 'script does not warn on handled 409' (
    $source -notmatch 'Write-Warning "versions\.json changed while pinning'
) $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
