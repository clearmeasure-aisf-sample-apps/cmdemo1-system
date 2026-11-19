#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests Get-SuccessfulVersion, the deployment window behind capability CAP-037.

.DESCRIPTION
    Loads only the Get-SuccessfulVersion function out of scripts/test-capabilities.ps1 (that script has a param block
    and runs its checks at the top level, so it cannot be dot-sourced) and calls it against a fake Octopus. A
    pull-request prerelease build (2.4.387-pr.1911.aot2) is no mainline release, so it is skipped instead of thrown
    at: the versions it does return still cover the window newest first, and a redeployed older release still reads
    as a rollback (cmdemo1-system #774, which failed CAP-037 every night). No Octopus, no Azure.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-capability-rollback-window.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# Load the one function under test, not the whole capability script.
$scriptPath = Join-Path $PSScriptRoot 'test-capabilities.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref] $tokens, [ref] $errors)
if ($errors.Count -gt 0) { Write-Host "FAIL test-capabilities.ps1 does not parse: $($errors[0])"; exit 1 }
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-SuccessfulVersion' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))

# Get-SuccessfulVersion reads $space and Invoke-Octopus from the enclosing scope.
$space = 'Spaces-1'

$failures = 0
function Test-That([string] $Name, [bool] $Ok) {
    if ($Ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name"; $script:failures++ }
}

# The history: 144 deployments of 1.0.200 every 20 minutes, a rollback to 1.0.150 ten days ago that 1.0.200 was
# redeployed over an hour later, a pull-request prerelease build three days ago, a failed deployment eleven days
# ago, and a success forty days ago (outside every window).
$now = [datetime]::UtcNow
$history = [Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt 144; $i++) { $history.Add([pscustomobject]@{ Version = '1.0.200'; At = $now.AddMinutes(-20 * $i); Succeeded = $true }) }
$history.Add([pscustomobject]@{ Version = '2.4.387-pr.1911.aot2'; At = $now.AddDays(-3); Succeeded = $true })
$history.Add([pscustomobject]@{ Version = '1.0.200'; At = $now.AddDays(-10).AddHours(1); Succeeded = $true })
$history.Add([pscustomobject]@{ Version = '1.0.150'; At = $now.AddDays(-10); Succeeded = $true })
$history.Add([pscustomobject]@{ Version = '1.0.200'; At = $now.AddDays(-10).AddHours(-1); Succeeded = $true })
$history.Add([pscustomobject]@{ Version = '1.0.100'; At = $now.AddDays(-11); Succeeded = $false })
$history.Add([pscustomobject]@{ Version = '1.0.100'; At = $now.AddDays(-40); Succeeded = $true })

$sorted = @($history | Sort-Object -Property At -Descending)
$script:deployments = [Collections.Generic.List[object]]::new()
for ($n = 0; $n -lt $sorted.Count; $n++) {
    $entry = $sorted[$n]
    $script:deployments.Add([pscustomobject]@{
            Id        = "Deployments-$($n + 1)"
            ReleaseId = "Releases-$($entry.Version)"
            Created   = $entry.At.ToString('o')
            Succeeded = $entry.Succeeded
        })
}
$script:successful = @($script:deployments | Where-Object Succeeded | ForEach-Object Id)

function Invoke-Octopus([string] $Path) {
    $skip = 0
    if ($Path -match 'skip=(\d+)') { $skip = [int] $Matches[1] }
    if ($Path -match '/tasks\?') {
        return [pscustomobject]@{ Items = @($script:successful | Select-Object -Skip $skip -First 100 |
                ForEach-Object { [pscustomobject]@{ Arguments = [pscustomobject]@{ DeploymentId = $_ } } }) }
    }
    if ($Path -match '/deployments\?') {
        return [pscustomobject]@{ Items = @($script:deployments | Select-Object -Skip $skip -First 100) }
    }
    if ($Path -match '/releases/Releases-(.+)$') {
        return [pscustomobject]@{ Version = $Matches[1] }
    }
    throw "no fake Octopus answer for $Path"
}

$versions = @()
$threw = $null
try { $versions = @(Get-SuccessfulVersion 'Projects-1' 'Environments-1') } catch { $threw = $_.Exception.Message }
$name = 'Get-SuccessfulVersion answers a 30-day window without throwing'
if ($threw) { $name = "$name ($threw)" }
Test-That $name ($null -eq $threw)

$unique = @($versions | Select-Object -Unique)
Test-That 'the window holds the mainline releases newest first, the prerelease skipped' (($unique -join ',') -ceq '1.0.200,1.0.150' -and $versions.Count -eq 147)

$rolledBack = $false
for ($i = 0; $i -lt $versions.Count - 1; $i++) { if ($versions[$i] -lt $versions[$i + 1]) { $rolledBack = $true } }
Test-That 'CAP-037 still reads the redeployed older release as a rollback' $rolledBack

Test-That 'a failed and an out-of-window deployment are not in the window' (-not ($versions -contains [version] '1.0.100'))

$daily = @(Get-SuccessfulVersion 'Projects-1' 'Environments-1' 1)
Test-That 'a 1-day window stops at its start' ($daily.Count -eq 72 -and @($daily | Select-Object -Unique).Count -eq 1)

if ($failures -gt 0) { Write-Host "$failures check(s) failed."; exit 1 }
Write-Host 'All rollback-window checks passed.'
exit 0
