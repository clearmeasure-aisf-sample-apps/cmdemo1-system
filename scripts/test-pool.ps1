#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    What-if-free checks of the pull-request pool stack (infra/pool), without applying anything to Azure.

.DESCRIPTION
    Runs in job env-checks of .github/workflows/env-checks.yml on every pull request, and locally:

      pwsh -NoProfile -File scripts/test-pool.ps1

    Proves issue #653 as code only:

      1. system.json pool declares 8 slots, 2 warm, Standard 50 eDTU, 1 vCPU, maxReplicas 3, 14-day artifacts.
      2. infra/pool/main.bicep and its modules build with no Bicep warning or error.
      3. The compiled template names stack-cmdemo1-pool, the template database, pool-1..pool-8, warm minReplicas,
         HTTP concurrency maxReplicas, and artifacts retention.
      4. scripts/apply-environment.ps1 and the system / drift workflows do not apply this stack (no auto-apply).

    Exit 1 when any check fails. Never signs in to Azure and never creates a resource.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-pool.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$failures = [Collections.Generic.List[string]]::new()
function Test-Rule {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        Write-Host "PASS $Name"
    }
    else {
        Write-Host "FAIL $Name$(if ($Detail) { ": $Detail" })"
        $failures.Add($Name)
    }
}

$systemPath = Join-Path $Root 'system.json'
$system = Get-Content -LiteralPath $systemPath -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
Test-Rule 'system.json has pool' ($system.ContainsKey('pool') -and $system.pool -is [Collections.IDictionary]) 'top-level object pool'

$pool = if ($system.ContainsKey('pool')) { $system.pool } else { @{} }
if ($pool -is [Collections.IDictionary]) {
    $allowed = @('slots', 'warm', 'elasticPoolEdtus', 'appCpu', 'maxReplicas', 'httpConcurrentRequests', 'artifactsRetentionDays')
    $extra = @($pool.Keys | Where-Object { $allowed -cnotcontains $_ })
    Test-Rule 'pool keys' ($extra.Count -eq 0) "unknown: $($extra -join ', ')"
    Test-Rule 'pool.slots' (($pool['slots'] -is [int] -or $pool['slots'] -is [long]) -and [int] $pool.slots -eq 8) '8 slots for shadow mode'
    Test-Rule 'pool.warm' (($pool['warm'] -is [int] -or $pool['warm'] -is [long]) -and [int] $pool.warm -eq 2) '2 warm slots for shadow mode'
    Test-Rule 'pool.elasticPoolEdtus' (($pool['elasticPoolEdtus'] -is [int] -or $pool['elasticPoolEdtus'] -is [long]) -and [int] $pool.elasticPoolEdtus -eq 50) 'Standard 50 eDTU'
    Test-Rule 'pool.appCpu' ($pool['appCpu'] -ceq '1') '1 vCPU (2 GiB on Consumption)'
    Test-Rule 'pool.maxReplicas' (($pool['maxReplicas'] -is [int] -or $pool['maxReplicas'] -is [long]) -and [int] $pool.maxReplicas -eq 3) 'maxReplicas 3'
    Test-Rule 'pool.httpConcurrentRequests' (($pool['httpConcurrentRequests'] -is [int] -or $pool['httpConcurrentRequests'] -is [long]) -and [int] $pool.httpConcurrentRequests -ge 1) 'HTTP concurrency threshold'
    Test-Rule 'pool.artifactsRetentionDays' (($pool['artifactsRetentionDays'] -is [int] -or $pool['artifactsRetentionDays'] -is [long]) -and [int] $pool.artifactsRetentionDays -eq 14) '14-day expiry'
}

$poolDir = Join-Path $Root 'infra' 'pool'
$main = Join-Path $poolDir 'main.bicep'
Test-Rule 'infra/pool/main.bicep exists' (Test-Path -LiteralPath $main)
foreach ($module in @('sql.bicep', 'slots.bicep', 'vault.bicep', 'artifacts.bicep')) {
    Test-Rule "infra/pool/modules/$module exists" (Test-Path -LiteralPath (Join-Path $poolDir 'modules' $module))
}

$readme = Join-Path $poolDir 'README.md'
Test-Rule 'infra/pool/README.md warns apply needs Jeffrey yes' (
    (Test-Path -LiteralPath $readme) -and
    ((Get-Content -LiteralPath $readme -Raw) -match "Jeffrey's (explicit )?yes") -and
    ((Get-Content -LiteralPath $readme -Raw) -match 'Do not') 
)

# Bicep build: warnings fail like env-checks. Needs az + Bicep; skip only when az is absent (local without CLI).
$compiled = Join-Path ([IO.Path]::GetTempPath()) "pool-bicep-$([Guid]::NewGuid().ToString('N')).json"
$az = Get-Command az -ErrorAction SilentlyContinue
if (-not $az) {
    Write-Host 'SKIP bicep build: az is not on PATH (env-checks installs it)'
}
else {
    $env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'
    $env:AZURE_BICEP_CHECK_VERSION = 'false'
    $previousErrorAction = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    $diagnostics = & az bicep build --file $main --outfile $compiled 2>&1 | ForEach-Object { "$_" }
    $PSNativeCommandUseErrorActionPreference = $previousErrorAction
    $problems = @($diagnostics | Where-Object { $_ -match ': (Warning|Error) ' })
    Test-Rule 'bicep build infra/pool/main.bicep' ($problems.Count -eq 0 -and (Test-Path -LiteralPath $compiled)) ($problems -join '; ')
}

if (Test-Path -LiteralPath $compiled) {
    $arm = Get-Content -LiteralPath $compiled -Raw
    # Names are format() expressions over system.json (slug, slot index), not literal cmdemo1 strings.
    Test-Rule 'compiled stack name stack-<slug>-pool' ($arm -match "format\('stack-\{0\}-pool'")
    Test-Rule 'compiled template database name' ($arm -match "format\('sqldb-\{0\}-pool-template'")
    Test-Rule 'compiled elastic pool StandardPool' ($arm -match 'StandardPool')
    Test-Rule 'compiled elastic pool capacity from pool.elasticPoolEdtus' ($arm -match 'elasticPoolEdtus|elasticPoolCapacity')
    Test-Rule 'compiled slots pool-{n} from range' (
        ($arm -match "format\('pool-\{0\}'") -and
        ($arm -match "range\(1,\s*variables\('slotCount'\)\)") -and
        ($arm -match "int\(variables\('pool'\)\.slots\)")
    )
    Test-Rule 'compiled slot databases sqldb-<slug>-<slot>' ($arm -match "format\('sqldb-\{0\}-\{1\}'")
    Test-Rule 'compiled warm minReplicas expression' ($arm -match 'minReplicas' -and $arm -match 'warmSlots')
    Test-Rule 'compiled warm count from pool.warm' ($arm -match "int\(variables\('pool'\)\.warm\)")
    Test-Rule 'compiled HTTP concurrency scale rule' ($arm -match 'http-concurrency' -and $arm -match 'concurrentRequests')
    Test-Rule 'compiled maxReplicas parameter' ($arm -match 'maxReplicas')
    Test-Rule 'compiled artifacts containers videos and traces' ($arm -match '"videos"' -and $arm -match '"traces"')
    Test-Rule 'compiled artifacts 14-day lifecycle' ($arm -match 'daysAfterModificationGreaterThan' -and $arm -match 'artifactsRetentionDays|retentionDays')
    Test-Rule 'compiled pool app identity' ($arm -match "format\('id-\{0\}-pool-app'")
    Remove-Item -LiteralPath $compiled -Force -ErrorAction SilentlyContinue
}

# No auto-apply: the environment apply path and the workflows that deploy infra must not name this stack.
$apply = Get-Content -LiteralPath (Join-Path $Root 'scripts' 'apply-environment.ps1') -Raw
Test-Rule 'apply-environment.ps1 does not apply stack-*-pool' (
    ($apply -notmatch 'stack-\$slug-pool') -and
    ($apply -notmatch 'infra/pool') -and
    ($apply -notmatch 'pool/main\.bicep')
) 'pool must stay out of the Octopus environment apply'

$systemWorkflow = Get-Content -LiteralPath (Join-Path $Root '.github' 'workflows' 'system.yml') -Raw
Test-Rule 'system.yml does not apply the pool stack' (
    ($systemWorkflow -notmatch 'infra/pool') -and
    ($systemWorkflow -notmatch 'stack-.*-pool')
)

$driftWorkflow = Get-Content -LiteralPath (Join-Path $Root '.github' 'workflows' 'drift.yml') -Raw
Test-Rule 'drift.yml does not apply the pool stack' (
    ($driftWorkflow -notmatch 'infra/pool') -and
    ($driftWorkflow -notmatch 'az stack group create')
)

$preview = Get-Content -LiteralPath (Join-Path $Root 'scripts' 'preview-environment.ps1') -Raw
Test-Rule 'preview-environment.ps1 stays on environment templates' (
    ($preview -notmatch 'infra/pool') -and
    ($preview -match 'infra/main\.bicep' -or $preview -match 'main\.bicep')
)

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) pool check(s) failed."
    exit 1
}
Write-Host 'All pool checks passed.'
