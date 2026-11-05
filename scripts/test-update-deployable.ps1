#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the Update deployable feature-toggle client inject without Azure.

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

$envName = 'Octopus__FeatureFlags__ClientIdentifier'
$client = 'client-identifier-tdd'
$others = @(
    @{ name = 'OTEL_SERVICE_NAME'; value = 'cmdemo1-ui' }
    @{ name = 'AI_OpenAI_ApiKey'; secretRef = 'ai-openai-apikey' }
)

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

foreach ($deployable in @('aisf', 'fworker', 'UI')) {
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
Test-Case 'script merges express env' ($source -match 'Merge-FeatureFlagClientEnv') $true
Test-Case 'script keeps the image update' ($source -match 'az containerapp update --name \$app --resource-group \$resourceGroup --image \$image @featureFlagArguments --no-wait --output none') $true
Test-Case 'script builds the splat from the planner' ($source -match 'Get-FeatureFlagUpdateArguments -Inject \$featureFlags') $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
