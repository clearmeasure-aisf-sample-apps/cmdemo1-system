#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the cmdemo1-ui feature-toggle planner without Octopus.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-ui-feature-toggles.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ensure-ui-feature-toggles.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 6
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 6
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

$ids = @{ tdd = 'Environments-1'; uat = 'Environments-2'; prod = 'Environments-3' }
$building = (Get-UiFeatureToggleSpecs)[0]
$vendor = (Get-UiFeatureToggleSpecs)[1]

Test-Case 'defaults' @(Get-UiFeatureToggleDefaults).tdd, (Get-UiFeatureToggleDefaults).uat, (Get-UiFeatureToggleDefaults).prod @($true, $false, $false)
Test-Case 'names' @($building.Name, $vendor.Name) @('BuildingManagement', 'VendorManagement')
Test-Case 'slugs match names' @($building.Slug, $vendor.Slug) @($building.Name, $vendor.Name)
foreach ($spec in @(Get-UiFeatureToggleSpecs)) {
    Test-Case "$($spec.Name) description length" (($spec.Description.Length -gt 0) -and ($spec.Description.Length -le 1000)) $true
}

$create = Get-UiFeatureTogglePlan -Spec $building -Current $null -EnvironmentIds $ids -Mode Ensure
Test-Case 'create action' $create.Action 'create'
Test-Case 'create default off' @($create.DefaultIsEnabled, $create.ChangeDefault) @($false, $true)
Test-Case 'create tdd on' (ConvertTo-Boolean ($create.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-1' }).IsEnabled) $true
Test-Case 'create uat off' (ConvertTo-Boolean ($create.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $false
Test-Case 'create prod off' (ConvertTo-Boolean ($create.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-3' }).IsEnabled) $false

$json = ConvertTo-OctopusJson @{ Environments = $create.Environments }
Test-Case 'json environments array' ($json -match '"Environments":\[') $true
Test-Case 'json one on' ([regex]::Matches($json, '"IsEnabled":true').Count) 1
Test-Case 'json two off' ([regex]::Matches($json, '"IsEnabled":false').Count) 2
Test-Case 'json empty phases' ([regex]::Matches($json, '"Phases":\[\]').Count) 3
Test-Case 'json has no api key' ($json -match 'API-') $false
$createBody = ConvertTo-OctopusJson (New-FeatureToggleBody 'Projects-981' 'Spaces-355' $building $create $null)
Test-Case 'create body name' $createBody.Contains('"Name":"BuildingManagement"') $true
Test-Case 'create body slug' $createBody.Contains('"Slug":"BuildingManagement"') $true
Test-Case 'create body project' $createBody.Contains('"ProjectId":"Projects-981"') $true
Test-Case 'create body space' $createBody.Contains('"SpaceId":"Spaces-355"') $true
Test-Case 'create body environments array' $createBody.Contains('"Environments":[') $true
Test-Case 'create body empty phases' $createBody.Contains('"Phases":[]') $true

$current = [pscustomobject]@{
    Name             = 'BuildingManagement'
    Slug             = 'BuildingManagement'
    Description      = 'operator text'
    DefaultIsEnabled = $false
    Environments     = @(
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-1'; IsEnabled = $true; Phases = @() }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-2'; IsEnabled = $true; Phases = @([pscustomobject]@{ Name = 'staff' }); RolloutPercentage = 10 }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-3'; IsEnabled = $false; Phases = @() }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-9'; IsEnabled = $true; Phases = @() }
    )
}
$kept = Get-UiFeatureTogglePlan -Spec $building -Current $current -EnvironmentIds $ids -Mode Ensure
Test-Case 'flip kept' $kept.Action 'none'
Test-Case 'description kept' $kept.Description 'operator text'

$missingProd = [pscustomobject]@{
    Name             = 'BuildingManagement'
    Slug             = 'BuildingManagement'
    Description      = 'operator text'
    DefaultIsEnabled = $true
    Environments     = @(
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-1'; IsEnabled = $true; Phases = @() }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-2'; IsEnabled = $true; Phases = @() }
    )
}
$added = Get-UiFeatureTogglePlan -Spec $building -Current $missingProd -EnvironmentIds $ids -Mode Ensure
Test-Case 'missing prod is an update' $added.Action 'update'
Test-Case 'missing prod stays off' (ConvertTo-Boolean ($added.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-3' }).IsEnabled) $false
Test-Case 'ensure does not reset uat' (ConvertTo-Boolean ($added.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $true
Test-Case 'ensure does not clear a default that is on' $added.DefaultIsEnabled $true

$reset = Get-UiFeatureTogglePlan -Spec $building -Current $current -EnvironmentIds $ids -Mode ResetDefaults
Test-Case 'reset updates' $reset.Action 'update'
Test-Case 'reset uat off' (ConvertTo-Boolean ($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $false
Test-Case 'reset keeps the extra environment' (ConvertTo-Boolean ($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-9' }).IsEnabled) $true
Test-Case 'reset keeps the phase' @(($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).Phases).Count 1
Test-Case 'reset keeps the phase name' (($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).Phases | Select-Object -First 1).Name 'staff'
$oneList = [System.Collections.Generic.List[object]]::new()
$oneList.Add(($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }))
$oneEnvironment = ConvertTo-OctopusJson @{ Environments = $oneList }
Test-Case 'one environment stays an array' ($oneEnvironment -match '"Environments":\[') $true
Test-Case 'one phase stays an array' ($oneEnvironment -match '"Phases":\[\{') $true
Test-Case 'reset keeps rollout' ($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).RolloutPercentage 10
Test-Case 'reset leaves a default that is already off' @($reset.DefaultIsEnabled, $reset.ChangeDefault) @($false, $false)
$defaultOn = [pscustomobject]@{
    Name             = 'BuildingManagement'
    Slug             = 'BuildingManagement'
    Description      = 'operator text'
    DefaultIsEnabled = $true
    Environments     = $current.Environments
}
$resetDefault = Get-UiFeatureTogglePlan -Spec $building -Current $defaultOn -EnvironmentIds $ids -Mode ResetDefaults
Test-Case 'reset turns a default off' @($resetDefault.DefaultIsEnabled, $resetDefault.ChangeDefault) @($false, $true)

$set = Get-UiFeatureTogglePlan -Spec $vendor -Current $current -EnvironmentIds $ids -Mode Set -EnvironmentName prod -EnvironmentEnabled $true
Test-Case 'set prod on' (ConvertTo-Boolean ($set.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-3' }).IsEnabled) $true
Test-Case 'set leaves uat' (ConvertTo-Boolean ($set.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $true
$same = Get-UiFeatureTogglePlan -Spec $vendor -Current $current -EnvironmentIds $ids -Mode Set -EnvironmentName prod -EnvironmentEnabled $false
Test-Case 'set already off is none' $same.Action 'none'

$unknown = $false
try { Get-UiFeatureTogglePlan -Spec $building -Current $null -EnvironmentIds $ids -Mode Set -EnvironmentName staging -EnvironmentEnabled $true } catch { $unknown = $true }
Test-Case 'unknown environment refused' $unknown $true

$chosen = @(Select-UiFeatureToggleSpecs 'Set' 'VendorManagement')
Test-Case 'set selects one' @($chosen.Count, $chosen[0].Name) @(1, 'VendorManagement')
Test-Case 'ensure selects both' @(Select-UiFeatureToggleSpecs 'Ensure' '').Count 2

$offline = @(Get-OfflineEnsurePlans)
Test-Case 'offline create count' $offline.Count 2
Test-Case 'offline second name' $offline[1].Name 'VendorManagement'

$repoSystem = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'system.json') -Raw | ConvertFrom-Json
Assert-UiFeatureToggleSystem $repoSystem
Test-Case 'repo system accepted' $true $true

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ensure-ui-feature-toggles.ps1') -Raw
Test-Case 'script has no api key literal' ($source -match 'API-[A-Za-z0-9]{8,}') $false
Test-Case 'script does not say fleet' ($source -match '(?i)fleet') $false

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
