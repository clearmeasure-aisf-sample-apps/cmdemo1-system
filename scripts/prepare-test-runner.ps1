#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Pulls the acceptance-test container onto the worker while the database migrates.

.DESCRIPTION
    Step "Prepare test runner" of the Octopus project <slug>-<deployable>, in the environments with acceptance tests;
    octopus/projects.tf inlines this file. It starts together with "Migrate database", in the custom test-runner image
    (Playwright plus the .NET 10 SDK) the test step uses, so the image is on the worker's Docker cache by the time the
    tests start: an Octopus Cloud customer leases one dynamic worker per pool, and it keeps its cache while it lives.
    The script only reports what the tests will have: cores, memory, browsers and the .NET SDKs of the image.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$memoryGb = [Math]::Round(([long] ((Get-Content -LiteralPath '/proc/meminfo' | Select-String -Pattern '^MemTotal:\s+(\d+)').Matches[0].Groups[1].Value)) / 1MB, 1)
$browsers = @(Get-ChildItem -LiteralPath ([string] $env:PLAYWRIGHT_BROWSERS_PATH) -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
$PSNativeCommandUseErrorActionPreference = $false
$sdks = @(dotnet --list-sdks 2>$null)
$PSNativeCommandUseErrorActionPreference = $true
Write-Host "Worker: $([Environment]::ProcessorCount) cores, $memoryGb GB; browsers in the image: $($browsers -join ', '); SDKs: $($sdks -join '; ')"

# Said as an exit code: Octopus ends a step with the exit code of the last program its script ran, which may be one
# whose refusal was expected and handled (a dormant system's resources that are gone: cmdemo2, 2026-10-15).
exit 0
