#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Lease, release, and sweep pull-request pool slots (Azure blob leases on slot-N).

.DESCRIPTION
    Issue #656: the PR workflow takes an infinite Azure blob lease on slot-N, recording the PR, commit and run.
    Release happens in an always-run step. The sweeper breaks any lease whose GitHub run has ended, and any lease
    over pool.lease.maxMinutes (30) without a hold-env label. A hold-env label keeps the slot after the run for up
    to pool.lease.holdEnvMaxHours (24) so someone can click around.

    Decision rules are pure and tested by scripts/test-pool-manager.ps1. Live Azure calls run only when -DryRun is
    off and a lease store is configured; this repository does not create the lease store (issue #652, Jeffrey's yes).

.PARAMETER Root
    Repository root.
.PARAMETER Action
    lease | release | sweep | decide-sweep (pure; no Azure).
.PARAMETER Slot
    pool-N or slot-N for lease/release.
.PARAMETER PrNumber, CommitSha, RunId, Repository, HoldEnv
    Lease metadata written into the blob.
.PARAMETER LeaseId
    Existing lease id for release.
.PARAMETER DryRun
    Decide and print; change no Azure state.
.PARAMETER LoadOnly
    Define functions and return.
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [ValidateSet('lease', 'release', 'sweep', 'decide-sweep', '')]
    [string] $Action = '',
    [string] $Slot = '',
    [int] $PrNumber = 0,
    [string] $CommitSha = '',
    [string] $RunId = '',
    [string] $Repository = '',
    [switch] $HoldEnv,
    [string] $LeaseId = '',
    [string] $StorageAccount = '',
    [string] $Container = 'leases',
    [datetime] $Now = [datetime]::SpecifyKind([datetime]::UtcNow, [DateTimeKind]::Utc),
    [switch] $DryRun,
    [switch] $LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'common.ps1') -Root $Root -LoadOnly
if (-not $Root) {
    $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function New-PoolLeaseRecord {
    param(
        [Parameter(Mandatory)][string] $Slot,
        [Parameter(Mandatory)][int] $PrNumber,
        [Parameter(Mandatory)][string] $CommitSha,
        [Parameter(Mandatory)][string] $RunId,
        [string] $Repository = '',
        [bool] $HoldEnv = $false,
        [datetime] $AcquiredAt = [datetime]::SpecifyKind([datetime]::UtcNow, [DateTimeKind]::Utc),
        [string] $LeaseId = ''
    )
    [ordered]@{
        slot       = $Slot
        blob       = (Get-PoolLeaseBlobName -Slot $Slot)
        prNumber   = $PrNumber
        commitSha  = $CommitSha
        runId      = [string] $RunId
        repository = $Repository
        holdEnv    = [bool] $HoldEnv
        acquiredAt = $AcquiredAt.ToUniversalTime().ToString('o')
        leaseId    = $LeaseId
    }
}

function Test-PoolLeaseShouldBreak {
    <#
    .SYNOPSIS
        Sweeper decision for one lease: break when the run has ended (unless hold-env), or when age exceeds the cap.
    .DESCRIPTION
        Without hold-env: break if the GitHub run has ended, or if the lease is older than MaxMinutes (30).
        With hold-env: keep the slot after the run so someone can click around, up to HoldEnvMaxHours (24).
    #>
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [string] $RunStatus = '',
        [string] $RunConclusion = '',
        [datetime] $Now = [datetime]::SpecifyKind([datetime]::UtcNow, [DateTimeKind]::Utc),
        [int] $MaxMinutes = 30,
        [int] $HoldEnvMaxHours = 24
    )
    $acquired = [datetime]::Parse([string] $Lease.acquiredAt, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    $age = $Now.ToUniversalTime() - $acquired
    $hold = [bool] $Lease.holdEnv
    if ($hold) {
        if ($age -ge [timespan]::FromHours($HoldEnvMaxHours)) {
            return [pscustomobject]@{
                Break  = $true
                Reason = "hold-env lease older than $HoldEnvMaxHours hours"
            }
        }
        return [pscustomobject]@{
            Break  = $false
            Reason = "hold-env within $HoldEnvMaxHours hours"
        }
    }
    if (Test-GitHubRunHasEnded -Status $RunStatus -Conclusion $RunConclusion) {
        return [pscustomobject]@{
            Break  = $true
            Reason = "run ended (status=$RunStatus conclusion=$RunConclusion)"
        }
    }
    if ($age -ge [timespan]::FromMinutes($MaxMinutes)) {
        return [pscustomobject]@{
            Break  = $true
            Reason = "lease older than $MaxMinutes minutes without hold-env"
        }
    }
    return [pscustomobject]@{
        Break  = $false
        Reason = "run still active and within $MaxMinutes minutes"
    }
}

function Select-PoolLeaseToAcquire {
    <#
    .SYNOPSIS
        Pick the first free slot (prefer warm indices first) for a new lease.
    #>
    param(
        [string[]] $SlotNames,
        [string[]] $LeasedSlots = @(),
        [int] $PreferWarmCount = 2
    )
    $leased = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @($LeasedSlots)) { [void] $leased.Add($s) }
    $ordered = @(
        $SlotNames | Select-Object -First ([Math]::Min($PreferWarmCount, $SlotNames.Count))
    ) + @(
        $SlotNames | Select-Object -Skip ([Math]::Min($PreferWarmCount, $SlotNames.Count))
    )
    foreach ($slot in $ordered) {
        if (-not $leased.Contains($slot)) { return $slot }
    }
    return $null
}

function Test-PoolWaitShouldNotify {
    param(
        [datetime] $WaitStartedAt,
        [datetime] $Now = [datetime]::SpecifyKind([datetime]::UtcNow, [DateTimeKind]::Utc),
        [int] $WaitNotifyMinutes = 5
    )
    ($Now.ToUniversalTime() - $WaitStartedAt.ToUniversalTime()) -ge [timespan]::FromMinutes($WaitNotifyMinutes)
}

function Get-PoolWaitingForSlotMessage {
    'waiting for a slot'
}

if ($LoadOnly) { return }

$system = Get-PoolSystem -RepositoryRoot $Root
$pool = if ($system.ContainsKey('pool')) { $system.pool } else { @{} }
$warm = Get-PoolWarmConfig -Pool $pool
$leaseCfg = Get-PoolLeaseConfig -Pool $pool
$slotNames = @(Get-PoolSlotNames -Slots ([int] $pool.slots))

switch ($Action) {
    'decide-sweep' {
        Write-Host "Pool lease sweeper decisions (dry rules). maxMinutes=$($leaseCfg.maxMinutes) holdEnvMaxHours=$($leaseCfg.holdEnvMaxHours)"
        exit 0
    }
    'lease' {
        if (-not $Slot -and -not $DryRun) {
            throw "Lease requires -Slot pool-N (or omit Slot only with -DryRun to print the selection rules)."
        }
        $record = New-PoolLeaseRecord -Slot $(if ($Slot) { $Slot } else { 'pool-1' }) -PrNumber $PrNumber -CommitSha $CommitSha `
            -RunId $RunId -Repository $Repository -HoldEnv:$HoldEnv -AcquiredAt $Now
        if ($DryRun -or -not $StorageAccount) {
            Write-Host "DRY-RUN lease $($record.blob) for PR $($record.prNumber) run $($record.runId) (infinite lease; store not written)."
            $record | ConvertTo-Json -Compress
            exit 0
        }
        throw "Live lease requires the lease store from issue #652 (Jeffrey's yes). Use -DryRun until then."
    }
    'release' {
        if (-not $Slot) { throw "Release requires -Slot pool-N." }
        $blob = Get-PoolLeaseBlobName -Slot $Slot
        if ($DryRun -or -not $StorageAccount) {
            Write-Host "DRY-RUN release $blob leaseId=$LeaseId (store not written)."
            exit 0
        }
        throw "Live release requires the lease store from issue #652 (Jeffrey's yes). Use -DryRun until then."
    }
    'sweep' {
        Write-Host "Sweep: break leases whose run ended, or age > $($leaseCfg.maxMinutes)m without hold-env (hold-env up to $($leaseCfg.holdEnvMaxHours)h)."
        if ($DryRun -or -not $StorageAccount) {
            Write-Host "DRY-RUN sweep (no Azure). PreferWarmCount=$($warm.count) slots=$($slotNames -join ',')"
            exit 0
        }
        throw "Live sweep requires the lease store from issue #652 (Jeffrey's yes). Use -DryRun until then."
    }
    default {
        throw "Action is required: lease | release | sweep | decide-sweep"
    }
}
