#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Commits the release's version of one deployable to environments/<env>/versions.json on main.

.DESCRIPTION
    Step "Pin version" of the Octopus project <slug>-<deployable>; octopus/projects.tf inlines this file. This is the
    GitOps write: desired state changes first, then the steps after it make the environment match. The commit goes
    straight to main through the contents API as the system's own GitHub App (a token made for this step, for this
    repository and its contents only: scripts/github-token.ps1), or with the stored GitHub.Token of a system that has
    no App. The main ruleset lets that identity bypass pull requests (the App by name; the stored token's account as
    an owner of the organization); the system workflow ignores pushes that change only versions.json, so a pin never
    starts an environment release. A pin that is already in place is not committed again (a redeployment).
    Output variables Pinned and PreviousVersion let step "Revert pin" put the previous version back when a later step
    fails, so main never keeps a version that did not deploy.
#>
# No param block: octopus/projects.tf joins scripts/github-token.ps1 and this file into one script, this one second.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$repository = [string] $OctopusParameters['System.Repository']
$deployable = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$deployment = [string] $OctopusParameters['Octopus.Deployment.Id']
$path = "environments/$environmentName/versions.json"
$uri = "https://api.github.com/repos/$repository/contents/$path"
# As the system's own GitHub App, with a token made now for this repository, or with the stored token of a system
# that has no App: Get-SystemGitHubToken of scripts/github-token.ps1, which octopus/projects.tf joins with this
# script into the step's one script body.
$headers = @{
    Authorization          = "Bearer $(Get-SystemGitHubToken -Permission @{ contents = 'write' })"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

function Get-HttpStatus {
    # The status GitHub answered with, or 0 when it did not answer at all.
    param([Parameter(Mandatory)] [Management.Automation.ErrorRecord] $ErrorRecord)
    $response = if ($ErrorRecord.Exception.PSObject.Properties['Response']) { $ErrorRecord.Exception.Response } else { $null }
    if ($response) { return [int] $response.StatusCode }
    return 0
}

function Invoke-GitHub {
    # One call of the contents API, sent again only for a failure that is known to pass (principle 004): no answer,
    # or 408, 429, 500, 502, 503 or 504. Four attempts, 5, 10 and 15 seconds apart; each retry is one line of
    # information, not a warning. Any other failure, and the fourth of these, is thrown as it came. The write may be
    # sent again too: it names the version of the file it replaces (sha), so a write whose answer was lost and that is
    # sent a second time is refused (409), and the loop below reads the file again (cmdemo1-fworker, 2026-10-30: one
    # 500 on the write failed a deployment that nothing retried).
    param([Parameter(Mandatory)] [hashtable] $Call, [Parameter(Mandatory)] [string] $What)
    for ($try = 1; $true; $try++) {
        try { return Invoke-RestMethod @Call }
        catch {
            $status = Get-HttpStatus -ErrorRecord $_
            if ($try -ge 4 -or $status -notin 0, 408, 429, 500, 502, 503, 504) { throw }
            Write-Host "GitHub did not $What ($(if ($status) { "HTTP $status" } else { 'no answer' }), attempt $try of 4); asking again in $(5 * $try) seconds."
            Start-Sleep -Seconds (5 * $try)
        }
    }
}

for ($attempt = 1; $attempt -le 4; $attempt++) {
    $sha = $null
    $versions = @{}
    try {
        $file = Invoke-GitHub -Call @{ Uri = "${uri}?ref=main"; Headers = $headers } -What "read $path"
        $sha = $file.sha
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
        $versions = $text | ConvertFrom-Json -AsHashtable
    }
    catch {
        if ((Get-HttpStatus -ErrorRecord $_) -ne 404) {
            throw
        }
    }

    if ($versions.ContainsKey($deployable) -and [string] $versions[$deployable] -eq $version) {
        Set-OctopusVariable -name 'Pinned' -value 'False'
        Write-Highlight "$path already pins $deployable ${version}: nothing to commit."
        return
    }
    $previous = if ($versions.ContainsKey($deployable)) { [string] $versions[$deployable] } else { '' }

    $versions[$deployable] = $version
    $ordered = [ordered] @{}
    foreach ($key in ($versions.Keys | Sort-Object)) {
        $ordered[$key] = $versions[$key]
    }
    $content = ($ordered | ConvertTo-Json -Depth 5) + "`n"
    $body = @{
        message = "Pin $deployable $version in $environmentName ($deployment)"
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        branch  = 'main'
    }
    if ($sha) {
        $body.sha = $sha
    }

    try {
        $commit = Invoke-GitHub -Call @{ Uri = $uri; Method = 'Put'; Headers = $headers; Body = ($body | ConvertTo-Json); ContentType = 'application/json' } -What "write $path"
        Set-OctopusVariable -name 'Pinned' -value 'True'
        Set-OctopusVariable -name 'PreviousVersion' -value $previous
        Write-Highlight "Pinned $deployable $version in ${environmentName}: $($commit.commit.html_url)"
        return
    }
    catch {
        # 409: another pin changed the file since it was read; read it again.
        if ((Get-HttpStatus -ErrorRecord $_) -eq 409 -and $attempt -lt 4) {
            Write-Warning "versions.json changed while pinning (attempt $attempt of 4); reading it again."
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }
        throw
    }
}

# Said as an exit code: Octopus ends a step with the exit code of the last program its script ran, which may be one
# whose refusal was expected and handled (a dormant system's resources that are gone: cmdemo2, 2026-10-15).
exit 0
