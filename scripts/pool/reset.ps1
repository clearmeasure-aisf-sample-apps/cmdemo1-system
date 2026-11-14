#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Reset a pool slot database from the template when the migration journal differs (or nightly).

.DESCRIPTION
    Issue #656: if the slot's migration journal differs from the next PR's migrations in either direction, copy
    the database again from sqldb-<slug>-pool-template inside the elastic pool. Otherwise keep it (tests never
    delete or reload shared data). Reset all slots every night. Target: under 5 minutes.

    Pure decision rules are tested by scripts/test-pool-manager.ps1. Live copy is not run until the pool stack
    exists (issue #653, Jeffrey's yes).

.PARAMETER LoadOnly
    Define functions and return.
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [ValidateSet('decide', 'reset', 'reset-all', '')]
    [string] $Action = '',
    [string] $Slot = '',
    [string[]] $SlotJournal = @(),
    [string[]] $IncomingMigrations = @(),
    [switch] $Nightly,
    [int] $TimeoutMinutes = 5,
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

function Test-PoolSlotNeedsReset {
    <#
    .SYNOPSIS
        True when journals differ in either direction, or when -Nightly forces a full copy.
    #>
    param(
        [string[]] $SlotJournal = @(),
        [string[]] $IncomingMigrations = @(),
        [switch] $Nightly
    )
    if ($Nightly) {
        return [pscustomobject]@{
            Reset  = $true
            Reason = 'nightly reset of all slots'
        }
    }
    $slotFp = Get-PoolMigrationJournalFingerprint -Entries $SlotJournal
    $nextFp = Get-PoolMigrationJournalFingerprint -Entries $IncomingMigrations
    if ($slotFp -ceq $nextFp) {
        return [pscustomobject]@{
            Reset  = $false
            Reason = 'migration journal matches; keep slot database'
        }
    }
    return [pscustomobject]@{
        Reset  = $true
        Reason = 'migration journal differs from incoming migrations'
    }
}

function Test-PoolResetWithinBudget {
    param(
        [timespan] $Elapsed,
        [int] $TimeoutMinutes = 5
    )
    $Elapsed -le [timespan]::FromMinutes($TimeoutMinutes)
}

function Get-PoolResetCopyPlan {
    <#
    .SYNOPSIS
        The Azure SQL copy plan for one slot (declared only; not executed here).
    #>
    param(
        [Parameter(Mandatory)][string] $Slug,
        [Parameter(Mandatory)][string] $Slot,
        [Parameter(Mandatory)][string] $SqlServerName,
        [Parameter(Mandatory)][string] $ResourceGroup
    )
    $database = "sqldb-$Slug-$Slot"
    $template = "sqldb-$Slug-pool-template"
    [ordered]@{
        resourceGroup    = $ResourceGroup
        server           = $SqlServerName
        templateDatabase = $template
        slotDatabase     = $database
        # Copy inside the elastic pool; live apply is a follow-up after Jeffrey's yes on #653.
        steps            = @(
            "az sql db delete --name $database --server $SqlServerName --resource-group $ResourceGroup --yes"
            "az sql db copy --name $template --dest-name $database --server $SqlServerName --dest-server $SqlServerName --resource-group $ResourceGroup --dest-resource-group $ResourceGroup --elastic-pool <pool>"
        )
    }
}

if ($LoadOnly) { return }

$system = Get-PoolSystem -RepositoryRoot $Root
$slug = [string] $system.system.slug

switch ($Action) {
    'decide' {
        $decision = Test-PoolSlotNeedsReset -SlotJournal $SlotJournal -IncomingMigrations $IncomingMigrations -Nightly:$Nightly
        Write-Host ("{0}: {1}" -f $(if ($decision.Reset) { 'RESET' } else { 'KEEP' }), $decision.Reason)
        if ($decision.Reset) { exit 0 }
        exit 0
    }
    'reset' {
        if (-not $Slot) { throw "reset requires -Slot pool-N." }
        $decision = Test-PoolSlotNeedsReset -SlotJournal $SlotJournal -IncomingMigrations $IncomingMigrations -Nightly:$Nightly
        if (-not $decision.Reset) {
            Write-Host "KEEP ${Slot}: $($decision.Reason)"
            exit 0
        }
        Write-Host "RESET ${Slot}: $($decision.Reason) (budget ${TimeoutMinutes}m)"
        if ($DryRun) {
            $plan = Get-PoolResetCopyPlan -Slug $slug -Slot $Slot -SqlServerName "sql-$slug-pool" -ResourceGroup ([string] $system.azure.resourceGroups.nonprod)
            $plan | ConvertTo-Json -Depth 5
            Write-Host 'DRY-RUN: no Azure SQL copy executed.'
            exit 0
        }
        throw "Live slot reset requires stack-$slug-pool (issue #653, Jeffrey's yes). Use -DryRun until then."
    }
    'reset-all' {
        $slots = @(Get-PoolSlotNames -Slots ([int] $system.pool.slots))
        Write-Host "Nightly reset of $($slots.Count) slots (budget ${TimeoutMinutes}m each)."
        if ($DryRun) {
            foreach ($s in $slots) {
                Write-Host "DRY-RUN RESET $s (nightly)"
            }
            exit 0
        }
        throw "Live nightly reset requires stack-$slug-pool (issue #653, Jeffrey's yes). Use -DryRun until then."
    }
    default {
        throw "Action is required: decide | reset | reset-all"
    }
}
