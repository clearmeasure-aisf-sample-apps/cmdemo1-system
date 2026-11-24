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

    Candidate (Select-Candidate): only Default channel releases (issue #655: Pull requests channel versions like
    2.4.<run>-pr.<n> are never candidates and never count as an environment's current version). Among those, newest first by
    version (Major.Minor.Patch; an unparsable version below every parsable one; Assembled only between equal or unparsable
    versions: releases can be assembled out of order); the first whose latest deployment to the previous
    environment (tdd before uat, uat before prod) succeeded. It is the candidate when it has no deployment at all to the
    next environment (any state: a canceled one is a person's no) and is newer than the release running there; prod is
    looked at before uat. Exception (issue #688): an open release-held issue for this deployable before that environment
    whose body lists Pipeline or infra change as its only flag keeps that held release as the candidate until it is
    promoted (or no longer qualifies, including when the hold later lists another flag); a newer success in the previous
    environment does not supersede it and does not restart the 60-minute pipeline-change clock. The newest $ReleaseWindow
    Default channel releases are listed; a running Default release older than those is found through
    the newest deployments to that environment (issue #314). A newer release that ended otherwise in the previous environment is skipped and the run log says so.
    Health window first (2026-11-24): among the releases that qualify for an environment, the newest whose health window
    in the previous environment is already complete by the reads stored so far is the candidate; only when none is
    complete is the newest one the candidate (it then takes the reads). tdd gets a new dashboard release every 5 to 10
    minutes, so always taking the newest restarted the 10-minute window and starved uat. A preferred pipeline-change
    hold (#688) keeps its place. When the window has passed but the verdict still waits (the later read landed seconds
    before it closed, or only one read since), the run pauses and reads once more (Get-HealthWaitSeconds: up to
    $HealthWaitMaxSeconds s, within the job budget). A read is recorded for a release only while its commit is what runs in
    the previous environment (Test-LiveCommitMatches).
    Environment window (2026-11-24, second fix): a release is live in tdd for only part of the 5 to 10 minutes between
    dashboard releases, so its own reads never spanned the window (runs 45442775877, 45445735479). Each read is now also
    kept for the environment with the commit it served (state key <deployable>/env-<environment>). A release's window is
    decided by its own reads plus the environment's reads since it finished (Get-WindowReads: nothing older runs there
    after it), and counts only when the release itself was read Healthy while live (Test-LiveHealthSeen). Get-Evaluation
    always takes a fresh read, so the environment must still be Healthy now; any non-Healthy read since it finished fails it.
    Failed retry (2026-11-24, after #957): a release whose every deployment to the next environment ended Failed or
    TimedOut is offered there again on a later run, at most $FailedDeploymentRetryLimit times, with every flag and the
    health window checked again; a Canceled deployment is still a person's no and is never retried.
    Nothing is promoted while any deployment or runbook run (any project) to the target environment, or any ui
    deployment to a later-than-first environment, is queued, running, cancelling or waiting at an interruption; a call that
    fails or a listing that is incomplete also stops the run (fail closed). When the only busy reason is a short-lived
    runbook in the target (e.g. Hourly health report), the same run waits and re-lists active tasks for about two to
    three minutes before giving up (issue #583); an unfinished deployment in the target still blocks at once. A
    deployment waiting only because Octopus refused this account permission to take its Sign-off (issue #569) is
    recorded as a hold and does not count as busy for other deployables.
    Superseded Sign-off (issue #731): when a newer release of the same project is the candidate for an environment and an
    older release's deployment there waits at a manual intervention or Sign-off, that older task is cancelled (with a log
    line naming it) so the newer deployment can run. The candidate's own task and the task for the release currently live
    in that environment are never cancelled. If Octopus refuses the cancel (HTTP 401/403 or permission wording), a hold
    names the exact missing permission; the run continues.
    Queued candidate (issue #733): the same cancel also runs when no release waits for a next environment yet the
    environment's newest busy deployment of this project is already Queued behind an older release waiting at a manual
    intervention or Sign-off (the candidate's existing deployment). Never cancel that queued newer task or the live
    release's task; never take a Sign-off; DryRun only logs the intended cancel.
    Stale Queued / not-running busy task (issue #747): when a task that blocks promotion has been Queued or Waiting
    (not Executing or Cancelling) for $QueuedTaskStaleMinutes minutes or more, open or update one release-held issue that
    names the task, its release, what other active tasks in that environment it waits on, and how long it has been
    queued. The "not finished" wait still blocks (the run stays green and does not promote). When the blocked task is a
    Queued deployment of this project and the release already live in that environment is the same version or newer,
    cancel it as safely superseded (same cancel / refused-TaskCancel hold as #731); never cancel an Executing task and
    never take a person's Sign-off.
    Recovery: a deployment this workflow created (its Comments start with "Promoted by workflow ui-auto-promote") that waits at
    its Sign-off is evaluated again; no flag: its Sign-off is answered; a flag: it stays waiting and the held issue says so.
    When the comparison shows that waiting release is behind what already runs in the environment (issue #739), the superseded
    Sign-off task is cancelled (same cancel / refused-TaskCancel hold as #731); every evaluation path sets Decision so StrictMode
    never throws on a missing property. Permission denied on take-responsibility or submit (HTTP 401/403, or Octopus "not in any
    team with permissions"): hold, warn, continue — do not fail the workflow.

    The four flags (Get-PromotionDecision), and what makes the run wait (nothing promoted, nothing flagged):
      1 checks   Flag: a check run of the release's commit in the application repository that ended failure, cancelled,
                 timed_out, action_required, startup_failure, stale or without a conclusion, or a commit status failure or
                 error. skipped and neutral pass. Wait: a check run not completed, a status pending, no check yet, or a
                 listing that could not be read whole. The workflow ui-auto-promote's own check runs are left out: a crash
                 or an unfinished run of this promoter is not a build or test of the release. Every other workflow still
                 counts, including one whose job happens to be named promote (system, env-checks). A check
                 run whose workflow cannot be read is counted. Monitoring workflows are left out too (owner, Jeffrey
                 Palermo 2026-11-21, $MonitorWorkflowFiles: capabilities, delivery, deployments, drift, workitems, ...):
                 they report on environments, not on the commit, for flag 1 and for master's state; capabilities
                 called from system.yml still counts.
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
                 Test-project files never flag (owner, Jeffrey Palermo 2026-11-21, $TestProjectFolders: a folder named
                 *Tests, *.Tests, test or tests, project file included), except under .github/ or scripts/ or a Dockerfile*.
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
# Test projects (owner, Jeffrey Palermo 2026-11-21: "test-project files are not a pipeline change"): a path with a folder
# named like a test project (src/UnitTests/..., src/Dashboard.Tests/Dashboard.Tests.csproj, tests/...) is not a pipeline
# change, its project file included. Never under .github/ or scripts/ (those keep the hold), and a Dockerfile* still flags.
$TestProjectFolders = @('*Tests', '*.Tests', '*.Tests.*', 'test', 'tests')
$TestProjectNeverPrefixes = @('.github/', 'scripts/')
# Monitoring workflows (owner, Jeffrey Palermo 2026-11-21: "scheduled monitoring runs don't count as red build"): their check
# runs on a commit are reports about the environments or the factory, not a build or test of that commit, so they never
# flag a release as red and never make master pending, like the promoter's own runs. Identified by the workflow file of
# the Actions run, never by the job name: capabilities called from system.yml (workflow system) still counts.
$MonitorWorkflowFiles = @('capabilities.yml', 'delivery.yml', 'deployments.yml', 'drift.yml', 'fleet-findings.yml', 'kit-templates.yml',
    'pool-manager.yml', 'pool-reset.yml', 'pool-template-refresh.yml', 'workitems.yml', 'factory-wake.yml', 'ui-feature-toggles.yml')
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
# A ripe hold of another deployable is given the free slot first, but only while it is younger than this (no starvation).
$RipeHoldYieldMaxMinutes = 240
# GHSA id in a pull request title or body (GitHub Security Advisory).
$GhsaIdPattern = 'GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}'
# Build/project files whose package-version surfaces may qualify for the security-advisory exemption (Dockerfile* does not).
$SecurityAdvisoryPackageFiles = @('Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json',
    'nuget.config', '*.csproj', '*.sln', '*.slnx', '*.props', '*.targets')
# The newest releases looked at for a candidate; the release running in an environment can be older: then it is found
# through the newest deployments to that environment, at most this many (issue #314; fewer than one success among them
# leaves the running release unknown: "comparison incomplete").
$ReleaseWindow = 40
# A release whose every deployment to the next environment failed (task Failed or TimedOut, never Canceled: a canceled one
# is a person's no) is offered there again on a later run, at most this many times (cmdemo1-system #957 follow-up: the
# dashboard 1.0.839 prod deployment failed on a transient npm ECONNRESET and no prod candidate was offered again until a
# newer release passed uat). After this many failed deployments the release is left alone, as before.
$FailedDeploymentRetryLimit = 2
$RetryableTaskStates = @('Failed', 'TimedOut')
$RunningLookupDeployments = 100
$PromotionMarker = 'Promoted by workflow ui-auto-promote'
# When a short-lived runbook (e.g. Hourly health report) is the only thing busy in the target environment, wait and
# re-list active Octopus tasks this many times, this many seconds apart, before giving up for this run (#583). Cap is
# about two to three minutes total; a real deployment in the target still blocks with no wait. $RunbookBusyPause is
# replaced by the harness so tests do not really sleep.
$RunbookBusyRetrySeconds = 40
$RunbookBusyRetryLimit = 4
$RunbookBusyPause = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
# When a Queued or Waiting (not Executing) task blocks promotion for this many minutes, open or update one release-held
# issue naming it (issue #747). Shorter stalls only log "Nothing to do"; the wait itself is never suppressed.
$QueuedTaskStaleMinutes = 20
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
# Longest wait in one run for the read that closes a health window (Get-HealthWaitSeconds); never past the job budget:
# the reserve below keeps $HealthPauseSeconds for it, and the wait also uses what is left before the deadline.
$HealthWaitMaxSeconds = 600
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

function Test-TestProjectPath([string] $Path) {
    # True when a folder of the path is named like a test project (owner 2026-11-21), outside .github/ and scripts/, and
    # the file is not a Dockerfile.
    if (@($TestProjectNeverPrefixes | Where-Object { $Path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { return $false }
    $parts = @($Path.Split('/'))
    if ($parts[-1] -ilike 'Dockerfile*') { return $false }
    foreach ($folder in @($parts | Select-Object -SkipLast 1)) { if (Test-GlobMatch $folder $TestProjectFolders) { return $true } }
    $false
}

function Get-PipelineEvidence {
    param([string[]] $Paths, [string[]] $Documentation = $DocumentationPaths, [string[]] $Build = $BuildFiles,
        [string[]] $Unflagged = $Settings.UnflaggedFolders, [string[]] $Application = $Settings.ApplicationPaths)
    $outside = "outside $(@($Application | ForEach-Object { $_ -replace '\*\*$', '' }) -join ', ')"
    foreach ($p in @($Paths | Where-Object { $_ })) {
        if (Test-GlobMatch $p $Documentation) { continue }
        if (@($Unflagged | Where-Object { $_ -and $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
        if (Test-TestProjectPath $p) { continue }
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

function Test-MonitorCheckRun {
    # A check run of a monitoring workflow (owner 2026-11-21, $MonitorWorkflowFiles) is not a build or test of the commit:
    # left out of flag 1 and of master's state, like the promoter's own runs. By workflow file only; an unreadable
    # workflow (empty path) still counts.
    param([string] $WorkflowPath)
    if (-not $WorkflowPath) { return $false }
    $file = $WorkflowPath.Split('/')[-1]
    ($WorkflowPath -like '.github/workflows/*') -and ($MonitorWorkflowFiles -contains $file)
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
            elseif ($Facts.ContainsKey('LiveHealthSeen') -and -not [bool] $Facts.LiveHealthSeen) { $waiting.Add('health window: no Healthy read of this release while it was live in the previous environment') }
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
    # Octopus cancel / other actions: "You do not have permission to perform this action. The TaskCancel permission is required."
    if ($msg -match '(?i)do not have permission to perform this action') { return $true }
    if ($msg -match '(?i)\b\w+\s+permission\s+is\s+required\b') { return $true }
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

# Flag text when Octopus refused permission to cancel a superseded task waiting at Sign-off/MI (#731).
$TaskCancelPermissionDeniedFlag = 'Task cancel permission denied'

function Get-OctopusMissingPermission {
    # Exact permission name from an Octopus refusal message (e.g. TaskCancel), or $null when none is named.
    param($ErrorRecord)
    $msg = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $parts = [Collections.Generic.List[string]]::new()
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $parts.Add([string] $ErrorRecord.ErrorDetails.Message) }
        if ($ErrorRecord.Exception) { $parts.Add([string] $ErrorRecord.Exception.Message) }
        $msg = $parts -join ' '
    } else {
        $msg = [string] $ErrorRecord
    }
    if ($msg -match '(?i)(?:the\s+)?[`''"]?(\w+)[`''"]?\s+permission\s+is\s+required') { return $Matches[1] }
    $null
}

function New-TaskCancelRefusedEvaluation {
    # Evaluation shape for Set-HeldIssue when Octopus refused cancel of a superseded waiting task (#731).
    param(
        [string] $Sha,
        [string] $ProjectName,
        [string] $ReleaseVersion,
        [string] $EnvironmentName,
        [string] $TaskId,
        [string] $Permission = '',
        [string] $Detail = ''
    )
    $evidence = [Collections.Generic.List[string]]::new()
    $permPart = if ($Permission) { " The missing permission is $Permission." } else { '' }
    $evidence.Add("Octopus refused the auto-promote account permission to cancel superseded task $TaskId ($ProjectName $ReleaseVersion in $EnvironmentName).$permPart")
    if ($Detail) { $evidence.Add($Detail) }
    @{
        Sha      = $(if ($Sha) { $Sha } else { 'unknown' })
        Decision = @{
            Decision = 'hold'
            Reason   = $null
            Note     = ''
            Flags    = @(@{ Flag = $TaskCancelPermissionDeniedFlag; Evidence = @($evidence) })
            Waiting  = @()
            Passed   = @()
        }
    }
}

function Test-TaskCancelRefusedHoldBody([string] $Body) {
    # True when a release-held issue body was written for a refused task cancel (#731).
    "$Body" -match [regex]::Escape($TaskCancelPermissionDeniedFlag)
}

function New-BehindEvaluation {
    # Evaluation when the release's commit is behind what already runs in the target (#739). Always includes Decision
    # so recovery/candidate callers under StrictMode never throw on a missing property.
    param([string] $Sha, [string] $BaseSha)
    $waiting = "commit $Sha is behind the running $BaseSha"
    @{
        Behind   = $true
        Sha      = $Sha
        BaseSha  = $BaseSha
        Decision = @{
            Decision = 'wait'
            Reason   = 'behind'
            Note     = ''
            Flags    = @()
            Waiting  = @($waiting)
            Passed   = @()
        }
    }
}

function Test-EvaluationBehind($Evaluation) {
    # StrictMode-safe: true when the evaluation says Behind (hashtable or object).
    if ($null -eq $Evaluation) { return $false }
    if ($Evaluation -is [System.Collections.IDictionary]) {
        return [bool] ($Evaluation.Contains('Behind') -and $Evaluation['Behind'])
    }
    $property = $Evaluation.PSObject.Properties['Behind']
    [bool] ($property -and $property.Value)
}

function Get-EvaluationDecision($Evaluation) {
    # StrictMode-safe: the Decision object, or $null when absent.
    if ($null -eq $Evaluation) { return $null }
    if ($Evaluation -is [System.Collections.IDictionary]) {
        if ($Evaluation.Contains('Decision')) { return $Evaluation['Decision'] }
        return $null
    }
    $property = $Evaluation.PSObject.Properties['Decision']
    if ($property) { $property.Value } else { $null }
}

function Get-RecoverySignOffDisposition {
    <# What recovery does after evaluating a workflow-created Sign-off (issue #739).
       Behind (waiting release older than what already runs): cancel-superseded — never read Decision first.
       promote → answer; hold → hold; anything else → wait. Missing Decision when not Behind fails closed. #>
    param($Evaluation)
    if ($null -eq $Evaluation) { throw 'Recovery evaluation is required' }
    if (Test-EvaluationBehind $Evaluation) {
        return @{ Action = 'cancel-superseded'; Decision = (Get-EvaluationDecision $Evaluation) }
    }
    $decision = Get-EvaluationDecision $Evaluation
    if ($null -eq $decision) {
        throw 'Recovery evaluation is missing Decision (and is not Behind).'
    }
    switch ([string] $decision.Decision) {
        'promote' { @{ Action = 'answer'; Decision = $decision } }
        'hold' { @{ Action = 'hold'; Decision = $decision } }
        default {
            $waiting = @()
            if ($decision -is [System.Collections.IDictionary]) {
                if ($decision.Contains('Waiting')) { $waiting = @($decision['Waiting']) }
            } else {
                $w = $decision.PSObject.Properties['Waiting']
                if ($w) { $waiting = @($w.Value) }
            }
            @{ Action = 'wait'; Decision = $decision; Waiting = $waiting }
        }
    }
}

function Test-PendingManualIntervention {
    # True when interruptions include a pending ManualIntervention (Sign-off or other) for the task (#731).
    param([object[]] $Interruptions, [string] $TaskId)
    @($Interruptions | Where-Object {
            $_.Type -eq 'ManualIntervention' -and $_.IsPending -and (-not $TaskId -or $_.TaskId -eq $TaskId)
        }).Count -gt 0
}

function Select-SupersededWaitingBusyItems {
    <# Busy deployments of this project in the candidate's target that wait at a manual intervention/Sign-off and are
       older than the candidate. Never returns the candidate's own task or a task for the live release in that
       environment (issue #731). TestWaitsAtManualIntervention {param($taskId)} -> bool. #>
    param(
        [object[]] $Items,
        [string] $ProjectId,
        [string] $TargetEnvironmentId,
        $CandidateRelease,
        $LiveRelease = $null,
        [string] $CandidateTaskId = '',
        [scriptblock] $TestWaitsAtManualIntervention
    )
    if (-not $CandidateRelease) { return @() }
    $liveVersion = if ($LiveRelease) { [string] $LiveRelease.Version } else { '' }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($b in @($Items)) {
        if ($null -eq $b -or $b.Kind -ne 'deployment') { continue }
        if ($b.ProjectId -ne $ProjectId -or $b.EnvironmentId -ne $TargetEnvironmentId) { continue }
        $taskId = [string] (Get-BusyItemProperty $b 'TaskId')
        if (-not $taskId) { continue }
        if ($CandidateTaskId -and $taskId -eq $CandidateTaskId) { continue }
        $version = [string] (Get-BusyItemProperty $b 'ReleaseVersion')
        if (-not $version) { continue }
        if ($liveVersion -and $version -eq $liveVersion) { continue }
        $asRelease = @{ Version = $version; Assembled = [datetimeoffset]'2000-01-01T00:00:00Z' }
        if ((Compare-Release $CandidateRelease $asRelease) -le 0) { continue }
        if (-not (& $TestWaitsAtManualIntervention $taskId)) { continue }
        $out.Add($b)
    }
    @($out)
}

function Format-SupersededCancelLog {
    # Log line naming the superseded task being cancelled (#731).
    param(
        [string] $TaskId,
        [string] $ReleaseVersion,
        [string] $EnvironmentName,
        [string] $CandidateVersion,
        [string] $Name = $Deployable,
        [string] $InterruptionTitle = 'manual intervention'
    )
    $waitLabel = if ($InterruptionTitle -eq 'Sign-off') { 'its Sign-off' } else { "a $InterruptionTitle" }
    "Cancelling superseded task $TaskId ($Name $ReleaseVersion waits at $waitLabel in $EnvironmentName) so candidate $CandidateVersion can run."
}

function Invoke-CancelOctopusTask {
    # POST cancel. Returns @{ Outcome = canceled|refused; Permission?; Message? }. Rethrows every other error.
    # Calls script-scope Invoke-Octopus (same rule as Invoke-SignOffOctopusCalls / #589).
    param(
        [Parameter(Mandatory)] [string] $Space,
        [Parameter(Mandatory)] [string] $TaskId
    )
    try {
        Invoke-Octopus "/api/$Space/tasks/$TaskId/cancel" 'Post' | Out-Null
        @{ Outcome = 'canceled'; Permission = $null; Message = '' }
    } catch {
        if (Test-OctopusPermissionDenied $_) {
            @{
                Outcome    = 'refused'
                Permission = (Get-OctopusMissingPermission $_)
                Message    = [string] $_.Exception.Message
            }
        } else {
            throw
        }
    }
}

function Get-CandidateBusyTaskId {
    # TaskId of the candidate release's busy deployment in the target, if any.
    param([object[]] $Items, [string] $ProjectId, [string] $TargetEnvironmentId, [string] $CandidateVersion)
    foreach ($b in @($Items)) {
        if ($null -eq $b -or $b.Kind -ne 'deployment') { continue }
        if ($b.ProjectId -ne $ProjectId -or $b.EnvironmentId -ne $TargetEnvironmentId) { continue }
        if ([string] (Get-BusyItemProperty $b 'ReleaseVersion') -ne $CandidateVersion) { continue }
        return [string] (Get-BusyItemProperty $b 'TaskId')
    }
    ''
}

function Get-NewestBusyDeploymentItem {
    <# Newest busy deployment of ProjectId in TargetEnvironmentId by Compare-Release on ReleaseVersion (issue #733).
       Assembled uses Deployment.Created when present so equal versions still order. $null when none. #>
    param([object[]] $Items, [string] $ProjectId, [string] $TargetEnvironmentId)
    $best = $null
    $bestAsRelease = $null
    foreach ($b in @($Items)) {
        if ($null -eq $b -or $b.Kind -ne 'deployment') { continue }
        if ($b.ProjectId -ne $ProjectId -or $b.EnvironmentId -ne $TargetEnvironmentId) { continue }
        $version = [string] (Get-BusyItemProperty $b 'ReleaseVersion')
        if (-not $version) { continue }
        $assembled = [datetimeoffset]'2000-01-01T00:00:00Z'
        $dep = Get-BusyItemProperty $b 'Deployment'
        if ($null -ne $dep) {
            $created = Get-BusyItemProperty $dep 'Created'
            if ($created) { $assembled = [datetimeoffset] $created }
        }
        $asRelease = @{ Version = $version; Assembled = $assembled }
        if ($null -eq $bestAsRelease -or (Compare-Release $asRelease $bestAsRelease) -gt 0) {
            $best = $b
            $bestAsRelease = $asRelease
        }
    }
    $best
}

function Get-QueuedCandidateBusyItem {
    <# When the newest busy deployment of this project in the target is Queued, return it (issue #733). That queued
       deployment is the candidate's existing deployment, blocked behind an older Sign-off or manual intervention.
       Otherwise $null (newest Waiting alone is not this path). #>
    param([object[]] $Items, [string] $ProjectId, [string] $TargetEnvironmentId)
    $newest = Get-NewestBusyDeploymentItem -Items $Items -ProjectId $ProjectId -TargetEnvironmentId $TargetEnvironmentId
    if ($null -eq $newest) { return $null }
    if ([string] (Get-BusyItemProperty $newest 'State') -ne 'Queued') { return $null }
    $newest
}

# Flag text when a Queued/Waiting task has blocked promotion for $QueuedTaskStaleMinutes or more (#747).
$QueuedTaskStaleFlag = 'Queued task stalled'

function Test-BusyItemNotRunning($Item) {
    # True when the busy task is Queued or Waiting. Never true for Executing/Cancelling (issue #747: never hold or
    # cancel those as "stale queued"). Unknown states fail closed (not treated as not-running).
    $state = [string] (Get-BusyItemProperty $Item 'State')
    if (-not $state) { return $false }
    switch -Regex ($state) {
        '^(?i)Executing|Cancelling|Canceling$' { return $false }
        '^(?i)Queued|Waiting$' { return $true }
        default { return $false }
    }
}

function Get-BusyItemQueueTimeUtc($Item) {
    # QueueTime from the Octopus task when present; else Deployment.Created. $null when neither is known.
    $raw = Get-BusyItemProperty $Item 'QueueTime'
    if (-not $raw) {
        $dep = Get-BusyItemProperty $Item 'Deployment'
        if ($null -ne $dep) { $raw = Get-BusyItemProperty $dep 'Created' }
    }
    if (-not $raw) { return $null }
    if ($raw -is [datetimeoffset]) { return $raw.UtcDateTime }
    if ($raw -is [datetime]) { return $raw.ToUniversalTime() }
    try {
        return [datetimeoffset]::Parse([string] $raw, [cultureinfo]::InvariantCulture).UtcDateTime
    } catch { return $null }
}

function Get-BusyItemQueuedAgeMinutes($Item, [datetime] $Now) {
    # Minutes since QueueTime (or Deployment.Created). $null when the time is unknown.
    $queuedAt = Get-BusyItemQueueTimeUtc $Item
    if ($null -eq $queuedAt) { return $null }
    [math]::Round(($Now.ToUniversalTime() - $queuedAt).TotalMinutes, 1)
}

function Test-StaleQueuedHoldNeeded($Item, [datetime] $Now, [int] $StaleMinutes = $QueuedTaskStaleMinutes) {
    # True when the item is Queued/Waiting and has been so for at least StaleMinutes (#747).
    if (-not (Test-BusyItemNotRunning $Item)) { return $false }
    $age = Get-BusyItemQueuedAgeMinutes $Item $Now
    if ($null -eq $age) { return $false }
    $age -ge $StaleMinutes
}

function Get-BlockingBusyItem {
    # The busy item Get-BusyReason would name first (same skip of refused Sign-offs). $null when nothing blocks.
    param([object[]] $Items, [string] $TargetEnvironmentId, [string] $FirstEnvironmentId, [string] $ProjectId)
    foreach ($i in @($Items)) {
        if (Test-BusyItemSignOffRefused $i) { continue }
        if ($i.EnvironmentId -eq $TargetEnvironmentId) { return $i }
        if ($i.Kind -eq 'deployment' -and $i.ProjectId -eq $ProjectId -and $i.EnvironmentId -ne $FirstEnvironmentId) { return $i }
    }
    $null
}

function Format-QueuedBehindSummary {
    <# What a Queued/Waiting task appears to wait on: other unfinished tasks in the same environment (#747). #>
    param([object[]] $Items, [string] $EnvironmentId, [string] $ExcludeTaskId = '')
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($i in @($Items)) {
        if ($null -eq $i) { continue }
        if ($i.EnvironmentId -ne $EnvironmentId) { continue }
        $tid = [string] (Get-BusyItemProperty $i 'TaskId')
        if ($ExcludeTaskId -and $tid -eq $ExcludeTaskId) { continue }
        $state = [string] (Get-BusyItemProperty $i 'State')
        $ver = [string] (Get-BusyItemProperty $i 'ReleaseVersion')
        $label = "$($i.Kind) of project $($i.ProjectId)"
        if ($ver) { $label += " release $ver" }
        $detail = @()
        if ($tid) { $detail += $tid }
        if ($state) { $detail += "state $state" }
        if ($detail.Count -gt 0) { $label += " ($($detail -join ', '))" }
        $parts.Add($label)
    }
    if ($parts.Count -eq 0) {
        return 'no other active task in this environment is visible (likely the per-environment concurrency tag or a worker/pool stall)'
    }
    ($parts -join '; ')
}

function New-QueuedTaskStaleEvaluation {
    # Evaluation shape for Set-HeldIssue when a Queued/Waiting task has blocked promotion too long (#747).
    param(
        [string] $Sha,
        [string] $ProjectName,
        [string] $ReleaseVersion,
        [string] $EnvironmentName,
        [string] $TaskId,
        [string] $State,
        [double] $AgeMinutes,
        [string] $BehindSummary,
        [int] $StaleMinutes = $QueuedTaskStaleMinutes
    )
    $evidence = [Collections.Generic.List[string]]::new()
    $ageText = if ($AgeMinutes -ge 60) {
        '{0:N0} minutes (~{1:N1} hours)' -f $AgeMinutes, ($AgeMinutes / 60.0)
    } else {
        '{0:N0} minutes' -f $AgeMinutes
    }
    $evidence.Add("Task $TaskId ($ProjectName $ReleaseVersion in $EnvironmentName) has been $State for $ageText (threshold ${StaleMinutes} minutes) and is blocking automatic promotion.")
    if ($BehindSummary) { $evidence.Add("It appears to wait on: $BehindSummary.") }
    $evidence.Add('The "not finished" wait still blocks promotion; this hold only makes the stall visible. Never cancel an Executing task; never take a person''s Sign-off.')
    @{
        Sha      = $(if ($Sha) { $Sha } else { 'unknown' })
        Decision = @{
            Decision = 'hold'
            Reason   = $null
            Note     = ''
            Flags    = @(@{ Flag = $QueuedTaskStaleFlag; Evidence = @($evidence) })
            Waiting  = @()
            Passed   = @()
        }
    }
}

function Test-QueuedTaskStaleHoldBody([string] $Body) {
    # True when a release-held issue body was written for a stale Queued/Waiting blocker (#747).
    "$Body" -match [regex]::Escape($QueuedTaskStaleFlag)
}

function Test-QueuedBusySafelySupersededByLive {
    <# True when a Queued/Waiting deployment of this project may be cancelled: the live release in that environment is
       the same version or newer (issue #747). Never true without a live release or for a newer queued version. #>
    param($QueuedItem, $LiveRelease)
    if ($null -eq $QueuedItem -or $null -eq $LiveRelease) { return $false }
    if (-not (Test-BusyItemNotRunning $QueuedItem)) { return $false }
    $queuedVersion = [string] (Get-BusyItemProperty $QueuedItem 'ReleaseVersion')
    $liveVersion = [string] $LiveRelease.Version
    if (-not $queuedVersion -or -not $liveVersion) { return $false }
    $queuedAs = @{ Version = $queuedVersion; Assembled = [datetimeoffset]'2000-01-01T00:00:00Z' }
    $liveAs = @{ Version = $liveVersion; Assembled = [datetimeoffset]'2000-01-01T00:00:00Z' }
    (Compare-Release $liveAs $queuedAs) -ge 0
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
    # A Pull requests channel version such as 2.4.999-pr.12 still parses as 2.4.999: callers must keep only Default
    # channel releases (Select-DefaultChannelReleases / issue #655) before sorting or promoting.
    if ($Version -match '^v?(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?!\d)') { [version]::new([int] $Matches[1], [int] $Matches[2], [int] $Matches[3]) }
}

function Get-ReleaseChannelId($Release) {
    # ChannelId of an Octopus release (hashtable or object); empty when absent.
    if ($null -eq $Release) { return '' }
    if ($Release -is [System.Collections.IDictionary]) {
        if ($Release.Contains('ChannelId')) { return [string] $Release['ChannelId'] }
        return ''
    }
    $property = $Release.PSObject.Properties['ChannelId']
    if ($property) { [string] $property.Value } else { '' }
}

function Get-DefaultChannelIds([object[]] $Channels) {
    # Ids of channels named Default (Octopus's built-in Default channel). Issue #655: only those releases are promoted.
    @($Channels | Where-Object {
            $name = if ($_ -is [System.Collections.IDictionary]) { [string] $_['Name'] } else { [string] $_.Name }
            $name -ceq 'Default'
        } | ForEach-Object {
            if ($_ -is [System.Collections.IDictionary]) { [string] $_['Id'] } else { [string] $_.Id }
        } | Where-Object { $_ })
}

function Test-DefaultChannelRelease($Release, [string[]] $DefaultChannelIds) {
    # True when the release is on a Default channel. A missing ChannelId is not Default (fail closed).
    $id = Get-ReleaseChannelId $Release
    if (-not $id -or -not $DefaultChannelIds -or $DefaultChannelIds.Count -eq 0) { return $false }
    $DefaultChannelIds -contains $id
}

function Select-DefaultChannelReleases([object[]] $Releases, [string[]] $DefaultChannelIds) {
    # Keeps only Default channel releases (issue #655). Pull requests channel releases are dropped.
    @($Releases | Where-Object { Test-DefaultChannelRelease $_ $DefaultChannelIds })
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
       {param($releaseId)}; GetTaskState {param($deployment)}. DefaultChannelIds (issue #655): when set, a successful
       deployment of a non-Default (e.g. Pull requests) channel release is skipped so it never counts as the environment's
       current version. $null when the listing is whole and no Default deployment there succeeded (nothing runs there).
       Throws "the release running in ..." when none of the newest $Max deployments succeeded (after channel filter) and
       there are more, or when the release answered is empty; a failed call throws its own error (the run stops, as for
       every failed call). #>
    param($Target, [scriptblock] $GetEnvironmentDeployments, [scriptblock] $GetRelease, [scriptblock] $GetTaskState, [int] $Max = $RunningLookupDeployments, [string[]] $DefaultChannelIds = @())
    $list = & $GetEnvironmentDeployments $Target.Id $Max
    $items = @(@($list.Items) | Where-Object { $_ -and $_.EnvironmentId -eq $Target.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending)
    foreach ($d in $items) {
        if ((& $GetTaskState $d) -ne 'Success') { continue }
        $r = & $GetRelease $d.ReleaseId
        $rid = if ($r) { try { [string] $r.Id } catch { '' } } else { '' }
        if (-not $rid) { throw "the release running in $($Target.Name) could not be read: release $($d.ReleaseId) of deployment $($d.Id)" }
        if ($DefaultChannelIds.Count -gt 0 -and -not (Test-DefaultChannelRelease $r $DefaultChannelIds)) { continue }
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

function Get-FailedTargetRetry {
    <# Whether a release that already has deployments to the target may be offered there again. TargetStates: the task state
       of each of its deployments to the target. Retry only when there is at least one and every one ended Failed or
       TimedOut (a Canceled one is a person's no; Success, Queued, Executing or Waiting is not a failure to retry) and
       there are no more than Limit of them. Returns @{ Retry = bool; Failed = count }. #>
    param([string[]] $TargetStates, [int] $Limit = $FailedDeploymentRetryLimit, [string[]] $Retryable = $RetryableTaskStates)
    $all = @($TargetStates)
    $failed = @($all | Where-Object { $_ -in $Retryable }).Count
    @{ Retry = ($all.Count -gt 0 -and $failed -eq $all.Count -and $failed -le $Limit); Failed = $failed }
}

function Get-WindowReads {
    <# The reads that decide a release's health window in the previous environment (2026-11-24, second fix): its own reads
       (taken while its commit was live there) and the environment's reads (any commit) since its deployment finished.
       Nothing older than the release runs there after it finished, so an environment read since then is of this release
       or a newer one that contains it. tdd gets a new dashboard release every 5 to 10 minutes and each is live for only
       part of that, so its own reads alone never span the 10-minute window. Own and Environment: @{ At; Status[; Commit] }. #>
    param([object[]] $Own, [object[]] $Environment, $Finished)
    $all = @(@($Own) + @($Environment) | Where-Object { $_ })
    if ($Finished) { $all = @($all | Where-Object { $_.At -ge ([datetime] $Finished) }) }
    @($all | Sort-Object { $_.At })
}

function Test-LiveHealthSeen {
    <# The release itself was read Healthy while it was what ran in the previous environment: an own read since it
       finished, or an environment read since then naming its commit. Without one, the environment's window does not count
       for it (it may never have served). #>
    param([object[]] $Own, [object[]] $Environment, $Finished, [string] $Commit)
    $since = { param($r) $r -and (-not $Finished -or $r.At -ge ([datetime] $Finished)) -and $r.Status -eq 'Healthy' }
    if (@(@($Own) | Where-Object { & $since $_ }).Count -gt 0) { return $true }
    [bool] ($Commit -and @(@($Environment) | Where-Object { (& $since $_) -and [string] $_.Commit -eq $Commit }).Count -gt 0)
}

function Limit-EnvironmentReads {
    # Environment reads kept in the state file: the last day (a release older than that is never a candidate).
    param([object[]] $Reads, [datetime] $Now, [int] $Hours = 24)
    @(@($Reads) | Where-Object { $_ -and $_.At -ge $Now.AddHours(-$Hours) } | Sort-Object { $_.At })
}

function Get-RetryBlocker {
    <# Why a failed deployment to the target must not be retried, or '' when it may. Only a deployment this workflow created
       ($PromotionMarker in its Comments) whose task has no interruption other than its Sign-off, and that Sign-off was
       answered Proceed, is a failure of the deployment itself (e.g. an npm ECONNRESET). A person's Abort at a Sign-off, a
       guided-failure answer or another manual intervention also leaves the task Failed: that is a person's no, never
       retried. Interruptions: Octopus interruptions regarding the task (Type, Title, IsPending, Form.Values.Result). #>
    param($Deployment, [object[]] $Interruptions, [string] $Marker = $PromotionMarker)
    $comments = [string] (Get-BusyItemProperty $Deployment 'Comments')
    if (-not $comments.StartsWith($Marker)) { return "deployment $(Get-BusyItemProperty $Deployment 'Id') was not created by this workflow" }
    foreach ($i in @($Interruptions)) {
        if ($null -eq $i) { continue }
        $type = [string] (Get-BusyItemProperty $i 'Type'); $title = [string] (Get-BusyItemProperty $i 'Title')
        if ($type -ne 'ManualIntervention' -or $title -ne 'Sign-off') { return "its task has the interruption '$title' ($type)" }
        if ([bool] (Get-BusyItemProperty $i 'IsPending')) { return 'its Sign-off is still pending' }
        $values = Get-BusyItemProperty (Get-BusyItemProperty $i 'Form') 'Values'
        $result = [string] (Get-BusyItemProperty $values 'Result')
        if ($result -ne 'Proceed') { return "its Sign-off was answered '$result'" }
    }
    ''
}

function Test-HealthWindowComplete {
    <# The health window of a deployment is complete from the reads already stored (no new read): HealthRequired false
       (system) is always complete; else Get-HealthVerdict of Finished, Now and Reads is ok. A missing finish time is
       not complete. #>
    param([bool] $HealthRequired, $Finished, [datetime] $Now, [object[]] $Reads)
    if (-not $HealthRequired) { return $true }
    if (-not $Finished) { return $false }
    (Get-HealthVerdict -Finished ([datetime] $Finished) -Now $Now -Reads @($Reads)) -eq 'ok'
}

function Get-HealthWaitSeconds {
    <# After this run's read: how long to wait in this run before one more read, or -1 for no wait. Only when the verdict
       waits (no read failed) and the window can be closed by one more read within MaxSeconds: that read must be at least
       WindowMinutes after Finished and GapMinutes after the earliest read since Finished. Before 2026-11-24 the run
       waited only after the window had passed with fewer than two reads, so a release superseded in tdd within about
       10 to 20 minutes never closed its window (dashboard 1.0.855: reads 15:39:01 and 15:48:48 UTC, window end a few
       seconds later, and the next run moved on to 1.0.858). MarginSeconds keeps the read clear of the boundary. #>
    param([datetime] $Finished, [datetime] $Now, [object[]] $Reads, [int] $MaxSeconds, [int] $WindowMinutes = 10, [int] $GapMinutes = 5, [int] $MarginSeconds = 5)
    if ((Get-HealthVerdict -Finished $Finished -Now $Now -Reads @($Reads) -WindowMinutes $WindowMinutes -GapMinutes $GapMinutes) -ne 'wait') { return -1 }
    $since = @($Reads | Where-Object { $_.At -ge $Finished })
    # No read since the deployment finished (the release no longer runs there, or no read was recorded): one more read
    # cannot close the window, so waiting would only spend job time.
    if ($since.Count -eq 0) { return -1 }
    $at = $Finished.AddMinutes($WindowMinutes)
    $first = ($since | Measure-Object -Property At -Minimum).Minimum
    if ($first.AddMinutes($GapMinutes) -gt $at) { $at = $first.AddMinutes($GapMinutes) }
    $wait = [int] [Math]::Ceiling([Math]::Max(0, ($at - $Now).TotalSeconds)) + $MarginSeconds
    if ($wait -gt $MaxSeconds) { return -1 }
    $wait
}

function Test-LiveCommitMatches {
    <# A health read of the previous environment counts for a release only while that release is what runs there: the
       commit the running app names at BuildPath (ui /_build, dashboard /build-facts.json) is the release's commit. No
       BuildPath (system): true. An unreadable or different commit: false, and the read is not recorded (review of the
       2026-11-24 change: a read of a newer tdd release must never be stored for an older candidate). #>
    param([string] $BuildPath, [string] $LiveCommit, [string] $ReleaseCommit)
    if (-not $BuildPath) { return $true }
    [bool] ($LiveCommit -and $ReleaseCommit -and $LiveCommit -eq $ReleaseCommit)
}

function Select-Candidate {
    <# Environments ordered; Releases (Id, Version, Assembled); GetDeployments {param($releaseId)} -> deployments (Id, ReleaseId,
       EnvironmentId, TaskId, Created); GetTaskState {param($deployment)} -> Octopus task state; GetRunningOutside
       {param($target)} -> the release running in the target when no listed release ran there (it may be older than the
       list; Get-RunningReleaseByEnvironment), or $null; when it throws, the running release is unknown: RunningUnknown
       says why, and the evaluation flags "comparison incomplete" (no base commit). PreferHeld: @{ Version; Environment }
       from Get-HeldPipelinePrefer — when that version still qualifies for Environment, it is the candidate even if a
       newer release also succeeded in the previous environment (issue #688). Returns
       @{ Release; Target; Previous; RunningReleaseId; Running; RunningUnknown; Notes; Retry } or $null with Notes. Looks at the
       last environment first.
       Failed retry: a release whose every deployment to the target ended Failed or TimedOut, no more than
       $FailedDeploymentRetryLimit of them (Get-FailedTargetRetry), is offered there again (Retry = number of failed
       deployments); a Canceled one is still a person's no. GetRetryBlocker {param($deployment)} -> '' or why a failed
       deployment is a person's no (Get-RetryBlocker: a Sign-off answered Abort, a guided failure, not this workflow's
       deployment); without it nothing is retried (fail closed).
       GetWindowComplete {param($release, $previousDeployment)} -> bool (optional): when given, the newest qualifying
       release whose health window in the previous environment is complete (stored reads, Test-HealthWindowComplete) is
       the candidate, so a steady stream of newer tdd releases cannot starve uat; when none is complete, the newest
       qualifying release is the candidate (it takes the reads), as before. A preferred held release (#688) is never
       passed over for this. #>
    param([object[]] $Environments, [object[]] $Releases, [scriptblock] $GetDeployments, [scriptblock] $GetTaskState, [scriptblock] $GetRunningOutside = $null, [object[]] $PreferHeld = @(), [scriptblock] $GetWindowComplete = $null, [scriptblock] $GetRetryBlocker = $null)
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
        $fallback = $null; $inWindow = [Collections.Generic.List[string]]::new()
        foreach ($r in $tryOrder) {
            $here = @(& $deps $r)
            $prev = @($here | Where-Object { $_.EnvironmentId -eq $previous.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending) | Select-Object -First 1
            if (-not $prev) { continue }
            $state = & $GetTaskState $prev
            if ($state -ne 'Success') { if (-not $skipped) { $skipped = "$($r.Version) ended $state in $($previous.Name)" }; continue }
            $inTarget = @($here | Where-Object { $_.EnvironmentId -eq $target.Id })
            $retry = 0
            $own = [Collections.Generic.List[string]]::new()
            if ($inTarget.Count -gt 0) {
                # Preferred held already in the target: fall through to the newest-first remainder (issue #688).
                if ($preferVersion -and $r.Version -eq $preferVersion) { continue }
                $fr = Get-FailedTargetRetry -TargetStates @($inTarget | ForEach-Object { [string] (& $GetTaskState $_) })
                if (-not $fr.Retry) {
                    if ($fr.Failed -gt 0 -and $fr.Failed -eq $inTarget.Count) { $notes.Add("$($r.Version) failed $($fr.Failed) deployments to $($target.Name): the retry limit ($FailedDeploymentRetryLimit) is reached, it is not offered again") }
                    break
                }
                if (-not $GetRetryBlocker) { break }
                $blockers = @($inTarget | ForEach-Object { [string] (& $GetRetryBlocker $_) } | Where-Object { $_ })
                if ($blockers.Count -gt 0) { $notes.Add("$($r.Version) failed in $($target.Name) but is not offered again: $($blockers -join '; ')"); break }
                $retry = $fr.Failed
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
                    $own.Add("$Deployable $($r.Version) is held under the pipeline-change window before $($target.Name): kept as the candidate (issue #688); newer $(@($newerInPrev | ForEach-Object Version) -join ', ') in $($previous.Name) is not considered yet")
                } else {
                    $own.Add("$Deployable $($r.Version) is held under the pipeline-change window before $($target.Name): kept as the candidate (issue #688)")
                }
            } elseif ($skipped) { $own.Add("newer release ${skipped}: the older release $($r.Version) is considered for $($target.Name)") }
            $isPreferred = [bool] ($preferVersion -and $r.Version -eq $preferVersion)
            if ($retry -gt 0) { $own.Add("$($r.Version) is offered to $($target.Name) again after $retry failed deployment$(if ($retry -ne 1) { 's' }) there (retry $retry of $FailedDeploymentRetryLimit)") }
            $complete = $isPreferred -or -not $GetWindowComplete -or [bool] (& $GetWindowComplete $r $prev)
            if ($complete -and $inWindow.Count -gt 0) { $own.Add("newer $($inWindow -join ', ') in $($previous.Name) still in the health window: $($r.Version), whose window is complete, is considered for $($target.Name)") }
            $found = @{ Release = $r; Target = $target; Previous = $previous; RunningReleaseId = $runningId; Running = $running; RunningUnknown = $unknown; Notes = @(@($notes) + @($own)); Retry = $retry }
            if ($complete) { return $found }
            if (-not $fallback) { $fallback = $found }
            $inWindow.Add([string] $r.Version)
        }
        if ($fallback) { return $fallback }
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
function Get-RipeHeldElsewhere {
    <# The open pipeline-only hold of another deployable that has waited longest past its hold window ($PipelineOverrideMinutes),
       or $null. Used to give that deployable the free slot before a newly queued release of this one: the order of $PromoteOrder
       made system last in every run, so ui and dashboard kept taking the single prod slot first. Only pipeline-only holds count
       (a hold that lists any other flag needs a person or a fix, so nobody waits for it), and only up to
       $RipeHoldYieldMaxMinutes of age, so a hold that never clears cannot starve the other deployables. #>
    param([object[]] $HeldIssues, [datetime] $Now, [string] $Name = $Deployable, [string[]] $Order = $PromoteOrder,
          [int] $WindowMinutes = $PipelineOverrideMinutes, [int] $MaxMinutes = $RipeHoldYieldMaxMinutes)
    $best = $null
    foreach ($hi in @($HeldIssues)) {
        if (-not $hi -or -not $hi.createdAt) { continue }
        foreach ($other in @($Order | Where-Object { $_ -ne $Name })) {
            $parts = Get-HeldTitleParts ([string] $hi.title) $other
            if (-not $parts) { continue }
            if (-not (Test-PipelineChangeHoldBody ([string] $hi.body))) { continue }
            $age = ($Now - ([datetime] $hi.createdAt).ToUniversalTime()).TotalMinutes
            if ($age -lt $WindowMinutes -or $age -gt $MaxMinutes) { continue }
            if (-not $best -or $age -gt $best.AgeMinutes) {
                $best = @{ Deployable = $other; Version = [string] $parts.Version; Environment = [string] $parts.Environment; Number = $hi.number; AgeMinutes = [int] $age }
            }
        }
    }
    $best
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
        $queueTime = Get-BusyItemProperty $t 'QueueTime'
        if ($t.Name -eq 'Deploy') {
            $d = Invoke-Octopus "/api/$space/deployments/$($t.Arguments.DeploymentId)"
            $version = $null
            if ($d.ReleaseId) {
                $version = (Invoke-Octopus "/api/$space/releases/$($d.ReleaseId)").Version
            }
            $items.Add(@{ Kind = 'deployment'; ProjectId = $d.ProjectId; EnvironmentId = $d.EnvironmentId; Deployment = $d; TaskId = $t.Id; State = $state; QueueTime = $queueTime; ReleaseVersion = $version; SignOffRefused = $false })
        } elseif ($t.Name -eq 'RunbookRun') {
            $d = Invoke-Octopus "/api/$space/runbookRuns/$($t.Arguments.RunbookRunId)"
            $items.Add(@{ Kind = 'runbook'; ProjectId = $d.ProjectId; EnvironmentId = $d.EnvironmentId; TaskId = $t.Id; State = $state; QueueTime = $queueTime; SignOffRefused = $false })
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
        # A head commit that only monitor workflows ran for (the Pin commits of the Octopus deployments) has no build
        # result of its own: it is judged by the nearest earlier commit that has one (at most 30 back), never by the empty list.
        $sha = $head
        $checks = @(Get-CommitChecks $sha)
        if ($checks.Count -eq 0) {
            foreach ($c in @((Invoke-Gh @("repos/$appRepo/commits?sha=$head&per_page=30")) | Select-Object -Skip 1)) {
                $checks = @(Get-CommitChecks ([string] $c.sha))
                if ($checks.Count -gt 0) { $sha = [string] $c.sha; break }
            }
        }
        $m = Get-MasterState -Checks $checks
        @{ State = $m.State; Evidence = @($m.Evidence); Sha = $sha; Branch = $branch }
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
# Only Default channel releases (issue #655): Pull requests channel releases must not be promoted or used as the
# environment's current version. Resolve Default, then list that channel's window (and filter again fail-closed).
$channels = @(Get-OctopusAll "/api/$space/projects/$($project.Id)/channels")
$defaultChannelIds = @(Get-DefaultChannelIds $channels)
if ($defaultChannelIds.Count -eq 0) { throw "project $($project.Name) has no Default channel" }
$defaultChannelId = $defaultChannelIds[0]
$releases = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/releases?channel=$defaultChannelId&take=$ReleaseWindow").Items)
$releases = @(Select-DefaultChannelReleases $releases $defaultChannelIds)
$taskCache = @{}
function Get-TaskState($d) { if (-not $taskCache.ContainsKey($d.TaskId)) { $taskCache[$d.TaskId] = Invoke-Octopus "/api/tasks/$($d.TaskId)" }; $taskCache[$d.TaskId].State }
function Get-ReleaseDeployments($releaseId) { Get-OctopusAll "/api/$space/releases/$releaseId/deployments" }
function Get-RunningOutsideList($target) {
    # The release running in the target when none of the listed releases ran there (issue #314). Skip Pull requests
    # channel successes so they never count as the current version (issue #655).
    Get-RunningReleaseByEnvironment -Target $target `
        -GetEnvironmentDeployments { param($environmentId, $take) $r = Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$environmentId&take=$take"; @{ Items = @($r.Items); Total = $r.TotalResults } } `
        -GetRelease { param($releaseId) Invoke-Octopus "/api/$space/releases/$releaseId" } `
        -GetTaskState { param($d) Get-TaskState $d } `
        -DefaultChannelIds $defaultChannelIds
}
$heldIssues = @(& gh issue list -R $ownRepo --label release-held --state open --json number,title,body,createdAt --limit 50 | ConvertFrom-Json)
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
            if (Test-MonitorCheckRun -WorkflowPath $workflowPath) { $ignored++; continue }
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
    # Every read is kept for the environment with the commit it served (Get-WindowReads); it is also the release's own
    # read when that commit is the release's (Test-LiveCommitMatches). Read before and after: a read can retry for
    # about 100 s while a newer release goes live.
    $envKey = Get-StateKey "env-$($Previous.Name)"
    $envReads = @(Read-StateReads $state "env-$($Previous.Name)" | ForEach-Object { @{ At = Get-Utc $_.at; Status = [string] $_.status; Commit = [string] $_.commit } })
    function Read-LiveCommit {
        $buildPath = [string] $Settings.BuildPath
        if (-not $buildPath) { return $sha }
        try { [string] (Invoke-RestMethod "$prevAddress$buildPath" -TimeoutSec 30).commit } catch { '' }
    }
    function Add-Read {
        $before = Read-LiveCommit
        $h = Read-Health
        $after = Read-LiveCommit
        $commit = if ($before -eq $after) { $after } else { '' }
        Set-Variable -Name envReads -Scope 1 -Value (@($envReads) + @(@{ At = $h.At; Status = $h.Status; Commit = $commit }))
        if (Test-LiveCommitMatches -BuildPath ([string] $Settings.BuildPath) -LiveCommit $commit -ReleaseCommit $sha) {
            Set-Variable -Name reads -Scope 1 -Value (@($reads) + @($h))
        } else { Say "Health read $($h.Status) of $($Previous.Name) at commit '$commit': kept for the environment, not as a read of $($Release.Version)." }
    }
    if ($healthRequired -and $addressKnown -and $prevTask.State -eq 'Success') {
        Add-Read
        $now = [datetime]::UtcNow
        $deadline = Get-MasterPendingDeadline
        $budget = if ($deadline) { [int] [Math]::Max(0, ($deadline - $now).TotalSeconds + $HealthPauseSeconds) } else { $HealthWaitMaxSeconds }
        $window = @(Get-WindowReads -Own $reads -Environment $envReads -Finished $finished)
        $pause = Get-HealthWaitSeconds -Finished $finished -Now $now -Reads $window -MaxSeconds ([Math]::Min($HealthWaitMaxSeconds, $budget))
        if ($pause -ge 0 -and (Test-LiveHealthSeen -Own $reads -Environment $envReads -Finished $finished -Commit $sha)) {
            Say "Waiting $pause s for the health read that closes the window."
            Start-Sleep -Seconds $pause
            Add-Read
        }
        $state[$key] = @($reads | ForEach-Object { @{ at = $_.At.ToString('o'); status = $_.Status } })
        $state[$envKey] = @(Limit-EnvironmentReads -Reads $envReads -Now ([datetime]::UtcNow) | ForEach-Object { @{ at = $_.At.ToString('o'); status = $_.Status; commit = $_.Commit } })
        Save-State
    }
    $liveSeen = Test-LiveHealthSeen -Own $reads -Environment $envReads -Finished $finished -Commit $sha
    $reads = @(Get-WindowReads -Own $reads -Environment $envReads -Finished $finished)

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
            if ($merged.Status -eq 'behind') { return (New-BehindEvaluation -Sha $sha -BaseSha $baseSha) }
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
        HealthRequired = $healthRequired; LiveHealthSeen = $liveSeen }
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
    # -Name: deployable name for the hold title/body (defaults to $Deployable). Used when the hold is about another
    # project's stalled Queued task that blocks this run (issue #747).
    param($Release, $Target, $Evaluation, [string] $DeploymentNote = '', [string] $Name = $Deployable)
    $title = Get-HeldIssueTitle -Version $Release.Version -Environment $Target.Name -Flags @($Evaluation.Decision.Flags) -Name $Name
    $evidence = Format-HeldEvidence -Version $Release.Version -Sha $Evaluation.Sha -Target $Target.Name -Flags $Evaluation.Decision.Flags -DeploymentNote $DeploymentNote -OverrideNote ([string] $Evaluation.Decision.Note) -Name $Name
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

function Cancel-SupersededWaitingTasks {
    <# Cancel each superseded busy item waiting at MI/Sign-off so CandidateVersion can run (#731 / #733).
       DryRun only logs. Refused cancel opens or updates the hold naming the missing permission. Returns the count of
       items considered. Uses script-scope Invoke-Octopus / $space / $releases / $project / $Deployable / $DryRun. #>
    param(
        [object[]] $SupersededItems,
        $Target,
        [string] $CandidateVersion
    )
    $count = 0
    foreach ($old in @($SupersededItems)) {
        $count++
        $oldVersion = [string] (Get-BusyItemProperty $old 'ReleaseVersion')
        $oldTaskId = [string] (Get-BusyItemProperty $old 'TaskId')
        $miTitle = 'manual intervention'
        try {
            $pendingMi = (Invoke-Octopus "/api/$space/interruptions?regarding=$oldTaskId").Items | Where-Object { $_.IsPending -and $_.Type -eq 'ManualIntervention' } | Select-Object -First 1
            if ($null -ne $pendingMi) {
                $titleProp = $pendingMi.PSObject.Properties['Title']
                if ($titleProp -and $titleProp.Value) { $miTitle = [string] $titleProp.Value }
            }
        } catch { }
        Say (Format-SupersededCancelLog -TaskId $oldTaskId -ReleaseVersion $oldVersion -EnvironmentName $Target.Name -CandidateVersion $CandidateVersion -Name $Deployable -InterruptionTitle $miTitle)
        if ($DryRun) { continue }
        $cancel = Invoke-CancelOctopusTask -Space $space -TaskId $oldTaskId
        if ($cancel.Outcome -eq 'refused') {
            $perm = [string] $cancel.Permission
            Say "WARNING: Octopus refused cancel of superseded task $oldTaskId ($Deployable $oldVersion in $($Target.Name))$(if ($perm) { ": missing permission $perm" } else { '' })."
            $oldRel = (@($releases | Where-Object Version -eq $oldVersion) | Select-Object -First 1)
            if (-not $oldRel) { $oldRel = @{ Version = $oldVersion; ReleaseNotes = '' } }
            $sha = try { Get-Commit $oldRel } catch { '' }
            $dep = Get-BusyItemProperty $old 'Deployment'
            $depId = if ($null -ne $dep) { [string] (Get-BusyItemProperty $dep 'Id') } else { '' }
            Set-HeldIssue -Release $oldRel -Target $Target -Evaluation (New-TaskCancelRefusedEvaluation -Sha $sha -ProjectName $project.Name -ReleaseVersion $oldVersion -EnvironmentName $Target.Name -TaskId $oldTaskId -Permission $perm -Detail ([string] $cancel.Message)) `
                -DeploymentNote "The deployment $depId waits at a manual intervention: the auto-promote account was refused permission to cancel the superseded task."
        }
    }
    $count
}

function Test-WaitsAtPendingManualIntervention([string] $TaskId) {
    # Script-scope helper for Select-SupersededWaitingBusyItems (no GetNewClosure: Invoke-Octopus must resolve #589).
    $ints = @((Invoke-Octopus "/api/$space/interruptions?regarding=$TaskId").Items)
    Test-PendingManualIntervention -Interruptions $ints -TaskId $TaskId
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
$recoveryCanceled = $false
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
    # Behind before Decision (#739): an older waiting Sign-off whose commit is behind what already runs is cancelled,
    # never left waiting via a StrictMode throw on a missing Decision property.
    $disp = Get-RecoverySignOffDisposition -Evaluation $ev
    if ($disp.Action -eq 'cancel-superseded') {
        $candidateVersion = if ($runningBefore -and "$($runningBefore.Version)") { [string] $runningBefore.Version } `
            elseif ($ev.BaseSha) { "running $($ev.BaseSha.Substring(0, [Math]::Min(7, $ev.BaseSha.Length)))" } `
            else { 'the newer release already in the environment' }
        Cancel-SupersededWaitingTasks -SupersededItems @($b) -Target $target -CandidateVersion $candidateVersion | Out-Null
        $recoveryCanceled = $true
        continue
    }
    if ($disp.Action -eq 'hold') {
        Set-HeldIssue -Release $rel -Target $target -Evaluation $ev -DeploymentNote "The deployment $($b.Deployment.Id) was created earlier and waits at its Sign-off: a person decides."
        continue
    }
    if ($disp.Action -ne 'answer') {
        Say "Left waiting: $(@($disp.Waiting) -join '; ')"
        continue
    }
    if ($DryRun) { Say 'Dry run: would answer the Sign-off.'; continue }
    $signOff = Submit-SignOff -TaskId $b.TaskId -Reason (Format-PromotionReason -Decision $disp.Decision -Previous $previous.Name -RunUrl $RunUrl -Recovered) -WaitSeconds 0 -ProjectName $project.Name -ReleaseVersion $rel.Version -EnvironmentName $target.Name
    if ($signOff -eq 'refused') {
        $b.SignOffRefused = $true
        Set-HeldIssue -Release $rel -Target $target -Evaluation (New-SignOffRefusedEvaluation -Sha (Get-Commit $rel) -ProjectName $project.Name -ReleaseVersion $rel.Version -EnvironmentName $target.Name) -DeploymentNote "The deployment $($b.Deployment.Id) waits at its Sign-off: the auto-promote account was refused permission to take it."
    }
}
if ($recoveryCanceled -and -not $DryRun) {
    try {
        $listed = Get-ActiveBusyItemsMarked
        $busyItems = @($listed.Items)
        $activeTaskIds = @($listed.ActiveTaskIds)
    } catch { Say "Waiting: Octopus tasks could not be read whole after cancelling superseded recovery Sign-off ($($_.Exception.Message))"; Complete-AutoPromoteSuccess }
}

# 3. Candidate. Prefer an open pipeline-change hold so a newer tdd release does not restart its 60-minute clock (#688).
$preferHeld = @(Get-HeldPipelinePrefer -HeldIssues $heldIssues)
# Newest release whose health window in the previous environment is already complete (stored reads only, no new read),
# so a steady stream of newer tdd releases cannot keep restarting the 10-minute window (2026-11-24, dashboard).
$healthRequiredHere = [string] $Settings.HealthRead -ne 'none'
$windowComplete = {
    # Script-scope names: the block runs inside Select-Candidate, whose own $state (a task state) would shadow the reads.
    # Complete: the release was read Healthy while live there, and its own plus the environment's reads since it
    # finished close the window (Get-WindowReads, Test-LiveHealthSeen). Get-Evaluation then takes a fresh read, so the
    # environment must still be Healthy now.
    param($r, $prevDeployment)
    if (-not $script:healthRequiredHere) { return $true }
    $own = @(Read-StateReads $script:state ([string] $prevDeployment.Id) | ForEach-Object { @{ At = Get-Utc $_.at; Status = [string] $_.status } })
    $prevName = [string] (@($script:envs | Where-Object { $_.Id -eq $prevDeployment.EnvironmentId }) | Select-Object -First 1).Name
    $envRs = @(Read-StateReads $script:state "env-$prevName" | ForEach-Object { @{ At = Get-Utc $_.at; Status = [string] $_.status; Commit = [string] $_.commit } })
    if ((@($own) + @($envRs)).Count -lt 2) { return $false }
    # An unreadable task or release commit is not complete (the newest release is then the candidate), never a stopped run.
    if (-not $script:taskCache.ContainsKey($prevDeployment.TaskId)) { try { $script:taskCache[$prevDeployment.TaskId] = Invoke-Octopus "/api/tasks/$($prevDeployment.TaskId)" } catch { return $false } }
    $completed = $script:taskCache[$prevDeployment.TaskId].CompletedTime
    if (-not $completed) { return $false }
    $finishedAt = Get-Utc $completed
    $commit = try { [string] (Get-Commit $r) } catch { '' }
    if (-not (Test-LiveHealthSeen -Own $own -Environment $envRs -Finished $finishedAt -Commit $commit)) { return $false }
    Test-HealthWindowComplete -HealthRequired $true -Finished $finishedAt -Now ([datetime]::UtcNow) -Reads @(Get-WindowReads -Own $own -Environment $envRs -Finished $finishedAt)
}
# A failed deployment is retried only when it was this workflow's and no person answered its task (Get-RetryBlocker).
# An unreadable interruption list blocks the retry (fail closed).
$retryBlocker = {
    param($d)
    try { Get-RetryBlocker -Deployment $d -Interruptions @((Invoke-Octopus "/api/$script:space/interruptions?regarding=$($d.TaskId)").Items) }
    catch { "the interruptions of $($d.TaskId) could not be read: $($_.Exception.Message)" }
}
$candidate = Select-Candidate -Environments $envs -Releases $releases -GetDeployments { param($id) Get-ReleaseDeployments $id } -GetTaskState { param($d) Get-TaskState $d } -GetRunningOutside { param($t) Get-RunningOutsideList $t } -PreferHeld $preferHeld -GetWindowComplete $windowComplete -GetRetryBlocker $retryBlocker
$candidate.Notes | ForEach-Object { Say $_ }
if (-not $candidate.Release) {
    # No new promotion candidate: still cancel an older Sign-off/MI when a newer deployment is already Queued (#733).
    $queuedCancelCount = 0
    for ($ei = 1; $ei -lt @($envs).Count; $ei++) {
        $queuedTarget = $envs[$ei]
        $queuedBusy = Get-QueuedCandidateBusyItem -Items $busyItems -ProjectId $project.Id -TargetEnvironmentId $queuedTarget.Id
        if ($null -eq $queuedBusy) { continue }
        $queuedVersion = [string] (Get-BusyItemProperty $queuedBusy 'ReleaseVersion')
        $queuedTaskId = [string] (Get-BusyItemProperty $queuedBusy 'TaskId')
        if (-not $queuedVersion -or -not $queuedTaskId) { continue }
        $queuedRelease = (@($releases | Where-Object Version -eq $queuedVersion) | Select-Object -First 1)
        if (-not $queuedRelease) {
            $queuedRelease = @{ Version = $queuedVersion; Assembled = [datetimeoffset]'2000-01-01T00:00:00Z'; ReleaseNotes = '' }
        }
        $queuedLive = $null
        try {
            $queuedLive = Get-RunningRelease -Target $queuedTarget -Releases $releases `
                -GetDeployments { param($id) Get-ReleaseDeployments $id } `
                -GetTaskState { param($d) Get-TaskState $d } `
                -GetRunningOutside { param($t) Get-RunningOutsideList $t }
        } catch {
            if (-not (Test-RunningLookupError $_)) { throw }
            Say "The release running in $($queuedTarget.Name) is unknown while cancelling superseded tasks: $($_.Exception.Message)"
        }
        $queuedSuperseded = @(Select-SupersededWaitingBusyItems -Items $busyItems -ProjectId $project.Id -TargetEnvironmentId $queuedTarget.Id `
                -CandidateRelease $queuedRelease -LiveRelease $queuedLive -CandidateTaskId $queuedTaskId `
                -TestWaitsAtManualIntervention { param([string] $taskId) Test-WaitsAtPendingManualIntervention $taskId })
        if ($queuedSuperseded.Count -eq 0) { continue }
        $queuedCancelCount += [int] (Cancel-SupersededWaitingTasks -SupersededItems $queuedSuperseded -Target $queuedTarget -CandidateVersion $queuedVersion)
    }
    if ($queuedCancelCount -gt 0 -and -not $DryRun) {
        try {
            $listed = Get-ActiveBusyItemsMarked
            $busyItems = @($listed.Items)
            $activeTaskIds = @($listed.ActiveTaskIds)
        } catch { Say "Waiting: Octopus tasks could not be read whole after cancelling superseded tasks ($($_.Exception.Message))" }
    }
    Say "No $Deployable release waits for a next environment."
    Close-HeldIssues $candidate $activeTaskIds
    Complete-AutoPromoteSuccess
}
$release = $candidate.Release; $target = $candidate.Target; $previous = $candidate.Previous
Close-HeldIssues $candidate $activeTaskIds

# Cancel older releases waiting at a manual intervention/Sign-off so this candidate can run (#731).
$candidateTaskId = Get-CandidateBusyTaskId -Items $busyItems -ProjectId $project.Id -TargetEnvironmentId $target.Id -CandidateVersion $release.Version
$supersededWaiting = @(Select-SupersededWaitingBusyItems -Items $busyItems -ProjectId $project.Id -TargetEnvironmentId $target.Id `
        -CandidateRelease $release -LiveRelease $candidate.Running -CandidateTaskId $candidateTaskId `
        -TestWaitsAtManualIntervention { param([string] $taskId) Test-WaitsAtPendingManualIntervention $taskId })
Cancel-SupersededWaitingTasks -SupersededItems $supersededWaiting -Target $target -CandidateVersion $release.Version | Out-Null
if (@($supersededWaiting).Count -gt 0 -and -not $DryRun) {
    try {
        $listed = Get-ActiveBusyItemsMarked
        $busyItems = @($listed.Items)
        $activeTaskIds = @($listed.ActiveTaskIds)
    } catch { Say "Waiting: Octopus tasks could not be read whole after cancelling superseded tasks ($($_.Exception.Message))"; Complete-AutoPromoteSuccess }
}

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
if ($busy) {
    Say "Nothing to do: $busy."
    # Stale Queued/Waiting blocker (#747): still blocks, but open one hold when age >= threshold; safely cancel a
    # Queued deployment of this project when the live release in that environment is the same or newer.
    $blocker = Get-BlockingBusyItem -Items $busyItems -TargetEnvironmentId $target.Id -FirstEnvironmentId $first.Id -ProjectId $project.Id
    if ($blocker -and (Test-StaleQueuedHoldNeeded $blocker ([datetime]::UtcNow))) {
        $blockerTaskId = [string] (Get-BusyItemProperty $blocker 'TaskId')
        $blockerVersion = [string] (Get-BusyItemProperty $blocker 'ReleaseVersion')
        $blockerState = [string] (Get-BusyItemProperty $blocker 'State')
        $blockerAge = Get-BusyItemQueuedAgeMinutes $blocker ([datetime]::UtcNow)
        $blockerEnv = (@($envs | Where-Object Id -eq $blocker.EnvironmentId) | Select-Object -First 1)
        $blockerDepName = $Deployable
        foreach ($dn in @($projectIdByDeployable.Keys)) {
            if ($projectIdByDeployable[$dn] -eq $blocker.ProjectId) { $blockerDepName = $dn; break }
        }
        $blockerProjectName = if ($blockerDepName -and $slug) { "$slug-$blockerDepName" } else { [string] $blocker.ProjectId }
        $behindSummary = Format-QueuedBehindSummary -Items $busyItems -EnvironmentId $blocker.EnvironmentId -ExcludeTaskId $blockerTaskId
        if ($blocker.Kind -eq 'deployment' -and $blocker.ProjectId -eq $project.Id -and $blockerEnv) {
            $blockerLive = $null
            try {
                $blockerLive = Get-RunningRelease -Target $blockerEnv -Releases $releases `
                    -GetDeployments { param($id) Get-ReleaseDeployments $id } `
                    -GetTaskState { param($d) Get-TaskState $d } `
                    -GetRunningOutside { param($t) Get-RunningOutsideList $t }
            } catch {
                if (-not (Test-RunningLookupError $_)) { throw }
                Say "The release running in $($blockerEnv.Name) is unknown while considering a stale Queued cancel: $($_.Exception.Message)"
            }
            if (Test-QueuedBusySafelySupersededByLive -QueuedItem $blocker -LiveRelease $blockerLive) {
                $liveVer = [string] $blockerLive.Version
                Say "Cancelling stale Queued task $blockerTaskId ($Deployable $blockerVersion in $($blockerEnv.Name), queued ${blockerAge}m) superseded by live $liveVer."
                if (-not $DryRun) {
                    $cancel = Invoke-CancelOctopusTask -Space $space -TaskId $blockerTaskId
                    if ($cancel.Outcome -eq 'refused') {
                        $perm = [string] $cancel.Permission
                        Say "WARNING: Octopus refused cancel of stale Queued task $blockerTaskId ($Deployable $blockerVersion in $($blockerEnv.Name))$(if ($perm) { ": missing permission $perm" } else { '' })."
                        $oldRel = (@($releases | Where-Object Version -eq $blockerVersion) | Select-Object -First 1)
                        if (-not $oldRel) { $oldRel = @{ Version = $blockerVersion; ReleaseNotes = '' } }
                        $sha = try { Get-Commit $oldRel } catch { '' }
                        $dep = Get-BusyItemProperty $blocker 'Deployment'
                        $depId = if ($null -ne $dep) { [string] (Get-BusyItemProperty $dep 'Id') } else { '' }
                        Set-HeldIssue -Release $oldRel -Target $blockerEnv -Evaluation (New-TaskCancelRefusedEvaluation -Sha $sha -ProjectName $project.Name -ReleaseVersion $blockerVersion -EnvironmentName $blockerEnv.Name -TaskId $blockerTaskId -Permission $perm -Detail ([string] $cancel.Message)) `
                            -DeploymentNote "The deployment $depId is Queued and superseded by live ${liveVer}: the auto-promote account was refused permission to cancel it."
                    }
                }
                Complete-AutoPromoteSuccess
            }
        }
        if (-not $blockerEnv) { $blockerEnv = @{ Name = [string] $blocker.EnvironmentId } }
        if (-not $blockerVersion) { $blockerVersion = 'unknown' }
        $blockerRel = (@($releases | Where-Object Version -eq $blockerVersion) | Select-Object -First 1)
        if (-not $blockerRel) { $blockerRel = @{ Version = $blockerVersion; ReleaseNotes = '' } }
        $blockerSha = try { Get-Commit $blockerRel } catch { '' }
        $dep = Get-BusyItemProperty $blocker 'Deployment'
        $depId = if ($null -ne $dep) { [string] (Get-BusyItemProperty $dep 'Id') } else { '' }
        Set-HeldIssue -Release $blockerRel -Target $blockerEnv -Name $blockerDepName `
            -Evaluation (New-QueuedTaskStaleEvaluation -Sha $blockerSha -ProjectName $blockerProjectName -ReleaseVersion $blockerVersion `
                -EnvironmentName $blockerEnv.Name -TaskId $blockerTaskId -State $blockerState -AgeMinutes ([double] $blockerAge) -BehindSummary $behindSummary) `
            -DeploymentNote $(if ($depId) { "The deployment $depId is still $blockerState and blocks promotion of every deployable into or past $($blockerEnv.Name)." } else { "Task $blockerTaskId is still $blockerState and blocks promotion." })
    }
    Complete-AutoPromoteSuccess
}
Say "Candidate: $Deployable $($release.Version) to $($target.Name) (commit $(Get-Commit $release))"
# A held candidate that has waited longest gets the free slot before a newly queued release of this deployable. A person's
# hold is never bypassed: only pipeline-only holds count, and that deployable's own run still decides promote or hold.
$ownHeld = @($preferHeld | Where-Object { $_.Version -eq [string] $release.Version -and $_.Environment -eq [string] $target.Name })
if ($ownHeld.Count -eq 0) {
    $ripe = Get-RipeHeldElsewhere -HeldIssues $heldIssues -Now ([datetime]::UtcNow)
    if ($ripe) {
        Say "Yielding the slot: $($ripe.Deployable) $($ripe.Version) (hold #$($ripe.Number), $($ripe.AgeMinutes) minutes) has waited longer than the new $Deployable $($release.Version); it is promoted first."
        Complete-AutoPromoteSuccess
    }
}

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
