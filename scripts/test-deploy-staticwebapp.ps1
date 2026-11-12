#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests ConvertTo-Topology's container-app deployables without Azure or Octopus.

.DESCRIPTION
    Loads scripts/deploy-staticwebapp.ps1 functions only, then proves topology.json deployables list
    ca-<slug>-<env>-ui with /_healthcheck and /_healthcheck/detailed for tdd, uat and prod, and never aisf, fworker
    or retired scorecard (system.azureExcludeDeployables, #542 / #556 / #573). Also proves ConvertTo-PageAddressMap
    fills ui from containers.json when the stack omits it (the live gap that left deployables empty).

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
    # A minimal system.json shape: ui (container app), aisf and fworker excluded from Azure, retired scorecard, dashboard static.
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
                name         = 'scorecard'
                retired      = $true
                healthPath   = '/health'
                buildPath    = '/_build'
                environments = @('tdd')
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
    Test-Case "$environmentName ui buildPath" ([string] $ui.buildPath) '/_build'
    Test-Case "$environmentName ui telemetryPath" ([string] $ui.telemetryPath) '/_telemetry'
    Test-Case "$environmentName ui trafficPaths" @($ui.trafficPaths | ForEach-Object { [string] $_ }) @('/', '/api/work-orders/status-counts')
    Test-Case "$environmentName has no aisf deployable" @($entry.deployables | Where-Object { [string] $_.name -eq 'aisf' }).Count 0
    Test-Case "$environmentName has no fworker deployable" @($entry.deployables | Where-Object { [string] $_.name -eq 'fworker' }).Count 0
    Test-Case "$environmentName has no scorecard deployable" @($entry.deployables | Where-Object { [string] $_.name -eq 'scorecard' }).Count 0
    Test-Case "$environmentName has no aisf or fworker node" @(
        $entry.deployables | ForEach-Object { $_.nodes } | ForEach-Object { [string] $_.name } |
            Where-Object { $_ -match '-(aisf|fworker|scorecard)$' }
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

# #573: own-environment (or any) stack outputs that omit ui must still pick ui up from containers.json. Before the
# fix, ConvertTo-PageAddressMap's predecessor only consulted status when the whole stack read failed ($reason), so a
# successful stack answer without ui left PageAddress empty and topology deployables [].
$uiUrl = 'https://ca-cmdemo1-prod-ui-bhj5.happyisland-465ac2bf.southcentralus.azurecontainerapps.io'
$stackWithoutUi = @(
    @{ name = 'dashboard'; hosting = 'staticwebapp'; url = 'https://blue-bush-041023510.1.azurestaticapps.net' }
)
$containersEnv = @{
    ui         = $uiUrl
    aisf       = 'https://ca-cmdemo1-prod-aisf-bhj5.happyisland-465ac2bf.southcentralus.azurecontainerapps.io'
    fworker    = 'https://ca-cmdemo1-prod-fworker-bhj5.happyisland-465ac2bf.southcentralus.azurecontainerapps.io'
    dashboard  = 'https://blue-bush-041023510.1.azurestaticapps.net'
    scorecard  = 'https://ca-cmdemo1-tdd-scorecard.example.southcentralus.azurecontainerapps.io'
}
$gapFill = ConvertTo-PageAddressMap -Wanted @('ui') -Reported $stackWithoutUi -Published $containersEnv
Test-Case 'stack without ui fills ui from containers.json' ([string] $gapFill.Addresses['ui']) $uiUrl
Test-Case 'stack without ui fills only wanted names' @($gapFill.Addresses.Keys | Sort-Object) @('ui')
Test-Case 'stack without ui records fill from status' @($gapFill.FilledFromStatus) @('ui')
Test-Case 'stack without ui has no missing after fill' @($gapFill.Missing).Count 0

# A stack that already has ui keeps the stack address and does not prefer a stale status url.
$stackWithUi = @(
    @{ name = 'ui'; hosting = 'containerapp'; url = 'https://ca-cmdemo1-prod-ui.example.southcentralus.azurecontainerapps.io' }
    @{ name = 'dashboard'; hosting = 'staticwebapp'; url = 'https://blue-bush-041023510.1.azurestaticapps.net' }
)
$preferStack = ConvertTo-PageAddressMap -Wanted @('ui') -Reported $stackWithUi -Published $containersEnv
Test-Case 'stack address wins over containers.json' ([string] $preferStack.Addresses['ui']) 'https://ca-cmdemo1-prod-ui.example.southcentralus.azurecontainerapps.io'
Test-Case 'stack address does not count as status fill' @($preferStack.FilledFromStatus).Count 0

# End-to-end: addresses recovered from containers.json produce a ui deployable with every health/code path, and never
# aisf, fworker, scorecard or a Factory page even when status still lists those deprecated apps.
$recoveredPages = @{
    tdd  = (ConvertTo-PageAddressMap -Wanted @('ui') -Reported @() -Published @{
            ui = 'https://ca-cmdemo1-tdd-ui.example.southcentralus.azurecontainerapps.io'
            aisf = 'https://ca-cmdemo1-tdd-aisf.example.southcentralus.azurecontainerapps.io'
            fworker = 'https://ca-cmdemo1-tdd-fworker.example.southcentralus.azurecontainerapps.io'
        }).Addresses
    uat  = (ConvertTo-PageAddressMap -Wanted @('ui') -Reported @(@{ name = 'dashboard'; url = 'https://example.net' }) -Published @{
            ui = 'https://ca-cmdemo1-uat-ui.example.southcentralus.azurecontainerapps.io'
            aisf = 'https://ca-cmdemo1-uat-aisf.example.southcentralus.azurecontainerapps.io'
            fworker = 'https://ca-cmdemo1-uat-fworker.example.southcentralus.azurecontainerapps.io'
        }).Addresses
    prod = $gapFill.Addresses
}
$recovered = ConvertTo-Topology -System $system -PageAddress $recoveredPages -Generated $generated -Dashboard 'dashboard'
foreach ($environmentName in @('tdd', 'uat', 'prod')) {
    $entry = @($recovered.environments | Where-Object { [string] $_.name -eq $environmentName }) | Select-Object -First 1
    $names = @($entry.deployables | ForEach-Object { [string] $_.name })
    Test-Case "recovered $environmentName deployables are only ui" $names @('ui')
    $ui = @($entry.deployables | Where-Object { [string] $_.name -eq 'ui' }) | Select-Object -First 1
    Test-Case "recovered $environmentName ui has address" ([string] @($ui.nodes)[0].url -match '^https://') $true
    Test-Case "recovered $environmentName ui healthPath" ([string] $ui.healthPath) '/_healthcheck'
    Test-Case "recovered $environmentName ui buildPath" ([string] $ui.buildPath) '/_build'
    Test-Case "recovered $environmentName ui telemetryPath" ([string] $ui.telemetryPath) '/_telemetry'
    Test-Case "recovered $environmentName ui trafficPaths" @($ui.trafficPaths | ForEach-Object { [string] $_ }) @('/', '/api/work-orders/status-counts')
    Test-Case "recovered $environmentName ui healthDetailPath" ([string] $ui.healthDetailPath) '/_healthcheck/detailed'
    Test-Case "recovered $environmentName has no aisf" @($entry.deployables | Where-Object { [string] $_.name -eq 'aisf' }).Count 0
    Test-Case "recovered $environmentName has no fworker" @($entry.deployables | Where-Object { [string] $_.name -eq 'fworker' }).Count 0
    Test-Case "recovered $environmentName has no scorecard" @($entry.deployables | Where-Object { [string] $_.name -eq 'scorecard' }).Count 0
    Test-Case "recovered $environmentName has no Factory page" @(
        if ($entry.Contains('pages')) { @($entry.pages | Where-Object { [string] $_['name'] -eq 'Factory' -or [string] $_['deployable'] -eq 'fworker' }).Count } else { 0 }
    ) 0
}

# Retired scorecard with a stale PageAddress still never appears.
$withScorecardAddress = New-PageAddress
foreach ($environmentName in @('tdd', 'uat', 'prod')) {
    $withScorecardAddress[$environmentName]['scorecard'] = "https://ca-cmdemo1-$environmentName-scorecard.example.southcentralus.azurecontainerapps.io"
}
$retiredGone = ConvertTo-Topology -System $system -PageAddress $withScorecardAddress -Generated $generated
Test-Case 'retired scorecard never becomes a deployable' @(
    $retiredGone.environments | ForEach-Object { $_.deployables } | Where-Object { [string] $_.name -eq 'scorecard' }
).Count 0

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'deploy-staticwebapp.ps1') -Raw
Test-Case 'writer still builds topology deployables' ($source -match 'healthDetailPath = if \(\$app\[''healthDetailPath''\]\)') $true
Test-Case 'writer defaults detail to /_healthcheck/detailed' ($source -match "'/_healthcheck/detailed'") $true
Test-Case 'writer omits azureExcludeDeployables' ($source -match 'azureExcludeDeployables') $true
Test-Case 'writer fills page addresses from containers.json gaps' ($source -match 'ConvertTo-PageAddressMap') $true
Test-Case 'writer skips retired deployables in topology' ($source -match "if \(\`$app\['retired'\] -eq \`$true\)") $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'
