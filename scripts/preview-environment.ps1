#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Previews what applying infra/ would change in each environment (what-if), for pull requests and drift checks.

.DESCRIPTION
    Runs in job preview of .github/workflows/env-checks.yml (the pull request's own files) and in
    .github/workflows/drift.yml (main), signed in as id-<slug>-plan (Reader). Writes a Markdown table per environment
    to the job summary. With -FailOnChange it exits 1 when any environment differs from main: that is drift.

    Versions come from the working tree's environments/<env>/versions.json. The SQL password parameter gets a
    stand-in: what-if never shows secure values, and vault secrets are left out of the drift decision for the same
    reason. An environment whose resource group does not exist yet is reported, not failed.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string[]] $Environment = @(),
    [switch] $FailOnChange
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$template = Join-Path $Root 'infra' 'main.bicep'
$summary = if ($env:GITHUB_STEP_SUMMARY) { $env:GITHUB_STEP_SUMMARY } else { Join-Path ([IO.Path]::GetTempPath()) 'preview-summary.md' }
$ignoredTypes = @('Microsoft.KeyVault/vaults/secrets')
$drifted = [Collections.Generic.List[string]]::new()

foreach ($entry in $system.environments) {
    $name = [string] $entry.name
    if ($Environment.Count -gt 0 -and $Environment -notcontains $name) {
        continue
    }
    $resourceGroup = [string] $system.azure.resourceGroups[[string] $entry.tier]
    $versionsFile = Join-Path $Root 'environments' $name 'versions.json'
    $versions = if (Test-Path -LiteralPath $versionsFile) { Get-Content -LiteralPath $versionsFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }

    $parameters = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            environmentName   = @{ value = $name }
            versions          = @{ value = $versions }
            sqlAdminPassword  = @{ value = "Preview-$([Guid]::NewGuid().ToString('N'))" }
            deployPrincipalId = @{ value = [string] $system.azure.identities.deploy[[string] $entry.tier].principalId }
        }
    }
    $parametersFile = Join-Path ([IO.Path]::GetTempPath()) "preview-$name-$([Guid]::NewGuid().ToString('N')).json"
    $parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parametersFile -Encoding utf8NoBOM

    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $raw = az deployment group what-if --resource-group $resourceGroup --template-file $template `
            --parameters "@$parametersFile" --result-format ResourceIdOnly --no-pretty-print --output json 2>&1
        $ok = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
    }
    finally {
        Remove-Item -LiteralPath $parametersFile -Force -ErrorAction SilentlyContinue
    }

    Add-Content -LiteralPath $summary -Value "### $name ($resourceGroup)`n"
    if (-not $ok) {
        $message = (@($raw) | ForEach-Object { "$_" }) -join "`n"
        Add-Content -LiteralPath $summary -Value "What-if could not run:`n`n``````text`n$message`n```````n"
        Write-Host "SKIP preview $name"
        continue
    }

    $result = (@($raw) -join "`n") | ConvertFrom-Json -AsHashtable
    $changes = @($result.changes | Where-Object { $_.changeType -notin @('NoChange', 'Ignore') })
    $relevant = @($changes | Where-Object { $type = ($_.resourceId -split '/providers/')[-1]; -not ($ignoredTypes | Where-Object { $type -like "$_/*" }) })
    if ($changes.Count -eq 0) {
        Add-Content -LiteralPath $summary -Value "No change.`n"
    }
    else {
        $rows = $changes | ForEach-Object { "| $($_.changeType) | ``$(($_.resourceId -split '/providers/')[-1])`` |" }
        Add-Content -LiteralPath $summary -Value ((@('| Change | Resource |', '|---|---|') + $rows + '') -join "`n")
    }
    if ($relevant.Count -gt 0) {
        $drifted.Add($name)
    }
    Write-Host "PASS preview $name ($($changes.Count) change(s))"
}

if ($FailOnChange -and $drifted.Count -gt 0) {
    Write-Host "FAIL drift: $($drifted -join ', ') differ from main"
    exit 1
}
