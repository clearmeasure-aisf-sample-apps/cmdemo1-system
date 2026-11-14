#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    After env-checks finishes on a cm-ai-ops-bot pull request, nudge the factory bot by re-assigning the linked issue(s).

.DESCRIPTION
    Workflow factory-wake runs this when workflow env-checks completes. It acts only for a pull_request run whose head
    branch is not the default branch, whose conclusion is success or failure, whose open pull request is by
    cm-ai-ops-bot, and whose linked issues still need a Review or fix.     For each such issue it removes and re-adds the
    cm-ai-ops-bot assignee (assigner becomes github-actions[bot]), which fires the bot's existing issue-assigned
    listener. It posts no comments and uses only GITHUB_TOKEN. Dedupe: skip an issue if it already has a Review
    verdict comment posted after the pull request's head commit date. The 10-minute recent-assign window does not
    apply when the wake reason is CI finished (this script), so a green bot PR still gets a Review nudge even if
    the bot was just assigned for In Progress → Review.

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
    Recent-assign window in minutes. Unused for the CI-finished wake reason (this script); kept for
    Get-IssueNudgeDecision when a non-CI reason is passed in tests.
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

$script:VerdictPrefixes = @('Review → Merged', 'Review → Done', 'Review → In Progress', 'Review: PASS')
# Closes #N (same repo) or Closes owner/name#N (cross-repo).
$script:ClosesPattern = '(?im)\bCloses\s+(?:(?<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#|#)(?<n>\d+)\b'

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

function Get-ClosingIssues {
    # Issues the pull request closes: GraphQL closingIssuesReferences when present (number + repository),
    # else Closes #N / Closes owner/name#N in the body. Each item is @{ number; repository }.
    param(
        [object[]] $ClosingReferences,
        [string] $Body,
        [string] $DefaultRepository = ''
    )
    $result = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    function Add-ClosingLink {
        param([int] $Number, [string] $Repository)
        if ($Number -le 0) { return }
        if (-not $Repository) { $Repository = $DefaultRepository }
        if (-not $Repository) { return }
        $key = "$Repository#$Number"
        if (-not $seen.Add($key)) { return }
        $result.Add([ordered] @{ number = $Number; repository = $Repository })
    }

    foreach ($ref in @($ClosingReferences)) {
        if ($null -eq $ref) { continue }
        if ($ref -is [int] -or $ref -is [long] -or ($ref -is [string] -and "$ref" -match '^\d+$')) {
            Add-ClosingLink -Number ([int] $ref) -Repository $DefaultRepository
            continue
        }
        $n = [int] (Get-FactValue $ref 'number')
        $repo = [string] (Get-FactValue $ref 'repository')
        Add-ClosingLink -Number $n -Repository $repo
    }
    if ($result.Count -gt 0) { return @($result) }

    foreach ($m in [regex]::Matches([string] $Body, $script:ClosesPattern)) {
        $n = [int] $m.Groups['n'].Value
        $repo = [string] $m.Groups['repo'].Value
        Add-ClosingLink -Number $n -Repository $repo
    }
    return @($result)
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
    # CI finished: do not apply the recent-assign debounce (In Progress → Review assign must not block the Review nudge).
    param(
        [int] $IssueNumber,
        [string] $Repository = '',
        [object[]] $AssignedEvents,
        [object[]] $Comments,
        [datetime] $HeadCommitDate,
        [string] $BotLogin,
        [datetime] $Now,
        [int] $DedupeMinutes,
        [string] $WakeReason = 'CI finished'
    )
    $label = if ($Repository) { "$Repository#$IssueNumber" } else { "#$IssueNumber" }
    if (Test-ReviewVerdictAfterHead -Comments $Comments -HeadCommitDate $HeadCommitDate) {
        return [ordered] @{
            Issue      = $IssueNumber
            Repository = $Repository
            Action     = 'skip'
            Reason     = "issue $label already has a Review verdict comment after the head commit"
        }
    }
    if ($WakeReason -cne 'CI finished' -and
        (Test-BotAssignedRecently -AssignedEvents $AssignedEvents -BotLogin $BotLogin -Now $Now -Minutes $DedupeMinutes)) {
        return [ordered] @{
            Issue      = $IssueNumber
            Repository = $Repository
            Action     = 'skip'
            Reason     = "cm-ai-ops-bot was assigned on $label within the last $DedupeMinutes minutes"
        }
    }
    return [ordered] @{
        Issue      = $IssueNumber
        Repository = $Repository
        Action     = 'nudge'
        Reason     = "re-assign $BotLogin on $label ($WakeReason)"
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
        [object[]] $ClosingReferences,
        [object[]] $Issues,
        [string] $DefaultRepository = '',
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
    $links = @(Get-ClosingIssues -ClosingReferences $ClosingReferences -Body $body -DefaultRepository $DefaultRepository)
    if ($links.Count -eq 0) {
        return [ordered] @{
            Action = 'skip'
            Reason = "pull request #$([int] $PullRequest.number) closes no issues"
            Issues = @()
        }
    }
    $headDate = [datetime]::SpecifyKind([datetime] (Get-FactValue $PullRequest 'headCommitDate'), [DateTimeKind]::Utc)
    $byKey = @{}
    foreach ($issue in @($Issues)) {
        $num = [int] (Get-FactValue $issue 'number')
        $repo = [string] (Get-FactValue $issue 'repository')
        if (-not $repo) { $repo = $DefaultRepository }
        if ($num -gt 0 -and $repo) { $byKey["$repo#$num"] = $issue }
    }
    $decisions = [Collections.Generic.List[object]]::new()
    foreach ($link in $links) {
        $n = [int] $link.number
        $repo = [string] $link.repository
        $issue = $byKey["$repo#$n"]
        if ($null -eq $issue) {
            $decisions.Add([ordered] @{
                    Issue      = $n
                    Repository = $repo
                    Action     = 'skip'
                    Reason     = "issue ${repo}#${n} was not found"
                })
            continue
        }
        $assignedEvents = @(Get-FactValue $issue 'assignedEvents')
        $comments = @(Get-FactValue $issue 'comments')
        $decisions.Add((Get-IssueNudgeDecision `
                    -IssueNumber $n `
                    -Repository $repo `
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
        Reason = "$($pr.Reason); $($links.Count) linked issue(s); $nudgeCount to nudge"
        Issues = @($decisions)
    }
}

function ConvertFrom-GhJson([string] $Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    return $Text | ConvertFrom-Json -Depth 40
}

function Test-GhGraphqlNotFoundOnly {
    # True when errors is non-empty and every GraphQL error is type NOT_FOUND (missing issue/repository).
    # FORBIDDEN, INSUFFICIENT_SCOPES, RATE_LIMITED, mixed types, and empty/missing errors are not "not found".
    param($Parsed)
    if ($null -eq $Parsed) { return $false }
    $errorsRaw = Get-FactValue $Parsed 'errors'
    # @() from an if-branch / @( $null ) is unsafe under StrictMode; build the list explicitly.
    $errors = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $errorsRaw) { foreach ($err in @($errorsRaw)) { $errors.Add($err) } }
    if ($errors.Count -eq 0) { return $false }
    foreach ($err in $errors) {
        if ([string] (Get-FactValue $err 'type') -cne 'NOT_FOUND') { return $false }
    }
    return $true
}

function Test-GhRestHttp404 {
    # True when a REST call returned exactly HTTP 404 (JSON status or gh stderr summary).
    param($Parsed, [string] $Stderr = '')
    $status = [string] (Get-FactValue $Parsed 'status')
    return ($status -ceq '404') -or ($Stderr -match '(?i)\bHTTP 404\b')
}

function Invoke-GhApiRaw {
    # Runs gh api without throwing NativeCommandExitException. Returns ExitCode, Stdout, Stderr, Parsed.
    # With $PSNativeCommandUseErrorActionPreference = $true (required preamble), a non-zero gh exit
    # would otherwise throw before $LASTEXITCODE can be read (#649 / same pattern as #646).
    # Stderr is kept out of the JSON body (gh prints a summary line there on GraphQL field errors).
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $written = @(& gh api @Arguments 2>&1)
        $code = [int] $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previous
    }
    $stdout = @($written | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"
    $stderr = @($written | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" } | Where-Object { $_ }) -join "`n"
    return [ordered] @{
        ExitCode = $code
        Stdout   = $stdout
        Stderr   = $stderr
        Parsed   = (ConvertFrom-GhJson $stdout)
    }
}

function Invoke-GhApi {
    # Runs gh api and returns the JSON object. On a non-zero exit, only a genuine not-found is returned
    # for the caller to skip: GraphQL errors that are all NOT_FOUND, or a REST HTTP 404. FORBIDDEN /
    # INSUFFICIENT_SCOPES / RATE_LIMITED / mixed errors / and any other non-zero exit throw (#649 review).
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $r = Invoke-GhApiRaw @Arguments
    if ($r.ExitCode -ne 0) {
        if ((Test-GhGraphqlNotFoundOnly -Parsed $r.Parsed) -or (Test-GhRestHttp404 -Parsed $r.Parsed -Stderr $r.Stderr)) {
            return $r.Parsed
        }
        $detail = if ($r.Stdout) { $r.Stdout } elseif ($r.Stderr) { $r.Stderr } else { '(no output)' }
        throw "gh api failed ($($r.ExitCode)): $detail"
    }
    return $r.Parsed
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
            closingIssuesReferences(first: 20) {
              nodes {
                number
                repository { nameWithOwner }
              }
            }
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
        $closingReferences = @(
            foreach ($c in @($closingNodes)) {
                $num = [int] (Get-FactValue $c 'number')
                if ($num -le 0) { continue }
                $repoNode = Get-FactValue $c 'repository'
                $nameWithOwner = [string] (Get-FactValue $repoNode 'nameWithOwner')
                [ordered] @{ number = $num; repository = $nameWithOwner }
            }
        )
        return [ordered] @{
            number            = [int] (Get-FactValue $node 'number')
            state             = [string] (Get-FactValue $node 'state')
            body              = [string] (Get-FactValue $node 'body')
            author            = [string] (Get-FactValue (Get-FactValue $node 'author') 'login')
            headCommitDate    = $headCommitDate
            closingReferences = $closingReferences
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
    # Invoke-GhApi returns the payload when errors are all NOT_FOUND; other non-zero exits throw (#649).
    $answer = Invoke-GhApi graphql -f "query=$query" -f "owner=$Owner" -f "name=$Name" -F "number=$Number"
    $repoNode = Get-FactValue (Get-FactValue $answer 'data') 'repository'
    if ($null -eq $repoNode) { return $null }
    $issue = Get-FactValue $repoNode 'issue'
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
        repository     = "$Owner/$Name"
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
$links = @(Get-ClosingIssues -ClosingReferences $closing -Body ([string] $pull.body) -DefaultRepository $Repository)
Write-Host ("linked issues: " + $(if ($links.Count) { ($links | ForEach-Object { "$($_.repository)#$($_.number)" }) -join ', ' } else { '(none)' }))
if ($links.Count -eq 0) { exit 0 }

$issueFacts = [Collections.Generic.List[hashtable]]::new()
foreach ($link in $links) {
    $repoFull = [string] $link.repository
    if ($repoFull -notmatch '^(?<issueOwner>[^/]+)/(?<issueName>[^/]+)$') {
        Write-Host "issue #$($link.number): skip — repository '$repoFull' is not owner/name"
        continue
    }
    $facts = Get-IssueWakeFacts -Owner $Matches['issueOwner'] -Name $Matches['issueName'] -Number ([int] $link.number) -BotLogin $BotLogin
    if ($null -eq $facts) {
        Write-Host "issue ${repoFull}#$($link.number): skip — not found"
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
    -DefaultRepository $Repository `
    -BotLogin $BotLogin `
    -Now $Now `
    -DedupeMinutes $DedupeMinutes

Write-Host "plan: $($plan.Action) — $($plan.Reason)"
foreach ($d in @($plan.Issues)) {
    $targetRepo = [string] (Get-FactValue $d 'Repository')
    if (-not $targetRepo) { $targetRepo = $Repository }
    Write-Host "issue ${targetRepo}#$($d.Issue): $($d.Action) — $($d.Reason)"
    if ($d.Action -eq 'nudge') {
        Invoke-IssueAssigneeNudge -Repository $targetRepo -Number ([int] $d.Issue) -BotLogin $BotLogin -DryRun:$DryRun
    }
}

exit 0
