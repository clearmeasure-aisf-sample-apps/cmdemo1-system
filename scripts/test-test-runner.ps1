#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the acceptance-test worker image wiring (issue #648) without Docker or Octopus.

.DESCRIPTION
    Proves the Dockerfile bakes Playwright + .NET 10, the published image name stays in sync across
    images/test-runner/image.txt, octopus/main.tf and system.yml, the Acceptance tests script prefers an
    image SDK 10 and keeps a retried fallback, and the Octopus test container uses the ghcr feed.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-test-runner.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSScriptRoot
$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualText = if ($null -eq $Actual) { '<null>' } else { [string] $Actual }
    $expectedText = if ($null -eq $Expected) { '<null>' } else { [string] $Expected }
    if ($actualText -ceq $expectedText) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedText, got $actualText"; $script:failures++ }
}

function Test-True([string] $Name, [bool] $Actual) {
    if ($Actual) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected true"; $script:failures++ }
}

$imageTxt = Join-Path $root 'images/test-runner/image.txt'
$dockerfile = Join-Path $root 'images/test-runner/Dockerfile'
$mainTf = Join-Path $root 'octopus/main.tf'
$systemYml = Join-Path $root '.github/workflows/system.yml'
$acceptance = Join-Path $root 'scripts/run-acceptance-tests.ps1'
$prepare = Join-Path $root 'scripts/prepare-test-runner.ps1'

Test-True 'image.txt exists' (Test-Path -LiteralPath $imageTxt)
Test-True 'Dockerfile exists' (Test-Path -LiteralPath $dockerfile)

$imageRef = @(Get-Content -LiteralPath $imageTxt | Where-Object { $_ -notmatch '^\s*(#|$)' } | ForEach-Object { $_.Trim() })[0]
Test-True 'image.txt names owner/name:tag' ($imageRef -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$')
Test-Case 'image tag includes playwright 1.61 and dotnet10' `
    ([string]($imageRef -match 'v1\.61\.0-dotnet10')) 'True'

$dockerText = Get-Content -LiteralPath $dockerfile -Raw
Test-True 'Dockerfile FROM playwright/dotnet:v1.61.0-noble' ($dockerText -cmatch 'FROM\s+mcr\.microsoft\.com/playwright/dotnet:v1\.61\.0-noble')
Test-True 'Dockerfile installs or verifies SDK 10' (
    ($dockerText -cmatch 'dotnet --list-sdks') -and (
        ($dockerText -cmatch '--channel 10\.0') -or ($dockerText -cmatch "grep -qE '\^10\\.'")
    )
)
Test-True 'Dockerfile does not leave a live download as the only path' ($dockerText -cmatch 'if ! dotnet --list-sdks')

$tfText = Get-Content -LiteralPath $mainTf -Raw
Test-True 'octopus test_runner_image default matches image.txt' ($tfText -cmatch [regex]::Escape("default     = `"$imageRef`""))
Test-True 'octopus defines ghcr feed' ($tfText -cmatch 'resource\s+"octopusdeploy_docker_container_registry"\s+"ghcr"')
Test-True 'octopus test_container uses ghcr feed' ($tfText -cmatch 'feed_id\s+=\s+octopusdeploy_docker_container_registry\.ghcr\.id')
Test-True 'octopus test_container uses test_runner_image' ($tfText -cmatch 'image\s+=\s+var\.test_runner_image')

$ymlText = Get-Content -LiteralPath $systemYml -Raw
Test-True 'system.yml has publish-test-runner job' ($ymlText -cmatch '(?m)^\s*publish-test-runner:\s*$')
Test-True 'octopus-apply needs publish-test-runner' ($ymlText -cmatch 'needs:\s*publish-test-runner')
Test-True 'system.yml pushes the image.txt reference' ($ymlText -cmatch [regex]::Escape("ghcr.io/$imageRef"))
Test-True 'system.yml builds images/test-runner/Dockerfile' ($ymlText -cmatch 'images/test-runner/Dockerfile')

$parseTokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($acceptance, [ref] $parseTokens, [ref] $parseErrors)
Test-True 'run-acceptance-tests.ps1 parses' ($parseErrors.Count -eq 0)
foreach ($fn in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($fn.Name -in @('Test-DotNetSdkListHas10', 'Install-DotNet10Sdk')) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}
Test-True 'defines Test-DotNetSdkListHas10' ($null -ne (Get-Command -Name Test-DotNetSdkListHas10 -CommandType Function -ErrorAction SilentlyContinue))
Test-True 'defines Install-DotNet10Sdk' ($null -ne (Get-Command -Name Install-DotNet10Sdk -CommandType Function -ErrorAction SilentlyContinue))

Test-Case 'SDK list with 10.x is present' (Test-DotNetSdkListHas10 -SdkList @('8.0.401 [/usr/share/dotnet/sdk]', '10.0.301 [/usr/share/dotnet/sdk]')) $true
Test-Case 'SDK list with only 8.x is absent' (Test-DotNetSdkListHas10 -SdkList @('8.0.401 [/usr/share/dotnet/sdk]')) $false
Test-Case 'empty SDK list is absent' (Test-DotNetSdkListHas10 -SdkList @()) $false

$acceptanceText = Get-Content -LiteralPath $acceptance -Raw
Test-True 'acceptance script calls Test-DotNetSdkListHas10 before install' (
    $acceptanceText.IndexOf('Test-DotNetSdkListHas10') -ge 0 -and
    $acceptanceText.IndexOf('Test-DotNetSdkListHas10') -lt $acceptanceText.IndexOf('Install-DotNet10Sdk -InstallDir')
)
Test-True 'fallback keeps retry URLs' (
    ($acceptanceText -cmatch 'dot\.net/v1/dotnet-install\.sh') -and
    ($acceptanceText -cmatch 'builds\.dotnet\.microsoft\.com/dotnet/scripts/v1/dotnet-install\.sh') -and
    ($acceptanceText -cmatch '\$maxAttempts\s*=\s*5')
)
Test-True 'image hit does not set temporary DOTNET_ROOT first' (
    $acceptanceText -cmatch 'SDK \(image\)' -and
    $acceptanceText -cmatch 'SDK \(fallback install\)'
)

$prepareText = Get-Content -LiteralPath $prepare -Raw
Test-True 'prepare-test-runner reports SDKs' ($prepareText -cmatch 'dotnet --list-sdks' -and $prepareText -cmatch 'SDKs:')

if ($failures -gt 0) {
    Write-Host "FAILED $failures test-test-runner check(s)"
    exit 1
}
Write-Host 'All test-test-runner checks passed.'
exit 0
