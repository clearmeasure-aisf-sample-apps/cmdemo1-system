#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Promotes the newest release of deployable ui to the next environment when nothing flags it, and holds it (one
    GitHub issue) when something does. One environment step per run.

.DESCRIPTION
    Owner's decision (Jeffrey Palermo, 2026-10-14): "release candidates automatically deployed to production if there
    is nothing to flag them. don't let them stop in release queue". For deployable ui only; every other deployable
    keeps a person's sign-off. Run by workflow ui-auto-promote.

    Candidate (Select-Candidate): releases newest Assembled first; the first whose latest deployment to the previous
    environment (tdd before uat, uat before prod) succeeded. It is the candidate when it has no deployment at all to the
    next environment (any state: a canceled one is a person's no) and is newer than the release running there; prod is
    looked at before uat. A newer release that ended otherwise in the previous environment is skipped and the run log says so.
    Nothing is promoted while any deployment or runbook run (any project) to the target environment, or any ui
    deployment to a later-than-first environment, is queued, running, cancelling or waiting at an interruption; a call that
    fails or a listing that is incomplete also stops the run (fail closed).
    Recovery: a deployment this workflow created (its Comments start with "Promoted by workflow ui-auto-promote") that waits at
    its Sign-off is evaluated again; no flag: its Sign-off is answered; a flag: it stays waiting and the held issue says so.

    The four flags (Get-PromotionDecision), and what makes the run wait (nothing promoted, nothing flagged):
      1 checks   Flag: a check run of the release's commit in the application repository that ended failure, cancelled,
                 timed_out, action_required, startup_failure, stale or without a conclusion, or a commit status failure or
                 error. skipped and neutral pass. Wait: a check run not completed, a status pending, no check yet, or a
                 listing that could not be read whole.
      2 deployment  Flag: the deployment to the previous environment is not Success; its task log is unreadable (under 20
                 lines or without its "Task ID:" header); the log has a line at Error, Warning or Fatal level or a step
                 SuccessWithWarning (the kit's test-deployment-logs.ps1 rule, plus Fatal, which a real failed ui task
                 logs); or a /_healthcheck/detailed read since it finished was not Healthy (a single unreachable read
                 flags: safe side). Health rule: no read since the deployment finished is not Healthy, at least two reads
                 are Healthy and at least 5 minutes apart, and the later one is at least 10 minutes after the deployment
                 finished. Else wait. A ui address that is not known: wait ("health address unknown").
      3 pipeline  Compared with the commit running in the next environment (/_build "commit", else the commit in the notes of
                 the release running there), a changed path (a renamed file counts both names) outside src/, or a build
                 or project file anywhere in src/ (BuildFiles list), unless it is documentation (DocumentationPaths list:
                 docs/**, arch/**, *.md anywhere, including .github/x.md). src/Database/ never flags (owner, 2026-10-14).
                 A comparison that is unknown or incomplete (no base commit, more than 250 commits, 300 files or more, a
                 read failed) flags as "comparison incomplete".
      4 hold      Flag: a pull request in the commits between those two, or an issue they close or reference (#N and
                 owner/repo#N in titles, bodies and commit messages, GitHub's closing references) labelled Hold (case
                 ignored). Wait: any read of that chain failed or was cut (more than 300 items).

    Flagged: the deployment is NOT created, so no Sign-off waits in the environment and holds it for every other
    deployable. One issue "ui <version> held before <env>" (label release-held, no assignee) lists each flag with its
    evidence; it is edited only when the evidence changes. It closes when that release has a deployment in the environment
    that no longer waits for this workflow, or a newer release is the candidate or runs there already.

.PARAMETER LoadOnly
    Defines the functions and stops (for the tests).
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
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
# Build and project files that flag wherever they are in src/ (file names, or *.ext).
$BuildFiles = @('Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json', 'nuget.config',
    '*.csproj', '*.sln', '*.slnx', '*.props', '*.targets', 'Dockerfile*')
# Under src/, never a flag.
$UnflaggedFolders = @('src/Database/')
$PromotionMarker = 'Promoted by workflow ui-auto-promote'

function ConvertTo-GlobRegex([string] $Glob) {
    $r = [regex]::Escape($Glob) -replace '\\\*\\\*/', '(?:.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*'
    "^$r$"
}
function Test-GlobMatch([string] $Path, [string[]] $Globs) {
    foreach ($g in $Globs) { if ($Path -imatch (ConvertTo-GlobRegex $g)) { return $true } }
    $false
}

function Get-PipelineEvidence {
    param([string[]] $Paths, [string[]] $Documentation = $DocumentationPaths, [string[]] $Build = $BuildFiles, [string[]] $Unflagged = $UnflaggedFolders)
    foreach ($p in @($Paths | Where-Object { $_ })) {
        if (Test-GlobMatch $p $Documentation) { continue }
        if ($Unflagged | Where-Object { $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) { continue }
        if (-not $p.StartsWith('src/', [StringComparison]::OrdinalIgnoreCase)) { "$p (outside src/)"; continue }
        if (Test-GlobMatch ($p.Split('/')[-1]) $Build) { "$p (build or project file)" }
    }
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

function Get-PromotionDecision {
    <# Facts: Checks, PathsKnown, PathsReason, Paths, HoldItems, HoldUnknown (reasons), PreviousState, LogFindings, Finished,
       Now, HealthReads, HealthAddressKnown. Returns @{ Decision = promote|hold|wait; Flags; Waiting; Passed }. #>
    param([hashtable] $Facts)
    $flags = [Collections.Generic.List[object]]::new()
    $waiting = [Collections.Generic.List[string]]::new()

    $c = Get-CheckFindings -Checks @($Facts.Checks)
    if ($c.Failed.Count -gt 0) { $flags.Add(@{ Flag = 'Red build or tests'; Evidence = @($c.Failed | ForEach-Object { "$($_.Name) $($_.Url)".Trim() }) }) }
    if ($c.Pending.Count -gt 0) { $waiting.Add("checks not finished: $(@($c.Pending | ForEach-Object Name) -join ', ')") }
    if (@($Facts.Checks).Count -eq 0) { $waiting.Add('no check has reported on the commit yet') }

    $d = [Collections.Generic.List[string]]::new()
    if ($Facts.PreviousState -ne 'Success') { $d.Add("the deployment to the previous environment ended $($Facts.PreviousState)") }
    foreach ($l in @($Facts.LogFindings)) { if ($l) { $d.Add("log: $l") } }
    if ($d.Count -eq 0) {
        if (-not $Facts.HealthAddressKnown) { $waiting.Add('health address unknown: the address of ui in the previous environment could not be read') }
        else {
            $h = Get-HealthVerdict -Finished $Facts.Finished -Now $Facts.Now -Reads @($Facts.HealthReads)
            if ($h -eq 'fail') { $d.Add("health: /_healthcheck/detailed was not Healthy: $(@($Facts.HealthReads | Where-Object { $_.Status -ne 'Healthy' } | ForEach-Object { "$($_.Status) at $($_.At.ToString('u'))" }) -join '; ')") }
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
    @{ Decision = $decision; Flags = @($flags); Waiting = @($waiting); Passed = @($c.Passed | ForEach-Object Name) }
}

function Get-BusyReason {
    # Items: @{ Kind = deployment|runbook; ProjectId; EnvironmentId } of every task that is not finished.
    param([object[]] $Items, [string] $TargetEnvironmentId, [string] $FirstEnvironmentId, [string] $ProjectId)
    foreach ($i in @($Items)) {
        if ($i.EnvironmentId -eq $TargetEnvironmentId) { return "a $($i.Kind) of project $($i.ProjectId) to the target environment is not finished" }
        if ($i.Kind -eq 'deployment' -and $i.ProjectId -eq $ProjectId -and $i.EnvironmentId -ne $FirstEnvironmentId) { return 'a ui deployment is not finished in another environment' }
    }
}

function Select-Candidate {
    <# Environments ordered; Releases (Id, Version, Assembled); GetDeployments {param($releaseId)} -> deployments (Id, ReleaseId,
       EnvironmentId, TaskId, Created); GetTaskState {param($deployment)} -> Octopus task state. Returns
       @{ Release; Target; Previous; RunningReleaseId; Notes } or $null with Notes. Looks at the last environment first. #>
    param([object[]] $Environments, [object[]] $Releases, [scriptblock] $GetDeployments, [scriptblock] $GetTaskState)
    $sorted = @($Releases | Sort-Object { [datetimeoffset] $_.Assembled } -Descending)
    $cache = @{}
    $deps = { param($r) if (-not $cache.ContainsKey($r.Id)) { $cache[$r.Id] = @(& $GetDeployments $r.Id) }; $cache[$r.Id] }
    $notes = [Collections.Generic.List[string]]::new()
    for ($i = $Environments.Count - 1; $i -ge 1; $i--) {
        $target = $Environments[$i]; $previous = $Environments[$i - 1]
        $skipped = $null
        foreach ($r in $sorted) {
            $here = @(& $deps $r)
            $prev = @($here | Where-Object { $_.EnvironmentId -eq $previous.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending) | Select-Object -First 1
            if (-not $prev) { continue }
            $state = & $GetTaskState $prev
            if ($state -ne 'Success') { if (-not $skipped) { $skipped = "$($r.Version) ended $state in $($previous.Name)" }; continue }
            if (@($here | Where-Object { $_.EnvironmentId -eq $target.Id }).Count -gt 0) { break }
            # Newer than the release running in the target?
            $runningId = $null
            foreach ($o in $sorted) {
                $ran = @(& $deps $o | Where-Object { $_.EnvironmentId -eq $target.Id } | Sort-Object { [datetimeoffset] $_.Created } -Descending | Where-Object { (& $GetTaskState $_) -eq 'Success' }) | Select-Object -First 1
                if ($ran) { $runningId = $o.Id; break }
            }
            if ($runningId -eq $r.Id) { break }
            if ($runningId) {
                $running = $sorted | Where-Object Id -eq $runningId
                if ([datetimeoffset] $running.Assembled -ge [datetimeoffset] $r.Assembled) { break }
            }
            if ($skipped) { $notes.Add("newer release ${skipped}: the older release $($r.Version) is considered for $($target.Name)") }
            return @{ Release = $r; Target = $target; Previous = $previous; RunningReleaseId = $runningId; Notes = @($notes) }
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

function Merge-ComparePages {
    # Pages of GET compare: paths, unique commits, status, and whether everything was read (cap: 250 commits, 300 files).
    param([object[]] $Pages)
    $paths = @(); $commits = @()
    foreach ($p in $Pages) {
        foreach ($f in @($p.files)) { $paths += $f.filename; if ($f.PSObject.Properties['previous_filename'] -and $f.previous_filename) { $paths += $f.previous_filename } }
        $commits += @($p.commits)
    }
    $commits = @($commits | Sort-Object { $_.sha } -Unique)
    $last = $Pages[-1]
    $fileCount = @($Pages | ForEach-Object { @($_.files).Count } | Measure-Object -Sum).Sum
    $reason = $null
    if ($last.total_commits -gt 250) { $reason = "$($last.total_commits) commits (more than 250)" }
    elseif ($commits.Count -lt $last.total_commits) { $reason = "$($commits.Count) of $($last.total_commits) commits read" }
    elseif ($fileCount -ge 300) { $reason = "$fileCount files (300 or more)" }
    @{ Paths = $paths; Commits = $commits; Status = $last.status; Known = ($null -eq $reason); Reason = $reason }
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
       GetClosing {param($pullNumber)} -> issue refs (@{Repo;Number}); GetItem {param($repo,$number)} -> @{Number;Url;Labels}.
       Any scriptblock may throw: that becomes an entry of Unknown. #>
    param([object[]] $Commits, [string] $Repo, [scriptblock] $GetPulls, [scriptblock] $GetClosing, [scriptblock] $GetItem, [int] $Max = 300)
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
    if ($todo.Count -gt $Max) { $unknown.Add("$($todo.Count) referenced items (more than $Max)"); $todo = @($todo | Select-Object -First $Max) }
    foreach ($k in $todo) {
        $r = $refs[$k]
        try { $items[$k] = & $GetItem $r.Repo $r.Number } catch { $unknown.Add("$k not read") }
    }
    @{ Items = @($items.Values); Unknown = @($unknown) }
}

function Read-State {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{} }
    try { $s = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable; if ($s -is [hashtable]) { return $s } } catch { }
    Write-Host "State file $Path is corrupt: starting with an empty one."
    @{}
}

function Get-EvidenceHash([string] $Text) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).Substring(0, 16).ToLowerInvariant() }

function Format-HeldEvidence {
    param([string] $Version, [string] $Sha, [string] $Target, [object[]] $Flags, [string] $DeploymentNote = '')
    $b = "ui $Version (commit $Sha) is not promoted to $Target automatically. Flags:`n"
    foreach ($f in $Flags) { $b += "`n**$($f.Flag)**`n" + (($f.Evidence | ForEach-Object { "- $_" }) -join "`n") + "`n" }
    $b += "`nRules: health needs no read since the deployment finished that is not Healthy, two Healthy reads at least 5 minutes apart, the later one at least 10 minutes after the deployment finished; a single unreachable read flags."
    if ($DeploymentNote) { $b += "`n$DeploymentNote" } else { $b += "`nNo deployment was created. A person promotes it in Octopus (the Sign-off waits for them)." }
    $b
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

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$octopus = ([string] $system.octopus.url).TrimEnd('/')
$space = [string] $system.octopus.spaceId
$ownRepo = "$($system.system.githubOrg)/$($system.system.repository)"
$app = @($system.deployables | Where-Object { $_.name -eq $Deployable })[0]
$appRepo = "$($system.system.githubOrg)/$($app.repository)"
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
    param([string] $TaskId, [string] $Reason, [int] $WaitSeconds = 900)
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $list = Invoke-Octopus "/api/$space/interruptions?regarding=$TaskId"
        $a = Get-SignOffAction -Interruptions @($list.Items) -TaskId $TaskId
        switch ($a.Action) {
            'yield' { Say "A person holds the Sign-off ($($a.Interruption.Id)): theirs."; return }
            'answered' { Say 'Sign-off already answered.'; return }
            'answer' {
                if (-not $a.Interruption.HasResponsibility) { Invoke-Octopus "/api/$space/interruptions/$($a.Interruption.Id)/responsible" 'Put' | Out-Null }
                Invoke-Octopus "/api/$space/interruptions/$($a.Interruption.Id)/submit" 'Post' @{ Notes = $Reason; Result = 'Proceed' } | Out-Null
                Say "Signed off ($($a.Interruption.Id))."; return
            }
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    Say 'No Sign-off appeared.'
}

# Environments, project, releases.
$envs = @(Invoke-Octopus "/api/$space/environments/all" | Sort-Object SortOrder)
$project = @(Invoke-Octopus "/api/$space/projects/all" | Where-Object { $_.Name -eq "$slug-$Deployable" })[0]
if (-not $project) { throw "project $slug-$Deployable not found" }
$first = $envs[0]
$releases = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/releases?take=40").Items)
$taskCache = @{}
function Get-TaskState($d) { if (-not $taskCache.ContainsKey($d.TaskId)) { $taskCache[$d.TaskId] = Invoke-Octopus "/api/tasks/$($d.TaskId)" }; $taskCache[$d.TaskId].State }
function Get-ReleaseDeployments($releaseId) { Get-OctopusAll "/api/$space/releases/$releaseId/deployments" }
function Get-Commit($release) { if ($release -and "$($release.ReleaseNotes)" -match 'of ([0-9a-f]{40})') { $Matches[1] } }

$heldIssues = @(& gh issue list -R $ownRepo --label release-held --state open --json number,title,body --limit 50 | ConvertFrom-Json)
$addresses = try { (Invoke-RestMethod "https://raw.githubusercontent.com/$ownRepo/status/containers.json").environments } catch { $null }
$state = Read-State $StatePath
function Save-State {
    if (-not $StatePath) { return }
    $cut = [datetime]::UtcNow.AddDays(-2)
    $keep = @{}
    foreach ($k in $state.Keys) { $r = @($state[$k]); if ($r.Count -gt 0 -and (Get-Utc $r[-1].at) -gt $cut) { $keep[$k] = $r } }
    $keep | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath
}

function Get-Evaluation {
    param($Release, $Target, $Previous, $RunningRelease)
    $sha = Get-Commit $Release
    if (-not $sha) { throw "release $($Release.Version) names no commit in its notes" }
    $facts = @{ HoldUnknown = @() }

    # 1. Checks
    $checks = [Collections.Generic.List[object]]::new(); $page = 1
    do {
        $r = Invoke-Gh @("repos/$appRepo/commits/$sha/check-runs?per_page=100&page=$page")
        foreach ($c in @($r.check_runs)) { $checks.Add(@{ Name = $c.name; State = ConvertTo-CheckState $c.status $c.conclusion; Url = $c.html_url }) }
        $page++
    } while (@($r.check_runs).Count -eq 100 -and $page -le 10)
    if ($r.total_count -gt $checks.Count) { $checks.Add(@{ Name = "check list incomplete ($($checks.Count) of $($r.total_count))"; State = 'pending'; Url = '' }) }
    $s = Invoke-Gh @("repos/$appRepo/commits/$sha/status?per_page=100")
    foreach ($c in @($s.statuses)) { $checks.Add(@{ Name = $c.context; State = ConvertTo-StatusState $c.state; Url = $c.target_url }) }
    if ($s.total_count -gt @($s.statuses).Count) { $checks.Add(@{ Name = 'status list incomplete'; State = 'pending'; Url = '' }) }

    # 2. Previous deployment: state, log, health
    $prevDeployment = @(Get-ReleaseDeployments $Release.Id | Where-Object { $_.EnvironmentId -eq $Previous.Id } | Sort-Object { Get-Utc $_.Created } -Descending)[0]
    $prevTask = Invoke-Octopus "/api/tasks/$($prevDeployment.TaskId)"
    $finished = Get-Utc $prevTask.CompletedTime
    $warned = @((Invoke-Octopus "/api/tasks/$($prevTask.Id)/details?verbose=false").ActivityLogs[0].Children | Where-Object { $_.Status -eq 'SuccessWithWarning' } | ForEach-Object Name)
    $raw = try { [string] (Invoke-Octopus "/api/tasks/$($prevTask.Id)/raw") } catch { '' }
    $findings = @(Get-LogFindings -Raw $raw -TaskId $prevTask.Id -WarnedSteps $warned)
    $key = [string] $prevDeployment.Id
    $stored = if ($state.ContainsKey($key)) { @($state[$key]) } else { @() }
    $reads = @($stored | ForEach-Object { @{ At = Get-Utc $_.at; Status = [string] $_.status } })
    $prevAddress = if ($addresses) { [string] $addresses.($Previous.Name).$Deployable } else { '' }
    $addressKnown = [bool] $prevAddress
    function Read-Health {
        $status = try { [string] (Invoke-RestMethod -Uri "$prevAddress/_healthcheck/detailed" -TimeoutSec 30 -SkipHttpErrorCheck).overallStatus } catch { 'Unreachable' }
        if (-not $status) { $status = 'Unreachable' }
        @{ At = [datetime]::UtcNow; Status = $status }
    }
    if ($addressKnown -and $prevTask.State -eq 'Success') {
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
    $baseAddress = if ($addresses) { [string] $addresses.($Target.Name).$Deployable } else { '' }
    if ($baseAddress) { $baseSha = try { [string] (Invoke-RestMethod "$baseAddress/_build" -TimeoutSec 30).commit } catch { $null } }
    if ($baseSha -notmatch '^[0-9a-f]{40}$') { $baseSha = Get-Commit $RunningRelease }
    $pathsKnown = $false; $pathsReason = 'no base commit: neither /_build nor the running release names one'; $paths = @(); $holdItems = @()
    if ($baseSha -match '^[0-9a-f]{40}$') {
        try {
            $pages = @(); $page = 1
            do {
                $cmp = Invoke-Gh @("repos/$appRepo/compare/${baseSha}...${sha}?per_page=100&page=$page")
                $pages += $cmp
                $merged = Merge-ComparePages -Pages $pages
                $page++
            } while ($merged.Commits.Count -lt $cmp.total_commits -and $page -le 5 -and @($cmp.commits).Count -gt 0)
            $paths = $merged.Paths; $pathsKnown = $merged.Known; $pathsReason = $merged.Reason
            if ($merged.Status -eq 'behind') { return @{ Behind = $true; Sha = $sha; BaseSha = $baseSha } }
            $hold = Get-HoldFacts -Commits $merged.Commits -Repo $appRepo `
                -GetPulls { param($c) $r = @(); $pg = 1; do { $x = @(Invoke-Gh @("repos/$appRepo/commits/$c/pulls?per_page=100&page=$pg")); $r += $x; $pg++ } while ($x.Count -eq 100 -and $pg -le 5); $r } `
                -GetClosing { param($n)
                    $q = 'query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){closingIssuesReferences(first:50){nodes{number repository{nameWithOwner}}}}}}'
                    $g = (& gh api graphql -f query=$q -f "o=$($system.system.githubOrg)" -f "r=$($app.repository)" -F "n=$n") | ConvertFrom-Json
                    @($g.data.repository.pullRequest.closingIssuesReferences.nodes | ForEach-Object { @{ Repo = $_.repository.nameWithOwner; Number = [int] $_.number } }) } `
                -GetItem { param($repo, $n) $it = Invoke-Gh @("repos/$repo/issues/$n"); @{ Number = $n; Url = $it.html_url; Labels = @($it.labels | ForEach-Object name) } }
            $holdItems = $hold.Items; $facts.HoldUnknown = $hold.Unknown
        } catch { $pathsKnown = $false; $pathsReason = "comparison failed: $($_.Exception.Message)" }
    }
    $facts += @{ Checks = $checks; PathsKnown = $pathsKnown; PathsReason = $pathsReason; Paths = $paths; HoldItems = $holdItems; PreviousState = $prevTask.State
        LogFindings = $findings; Finished = $finished; Now = [datetime]::UtcNow; HealthReads = $reads; HealthAddressKnown = $addressKnown }
    @{ Behind = $false; Sha = $sha; BaseSha = $baseSha; Decision = (Get-PromotionDecision -Facts $facts) }
}

function Set-HeldIssue {
    param($Release, $Target, $Evaluation, [string] $DeploymentNote = '')
    $title = "ui $($Release.Version) held before $($Target.Name)"
    $evidence = Format-HeldEvidence -Version $Release.Version -Sha $Evaluation.Sha -Target $Target.Name -Flags $Evaluation.Decision.Flags -DeploymentNote $DeploymentNote
    $hash = Get-EvidenceHash $evidence
    $body = "$evidence`n`nRun $RunUrl`n<!-- evidence:$hash -->"
    Say $evidence
    if ($DryRun) { return }
    & gh label create release-held --color B60205 --description 'A release is held before an environment by the automatic promotion' -R $ownRepo --force | Out-Null
    $existing = @($heldIssues | Where-Object { $_.title -eq $title })[0]
    if (-not $existing) { & gh issue create -R $ownRepo --title $title --label release-held --body $body | Out-Null }
    elseif ($existing.body -notmatch "evidence:$hash") { & gh issue edit $existing.number -R $ownRepo --body $body | Out-Null }
    else { Say "Issue #$($existing.number) already says this." }
}

function Close-HeldIssues {
    # Closes an issue when its release got a deployment that does not wait for this workflow, or a newer release is the
    # candidate or runs in that environment.
    param($Candidate, [object[]] $ActiveTaskIds)
    foreach ($i in $heldIssues) {
        if ($i.title -notmatch '^ui (\S+) held before (\S+)$') { continue }
        $version = $Matches[1]; $envName = $Matches[2]
        if ($Candidate.Release -and $Candidate.Release.Version -eq $version -and $Candidate.Target.Name -eq $envName) { continue }
        $rel = @($releases | Where-Object Version -eq $version)[0]
        $env = @($envs | Where-Object Name -eq $envName)[0]
        $why = $null
        if ($rel -and $env) {
            $deps = @(Get-ReleaseDeployments $rel.Id | Where-Object { $_.EnvironmentId -eq $env.Id })
            if (@($deps | Where-Object { $_.TaskId -notin $ActiveTaskIds }).Count -gt 0) { $why = "ui $version has a deployment to $envName." }
            elseif ($Candidate.Release -and $Candidate.Target.Id -eq $env.Id -and [datetimeoffset] $Candidate.Release.Assembled -gt [datetimeoffset] $rel.Assembled) { $why = "ui $($Candidate.Release.Version), a newer release, is the candidate for $envName." }
        }
        if ($why) { Say "closing issue #$($i.number): $why"; if (-not $DryRun) { & gh issue close $i.number -R $ownRepo --comment "$why $RunUrl" | Out-Null } }
    }
}

# 1. What is not finished: any project, deployments and runbook runs. A failed call or an incomplete listing stops the run.
try {
    $active = @(Get-OctopusAll "/api/$space/tasks?active=true") + @(Get-OctopusAll "/api/$space/tasks?states=Cancelling")
    $busyItems = @(); $activeTaskIds = @()
    foreach ($t in @($active | Sort-Object Id -Unique)) {
        $activeTaskIds += $t.Id
        if ($t.Name -eq 'Deploy') { $d = Invoke-Octopus "/api/$space/deployments/$($t.Arguments.DeploymentId)"; $busyItems += @{ Kind = 'deployment'; ProjectId = $d.ProjectId; EnvironmentId = $d.EnvironmentId; Deployment = $d; TaskId = $t.Id } }
        elseif ($t.Name -eq 'RunbookRun') { $d = Invoke-Octopus "/api/$space/runbookRuns/$($t.Arguments.RunbookRunId)"; $busyItems += @{ Kind = 'runbook'; ProjectId = $d.ProjectId; EnvironmentId = $d.EnvironmentId; TaskId = $t.Id } }
    }
} catch { Say "Waiting: Octopus tasks could not be read whole ($($_.Exception.Message))"; return }

# 2. Recovery: a deployment this workflow created that waits at its Sign-off.
foreach ($b in @($busyItems | Where-Object { $_.Kind -eq 'deployment' -and $_.ProjectId -eq $project.Id -and $_.EnvironmentId -ne $first.Id -and "$($_.Deployment.Comments)".StartsWith($PromotionMarker) })) {
    $pending = Get-SignOffAction -Interruptions @((Invoke-Octopus "/api/$space/interruptions?regarding=$($b.TaskId)").Items) -TaskId $b.TaskId
    if ($pending.Action -ne 'answer') { continue }
    $rel = @($releases | Where-Object Id -eq $b.Deployment.ReleaseId)[0]
    $tIndex = [array]::IndexOf(@($envs | ForEach-Object Id), $b.EnvironmentId)
    $target = $envs[$tIndex]; $previous = $envs[$tIndex - 1]
    Say "Recovery: ui $($rel.Version) waits at its Sign-off in $($target.Name) ($($b.TaskId))."
    $ev = Get-Evaluation -Release $rel -Target $target -Previous $previous -RunningRelease $null
    if ($ev.Behind -or $ev.Decision.Decision -ne 'promote') {
        if (-not $ev.Behind -and $ev.Decision.Decision -eq 'hold') { Set-HeldIssue -Release $rel -Target $target -Evaluation $ev -DeploymentNote "The deployment $($b.Deployment.Id) was created earlier and waits at its Sign-off: a person decides." }
        else { Say "Left waiting: $(@($ev.Decision.Waiting) -join '; ')" }
        continue
    }
    if ($DryRun) { Say 'Dry run: would answer the Sign-off.'; continue }
    Submit-SignOff -TaskId $b.TaskId -Reason "Auto-promoted (recovered): no flag. checks green ($($ev.Decision.Passed.Count) passed), deployment and health ok in $($previous.Name), no pipeline change, no Hold label; run $RunUrl" -WaitSeconds 0
}

# 3. Candidate.
$candidate = Select-Candidate -Environments $envs -Releases $releases -GetDeployments { param($id) Get-ReleaseDeployments $id } -GetTaskState { param($d) Get-TaskState $d }
$candidate.Notes | ForEach-Object { Say $_ }
if (-not $candidate.Release) { Say 'No ui release waits for a next environment.'; Close-HeldIssues $candidate $activeTaskIds; return }
$release = $candidate.Release; $target = $candidate.Target; $previous = $candidate.Previous
Close-HeldIssues $candidate $activeTaskIds
$busy = Get-BusyReason -Items $busyItems -TargetEnvironmentId $target.Id -FirstEnvironmentId $first.Id -ProjectId $project.Id
if ($busy) { Say "Nothing to do: $busy."; return }
Say "Candidate: ui $($release.Version) to $($target.Name) (commit $(Get-Commit $release))"

$running = @($releases | Where-Object Id -eq $candidate.RunningReleaseId)[0]
$ev = Get-Evaluation -Release $release -Target $target -Previous $previous -RunningRelease $running
if ($ev.Behind) { Say "commit $($ev.Sha) is behind the running $($ev.BaseSha): not promoted."; return }
$decision = $ev.Decision
Say "Decision: $($decision.Decision)"
if ($decision.Decision -eq 'wait') { $decision.Waiting | ForEach-Object { Say "  waiting: $_" }; return }
if ($decision.Decision -eq 'hold') { Set-HeldIssue -Release $release -Target $target -Evaluation $ev; return }

$reason = "Auto-promoted: no flag. checks green ($($decision.Passed.Count) passed), deployment and health ok in $($previous.Name), no pipeline change, no Hold label; run $RunUrl"
Say $reason
if ($DryRun) { return }
$created = Invoke-Octopus "/api/$space/deployments" 'Post' @{ ReleaseId = $release.Id; EnvironmentId = $target.Id; Comments = "${PromotionMarker}: $RunUrl" }
Say "Deployment $($created.Id) to $($target.Name) (task $($created.TaskId))"
Submit-SignOff -TaskId $created.TaskId -Reason $reason
