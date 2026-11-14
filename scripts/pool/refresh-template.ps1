#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Refresh the pool template database: migrate sqldb-<slug>-pool-template and seed reference data once.

.DESCRIPTION
    Issue #656: each merge to master migrates the template and seeds reference data once. This script is the
    system-side action (workflow_dispatch / repository_dispatch). Live Azure SQL work waits for the pool stack
    (issue #653) and is not run from env-checks.

.PARAMETER LoadOnly
    Define functions and return.
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [ValidateSet('plan', 'refresh', '')]
    [string] $Action = '',
    [string] $MigrationPackagePath = '',
    [string[]] $MigrationScripts = @(),
    [switch] $SeedReferenceData,
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

function Get-PoolTemplateRefreshPlan {
    <#
    .SYNOPSIS
        Ordered steps to refresh the template database (declared; not executed by env-checks).
    #>
    param(
        [Parameter(Mandatory)][string] $Slug,
        [string[]] $MigrationScripts = @(),
        [bool] $SeedReferenceData = $true
    )
    $template = "sqldb-$Slug-pool-template"
    $steps = [Collections.Generic.List[string]]::new()
    $steps.Add("Migrate $template with DbUp ($($MigrationScripts.Count) script(s))")
    if ($SeedReferenceData) {
        $steps.Add("Seed reference data once into $template")
    }
    [ordered]@{
        templateDatabase   = $template
        migrationCount     = @($MigrationScripts).Count
        seedReferenceData  = [bool] $SeedReferenceData
        steps              = @($steps)
    }
}

function Test-PoolTemplateRefreshNeeded {
    <#
    .SYNOPSIS
        True when the template journal is behind (or ahead of) the incoming master migrations.
    #>
    param(
        [string[]] $TemplateJournal = @(),
        [string[]] $IncomingMigrations = @()
    )
    $left = Get-PoolMigrationJournalFingerprint -Entries $TemplateJournal
    $right = Get-PoolMigrationJournalFingerprint -Entries $IncomingMigrations
    if ($left -ceq $right) {
        return [pscustomobject]@{
            Refresh = $false
            Reason  = 'template journal already matches master migrations'
        }
    }
    return [pscustomobject]@{
        Refresh = $true
        Reason  = 'template journal differs from master migrations'
    }
}

if ($LoadOnly) { return }

$system = Get-PoolSystem -RepositoryRoot $Root
$slug = [string] $system.system.slug

switch ($Action) {
    'plan' {
        $scripts = @($MigrationScripts)
        if ($MigrationPackagePath -and (Test-Path -LiteralPath $MigrationPackagePath)) {
            $scripts = @(Get-ChildItem -Path (Join-Path $MigrationPackagePath 'scripts') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        }
        $plan = Get-PoolTemplateRefreshPlan -Slug $slug -MigrationScripts $scripts -SeedReferenceData:($true)
        $plan | ConvertTo-Json -Depth 5
        exit 0
    }
    'refresh' {
        $scripts = @($MigrationScripts)
        $plan = Get-PoolTemplateRefreshPlan -Slug $slug -MigrationScripts $scripts -SeedReferenceData:(-not $PSBoundParameters.ContainsKey('SeedReferenceData') -or $SeedReferenceData)
        Write-Host "Template refresh: $($plan.templateDatabase)"
        foreach ($step in $plan.steps) { Write-Host " - $step" }
        if ($DryRun) {
            Write-Host 'DRY-RUN: no migrate/seed against Azure SQL.'
            exit 0
        }
        throw "Live template refresh requires stack-$slug-pool (issue #653, Jeffrey's yes). Use -DryRun until then."
    }
    default {
        throw "Action is required: plan | refresh"
    }
}
