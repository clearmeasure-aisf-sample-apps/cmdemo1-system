#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Warm and cool pool slots from the schedule in system.json pool.warm.

.DESCRIPTION
    Issue #656: the pool manager runs every pool.warm.managerIntervalMinutes (5) and on dispatch. It warms more
    slots when a run has waited over pool.warm.waitToWarmMinutes (1) and cools them after
    pool.warm.idleToCoolMinutes (30) idle. All 8 slots stay defined in code; only warmth (minReplicas) changes.
    Pool-slot minReplicas / tags.warm may be ignored by Select-PoolDriftChanges when drift later what-ifs the pool stack.

.PARAMETER LoadOnly
    Define functions and return.
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [ValidateSet('decide', 'apply', '')]
    [string] $Action = '',
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

function Get-PoolDesiredWarmSlots {
    <#
    .SYNOPSIS
        Decide which slots should be warm given waiters, idle timestamps, and the schedule.
    #>
    param(
        [Parameter(Mandatory)][string[]] $SlotNames,
        [Parameter(Mandatory)]$WarmConfig,
        [datetime[]] $WaiterStartedAt = @(),
        [hashtable] $SlotIdleSince = @{},
        [string[]] $CurrentlyWarm = @(),
        [datetime] $Now = [datetime]::SpecifyKind([datetime]::UtcNow, [DateTimeKind]::Utc)
    )
    $baseline = [int] $WarmConfig.count
    $waitMinutes = [int] $WarmConfig.waitToWarmMinutes
    $idleMinutes = [int] $WarmConfig.idleToCoolMinutes
    $now = $Now.ToUniversalTime()

    $desired = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt [Math]::Min($baseline, $SlotNames.Count); $i++) {
        [void] $desired.Add($SlotNames[$i])
    }

    $extraDemand = 0
    foreach ($started in @($WaiterStartedAt)) {
        if (($now - $started.ToUniversalTime()) -ge [timespan]::FromMinutes($waitMinutes)) {
            $extraDemand++
        }
    }
    if ($extraDemand -gt 0) {
        $needed = [Math]::Min($SlotNames.Count, $baseline + $extraDemand)
        for ($i = 0; $i -lt $needed; $i++) {
            [void] $desired.Add($SlotNames[$i])
        }
    }

    # Cool non-baseline slots that have been idle long enough (and are currently warm).
    $current = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in @($CurrentlyWarm)) { [void] $current.Add($s) }

    $result = [Collections.Generic.List[string]]::new()
    $actions = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $SlotNames.Count; $i++) {
        $slot = $SlotNames[$i]
        $isBaseline = $i -lt $baseline
        $wantWarm = $desired.Contains($slot)
        if ($wantWarm -and -not $isBaseline) {
            # Extra warm slot: keep only while not idle past the cool window.
            if ($SlotIdleSince.ContainsKey($slot) -and $SlotIdleSince[$slot]) {
                $idleAt = [datetime] $SlotIdleSince[$slot]
                if (($now - $idleAt.ToUniversalTime()) -ge [timespan]::FromMinutes($idleMinutes)) {
                    $wantWarm = $false
                    $desired.Remove($slot) | Out-Null
                }
            }
        }
        if ($wantWarm) {
            $result.Add($slot)
            if (-not $current.Contains($slot)) {
                $actions.Add([pscustomobject]@{ Slot = $slot; Action = 'warm'; MinReplicas = 1 })
            }
        }
        else {
            if ($current.Contains($slot)) {
                $actions.Add([pscustomobject]@{ Slot = $slot; Action = 'cool'; MinReplicas = 0 })
            }
        }
    }

    [pscustomobject]@{
        DesiredWarm = @($result)
        Actions     = @($actions)
        Baseline    = $baseline
    }
}

function Get-PoolMinReplicasForSlot {
    param(
        [Parameter(Mandatory)][string] $Slot,
        [string[]] $DesiredWarm = @()
    )
    if (@($DesiredWarm) -contains $Slot) { return 1 }
    return 0
}

if ($LoadOnly) { return }

$system = Get-PoolSystem -RepositoryRoot $Root
$pool = $system.pool
$warm = Get-PoolWarmConfig -Pool $pool
$slotNames = @(Get-PoolSlotNames -Slots ([int] $pool.slots))

switch ($Action) {
    'decide' {
        # Default decide with baseline only (no live waiter/idle signals in this mode).
        $decision = Get-PoolDesiredWarmSlots -SlotNames $slotNames -WarmConfig $warm -CurrentlyWarm ($slotNames | Select-Object -First $warm.count) -Now $Now
        Write-Host "Baseline warm=$($warm.count); interval=$($warm.managerIntervalMinutes)m waitToWarm=$($warm.waitToWarmMinutes)m idleToCool=$($warm.idleToCoolMinutes)m"
        Write-Host "Desired warm: $($decision.DesiredWarm -join ', ')"
        exit 0
    }
    'apply' {
        $decision = Get-PoolDesiredWarmSlots -SlotNames $slotNames -WarmConfig $warm -CurrentlyWarm ($slotNames | Select-Object -First $warm.count) -Now $Now
        foreach ($a in $decision.Actions) {
            Write-Host "$($a.Action) $($a.Slot) minReplicas=$($a.MinReplicas)"
        }
        if ($DryRun -or $decision.Actions.Count -eq 0) {
            Write-Host 'DRY-RUN or no scale changes: Azure Container Apps not updated.'
            exit 0
        }
        throw "Live warm/cool requires stack-$(([string] $system.system.slug))-pool (issue #653, Jeffrey's yes). Use -DryRun until then."
    }
    default {
        throw "Action is required: decide | apply"
    }
}
