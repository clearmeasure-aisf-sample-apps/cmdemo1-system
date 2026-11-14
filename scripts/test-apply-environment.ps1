#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the deprecated prod aisf/fworker/fwrunner removal helpers without Azure.

.DESCRIPTION
    Loads Get-DeprecatedProdComputeName and Select-PresentResourceName from scripts/apply-environment.ps1
    (AST only: that script has no LoadOnly and is inlined into the Octopus system step). Proves #575: the four
    exact prod resource names are selected only in prod when aisf and fworker are retired, and selection against a
    present list is idempotent (already-gone names are skipped).

.EXAMPLE
    pwsh -NoProfile -File scripts/test-apply-environment.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$scriptPath = Join-Path $PSScriptRoot 'apply-environment.ps1'
$parseTokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $parseTokens, [ref] $parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host "FAIL apply-environment.ps1 does not parse: $($parseErrors[0])"
    exit 1
}
$needed = @('Get-DeprecatedProdComputeName', 'Select-PresentResourceName', 'Remove-DeprecatedProdCompute')
foreach ($fn in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($needed -contains $fn.Name) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}
foreach ($name in $needed) {
    if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-Host "FAIL apply-environment.ps1 does not define $name"
        exit 1
    }
}

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    # Empty function results are often $null in PowerShell; treat them as @() for stable JSON.
    $actualList = if ($null -eq $Actual) { @() } else { @($Actual) }
    $expectedList = if ($null -eq $Expected) { @() } else { @($Expected) }
    $actualJson = ConvertTo-Json -InputObject $actualList -Compress -Depth 8
    $expectedJson = ConvertTo-Json -InputObject $expectedList -Compress -Depth 8
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

$prodFour = @(
    'ca-cmdemo1-prod-aisf-bhj5'
    'ca-cmdemo1-prod-fworker-bhj5'
    'caj-cmdemo1-prod-fwrunner'
    'caj-cmdemo1-prod-fwrunner-codex'
)

Test-Case 'prod + retired aisf/fworker: the four exact names' (
    Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment 'prod' -Retired @('aisf', 'fworker', 'scorecard')
) $prodFour

Test-Case 'uat is never targeted (#574 was the uat path)' (
    Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment 'uat' -Retired @('aisf', 'fworker')
) @()

Test-Case 'tdd is never targeted' (
    Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment 'tdd' -Retired @('aisf', 'fworker')
) @()

Test-Case 'prod without retired aisf: nothing' (
    Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment 'prod' -Retired @('fworker')
) @()

Test-Case 'prod without retired fworker: nothing' (
    Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment 'prod' -Retired @('aisf')
) @()

Test-Case 'prod with no retired list: nothing' (
    Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment 'prod' -Retired @()
) @()

Test-Case 'slug is part of the exact names' (
    Get-DeprecatedProdComputeName -Slug 'other' -Environment 'prod' -Retired @('aisf', 'fworker')
) @(
    'ca-other-prod-aisf-bhj5'
    'ca-other-prod-fworker-bhj5'
    'caj-other-prod-fwrunner'
    'caj-other-prod-fwrunner-codex'
)

Test-Case 'select: all four still present' (
    Select-PresentResourceName -Wanted $prodFour -Present @($prodFour + 'ca-cmdemo1-prod-ui-bhj5')
) $prodFour

Test-Case 'select: already gone is a no-op (idempotent)' (
    Select-PresentResourceName -Wanted $prodFour -Present @('ca-cmdemo1-prod-ui-bhj5', 'kvcmdemo1prod7ep6z')
) @()

Test-Case 'select: only the leftover job is removed' (
    Select-PresentResourceName -Wanted $prodFour -Present @('caj-cmdemo1-prod-fwrunner-codex', 'ca-cmdemo1-prod-ui-bhj5')
) @('caj-cmdemo1-prod-fwrunner-codex')

Test-Case 'select: case-insensitive Azure names' (
    Select-PresentResourceName -Wanted @('ca-cmdemo1-prod-aisf-bhj5') -Present @('CA-cmdemo1-prod-aisf-bhj5')
) @('CA-cmdemo1-prod-aisf-bhj5')

Test-Case 'apply-environment documents #575' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match '\#575'
) $true

Test-Case 'apply-environment calls Remove-DeprecatedProdCompute before stack apply' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match 'Remove-DeprecatedProdCompute[\s\S]*Invoke-StackApply'
) $true

# Regression: system 1.0.207 failed in tdd because Mandatory [string[]] $Name rejected @().
$emptyCallOk = try { Remove-DeprecatedProdCompute -Group 'rg-cmdemo1-nonprod' -Name @(); $true } catch { $false }
Test-Case 'Remove-DeprecatedProdCompute accepts empty -Name (tdd/uat)' $emptyCallOk $true

Test-Case 'Remove-DeprecatedProdCompute declares AllowEmptyCollection' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match 'AllowEmptyCollection\(\)\]\s*\[string\[\]\]\s*\$Name'
) $true

Test-Case 'apply-environment skips Remove when no deprecated prod names' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match 'if \(\$deprecatedProdCompute\.Length -gt 0\)'
) $true

# Regression: system 1.0.208 — call site must match apply-environment.ps1 (no `@()` around Get-*, null → @()).
# `return , @()` + `@($result)` made Count 1 with a nested empty array and -Name failed as empty string.
foreach ($envName in @('tdd', 'uat')) {
    $deprecatedProdCompute = Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment $envName -Retired @('aisf', 'fworker')
    if ($null -eq $deprecatedProdCompute) { $deprecatedProdCompute = [string[]]@() }
    elseif ($deprecatedProdCompute -isnot [string[]]) { $deprecatedProdCompute = [string[]]@($deprecatedProdCompute) }
    Test-Case "call site ${envName} Length 0" $deprecatedProdCompute.Length 0
    $wouldCall = $deprecatedProdCompute.Length -gt 0
    Test-Case "call site ${envName} does not call Remove" $wouldCall $false
}
$prodNames = Get-DeprecatedProdComputeName -Slug 'cmdemo1' -Environment 'prod' -Retired @('aisf', 'fworker')
if ($null -eq $prodNames) { $prodNames = [string[]]@() }
elseif ($prodNames -isnot [string[]]) { $prodNames = [string[]]@($prodNames) }
Test-Case 'call site prod: Length 4' $prodNames.Length 4
Test-Case 'call site prod: would call Remove' ($prodNames.Length -gt 0) $true
# Prove the broken pattern is not used in executable code (comments may mention it).
$getFn = ($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DeprecatedProdComputeName' }, $false) | Select-Object -First 1)
Test-Case 'Get-DeprecatedProdComputeName body has no unary-comma empty return' (
    $getFn -and ($getFn.Body.Extent.Text -notmatch 'return\s*,\s*@\(\)')
) $true

if ($failures -gt 0) {
    Write-Host "$failures apply-environment check(s) failed."
    exit 1
}
Write-Host 'All apply-environment checks passed.'
