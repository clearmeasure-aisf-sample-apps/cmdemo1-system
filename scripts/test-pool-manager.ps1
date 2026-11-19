#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the pool manager decision rules (lease, sweep, reset, warm/cool, drift exclusion). No Azure.

.DESCRIPTION
    Runs in job env-checks of .github/workflows/env-checks.yml on every pull request, and locally:

      pwsh -NoProfile -File scripts/test-pool-manager.ps1

    Proves issue #656 as code only. Exit 1 when any check fails.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-pool-manager.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'pool' 'common.ps1') -Root $Root -LoadOnly
. (Join-Path $PSScriptRoot 'pool' 'lease.ps1') -Root $Root -LoadOnly
. (Join-Path $PSScriptRoot 'pool' 'reset.ps1') -Root $Root -LoadOnly
. (Join-Path $PSScriptRoot 'pool' 'refresh-template.ps1') -Root $Root -LoadOnly
. (Join-Path $PSScriptRoot 'pool' 'manage-warm.ps1') -Root $Root -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $a = ConvertTo-Json -InputObject @($Actual | ForEach-Object { $_ }) -Compress -Depth 8
    $e = ConvertTo-Json -InputObject @($Expected | ForEach-Object { $_ }) -Compress -Depth 8
    if ($a -ceq $e) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $e, got $a"; $script:failures++ }
}
function Test-True([string] $Name, [bool] $Condition) {
    if ($Condition) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL $Name"; $script:failures++ }
}

$now = [datetime]::Parse('2026-11-14T18:00:00Z').ToUniversalTime()
$system = Get-PoolSystem -RepositoryRoot $Root
$pool = $system.pool
$warm = Get-PoolWarmConfig -Pool $pool
$leaseCfg = Get-PoolLeaseConfig -Pool $pool

# --- system.json schedule (pool.warm object + pool.lease) ---
Test-True 'pool.warm is an object with schedule' ($pool.warm -is [Collections.IDictionary])
Test-Case 'pool.warm.count shadow baseline' $warm.count 2
Test-Case 'pool.warm.managerIntervalMinutes' $warm.managerIntervalMinutes 5
Test-Case 'pool.warm.waitToWarmMinutes' $warm.waitToWarmMinutes 1
Test-Case 'pool.warm.idleToCoolMinutes' $warm.idleToCoolMinutes 30
Test-Case 'pool.lease.maxMinutes' $leaseCfg.maxMinutes 30
Test-Case 'pool.lease.holdEnvMaxHours' $leaseCfg.holdEnvMaxHours 24
Test-Case 'pool.lease.waitNotifyMinutes' $leaseCfg.waitNotifyMinutes 5

# Integer warm still resolves (legacy / Bicep default union)
$legacy = Get-PoolWarmConfig -Pool @{ warm = 2 }
Test-Case 'legacy pool.warm int count' $legacy.count 2
Test-Case 'legacy pool.warm keeps schedule defaults' $legacy.managerIntervalMinutes 5

# --- lease blob naming ---
Test-Case 'lease blob for pool-3' (Get-PoolLeaseBlobName -Slot 'pool-3') 'slot-3'
Test-Case 'slot from lease blob' (Get-PoolSlotFromLeaseBlob -BlobName 'slot-7') 'pool-7'
Test-Case 'slot names 8' (@(Get-PoolSlotNames -Slots 8) -join ',') 'pool-1,pool-2,pool-3,pool-4,pool-5,pool-6,pool-7,pool-8'

# --- lease acquire preference ---
Test-Case 'lease prefers first free warm slot' (
    Select-PoolLeaseToAcquire -SlotNames @(Get-PoolSlotNames) -LeasedSlots @('pool-1') -PreferWarmCount 2
) 'pool-2'
Test-Case 'lease takes cool when warm full' (
    Select-PoolLeaseToAcquire -SlotNames @(Get-PoolSlotNames) -LeasedSlots @('pool-1', 'pool-2') -PreferWarmCount 2
) 'pool-3'
Test-Case 'pool empty returns null' (
    Select-PoolLeaseToAcquire -SlotNames @('pool-1', 'pool-2') -LeasedSlots @('pool-1', 'pool-2') -PreferWarmCount 2
) $null
Test-Case 'waiting message' (Get-PoolWaitingForSlotMessage) 'waiting for a slot'
Test-True 'wait notify after 5 minutes' (
    Test-PoolWaitShouldNotify -WaitStartedAt $now.AddMinutes(-6) -Now $now -WaitNotifyMinutes 5
)
Test-True 'wait notify not before 5 minutes' (
    -not (Test-PoolWaitShouldNotify -WaitStartedAt $now.AddMinutes(-4) -Now $now -WaitNotifyMinutes 5)
)

# --- sweeper: run status first, then age / hold-env ---
$lease30 = New-PoolLeaseRecord -Slot 'pool-1' -PrNumber 1 -CommitSha 'abc' -RunId '99' -AcquiredAt $now.AddMinutes(-31)
$lease10 = New-PoolLeaseRecord -Slot 'pool-2' -PrNumber 2 -CommitSha 'def' -RunId '100' -AcquiredAt $now.AddMinutes(-10)
$leaseHold = New-PoolLeaseRecord -Slot 'pool-3' -PrNumber 3 -CommitSha 'ghi' -RunId '101' -HoldEnv $true -AcquiredAt $now.AddHours(-2)
$leaseHoldOld = New-PoolLeaseRecord -Slot 'pool-4' -PrNumber 4 -CommitSha 'jkl' -RunId '102' -HoldEnv $true -AcquiredAt $now.AddHours(-25)

Test-True 'run ended status completed breaks lease' (
    (Test-PoolLeaseShouldBreak -Lease $lease10 -RunStatus 'completed' -RunConclusion 'success' -Now $now).Break
)
Test-True 'run ended conclusion failure breaks lease' (
    (Test-PoolLeaseShouldBreak -Lease $lease10 -RunStatus 'in_progress' -RunConclusion 'failure' -Now $now).Break
)
Test-True 'cancelled run breaks lease' (
    (Test-PoolLeaseShouldBreak -Lease $lease10 -RunStatus 'completed' -RunConclusion 'cancelled' -Now $now).Break
)
Test-True 'active run under 30m keeps lease' (
    -not (Test-PoolLeaseShouldBreak -Lease $lease10 -RunStatus 'in_progress' -RunConclusion '' -Now $now).Break
)
Test-True 'active run over 30m without hold-env breaks' (
    (Test-PoolLeaseShouldBreak -Lease $lease30 -RunStatus 'in_progress' -RunConclusion '' -Now $now -MaxMinutes 30).Break
)
# hold-env keeps the slot after the run ends (click-around), up to 24 hours
Test-True 'hold-env keeps lease after run ended under 24h' (
    -not (Test-PoolLeaseShouldBreak -Lease $leaseHold -RunStatus 'completed' -RunConclusion 'success' -Now $now -HoldEnvMaxHours 24).Break
)
Test-True 'hold-env active under 24h kept past 30m' (
    -not (Test-PoolLeaseShouldBreak -Lease $leaseHold -RunStatus 'in_progress' -RunConclusion '' -Now $now -MaxMinutes 30 -HoldEnvMaxHours 24).Break
)
Test-True 'hold-env over 24h breaks even if run still listed' (
    (Test-PoolLeaseShouldBreak -Lease $leaseHoldOld -RunStatus 'in_progress' -RunConclusion '' -Now $now -HoldEnvMaxHours 24).Break
)
Test-True 'hold-env over 24h breaks after run ended' (
    (Test-PoolLeaseShouldBreak -Lease $leaseHoldOld -RunStatus 'completed' -RunConclusion 'success' -Now $now -HoldEnvMaxHours 24).Break
)
Test-True 'GitHub run ended helper' (Test-GitHubRunHasEnded -Status 'completed' -Conclusion 'success')
Test-True 'GitHub run in_progress not ended' (-not (Test-GitHubRunHasEnded -Status 'in_progress' -Conclusion ''))

# --- reset / journal ---
Test-True 'matching journal keeps slot' (
    -not (Test-PoolSlotNeedsReset -SlotJournal @('001.sql', '002.sql') -IncomingMigrations @('002.sql', '001.sql')).Reset
)
Test-True 'differing journal resets' (
    (Test-PoolSlotNeedsReset -SlotJournal @('001.sql') -IncomingMigrations @('001.sql', '002.sql')).Reset
)
Test-True 'slot ahead of PR still resets' (
    (Test-PoolSlotNeedsReset -SlotJournal @('001.sql', '002.sql') -IncomingMigrations @('001.sql')).Reset
)
Test-True 'nightly forces reset' (
    (Test-PoolSlotNeedsReset -SlotJournal @('001.sql') -IncomingMigrations @('001.sql') -Nightly).Reset
)
Test-True 'reset budget 4m ok' (Test-PoolResetWithinBudget -Elapsed ([timespan]::FromMinutes(4)) -TimeoutMinutes 5)
Test-True 'reset budget 6m over' (-not (Test-PoolResetWithinBudget -Elapsed ([timespan]::FromMinutes(6)) -TimeoutMinutes 5))
$plan = Get-PoolResetCopyPlan -Slug 'cmdemo1' -Slot 'pool-2' -SqlServerName 'sql-cmdemo1-pool' -ResourceGroup 'rg-cmdemo1-nonprod'
Test-Case 'reset plan slot database' $plan.slotDatabase 'sqldb-cmdemo1-pool-2'
Test-Case 'reset plan template' $plan.templateDatabase 'sqldb-cmdemo1-pool-template'

# --- template refresh ---
Test-True 'template refresh when journals differ' (
    (Test-PoolTemplateRefreshNeeded -TemplateJournal @('001.sql') -IncomingMigrations @('001.sql', '002.sql')).Refresh
)
Test-True 'template refresh skip when match' (
    -not (Test-PoolTemplateRefreshNeeded -TemplateJournal @('001.sql') -IncomingMigrations @('001.sql')).Refresh
)
$tplan = Get-PoolTemplateRefreshPlan -Slug 'cmdemo1' -MigrationScripts @('001.sql') -SeedReferenceData $true
Test-Case 'template name' $tplan.templateDatabase 'sqldb-cmdemo1-pool-template'
Test-True 'template plan seeds' ($tplan.seedReferenceData -eq $true)
Test-True 'template plan has migrate step' ($tplan.steps[0] -match 'Migrate')

# --- warm / cool schedule ---
$slots = @(Get-PoolSlotNames -Slots 8)
$baselineWarm = @('pool-1', 'pool-2')
$idle = @{ 'pool-3' = $now.AddMinutes(-31) }
$decision = Get-PoolDesiredWarmSlots -SlotNames $slots -WarmConfig $warm -WaiterStartedAt @($now.AddMinutes(-2)) `
    -SlotIdleSince @{} -CurrentlyWarm $baselineWarm -Now $now
Test-True 'waiter over 1m warms an extra slot' ($decision.DesiredWarm -contains 'pool-3')
Test-Case 'warm action for pool-3' (@($decision.Actions | Where-Object { $_.Slot -eq 'pool-3' -and $_.Action -eq 'warm' }).Count) 1

$cooled = Get-PoolDesiredWarmSlots -SlotNames $slots -WarmConfig $warm -WaiterStartedAt @() `
    -SlotIdleSince $idle -CurrentlyWarm @('pool-1', 'pool-2', 'pool-3') -Now $now
Test-True 'idle extra slot cools after 30m' ($cooled.DesiredWarm -notcontains 'pool-3')
Test-True 'baseline warm stays' (($cooled.DesiredWarm -contains 'pool-1') -and ($cooled.DesiredWarm -contains 'pool-2'))
Test-Case 'cool action for pool-3' (@($cooled.Actions | Where-Object { $_.Slot -eq 'pool-3' -and $_.Action -eq 'cool' }).Count) 1

Test-Case 'minReplicas warm' (Get-PoolMinReplicasForSlot -Slot 'pool-1' -DesiredWarm @('pool-1', 'pool-2')) 1
Test-Case 'minReplicas cool' (Get-PoolMinReplicasForSlot -Slot 'pool-8' -DesiredWarm @('pool-1', 'pool-2')) 0

# --- drift exclusion (pool-slot minReplicas + tags.warm only; not wired into nightly drift yet) ---
Test-True 'minReplicas path is scale drift' (Test-IsPoolScaleDriftProperty -PropertyPath 'properties.template.scale.minReplicas')
Test-True 'scale.rules is NOT scale drift' (-not (Test-IsPoolScaleDriftProperty -PropertyPath 'properties.template.scale.rules'))
Test-True 'scale.maxReplicas is NOT scale drift' (-not (Test-IsPoolScaleDriftProperty -PropertyPath 'properties.template.scale.maxReplicas'))
Test-True 'warm tag is scale drift' (Test-IsPoolScaleDriftProperty -PropertyPath 'tags.warm')
Test-True 'cpu change is not scale drift' (-not (Test-IsPoolScaleDriftProperty -PropertyPath 'properties.template.containers[0].resources.cpu'))
Test-True 'empty path is not scale drift' (-not (Test-IsPoolScaleDriftProperty -PropertyPath ''))
Test-True 'bare minReplicas substring is not scale drift' (-not (Test-IsPoolScaleDriftProperty -PropertyPath 'foo.minReplicas.bar'))
Test-True 'pool slot app id matches' (Test-IsPoolSlotContainerApp -ResourceId '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-pool-3')
Test-True 'tdd-ui is not a pool slot' (-not (Test-IsPoolSlotContainerApp -ResourceId '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-tdd-ui'))
Test-True 'prod-ui is not a pool slot' (-not (Test-IsPoolSlotContainerApp -ResourceId '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-prod-ui'))

$filtered = @(Select-PoolDriftChanges -Change @(
        @{ changeType = 'Modify'; resourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-pool-3'; properties = @('properties.template.scale.minReplicas', 'tags.warm') }
        @{ changeType = 'Modify'; resourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-pool-3'; properties = @('properties.template.scale.minReplicas', 'properties.template.containers[0].image') }
        @{ changeType = 'Modify'; resourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-pool-3'; properties = @('properties.template.scale.rules', 'properties.template.scale.maxReplicas') }
        @{ changeType = 'Modify'; resourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-tdd-ui'; properties = @('properties.template.scale.minReplicas') }
        @{ changeType = 'Modify'; resourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-cmdemo1-prod-ui'; properties = @('properties.template.scale.rules') }
        @{ changeType = 'Create'; resourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.App/containerApps/ca-new'; properties = @() }
    ))
Test-Case 'pool scale-only modify dropped' (@($filtered | Where-Object { $_.resourceId -match 'ca-cmdemo1-pool-3' -and (@($_.properties) -contains 'properties.template.scale.minReplicas' -or @($_.properties) -contains 'tags.warm') }).Count) 0
Test-True 'pool mixed modify keeps image, drops minReplicas' (
    (
        @($filtered | Where-Object {
                $_.resourceId -match 'ca-cmdemo1-pool-3' -and
                @($_.properties) -contains 'properties.template.containers[0].image' -and
                @($_.properties) -notcontains 'properties.template.scale.minReplicas'
            }).Count -eq 1
    )
)
Test-True 'pool slot scale.rules and maxReplicas are kept' (
    (
        @($filtered | Where-Object {
                $_.resourceId -match 'ca-cmdemo1-pool-3' -and
                @($_.properties) -contains 'properties.template.scale.rules' -and
                @($_.properties) -contains 'properties.template.scale.maxReplicas'
            }).Count -eq 1
    )
)
Test-True 'tdd-ui minReplicas is NOT dropped' (
    @($filtered | Where-Object { $_.resourceId -match 'ca-cmdemo1-tdd-ui' -and @($_.properties) -contains 'properties.template.scale.minReplicas' }).Count -eq 1
)
Test-True 'prod-ui scale.rules is NOT dropped' (
    @($filtered | Where-Object { $_.resourceId -match 'ca-cmdemo1-prod-ui' -and @($_.properties) -contains 'properties.template.scale.rules' }).Count -eq 1
)
Test-True 'create is never dropped as scale' (
    @($filtered | Where-Object { $_.changeType -eq 'Create' }).Count -eq 1
)

# --- scripts and workflow wiring exist; no live apply ---
foreach ($name in @('common.ps1', 'lease.ps1', 'reset.ps1', 'refresh-template.ps1', 'manage-warm.ps1')) {
    Test-True "scripts/pool/$name exists" (Test-Path -LiteralPath (Join-Path $Root 'scripts' 'pool' $name))
}
$managerWf = Join-Path $Root '.github' 'workflows' 'pool-manager.yml'
$resetWf = Join-Path $Root '.github' 'workflows' 'pool-reset.yml'
$templateWf = Join-Path $Root '.github' 'workflows' 'pool-template-refresh.yml'
Test-True 'pool-manager.yml exists' (Test-Path -LiteralPath $managerWf)
Test-True 'pool-reset.yml exists' (Test-Path -LiteralPath $resetWf)
Test-True 'pool-template-refresh.yml exists' (Test-Path -LiteralPath $templateWf)

$managerText = Get-Content -LiteralPath $managerWf -Raw
Test-True 'pool-manager schedule every 5 minutes' ($managerText -match 'cron:.*"\d+/\d+ \* \* \* \*"' -or $managerText -match 'schedule:')
Test-True 'pool-manager runs sweeper dry by default until store exists' ($managerText -match 'DryRun' -or $managerText -match 'dry')
Test-True 'pool-manager does not az stack create' ($managerText -notmatch 'az stack group create')

$envChecks = Get-Content -LiteralPath (Join-Path $Root '.github' 'workflows' 'env-checks.yml') -Raw
Test-True 'env-checks runs test-pool-manager.ps1' ($envChecks -match 'test-pool-manager\.ps1')

$drift = Get-Content -LiteralPath (Join-Path $Root '.github' 'workflows' 'drift.yml') -Raw
Test-True 'drift.yml notes pool scale exclusion' ($drift -match 'pool scale' -or $drift -match 'minReplicas' -or $drift -match 'pool-manager')

# Dry-run scripts exit 0 without Azure (nested pwsh so their exit does not end this test run)
function Invoke-PoolScriptDryRun([string] $RelativeScript, [string[]] $ScriptArgs) {
    $scriptPath = (Join-Path $Root $RelativeScript).Replace('''', '''''')
    $argList = @('-NoProfile', '-File', $scriptPath) + $ScriptArgs
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    & pwsh @argList 2>&1 | Out-Host
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $previous
    return $code
}
Test-True 'lease sweep DryRun exits 0' ((Invoke-PoolScriptDryRun 'scripts/pool/lease.ps1' @('-Root', $Root, '-Action', 'sweep', '-DryRun')) -eq 0)
Test-True 'manage-warm decide exits 0' ((Invoke-PoolScriptDryRun 'scripts/pool/manage-warm.ps1' @('-Root', $Root, '-Action', 'decide')) -eq 0)
Test-True 'reset-all DryRun exits 0' ((Invoke-PoolScriptDryRun 'scripts/pool/reset.ps1' @('-Root', $Root, '-Action', 'reset-all', '-DryRun')) -eq 0)
Test-True 'refresh-template DryRun exits 0' ((Invoke-PoolScriptDryRun 'scripts/pool/refresh-template.ps1' @('-Root', $Root, '-Action', 'refresh', '-DryRun')) -eq 0)

if ($failures -gt 0) {
    Write-Host "$failures pool-manager check(s) failed."
    exit 1
}
Write-Host 'All pool-manager checks passed.'
