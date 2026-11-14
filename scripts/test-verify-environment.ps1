#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the Verify revert planner of scripts/verify-environment.ps1 without Azure.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-verify-environment.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'verify-environment.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 6
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 6
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

$verify = Resolve-ContainerVerifyTarget -Step 'Verify deployable' -Release '2.4.2214' -Parameters @{
    'Octopus.Action[Pin version].Output.Pinned'            = 'True'
    'Octopus.Action[Pin version].Output.PreviousVersion'   = '2.4.2206'
    'Octopus.Action[Revert deployable].Output.Reverted'    = 'True'
}
Test-Case 'verify deployable is not a revert' @($verify.AfterRevert, $verify.Skip, $verify.Fail, $verify.Version) @($false, $false, $false, '2.4.2214')

$ok = Resolve-ContainerVerifyTarget -Step 'Verify revert' -Release '2.4.2214' -Parameters @{
    'Octopus.Action[Pin version].Output.Pinned'            = 'True'
    'Octopus.Action[Pin version].Output.PreviousVersion'   = '2.4.2206'
    'Octopus.Action[Revert deployable].Output.Reverted'    = 'True'
}
Test-Case 'verify revert asks for PreviousVersion' @($ok.AfterRevert, $ok.Skip, $ok.Fail, $ok.Version) @($true, $false, $false, '2.4.2206')

$notReverted = Resolve-ContainerVerifyTarget -Step 'Verify revert' -Release '2.4.2214' -Parameters @{
    'Octopus.Action[Pin version].Output.Pinned'            = 'True'
    'Octopus.Action[Pin version].Output.PreviousVersion'   = '2.4.2206'
    'Octopus.Action[Revert deployable].Output.Reverted'    = ''
}
Test-Case 'verify revert fails when not reverted' @($notReverted.Fail, $notReverted.Reason, $notReverted.Version) @($true, 'not-reverted', '2.4.2206')

$notPinned = Resolve-ContainerVerifyTarget -Step 'Verify revert' -Release '2.4.2214' -Parameters @{
    'Octopus.Action[Pin version].Output.Pinned'            = 'False'
    'Octopus.Action[Pin version].Output.PreviousVersion'   = '2.4.2206'
}
Test-Case 'verify revert skips when not pinned' @($notPinned.Skip, $notPinned.Reason) @($true, 'not-pinned')

$noPrevious = Resolve-ContainerVerifyTarget -Step 'Verify revert' -Release '2.4.2214' -Parameters @{
    'Octopus.Action[Pin version].Output.Pinned'            = 'True'
    'Octopus.Action[Pin version].Output.PreviousVersion'   = ''
}
Test-Case 'verify revert skips when no previous' @($noPrevious.Skip, $noPrevious.Reason) @($true, 'no-previous')

$image = 'acrcmdemo1chu4gq.azurecr.io/cmdemo1/ui:2.4.2206'
Test-Case 'image tag matches previous' (
    Test-ContainerImageTag -Image $image -Registry 'acrcmdemo1chu4gq.azurecr.io' -Slug 'cmdemo1' -Deployable 'ui' -Version '2.4.2206'
) $true
Test-Case 'image tag rejects the failed release' (
    Test-ContainerImageTag -Image 'acrcmdemo1chu4gq.azurecr.io/cmdemo1/ui:2.4.2214' -Registry 'acrcmdemo1chu4gq.azurecr.io' -Slug 'cmdemo1' -Deployable 'ui' -Version '2.4.2206'
) $false

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-environment.ps1') -Raw
Test-Case 'script resolves the verify target' ($source -match 'Resolve-ContainerVerifyTarget -Step \$step -Release \$release -Parameters \$OctopusParameters') $true
Test-Case 'script checks the image tag after a revert' ($source -match 'Test-ContainerImageTag') $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
