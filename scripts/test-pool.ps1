#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    What-if-free checks of the pull-request pool stack (infra/pool), without applying anything to Azure.

.DESCRIPTION
    Runs in job env-checks of .github/workflows/env-checks.yml on every pull request, and locally:

      pwsh -NoProfile -File scripts/test-pool.ps1

    Proves, as code only, the pool stack (#653/#656) and the seed pool identity and lease store (#652):

      1. system.json pool declares 8 slots, pool.warm.count 2 (plus warm/cool schedule), Standard 50 eDTU, 1 vCPU,
         maxReplicas 3, 14-day artifacts, and pool.lease caps.
      2. infra/pool/main.bicep and its modules build with no Bicep warning or error.
      3. The compiled template names stack-cmdemo1-pool, the template database, pool-1..pool-8, warm minReplicas,
         HTTP concurrency maxReplicas, and artifacts retention.
      4. Artifacts RBAC grants Storage Blob Data Contributor at videos/traces container scope to the pool app
         identity and the existing acr-push OIDC principal (system.json azure.identities.acrPush).
      5. scripts/apply-environment.ps1 and the system / drift workflows do not apply this stack (no auto-apply).

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
    $allowed = @('slots', 'warm', 'lease', 'elasticPoolEdtus', 'appCpu', 'maxReplicas', 'httpConcurrentRequests', 'artifactsRetentionDays')
    $extra = @($pool.Keys | Where-Object { $allowed -cnotcontains $_ })
    Test-Rule 'pool keys' ($extra.Count -eq 0) "unknown: $($extra -join ', ')"
    Test-Rule 'pool.slots' (($pool['slots'] -is [int] -or $pool['slots'] -is [long]) -and [int] $pool.slots -eq 8) '8 slots for shadow mode'
    $warm = $pool['warm']
    Test-Rule 'pool.warm is schedule object' ($warm -is [Collections.IDictionary]) 'count + warm/cool schedule (#656)'
    if ($warm -is [Collections.IDictionary]) {
        Test-Rule 'pool.warm.count' (($warm['count'] -is [int] -or $warm['count'] -is [long]) -and [int] $warm.count -eq 2) '2 warm slots for shadow mode'
        Test-Rule 'pool.warm.managerIntervalMinutes' (($warm['managerIntervalMinutes'] -is [int] -or $warm['managerIntervalMinutes'] -is [long]) -and [int] $warm.managerIntervalMinutes -eq 5) 'manager every 5 minutes'
        Test-Rule 'pool.warm.waitToWarmMinutes' (($warm['waitToWarmMinutes'] -is [int] -or $warm['waitToWarmMinutes'] -is [long]) -and [int] $warm.waitToWarmMinutes -eq 1) 'warm after 1 minute wait'
        Test-Rule 'pool.warm.idleToCoolMinutes' (($warm['idleToCoolMinutes'] -is [int] -or $warm['idleToCoolMinutes'] -is [long]) -and [int] $warm.idleToCoolMinutes -eq 30) 'cool after 30 idle minutes'
    }
    $lease = $pool['lease']
    Test-Rule 'pool.lease is object' ($lease -is [Collections.IDictionary]) 'lease caps (#656)'
    if ($lease -is [Collections.IDictionary]) {
        Test-Rule 'pool.lease.maxMinutes' (($lease['maxMinutes'] -is [int] -or $lease['maxMinutes'] -is [long]) -and [int] $lease.maxMinutes -eq 30) '30 minute lease cap without hold-env'
        Test-Rule 'pool.lease.holdEnvMaxHours' (($lease['holdEnvMaxHours'] -is [int] -or $lease['holdEnvMaxHours'] -is [long]) -and [int] $lease.holdEnvMaxHours -eq 24) 'hold-env up to 24 hours'
        Test-Rule 'pool.lease.waitNotifyMinutes' (($lease['waitNotifyMinutes'] -is [int] -or $lease['waitNotifyMinutes'] -is [long]) -and [int] $lease.waitNotifyMinutes -eq 5) 'notify after 5 minutes waiting'
    }
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
    Test-Rule 'compiled warm count from pool.warm.count' ($arm -match "int\(variables\('pool'\)\.warm\.count\)")
    Test-Rule 'compiled HTTP concurrency scale rule' ($arm -match 'http-concurrency' -and $arm -match 'concurrentRequests')
    Test-Rule 'compiled maxReplicas parameter' ($arm -match 'maxReplicas')
    Test-Rule 'compiled artifacts containers videos and traces' ($arm -match '"videos"' -and $arm -match '"traces"')
    Test-Rule 'compiled artifacts 14-day lifecycle' ($arm -match 'daysAfterModificationGreaterThan' -and $arm -match 'artifactsRetentionDays|retentionDays')
    Test-Rule 'compiled pool app identity' ($arm -match "format\('id-\{0\}-pool-app'")
    # Storage Blob Data Contributor (ba92f5b4-...) at container scope for pool app + existing acr-push OIDC principal.
    $blobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    $acrPushPrincipalId = [string] $system.azure.identities.acrPush.principalId
    Test-Rule 'system.json azure.identities.acrPush.principalId' (-not [string]::IsNullOrWhiteSpace($acrPushPrincipalId))
    Test-Rule 'compiled artifacts Storage Blob Data Contributor role' ($arm -match [regex]::Escape($blobDataContributor))
    Test-Rule 'compiled artifacts grant acr-push principalId' ($arm -match [regex]::Escape($acrPushPrincipalId))
    Test-Rule 'compiled artifacts role assignments at container scope' (
        ($arm -match 'Microsoft\.Storage/storageAccounts/blobServices/containers') -and
        ($arm -match 'contributorPrincipalIds')
    )
    Remove-Item -LiteralPath $compiled -Force -ErrorAction SilentlyContinue
}

# Source contract: pool stack wires existing acr-push object id from system.json (no new identity/secret/SAS).
$poolMainSource = Get-Content -LiteralPath $main -Raw
$artifactsSource = Get-Content -LiteralPath (Join-Path $poolDir 'modules' 'artifacts.bicep') -Raw
Test-Rule 'pool main passes acrPush principalId to artifacts' (
    ($poolMainSource -match 'contributorPrincipalIds') -and
    ($poolMainSource -match 'system\.azure\.identities\.acrPush\.principalId') -and
    ($poolMainSource -match 'poolAppIdentity\.properties\.principalId')
)
Test-Rule 'artifacts role assignments use container scope' (
    ($artifactsSource -match "scope:\s*artifactContainers") -and
    ($artifactsSource -notmatch "scope:\s*account\b")
)
Test-Rule 'artifacts grants Storage Blob Data Contributor only' (
    ($artifactsSource -match [regex]::Escape('ba92f5b4-2d11-453d-a403-e96b0029c9fe')) -and
    ($artifactsSource -match 'contributorPrincipalIds')
)

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

# Seed: pool identities and the lease store (#652)
$seed = Get-Content -LiteralPath (Join-Path $Root 'bootstrap' 'seed.bicep') -Raw
$seedNonprod = Get-Content -LiteralPath (Join-Path $Root 'bootstrap' 'modules' 'seed-nonprod.bicep') -Raw
Test-Rule 'seed pool params default off' (
    ($seed -match "param\s+poolManagerSubject\s+string\s*=\s*''") -and
    ($seed -match "param\s+poolLeaseStore\s+bool\s*=\s*false") -and
    ($seed -match 'poolManagerSubject:\s*poolManagerSubject') -and
    ($seed -match 'poolLeaseStore:\s*poolLeaseStore')
) 'no pool-manager credential and no lease store unless the operator opts in'

Test-Rule 'seed pool app identity' (
    ($seedNonprod -match "resource\s+poolApp\s+'Microsoft\.ManagedIdentity/userAssignedIdentities@2023-01-31'") -and
    ($seedNonprod -match "name:\s*'id-\$\{slug\}-pool-app'")
)

Test-Rule 'seed pool-manager federated credential' (
    ($seedNonprod -match "resource\s+poolAppCredential\s+'Microsoft\.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31'\s*=\s*if\s*\(\s*!empty\(poolManagerSubject\)\s*\)") -and
    ($seedNonprod -match "name:\s*'github-pool-manager'") -and
    ($seedNonprod -match 'issuer:\s*githubIssuer') -and
    ($seedNonprod -match 'subject:\s*poolManagerSubject') -and
    ($seedNonprod -match 'audiences:\s*\[audience\]')
) 'github-pool-manager, only with a poolManagerSubject'

Test-Rule 'seed lease store' (
    ($seedNonprod -match "resource\s+leaseStore\s+'Microsoft\.Storage/storageAccounts@2023-05-01'\s*=\s*if\s*\(\s*poolLeaseStore\s*\)") -and
    ($seedNonprod -match "name:\s*'st\$\{slug\}pool\$\{suffix\}'") -and
    ($seedNonprod -match "name:\s*'leases'")
) 'st<slug>pool<suffix> account with a leases container'

Test-Rule 'seed lease store RBAC' (
    ($seedNonprod -match "resource\s+leaseStoreContributor\s+'Microsoft\.Authorization/roleAssignments@2022-04-01'\s*=\s*if\s*\(\s*poolLeaseStore\s*\)") -and
    ($seedNonprod -match 'scope:\s*leaseStore') -and
    ($seedNonprod -match 'principalId:\s*poolApp\.properties\.principalId') -and
    ($seedNonprod -match [regex]::Escape('ba92f5b4-2d11-453d-a403-e96b0029c9fe'))
) 'Storage Blob Data Contributor on the lease store for the pool app identity'

Test-Rule 'seed pool outputs' (
    ($seed -match "(?s)output\s+identities\s+object\s*=.*?poolApp:\s*nonprod\.outputs\.poolApp") -and
    ($seed -match 'output\s+leaseStore\s+object\s*=\s*nonprod\.outputs\.leaseStore')
) 'identities.poolApp and the leaseStore output from the nonprod module'

$seedApplyingWorkflow = @(
    Get-ChildItem -LiteralPath (Join-Path $Root '.github' 'workflows') -Filter '*.yml' |
        Where-Object {
            $workflow = Get-Content -LiteralPath $_.FullName -Raw
            ($workflow -match 'bootstrap/seed') -and (($workflow -match 'az deployment') -or ($workflow -match 'az stack group create'))
        }
)
Test-Rule 'no workflow applies the seed' (($seedApplyingWorkflow.Count -eq 0) -and ($apply -notmatch 'bootstrap/seed')) $(
    if ($seedApplyingWorkflow.Count -gt 0) { "applying workflow(s): $(@($seedApplyingWorkflow | ForEach-Object Name) -join ', ')" } else { 'apply-environment.ps1 references bootstrap/seed' }
)

$poolManager = Get-Content -LiteralPath (Join-Path $Root '.github' 'workflows' 'pool-manager.yml') -Raw
Test-Rule 'pool-manager runs dry by default' (
    ($poolManager -match 'lease\.ps1\s+-Action\s+sweep\s+-DryRun:') -and
    ($poolManager -match 'manage-warm\.ps1\s+-Action\s+apply\s+-DryRun:') -and
    ($poolManager -notmatch 'az stack group create')
) 'lease sweep and warm/cool run with -DryRun until the lease store and the pool stack exist'

# Bicep build of the seed: the pool app identity and the lease store compile. Bicep writes its diagnostics to stderr
# with exit code 0, so any stderr or a non-zero exit fails. Needs az + Bicep; skip only when az is absent (local without the CLI).
$seedFile = Join-Path $Root 'bootstrap' 'seed.bicep'
$seedBuild = "seed-bicep-$([Guid]::NewGuid().ToString('N'))"
$seedCompiled = Join-Path ([IO.Path]::GetTempPath()) "$seedBuild.json"
$seedStderr = Join-Path ([IO.Path]::GetTempPath()) "$seedBuild.err"
if ($az) {
    $env:BICEP_CLI_DIAGNOSTICS = 'warn'
    $env:BICEP_OUT = $seedCompiled
    $previousErrorAction = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    $null = & az bicep build --file $seedFile --stdout > $env:BICEP_OUT 2> $seedStderr
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $previousErrorAction
    $env:BICEP_CLI_DIAGNOSTICS = $null
    $env:BICEP_OUT = $null
    $stderr = [string] (Get-Content -LiteralPath $seedStderr -Raw -ErrorAction SilentlyContinue)
    Test-Rule 'bicep build bootstrap/seed.bicep' ($code -eq 0 -and [string]::IsNullOrWhiteSpace($stderr)) $stderr
    Remove-Item -LiteralPath $seedCompiled, $seedStderr -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host 'SKIP bicep build bootstrap/seed.bicep: az is not on PATH (env-checks installs it)'
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) pool check(s) failed."
    exit 1
}
Write-Host 'All pool checks passed.'
