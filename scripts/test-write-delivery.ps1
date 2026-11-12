#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests Select-DeliveryDeployable without Octopus or GitHub.

.DESCRIPTION
    Loads scripts/write-delivery.ps1 functions only, then proves delivery.json's deployable list omits
    system.azureExcludeDeployables (aisf, fworker) and retired scorecard (#577), and keeps ui and dashboard.
    The system project is added by write-delivery.ps1 after this filter; it is not a deployables[] entry.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-write-delivery.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# No param block and no LoadOnly on write-delivery.ps1 (the delivery workflow runs it end-to-end). Load only its
# top-level functions so Select-DeliveryDeployable can be exercised without Octopus credentials.
$scriptPath = Join-Path $PSScriptRoot 'write-delivery.ps1'
$parseTokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $parseTokens, [ref] $parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host "FAIL write-delivery.ps1 does not parse: $($parseErrors[0])"
    exit 1
}
foreach ($fn in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 8
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 8
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

function New-DeliverySystem {
    # Minimal system.json shape: ui and dashboard kept; aisf and fworker excluded from Azure; scorecard retired.
    return @{
        system      = @{
            slug                    = 'cmdemo1'
            azureExcludeDeployables = @('aisf', 'fworker')
        }
        deployables = @(
            @{ name = 'ui'; repository = 'cmdemo1-workorders' }
            @{ name = 'aisf'; repository = 'cmdemo1-aisf' }
            @{ name = 'dashboard'; repository = 'cmdemo1-dashboard'; hosting = 'staticwebapp' }
            @{ name = 'scorecard'; repository = 'cmdemo1-scorecard'; retired = $true }
            @{ name = 'fworker'; repository = 'cmdemo1-fworker' }
        )
    }
}

$system = New-DeliverySystem
$kept = @(Select-DeliveryDeployable $system | ForEach-Object { [string] $_.name })
Test-Case 'Select-DeliveryDeployable keeps ui and dashboard' $kept @('ui', 'dashboard')
Test-Case 'Select-DeliveryDeployable omits azureExcludeDeployables aisf' ($kept -contains 'aisf') $false
Test-Case 'Select-DeliveryDeployable omits azureExcludeDeployables fworker' ($kept -contains 'fworker') $false
Test-Case 'Select-DeliveryDeployable omits retired scorecard' ($kept -contains 'scorecard') $false

$withoutExclude = New-DeliverySystem
$withoutExclude.system.Remove('azureExcludeDeployables')
$withoutExcludeNames = @(Select-DeliveryDeployable $withoutExclude | ForEach-Object { [string] $_.name })
Test-Case 'without azureExcludeDeployables keeps aisf and fworker, still omits retired' $withoutExcludeNames @('ui', 'aisf', 'dashboard', 'fworker')

$source = Get-Content -LiteralPath $scriptPath -Raw
Test-Case 'writer applies Select-DeliveryDeployable before projects' ($source -match 'Select-DeliveryDeployable \$system') $true
Test-Case 'writer documents azureExcludeDeployables' ($source -match 'azureExcludeDeployables') $true
Test-Case 'writer documents retired' ($source -match "retired") $true

if ($failures -gt 0) {
    Write-Host "$failures check(s) failed."
    exit 1
}
Write-Host 'All write-delivery checks passed.'
