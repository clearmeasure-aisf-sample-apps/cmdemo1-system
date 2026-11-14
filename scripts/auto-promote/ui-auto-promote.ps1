#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Promotes the newest release of a deployable ($Deployable: ui, dashboard, system, or another in
    $DeployableSettings) to the next environment when nothing flags it, and holds it (one GitHub issue) when something
    does. One environment step per run.

.DESCRIPTION
    Owner's decision (Jeffrey Palermo, 2026-10-14): "release candidates automatically deployed to production if there
    is nothing to flag them. don't let them stop in release queue". Deployables in $DeployableSettings (ui; dashboard
    and system by 2026-11-10, issue #560). A deployable that is not in $DeployableSettings keeps a person's sign-off
    (the script stops). AISF and fworker (deprecated) are excluded. Run by workflow ui-auto-promote, once per
    deployable in $PromoteOrder, one after the other. Below, "ui" stands for the deployable.

    Candidate (Select-Candidate): releases newest first by version (Major.Minor.Patch; an unparsable version below every
    parsable one; Assembled only between equal or unparsable versions: releases can be assembled out of order); the first whose latest deployment to the previous
    environment (tdd before uat, uat before prod) succeeded. It is the candidate when it has no deployment at all to the
    next environment (any state: a canceled one is a person's no) and is newer than the release running there; prod is
    looked at before uat. Exception (issue #688): an open release-held issue for this deployable before that environment
    whose body lists Pipeline or infra change as its only flag keeps that held release as the candidate until it is
    promoted (or no longer qualifies, including when the hold later lists another flag); a newer success in the previous
    environment does not supersede it and does not restart the 60-minute pipeline-change clock. The newest $ReleaseWindow
    releases are listed; a running release older than those is found through
    the newest deployments to that environment (issue #314). A newer release that ended otherwise in the previous environment is skipped and the run log says so.
    Nothing is promoted while any deployment or runbook run (any project) to the target environment, or any ui
    deployment to a later-than-first environment, is queued, running, cancelling or waiting at an interruption; a call that
    fails or a listing that is incomplete also stops the run (fail closed). When the only busy reason is a short-lived
    runbook in the target (e.g. Hourly health report), the same run waits and re-lists active tasks for about two to
    three minutes before giving up (issue #583); an unfinished deployment in the target still blocks at once. A
    deployment waiting only because Octopus refused this account permission to take its Sign-off (issue #569) is
    recorded as a hold and does not count as busy for other deployables.
    Recovery: a deployment this workflow created (its Comments start with "Promoted by workflow ui-auto-promote") that waits at
    its Sign-off is evaluated again; no flag: its Sign-off is answered; a flag: it stays waiting and the held issue says so.
    Permission denied on take-responsibility or submit (HTTP 401/403, or Octopus "not in any team with permissions"): hold,
    warn, continue — do not fail the workflow.

    The four flags (Get-PromotionDecision), and what makes the run wait (nothing promoted, nothing flagged):
      1 checks   Flag: a check run of the release's commit in the application repository that ended failure, cancelled,
                 timed_out, action_required, startup_failure, stale or without a conclusion, or a commit status failure or
                 error. skipped and neutral pass. Wait: a check run not completed, a status pending, no check yet, or a
                 listing that could not be read whole. The workflow ui-auto-promote's own check runs are left out: a crash
                 or an unfinished run of this promoter is not a build or test of the release. Every other workflow still
                 counts, including one whose job happens to be named promote (system, capabilities, env-checks). A check
                 run whose workflow cannot be read is counted.
      2 deployment  Flag: the deployment to the previous environment is not Success; its task log is unreadable (under 20
                 lines or without its "Task ID:" header); the log has a line at Error, Warning or Fatal level or a step
                 SuccessWithWarning (the kit's test-deployment-logs.ps1 rule, plus Fatal, which a real failed ui task
                 logs); or a health read (HealthPath of the deployable: ui /_healthcheck/detailed, dashboard /, system
                 none) since it finished was not Healthy (an answered status other than Healthy counts at once; an
                 unreachable or timed-out read is tried up to 3 more times, 20 to 30 s apart, in the same run, and is
                 recorded Unreachable, which flags, only when all four fail). Health rule: no read since the deployment
                 finished is not Healthy, at least two reads are Healthy and at least 5 minutes apart, and the later one
                 is at least 10 minutes after the deployment finished. Else wait. A ui address that is not known: wait
                 ("health address unknown").
      3 pipeline  Compared with the commit running in the next environment (/_build "commit", else the commit in the notes of
                 the release running there), a changed path (a renamed file counts both names) outside the deployable's
                 ApplicationPaths (ui: src/), or a build or project file anywhere (BuildFiles list), unless it is documentation (DocumentationPaths list:
                 docs/**, arch/**, *.md anywhere, including .github/x.md). UnflaggedFolders never flag (ui: src/Database/ and .github/private-build/, owner 2026-10-14).
                 The comparison is read from a clone of the application repository without blobs (Get-AppComparison), so
                 it has no commit or file cap: GitHub's compare answers 250 commits and 300 files at most, and the jump
                 of ui from 2.4.1120 to 2.4.2060 is 405 commits and 687 files. A comparison that is unknown or incomplete
                 (no base commit, a read failed) flags as "comparison incomplete".
      4 hold      Flag: a pull request in the commits between those two, or an issue they close or reference (#N and
                 owner/repo#N in titles, bodies and commit messages, GitHub's closing references) labelled Hold (case
                 ignored). The pull requests of the commits are read in batched GraphQL queries (Get-CommitPulls) and the
                 application repository's Hold items in one listing (Get-RepoHeld), so a large comparison costs a few
                 calls. Wait: any read of that chain failed or was cut (more than 5 pull requests on one commit, more than
                 300 items of other repositories). A #N that the application repository answers 404 for is no item there,
                 so nothing to hold. This relies on the application repository being readable (it is public; the
                 comparison read it). A 404 from another repository still waits (it may be one not readable).

    Flagged: the deployment is NOT created, so no Sign-off waits in the environment and holds it for every other
    deployable. One issue "<deployable> <version> held before <env>" (label release-held, no assignee) lists each flag with its
    evidence; it is edited only when the evidence changes. It closes when that release has a deployment in the environment
    that no longer waits for this workflow, or a newer release is the candidate or runs there already (a newer tdd
    release does not become the candidate over an open pipeline-only hold: issue #688).
    A candidate whose release notes name no commit (hand-created in Octopus, issue #621) is the same hold pattern, not a
    workflow failure: one issue "<deployable> <version> held: release notes name no commit", no promotion, step finishes green.
    Pipeline-only override (owner, 2026-10-14): when flag 3 (a known change, not "comparison incomplete") is the only flag
    and nothing waits, the release is promoted anyway once 60 minutes ($PipelineOverrideMinutes) have passed since its deployment to the
    previous environment finished AND the head commit of the application repository's default branch (master) is green:
    every check run and commit status completed success, skipped or neutral. Pending (none failed): the same run waits and
    polls the head's checks (every $MasterPendingPollSeconds s, up to $MasterPendingTimeoutSeconds s, never longer than
    the remaining job-time budget before Sign-off/health/runbook; issue #697) then decides: green continues, any failure
    holds, still pending at the timeout or when the budget is too small to wait holds. Red, or a read that failed: hold.
    Until then the held issue says when it will be promoted.
    Security-advisory exemption (owner, 2026-11-11): the same pipeline-only case skips that 60-minute wait when every path that
    triggered flag 3 comes from source PRs that only change package version numbers (project/package files and
    unused-package-baseline.json) and each such PR has a GHSA-…. id in its title or body; master must still be green, and
    health/soak and every other flag are unchanged. Diffs or PR lookup that cannot be read: fail closed (no exemption).

.PARAMETER LoadOnly
    Defines the functions and stops (for the tests).
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [string] $Deployable = 'ui',
    [string] $StatePath = '',
    [string] $RunUrl = '',
    [int] $HealthPauseSeconds = 300,
    [switch] $DryRun,
    [switch] $LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# --- Lists the owner can edit -------------------------------------------------------------------------------------
# Documentation-only paths: a change to them alone does not flag (proposed, not decided by the owner: remove a line to
# make that kind of change a flag). ** any depth, * inside one folder. *.md matches a Markdown file anywhere.
$DocumentationPaths = @('docs/**', 'arch/**', '*.md', '**/*.md')
# Build and project files that flag wherever they are, also inside the application paths (file names, or *.ext).
$BuildFiles = @('Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json', 'nuget.config',
    '*.csproj', '*.sln', '*.slnx', '*.props', '*.targets', 'Dockerfile*')
# The deployables this workflow promotes, keyed by deployable name (system.json deployables[].name). A deployable that is
# not here is not promoted automatically (the script stops). Per deployable:
#   ApplicationPaths  globs of the application repository: a change inside them is not a pipeline change, except a build
#                     or project file (BuildFiles). Every path outside them flags, unless documentation or UnflaggedFolders.
#   UnflaggedFolders  never a flag (prefixes of the repository path).
#   HealthPath        read in the previous environment since the deployment finished (unused when HealthRead is none).
#   HealthRead        overallStatus: the JSON overallStatus of the answer is the status (Healthy or not, answered at once).
#                     ready: 200 is Healthy; 503 with a JSON "ready" answer is NotReady, retried like an unreachable read
#                     (the gateway answers it while it starts) and recorded only when every attempt answered it; anything
#                     else (another status code, no answer, a timeout) is retried like an unreachable read.
#                     httpOk: an HTTP 2xx from HealthPath is Healthy; an answered other status is Unhealthy at once; no
#                     answer or a timeout is retried like an unreachable read (static sites: dashboard).
#                     none: no HTTP health read (system infra apply: the Verify environment step already ran in the
#                     previous deployment; Success and a clean task log are the gate).
#   BuildPath         where the running app names its commit (ui /_build "commit"; dashboard /build-facts.json
#                     "commit"). Empty: only the running release's notes name the base commit (system).
$DeployableSettings = @{
    # The work-order app (cmdemo1-workorders). Owner's decision 2026-10-14.
    ui        = @{
        ApplicationPaths = @('src/**')
        # src/Database/: migrations; .github/private-build/: the kit's own script, synced by the kit (owner, 2026-10-14).
        UnflaggedFolders = @('src/Database/', '.github/private-build/')
        HealthPath       = '/_healthcheck/detailed'
        HealthRead       = 'overallStatus'
        BuildPath        = '/_build'
    }
    # The health dashboard (cmdemo1-dashboard), Static Web Apps. Owner's decision 2026-11-10 (#560): same promotion
    # rules as ui. Application: the Blazor site under src/. Pipeline: the rest (.github/, scripts/, project files).
    dashboard = @{
        ApplicationPaths = @('src/**')
        UnflaggedFolders = @()
        HealthPath       = '/'
        HealthRead       = 'httpOk'
        BuildPath        = '/build-facts.json'
    }
    # The system repository itself (cmdemo1-system project): environments, infra, Octopus. Owner's decision 2026-11-10
    # (#560). Application: the GitOps tree a system release applies. Pipeline: workflow and build files under .github/
    # and at the root. No HTTP health: Verify environment already ran when the previous deployment succeeded.
    system    = @{
        ApplicationPaths = @('environments/**', 'infra/**', 'octopus/**', 'scripts/**', 'bootstrap/**', 'factory/**',
            'space-scorecard/**', 'system.json', '.gitignore')
        UnflaggedFolders = @()
        HealthPath       = ''
        HealthRead       = 'none'
        BuildPath        = ''
    }
    # AISF and fworker (deprecated) are excluded (#560): do not add them.
}
# Order the workflow runs when deployable=all (one after the other; never two promotions to one environment at once).
$PromoteOrder = @('ui', 'dashboard', 'system')
# Pipeline-only override (owner's decision, Jeffrey Palermo 2026-10-14): a release whose only flag is a pipeline or infra
# change is promoted anyway this many minutes after its deployment to the previous environment finished, when master of
# the application repository is green. Security-advisory exemption (owner, Jeffrey Palermo 2026-11-11): the same case
# skips this wait when every flag-3 path is a package-version-only dependency fix with a GHSA id in the source PR title
# or body (see Test-SecurityAdvisoryExemption); master must still be green.
$PipelineOverrideMinutes = 60
# GHSA id in a pull request title or body (GitHub Security Advisory).
$GhsaIdPattern = 'GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}'
# Build/project files whose package-version surfaces may qualify for the security-advisory exemption (Dockerfile* does not).
$SecurityAdvisoryPackageFiles = @('Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json',
    'nuget.config', '*.csproj', '*.sln', '*.slnx', '*.props', '*.targets')
# The newest releases looked at for a candidate; the release running in an environment can be older: then it is found
# through the newest deployments to that environment, at most this many (issue #314; fewer than one success among them
# leaves the running release unknown: "comparison incomplete").
$ReleaseWindow = 40
$RunningLookupDeployments = 100
$PromotionMarker = 'Promoted by workflow ui-auto-promote'
# When a short-lived runbook (e.g. Hourly health report) is the only thing busy in the target environment, wait and
# re-list active Octopus tasks this many times, this many seconds apart, before giving up for this run (#583). Cap is
# about two to three minutes total; a real deployment in the target still blocks with no wait. $RunbookBusyPause is
# replaced by the harness so tests do not really sleep.
$RunbookBusyRetrySeconds = 40
$RunbookBusyRetryLimit = 4
$RunbookBusyPause = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
# When master's head has only pending checks (none failed), wait in the same run and re-read check runs and statuses
# this often, for at most this long, before holding (issue #697). $MasterPendingPause is replaced by the harness so
# tests do not really sleep; PollSeconds, TimeoutSeconds, Deadline and GetNow are injectable for the same reason.
$MasterPendingPollSeconds = 30
$MasterPendingTimeoutSeconds = 600
$MasterPendingPause = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
# Job-time budget so the wait never risks the promote job's timeout (review of PR #698): deadline =
# AUTO_PROMOTE_JOB_STARTED_AT + JobTimeoutMinutes − reserve. Reserve is the worst-case work after the wait in one
# Promote-or-hold step (Sign-off, second health pause, runbook busy wait). The wait uses
# min($MasterPendingTimeoutSeconds, remaining); too little remaining skips the wait and holds (pending). Never
# promotes when the budget is exhausted. Job timeout stays 55 minutes.
$MasterPendingJobTimeoutMinutes = 55
$SignOffWaitSeconds = 900
$MasterPendingJobReserveSeconds = $SignOffWaitSeconds + $HealthPauseSeconds + ($RunbookBusyRetrySeconds * $RunbookBusyRetryLimit)

$Settings = $DeployableSettings[$Deployable]
if (-not $Settings) { throw "deployable $Deployable is not promoted automatically: no entry in `$DeployableSettings ($(@($DeployableSettings.Keys | Sort-Object) -join ', '))" }

function ConvertTo-GlobRegex([string] $Glob) {
    $r = [regex]::Escape($Glob) -replace '\\\*\\\*/', '(?:.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*'
    "^$r$"
}
function Test-GlobMatch([string] $Path, [string[]] $Globs) {
    foreach ($g in $Globs) { if ($Path -imatch (ConvertTo-GlobRegex $g)) { return $true } }
    $false
}

function Get-PipelineEvidence {
    param([string[]] $Paths, [string[]] $Documentation = $DocumentationPaths, [string[]] $Build = $BuildFiles,
        [string[]] $Unflagged = $Settings.UnflaggedFolders, [string[]] $Application = $Settings.ApplicationPaths)
    $outside = "outside $(@($Application | ForEach-Object { $_ -replace '\*\*$', '' }) -join ', ')"
    foreach ($p in @($Paths | Where-Object { $_ })) {
        if (Test-GlobMatch $p $Documentation) { continue }
        if (@($Unflagged | Where-Object { $_ -and $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        if (-not (Test-GlobMatch $p $Application)) { "$p ($outside)"; continue }
        if (Test-GlobMatch ($p.Split('/')[-1]) $Build) { "$p (build or project file)" }
    }
}

function ConvertFrom-PipelineEvidencePath([string] $Evidence) {
    # "path (outside src/)" or "path (build or project file)" -> path; anything else unchanged.
    if ($Evidence -match '^(.*) \((?:outside .*|build or project file)\)$') { return $Matches[1] }
    $Evidence
}

function Get-GhsaIds([string] $Text) {
    # Distinct GHSA-…. ids in title or body (canonical published-advisory signal).
    [string[]] @([regex]::Matches($Text ?? '', $GhsaIdPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
}

function Test-SecurityAdvisoryPackagePath([string] $Path, [string[]] $PackageFiles = $SecurityAdvisoryPackageFiles) {
    # Project/package version surfaces, or the dead-code unused-package baseline (any depth).
    if ($Path -match '(?i)(^|/)unused-package-baseline\.json$') { return $true }
    Test-GlobMatch ($Path.Split('/')[-1]) $PackageFiles
}

function Test-PackageVersionOnlyPatch {
    <# A unified diff (GitHub pull file patch, or git diff) whose changed lines are only package version numbers on a
       project/package file, or any change to unused-package-baseline.json. $null patch: unreadable (fail closed). #>
    param([string] $Path, $Patch)
    if ($null -eq $Patch) { return $false }
    $Patch = [string] $Patch
    if ($Path -match '(?i)(^|/)unused-package-baseline\.json$') { return $true }
    $inComment = $false
    foreach ($line in @(($Patch ?? '') -split "`r?`n")) {
        if ($line -match '^(--- |\+\+\+ |@@ )') { continue }
        if ($line -notmatch '^[\+\-]') { continue }
        $t = $line.Substring(1)
        if ($t -match '<!--') { $inComment = $true }
        if ($inComment) { if ($t -match '-->') { $inComment = $false }; continue }
        if ($t -match '^\s*$') { continue }
        if ($t -match '^\s*</?(PackageReference|PackageVersion|ItemGroup)\b') { continue }
        if ($t -match '^\s*<Version\b') { continue }
        if ($t -match '^\s*<Project\b' -and $t -match '\bSdk\s*=') { continue }
        if ($t -match '^\s*<Sdk\b') { continue }
        if ($Path -match '(?i)(^|/)global\.json$' -and $t -match '^\s*"(sdk|version)"\s*:') { continue }
        return $false
    }
    $true
}

function Test-SecurityAdvisoryExemption {
    <# Whether the pipeline/project-file hold may skip its 60-minute wait: every flagged path is a package-version
       surface (or unused-package-baseline.json) owned by a PR that has a GHSA id in title or body and whose entire
       file list is package-version-only. PullByPath: path -> @{ Number; Title; Body; Files = @(@{ Filename; Patch });
       Error }. Missing lookup, Error, or $null Patch: Qualifies is false (fail closed). #>
    param([string[]] $FlaggedPaths, [hashtable] $PullByPath)
    $paths = @($FlaggedPaths | Where-Object { $_ } | Select-Object -Unique)
    if ($paths.Count -eq 0) { return @{ Qualifies = $false; GhsaIds = @(); Paths = @(); Why = 'no flagged path' } }
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($p in $paths) {
        if (-not (Test-SecurityAdvisoryPackagePath $p)) {
            return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "$p is not a package-version surface" }
        }
        if (-not $PullByPath -or -not $PullByPath.ContainsKey($p)) {
            return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "pull request of $p not known" }
        }
        $pr = $PullByPath[$p]
        if ($pr['Error']) {
            return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "pull request of $p not read: $($pr.Error)" }
        }
        $found = @(Get-GhsaIds "$($pr.Title) $($pr.Body)")
        if ($found.Count -eq 0) {
            return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "pull request #$($pr.Number) has no GHSA id in title or body" }
        }
        foreach ($id in $found) { if ($ids -notcontains $id) { $ids.Add($id) } }
        $files = @($pr.Files)
        if ($files.Count -eq 0) {
            return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "files of pull request #$($pr.Number) not read" }
        }
        foreach ($f in $files) {
            $name = [string] $f.Filename
            if (-not (Test-SecurityAdvisoryPackagePath $name)) {
                return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "#$($pr.Number) changes $name (not a package-version surface)" }
            }
            if ($null -eq $f.Patch) {
                return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "diff of $name in #$($pr.Number) not readable" }
            }
            if (-not (Test-PackageVersionOnlyPatch -Path $name -Patch ([string] $f.Patch))) {
                return @{ Qualifies = $false; GhsaIds = @(); Paths = $paths; Why = "#$($pr.Number) changes more than package versions in $name" }
            }
        }
    }
    @{ Qualifies = $true; GhsaIds = @($ids); Paths = $paths; Why = '' }
}

function ConvertTo-CheckState {
    # A check run: success; skipped and neutral pass; a conclusion that is anything else fails; no conclusion yet is pending.
    param([string] $Status, [string] $Conclusion)
    if ($Conclusion) {
        switch ($Conclusion) { 'success' { return 'success' } { $_ -in 'skipped', 'neutral' } { return 'skipped' } default { return 'failure' } }
    }
    if ($Status -eq 'completed') { return 'failure' }
    'pending'
}
function ConvertTo-StatusState([string] $State) { switch ($State) { 'success' { 'success' } 'pending' { 'pending' } default { 'failure' } } }
function Test-AgentCheckRun([string] $Name, [string] $AppSlug) {
    # A GitHub Copilot cloud agent session ("Running Copilot cloud agent", event dynamic) is not a build or test of the commit.
    ($AppSlug -match '^copilot-swe-agent') -or ($Name -match '^(Running Copilot cloud agent|copilot)$')
}

function Get-ActionsRunId([string] $Url) {
    # The Actions run id in a check-run URL (.../actions/runs/<id>/job/<id>); empty when the URL is not one.
    if ($Url -match '/actions/runs/(?<id>[0-9]+)(/|$)') { return $Matches['id'] }
    ''
}

function Test-PromoterCheckRun {
    # ui-auto-promote only decides whether to promote. Its own check runs (the promote and publish jobs), red or still
    # running, are not a build or test of the commit (issue #610: the promoter's crashed runs flagged the release).
    # Identified by the workflow, never by the job name: a job named promote in another workflow still counts.
    param([string] $WorkflowName, [string] $WorkflowPath)
    ($WorkflowName -eq 'ui-auto-promote') -or ($WorkflowPath -eq '.github/workflows/ui-auto-promote.yml')
}


function Get-MasterState {
    # Checks of master's head commit (Name, State): green when every one passed, red when one failed, pending when one is not
    # finished or none has reported. A read that failed is 'unknown' (decided by the caller), never green.
    param([object[]] $Checks)
    $c = Get-CheckFindings -Checks @($Checks)
    if ($c.Failed.Count -gt 0) { return @{ State = 'red'; Evidence = @($c.Failed | ForEach-Object { "$($_.Name) $($_.Url)".Trim() }) } }
    if (@($Checks).Count -eq 0) { return @{ State = 'pending'; Evidence = @('no check has reported yet') } }
    if ($c.Pending.Count -gt 0) { return @{ State = 'pending'; Evidence = @($c.Pending | ForEach-Object Name) } }
    @{ State = 'green'; Evidence = @() }
}

function Get-MasterPendingDeadline {
    <# Absolute UTC deadline for finishing the master-pending wait. Null when the job start is unset (local runs /
       tests without a budget). start + JobTimeoutMinutes − reserve; reserve covers Sign-off, health pause, runbook. #>
    param(
        [string] $StartedAt = $env:AUTO_PROMOTE_JOB_STARTED_AT,
        [int] $JobTimeoutMinutes = $MasterPendingJobTimeoutMinutes,
        [int] $ReserveSeconds = $MasterPendingJobReserveSeconds
    )
    if (-not $StartedAt) { return $null }
    $start = [datetime]::Parse(
        $StartedAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
    $start.AddMinutes($JobTimeoutMinutes).AddSeconds(-$ReserveSeconds)
}

function Wait-MasterPendingClear {
    <# When master's checks are only pending (none failed), wait and re-read until green, red, unknown, or the timeout.
       Does not loosen the gate: a failed check still holds; still pending at the timeout still holds (issue #697).
       Caps the wait by Deadline − GetNow when a Deadline is set so the promote job can still finish Sign-off, a
       health pause and a runbook wait before its timeout (PR #698 review). Too little remaining: skip wait, return
       pending (hold). Never promotes when the budget is exhausted.
       Pause / PollSeconds / TimeoutSeconds / Deadline / GetNow are injectable so the harness does not sleep.
       ReadAgain: { } -> @{ State; Evidence; Sha; Branch } (one fresh read of the current head, no wait).
       Returns the last master state. #>
    param(
        [hashtable] $Initial,
        [scriptblock] $ReadAgain,
        [scriptblock] $Pause = $MasterPendingPause,
        [int] $PollSeconds = $MasterPendingPollSeconds,
        [int] $TimeoutSeconds = $MasterPendingTimeoutSeconds,
        [scriptblock] $WriteLog = { param([string] $Message) Write-Host $Message },
        $Deadline = $null,
        [scriptblock] $GetNow = { [datetime]::UtcNow }
    )
    $current = $Initial
    if ($current.State -ne 'pending') { return $current }
    $effectiveTimeout = $TimeoutSeconds
    if ($null -ne $Deadline) {
        $remaining = [int][math]::Floor((([datetime]$Deadline).ToUniversalTime() - (& $GetNow).ToUniversalTime()).TotalSeconds)
        if ($remaining -lt $PollSeconds) {
            & $WriteLog "Skipping wait for master's checks: not enough job time left before the promote timeout (need ${PollSeconds}s, have ${remaining}s; reserve covers Sign-off, health pause, runbook wait)."
            return $current
        }
        $effectiveTimeout = [math]::Min($TimeoutSeconds, $remaining)
    }
    $limit = [math]::Max(1, [int][math]::Floor($effectiveTimeout / [double]$PollSeconds))
    for ($n = 1; $n -le $limit; $n++) {
        $why = if (@($current.Evidence).Count) { ": $(@($current.Evidence) -join ', ')" } else { '' }
        & $WriteLog "Waiting for master's checks to finish ($n/$limit, ${PollSeconds}s)$why."
        & $Pause $PollSeconds
        try {
            $current = & $ReadAgain
        } catch {
            & $WriteLog "Waiting: master's checks could not be read ($($_.Exception.Message))"
            return @{ State = 'unknown'; Evidence = @("read failed: $($_.Exception.Message)"); Sha = $current.Sha; Branch = $current.Branch }
        }
        if (-not $current -or -not $current.State) {
            & $WriteLog 'Waiting: master state could not be read (empty answer).'
            return @{ State = 'unknown'; Evidence = @('read failed: empty answer'); Sha = $Initial.Sha; Branch = $Initial.Branch }
        }
        if ($current.State -ne 'pending') {
            $afterWhy = if (@($current.Evidence).Count) { ': ' + (@($current.Evidence) -join ', ') } else { '' }
            & $WriteLog "Master ($($current.Branch) $($current.Sha)): $($current.State) after waiting$afterWhy"
            return $current
        }
    }
    $stillWhy = if (@($current.Evidence).Count) { ": $(@($current.Evidence) -join ', ')" } else { '' }
    & $WriteLog "Master still pending after ${effectiveTimeout}s$stillWhy."
    $current
}

function Get-CheckFindings {
    param([object[]] $Checks)
    @{
        Failed  = @($Checks | Where-Object { $_.State -eq 'failure' })
        Pending = @($Checks | Where-Object { $_.State -eq 'pending' })
        Passed  = @($Checks | Where-Object { $_.State -in 'success', 'skipped' })
    }
}

function Get-HealthVerdict {
    param([datetime] $Finished, [datetime] $Now, [object[]] $Reads, [int] $WindowMinutes = 10, [int] $GapMinutes = 5)
    $since = @($Reads | Where-Object { $_.At -ge $Finished })
    if (@($since | Where-Object { $_.Status -ne 'Healthy' }).Count -gt 0) { return 'fail' }
    if ($Now -lt $Finished.AddMinutes($WindowMinutes) -or $since.Count -lt 2) { return 'wait' }
    $first = ($since | Measure-Object -Property At -Minimum).Minimum
    $last = ($since | Measure-Object -Property At -Maximum).Maximum
    if (($last - $first).TotalMinutes -ge $GapMinutes -and $last -ge $Finished.AddMinutes($WindowMinutes)) { 'ok' } else { 'wait' }
}

function Invoke-HealthRead {
    # One health read. Reader: the answered overallStatus; it throws or answers nothing when the app is unreachable or the
    # request timed out, and then it is tried again up to Retries more times, Pause between (20 to 30 s). An answered
    # status, Healthy or not, counts at once, except NotReady (an app still starting), which is tried again too and
    # counts only when every attempt answered it. Returns @{ Status; Attempts }; Status Unreachable when every attempt
    # failed.
    param([scriptblock] $Reader, [int] $Retries = 3, [scriptblock] $Pause = { Start-Sleep -Seconds (Get-Random -Minimum 20 -Maximum 31) })
    $notReady = 0
    for ($i = 1; $i -le $Retries + 1; $i++) {
        $status = try { [string] (& $Reader) } catch { '' }
        if ($status -eq 'NotReady') { $notReady++ }
        elseif ($status) { return @{ Status = $status; Attempts = $i } }
        if ($i -le $Retries) { & $Pause }
    }
    @{ Status = ($notReady -eq $Retries + 1 ? 'NotReady' : 'Unreachable'); Attempts = $Retries + 1 }
}

function ConvertTo-ReadyStatus {
    # A /ready answer (HealthRead ready): 200 is Healthy; 503 whose JSON has "ready" is NotReady (Invoke-HealthRead retries it);
    # anything else is '' (not answered: Invoke-HealthRead tries again, as for an unreachable app).
    param([int] $StatusCode, [string] $Body)
    if ($StatusCode -eq 200) { return 'Healthy' }
    if ($StatusCode -eq 503) {
        $j = try { $Body | ConvertFrom-Json -AsHashtable } catch { $null }
        if ($j -is [Collections.IDictionary] -and $j.ContainsKey('ready')) { return 'NotReady' }
    }
    ''
}

function ConvertTo-HttpOkStatus {
    # HealthRead httpOk (static site): 2xx is Healthy; any other answered status is Unhealthy at once; 0 / no answer is
    # '' (Invoke-HealthRead tries again).
    param([int] $StatusCode)
    if ($StatusCode -ge 200 -and $StatusCode -lt 300) { return 'Healthy' }
    if ($StatusCode -gt 0) { return 'Unhealthy' }
    ''
}

function Get-LogFindings {
    # The task's raw log: findings, or "task log unreadable" when it is empty, short or lacks the task's own header.
    param([string] $Raw, [string] $TaskId, [string[]] $WarnedSteps = @())
    $lines = @(($Raw ?? '') -split "`r?`n")
    if ($lines.Count -lt 20 -or $Raw -notmatch ('(?m)^Task ID:\s+' + [regex]::Escape($TaskId))) { return @('task log unreadable') }
    $out = @()
    if ($WarnedSteps.Count -gt 0) { $out += "steps SuccessWithWarning: $($WarnedSteps -join ', ')" }
    $out += @($lines | Where-Object { $_ -match '^\S+\s+(Error|Warning|Fatal)\s+\|' } | Select-Object -First 8 | ForEach-Object { $_.Trim() })
    $out
}

function Test-PipelineOnly {
    # The pipeline-or-infra flag is the only flag, from a known comparison (an incomplete one also skipped the Hold lookup).
    param([object[]] $Flags, [hashtable] $Facts)
    @($Flags).Count -eq 1 -and $Flags[0].Flag -eq 'Pipeline or infra change' -and [bool] $Facts.PathsKnown
}

function Read-SecurityAdvisoryOverride {
    <# Builds SecurityAdvisoryOverride facts from Get-PipelineEvidence lines. GetPullForPath {param($path)} ->
       @{ Number; Title; Body; Files = @(@{ Filename; Patch }) } or throws / returns Error. Fail closed on any miss. #>
    param([string[]] $Evidence, [scriptblock] $GetPullForPath)
    $paths = @($Evidence | ForEach-Object { ConvertFrom-PipelineEvidencePath $_ } | Where-Object { $_ } | Select-Object -Unique)
    $byPath = @{}
    foreach ($p in $paths) {
        try {
            $pr = & $GetPullForPath $p
            if (-not $pr) { $byPath[$p] = @{ Number = 0; Title = ''; Body = ''; Files = @(); Error = "pull request of $p not known" } }
            elseif ($pr['Error']) { $byPath[$p] = $pr }
            else { $byPath[$p] = $pr }
        } catch {
            $byPath[$p] = @{ Number = 0; Title = ''; Body = ''; Files = @(); Error = $_.Exception.Message }
        }
    }
    Test-SecurityAdvisoryExemption -FlaggedPaths $paths -PullByPath $byPath
}

function Get-PromotionDecision {
    <# Facts: Checks, PathsKnown, PathsReason, Paths, HoldItems, HoldUnknown (reasons), PreviousState, LogFindings, Finished,
       Now, HealthReads, HealthAddressKnown, PipelineOverride = @{ Minutes (since the previous deployment finished);
       MasterState = green|pending|red|unknown; MasterEvidence } (read only when the pipeline flag is the only one), and
       SecurityAdvisoryOverride = @{ Qualifies; GhsaIds; Paths; Why } (Test-SecurityAdvisoryExemption; same gate).
       Returns @{ Decision = promote|hold|wait; Reason = no-flag|pipeline-override|security-advisory-override (promote);
       Note (hold); Flags; Waiting; Passed }. #>
    param([hashtable] $Facts, [int] $OverrideMinutes = $PipelineOverrideMinutes, [string] $Name = $Deployable, [string] $HealthPath = $Settings.HealthPath)
    $flags = [Collections.Generic.List[object]]::new()
    $waiting = [Collections.Generic.List[string]]::new()

    $c = Get-CheckFindings -Checks @($Facts.Checks)
    if ($c.Failed.Count -gt 0) { $flags.Add(@{ Flag = 'Red build or tests'; Evidence = @($c.Failed | ForEach-Object { "$($_.Name) $($_.Url)".Trim() }) }) }
    if ($c.Pending.Count -gt 0) { $waiting.Add("checks not finished: $(@($c.Pending | ForEach-Object Name) -join ', ')") }
    if (@($Facts.Checks).Count -eq 0) { $waiting.Add('no check has reported on the commit yet') }

    $d = [Collections.Generic.List[string]]::new()
    if ($Facts.PreviousState -ne 'Success') { $d.Add("the deployment to the previous environment ended $($Facts.PreviousState)") }
    foreach ($l in @($Facts.LogFindings)) { if ($l) { $d.Add("log: $l") } }
    $healthRequired = -not ($Facts.ContainsKey('HealthRequired') -and -not [bool] $Facts.HealthRequired)
    if ($d.Count -eq 0 -and $healthRequired) {
        if (-not $Facts.HealthAddressKnown) { $waiting.Add("health address unknown: the address of $Name in the previous environment could not be read") }
        else {
            $h = Get-HealthVerdict -Finished $Facts.Finished -Now $Facts.Now -Reads @($Facts.HealthReads)
            if ($h -eq 'fail') { $d.Add("health: $HealthPath was not Healthy: $(@($Facts.HealthReads | Where-Object { $_.Status -ne 'Healthy' } | ForEach-Object { "$($_.Status) at $($_.At.ToString('u'))" }) -join '; ')") }
            elseif ($h -eq 'wait') { $waiting.Add('health window: not yet 10 minutes since the deployment finished with two Healthy reads 5 minutes apart') }
        }
    }
    if ($d.Count -gt 0) { $flags.Add(@{ Flag = 'Deployment or health failed'; Evidence = @($d) }) }

    if (-not $Facts.PathsKnown) { $flags.Add(@{ Flag = 'Pipeline or infra change'; Evidence = @("comparison incomplete: $($Facts.PathsReason ?? 'the changes since the commit running in the next environment could not be determined')") }) }
    else {
        $p = @(Get-PipelineEvidence -Paths @($Facts.Paths))
        if ($p.Count -gt 0) { $flags.Add(@{ Flag = 'Pipeline or infra change'; Evidence = $p }) }
    }

    $hold = @(@($Facts.HoldItems) | Where-Object { $_ -and @($_.Labels | Where-Object { $_ -ieq 'Hold' }).Count -gt 0 })
    if ($hold.Count -gt 0) { $flags.Add(@{ Flag = 'Hold label'; Evidence = @($hold | ForEach-Object { "#$($_.Number) $($_.Url)".Trim() }) }) }
    foreach ($u in @($Facts.HoldUnknown)) { if ($u) { $waiting.Add("hold lookup incomplete: $u") } }

    $decision = if ($flags.Count -gt 0) { 'hold' } elseif ($waiting.Count -gt 0) { 'wait' } else { 'promote' }
    $reason = if ($decision -eq 'promote') { 'no-flag' } else { $null }
    $note = $null
    if (Test-PipelineOnly -Flags @($flags) -Facts $Facts) {
        $o = $Facts['PipelineOverride']
        $sa = $Facts['SecurityAdvisoryOverride']
        $minutes = if ($o -and $null -ne $o['Minutes']) { [double] $o['Minutes'] } else { -1 }
        $master = if ($o -and $o['MasterState']) { [string] $o['MasterState'] } else { 'unknown' }
        $masterWhy = if ($o -and $o['MasterEvidence']) { ": $(@($o['MasterEvidence']) -join ', ')" } else { '' }
        $at = if ($Facts.Finished) { ([datetime] $Facts.Finished).AddMinutes($OverrideMinutes).ToString('yyyy-MM-dd HH:mm') + ' UTC' } else { "$OverrideMinutes minutes after the deployment to the previous environment finished" }
        $advisory = [bool] ($sa -and $sa['Qualifies'])
        $ghsa = if ($advisory) { (@($sa['GhsaIds']) -join ', ') } else { '' }
        $when = if ($advisory) {
            "Security-advisory dependency fix ($ghsa) is the only pipeline flag: promoted immediately when master of the application repository is green (owner rule 2026-11-11); otherwise after $at (owner rule 2026-10-14)."
        } else {
            "Pipeline change is the only flag: promoted automatically after $at if master of the application repository is green (owner rule 2026-10-14)."
        }
        if ($master -eq 'red') { $note = "$when Not now: master is red$masterWhy." }
        elseif ($master -ne 'green' -and $master -ne 'pending') { $note = "$when Not now: the state of master could not be read$masterWhy (unknown counts as not green)." }
        elseif ($advisory -and $master -eq 'green' -and $waiting.Count -eq 0) { $decision = 'promote'; $reason = 'security-advisory-override' }
        elseif ($minutes -lt $OverrideMinutes) { $note = $when }
        elseif ($master -eq 'pending') { $note = "$when Not yet: master is not green yet (pending$masterWhy)." }
        elseif ($waiting.Count -gt 0) { $note = "$when Not yet: waiting for $(@($waiting) -join '; ')." }
        else { $decision = 'promote'; $reason = 'pipeline-override' }
    }
    @{ Decision = $decision; Reason = $reason; Note = $note; Flags = @($flags); Waiting = @($waiting); Passed = @($c.Passed | ForEach-Object Name) }
}

function Get-BusyItemProperty($Item, [string] $Name) {
    # Optional busy-item field under StrictMode: hashtable key or note property; otherwise $null.
    if ($null -eq $Item) { return $null }
    if ($Item -is [hashtable]) {
        if (-not $Item.ContainsKey($Name)) { return $null }
        return $Item[$Name]
    }
    if ($Item.PSObject.Properties[$Name]) { return $Item.$Name }
    $null
}

function Format-BusyItemDetail($Item) {
    # Names the unfinished Octopus task so a stall can be diagnosed from the run log (#701).
    $parts = [Collections.Generic.List[string]]::new()
    $taskId = Get-BusyItemProperty $Item 'TaskId'
    $version = Get-BusyItemProperty $Item 'ReleaseVersion'
    $state = Get-BusyItemProperty $Item 'State'
    if ($taskId) { $parts.Add("task $taskId") }
    if ($version) { $parts.Add("release $version") }
    if ($state) { $parts.Add("state $state") }
    if ($parts.Count -eq 0) { return '' }
    " ($($parts -join ', '))"
}

function Get-BusyReason {
    # Items: @{ Kind = deployment|runbook; ProjectId; EnvironmentId; TaskId?; ReleaseVersion?; State?; SignOffRefused? }
    # of every task that is not finished. TaskId / ReleaseVersion / State are named in the message when present (#701).
    # SignOffRefused: a deployment parked only because Octopus refused this account the Sign-off (#569) does not block.
    param([object[]] $Items, [string] $TargetEnvironmentId, [string] $FirstEnvironmentId, [string] $ProjectId, [string] $Name = $Deployable)
    foreach ($i in @($Items)) {
        if (Test-BusyItemSignOffRefused $i) { continue }
        $detail = Format-BusyItemDetail $i
        if ($i.EnvironmentId -eq $TargetEnvironmentId) { return "a $($i.Kind) of project $($i.ProjectId) to the target environment is not finished$detail" }
        if ($i.Kind -eq 'deployment' -and $i.ProjectId -eq $ProjectId -and $i.EnvironmentId -ne $FirstEnvironmentId) { return "a $Name deployment is not finished in another environment$detail" }
    }
}

function Test-BusyItemSignOffRefused($Item) {
    # True when the busy item is a deployment parked only on a refused Sign-off (Get-BusyReason skips it).
    if ($null -eq $Item) { return $false }
    if ($Item -is [hashtable]) { return [bool] $Item['SignOffRefused'] }
    if ($Item.PSObject.Properties['SignOffRefused']) { return [bool] $Item.SignOffRefused }
    $false
}

function Test-BusyOnlyRunbookToTarget {
    # True when Get-BusyReason would block solely because of runbook run(s) in the target environment (#583).
    # A deployment in the target, or this project's deployment in a later-than-first environment, is not "runbook only".
    param([object[]] $Items, [string] $TargetEnvironmentId, [string] $FirstEnvironmentId, [string] $ProjectId)
    $hasRunbook = $false
    foreach ($i in @($Items)) {
        if (Test-BusyItemSignOffRefused $i) { continue }
        if ($i.EnvironmentId -eq $TargetEnvironmentId) {
            if ($i.Kind -eq 'runbook') { $hasRunbook = $true; continue }
            return $false
        }
        if ($i.Kind -eq 'deployment' -and $i.ProjectId -eq $ProjectId -and $i.EnvironmentId -ne $FirstEnvironmentId) {
            return $false
        }
    }
    $hasRunbook
}

function Wait-BusyRunbookClear {
    <# When the only busy reason is runbook(s) to the target, wait and re-list until clear, a non-runbook busy reason
       appears, the retry budget is spent, or GetBusyItems fails. Pause is injectable so the harness does not sleep.
       Returns @{ Items; Busy; Cleared; Exhausted; Failed }. #>
    param(
        [object[]] $Items,
        [string] $TargetEnvironmentId,
        [string] $FirstEnvironmentId,
        [string] $ProjectId,
        [string] $EnvironmentName = '',
        [scriptblock] $GetBusyItems,
        [scriptblock] $Pause = $RunbookBusyPause,
        [int] $RetrySeconds = $RunbookBusyRetrySeconds,
        [int] $RetryLimit = $RunbookBusyRetryLimit,
        [scriptblock] $WriteLog = { param([string] $Message) Write-Host $Message },
        [string] $Name = $Deployable
    )
    $current = @($Items)
    $busy = Get-BusyReason -Items $current -TargetEnvironmentId $TargetEnvironmentId -FirstEnvironmentId $FirstEnvironmentId -ProjectId $ProjectId -Name $Name
    if (-not $busy) {
        return @{ Items = $current; Busy = $null; Cleared = $true; Exhausted = $false; Failed = $false }
    }
    if (-not (Test-BusyOnlyRunbookToTarget -Items $current -TargetEnvironmentId $TargetEnvironmentId -FirstEnvironmentId $FirstEnvironmentId -ProjectId $ProjectId)) {
        return @{ Items = $current; Busy = $busy; Cleared = $false; Exhausted = $false; Failed = $false }
    }
    for ($n = 1; $n -le $RetryLimit; $n++) {
        $runbooks = @($current | Where-Object { $_.Kind -eq 'runbook' -and $_.EnvironmentId -eq $TargetEnvironmentId })
        $projects = (@($runbooks | ForEach-Object { $_.ProjectId } | Select-Object -Unique) -join ', ')
        $taskIds = (@($runbooks | ForEach-Object { $_.TaskId } | Where-Object { $_ } | Select-Object -Unique) -join ', ')
        $envLabel = if ($EnvironmentName) { $EnvironmentName } else { $TargetEnvironmentId }
        $taskPart = if ($taskIds) { ", task $taskIds" } else { '' }
        & $WriteLog "Waiting for a runbook of project $projects in $envLabel$taskPart to finish before promoting ($n/$RetryLimit, ${RetrySeconds}s)."
        & $Pause $RetrySeconds
        try {
            $current = @(& $GetBusyItems)
        } catch {
            & $WriteLog "Waiting: Octopus tasks could not be read whole ($($_.Exception.Message))"
            return @{ Items = $current; Busy = $busy; Cleared = $false; Exhausted = $false; Failed = $true }
        }
        $busy = Get-BusyReason -Items $current -TargetEnvironmentId $TargetEnvironmentId -FirstEnvironmentId $FirstEnvironmentId -ProjectId $ProjectId -Name $Name
        if (-not $busy) {
            return @{ Items = $current; Busy = $null; Cleared = $true; Exhausted = $false; Failed = $false }
        }
        if (-not (Test-BusyOnlyRunbookToTarget -Items $current -TargetEnvironmentId $TargetEnvironmentId -FirstEnvironmentId $FirstEnvironmentId -ProjectId $ProjectId)) {
            return @{ Items = $current; Busy = $busy; Cleared = $false; Exhausted = $false; Failed = $false }
        }
    }
    @{ Items = $current; Busy = $busy; Cleared = $false; Exhausted = $true; Failed = $false }
}

function Test-OctopusPermissionDenied {
    # True for HTTP 401/403 or Octopus wording that the account is not in a team that may take the interruption.
    param($ErrorRecord)
    $ex = $null; $msg = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ex = $ErrorRecord.Exception
        $parts = [Collections.Generic.List[string]]::new()
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $parts.Add([string] $ErrorRecord.ErrorDetails.Message) }
        if ($ex) { $parts.Add([string] $ex.Message) }
        $msg = $parts -join ' '
    } else {
        $msg = [string] $ErrorRecord
    }
    $status = 0
    if ($ex -and $ex.PSObject.Properties['Response'] -and $null -ne $ex.Response -and $ex.Response.PSObject.Properties['StatusCode']) {
        $status = [int] $ex.Response.StatusCode
    } elseif ($msg -match 'Response status code does not indicate success:\s*(401|403)\b') {
        $status = [int] $Matches[1]
    }
    if ($status -eq 401 -or $status -eq 403) { return $true }
    if ($msg -match 'You must be in a team that has permissions|not in any team with permissions') { return $true }
    $false
}

function Invoke-SignOffOctopusCalls {
    # Take responsibility (optional) then submit. Returns 'signed' or 'refused'; rethrows every other error.
    # Calls Invoke-Octopus directly (script scope): do not wrap those calls in GetNewClosure scriptblocks —
    # a closure binds to a dynamic module that cannot see script-scope functions when the workflow runs the
    # script with & (GitHub Actions' pwsh shell), which is why every ui-auto-promote run failed in #589.
    param(
        [Parameter(Mandatory)] [string] $Space,
        [Parameter(Mandatory)] [string] $InterruptionId,
        [Parameter(Mandatory)] [string] $Reason,
        [bool] $NeedTakeResponsibility
    )
    try {
        if ($NeedTakeResponsibility) {
            Invoke-Octopus "/api/$Space/interruptions/$InterruptionId/responsible" 'Put' | Out-Null
        }
        Invoke-Octopus "/api/$Space/interruptions/$InterruptionId/submit" 'Post' @{ Notes = $Reason; Result = 'Proceed' } | Out-Null
        'signed'
    } catch {
        if (Test-OctopusPermissionDenied $_) { 'refused' } else { throw }
    }
}

# Flag text of a release-held issue opened when Octopus refused Sign-off permission (#569). Kept stable so later runs
# can spot it in the issue body and so Get-BusyReason can ignore that parked deployment.
$SignOffPermissionDeniedFlag = 'Sign-off permission denied'

function New-SignOffRefusedEvaluation {
    # Evaluation shape for Set-HeldIssue when Octopus refused take-responsibility or submit on a Sign-off.
    param([string] $Sha, [string] $ProjectName, [string] $ReleaseVersion, [string] $EnvironmentName, [string] $Detail = '')
    $evidence = [Collections.Generic.List[string]]::new()
    $evidence.Add("Octopus refused the auto-promote account permission to take the Sign-off for $ProjectName $ReleaseVersion in $EnvironmentName.")
    if ($Detail) { $evidence.Add($Detail) }
    @{
        Sha      = $(if ($Sha) { $Sha } else { 'unknown' })
        Decision = @{
            Decision = 'hold'
            Reason   = $null
            Note     = ''
            Flags    = @(@{ Flag = $SignOffPermissionDeniedFlag; Evidence = @($evidence) })
            Waiting  = @()
            Passed   = @()
        }
    }
}

function Test-SignOffRefusedHoldBody([string] $Body) {
    # True when a release-held issue body was written for a refused Sign-off (#569).
    "$Body" -match [regex]::Escape($SignOffPermissionDeniedFlag)
}

# Flag text when a release's notes name no commit sha (#621). Kept stable so later runs spot the hold body.
$NoCommitInNotesFlag = 'release notes name no commit'

function New-NoCommitHoldEvaluation {
    # Evaluation shape for Set-HeldIssue when release notes name no commit: hold, do not throw, do not promote (#621).
    param([string] $ReleaseVersion, [string] $Name = $Deployable, [string] $TargetName = '')
    $evidence = [Collections.Generic.List[string]]::new()
    $evidence.Add("$Name $ReleaseVersion names no commit in its release notes, so auto-promote cannot evaluate checks, comparison, or health.")
    if ($TargetName) { $evidence.Add("It was the candidate for $TargetName.") }
    @{
        Sha      = 'none'
        Decision = @{
            Decision = 'hold'
            Reason   = $null
            Note     = ''
            Flags    = @(@{ Flag = $NoCommitInNotesFlag; Evidence = @($evidence) })
            Waiting  = @()
            Passed   = @()
        }
    }
}

function Test-NoCommitHoldBody([string] $Body) {
    # True when a release-held issue body was written because release notes named no commit (#621).
    "$Body" -match [regex]::Escape($NoCommitInNotesFlag)
}

function Test-NoCommitHoldFlags([object[]] $Flags) {
    @($Flags | Where-Object { $_.Flag -eq $NoCommitInNotesFlag }).Count -gt 0
}

function Get-NoCommitHeldTitle([string] $Version, [string] $Name = $Deployable) {
    "$Name $Version held: release notes name no commit"
}

function Get-EvaluationCommitOrHold {
    # Commit from release notes, or a hold evaluation when none (#621). Never throws for a missing commit.
    param($Release, [string] $Name = $Deployable, [string] $TargetName = '')
    $sha = Get-Commit $Release
    if ($sha) { return @{ Sha = $sha; Hold = $null } }
    $version = if ($null -eq $Release) { '' } else { [string] $Release.Version }
    @{ Sha = $null; Hold = (New-NoCommitHoldEvaluation -ReleaseVersion $version -Name $Name -TargetName $TargetName) }
}

function Set-SignOffRefusedOnBusyItems {
    # Marks busy deployments that match an open refused-Sign-off hold so Get-BusyReason does not block other projects.
    param([object[]] $Items, [object[]] $HeldIssues, [hashtable] $ProjectIdByDeployableName, [hashtable] $EnvironmentIdByName, [scriptblock] $GetReleaseVersion)
    foreach ($hi in @($HeldIssues)) {
        if (-not (Test-SignOffRefusedHoldBody ([string] $hi.body))) { continue }
        if ("$($hi.title)" -notmatch '^(\S+) (\S+) held before (\S+)$') { continue }
        $depName = $Matches[1]; $ver = $Matches[2]; $envName = $Matches[3]
        if (-not $ProjectIdByDeployableName.ContainsKey($depName)) { continue }
        if (-not $EnvironmentIdByName.ContainsKey($envName)) { continue }
        $heldProjectId = $ProjectIdByDeployableName[$depName]
        $heldEnvironmentId = $EnvironmentIdByName[$envName]
        foreach ($b in @($Items)) {
            if ($null -eq $b -or $b.Kind -ne 'deployment' -or $b.ProjectId -ne $heldProjectId -or $b.EnvironmentId -ne $heldEnvironmentId) { continue }
            $v = & $GetReleaseVersion $b
            if ($v -eq $ver) {
                if ($b -is [hashtable]) { $b['SignOffRefused'] = $true } else { $b | Add-Member -NotePropertyName SignOffRefused -NotePropertyValue $true -Force }
            }
        }
    }
}

function ConvertTo-ReleaseVersion([string] $Version) {
    # Major.Minor.Patch of a release version (a suffix is ignored); $null when it does not parse.
    if ($Version -match '^v?(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?!\d)') { [version]::new([int] $Matches[1], [int] $Matches[2], [int] $Matches[3]) }
}
function Compare-Release($A, $B) {
    # Above 0 when release A is newer than B: by version; an unparsable version is older than every parsable one; by
    # Assembled when the versions are equal or both do not parse (a total order, so the sort is consistent).
    $va = ConvertTo-ReleaseVersion $A.Version; $vb = ConvertTo-ReleaseVersion $B.Version
    if ($va -and -not $vb) { return 1 }
    if ($vb -and -not $va) { return -1 }
    if ($va -and $va -ne $vb) { return $va.CompareTo($vb) }
    ([datetimeoffset] $A.Assembled).CompareTo([datetimeoffset] $B.Assembled)
}
function Get-ReleasesNewestFirst([object[]] $Releases) {
    $l = [Collections.Generic.List[object]]::new(); foreach ($r in @($Releases)) { if ($r) { $l.Add($r) } }
    $l.Sort([Comparison[object]] { param($x, $y) Compare-Release $y $x })
    @($l)
}

function Get-RunningReleaseByEnvironment {
    <# The release that runs in Target when no release of the listed window ran there: the window holds only the newest
       releases, and the running one can be older (fworker 1.0.474, about 113 versions back, issue #314). The release of the
       newest deployment to Target whose task succeeded, read by its id. GetEnvironmentDeployments {param($environmentId,
       $take)} -> @{ Items (deployments of the project to that environment, newest first); Total }; GetRelease
       {param($releaseId)}; GetTaskState {param($deployment)}. $null when the listing is whole and no deployment there
       succeeded (nothing runs there). Throws "the release running in ..." when none of the newest $Max deployments
       succeeded and there are more, or when the release answered is empty; a failed call throws its own error (the run
       stops, as for every failed call). #>
    param($Target, [scriptblock] $GetEnvironmentDeployments, [scriptblock] $GetRelease, [scriptblock] $GetTaskState, [int] $Max = $RunningLookupDeployments)
    $list = & $GetEnvironmentDeployments $Target.Id $Max
    $items = @(@($list.Items) | Where-Object { $_ -and $_.EnvironmentId -eq $Target.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending)
    foreach ($d in $items) {
        if ((& $GetTaskState $d) -ne 'Success') { continue }
        $r = & $GetRelease $d.ReleaseId
        $rid = if ($r) { try { [string] $r.Id } catch { '' } } else { '' }
        if (-not $rid) { throw "the release running in $($Target.Name) could not be read: release $($d.ReleaseId) of deployment $($d.Id)" }
        return $r
    }
    if ([int] $list.Total -gt @($list.Items).Count) { throw "the release running in $($Target.Name) was not found: none of the newest $(@($list.Items).Count) of $($list.Total) deployments there succeeded" }
    $null
}

function Test-RunningLookupError($ErrorRecord) { "$($ErrorRecord.Exception.Message)" -like 'the release running in *' }

function Get-RunningRelease {
    <# The release that runs in Target: the newest (by version) with a deployment there whose task succeeded. A queued or
       waiting deployment is not running. Releases; GetDeployments {param($releaseId)}; GetTaskState {param($deployment)};
       GetRunningOutside {param($target)}: when no listed release ran there (Get-RunningReleaseByEnvironment; may throw). #>
    param($Target, [object[]] $Releases, [scriptblock] $GetDeployments, [scriptblock] $GetTaskState, [scriptblock] $GetRunningOutside = $null)
    foreach ($o in @(Get-ReleasesNewestFirst $Releases)) {
        $ran = @(& $GetDeployments $o.Id | Where-Object { $_.EnvironmentId -eq $Target.Id } | Where-Object { (& $GetTaskState $_) -eq 'Success' }) | Select-Object -First 1
        if ($ran) { return $o }
    }
    if ($GetRunningOutside) { return (& $GetRunningOutside $Target) }
    $null
}

function Select-Candidate {
    <# Environments ordered; Releases (Id, Version, Assembled); GetDeployments {param($releaseId)} -> deployments (Id, ReleaseId,
       EnvironmentId, TaskId, Created); GetTaskState {param($deployment)} -> Octopus task state; GetRunningOutside
       {param($target)} -> the release running in the target when no listed release ran there (it may be older than the
       list; Get-RunningReleaseByEnvironment), or $null; when it throws, the running release is unknown: RunningUnknown
       says why, and the evaluation flags "comparison incomplete" (no base commit). PreferHeld: @{ Version; Environment }
       from Get-HeldPipelinePrefer — when that version still qualifies for Environment, it is the candidate even if a
       newer release also succeeded in the previous environment (issue #688). Returns
       @{ Release; Target; Previous; RunningReleaseId; Running; RunningUnknown; Notes } or $null with Notes. Looks at the
       last environment first. #>
    param([object[]] $Environments, [object[]] $Releases, [scriptblock] $GetDeployments, [scriptblock] $GetTaskState, [scriptblock] $GetRunningOutside = $null, [object[]] $PreferHeld = @())
    $sorted = @(Get-ReleasesNewestFirst $Releases)
    $cache = @{}; $outside = @{}
    $deps = { param($r) if (-not $cache.ContainsKey($r.Id)) { $cache[$r.Id] = @(& $GetDeployments $r.Id) }; $cache[$r.Id] }
    $notes = [Collections.Generic.List[string]]::new()
    $resolveRunning = {
        param($target)
        $running = $null; $unknown = $null
        foreach ($o in $sorted) {
            $ran = @(& $deps $o | Where-Object { $_.EnvironmentId -eq $target.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending | Where-Object { (& $GetTaskState $_) -eq 'Success' }) | Select-Object -First 1
            if ($ran) { $running = $o; break }
        }
        if (-not $running -and $GetRunningOutside) {
            if (-not $outside.ContainsKey($target.Id)) {
                $outside[$target.Id] = try { @{ Release = (& $GetRunningOutside $target); Unknown = $null } } catch { if (-not (Test-RunningLookupError $_)) { throw }; @{ Release = $null; Unknown = $_.Exception.Message } }
                if ($outside[$target.Id].Release) { $notes.Add("the release running in $($target.Name), $($outside[$target.Id].Release.Version), is older than the listed releases: read through its deployment") }
            }
            $running = $outside[$target.Id].Release; $unknown = $outside[$target.Id].Unknown
        }
        @{ Running = $running; Unknown = $unknown }
    }
    for ($i = $Environments.Count - 1; $i -ge 1; $i--) {
        $target = $Environments[$i]; $previous = $Environments[$i - 1]
        $preferVersion = $null
        foreach ($p in @($PreferHeld)) {
            if ($p -and [string] $p.Environment -eq $target.Name -and [string] $p.Version) { $preferVersion = [string] $p.Version; break }
        }
        $tryOrder = $sorted
        if ($preferVersion) {
            $heldRel = @($sorted | Where-Object { $_.Version -eq $preferVersion } | Select-Object -First 1)
            if ($heldRel.Count -gt 0) { $tryOrder = @($heldRel[0]) + @($sorted | Where-Object { $_.Id -ne $heldRel[0].Id }) }
        }
        $skipped = $null
        foreach ($r in $tryOrder) {
            $here = @(& $deps $r)
            $prev = @($here | Where-Object { $_.EnvironmentId -eq $previous.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending) | Select-Object -First 1
            if (-not $prev) { continue }
            $state = & $GetTaskState $prev
            if ($state -ne 'Success') { if (-not $skipped) { $skipped = "$($r.Version) ended $state in $($previous.Name)" }; continue }
            if (@($here | Where-Object { $_.EnvironmentId -eq $target.Id }).Count -gt 0) {
                # Preferred held already in the target: fall through to the newest-first remainder (issue #688).
                if ($preferVersion -and $r.Version -eq $preferVersion) { continue }
                break
            }
            $runInfo = & $resolveRunning $target
            $running = $runInfo.Running; $unknown = $runInfo.Unknown
            $runningId = if ($running) { $running.Id } else { $null }
            if ($runningId -and $runningId -eq $r.Id) {
                if ($preferVersion -and $r.Version -eq $preferVersion) { continue }
                break
            }
            if ($running -and (Compare-Release $running $r) -ge 0) {
                if ($preferVersion -and $r.Version -eq $preferVersion) { continue }
                break
            }
            if ($preferVersion -and $r.Version -eq $preferVersion) {
                $newerInPrev = @($sorted | Where-Object {
                        if ((Compare-Release $_ $r) -le 0) { return $false }
                        $h = @(& $deps $_)
                        $p = @($h | Where-Object { $_.EnvironmentId -eq $previous.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending) | Select-Object -First 1
                        if (-not $p -or ((& $GetTaskState $p) -ne 'Success')) { return $false }
                        @($h | Where-Object { $_.EnvironmentId -eq $target.Id }).Count -eq 0
                    })
                if ($newerInPrev.Count -gt 0) {
                    $notes.Add("$Deployable $($r.Version) is held under the pipeline-change window before $($target.Name): kept as the candidate (issue #688); newer $(@($newerInPrev | ForEach-Object Version) -join ', ') in $($previous.Name) is not considered yet")
                } else {
                    $notes.Add("$Deployable $($r.Version) is held under the pipeline-change window before $($target.Name): kept as the candidate (issue #688)")
                }
            } elseif ($skipped) { $notes.Add("newer release ${skipped}: the older release $($r.Version) is considered for $($target.Name)") }
            return @{ Release = $r; Target = $target; Previous = $previous; RunningReleaseId = $runningId; Running = $running; RunningUnknown = $unknown; Notes = @($notes) }
        }
    }
    @{ Release = $null; Notes = @($notes) }
}

function Select-SignOff {
    # Only the Sign-off manual intervention of this deployment's task.
    param([object[]] $Interruptions, [string] $TaskId)
    @($Interruptions | Where-Object { $_.Type -eq 'ManualIntervention' -and $_.TaskId -eq $TaskId -and $_.Title -eq 'Sign-off' })
}
function Get-SignOffAction {
    # answer (take responsibility if needed, then submit), yield (a person holds it), answered, none (not there yet).
    param([object[]] $Interruptions, [string] $TaskId)
    $s = @(Select-SignOff -Interruptions $Interruptions -TaskId $TaskId)
    $pending = $s | Where-Object { $_.IsPending } | Select-Object -First 1
    if ($pending) {
        if ($pending.ResponsibleUserId -and -not $pending.HasResponsibility) { return @{ Action = 'yield'; Interruption = $pending } }
        return @{ Action = 'answer'; Interruption = $pending }
    }
    if (@($s).Count -gt 0) { return @{ Action = 'answered'; Interruption = $null } }
    @{ Action = 'none'; Interruption = $null }
}

function ConvertFrom-GitComparison {
    <# The comparison of the commit running in the next environment (base) with the release's commit, read from a clone of
       the application repository, so it has no commit or file cap (GitHub's compare answers 250 commits and 300 files at
       most: 2.4.1120 to 2.4.2060 of ui is 405 commits and 687 files). NameOnly: git diff --name-only --no-renames -z
       base...head (a rename is a deletion and an addition: both names count). Log: git log --format=%H%x1f%B%x1e base..head.
       Count: git rev-list --count base..head. Returns @{ Paths; Commits (sha, commit.message, as GET compare answers them);
       Status; Known; Reason }. #>
    param([string] $NameOnly, [string] $Log, [int] $Count, [string] $Status)
    $paths = @(($NameOnly ?? '') -split "`0" | ForEach-Object { $_.Trim("`r", "`n") } | Where-Object { $_ })
    $commits = @(($Log ?? '') -split [char] 0x1e | ForEach-Object {
            $parts = $_.TrimStart("`r", "`n") -split [char] 0x1f, 2
            if ($parts[0] -match '^[0-9a-f]{40}$') { [pscustomobject] @{ sha = $parts[0]; commit = [pscustomobject] @{ message = ($parts.Count -gt 1 ? $parts[1] : '') } } }
        })
    $reason = if ($commits.Count -ne $Count) { "$($commits.Count) of $Count commits read" }
    @{ Paths = $paths; Commits = $commits; Status = $Status; Known = ($null -eq $reason); Reason = $reason }
}

function Get-AppComparison {
    # Clones the application repository once per run (no blobs: trees and commits are enough for the paths), fetches a
    # commit it lacks, and compares. Status: identical, ahead, behind (the release's commit is an ancestor of the base) or
    # diverged. Throws when a read fails.
    param([string] $AppRepo, [string] $Directory, [string] $BaseSha, [string] $Sha)
    $PSNativeCommandUseErrorActionPreference = $false
    function Invoke-Git { $out = & git -C $Directory @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" }; $out }
    if (-not (Test-Path -LiteralPath (Join-Path $Directory '.git'))) {
        & git clone --quiet --filter=blob:none --no-checkout "https://github.com/$AppRepo.git" $Directory
        if ($LASTEXITCODE -ne 0) { throw "git clone of $AppRepo failed (exit $LASTEXITCODE)" }
    }
    foreach ($c in $BaseSha, $Sha) {
        & git -C $Directory cat-file -e "$c^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { Invoke-Git fetch --quiet --filter=blob:none origin $c | Out-Null }
    }
    function Test-Ancestor([string] $A, [string] $B) {
        & git -C $Directory merge-base --is-ancestor $A $B
        switch ($LASTEXITCODE) { 0 { $true } 1 { $false } default { throw "git merge-base --is-ancestor $A $B failed (exit $LASTEXITCODE)" } }
    }
    $status = if ($BaseSha -eq $Sha) { 'identical' } elseif (Test-Ancestor $Sha $BaseSha) { 'behind' } elseif (Test-Ancestor $BaseSha $Sha) { 'ahead' } else { 'diverged' }
    $names = (Invoke-Git -c core.quotePath=false diff --name-only --no-renames -z "$BaseSha...$Sha") -join "`n"
    $log = (Invoke-Git log --format=%H%x1f%B%x1e "$BaseSha..$Sha") -join "`n"
    $count = [int] (Invoke-Git rev-list --count "$BaseSha..$Sha")
    ConvertFrom-GitComparison -NameOnly $names -Log $log -Count $count -Status $status
}

function ConvertFrom-CommitPullsGraph {
    <# The answer of one batched GraphQL query (Get-CommitPulls): repository.c<i> is the commit Shas[i]. Returns, per sha,
       @{ Pulls (number, title, body, html_url, labels.name: as GET commits/<sha>/pulls answers them); Closing (pull
       request number -> @{ Repo; Number }); Error } where Error says why that commit's pull requests are not known (the
       commit is unknown, more pull requests or labels than the query read). #>
    param($Repository, [string[]] $Shas, [int] $MaxPulls = 5)
    $out = @{}
    for ($i = 0; $i -lt $Shas.Count; $i++) {
        $o = if ($Repository -and $Repository.PSObject.Properties["c$i"]) { $Repository."c$i" } else { $null }
        if (-not $o -or -not $o.PSObject.Properties['associatedPullRequests']) { $out[$Shas[$i]] = @{ Pulls = @(); Closing = @{}; Error = "commit $($Shas[$i]) not found" }; continue }
        $a = $o.associatedPullRequests
        if ([int] $a.totalCount -gt @($a.nodes).Count) { $out[$Shas[$i]] = @{ Pulls = @(); Closing = @{}; Error = "$($a.totalCount) pull requests of $($Shas[$i]) (more than $MaxPulls)" }; continue }
        $pulls = @(); $closing = @{}; $err = $null
        foreach ($p in @($a.nodes)) {
            if ([int] $p.labels.totalCount -gt @($p.labels.nodes).Count) { $err = "labels of #$($p.number) not read whole" }
            $pulls += [pscustomobject] @{ number = [int] $p.number; title = [string] $p.title; body = [string] $p.body; html_url = [string] $p.url; labels = @($p.labels.nodes | ForEach-Object { [pscustomobject] @{ name = [string] $_.name } }) }
            $closing[[int] $p.number] = @($p.closingIssuesReferences.nodes | ForEach-Object { @{ Repo = [string] $_.repository.nameWithOwner; Number = [int] $_.number } })
        }
        $out[$Shas[$i]] = @{ Pulls = $pulls; Closing = $closing; Error = $err }
    }
    $out
}

function Get-CommitPulls {
    # The pull requests of many commits in few GraphQL queries ($Batch commits each; one REST call per commit and one
    # GraphQL call per pull request would spend the run's token on a large comparison). A query that fails leaves its
    # commits out: their pull requests are not read (Get-HoldFacts waits).
    param([string] $AppRepo, [string[]] $Shas, [int] $Batch = 40, [int] $MaxPulls = 5)
    $owner, $name = $AppRepo.Split('/', 2)
    $all = @{}
    for ($i = 0; $i -lt $Shas.Count; $i += $Batch) {
        $chunk = @($Shas[$i..([Math]::Min($i + $Batch, $Shas.Count) - 1)])
        $fields = for ($j = 0; $j -lt $chunk.Count; $j++) {
            "c${j}: object(oid: `"$($chunk[$j])`") { ... on Commit { associatedPullRequests(first: $MaxPulls) { totalCount nodes { number title body url labels(first: 50) { totalCount nodes { name } } closingIssuesReferences(first: 50) { nodes { number repository { nameWithOwner } } } } } } }"
        }
        $q = "query(`$o: String!, `$r: String!) { repository(owner: `$o, name: `$r) { $($fields -join ' ') } }"
        try {
            $g = (& gh api graphql -f "query=$q" -f "o=$owner" -f "r=$name") | ConvertFrom-Json -Depth 30
            $part = ConvertFrom-CommitPullsGraph -Repository $g.data.repository -Shas $chunk -MaxPulls $MaxPulls
            foreach ($k in $part.Keys) { $all[$k] = $part[$k] }
        } catch { Write-Host "Pull requests of $($chunk.Count) commits not read: $($_.Exception.Message)" }
    }
    $all
}

function Get-RepoHeld {
    # Every issue and pull request of the application repository labelled Hold (case ignored), open or closed, by number:
    # one listing instead of one read per referenced item. Throws when a read fails.
    param([string] $AppRepo)
    $held = @{}
    $labels = @(& gh api "repos/$AppRepo/labels?per_page=100" --paginate --jq '.[].name')
    foreach ($l in @($labels | Where-Object { $_ -ieq 'Hold' })) {
        foreach ($line in @(& gh api "repos/$AppRepo/issues?labels=$([uri]::EscapeDataString($l))&state=all&per_page=100" --paginate --jq '.[] | [.number, .html_url] | @tsv')) {
            $n, $url = "$line" -split "`t", 2
            if ($n -match '^\d+$') { $held[[int] $n] = @{ Number = [int] $n; Url = $url; Labels = @($l) } }
        }
    }
    $held
}

function Get-ReferencedNumbers {
    # #N of the application repository and owner/repo#N of another one. AB#N (Azure Boards) is not a GitHub reference.
    param([string] $Text, [string] $DefaultRepo)
    foreach ($m in [regex]::Matches($Text, '(?<![\w/#])(?:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+))?#(\d+)\b')) {
        @{ Repo = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $DefaultRepo }); Number = [int] $m.Groups[2].Value }
    }
}

function Get-HoldFacts {
    <# Commits (sha, commit.message); GetPulls {param($sha)} -> pull requests (number, title, body, labels, html_url);
       GetClosing {param($pullNumber)} -> issue refs (@{Repo;Number}); GetItem {param($repo,$number)} -> @{Number;Url;Labels},
       or $null when there is no such item (ConvertFrom-IssueRead). Any scriptblock may throw: that becomes an entry of Unknown.
       RepoHeld (Get-RepoHeld): when given, the complete list of Repo's items labelled Hold, by number; a reference to Repo
       is then answered from it without a read, and only the references to other repositories count against Max. #>
    param([object[]] $Commits, [string] $Repo, [scriptblock] $GetPulls, [scriptblock] $GetClosing, [scriptblock] $GetItem, [int] $Max = 300, [hashtable] $RepoHeld = $null)
    $refs = [Collections.Generic.Dictionary[string, hashtable]]::new()
    $items = @{}; $unknown = [Collections.Generic.List[string]]::new()
    function Add-Ref($r) { $refs["$($r.Repo)#$($r.Number)"] = $r }
    foreach ($c in $Commits) {
        foreach ($r in @(Get-ReferencedNumbers -Text ([string] $c.commit.message) -DefaultRepo $Repo)) { Add-Ref $r }
        try { $pulls = @(& $GetPulls $c.sha) } catch { $unknown.Add("pull requests of $($c.sha) not read"); continue }
        foreach ($pr in $pulls) {
            $items["$Repo#$($pr.number)"] = @{ Number = $pr.number; Url = $pr.html_url; Labels = @($pr.labels | ForEach-Object name) }
            foreach ($r in @(Get-ReferencedNumbers -Text "$($pr.title) $($pr.body)" -DefaultRepo $Repo)) { Add-Ref $r }
            try { foreach ($r in @(& $GetClosing $pr.number)) { Add-Ref $r } } catch { $unknown.Add("closing references of #$($pr.number) not read") }
        }
    }
    $todo = @($refs.Keys | Where-Object { -not $items.ContainsKey($_) } | Sort-Object)
    if ($null -ne $RepoHeld) {
        foreach ($k in @($todo | Where-Object { $refs[$_].Repo -ieq $Repo })) { $n = [int] $refs[$k].Number; if ($RepoHeld.ContainsKey($n)) { $items[$k] = $RepoHeld[$n] } }
        $todo = @($todo | Where-Object { $refs[$_].Repo -ine $Repo })
    }
    if ($todo.Count -gt $Max) { $unknown.Add("$($todo.Count) referenced items (more than $Max)"); $todo = @($todo | Select-Object -First $Max) }
    foreach ($k in $todo) {
        $r = $refs[$k]
        try { $it = & $GetItem $r.Repo $r.Number; if ($null -ne $it) { $items[$k] = $it } } catch { $unknown.Add("$k not read") }
    }
    @{ Items = @($items.Values); Unknown = @($unknown) }
}

function ConvertFrom-IssueRead {
    <# The answer of gh api repos/<Repo>/issues/<Number> (exit code, standard output): @{ Number; Url; Labels }; $null when the
       application repository (AppRepo, public, read by this run already) answers 404: no such issue or pull request there,
       nothing to hold. Throws on any other failure, a 404 of another repository included (it may be one that is not readable). #>
    param([int] $ExitCode, [string] $Output, [string] $Repo, [int] $Number, [string] $AppRepo)
    $j = try { $Output | ConvertFrom-Json -Depth 30 } catch { $null }
    if ($ExitCode -ne 0) {
        $status = if ($j -and $j.PSObject.Properties['status']) { [string] $j.status } else { '' }
        if ($status -eq '404' -and $Repo -ieq $AppRepo) { return $null }
        throw "$Repo#$Number not read (gh exit $ExitCode$(if ($status) { ", HTTP $status" }))"
    }
    if (-not $j -or -not $j.PSObject.Properties['html_url']) { throw "$Repo#$Number not read (no issue in the answer)" }
    @{ Number = $Number; Url = $j.html_url; Labels = @($j.labels | ForEach-Object name) }
}

function Read-State {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{} }
    try { $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable; if ($s -is [hashtable]) { return $s } } catch { }
    Write-Host "State file $Path is corrupt: starting with an empty one."
    @{}
}

function Get-EvidenceHash([string] $Text) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).Substring(0, 16).ToLowerInvariant() }

function Format-PromotionReason {
    # The Sign-off note of a promotion.
    param([hashtable] $Decision, [string] $Previous, [string] $RunUrl, [switch] $Recovered, [int] $OverrideMinutes = $PipelineOverrideMinutes)
    $how = if ($Recovered) { 'Auto-promoted (recovered)' } else { 'Auto-promoted' }
    $common = "checks green ($(@($Decision.Passed).Count) passed), deployment and health ok in $Previous"
    if ($Decision.Reason -eq 'security-advisory-override') {
        return "$how immediately: security-advisory dependency fix skipped the project-file hold (owner rule 2026-11-11), master green, no other flag; $common, no Hold label; run $RunUrl"
    }
    if ($Decision.Reason -eq 'pipeline-override') {
        return "$how after $OverrideMinutes minutes: pipeline change accepted (owner rule 2026-10-14), master green, no other flag; $common, no Hold label; run $RunUrl"
    }
    "${how}: no flag. $common, no pipeline change, no Hold label; run $RunUrl"
}

function Format-HeldEvidence {
    param([string] $Version, [string] $Sha, [string] $Target, [object[]] $Flags, [string] $DeploymentNote = '', [string] $OverrideNote = '', [string] $Name = $Deployable)
    $b = "$Name $Version (commit $Sha) is not promoted to $Target automatically. Flags:`n"
    foreach ($f in $Flags) { $b += "`n**$($f.Flag)**`n" + (($f.Evidence | ForEach-Object { "- $_" }) -join "`n") + "`n" }
    if ($OverrideNote) { $b += "`n$OverrideNote`n" }
    $b += "`nRules: health needs no read since the deployment finished that is not Healthy, two Healthy reads at least 5 minutes apart, the later one at least 10 minutes after the deployment finished; an unreachable or timed-out read is retried up to 3 times, 20 to 30 seconds apart, and flags only when all four attempts fail."
    if ($DeploymentNote) { $b += "`n$DeploymentNote" } else { $b += "`nNo deployment was created. A person promotes it in Octopus (the Sign-off waits for them)." }
    $b
}

function Get-HeldTitle([string] $Version, [string] $Environment, [string] $Name = $Deployable) { "$Name $Version held before $Environment" }
function Get-HeldIssueTitle {
    # Title of the release-held issue: no-commit holds use a fixed title without the environment (#621); others name the target.
    param([string] $Version, [string] $Environment, [object[]] $Flags, [string] $Name = $Deployable)
    if (Test-NoCommitHoldFlags $Flags) { Get-NoCommitHeldTitle $Version $Name } else { Get-HeldTitle $Version $Environment $Name }
}
function Get-HeldTitleParts {
    # Version and Environment of a held issue of this deployable; $null for any other title (another deployable's too).
    param([string] $Title, [string] $Name = $Deployable)
    if ($Title -cmatch ('^' + [regex]::Escape($Name) + ' (\S+) held before (\S+)$')) { @{ Version = $Matches[1]; Environment = $Matches[2] } }
}
function Test-PipelineChangeHoldBody([string] $Body) {
    # True when a release-held issue body lists Pipeline or infra change as its only flag heading (issue #688: keep that
    # candidate for the 60-minute window). Format-HeldEvidence writes **Flag** for every flag; a hold that also lists
    # Deployment or health failed, Red build or tests, Hold label, etc. must not pin the version — newest-first resumes.
    $flagHeadings = @([regex]::Matches([string] $Body, '(?m)^\*\*([^*]+)\*\*') | ForEach-Object { $_.Groups[1].Value })
    $flagHeadings.Count -eq 1 -and $flagHeadings[0] -eq 'Pipeline or infra change'
}
function Get-HeldPipelinePrefer {
    <# Open pipeline-only holds of this deployable as PreferHeld for Select-Candidate: @{ Version; Environment }.
       Oldest version per environment so a later hold does not restart the clock (issue #688). A hold whose body lists
       any other flag is skipped so a newer healthy release can become the candidate. #>
    param([object[]] $HeldIssues, [string] $Name = $Deployable)
    $byEnv = @{}
    foreach ($hi in @($HeldIssues)) {
        $parts = Get-HeldTitleParts ([string] $hi.title) $Name
        if (-not $parts) { continue }
        if (-not (Test-PipelineChangeHoldBody ([string] $hi.body))) { continue }
        $envName = [string] $parts.Environment
        if (-not $byEnv.ContainsKey($envName)) { $byEnv[$envName] = [Collections.Generic.List[string]]::new() }
        $byEnv[$envName].Add([string] $parts.Version)
    }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($envName in @($byEnv.Keys | Sort-Object)) {
        $ranked = @($byEnv[$envName] | Sort-Object { $v = ConvertTo-ReleaseVersion $_; if ($v) { $v } else { [version]::new(0, 0, 0) } }, { $_ })
        $out.Add(@{ Version = [string] $ranked[0]; Environment = $envName })
    }
    @($out)
}
function Get-StateKey([string] $DeploymentId, [string] $Name = $Deployable) {
    # Health reads are kept per deployable and deployment ("dashboard/Deployments-12"); Read-StateReads also finds ui's
    # reads stored before the key named the deployable (bare "Deployments-12").
    "$Name/$DeploymentId"
}
function Read-StateReads([hashtable] $State, [string] $DeploymentId, [string] $Name = $Deployable) {
    $k = Get-StateKey $DeploymentId $Name
    if ($State.ContainsKey($k)) { return @($State[$k]) }
    if ($Name -eq 'ui' -and $State.ContainsKey($DeploymentId)) { return @($State[$DeploymentId]) }
    @()
}

function Get-Commit($release) {
    # Release notes name the commit as "Build <run> of <sha>, committed <time>" (an app) or
    # "Commit <sha>: <message>" (cmdemo1-system, .github/workflows/system.yml). Only the app form matched before
    # (#574): system 1.0.183 stayed in tdd and never reached uat, so azureExcludeDeployables never deleted the
    # uat aisf/fworker apps and fwrunner jobs. Same extraction as scripts/write-delivery.ps1 Get-Commit.
    if (-not $release) { return $null }
    $notes = [string] $release.ReleaseNotes
    if ($notes -match '(?i)(?:^|\b)(?:commit|of)\s+([0-9a-f]{40})\b') { return $Matches[1] }
    $any = [regex]::Match($notes, '\b[0-9a-f]{40}\b').Value
    if ($any) { return $any }
    $null
}

function Get-ActiveBusyItems {
    # Active and Cancelling Octopus tasks as busy items. Calls script-scope Get-OctopusAll / Invoke-Octopus and
    # reads $space: do not wrap callers in GetNewClosure (#589) or those names are not found.
    # Each item carries TaskId, State, and (for deployments) ReleaseVersion so Get-BusyReason can name them (#701).
    $active = @(Get-OctopusAll "/api/$space/tasks?active=true") + @(Get-OctopusAll "/api/$space/tasks?states=Cancelling")
    $items = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($t in @($active | Sort-Object Id -Unique)) {
        $ids.Add([string] $t.Id)
        $state = [string] (Get-BusyItemProperty $t 'State')
        if ($t.Name -eq 'Deploy') {
            $d = Invoke-Octopus "/api/$space/deployments/$($t.Arguments.DeploymentId)"
            $version = $null
            if ($d.ReleaseId) {
                $version = (Invoke-Octopus "/api/$space/releases/$($d.ReleaseId)").Version
            }
            $items.Add(@{ Kind = 'deployment'; ProjectId = $d.ProjectId; EnvironmentId = $d.EnvironmentId; Deployment = $d; TaskId = $t.Id; State = $state; ReleaseVersion = $version; SignOffRefused = $false })
        } elseif ($t.Name -eq 'RunbookRun') {
            $d = Invoke-Octopus "/api/$space/runbookRuns/$($t.Arguments.RunbookRunId)"
            $items.Add(@{ Kind = 'runbook'; ProjectId = $d.ProjectId; EnvironmentId = $d.EnvironmentId; TaskId = $t.Id; State = $state; SignOffRefused = $false })
        }
    }
    @{ Items = @($items); ActiveTaskIds = @($ids) }
}

function Get-BusyReleaseVersion {
    # Release version for a busy deployment item; uses script-scope $releaseVersionCache / Invoke-Octopus / $space.
    # Prefer ReleaseVersion already filled by Get-ActiveBusyItems (#701).
    param($b)
    $existing = Get-BusyItemProperty $b 'ReleaseVersion'
    if ($existing) { return $existing }
    $rid = $b.Deployment.ReleaseId
    if (-not $releaseVersionCache.ContainsKey($rid)) {
        $releaseVersionCache[$rid] = (Invoke-Octopus "/api/$space/releases/$rid").Version
    }
    $releaseVersionCache[$rid]
}

function Set-BusyItemsSignOffRefused([object[]] $Items) {
    # Marks refused-Sign-off holds on busy items. Named so wait-retry does not need GetNewClosure (#583 / #589).
    Set-SignOffRefusedOnBusyItems -Items $Items -HeldIssues $heldIssues -ProjectIdByDeployableName $projectIdByDeployable `
        -EnvironmentIdByName $environmentIdByName -GetReleaseVersion ${function:Get-BusyReleaseVersion}
}

function Get-ActiveBusyItemsMarked {
    # Re-list active tasks and re-apply refused-Sign-off marks (runbook wait-retry path).
    $listed = Get-ActiveBusyItems
    Set-BusyItemsSignOffRefused -Items $listed.Items
    $listed
}

function Get-ContainerAddress($Addresses, [string] $EnvironmentName, [string] $DeployableName) {
    # Strict-mode-safe lookup in status/containers.json environments. That file lists only container apps (ui,
    # dashboard, …): system has no address. A missing environment or deployable is '' (address unknown), not a throw.
    if ($null -eq $Addresses -or -not $EnvironmentName -or -not $DeployableName) { return '' }
    $envObj = $null
    if ($Addresses -is [System.Collections.IDictionary]) {
        if ($Addresses.Contains($EnvironmentName)) { $envObj = $Addresses[$EnvironmentName] }
    }
    else {
        $envProp = $Addresses.PSObject.Properties[$EnvironmentName]
        if ($null -ne $envProp) { $envObj = $envProp.Value }
    }
    if ($null -eq $envObj) { return '' }
    if ($envObj -is [System.Collections.IDictionary]) {
        if ($envObj.Contains($DeployableName)) { return [string] $envObj[$DeployableName] }
        return ''
    }
    $depProp = $envObj.PSObject.Properties[$DeployableName]
    if ($null -eq $depProp -or $null -eq $depProp.Value) { return '' }
    return [string] $depProp.Value
}

function Read-MasterStateOnce {
    # One read of the application repository's default-branch head and its checks (no wait). Any failure: unknown.
    # Calls Invoke-Gh / Get-CommitChecks (defined after LoadOnly); the harness injects ReadAgain on Read-MasterState.
    try {
        $branch = [string] (Invoke-Gh @("repos/$appRepo")).default_branch
        if (-not $branch) { throw 'no default branch' }
        $head = [string] (Invoke-Gh @("repos/$appRepo/branches/$branch")).commit.sha
        if ($head -notmatch '^[0-9a-f]{40}$') { throw "no head commit of $branch" }
        $m = Get-MasterState -Checks @(Get-CommitChecks $head)
        @{ State = $m.State; Evidence = @($m.Evidence); Sha = $head; Branch = $branch }
    } catch { @{ State = 'unknown'; Evidence = @("read failed: $($_.Exception.Message)"); Sha = $null; Branch = $null } }
}

function Read-MasterState {
    # The head commit of the application repository's default branch, and its checks. When only pending (none failed),
    # wait in this run and poll until green, red, or the timeout (issue #697), capped by the job-time budget (PR #698).
    # Any failure: unknown. Pause / PollSeconds / TimeoutSeconds / Deadline / GetNow / WriteLog / ReadAgain are
    # injectable so tests do not sleep or call GitHub.
    param(
        [scriptblock] $ReadAgain = $null,
        [scriptblock] $Pause = $MasterPendingPause,
        [int] $PollSeconds = $MasterPendingPollSeconds,
        [int] $TimeoutSeconds = $MasterPendingTimeoutSeconds,
        [scriptblock] $WriteLog = { param([string] $Message) Write-Host $Message },
        $Deadline = $(Get-MasterPendingDeadline),
        [scriptblock] $GetNow = { [datetime]::UtcNow }
    )
    $once = if ($ReadAgain) { $ReadAgain } else { { Read-MasterStateOnce } }
    $result = & $once
    if ($result.State -eq 'pending') {
        $result = Wait-MasterPendingClear -Initial $result -ReadAgain $once -Pause $Pause `
            -PollSeconds $PollSeconds -TimeoutSeconds $TimeoutSeconds -WriteLog $WriteLog `
            -Deadline $Deadline -GetNow $GetNow
    }
    $result
}

function Complete-AutoPromoteSuccess {
    # Said as an exit code: GitHub Actions' pwsh shell appends `exit $LASTEXITCODE` to every step
    # (ScriptHandlerHelpers). A native gh/git call whose non-zero was expected and handled
    # (merge-base --is-ancestor, issue 404) leaves $LASTEXITCODE at 1; without this, a successful
    # promote still fails the step after "Signed off" (#646).
    exit 0
}

if ($LoadOnly) { return }

# --- Running ------------------------------------------------------------------------------------------------------
function Say([string] $m) { Write-Host $m }
function Get-Utc($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetimeoffset]) { return $v.UtcDateTime }
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    [datetimeoffset]::Parse([string] $v, [cultureinfo]::InvariantCulture).UtcDateTime
}

# The repository root: two folders above this script. Resolved here, not as the parameter's default: in the
# workflow's pwsh step $PSScriptRoot was empty while the parameters were bound (run 38516692223).
if (-not $Root) { $Root = if ($PSScriptRoot) { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) } else { (Get-Location).Path } }
$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$octopus = ([string] $system.octopus.url).TrimEnd('/')
$space = [string] $system.octopus.spaceId
$ownRepo = "$($system.system.githubOrg)/$($system.system.repository)"
$app = (@($system.deployables | Where-Object { $_.name -eq $Deployable }) | Select-Object -First 1)
# system is the system repository's own Octopus project (write-delivery.ps1 treats it the same way); every other
# name is a deployables[] entry.
if ($Deployable -eq 'system') { $appRepo = $ownRepo }
elseif (-not $app) { throw "deployable $Deployable is not in system.json deployables" }
else { $appRepo = "$($system.system.githubOrg)/$($app.repository)" }
$appClone = Join-Path ($env:RUNNER_TEMP ? $env:RUNNER_TEMP : [IO.Path]::GetTempPath()) "ui-auto-promote-$Deployable-$PID"
if (-not $env:OCTOPUS_ACCESS_TOKEN -and -not $env:OCTOPUS_API_KEY) { throw 'no Octopus credential: OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login) or OCTOPUS_API_KEY' }

function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    $h = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    $a = @{ Uri = "$octopus$Path"; Headers = $h; Method = $Method }
    if ($null -ne $Body) { $a.Body = ($Body | ConvertTo-Json -Depth 8); $a.ContentType = 'application/json' }
    Invoke-RestMethod @a | ForEach-Object { $_ }
}
function Get-OctopusAll([string] $Path) {
    $all = @(); $skip = 0; $sep = if ($Path.Contains('?')) { '&' } else { '?' }
    do {
        $r = Invoke-Octopus "$Path${sep}skip=$skip&take=100"
        $all += @($r.Items); $skip += 100
    } while ($skip -lt $r.TotalResults)
    if ($all.Count -lt $r.TotalResults) { throw "listing $Path is incomplete ($($all.Count) of $($r.TotalResults))" }
    $all
}
function Invoke-Gh([string[]] $Arguments) { (& gh api @Arguments) | ConvertFrom-Json -Depth 30 }

function Submit-SignOff {
    # Answers a pending Sign-off. Returns signed|yielded|answered|none|refused. Refused (permission denied on
    # take-responsibility or submit) does not throw: the caller records a hold (#569). Every other error rethrows.
    param(
        [string] $TaskId,
        [string] $Reason,
        [int] $WaitSeconds = 900,
        [string] $ProjectName = '',
        [string] $ReleaseVersion = '',
        [string] $EnvironmentName = ''
    )
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $list = Invoke-Octopus "/api/$space/interruptions?regarding=$TaskId"
        $a = Get-SignOffAction -Interruptions @($list.Items) -TaskId $TaskId
        switch ($a.Action) {
            'yield' { Say "A person holds the Sign-off ($($a.Interruption.Id)): theirs."; return 'yielded' }
            'answered' { Say 'Sign-off already answered.'; return 'answered' }
            'answer' {
                $interruptId = $a.Interruption.Id
                $needTake = -not $a.Interruption.HasResponsibility
                $outcome = Invoke-SignOffOctopusCalls -Space $space -InterruptionId $interruptId -Reason $Reason -NeedTakeResponsibility $needTake
                if ($outcome -eq 'refused') {
                    Say "WARNING: Octopus refused Sign-off permission for project $ProjectName release $ReleaseVersion in $EnvironmentName (interruption $interruptId)."
                    return 'refused'
                }
                Say "Signed off ($interruptId)."; return 'signed'
            }
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    Say 'No Sign-off appeared.'
    'none'
}

# Environments, project, releases.
$envs = @(Invoke-Octopus "/api/$space/environments/all" | Sort-Object SortOrder)
$allProjects = @(Invoke-Octopus "/api/$space/projects/all")
$project = (@($allProjects | Where-Object { $_.Name -eq "$slug-$Deployable" }) | Select-Object -First 1)
if (-not $project) { throw "project $slug-$Deployable not found" }
$first = $envs[0]
$releases = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/releases?take=$ReleaseWindow").Items)
$taskCache = @{}
function Get-TaskState($d) { if (-not $taskCache.ContainsKey($d.TaskId)) { $taskCache[$d.TaskId] = Invoke-Octopus "/api/tasks/$($d.TaskId)" }; $taskCache[$d.TaskId].State }
function Get-ReleaseDeployments($releaseId) { Get-OctopusAll "/api/$space/releases/$releaseId/deployments" }
function Get-RunningOutsideList($target) {
    # The release running in the target when none of the listed releases ran there (issue #314).
    Get-RunningReleaseByEnvironment -Target $target `
        -GetEnvironmentDeployments { param($environmentId, $take) $r = Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$environmentId&take=$take"; @{ Items = @($r.Items); Total = $r.TotalResults } } `
        -GetRelease { param($releaseId) Invoke-Octopus "/api/$space/releases/$releaseId" } `
        -GetTaskState { param($d) Get-TaskState $d }
}
$heldIssues = @(& gh issue list -R $ownRepo --label release-held --state open --json number,title,body --limit 50 | ConvertFrom-Json)
# Every run lists open holds (including refused Sign-offs) so they stay visible until cleared (#569).
Say "Open holds: $(if ($heldIssues.Count -eq 0) { 'none' } else { $heldIssues.Count })"
foreach ($hi in $heldIssues) { Say "  hold #$($hi.number): $($hi.title)" }
$addresses = try { (Invoke-RestMethod "https://raw.githubusercontent.com/$ownRepo/status/containers.json").environments } catch { $null }
$state = Read-State $StatePath
function Save-State {
    if (-not $StatePath) { return }
    $cut = [datetime]::UtcNow.AddDays(-2)
    $keep = @{}
    foreach ($k in $state.Keys) { $r = @($state[$k]); if ($r.Count -gt 0 -and (Get-Utc $r[-1].at) -gt $cut) { $keep[$k] = $r } }
    $keep | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath
}

function Get-CommitChecks([string] $Sha) {
    # Check runs (paged) and commit statuses of a commit of the application repository; an incomplete list adds a pending entry.
    # ui-auto-promote's own runs are not a result of the commit (Test-PromoterCheckRun). The check-run payload has no
    # workflow name, so each Actions run id is read once. A read that fails is counted, not ignored.
    $checks = [Collections.Generic.List[object]]::new(); $page = 1; $ignored = 0
    $workflowByRun = @{}
    do {
        $r = Invoke-Gh @("repos/$appRepo/commits/$Sha/check-runs?per_page=100&page=$page")
        foreach ($c in @($r.check_runs)) {
            if (Test-AgentCheckRun ([string] $c.name) ([string] $c.app.slug)) { $ignored++; continue }
            $runId = Get-ActionsRunId ([string] $c.html_url)
            $workflowName = ''
            $workflowPath = ''
            if ($runId) {
                if (-not $workflowByRun.ContainsKey($runId)) {
                    $workflowByRun[$runId] = @{ Name = ''; Path = '' }
                    try {
                        $run = Invoke-Gh @("repos/$appRepo/actions/runs/$runId")
                        $workflowByRun[$runId] = @{ Name = [string] $run.name; Path = [string] $run.path }
                    }
                    catch {
                        # Fail closed: an unreadable workflow is not treated as the promoter.
                    }
                }
                $workflowName = [string] $workflowByRun[$runId].Name
                $workflowPath = [string] $workflowByRun[$runId].Path
            }
            if (Test-PromoterCheckRun -WorkflowName $workflowName -WorkflowPath $workflowPath) { $ignored++; continue }
            $checks.Add(@{ Name = $c.name; State = ConvertTo-CheckState $c.status $c.conclusion; Url = $c.html_url })
        }
        $page++
    } while (@($r.check_runs).Count -eq 100 -and $page -le 10)
    if ($r.total_count -gt ($checks.Count + $ignored)) { $checks.Add(@{ Name = "check list incomplete ($($checks.Count) of $($r.total_count))"; State = 'pending'; Url = '' }) }
    $s = Invoke-Gh @("repos/$appRepo/commits/$Sha/status?per_page=100")
    foreach ($c in @($s.statuses)) { $checks.Add(@{ Name = $c.context; State = ConvertTo-StatusState $c.state; Url = $c.target_url }) }
    if ($s.total_count -gt @($s.statuses).Count) { $checks.Add(@{ Name = 'status list incomplete'; State = 'pending'; Url = '' }) }
    $checks
}

function Get-Evaluation {
    # RunningUnknown: why the release running in the target could not be determined (it then names no base commit).
    # No commit in the release notes: hold (issue #621), never throw and never promote.
    param($Release, $Target, $Previous, $RunningRelease, [string] $RunningUnknown = '')
    $commitOrHold = Get-EvaluationCommitOrHold $Release -TargetName ([string] $Target.Name)
    if ($commitOrHold.Hold) {
        $h = $commitOrHold.Hold
        return @{ Behind = $false; Sha = $h.Sha; BaseSha = $null; Decision = $h.Decision }
    }
    $sha = $commitOrHold.Sha
    $facts = @{ HoldUnknown = @() }

    # 1. Checks
    $checks = @(Get-CommitChecks $sha)

    # 2. Previous deployment: state, log, health
    $prevDeployment = (@(Get-ReleaseDeployments $Release.Id | Where-Object { $_.EnvironmentId -eq $Previous.Id } | Sort-Object { Get-Utc $_.Created } -Descending) | Select-Object -First 1)
    $prevTask = Invoke-Octopus "/api/tasks/$($prevDeployment.TaskId)"
    $finished = Get-Utc $prevTask.CompletedTime
    $warned = @((Invoke-Octopus "/api/tasks/$($prevTask.Id)/details?verbose=false").ActivityLogs[0].Children | Where-Object { $_.Status -eq 'SuccessWithWarning' } | ForEach-Object Name)
    $raw = try { [string] (Invoke-Octopus "/api/tasks/$($prevTask.Id)/raw") } catch { '' }
    $findings = @(Get-LogFindings -Raw $raw -TaskId $prevTask.Id -WarnedSteps $warned)
    $key = Get-StateKey ([string] $prevDeployment.Id)
    $stored = @(Read-StateReads $state ([string] $prevDeployment.Id))
    $reads = @($stored | ForEach-Object { @{ At = Get-Utc $_.at; Status = [string] $_.status } })
    $prevAddress = Get-ContainerAddress $addresses ([string] $Previous.Name) $Deployable
    $healthRequired = [string] $Settings.HealthRead -ne 'none'
    $addressKnown = [bool] $prevAddress
    function Read-Health {
        $uri = "$prevAddress$($Settings.HealthPath)"
        $reader = switch ($Settings.HealthRead) {
            'overallStatus' { { (Invoke-RestMethod -Uri $uri -TimeoutSec 30 -SkipHttpErrorCheck).overallStatus }.GetNewClosure() }
            # The function travels as a value: a closure does not see the script's own functions.
            'ready' { $toReady = ${function:ConvertTo-ReadyStatus}; { $w = Invoke-WebRequest -Uri $uri -TimeoutSec 30 -SkipHttpErrorCheck; & $toReady -StatusCode ([int] $w.StatusCode) -Body ([string] $w.Content) }.GetNewClosure() }
            'httpOk' { $toHttp = ${function:ConvertTo-HttpOkStatus}; { $w = Invoke-WebRequest -Uri $uri -TimeoutSec 30 -SkipHttpErrorCheck; & $toHttp -StatusCode ([int] $w.StatusCode) }.GetNewClosure() }
            default { throw "HealthRead $($Settings.HealthRead) of $Deployable is not known (overallStatus, ready, httpOk or none)" }
        }
        $r = Invoke-HealthRead -Reader $reader
        if ($r.Attempts -gt 1) { Say "Health read: $($r.Status) after $($r.Attempts) attempts." }
        @{ At = [datetime]::UtcNow; Status = $r.Status }
    }
    if ($healthRequired -and $addressKnown -and $prevTask.State -eq 'Success') {
        $reads += Read-Health
        $now = [datetime]::UtcNow
        if ((Get-HealthVerdict -Finished $finished -Now $now -Reads $reads) -eq 'wait' -and $now -ge $finished.AddMinutes(10) -and @($reads | Where-Object { $_.At -ge $finished }).Count -lt 2) {
            Say "Waiting $HealthPauseSeconds s for the second health read."
            Start-Sleep -Seconds $HealthPauseSeconds
            $reads += Read-Health
        }
        $state[$key] = @($reads | ForEach-Object { @{ at = $_.At.ToString('o'); status = $_.Status } })
        Save-State
    }

    # 3 and 4. Changes since the commit running in the target
    $baseSha = $null
    $baseAddress = Get-ContainerAddress $addresses ([string] $Target.Name) $Deployable
    $buildPath = [string] $Settings.BuildPath
    if ($baseAddress -and $buildPath) { $baseSha = try { [string] (Invoke-RestMethod "$baseAddress$buildPath" -TimeoutSec 30).commit } catch { $null } }
    if ($baseSha -notmatch '^[0-9a-f]{40}$') { $baseSha = Get-Commit $RunningRelease }
    $pathsKnown = $false; $paths = @(); $holdItems = @(); $commitPulls = @{}
    $pathsReason = if ($RunningUnknown) { "no base commit: /_build names none and $RunningUnknown" } else { 'no base commit: neither /_build nor the running release names one' }
    if ($baseSha -match '^[0-9a-f]{40}$') {
        try {
            $merged = Get-AppComparison -AppRepo $appRepo -Directory $appClone -BaseSha $baseSha -Sha $sha
            $paths = $merged.Paths; $pathsKnown = $merged.Known; $pathsReason = $merged.Reason
            Say "Comparison $baseSha...${sha}: $($merged.Status), $(@($merged.Commits).Count) commits, $(@($paths).Count) paths."
            if ($merged.Status -eq 'behind') { return @{ Behind = $true; Sha = $sha; BaseSha = $baseSha } }
            $commitPulls = Get-CommitPulls -AppRepo $appRepo -Shas @($merged.Commits | ForEach-Object sha)
            $closingRefs = @{}; foreach ($e in $commitPulls.Values) { foreach ($n in $e.Closing.Keys) { $closingRefs[$n] = $e.Closing[$n] } }
            $repoHeld = try { Get-RepoHeld -AppRepo $appRepo } catch { Say "The Hold items of $appRepo could not be listed ($($_.Exception.Message)): each is read."; $null }
            $hold = Get-HoldFacts -Commits $merged.Commits -Repo $appRepo -RepoHeld $repoHeld `
                -GetPulls { param($c) $e = $commitPulls[$c]; if (-not $e) { throw "pull requests of $c not read" }; if ($e.Error) { throw $e.Error }; $e.Pulls }.GetNewClosure() `
                -GetClosing { param($n) if (-not $closingRefs.ContainsKey([int] $n)) { throw "closing references of #$n not read" }; $closingRefs[[int] $n] }.GetNewClosure() `
                -GetItem { param($repo, $n)
                    # A failed gh answers its exit code here (not an exception), so a 404 can be told from other failures.
                    $PSNativeCommandUseErrorActionPreference = $false
                    $out = (& gh api "repos/$repo/issues/$n" 2>$null) -join "`n"
                    ConvertFrom-IssueRead -ExitCode $LASTEXITCODE -Output $out -Repo $repo -Number $n -AppRepo $appRepo }
            $holdItems = $hold.Items; $facts.HoldUnknown = $hold.Unknown
        } catch { $pathsKnown = $false; $pathsReason = "comparison failed: $($_.Exception.Message)" }
    }
    $facts += @{ Checks = $checks; PathsKnown = $pathsKnown; PathsReason = $pathsReason; Paths = $paths; HoldItems = $holdItems; PreviousState = $prevTask.State
        LogFindings = $findings; Finished = $finished; Now = [datetime]::UtcNow; HealthReads = $reads; HealthAddressKnown = $addressKnown
        HealthRequired = $healthRequired }
    $decision = Get-PromotionDecision -Facts $facts
    if (Test-PipelineOnly -Flags @($decision.Flags) -Facts $facts) {
        # The pipeline-only override: master of the application repository, read only when it can matter.
        # Security-advisory exemption (owner 2026-11-11): skip the 60-minute wait when every flag-3 path is a
        # package-version-only GHSA fix; fail closed when diffs or PR lookup are unreadable.
        $m = Read-MasterState -WriteLog { param([string] $Message) Say $Message }
        Say "Master ($($m.Branch) $($m.Sha)): $($m.State)$(if (@($m.Evidence).Count) { ': ' + (@($m.Evidence) -join ', ') })"
        $masterEvidence = if ($m.State -eq 'unknown') { @('read failed') } else { @($m.Evidence | Select-Object -First 5) }
        $pipelineEvidence = @(Get-PipelineEvidence -Paths @($facts.Paths))
        $sa = Read-SecurityAdvisoryOverride -Evidence $pipelineEvidence -GetPullForPath {
            param($path)
            $PSNativeCommandUseErrorActionPreference = $false
            $shas = @(& git -C $appClone -c core.quotePath=false log --format=%H "$baseSha..$sha" -- $path 2>$null)
            if ($LASTEXITCODE -ne 0) { throw "commits of $path not read (git exit $LASTEXITCODE)" }
            if ($shas.Count -eq 0) { throw "no commit of $path between $baseSha and $sha" }
            $pull = $null
            foreach ($c in $shas) {
                $e = $commitPulls[$c]
                if (-not $e) { throw "pull requests of $c not read" }
                if ($e.Error) { throw $e.Error }
                $prs = @($e.Pulls)
                if ($prs.Count -eq 0) { throw "no pull request for commit $c of $path" }
                foreach ($p in $prs) {
                    if (-not $pull) { $pull = $p }
                    elseif ([int] $p.number -ne [int] $pull.number) { throw "$path has commits from #$($pull.number) and #$($p.number)" }
                }
            }
            $PSNativeCommandUseErrorActionPreference = $false
            $raw = (& gh api "repos/$appRepo/pulls/$($pull.number)/files" --paginate 2>$null) -join "`n"
            if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "files of pull request #$($pull.number) not read (gh exit $LASTEXITCODE)" }
            $files = @(try { $raw | ConvertFrom-Json -Depth 20 } catch { throw "files of pull request #$($pull.number) not read (JSON)" })
            @{
                Number = [int] $pull.number; Title = [string] $pull.title; Body = [string] $pull.body
                Files  = @($files | ForEach-Object {
                        $patch = if ($_.PSObject.Properties.Name -contains 'patch') { [string] $_.patch } else { $null }
                        @{ Filename = [string] $_.filename; Patch = $patch }
                    })
            }
        }.GetNewClosure()
        if ($sa.Qualifies) {
            Say "Security-advisory override: $(@($sa.GhsaIds) -join ', ') on $(@($sa.Paths) -join ', ') (skipping the ${PipelineOverrideMinutes}-minute project-file hold)."
        } elseif ($sa.Why -and $sa.Why -ne 'no flagged path') {
            Say "Security-advisory override not applied: $($sa.Why)"
        }
        $facts['SecurityAdvisoryOverride'] = $sa
        $facts['PipelineOverride'] = @{ Minutes = ($facts.Now - $finished).TotalMinutes; MasterState = $m.State; MasterEvidence = $masterEvidence }
        $decision = Get-PromotionDecision -Facts $facts
    }
    @{ Behind = $false; Sha = $sha; BaseSha = $baseSha; Decision = $decision }
}

function Set-HeldIssue {
    param($Release, $Target, $Evaluation, [string] $DeploymentNote = '')
    $title = Get-HeldIssueTitle -Version $Release.Version -Environment $Target.Name -Flags @($Evaluation.Decision.Flags)
    $evidence = Format-HeldEvidence -Version $Release.Version -Sha $Evaluation.Sha -Target $Target.Name -Flags $Evaluation.Decision.Flags -DeploymentNote $DeploymentNote -OverrideNote ([string] $Evaluation.Decision.Note)
    $hash = Get-EvidenceHash $evidence
    $body = "$evidence`n`nRun $RunUrl`n<!-- evidence:$hash -->"
    Say $evidence
    if ($DryRun) { return }
    & gh label create release-held --color B60205 --description 'A release is held before an environment by the automatic promotion' -R $ownRepo --force | Out-Null
    $existing = (@($heldIssues | Where-Object { $_.title -eq $title }) | Select-Object -First 1)
    if (-not $existing) { & gh issue create -R $ownRepo --title $title --label release-held --body $body | Out-Null }
    elseif ($existing.body -notmatch "evidence:$hash") { & gh issue edit $existing.number -R $ownRepo --body $body | Out-Null }
    else { Say "Issue #$($existing.number) already says this." }
}

function Close-HeldIssues {
    # Closes an issue when its release got a deployment that does not wait for this workflow, or a newer release is the
    # candidate or runs in that environment.
    param($Candidate, [object[]] $ActiveTaskIds)
    foreach ($i in $heldIssues) {
        $parts = Get-HeldTitleParts $i.title
        if (-not $parts) { continue }
        $version = $parts.Version; $envName = $parts.Environment
        if ($Candidate.Release -and $Candidate.Release.Version -eq $version -and $Candidate.Target.Name -eq $envName) { continue }
        $rel = (@($releases | Where-Object Version -eq $version) | Select-Object -First 1)
        $env = (@($envs | Where-Object Name -eq $envName) | Select-Object -First 1)
        $why = $null
        if ($rel -and $env) {
            $deps = @(Get-ReleaseDeployments $rel.Id | Where-Object { $_.EnvironmentId -eq $env.Id })
            if (@($deps | Where-Object { $_.TaskId -notin $ActiveTaskIds }).Count -gt 0) { $why = "$Deployable $version has a deployment to $envName." }
            elseif ($Candidate.Release -and $Candidate.Target.Id -eq $env.Id -and (Compare-Release $Candidate.Release $rel) -gt 0) { $why = "$Deployable $($Candidate.Release.Version), a newer release, is the candidate for $envName." }
        }
        if ($why) { Say "closing issue #$($i.number): $why"; if (-not $DryRun) { & gh issue close $i.number -R $ownRepo --comment "$why $RunUrl" | Out-Null } }
    }
}

# 1. What is not finished: any project, deployments and runbook runs. A failed call or an incomplete listing stops the run.
try {
    $listed = Get-ActiveBusyItems
    $busyItems = @($listed.Items)
    $activeTaskIds = @($listed.ActiveTaskIds)
} catch { Say "Waiting: Octopus tasks could not be read whole ($($_.Exception.Message))"; Complete-AutoPromoteSuccess }

# Deployments parked only on a refused Sign-off hold do not block other deployables (#569).
$projectIdByDeployable = @{}
foreach ($p in $allProjects) {
    if ($p.Name -like "$slug-*") { $projectIdByDeployable[$p.Name.Substring($slug.Length + 1)] = $p.Id }
}
$environmentIdByName = @{}; foreach ($e in $envs) { $environmentIdByName[$e.Name] = $e.Id }
$releaseVersionCache = @{}
Set-BusyItemsSignOffRefused -Items $busyItems

# 2. Recovery: a deployment this workflow created that waits at its Sign-off.
foreach ($b in @($busyItems | Where-Object { $_.Kind -eq 'deployment' -and $_.ProjectId -eq $project.Id -and $_.EnvironmentId -ne $first.Id -and "$($_.Deployment.Comments)".StartsWith($PromotionMarker) })) {
    $pending = Get-SignOffAction -Interruptions @((Invoke-Octopus "/api/$space/interruptions?regarding=$($b.TaskId)").Items) -TaskId $b.TaskId
    if ($pending.Action -ne 'answer') { continue }
    $rel = (@($releases | Where-Object Id -eq $b.Deployment.ReleaseId) | Select-Object -First 1)
    $tIndex = [array]::IndexOf(@($envs | ForEach-Object Id), $b.EnvironmentId)
    $target = $envs[$tIndex]; $previous = $envs[$tIndex - 1]
    Say "Recovery: $Deployable $($rel.Version) waits at its Sign-off in $($target.Name) ($($b.TaskId))."
    # The base of the comparison is the release that ran there before this deployment, not the waiting one.
    $runningUnknown = ''
    $runningBefore = try { Get-RunningRelease -Target $target -Releases $releases -GetDeployments { param($id) Get-ReleaseDeployments $id } -GetTaskState { param($d) Get-TaskState $d } -GetRunningOutside { param($t) Get-RunningOutsideList $t } } catch { if (-not (Test-RunningLookupError $_)) { throw }; $runningUnknown = $_.Exception.Message; $null }
    $ev = Get-Evaluation -Release $rel -Target $target -Previous $previous -RunningRelease $runningBefore -RunningUnknown $runningUnknown
    if ($ev.Behind -or $ev.Decision.Decision -ne 'promote') {
        if (-not $ev.Behind -and $ev.Decision.Decision -eq 'hold') { Set-HeldIssue -Release $rel -Target $target -Evaluation $ev -DeploymentNote "The deployment $($b.Deployment.Id) was created earlier and waits at its Sign-off: a person decides." }
        else { Say "Left waiting: $(@($ev.Decision.Waiting) -join '; ')" }
        continue
    }
    if ($DryRun) { Say 'Dry run: would answer the Sign-off.'; continue }
    $signOff = Submit-SignOff -TaskId $b.TaskId -Reason (Format-PromotionReason -Decision $ev.Decision -Previous $previous.Name -RunUrl $RunUrl -Recovered) -WaitSeconds 0 -ProjectName $project.Name -ReleaseVersion $rel.Version -EnvironmentName $target.Name
    if ($signOff -eq 'refused') {
        $b.SignOffRefused = $true
        Set-HeldIssue -Release $rel -Target $target -Evaluation (New-SignOffRefusedEvaluation -Sha (Get-Commit $rel) -ProjectName $project.Name -ReleaseVersion $rel.Version -EnvironmentName $target.Name) -DeploymentNote "The deployment $($b.Deployment.Id) waits at its Sign-off: the auto-promote account was refused permission to take it."
    }
}

# 3. Candidate. Prefer an open pipeline-change hold so a newer tdd release does not restart its 60-minute clock (#688).
$preferHeld = @(Get-HeldPipelinePrefer -HeldIssues $heldIssues)
$candidate = Select-Candidate -Environments $envs -Releases $releases -GetDeployments { param($id) Get-ReleaseDeployments $id } -GetTaskState { param($d) Get-TaskState $d } -GetRunningOutside { param($t) Get-RunningOutsideList $t } -PreferHeld $preferHeld
$candidate.Notes | ForEach-Object { Say $_ }
if (-not $candidate.Release) { Say "No $Deployable release waits for a next environment."; Close-HeldIssues $candidate $activeTaskIds; Complete-AutoPromoteSuccess }
$release = $candidate.Release; $target = $candidate.Target; $previous = $candidate.Previous
Close-HeldIssues $candidate $activeTaskIds
$busy = Get-BusyReason -Items $busyItems -TargetEnvironmentId $target.Id -FirstEnvironmentId $first.Id -ProjectId $project.Id
# A short-lived runbook in the target (Hourly health report) is waited out in this run (#583); a deployment still blocks at once.
# GetBusyItems is a plain scriptblock (no GetNewClosure): Get-ActiveBusyItemsMarked must resolve script-scope Octopus helpers (#589).
if ($busy -and (Test-BusyOnlyRunbookToTarget -Items $busyItems -TargetEnvironmentId $target.Id -FirstEnvironmentId $first.Id -ProjectId $project.Id)) {
    $wait = Wait-BusyRunbookClear -Items $busyItems -TargetEnvironmentId $target.Id -FirstEnvironmentId $first.Id -ProjectId $project.Id `
        -EnvironmentName $target.Name -Pause $RunbookBusyPause -WriteLog { param([string] $Message) Say $Message } `
        -GetBusyItems { @((Get-ActiveBusyItemsMarked).Items) }
    if ($wait.Failed) { Complete-AutoPromoteSuccess }
    $busyItems = @($wait.Items)
    $busy = $wait.Busy
}
if ($busy) { Say "Nothing to do: $busy."; Complete-AutoPromoteSuccess }
Say "Candidate: $Deployable $($release.Version) to $($target.Name) (commit $(Get-Commit $release))"

$running = $candidate.Running
if ($candidate.RunningUnknown) { Say "The release running in $($target.Name) is unknown: $($candidate.RunningUnknown)" }
$ev = Get-Evaluation -Release $release -Target $target -Previous $previous -RunningRelease $running -RunningUnknown ([string] $candidate.RunningUnknown)
if ($ev.Behind) { Say "commit $($ev.Sha) is behind the running $($ev.BaseSha): not promoted."; Complete-AutoPromoteSuccess }
$decision = $ev.Decision
Say "Decision: $($decision.Decision)"
if ($decision.Decision -eq 'wait') { $decision.Waiting | ForEach-Object { Say "  waiting: $_" }; Complete-AutoPromoteSuccess }
if ($decision.Decision -eq 'hold') { Set-HeldIssue -Release $release -Target $target -Evaluation $ev; Complete-AutoPromoteSuccess }

$reason = Format-PromotionReason -Decision $decision -Previous $previous.Name -RunUrl $RunUrl
Say $reason
if ($DryRun) { Complete-AutoPromoteSuccess }
$created = Invoke-Octopus "/api/$space/deployments" 'Post' @{ ReleaseId = $release.Id; EnvironmentId = $target.Id; Comments = "${PromotionMarker}: $RunUrl" }
Say "Deployment $($created.Id) to $($target.Name) (task $($created.TaskId))"
$signOff = Submit-SignOff -TaskId $created.TaskId -Reason $reason -ProjectName $project.Name -ReleaseVersion $release.Version -EnvironmentName $target.Name
if ($signOff -eq 'refused') {
    Set-HeldIssue -Release $release -Target $target -Evaluation (New-SignOffRefusedEvaluation -Sha (Get-Commit $release) -ProjectName $project.Name -ReleaseVersion $release.Version -EnvironmentName $target.Name) -DeploymentNote "The deployment $($created.Id) waits at its Sign-off: the auto-promote account was refused permission to take it."
}
Complete-AutoPromoteSuccess
