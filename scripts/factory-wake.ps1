#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    After env-checks finishes on a cm-ai-ops-bot pull request, nudge the factory bot by re-assigning the linked issue(s).

.DESCRIPTION
    Workflow factory-wake runs this when workflow env-checks completes. It acts only for a pull_request run whose head
    branch is not the default branch, whose conclusion is success or failure, whose open pull request is by
    cm-ai-ops-bot, and whose linked issues still need a Review or fix. For each such issue it removes and re-adds the
    cm-ai-ops-bot assignee (assigner becomes github-actions[bot]), which fires the bot's existing issue-assigned
    listener. It posts no comments and uses only GITHUB_TOKEN. Dedupe: skip an issue if cm-ai-ops-bot was assigned on
    it in the last 10 minutes, or if it already has a Review verdict comment posted after the pull request's head
    commit date.

.PARAMETER Repository
    owner/name of this repository.
.PARAMETER Event
    The completed run's event (pull_request).
.PARAMETER Conclusion
    The completed run's conclusion (success or failure).
.PARAMETER HeadBranch
    The completed run's head branch.
.PARAMETER HeadSha
    The completed run's head commit SHA.
.PARAMETER DefaultBranch
    The repository default branch (runs whose head is this branch are ignored).
.PARAMETER BotLogin
    The factory bot login to re-assign.
.PARAMETER DedupeMinutes
    Skip when the bot was assigned on the issue within this many minutes.
.PARAMETER Now
    Clock for the recent-assign window (UTC). Tests pass a fixed instant.
.PARAMETER DryRun
    Decide and log; change no assignees.
.PARAMETER LoadOnly
    Define the functions and return (scripts/test-factory-wake.ps1).
.EXAMPLE
    pwsh -NoProfile -File scripts/factory-wake.ps1 -Repository clearmeasure-aisf-sample-apps/cmdemo1-system `
      -Event pull_request -Conclusion success -HeadBranch cm-ai-ops-bot/x -HeadSha abc -DefaultBranch main
#>
[CmdletBinding()]
param(
    [string] $Repository = '',
    [string] $Event = '',
    [string] $Conclusion = '',
    [string] $HeadBranch = '',
    [string] $HeadSha = '',
    [string] $DefaultBranch = 'main',
    [string] $BotLogin = 'cm-ai-ops-bot',
    [int] $DedupeMinutes = 10,
    [datetime] $Now = [datetime]::SpecifyKind([datetime]::UtcNow, [DateTimeKind]::Utc),
    [switch] $DryRun,
    [switch] $LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$script:VerdictPrefixes = @('Review → Merged', 'Review → Done', 'Review → In Progress')
$script:ClosesPattern = '(?im)\bCloses\s+#(?<n>\d+)\b'

function Get-FactValue($Object, [string] $Name) {
    # Value of a property or hashtable key; $null when missing (Safe for StrictMode).
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-RunGate {
    # Whether the completed workflow_run itself is one we may act on. Returns Action skip|consider and a Reason.
    param(
        [string] $Event,
        [string] $Conclusion,
        [string] $HeadBranch,
        [string] $DefaultBranch
    )
    if ($Event -cne 'pull_request') {
        return [ordered] @{ Action = 'skip'; Reason = "run event is '$Event', not pull_request" }
    }
    if ($Conclusion -notin @('success', 'failure')) {
        return [ordered] @{ Action = 'skip'; Reason = "run conclusion is '$Conclusion', not success or failure" }
    }
    if (-not $HeadBranch) {
        return [ordered] @{ Action = 'skip'; Reason = 'run has no head branch' }
    }
    if ($HeadBranch -ceq $DefaultBranch) {
        return [ordered] @{ Action = 'skip'; Reason = "head branch '$HeadBranch' is the default branch" }
    }
    return [ordered] @{ Action = 'consider'; Reason = "pull_request run on '$HeadBranch' concluded $Conclusion" }
}

function Get-PullRequestGate {
    # Whether the open pull request at the run's head is one we may act on.
    param(
        $PullRequest,
        [string] $BotLogin
    )
    if ($null -eq $PullRequest) {
        return [ordered] @{ Action = 'skip'; Reason = 'no open pull request for the run head' }
    }
    $number = [int] $PullRequest.number
    $author = [string] $PullRequest.author
    $state = [string] $PullRequest.state
    if ($state -cne 'OPEN' -and $state -cne 'open') {
        return [ordered] @{ Action = 'skip'; Reason = "pull request #${number} is $state, not open" }
    }
    if ($author -cne $BotLogin) {
        return [ordered] @{ Action = 'skip'; Reason = "pull request #${number} author is '$author', not $BotLogin" }
    }
    return [ordered] @{ Action = 'consider'; Reason = "open bot pull request #${number}" }
}

function Get-ClosingIssueNumbers {
    # Issues the pull request closes: GraphQL closingIssuesReferences when present, else Closes #N in the body.
    param(
        [int[]] $ClosingReferences,
        [string] $Body
    )
    $fromRefs = @($ClosingReferences | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($fromRefs.Count -gt 0) { return @($fromRefs) }
    $fromBody = [Collections.Generic.List[int]]::new()
    foreach ($m in [regex]::Matches([string] $Body, $script:ClosesPattern)) {
        $n = [int] $m.Groups['n'].Value
        if ($n -gt 0 -and -not $fromBody.Contains($n)) { $fromBody.Add($n) }
    }
    return @($fromBody.ToArray())
}

function Test-BotAssignedRecently {
    # True when an AssignedEvent for the bot falls within the dedupe window ending at Now.
    param(
        [object[]] $AssignedEvents,
        [string] $BotLogin,
        [datetime] $Now,
        [int] $Minutes
    )
    $cutoff = $Now.ToUniversalTime().AddMinutes(-1 * $Minutes)
    foreach ($ev in @($AssignedEvents)) {
        $login = [string] $ev.assignee
        if ($login -cne $BotLogin) { continue }
        $at = [datetime]::SpecifyKind([datetime] $ev.createdAt, [DateTimeKind]::Utc)
        if ($at -ge $cutoff) { return $true }
    }
    return $false
}

function Test-ReviewVerdictAfterHead {
    # True when an issue comment starting with a Review verdict prefix was posted after the head commit date.
    param(
        [object[]] $Comments,
        [datetime] $HeadCommitDate
    )
    $after = $HeadCommitDate.ToUniversalTime()
    foreach ($c in @($Comments)) {
        $body = [string] $c.body
        $created = [datetime]::SpecifyKind([datetime] $c.createdAt, [DateTimeKind]::Utc)
        if ($created -le $after) { continue }
        foreach ($prefix in $script:VerdictPrefixes) {
            if ($body.StartsWith($prefix, [StringComparison]::Ordinal)) { return $true }
        }
    }
    return $false
}

function Get-IssueNudgeDecision {
    # Per linked issue: nudge (re-assign), or skip with reason.
    param(
        [int] $IssueNumber,
        [object[]] $AssignedEvents,
        [object[]] $Comments,
        [datetime] $HeadCommitDate,
        [string] $BotLogin,
        [datetime] $Now,
        [int] $DedupeMinutes
    )
    if (Test-BotAssignedRecently -AssignedEvents $AssignedEvents -BotLogin $BotLogin -Now $Now -Minutes $DedupeMinutes) {
        return [ordered] @{
            Issue  = $IssueNumber
            Action = 'skip'
            Reason = "cm-ai-ops-bot was assigned on #${IssueNumber} within the last $DedupeMinutes minutes"
        }
    }
    if (Test-ReviewVerdictAfterHead -Comments $Comments -HeadCommitDate $HeadCommitDate) {
        return [ordered] @{
            Issue  = $IssueNumber
            Action = 'skip'
            Reason = "issue #${IssueNumber} already has a Review verdict comment after the head commit"
        }
    }
    return [ordered] @{
        Issue  = $IssueNumber
        Action = 'nudge'
        Reason = "re-assign $BotLogin on #${IssueNumber} (CI finished)"
    }
}

function Get-FactoryWakePlan {
    # Full plan for one completed run: run gate, pull request gate, then per-issue decisions.
    param(
        [string] $Event,
        [string] $Conclusion,
        [string] $HeadBranch,
        [string] $DefaultBranch,
        $PullRequest,
        [int[]] $ClosingReferences,
        [object[]] $Issues,
        [string] $BotLogin,
        [datetime] $Now,
        [int] $DedupeMinutes
    )
    $run = Get-RunGate -Event $Event -Conclusion $Conclusion -HeadBranch $HeadBranch -DefaultBranch $DefaultBranch
    if ($run.Action -eq 'skip') {
        return [ordered] @{ Action = 'skip'; Reason = $run.Reason; Issues = @() }
    }
    $pr = Get-PullRequestGate -PullRequest $PullRequest -BotLogin $BotLogin
    if ($pr.Action -eq 'skip') {
        return [ordered] @{ Action = 'skip'; Reason = $pr.Reason; Issues = @() }
    }
    $body = if ($null -ne $PullRequest) { [string] $PullRequest.body } else { '' }
    $numbers = @(Get-ClosingIssueNumbers -ClosingReferences $ClosingReferences -Body $body)
    if ($numbers.Count -eq 0) {
        return [ordered] @{
            Action = 'skip'
            Reason = "pull request #$([int] $PullRequest.number) closes no issues"
            Issues = @()
        }
    }
    $headDate = [datetime]::SpecifyKind([datetime] (Get-FactValue $PullRequest 'headCommitDate'), [DateTimeKind]::Utc)
    $byNumber = @{}
    foreach ($issue in @($Issues)) {
        $num = [int] (Get-FactValue $issue 'number')
        if ($num -gt 0) { $byNumber[$num] = $issue }
    }
    $decisions = [Collections.Generic.List[object]]::new()
    foreach ($n in $numbers) {
        $issue = $byNumber[$n]
        if ($null -eq $issue) {
            $decisions.Add([ordered] @{
                    Issue  = $n
                    Action = 'skip'
                    Reason = "issue #${n} was not found"
                })
            continue
        }
        $assignedEvents = @(Get-FactValue $issue 'assignedEvents')
        $comments = @(Get-FactValue $issue 'comments')
        $decisions.Add((Get-IssueNudgeDecision `
                    -IssueNumber $n `
                    -AssignedEvents $assignedEvents `
                    -Comments $comments `
                    -HeadCommitDate $headDate `
                    -BotLogin $BotLogin `
                    -Now $Now `
                    -DedupeMinutes $DedupeMinutes))
    }
    $nudgeCount = @($decisions | Where-Object { $_.Action -eq 'nudge' }).Count
    return [ordered] @{
        Action = $(if ($nudgeCount -gt 0) { 'nudge' } else { 'skip' })
        Reason = "$($pr.Reason); $($numbers.Count) linked issue(s); $nudgeCount to nudge"
        Issues = @($decisions)
    }
}

function ConvertFrom-GhJson([string] $Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    return $Text | ConvertFrom-Json -Depth 40
}

function Invoke-GhApi {
    # Runs gh api and returns the JSON object (or throws). Arguments after the verb go to gh.
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $raw = (& gh api @Arguments 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "gh api failed ($LASTEXITCODE): $raw" }
    return ConvertFrom-GhJson $raw
}

function Get-OpenPullRequestForHead {
    # Open pull request whose head commit is HeadSha, or $null.
    param(
        [string] $Owner,
        [string] $Name,
        [string] $HeadSha
    )
    $query = @'
query($owner: String!, $name: String!, $oid: GitObjectID!) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) {
      ... on Commit {
        committedDate
        associatedPullRequests(first: 20) {
          nodes {
            number
            state
            body
            author { login }
            headRefOid
            commits(last: 1) { nodes { commit { oid committedDate } } }
            closingIssuesReferences(first: 20) { nodes { number } }
          }
        }
      }
    }
  }
}
'@
    $answer = Invoke-GhApi graphql -f "query=$query" -f "owner=$Owner" -f "name=$Name" -f "oid=$HeadSha"
    $commit = $answer.data.repository.object
    if ($null -eq $commit) { return $null }
    $commitDate = [datetime]::SpecifyKind([datetime] $commit.committedDate, [DateTimeKind]::Utc)
    $associated = Get-FactValue (Get-FactValue $commit 'associatedPullRequests') 'nodes'
    foreach ($node in @($associated)) {
        if ([string] (Get-FactValue $node 'state') -cne 'OPEN') { continue }
        $headOid = [string] (Get-FactValue $node 'headRefOid')
        $commitOids = @($(Get-FactValue (Get-FactValue $node 'commits') 'nodes') | ForEach-Object {
                Get-FactValue (Get-FactValue $_ 'commit') 'oid'
            })
        if ($headOid -cne $HeadSha -and $commitOids -notcontains $HeadSha) { continue }
        $headCommitDate = $commitDate
        $last = @($(Get-FactValue (Get-FactValue $node 'commits') 'nodes')) | Select-Object -Last 1
        $lastCommit = Get-FactValue $last 'commit'
        $lastDate = Get-FactValue $lastCommit 'committedDate'
        if ($null -ne $lastDate) {
            $headCommitDate = [datetime]::SpecifyKind([datetime] $lastDate, [DateTimeKind]::Utc)
        }
        $closingNodes = Get-FactValue (Get-FactValue $node 'closingIssuesReferences') 'nodes'
        return [ordered] @{
            number            = [int] (Get-FactValue $node 'number')
            state             = [string] (Get-FactValue $node 'state')
            body              = [string] (Get-FactValue $node 'body')
            author            = [string] (Get-FactValue (Get-FactValue $node 'author') 'login')
            headCommitDate    = $headCommitDate
            closingReferences = @($closingNodes | ForEach-Object { [int] (Get-FactValue $_ 'number') })
        }
    }
    return $null
}

function Get-IssueWakeFacts {
    # Assignees timeline and comments for one issue.
    param(
        [string] $Owner,
        [string] $Name,
        [int] $Number,
        [string] $BotLogin
    )
    $query = @'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      number
      comments(last: 100) { nodes { body createdAt } }
      timelineItems(itemTypes: [ASSIGNED_EVENT], last: 50) {
        nodes {
          ... on AssignedEvent {
            createdAt
            assignee { ... on User { login } ... on Bot { login } }
          }
        }
      }
    }
  }
}
'@
    $answer = Invoke-GhApi graphql -f "query=$query" -f "owner=$Owner" -f "name=$Name" -F "number=$Number"
    $issue = $answer.data.repository.issue
    if ($null -eq $issue) { return $null }
    $assigned = [Collections.Generic.List[object]]::new()
    foreach ($ev in @($issue.timelineItems.nodes)) {
        $assignee = Get-FactValue $ev 'assignee'
        $login = [string] (Get-FactValue $assignee 'login')
        if (-not $login) { continue }
        $assigned.Add([ordered] @{
                assignee  = $login
                createdAt = [datetime]::SpecifyKind([datetime] (Get-FactValue $ev 'createdAt'), [DateTimeKind]::Utc)
            })
    }
    $comments = @($(Get-FactValue (Get-FactValue $issue 'comments') 'nodes') | ForEach-Object {
            [ordered] @{
                body      = [string] (Get-FactValue $_ 'body')
                createdAt = [datetime]::SpecifyKind([datetime] (Get-FactValue $_ 'createdAt'), [DateTimeKind]::Utc)
            }
        })
    return [ordered] @{
        number         = [int] $issue.number
        assignedEvents = @($assigned)
        comments       = $comments
        botLogin       = $BotLogin
    }
}

function Invoke-IssueAssigneeNudge {
    # Remove then add the bot assignee so an issue-assigned event fires as github-actions[bot].
    param(
        [string] $Repository,
        [int] $Number,
        [string] $BotLogin,
        [switch] $DryRun
    )
    if ($DryRun) {
        Write-Host "DRY-RUN: would remove and re-add $BotLogin on #${Number} in $Repository"
        return
    }
    # Remove may 404/422 when the bot is not currently assigned; still add so the assign event fires.
    # The native-command preference is off for this one call: a missing assignee is not a failure of the nudge.
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $null = Invoke-GhApi --method DELETE "repos/$Repository/issues/$Number/assignees" -f "assignees[]=$BotLogin"
        Write-Host "Removed $BotLogin from #${Number}"
    }
    catch {
        Write-Host "Remove $BotLogin from #${Number}: $($_.Exception.Message) (continuing to add)"
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $true
    }
    $null = Invoke-GhApi --method POST "repos/$Repository/issues/$Number/assignees" -f "assignees[]=$BotLogin"
    Write-Host "Added $BotLogin to #${Number}"
}

if ($LoadOnly) { return }

if (-not $Repository) { $Repository = [string] $env:GITHUB_REPOSITORY }
if (-not $Repository) { throw 'Repository is required (owner/name or GITHUB_REPOSITORY).' }
if ($Repository -notmatch '^(?<owner>[^/]+)/(?<name>[^/]+)$') { throw "Repository '$Repository' is not owner/name." }
$owner = $Matches['owner']
$name = $Matches['name']

$Now = [datetime]::SpecifyKind($Now.ToUniversalTime(), [DateTimeKind]::Utc)

Write-Host "factory-wake: repository=$Repository event=$Event conclusion=$Conclusion head=$HeadBranch sha=$HeadSha default=$DefaultBranch"

$runGate = Get-RunGate -Event $Event -Conclusion $Conclusion -HeadBranch $HeadBranch -DefaultBranch $DefaultBranch
Write-Host "run gate: $($runGate.Action) — $($runGate.Reason)"
if ($runGate.Action -eq 'skip') { exit 0 }

$pull = Get-OpenPullRequestForHead -Owner $owner -Name $name -HeadSha $HeadSha
$prGate = Get-PullRequestGate -PullRequest $pull -BotLogin $BotLogin
Write-Host "pull request gate: $($prGate.Action) — $($prGate.Reason)"
if ($prGate.Action -eq 'skip') { exit 0 }

$closing = @($pull.closingReferences)
$issueNumbers = @(Get-ClosingIssueNumbers -ClosingReferences $closing -Body ([string] $pull.body))
Write-Host ("linked issues: " + $(if ($issueNumbers.Count) { ($issueNumbers | ForEach-Object { "#$_" }) -join ', ' } else { '(none)' }))
if ($issueNumbers.Count -eq 0) { exit 0 }

$issueFacts = [Collections.Generic.List[hashtable]]::new()
foreach ($n in $issueNumbers) {
    $facts = Get-IssueWakeFacts -Owner $owner -Name $name -Number $n -BotLogin $BotLogin
    if ($null -eq $facts) {
        Write-Host "issue #${n}: skip — not found"
        continue
    }
    $issueFacts.Add($facts)
}

$plan = Get-FactoryWakePlan `
    -Event $Event `
    -Conclusion $Conclusion `
    -HeadBranch $HeadBranch `
    -DefaultBranch $DefaultBranch `
    -PullRequest $pull `
    -ClosingReferences $closing `
    -Issues @($issueFacts) `
    -BotLogin $BotLogin `
    -Now $Now `
    -DedupeMinutes $DedupeMinutes

Write-Host "plan: $($plan.Action) — $($plan.Reason)"
foreach ($d in @($plan.Issues)) {
    Write-Host "issue #$($d.Issue): $($d.Action) — $($d.Reason)"
    if ($d.Action -eq 'nudge') {
        Invoke-IssueAssigneeNudge -Repository $Repository -Number ([int] $d.Issue) -BotLogin $BotLogin -DryRun:$DryRun
    }
}

exit 0
