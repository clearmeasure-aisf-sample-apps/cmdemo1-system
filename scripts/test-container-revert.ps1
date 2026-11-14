#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests that octopus/projects.tf puts container image rollback before Revert pin.

.DESCRIPTION
    Reads the Terraform text only (no Octopus, no terraform apply). A failed tdd acceptance/smoke test must put the
    previous container image back and verify it (#650): steps "Revert deployable" and "Verify revert" for
    local.container_deployables, on Failure, in that order, before "Revert pin".

.EXAMPLE
    pwsh -NoProfile -File scripts/test-container-revert.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 6
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 6
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

function ConvertTo-Slug {
    param([Parameter(Mandatory)] [string] $Name)
    return ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

$root = Split-Path -Parent $PSScriptRoot
$projects = Get-Content -LiteralPath (Join-Path $root 'octopus/projects.tf') -Raw

$steps = @{}
foreach ($block in [regex]::Matches($projects, '(?ms)^resource "octopusdeploy_process_step" "(?<resource>\w+)" \{(?<body>.*?)^\}')) {
    $body = $block.Groups['body'].Value
    $name = [regex]::Match($body, '(?m)^  name\s+= "(?<name>[^"]+)"').Groups['name'].Value
    $condition = [regex]::Match($body, '(?m)^  condition\s+= "(?<condition>[^"]+)"')
    $script = [regex]::Match($body, 'file\("\$\{path\.module\}/\.\./scripts/(?<file>[\w.-]+)"\)')
    $forEach = [regex]::Match($body, '(?m)^  for_each = local\.(?<set>\w+)')
    $steps[$block.Groups['resource'].Value] = @{
        Name      = $name
        Slug      = ConvertTo-Slug -Name $name
        Condition = if ($condition.Success) { $condition.Groups['condition'].Value } else { 'Success' }
        Waits     = $body -notmatch 'start_trigger\s+= "StartWithPrevious"'
        Script    = if ($script.Success) { $script.Groups['file'].Value } else { '' }
        Set       = if ($forEach.Success) { $forEach.Groups['set'].Value } else { '' }
    }
}

$order = [regex]::Match($projects, '(?ms)^resource "octopusdeploy_process_steps_order" "deployable" \{(?<body>.*?)^\}').Groups['body'].Value
$sequence = @([regex]::Matches($order, 'octopusdeploy_process_step\.(?<resource>\w+)\[each\.key\]\.id') | ForEach-Object { $_.Groups['resource'].Value })

$revert = $steps['revert_container']
$verify = $steps['verify_container_revert']
$revertExists = [object[]]@(($null -ne $revert), [string] $revert.Set, [string] $revert.Name, [string] $revert.Condition)
$verifyExists = [object[]]@(($null -ne $verify), [string] $verify.Set, [string] $verify.Name, [string] $verify.Condition)
Test-Case 'revert_container exists for container_deployables' $revertExists ([object[]]@($true, 'container_deployables', 'Revert deployable', 'Failure'))
Test-Case 'verify_container_revert exists for container_deployables' $verifyExists ([object[]]@($true, 'container_deployables', 'Verify revert', 'Failure'))
Test-Case 'revert slug is what the platform looks for' $revert.Slug 'revert-deployable'
$verifySlug = [object[]]@([string] $verify.Slug, [bool] ($verify.Slug -like 'verify-*'))
Test-Case 'verify slug starts with verify- and is verify-revert' $verifySlug ([object[]]@('verify-revert', $true))
Test-Case 'verify waits for the revert' $verify.Waits $true
Test-Case 'revert uses update-deployable.ps1' $revert.Script 'update-deployable.ps1'
Test-Case 'verify uses verify-environment.ps1' $verify.Script 'verify-environment.ps1'

$atRevert = [array]::IndexOf($sequence, 'revert_container')
$atVerify = [array]::IndexOf($sequence, 'verify_container_revert')
$atPin = [array]::IndexOf($sequence, 'revert_pin')
$failureOrder = [object[]]@(($atRevert -ge 0), ($atVerify -eq $atRevert + 1), ($atPin -gt $atVerify))
Test-Case 'failure order is revert, verify, pin' $failureOrder ([object[]]@($true, $true, $true))

$acceptance = [array]::IndexOf($sequence, 'acceptance_tests')
$testsBefore = [object[]]@(($acceptance -ge 0), ($acceptance -lt $atRevert))
Test-Case 'acceptance tests stand before the container rollback' $testsBefore ([object[]]@($true, $true))

# Sign-off, auto-promote and the prod restore point stay ahead of the rollback; this change does not move them.
$signOff = [array]::IndexOf($sequence, 'sign_off')
$restore = [array]::IndexOf($sequence, 'restore_point')
Test-Case 'Sign-off stays first' $signOff 0
Test-Case 'restore point stays before pin when present' (($restore -lt 0) -or ($restore -gt $signOff -and $restore -lt [array]::IndexOf($sequence, 'pin'))) $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
