#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Shared pool-manager helpers: read system.json pool config, slot names, and drift-exclusion rules.

.DESCRIPTION
    Dot-sourced by the lease, reset, template-refresh and warm/cool scripts. With -LoadOnly, defines the
    functions and returns (scripts/test-pool-manager.ps1). Never creates Azure resources.

.PARAMETER Root
    Repository root (parent of scripts/).
.PARAMETER LoadOnly
    Define functions and return.
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [switch] $LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

if (-not $Root) {
    $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'system.json'))) {
        $Root = Split-Path -Parent $PSScriptRoot
    }
}

function Get-PoolSystem {
    param([string] $RepositoryRoot = $Root)
    $path = Join-Path $RepositoryRoot 'system.json'
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
}

function Get-PoolWarmConfig {
    <#
    .SYNOPSIS
        Resolve pool.warm: shadow baseline count plus the warm/cool schedule (issue #656).
    #>
    param(
        [Collections.IDictionary] $Pool
    )
    $defaults = [ordered]@{
        count                   = 2
        managerIntervalMinutes  = 5
        waitToWarmMinutes       = 1
        idleToCoolMinutes       = 30
    }
    if (-not $Pool -or -not $Pool.ContainsKey('warm')) {
        return [pscustomobject]$defaults
    }
    $warm = $Pool.warm
    if ($warm -is [int] -or $warm -is [long]) {
        $defaults.count = [int] $warm
        return [pscustomobject]$defaults
    }
    if ($warm -isnot [Collections.IDictionary]) {
        throw "pool.warm must be an object with count and schedule, or an integer count."
    }
    foreach ($key in @('count', 'managerIntervalMinutes', 'waitToWarmMinutes', 'idleToCoolMinutes')) {
        if ($warm.ContainsKey($key)) {
            $defaults[$key] = [int] $warm[$key]
        }
    }
    return [pscustomobject]$defaults
}

function Get-PoolLeaseConfig {
    <#
    .SYNOPSIS
        Resolve pool.lease: max lease age, hold-env ceiling, and wait-for-slot notify threshold.
    #>
    param(
        [Collections.IDictionary] $Pool
    )
    $defaults = [ordered]@{
        maxMinutes         = 30
        holdEnvMaxHours    = 24
        waitNotifyMinutes  = 5
    }
    if (-not $Pool -or -not $Pool.ContainsKey('lease')) {
        return [pscustomobject]$defaults
    }
    $lease = $Pool.lease
    if ($lease -isnot [Collections.IDictionary]) {
        throw "pool.lease must be an object."
    }
    foreach ($key in @('maxMinutes', 'holdEnvMaxHours', 'waitNotifyMinutes')) {
        if ($lease.ContainsKey($key)) {
            $defaults[$key] = [int] $lease[$key]
        }
    }
    return [pscustomobject]$defaults
}

function Get-PoolSlotNames {
    param(
        [int] $Slots = 8
    )
    1..$Slots | ForEach-Object { "pool-$_" }
}

function Get-PoolLeaseBlobName {
    <#
    .SYNOPSIS
        Blob name for a slot lease: slot-N (issue #656), mapped from pool-N.
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Slot
    )
    if ($Slot -match '^pool-(\d+)$') {
        return "slot-$($Matches[1])"
    }
    if ($Slot -match '^slot-(\d+)$') {
        return $Slot
    }
    throw "Slot name must be pool-N or slot-N, got '$Slot'."
}

function Get-PoolSlotFromLeaseBlob {
    param(
        [Parameter(Mandatory)]
        [string] $BlobName
    )
    if ($BlobName -match '^slot-(\d+)$') {
        return "pool-$($Matches[1])"
    }
    throw "Lease blob name must be slot-N, got '$BlobName'."
}

function Test-IsPoolScaleDriftProperty {
    <#
    .SYNOPSIS
        True when a what-if property path is only pool scale (minReplicas / warm tag), so drift must ignore it.

    .DESCRIPTION
        The pool manager changes warmth at runtime without re-applying the stack (same idea as ui-auto-promote
        acting at runtime). Declared desired state still has all 8 slots; only warmth changes. Drift of those
        scale fields is expected and must not fail the nightly check.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $PropertyPath
    )
    if ([string]::IsNullOrWhiteSpace($PropertyPath)) { return $false }
    $path = $PropertyPath.TrimStart('.')
    # ARM/Bicep what-if paths for Container Apps scale and the warm tag the manager flips with scale.
    if ($path -match '(?i)(^|\.)properties\.template\.scale(\.|$)') { return $true }
    if ($path -match '(?i)(^|\.)properties\.template\.scale\.minReplicas$') { return $true }
    if ($path -match '(?i)(^|\.)tags\.warm$') { return $true }
    if ($path -match '(?i)minReplicas') { return $true }
    return $false
}

function Select-PoolDriftChanges {
    <#
    .SYNOPSIS
        Drop what-if changes that are only pool scale, keeping every other difference.
    #>
    param(
        [object[]] $Change = @()
    )
    foreach ($one in @($Change)) {
        if (-not $one) { continue }
        $properties = @($one.properties)
        if ($properties.Count -eq 0) {
            # Create/Delete/whole-resource changes are never "scale only".
            if ($one.changeType -ne 'Modify') {
                $one
            }
            continue
        }
        $kept = @($properties | Where-Object { -not (Test-IsPoolScaleDriftProperty -PropertyPath ([string] $_)) })
        if ($kept.Count -gt 0) {
            @{
                changeType = $one.changeType
                resourceId = $one.resourceId
                properties = $kept
            }
        }
    }
}

function Get-PoolMigrationJournalFingerprint {
    <#
    .SYNOPSIS
        Stable fingerprint of a migration journal (ordered script names or ids).
    #>
    param(
        [string[]] $Entries = @()
    )
    $normalized = @(
        $Entries |
            ForEach-Object { ([string] $_).Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    if ($normalized.Count -eq 0) { return '' }
    return ($normalized -join '|')
}

function Get-PoolGitHubRunTerminalStatuses {
    # GitHub Actions conclusions that mean the run has ended (sweeper keys on status, not only age).
    @('success', 'failure', 'cancelled', 'skipped', 'timed_out', 'action_required', 'neutral', 'stale', 'startup_failure')
}

function Test-GitHubRunHasEnded {
    param(
        [string] $Status = '',
        [string] $Conclusion = ''
    )
    $status = ([string] $Status).ToLowerInvariant()
    if ($status -in @('completed', 'cancelled')) { return $true }
    $conclusion = ([string] $Conclusion).ToLowerInvariant()
    if ($conclusion -and $conclusion -ne 'null' -and (Get-PoolGitHubRunTerminalStatuses) -contains $conclusion) {
        return $true
    }
    return $false
}

if ($LoadOnly) { return }
