#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests ConvertTo-Topology's container-app deployables without Azure or Octopus.

.DESCRIPTION
    Loads scripts/deploy-staticwebapp.ps1 with DeployStaticWebAppLoadOnly so only its functions run, then proves
    topology.json deployables list ca-<slug>-<env>-ui with /_healthcheck and /_healthcheck/detailed for tdd, uat and
    prod, and never aisf or fworker (system.azureExcludeDeployables, #542 / #556).

.EXAMPLE
    pwsh -NoProfile -File scripts/test-deploy-staticwebapp.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# No param block and no LoadOnly on deploy-staticwebapp.ps1 (octopus/projects.tf joins it with github-token.ps1).
# Load only its top-level functions so ConvertTo-Topology can be exercised without OctopusParameters or Azure.
$scriptPath = Join-Path $PSScriptRoot 'deploy-staticwebapp.ps1'
$parseTokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $parseTokens, [ref] $parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host "FAIL deploy-staticwebapp.ps1 does not parse: $($parseErrors[0])"
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

function New-TopologySystem {
    # A minimal system.json shape: ui (container app), aisf and fworker excluded from Azure, dashboard static.
    param([string[]] $Environments = @('tdd', 'uat', 'prod'))
    return @{
        system      = @{
            slug                     = 'cmdemo1'
            name                     = 'Clear Measure work orders demo 1'
            location                 = 'southcentralus'
            githubOrg                = 'clearmeasure-aisf-sample-apps'
            repository               = 'cmdemo1-system'
            azureExcludeDeployables  = @('aisf', 'fworker')
        }
        azure       = @{
            tenantId       = '00000000-0000-0000-0000-000000000001'
            subscriptionId = '00000000-0000-0000-0000-000000000002'
            resourceGroups = @{ nonprod = 'rg-cmdemo1-nonprod'; prod = 'rg-cmdemo1-prod' }
        }
        octopus     = @{
            url     = 'https://clearmeasure.octopus.app'
            spaceId = 'Spaces-355'
        }
        deployables = @(
            @{
                name          = 'ui'
                healthPath    = '/_healthcheck'
                buildPath     = '/_build'
                telemetryPath = '/_telemetry'
                trafficPaths  = @('/', '/api/work-orders/status-counts')
            }
            @{
                name       = 'aisf'
                healthPath = '/health'
            }
            @{
                name          = 'dashboard'
                hosting       = 'staticwebapp'
                healthPath    = '/'
                buildPath     = '/build-facts.json'
            }
            @{
                name          = 'fworker'
                healthPath    = '/health'
                dashboardLink = @{ text = 'Factory'; path = '/dashboard' }
                environments  = @('tdd', 'uat', 'prod')
            }
        )
        environments = @(foreach ($name in $Environments) {
                $tier = if ($name -eq 'prod') { 'prod' } else { 'nonprod' }
                @{ name = $name; tier = $tier; capabilities = @('baseline', 'telemetry') }
            })
    }
}

function New-PageAddress {
    # One https address per environment for ui, and stale addresses for aisf/fworker so exclusion is proven.
    param([string[]] $Environments = @('tdd', 'uat', 'prod'))
    $pages = @{}
    foreach ($name in $Environments) {
        $pages[$name] = @{
            ui      = "https://ca-cmdemo1-$name-ui.example.southcentralus.azurecontainerapps.io"
            aisf    = "https://ca-cmdemo1-$name-aisf.example.southcentralus.azurecontainerapps.io"
            fworker = "https://ca-cmdemo1-$name-fworker.example.southcentralus.azurecontainerapps.io"
        }
    }
    return $pages
}

$generated = [datetime]::Parse('2026-11-11T02:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
$system = New-TopologySystem
$pages = New-PageAddress
$topology = ConvertTo-Topology -System $system -PageAddress $pages -Generated $generated -Dashboard 'dashboard'

Test-Case 'topology lists tdd, uat and prod' @($topology.environments | ForEach-Object { [string] $_.name }) @('tdd', 'uat', 'prod')

foreach ($environmentName in @('tdd', 'uat', 'prod')) {
    $entry = @($topology.environments | Where-Object { [string] $_.name -eq $environmentName }) | Select-Object -First 1
    $names = @($entry.deployables | ForEach-Object { [string] $_.name })
    Test-Case "$environmentName deployables are only ui" $names @('ui')

    $ui = @($entry.deployables | Where-Object { [string] $_.name -eq 'ui' }) | Select-Object -First 1
    $nodeName = "ca-cmdemo1-$environmentName-ui"
    $url = "https://ca-cmdemo1-$environmentName-ui.example.southcentralus.azurecontainerapps.io"
    Test-Case "$environmentName ui node is $nodeName" @($ui.nodes | ForEach-Object { [string] $_.name }) @($nodeName)
    Test-Case "$environmentName ui node url" @($ui.nodes | ForEach-Object { [string] $_.url }) @($url)
    Test-Case "$environmentName ui healthPath" ([string] $ui.healthPath) '/_healthcheck'
    Test-Case "$environmentName ui healthDetailPath" ([string] $ui.healthDetailPath) '/_healthcheck/detailed'
    Test-Case "$environmentName ui alivePath follows healthPath" ([string] $ui.alivePath) '/_healthcheck'
    Test-Case "$environmentName has no aisf deployable" @($entry.deployables | Where-Object { [string] $_.name -eq 'aisf' }).Count 0
    Test-Case "$environmentName has no fworker deployable" @($entry.deployables | Where-Object { [string] $_.name -eq 'fworker' }).Count 0
    Test-Case "$environmentName has no aisf or fworker node" @(
        $entry.deployables | ForEach-Object { $_.nodes } | ForEach-Object { [string] $_.name } |
            Where-Object { $_ -match '-(aisf|fworker)$' }
    ).Count 0
    Test-Case "$environmentName has no Factory page from excluded fworker" @(
        if ($entry.Contains('pages')) { @($entry.pages | Where-Object { [string] $_['deployable'] -eq 'fworker' }).Count } else { 0 }
    ) 0
}

# Without azureExcludeDeployables, a listed address would still emit aisf; with it, a stale PageAddress cannot.
$withoutExclude = New-TopologySystem
$withoutExclude.system.Remove('azureExcludeDeployables')
$leaked = ConvertTo-Topology -System $withoutExclude -PageAddress $pages -Generated $generated
$tddNames = @(@($leaked.environments | Where-Object { [string] $_.name -eq 'tdd' })[0].deployables | ForEach-Object { [string] $_.name } | Sort-Object)
Test-Case 'without azureExcludeDeployables tdd lists aisf, fworker and ui' $tddNames @('aisf', 'fworker', 'ui')

# An environment with no address for ui leaves deployables empty there (no invented host).
$partial = New-PageAddress -Environments @('tdd')
$partial['uat'] = @{ aisf = 'https://ca-cmdemo1-uat-aisf.example.southcentralus.azurecontainerapps.io' }
$partial['prod'] = $pages['prod']
$sparse = ConvertTo-Topology -System $system -PageAddress $partial -Generated $generated
Test-Case 'uat without ui address has no deployables' @(
    @($sparse.environments | Where-Object { [string] $_.name -eq 'uat' })[0].deployables
).Count 0
Test-Case 'tdd with ui address still has ca-cmdemo1-tdd-ui' @(
    @(@($sparse.environments | Where-Object { [string] $_.name -eq 'tdd' })[0].deployables | ForEach-Object { $_.nodes } | ForEach-Object { [string] $_.name })
) @('ca-cmdemo1-tdd-ui')

# system.json healthDetailPath wins over the container-app default.
$custom = New-TopologySystem
$custom.deployables[0].healthDetailPath = '/custom/detailed'
$custom.deployables[0].healthPath = '/custom/live'
$customTopology = ConvertTo-Topology -System $custom -PageAddress $pages -Generated $generated
$customUi = @(@($customTopology.environments | Where-Object { [string] $_.name -eq 'prod' })[0].deployables | Where-Object { [string] $_.name -eq 'ui' })[0]
Test-Case 'system.json healthPath is kept' ([string] $customUi.healthPath) '/custom/live'
Test-Case 'system.json healthDetailPath is kept' ([string] $customUi.healthDetailPath) '/custom/detailed'

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'deploy-staticwebapp.ps1') -Raw
Test-Case 'writer still builds topology deployables' ($source -match 'healthDetailPath = if \(\$app\[''healthDetailPath''\]\)') $true
Test-Case 'writer defaults detail to /_healthcheck/detailed' ($source -match "'/_healthcheck/detailed'") $true
Test-Case 'writer omits azureExcludeDeployables' ($source -match 'azureExcludeDeployables') $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
