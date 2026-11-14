#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the Update deployable feature-toggle client inject and container revert planner without Azure.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-update-deployable.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'update-deployable.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 6
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 6
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

$updateKeep = Get-ContainerRevertTarget -StepName 'Update deployable' -ReleaseVersion '2.4.2210' -Pinned 'True' -PreviousVersion '2.4.2206'
Test-Case 'update keeps the release version' @($updateKeep.IsRevert, $updateKeep.Skip, $updateKeep.Version) @($false, $false, '2.4.2210')

$revertOk = Get-ContainerRevertTarget -StepName 'Revert deployable' -ReleaseVersion '2.4.2210' -Pinned 'True' -PreviousVersion '2.4.2206'
Test-Case 'revert uses PreviousVersion' @($revertOk.IsRevert, $revertOk.Skip, $revertOk.Version, $revertOk.Reason) @($true, $false, '2.4.2206', '')

$notPinned = Get-ContainerRevertTarget -StepName 'Revert deployable' -ReleaseVersion '2.4.2210' -Pinned 'False' -PreviousVersion '2.4.2206'
Test-Case 'revert skips when not pinned' @($notPinned.IsRevert, $notPinned.Skip, $notPinned.Reason) @($true, $true, 'not-pinned')

$noPrevious = Get-ContainerRevertTarget -StepName 'Revert deployable' -ReleaseVersion '2.4.2210' -Pinned 'True' -PreviousVersion ''
Test-Case 'revert skips when no previous version' @($noPrevious.IsRevert, $noPrevious.Skip, $noPrevious.Reason) @($true, $true, 'no-previous')

$blankPrevious = Get-ContainerRevertTarget -StepName 'Revert deployable' -ReleaseVersion '2.4.2210' -Pinned 'True' -PreviousVersion '   '
Test-Case 'revert skips blank previous version' @($blankPrevious.Skip, $blankPrevious.Reason) @($true, 'no-previous')

$envName = 'Octopus__FeatureFlags__ClientIdentifier'
$client = 'client-identifier-tdd'
$aliasClient = 'client-identifier-alias'
$others = @(
    @{ name = 'OTEL_SERVICE_NAME'; value = 'cmdemo1-ui' }
    @{ name = 'AI_OpenAI_ApiKey'; secretRef = 'ai-openai-apikey' }
)

$preferred = Resolve-FeatureFlagClientIdentifier -Parameters @{
    'Octopus.FeatureFlags.ClientIdentifier'   = $client
    'Octopus.FeatureToggles.ClientIdentifier' = $aliasClient
}
Test-Case 'resolver prefers FeatureFlags' $preferred $client
$fallback = Resolve-FeatureFlagClientIdentifier -Parameters @{
    'Octopus.FeatureFlags.ClientIdentifier'   = ''
    'Octopus.FeatureToggles.ClientIdentifier' = $aliasClient
}
Test-Case 'resolver falls back to FeatureToggles' $fallback $aliasClient
$blankPreferred = Resolve-FeatureFlagClientIdentifier -Parameters @{
    'Octopus.FeatureFlags.ClientIdentifier'   = '   '
    'Octopus.FeatureToggles.ClientIdentifier' = $aliasClient
}
Test-Case 'resolver treats blank FeatureFlags as missing' $blankPreferred $aliasClient
$bothEmpty = Resolve-FeatureFlagClientIdentifier -Parameters @{
    'Octopus.FeatureFlags.ClientIdentifier'   = ''
    'Octopus.FeatureToggles.ClientIdentifier' = ''
}
Test-Case 'resolver empty when both empty' $bothEmpty ''
$noParams = Resolve-FeatureFlagClientIdentifier -Parameters $null
Test-Case 'resolver empty when parameters missing' $noParams ''

$ui = Get-FeatureFlagClientInject -Deployable 'ui' -ClientIdentifier $client
Test-Case 'ui with identifier applies' $ui.Apply $true
Test-Case 'ui with identifier name' $ui.Name $envName
Test-Case 'ui with identifier value' $ui.Value $client
Test-Case 'ui with identifier arguments' @($ui.Arguments) @('--set-env-vars', "${envName}=${client}")

$empty = Get-FeatureFlagClientInject -Deployable 'ui' -ClientIdentifier ''
Test-Case 'empty identifier is skipped' @($empty.Apply, @($empty.Arguments).Count) @($false, 0)
$blank = Get-FeatureFlagClientInject -Deployable 'ui' -ClientIdentifier '   '
Test-Case 'blank identifier is skipped' $blank.Apply $false
$missing = Get-FeatureFlagClientInject -Deployable 'ui' -ClientIdentifier $null
Test-Case 'missing identifier is skipped' $missing.Apply $false

foreach ($deployable in @('dashboard', 'scorecard', 'UI')) {
    $skipped = Get-FeatureFlagClientInject -Deployable $deployable -ClientIdentifier $client
    Test-Case "$deployable is skipped" @($skipped.Apply, @($skipped.Arguments).Count) @($false, 0)
}

# Same assignment the update uses, so one variable stays an array.
$merged = Merge-FeatureFlagClientEnv -Env $others -Inject $ui
Test-Case 'inject keeps the other variables' @($merged.Count, $merged[0].name, $merged[1].secretRef) @(3, 'OTEL_SERVICE_NAME', 'ai-openai-apikey')
Test-Case 'inject appends the client identifier' @($merged[2].name, $merged[2].value) @($envName, $client)

$replacedSource = @(
    @{ name = 'OTEL_SERVICE_NAME'; value = 'cmdemo1-ui' }
    @{ name = $envName; value = 'previous-client' }
)
$replaced = Merge-FeatureFlagClientEnv -Env $replacedSource -Inject $ui
Test-Case 'inject replaces an existing value' @($replaced.Count, $replaced[1].value) @(2, $client)

$untouched = Merge-FeatureFlagClientEnv -Env $others -Inject $empty
Test-Case 'skip leaves env unchanged' @($untouched.Count, $untouched[0].name, $untouched[1].secretRef) @(2, 'OTEL_SERVICE_NAME', 'ai-openai-apikey')
Test-Case 'skip does not add the variable' @($untouched | ForEach-Object { [string] $_.name }) @('OTEL_SERVICE_NAME', 'AI_OpenAI_ApiKey')

$none = Merge-FeatureFlagClientEnv -Env $null -Inject $empty
Test-Case 'skip of no env stays empty' $none.Count 0
$added = Merge-FeatureFlagClientEnv -Env $null -Inject $ui
Test-Case 'inject onto no env' @($added.Count, $added[0].name, $added[0].value) @(1, $envName, $client)

# Same splat the container app update uses. An empty array adds no argument.
$recorded = [System.Collections.Generic.List[string]]::new()
function Register-UpdateArgument {
    param([Parameter(ValueFromRemainingArguments)] [object[]] $Argument)
    foreach ($one in $Argument) { $script:recorded.Add([string] $one) }
}
$skippedArgs = Get-FeatureFlagUpdateArguments -Inject $empty
Register-UpdateArgument --name app --resource-group rg --image example:1 @skippedArgs --no-wait --output none
Test-Case 'empty inject adds no argument' @($recorded) @('--name', 'app', '--resource-group', 'rg', '--image', 'example:1', '--no-wait', '--output', 'none')
$recorded.Clear()
$setArgs = Get-FeatureFlagUpdateArguments -Inject $ui
Register-UpdateArgument --name app --resource-group rg --image example:1 @setArgs --no-wait --output none
Test-Case 'set inject adds the env assignment' @($recorded) @('--name', 'app', '--resource-group', 'rg', '--image', 'example:1', '--set-env-vars', "${envName}=${client}", '--no-wait', '--output', 'none')

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'update-deployable.ps1') -Raw
Test-Case 'script still fails fast' ($source -match 'function Get-RevisionProblem') $true
Test-Case 'script asks the planner' ($source -match 'Get-FeatureFlagClientInject') $true
Test-Case 'script resolves the client identifier' ($source -match 'Resolve-FeatureFlagClientIdentifier -Parameters \$OctopusParameters') $true
Test-Case 'script merges express env' ($source -match 'Merge-FeatureFlagClientEnv') $true
Test-Case 'script keeps the image update' ($source -match 'az containerapp update --name \$app --resource-group \$resourceGroup --image \$image @featureFlagArguments --no-wait --output none') $true
Test-Case 'script builds the splat from the planner' ($source -match 'Get-FeatureFlagUpdateArguments -Inject \$featureFlags') $true
Test-Case 'script plans a container revert from Pin version' ($source -match 'Get-ContainerRevertTarget') $true
Test-Case 'script sets Reverted after a successful container revert' ($source -match "Set-OctopusVariable -name 'Reverted' -value 'True'") $true
# The JWT must never be written to the deployment log.
Test-Case 'script never logs the client identifier value' (
    ($source -notmatch 'Write-Host.*(FeatureFlags\.ClientIdentifier|FeatureToggles\.ClientIdentifier|featureFlags\.Value)') -and
    ($source -notmatch 'Write-Verbose.*(FeatureFlags\.ClientIdentifier|FeatureToggles\.ClientIdentifier|featureFlags\.Value)')
) $true

$projects = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'octopus/projects.tf') -Raw
Test-Case 'projects.tf has container Revert deployable on failure' (
    $projects -match 'resource "octopusdeploy_process_step" "revert_container"' -and
    $projects -match 'for_each = local\.container_deployables' -and
    $projects -match 'name\s+= "Revert deployable"' -and
    $projects -match 'condition\s+= "Failure"' -and
    $projects -match 'update-deployable\.ps1'
) $true
Test-Case 'projects.tf has container Verify revert on failure' (
    $projects -match 'resource "octopusdeploy_process_step" "verify_container_revert"' -and
    $projects -match 'name\s+= "Verify revert"' -and
    $projects -match 'verify-environment\.ps1'
) $true
Test-Case 'projects.tf orders container revert before Revert pin' (
    $projects -match 'octopusdeploy_process_step\.revert_container\[each\.key\]\.id' -and
    $projects -match 'octopusdeploy_process_step\.verify_container_revert\[each\.key\]\.id' -and
    $projects -match 'octopusdeploy_process_step\.revert_pin\[each\.key\]\.id'
) $true

$verify = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify-environment.ps1') -Raw
Test-Case 'verify-environment handles Verify revert' ($verify -match "Verify revert") $true
Test-Case 'verify-environment requires Reverted after container revert' (
    $verify -match "Octopus\.Action\[Revert deployable\]\.Output\.Reverted"
) $true
Test-Case 'verify-environment checks previous image tag after revert' ($verify -match 'EndsWith\("\:\$previous"\)') $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
