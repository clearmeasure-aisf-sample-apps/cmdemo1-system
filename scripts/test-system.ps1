#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Checks system.json and the environment folders before anything is applied.

.DESCRIPTION
    Runs in job env-checks of .github/workflows/env-checks.yml on every pull request, and locally:
      pwsh -NoProfile -File scripts/test-system.ps1
    Prints PASS or FAIL per check and exits 1 when any check fails.

    - The slug, environment and deployable names follow the naming rules every template relies on.
    - Each environment has a tier (nonprod or prod), a runtime identity from the seed and a folder
      environments/<env>/ with a versions.json object whose keys are deployables.
    - Each capability has a module: baseline is built in, every other one is infra/modules/<capability>.bicep.
    - employeeMiddleNames, where an environment has it, maps user names to middle names of 1 to 100 characters.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$failures = [Collections.Generic.List[string]]::new()
function Test-Rule {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        Write-Host "PASS $Name"
    }
    else {
        Write-Host "FAIL $Name$(if ($Detail) { ": $Detail" })"
        $failures.Add($Name)
    }
}

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
Test-Rule 'slug' ($slug -cmatch '^[a-z][a-z0-9]{2,9}$') "'$slug' must be 3 to 10 lowercase letters and digits, starting with a letter"

$deployableNames = @($system.deployables | ForEach-Object { [string] $_.name })
Test-Rule 'deployables present' ($deployableNames.Count -gt 0)
foreach ($name in $deployableNames) {
    # Azure names carry it: ca-<slug>-<env>-<deployable> has at most 32 characters, hyphens inside but not doubled.
    Test-Rule "deployable $name name" ($name -cmatch '^[a-z](?:[a-z0-9]|-(?=[a-z0-9])){1,9}$') 'lowercase letters, digits and inner hyphens, 2 to 10'
    Test-Rule "deployable $name is not 'system'" ($name -cne 'system') 'the Octopus project <slug>-system is the environments project'
}
Test-Rule 'deployable names unique' (@($deployableNames | Select-Object -Unique).Count -eq $deployableNames.Count)

$environmentNames = @($system.environments | ForEach-Object { [string] $_.name })
Test-Rule 'environments present' ($environmentNames.Count -gt 0)
Test-Rule 'environment names unique' (@($environmentNames | Select-Object -Unique).Count -eq $environmentNames.Count)

$modules = Join-Path $Root 'infra' 'modules'
foreach ($environment in $system.environments) {
    $name = [string] $environment.name
    Test-Rule "environment $name name" ($name -cmatch '^[a-z][a-z0-9]{1,7}$') 'lowercase letters and digits, 2 to 8'
    Test-Rule "environment $name tier" (@('nonprod', 'prod') -ccontains [string] $environment.tier)
    Test-Rule "environment $name runtime identity" (@($system.azure.identities.apps | Where-Object { $_.environment -eq $name }).Count -eq 1) 'the seed creates one per planned environment; re-run it for a new name'

    # Placement: sharesAppEnvironmentWith names an earlier environment of the same tier that hosts its own apps; a moved or
    # shared placement adds a 5-character suffix to the app names (ca-<slug>-<env>-<deployable>-xxxx, at most 32).
    $index = [array]::IndexOf($environmentNames, $name)
    if ($environment.ContainsKey('sharesAppEnvironmentWith')) {
        $hostName = [string] $environment.sharesAppEnvironmentWith
        $hostEntry = @($system.environments | Where-Object { $_.name -eq $hostName })[0]
        Test-Rule "environment $name shares $hostName" ($null -ne $hostEntry -and [array]::IndexOf($environmentNames, $hostName) -lt $index -and $hostEntry.tier -eq $environment.tier -and -not $hostEntry.ContainsKey('sharesAppEnvironmentWith') -and -not $environment.ContainsKey('appLocation')) 'an earlier environment of the same tier that hosts its own apps; no appLocation of its own'
    }
    if ($environment.ContainsKey('sharesAppEnvironmentWith') -or $environment.ContainsKey('appLocation')) {
        foreach ($deployableName in $deployableNames) {
            Test-Rule "environment $name app name length ($deployableName)" (("ca-$slug-$name-$deployableName-xxxx").Length -le 32) 'slug, environment and deployable too long for a suffixed container app name (32 characters)'
        }
    }

    # Demo data, optional: user name -> middle name for the system step "Set employee middle names";
    # dbo.Employee.MiddleName holds at most 100 characters.
    if ($environment.ContainsKey('employeeMiddleNames')) {
        $middleNames = $environment.employeeMiddleNames
        $valid = $middleNames -is [Collections.IDictionary] -and @($middleNames.GetEnumerator() | Where-Object {
                [string]::IsNullOrWhiteSpace($_.Key) -or $_.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($_.Value) -or $_.Value.Length -gt 100
            }).Count -eq 0
        Test-Rule "environment $name employee middle names" $valid 'an object of user name to middle name, 1 to 100 characters each'
    }

    foreach ($capability in @($environment.capabilities)) {
        $known = $capability -eq 'baseline' -or (Test-Path -LiteralPath (Join-Path $modules "$capability.bicep"))
        Test-Rule "environment $name capability $capability" $known "no module infra/modules/$capability.bicep"
    }

    $versionsFile = Join-Path $Root 'environments' $name 'versions.json'
    if (-not (Test-Path -LiteralPath $versionsFile)) {
        Test-Rule "environment $name versions.json" $false "missing $versionsFile (start it as {})"
        continue
    }
    $versions = Get-Content -LiteralPath $versionsFile -Raw | ConvertFrom-Json -AsHashtable
    $unknown = @($versions.Keys | Where-Object { $deployableNames -notcontains $_ })
    Test-Rule "environment $name versions.json keys" ($unknown.Count -eq 0) "unknown deployables: $($unknown -join ', ')"
}

foreach ($folder in Get-ChildItem -Path (Join-Path $Root 'environments') -Directory) {
    Test-Rule "folder environments/$($folder.Name) is declared" ($environmentNames -contains $folder.Name) 'add it to system.json or remove the folder'
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed."
    exit 1
}
Write-Host 'All system checks passed.'
