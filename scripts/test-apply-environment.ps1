#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the deprecated aisf/fworker/fwrunner removal helpers without Azure.

.DESCRIPTION
    Loads helpers from scripts/apply-environment.ps1 (AST only: that script has no LoadOnly and is inlined into the
    Octopus system step). Proves #575: the four exact prod compute names are selected only in prod when aisf and
    fworker are retired. Proves #578: the ten leftover identity/storage/AI names are selected only in prod and uat
    when those deployables are retired, keep-list names are never wanted, and ui settings detection is pure.

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
$needed = @(
    'Get-DeprecatedProdComputeName'
    'Select-PresentResourceName'
    'Remove-DeprecatedProdCompute'
    'Get-DeprecatedAisfLeftoverName'
    'Get-DeprecatedAisfComputePrerequisiteName'
    'Get-AisfLeftoverKeepName'
    'Test-UiReferencesAisfLeftover'
    'Remove-DeprecatedAisfLeftover'
)
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
function Test-Bool([string] $Name, [bool] $Actual, [bool] $Expected) {
    if ($Actual -eq $Expected) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $Expected, got $Actual"; $script:failures++ }
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

# --- #578 leftover identities / fwrunner storage / unused AI accounts ---
$prodFive = @(
    'id-cmdemo1-prod-aisf'
    'id-cmdemo1-prod-fworker'
    'id-cmdemo1-prod-fwrunner'
    'stcmdemo1prodfwrj7265dy3'
    'aif-cmdemo1-prod'
)
$uatFive = @(
    'id-cmdemo1-uat-aisf'
    'id-cmdemo1-uat-fworker'
    'id-cmdemo1-uat-fwrunner'
    'stcmdemo1uatfwr2bttonyso'
    'aif-cmdemo1-uat'
)

Test-Case 'prod leftovers: the five exact names (#578)' (
    Get-DeprecatedAisfLeftoverName -Slug 'cmdemo1' -Environment 'prod' -Retired @('aisf', 'fworker', 'scorecard')
) $prodFive

Test-Case 'uat leftovers: the five exact names (#578)' (
    Get-DeprecatedAisfLeftoverName -Slug 'cmdemo1' -Environment 'uat' -Retired @('aisf', 'fworker')
) $uatFive

Test-Case 'tdd leftovers: none (#578)' (
    Get-DeprecatedAisfLeftoverName -Slug 'cmdemo1' -Environment 'tdd' -Retired @('aisf', 'fworker')
) @()

Test-Case 'prod leftovers without retired aisf: nothing' (
    Get-DeprecatedAisfLeftoverName -Slug 'cmdemo1' -Environment 'prod' -Retired @('fworker')
) @()

Test-Case 'uat leftovers without retired fworker: nothing' (
    Get-DeprecatedAisfLeftoverName -Slug 'cmdemo1' -Environment 'uat' -Retired @('aisf')
) @()

Test-Case 'leftover slug is part of the exact names' (
    Get-DeprecatedAisfLeftoverName -Slug 'other' -Environment 'prod' -Retired @('aisf', 'fworker')
) @(
    'id-other-prod-aisf'
    'id-other-prod-fworker'
    'id-other-prod-fwrunner'
    'stotherprodfwrj7265dy3'
    'aif-other-prod'
)

Test-Case 'prod prerequisite compute names (#575 / #578)' (
    Get-DeprecatedAisfComputePrerequisiteName -Slug 'cmdemo1' -Environment 'prod'
) $prodFour

Test-Case 'uat prerequisite compute names (#574 / #578)' (
    Get-DeprecatedAisfComputePrerequisiteName -Slug 'cmdemo1' -Environment 'uat'
) @(
    'ca-cmdemo1-uat-aisf-fccv'
    'ca-cmdemo1-uat-fworker-fccv'
    'caj-cmdemo1-uat-fwrunner'
    'caj-cmdemo1-uat-fwrunner-codex'
)

Test-Case 'tdd has no leftover prerequisite list' (
    Get-DeprecatedAisfComputePrerequisiteName -Slug 'cmdemo1' -Environment 'tdd'
) @()

$keep = @(Get-AisfLeftoverKeepName -Slug 'cmdemo1')
Test-Case 'keep-list includes app/ui/deploy/plan/acr/octopus/scorecard-site and kept storage' (
    $keep
) @(
    'id-cmdemo1-tdd-app'
    'id-cmdemo1-uat-app'
    'id-cmdemo1-prod-app'
    'id-cmdemo1-tdd-ui'
    'id-cmdemo1-uat-ui'
    'id-cmdemo1-prod-ui'
    'id-cmdemo1-deploy-nonprod'
    'id-cmdemo1-deploy-prod'
    'id-cmdemo1-plan'
    'id-cmdemo1-acr-push'
    'id-cmdemo1-octopus-config'
    'id-cmdemo1-prod-scorecard-site'
    'stcmdemo1prodsscj7265dy3'
    'stcmdemo1tfchu4gq'
)

$wantedTen = @($prodFive + $uatFive)
$overlap = @($wantedTen | Where-Object { $keep -contains $_ })
Test-Case 'wanted leftovers never intersect keep-list' $overlap @()

Test-Bool 'ui settings that name aif leftover are a reference' (
    Test-UiReferencesAisfLeftover -SettingsJson '[{"name":"X","value":"https://aif-cmdemo1-prod.cognitiveservices.azure.com/"}]' -LeftoverName $prodFive
) $true

Test-Bool 'ui settings with only AI_OpenAI_Url are not a leftover reference' (
    Test-UiReferencesAisfLeftover -SettingsJson '[{"name":"AI_OpenAI_Url","value":"https://jeffr-mlq3cayr-swedencentral.openai.azure.com/"}]' -LeftoverName $prodFive
) $false

Test-Bool 'empty ui settings are not a leftover reference' (
    Test-UiReferencesAisfLeftover -SettingsJson '' -LeftoverName $prodFive
) $false

Test-Case 'apply-environment documents #578' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match '\#578'
) $true

Test-Case 'apply-environment lists blobs before storage delete' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match 'Write-StorageAccountBlobInventory'
) $true

Test-Case 'apply-environment calls Remove-DeprecatedAisfLeftover before stack apply' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match 'Remove-DeprecatedAisfLeftover[\s\S]*Invoke-StackApply'
) $true

Test-Case 'apply-environment skips leftover Remove when Length 0' (
    (Get-Content -LiteralPath $scriptPath -Raw) -match 'if \(\$deprecatedAisfLeftover\.Length -gt 0\)'
) $true

$emptyLeftoverOk = try {
    Remove-DeprecatedAisfLeftover -Group 'rg-cmdemo1-nonprod' -Slug 'cmdemo1' -Environment 'tdd' -Name @() -PrerequisiteName @()
    $true
} catch { $false }
Test-Case 'Remove-DeprecatedAisfLeftover accepts empty -Name (tdd)' $emptyLeftoverOk $true

foreach ($envName in @('tdd')) {
    $leftover = Get-DeprecatedAisfLeftoverName -Slug 'cmdemo1' -Environment $envName -Retired @('aisf', 'fworker')
    if ($null -eq $leftover) { $leftover = [string[]]@() }
    elseif ($leftover -isnot [string[]]) { $leftover = [string[]]@($leftover) }
    Test-Case "call site leftover ${envName} Length 0" $leftover.Length 0
    Test-Case "call site leftover ${envName} does not call Remove" ($leftover.Length -gt 0) $false
}
foreach ($envName in @('uat', 'prod')) {
    $leftover = Get-DeprecatedAisfLeftoverName -Slug 'cmdemo1' -Environment $envName -Retired @('aisf', 'fworker')
    if ($null -eq $leftover) { $leftover = [string[]]@() }
    elseif ($leftover -isnot [string[]]) { $leftover = [string[]]@($leftover) }
    Test-Case "call site leftover ${envName} Length 5" $leftover.Length 5
    Test-Case "call site leftover ${envName} would call Remove" ($leftover.Length -gt 0) $true
}

$getLeftoverFn = ($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DeprecatedAisfLeftoverName' }, $false) | Select-Object -First 1)
Test-Case 'Get-DeprecatedAisfLeftoverName body has no unary-comma empty return' (
    $getLeftoverFn -and ($getLeftoverFn.Body.Extent.Text -notmatch 'return\s*,\s*@\(\)')
) $true

# system.json: ui OpenAI is not the leftover AI accounts; aisf and fworker stay retired.
$systemPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'system.json'
$system = Get-Content -LiteralPath $systemPath -Raw | ConvertFrom-Json -AsHashtable
$ui = @($system.deployables | Where-Object { [string] $_.name -eq 'ui' })[0]
$openaiUrl = [string] $ui.settings.AI_OpenAI_Url
Test-Bool 'system.json ui AI_OpenAI_Url is not aif-cmdemo1-prod/uat' (
    ($openaiUrl -notmatch 'aif-cmdemo1-(prod|uat)') -and ($openaiUrl.Length -gt 0)
) $true
foreach ($name in @('aisf', 'fworker')) {
    $d = @($system.deployables | Where-Object { [string] $_.name -eq $name })[0]
    Test-Bool "system.json $name is retired" ([bool] $d.retired) $true
}

if ($failures -gt 0) {
    Write-Host "$failures apply-environment check(s) failed."
    exit 1
}
Write-Host 'All apply-environment checks passed.'
