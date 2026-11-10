#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Writes workitems.json: every issue of the business repository, tagged bot or team, where each one stands on the
    board, which release carries its change and which environments run it. It changes nothing anywhere.

.DESCRIPTION
    The workflow "workitems" runs it and publishes the file on branch "status", next to delivery.json, where the
    dashboard reads it from the browser (https://raw.githubusercontent.com/<org>/<repository>/status/workitems.json).
    docs/ops/workitems.md is the contract of the file and says how each field is found; in short:

      scope      every issue of the deployable's repository (-Deployable, ui: cmdemo1-workorders). Kept: every open
                 one, and the closed ones closed, merged or deployed in the last -Days days. worker is "bot" when an
                 automated identity did the work (assigned to cm-ai-ops-bot; a linked pull request by cm-ai-ops-bot,
                 factory-worker-author, cursor, Copilot or another bot account; or the factory's label or state
                 comment, which is a record on the issue), and "team" otherwise. agent is that identity.
      column     the Status of the item on the organization's project -Project (679, node PVT_kwDOD_ESUc4BliGL) when
                 this token may read the project; otherwise derived (scope.columnSource "derived") from cm-ai-ops-bot's
                 journal lines only ("Todo → In Progress", "A → B → C", "X → Y (via Z)"). A factory-state comment is
                 never a column source.
      prs        linked pull requests: closing references, "Refs/Closes/Fixes/Resolves #N", a title ending "(#N)",
                 branches factory-worker/<N>-* and issue-<N>-*, and the pull request of the factory state.
      release    releaseCandidate: the first release (by time) whose commit contains the merge commit of the item's
                 last merged pull request. A release is a GitHub deployment "release" of the repository (release.yml
                 creates the Octopus release with it); its version is that of the master Build run of its commit
                 (MAJOR.MINOR.run_number, the run's title).
      environments
                 per environment: the first pin of the deployable (this repository's commits "Pin <deployable> <v> in
                 <env>", whose deployment was not reverted as failed) whose release contains the merge commit: version
                 and the pin's time (the deployment's start). Only while the commit running there (delivery.json, else
                 the version pinned in environments/<env>/versions.json) contains it.
    Containment is git ancestry in a partial clone of the repository (-Clone; made with --filter=tree:0 when not
    given): the same answer as GitHub's compare API, without one call per commit and release.

    Stats, three times (stats.all, stats.bot, stats.team), and the same keys of stats.all repeated at the top of
    stats so a reader of the first contract sees every item: WIP per column (Done left out); cycle time (first column
    after Todo to Done) and lead time (created to prod) over the last -StatsDays days, median and p85; merged and
    deployed-to-prod per week (Monday, UTC) for -Weeks weeks; rework; cost (null: no cost source is connected).
    stats.bot also has hoursByColumn (median hours in each column), throughputByAgent (items reaching Done in the
    window, by agent) and mergeToProdHours. A bot item also carries the hours it spent in each column, its pull
    requests' check conclusion, its latest status or blocker comment, and its merge-to-prod hours.

    A source that cannot be read fails nothing that does not need it: the file names it in "missing".

.PARAMETER Path
    Where the file is written.
.PARAMETER Deployable
    The deployable of system.json whose repository holds the work items (its "repository").
.PARAMETER Project
    The number of the organization's project (GitHub Projects) of the board.
.PARAMETER DeliveryPath
    The published delivery.json (the commit each environment runs). Without one, the pinned version's commit is used.
.PARAMETER Clone
    A clone of the repository's default branch (commits only are needed). Made in the temporary folder when empty.
.PARAMETER Days
    How far back closed items are kept.
.PARAMETER StatsDays
    The window of the cycle and lead times.
.PARAMETER Weeks
    How many weeks perWeek has, the current one last.
.PARAMETER LoadOnly
    Define the functions and return (scripts/workitems/test-write-workitems.ps1).
.EXAMPLE
    pwsh -NoProfile -File scripts/workitems/write-workitems.ps1 -Path workitems.json -DeliveryPath delivery.json
#>
[CmdletBinding()]
param(
    [string] $Path = 'workitems.json',
    [string] $Deployable = 'ui',
    [int] $Project = 679,
    [string] $DeliveryPath = '',
    [string] $Clone = '',
    [int] $Days = 56,
    [int] $StatsDays = 28,
    [int] $Weeks = 8,
    [switch] $LoadOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The board's columns in their order (cmdemo1-workorders docs/board-columns.md).
$script:Columns = @('Todo', 'In Progress', 'Technical Design', 'Development', 'Functional Testing', 'Release Queue', 'Done')
# Who counts as automated work, and whose comments are a column journal when the project cannot be read. A factory
# label or state comment is read from the issue (it is the record a bot left there); nothing calls a gateway.
$script:BotAssignees = @('cm-ai-ops-bot')
$script:BotLabelPattern = '^(factory worker|AI Factory)$|^(agent|worker|runtime):'
$script:BotAuthors = @('cm-ai-ops-bot', 'factory-worker-author', 'cursor', 'copilot-swe-agent', 'copilot')
$script:JournalAuthors = @('cm-ai-ops-bot')
$script:ProjectNodeId = 'PVT_kwDOD_ESUc4BliGL'
$script:CostNote = 'No cost source is connected yet.'

$script:ColumnPattern = ($script:Columns | ForEach-Object { [regex]::Escape($_) }) -join '|'

function Get-Value($Object, [string[]] $Name) {
    # A value in nested hashtables (ConvertFrom-Json -AsHashtable), or $null where any part is missing.
    $value = $Object
    foreach ($part in $Name) {
        if ($value -isnot [Collections.IDictionary] -or -not $value.Contains($part)) { return $null }
        $value = $value[$part]
    }
    return $value
}

function Get-Nodes($Connection) {
    # The nodes of a GraphQL connection, always an array.
    return @(Get-Value $Connection 'nodes' | Where-Object { $null -ne $_ })
}

function ConvertTo-Moment($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string] $Value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $parsed)) { return $parsed.UtcDateTime }
    return $null
}

function Format-Moment($Moment) {
    if ($null -eq $Moment) { return $null }
    return (ConvertTo-Moment $Moment).ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
}

function ConvertTo-Login([string] $Login) {
    # GraphQL names an App's bot "factory-worker-author", REST "factory-worker-author[bot]", gh "app/factory-worker-author".
    return ($Login -replace '^app/', '' -replace '\[bot\]$', '')
}

function Add-HistoryEntry([Collections.Generic.List[object]] $Entries, [string] $Column, $At) {
    $moment = ConvertTo-Moment $At
    if ($script:Columns -cnotcontains $Column -or $null -eq $moment) { return }
    $Entries.Add([ordered] @{ column = $Column; enteredAt = $moment })
}

function Optimize-History([object[]] $Entries) {
    # In time order (entries of one moment keep their order); a column entered again right after itself is one entry.
    $sorted = @($Entries | ForEach-Object { $_ } | Where-Object { $_ -is [Collections.IDictionary] } | Sort-Object -Stable { $_['enteredAt'] })
    $kept = [Collections.Generic.List[object]]::new()
    foreach ($entry in $sorted) {
        if ($kept.Count -gt 0 -and $kept[$kept.Count - 1].column -ceq $entry.column) { continue }
        $kept.Add($entry)
    }
    return , $kept.ToArray()
}

function Read-FactoryState([object[]] $Comments) {
    # The fworker's machine-read state comment ("<!-- factory-state:<worker> v1 -->" and a json block); the newest by
    # its "updated" when an item has more than one. $null when none parses.
    $best = $null
    foreach ($comment in @($Comments)) {
        $body = [string] (Get-Value $comment 'body')
        $match = [regex]::Match($body, '<!--\s*factory-state:(?<worker>[^\s>]+)[^>]*-->[\s\S]*?```json\s*\r?\n(?<json>[\s\S]*?)\r?\n```')
        if (-not $match.Success) { continue }
        try { $state = $match.Groups['json'].Value | ConvertFrom-Json -AsHashtable -Depth 64 } catch { continue }
        if ($state -isnot [Collections.IDictionary]) { continue }
        $state['_worker'] = $match.Groups['worker'].Value
        $state['_updated'] = ConvertTo-Moment (Get-Value $state 'updated')
        if ($null -eq $best -or ($null -ne $state['_updated'] -and ($null -eq $best['_updated'] -or $state['_updated'] -gt $best['_updated']))) { $best = $state }
    }
    return $best
}

function Get-FactoryHistory($State) {
    # The columns the fworker recorded: "flow" (column and time, in order), else "dispatched_at" (when it dispatched
    # each column) for states written before flow existed; merge.queued_at is Release Queue, merge.done_at Done.
    $entries = [Collections.Generic.List[object]]::new()
    if ($null -eq $State) { return , @() }
    $flow = @(Get-Value $State 'flow' | Where-Object { $null -ne $_ })
    if ($flow.Count -gt 0) {
        foreach ($step in $flow) { Add-HistoryEntry $entries ([string] (Get-Value $step 'c')) (Get-Value $step 'at') }
    }
    else {
        $dispatched = Get-Value $State 'dispatched_at'
        if ($dispatched -is [Collections.IDictionary]) { foreach ($column in $dispatched.Keys) { Add-HistoryEntry $entries ([string] $column) $dispatched[$column] } }
    }
    Add-HistoryEntry $entries 'Release Queue' (Get-Value $State 'merge', 'queued_at')
    Add-HistoryEntry $entries 'Done' (Get-Value $State 'merge', 'done_at')
    return Optimize-History $entries.ToArray()
}

function Get-JournalHistory([object[]] $Comments) {
    # Column moves the bots journal in their comments: "Todo → In Progress", "A → B → C", "X → Y (via Z)", each
    # entered at the comment's time. A move counts when it leaves the column the item is in, or goes past it (a
    # journal may skip a move); one that starts elsewhere and does not go past it is a recap of earlier moves ("catch-up"
    # comments) and does not count. Comments of people and factory-state comments are not read.
    $entries = [Collections.Generic.List[object]]::new()
    $chain = "(?<![\w-])(?:$script:ColumnPattern)(?:\s*(?:→|->)\s*(?:$script:ColumnPattern)(?:\s*\(via (?:$script:ColumnPattern)\))?)+"
    $token = "\(via (?<via>$script:ColumnPattern)\)|(?<column>$script:ColumnPattern)"
    $current = $null
    foreach ($comment in @($Comments | Sort-Object -Stable { ConvertTo-Moment (Get-Value $_ 'createdAt') })) {
        $author = ConvertTo-Login ([string] (Get-Value $comment 'author', 'login'))
        $body = [string] (Get-Value $comment 'body')
        if ($script:JournalAuthors -notcontains $author -or $body -match 'factory-state:') { continue }
        $at = Get-Value $comment 'createdAt'
        foreach ($match in [regex]::Matches($body, $chain)) {
            $sequence = [Collections.Generic.List[string]]::new()
            foreach ($part in [regex]::Matches($match.Value, $token)) {
                if ($part.Groups['via'].Success) { if ($sequence.Count -gt 1) { $sequence.Insert($sequence.Count - 1, $part.Groups['via'].Value) } }
                else { $sequence.Add($part.Groups['column'].Value) }
            }
            for ($i = 1; $i -lt $sequence.Count; $i++) {
                $from = $sequence[$i - 1]; $to = $sequence[$i]
                $ahead = $null -eq $current -or $script:Columns.IndexOf($to) -gt $script:Columns.IndexOf($current)
                if ($from -ceq $current -or $ahead) {
                    Add-HistoryEntry $entries $to $at
                    $current = $to
                }
            }
        }
    }
    return Optimize-History $entries.ToArray()
}

function Get-ProjectHistory([object[]] $Timeline, [int] $ProjectNumber, [string] $Status) {
    # The project's own record (readable only with project access): each Status change of the item on the project.
    # The column before the first change is entered when the item was added to the project; an item added and never
    # moved is in its current Status since then.
    $entries = [Collections.Generic.List[object]]::new()
    $added = $null
    foreach ($event in @($Timeline)) {
        if ((Get-Value $event 'project', 'number') -ne $ProjectNumber) { continue }
        switch ([string] (Get-Value $event '__typename')) {
            'AddedToProjectV2Event' { if ($null -eq $added) { $added = Get-Value $event 'createdAt' } }
            'ProjectV2ItemStatusChangedEvent' {
                $previous = [string] (Get-Value $event 'previousStatus')
                if ($entries.Count -eq 0 -and $previous -and $null -ne $added) { Add-HistoryEntry $entries $previous $added }
                Add-HistoryEntry $entries ([string] (Get-Value $event 'status')) (Get-Value $event 'createdAt')
            }
        }
    }
    if ($entries.Count -eq 0 -and $Status -and $null -ne $added) { Add-HistoryEntry $entries $Status $added }
    return Optimize-History $entries.ToArray()
}

function Get-ProjectStatus($Issue, [int] $ProjectNumber) {
    foreach ($item in (Get-Nodes (Get-Value $Issue 'projectItems'))) {
        if ((Get-Value $item 'project', 'number') -eq $ProjectNumber) { return [string] (Get-Value $item 'fieldValueByName', 'name') }
    }
    return $null
}

function Get-CursorSessions([string[]] $Text) {
    # Cursor agent links, in order of first mention, one per agent: cursor.com/agents/<id> and cursor.com/agents?id=<id>.
    $seen = [Collections.Generic.List[string]]::new()
    foreach ($t in @($Text | Where-Object { $_ })) {
        foreach ($m in [regex]::Matches($t, 'https?://(?:www\.)?cursor\.com/agents(?:/|\?id=)(?<id>[A-Za-z0-9][A-Za-z0-9_-]*)')) {
            $url = "https://cursor.com/agents/$($m.Groups['id'].Value)"
            if (-not $seen.Contains($url)) { $seen.Add($url) }
        }
    }
    return , $seen.ToArray()
}

function Get-LinkedIssueNumbers($PullRequest, [string] $RepositoryName) {
    # The issues a pull request works on: its closing references, "Closes/Fixes/Resolves/Refs #N" (also
    # <repository>#N), a title that ends "(#N)", and the branches the bots name after an issue.
    $numbers = [Collections.Generic.SortedSet[int]]::new()
    foreach ($ref in (Get-Nodes (Get-Value $PullRequest 'closingIssuesReferences'))) { [void] $numbers.Add([int] (Get-Value $ref 'number')) }
    $title = [string] (Get-Value $PullRequest 'title')
    $body = [string] (Get-Value $PullRequest 'body')
    $branch = [string] (Get-Value $PullRequest 'headRefName')
    $repo = if ($RepositoryName) { "(?:[\w.-]+/)?$([regex]::Escape($RepositoryName))" } else { '(?!)' }
    foreach ($m in [regex]::Matches("$title`n$body", "(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)\b:?\s+(?:$repo)?#(?<n>\d+)\b")) { [void] $numbers.Add([int] $m.Groups['n'].Value) }
    $titled = [regex]::Match($title, '\(#(?<n>\d+)\)\s*$')
    if ($titled.Success) { [void] $numbers.Add([int] $titled.Groups['n'].Value) }
    $named = [regex]::Match($branch, '^(?:factory-worker/|issue-)(?<n>\d+)(?:-|$)')
    if ($named.Success) { [void] $numbers.Add([int] $named.Groups['n'].Value) }
    return , @($numbers)
}

function Get-RevertedPullRequests([object[]] $PullRequests, [string[]] $CommitSubjects) {
    # Pull requests whose change was reverted on the default branch: a merged pull request titled "Revert ..."
    # ("Reverts <owner>/<repo>#N" in GitHub's body, else the first #N of its title), and a commit subject
    # 'Revert "... (#N)"'. A revert that was never merged reverts nothing.
    $reverted = [Collections.Generic.SortedSet[int]]::new()
    foreach ($pr in @($PullRequests)) {
        $title = [string] (Get-Value $pr 'title')
        if ((Get-Value $pr 'state') -ne 'MERGED' -or $title -notmatch '^(?i)revert\b') { continue }
        $body = [regex]::Match([string] (Get-Value $pr 'body'), '(?i)\breverts\s+(?:[\w.-]+/[\w.-]+)?#(?<n>\d+)')
        $inTitle = [regex]::Match($title, '#(?<n>\d+)')
        if ($body.Success) { [void] $reverted.Add([int] $body.Groups['n'].Value) }
        elseif ($inTitle.Success) { [void] $reverted.Add([int] $inTitle.Groups['n'].Value) }
    }
    foreach ($subject in @($CommitSubjects)) {
        $m = [regex]::Match([string] $subject, '^Revert "[^"]*?\(#(?<n>\d+)\)"')
        if ($m.Success) { [void] $reverted.Add([int] $m.Groups['n'].Value) }
    }
    return , @($reverted)
}

function Test-BotIdentity([string] $Login, [string] $TypeName = '') {
    # An automated account: a known bot, any GitHub App (app/<name> or <name>[bot]), or an author GraphQL types as Bot.
    if ($TypeName -eq 'Bot') { return $true }
    if ($Login -match '\[bot\]$' -or $Login -match '^app/') { return $true }
    $name = ConvertTo-Login $Login
    return [bool] ($name -and $script:BotAuthors -contains $name)
}

function Get-BotEvidence($Issue, [object[]] $PullRequests, $State) {
    # Why the work was done by an automated identity; none means a person's item. A factory label or state comment is
    # the record on the issue, not a call to anything.
    $reasons = [Collections.Generic.List[string]]::new()
    $assigned = @(Get-Nodes (Get-Value $Issue 'assignees') | ForEach-Object { ConvertTo-Login ([string] (Get-Value $_ 'login')) })
    $assigned += @(Get-Nodes (Get-Value $Issue 'timelineItems') | Where-Object { (Get-Value $_ '__typename') -eq 'AssignedEvent' } | ForEach-Object { ConvertTo-Login ([string] (Get-Value $_ 'assignee', 'login')) })
    foreach ($bot in $script:BotAssignees) { if ($assigned -contains $bot) { $reasons.Add("assigned to $bot") } }
    foreach ($label in (Get-Nodes (Get-Value $Issue 'labels'))) {
        $name = [string] (Get-Value $label 'name')
        if ($name -match $script:BotLabelPattern) { $reasons.Add("label $name") }
    }
    if ($null -ne $State) { $reasons.Add("factory state ($($State['_worker']))") }
    foreach ($pr in @($PullRequests)) {
        $login = [string] (Get-Value $pr 'author', 'login')
        if (Test-BotIdentity $login ([string] (Get-Value $pr 'author', '__typename'))) { $reasons.Add("pull request by $(ConvertTo-Login $login)") }
    }
    return , @($reasons | Select-Object -Unique)
}

function Get-Agent($Issue, $State, [object[]] $PullRequests, [string[]] $Reasons) {
    # The specific identity: the factory worker named in its state, else the assigned bot, else the bot that wrote a
    # pull request; for a person's item, its assignee, else the pull request's author, else the issue's author.
    if ($null -ne $State -and $State['_worker']) { return [string] $State['_worker'] }
    foreach ($bot in $script:BotAssignees) { if ($Reasons -contains "assigned to $bot") { return $bot } }
    foreach ($pr in @($PullRequests)) {
        $login = [string] (Get-Value $pr 'author', 'login')
        if (Test-BotIdentity $login ([string] (Get-Value $pr 'author', '__typename'))) { return (ConvertTo-Login $login) }
    }
    if (@($Reasons | Where-Object { $_ -like 'label *' }).Count -gt 0) { return 'factory-worker' }
    $assignee = @(Get-Nodes (Get-Value $Issue 'assignees') | ForEach-Object { ConvertTo-Login ([string] (Get-Value $_ 'login')) }) | Select-Object -First 1
    if ($assignee) { return $assignee }
    $first = @($PullRequests) | Select-Object -First 1
    $author = ConvertTo-Login ([string] (Get-Value $first 'author', 'login'))
    if ($author) { return $author }
    $opened = ConvertTo-Login ([string] (Get-Value $Issue 'author', 'login'))
    if ($opened) { return $opened }
    return $null
}

function Get-ChecksConclusion($PullRequest) {
    # The rollup of the pull request's latest commit: success, failure, pending, error, expected; $null when unknown.
    $commit = @(Get-Nodes (Get-Value $PullRequest 'commits')) | Select-Object -First 1
    $state = [string] (Get-Value $commit 'commit', 'statusCheckRollup', 'state')
    if (-not $state) { return $null }
    return $state.ToLowerInvariant()
}

function Add-ColumnSpan([object[]] $History, [datetime] $Now) {
    # enteredAt, leftAt (the next column's enteredAt; null while it is the current column) and the hours spent there
    # (up to now, for the current column).
    $visits = @($History)
    $spanned = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $visits.Count; $i++) {
        $left = if ($i + 1 -lt $visits.Count) { $visits[$i + 1].enteredAt } else { $null }
        $end = if ($null -ne $left) { $left } else { $Now }
        $hours = if ($null -ne $end -and $null -ne $visits[$i].enteredAt -and $end -ge $visits[$i].enteredAt) {
            [Math]::Round(($end - $visits[$i].enteredAt).TotalHours, 1, [MidpointRounding]::AwayFromZero)
        } else { $null }
        $spanned.Add([ordered] @{ column = $visits[$i].column; enteredAt = $visits[$i].enteredAt; leftAt = $left; hours = $hours })
    }
    return , $spanned.ToArray()
}

function Get-LatestStatusComment([object[]] $Comments) {
    # The newest comment that reports status or names a blocker. A blocker says so; a status comment is one of the
    # bots' journals or verdicts. People chatting are neither.
    $best = $null
    foreach ($comment in @($Comments)) {
        $body = [string] (Get-Value $comment 'body')
        $author = ConvertTo-Login ([string] (Get-Value $comment 'author', 'login'))
        $kind = $null
        if ($body -match '(?i)(^|\b)blocker\b') { $kind = 'blocker' }
        elseif ($script:JournalAuthors -contains $author -or $author -eq 'factory-worker-author' -or $author -eq 'cursor') {
            if ($body -match 'Journal|→|->|factory-journal|validation verdict|factory-worker:') { $kind = 'status' }
        }
        if (-not $kind) { continue }
        $at = ConvertTo-Moment (Get-Value $comment 'createdAt')
        if ($null -eq $best -or ($null -ne $at -and $at -gt $best.at)) {
            $best = [ordered] @{ url = [string] (Get-Value $comment 'url'); at = $at; kind = $kind }
        }
    }
    if ($null -ne $best -and -not $best.url) { $best.url = $null }
    return $best
}

function Get-Runtime($Issue) {
    # The runtime a factory label names: runtime:<x>, else worker:<x>, else agent:<x>.
    $names = @(Get-Nodes (Get-Value $Issue 'labels') | ForEach-Object { [string] (Get-Value $_ 'name') })
    foreach ($prefix in 'runtime:', 'worker:', 'agent:') {
        $found = @($names | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) })
        if ($found.Count -gt 0) { return $found[0].Substring($prefix.Length) }
    }
    return $null
}

function Get-FunctionalTestingFailures($State, [object[]] $Comments, [object[]] $History) {
    # Functional Testing failures that sent the item back: the most of the fworker's count (demotions: FAIL verdicts
    # that moved it back to Development), its FAIL verdict comments, and moves out of Functional Testing to an
    # earlier column in the history.
    $demotions = [int] (Get-Value $State 'demotions')
    $verdicts = @($Comments | Where-Object { ([string] (Get-Value $_ 'body')) -match 'verdict for \*\*Functional Testing\*\*: FAIL' }).Count
    $back = 0
    $earlier = @('Todo', 'In Progress', 'Technical Design', 'Development')
    for ($i = 1; $i -lt @($History).Count; $i++) {
        if ($History[$i - 1].column -eq 'Functional Testing' -and $earlier -contains $History[$i].column) { $back++ }
    }
    return [Math]::Max($demotions, [Math]::Max($verdicts, $back))
}

function Get-RunVersion($Run) {
    # The version of a master Build run: its title starts with it (build.yml: MAJOR.MINOR.run_number).
    $m = [regex]::Match([string] (Get-Value $Run 'display_title'), '^(?<v>\d+\.\d+\.\d+)\b')
    if ($m.Success) { return $m.Groups['v'].Value }
    return $null
}

function Get-Releases([object[]] $Deployments, [object[]] $Runs, [string[]] $PinnedVersions) {
    # The releases of the deployable, oldest first: each GitHub deployment "release" (release.yml makes one when it
    # creates the Octopus release of a commit), with the version of the newest push or dispatched master Build run of
    # that commit that started before it. A version pinned in an environment that no deployment names (made before
    # the deployments were recorded) is a release too, at the time its Build run ended.
    $byVersion = @{}
    $builds = @($Runs | Where-Object { (Get-Value $_ 'event') -in 'push', 'workflow_dispatch' })
    foreach ($deployment in @($Deployments)) {
        $sha = [string] (Get-Value $deployment 'sha')
        $at = ConvertTo-Moment (Get-Value $deployment 'created_at')
        $run = @($builds | Where-Object { (Get-Value $_ 'head_sha') -eq $sha -and (ConvertTo-Moment (Get-Value $_ 'created_at')) -le $at } | Sort-Object { [int] (Get-Value $_ 'run_number') } -Descending) | Select-Object -First 1
        if ($null -eq $run) { continue }
        $version = Get-RunVersion $run
        if (-not $version) { continue }
        if (-not $byVersion.ContainsKey($version) -or $byVersion[$version].createdAt -gt $at) { $byVersion[$version] = [ordered] @{ version = $version; sha = $sha; createdAt = $at } }
    }
    foreach ($version in @($PinnedVersions | Where-Object { $_ } | Select-Object -Unique)) {
        if ($byVersion.ContainsKey($version)) { continue }
        $run = @($builds | Where-Object { (Get-RunVersion $_) -eq $version }) | Select-Object -First 1
        if ($null -eq $run) { continue }
        $byVersion[$version] = [ordered] @{ version = $version; sha = [string] (Get-Value $run 'head_sha'); createdAt = ConvertTo-Moment (Get-Value $run 'updated_at') }
    }
    return , @($byVersion.Values | Sort-Object -Stable { $_.createdAt })
}

function Read-PinEvents([string[]] $Lines, [string] $DeployableName) {
    # The deployments of the deployable to one environment, oldest first, from the log of its versions.json
    # ("<committer time>`t<subject>"): "Pin <deployable> <version> in <env> (Deployments-N)", and a deployment that
    # failed is reverted ("Revert pin of <deployable> <version> in <env> (Deployments-N failed)").
    $pins = [Collections.Generic.List[object]]::new()
    $failed = [Collections.Generic.HashSet[string]]::new()
    $name = [regex]::Escape($DeployableName)
    foreach ($line in @($Lines)) {
        $at, $subject = ([string] $line) -split "`t", 2
        if ($null -eq $subject) { continue }
        $pin = [regex]::Match($subject, "^Pin $name (?<v>\S+) in (?<e>\S+) \((?<d>Deployments-\d+)\)")
        if ($pin.Success) { $pins.Add([ordered] @{ version = $pin.Groups['v'].Value; environment = $pin.Groups['e'].Value; deployment = $pin.Groups['d'].Value; at = ConvertTo-Moment $at; reverted = $false }); continue }
        $revert = [regex]::Match($subject, "^Revert pin of $name (?<v>\S+) in (?<e>\S+) \((?<d>Deployments-\d+) failed\)")
        if ($revert.Success) { [void] $failed.Add($revert.Groups['d'].Value) }
    }
    foreach ($pin in $pins) { if ($failed.Contains($pin.deployment)) { $pin.reverted = $true } }
    return , $pins.ToArray()
}

function Get-PinPoints([object[]] $Pins, [string] $Environment, [hashtable] $ShaOfVersion) {
    # The deployments of one environment that did not fail, as points (version, at, sha) for Get-FirstContaining; a
    # version whose commit is not known is left out.
    $points = foreach ($pin in @($Pins)) {
        if ($pin.environment -ne $Environment -or $pin.reverted -or -not $ShaOfVersion.ContainsKey($pin.version)) { continue }
        [ordered] @{ version = $pin.version; at = $pin.at; sha = $ShaOfVersion[$pin.version] }
    }
    return , @($points)
}

function Get-FirstContaining([object[]] $Points, [scriptblock] $RevList) {
    # Per commit, the first point (in the order given) whose commit contains it. $RevList is asked
    # (commit, earlier commits) and answers @{ Known; Commits }: the commits reachable from the first and from none of
    # the others; Known is false when the commit is not in the clone (that point is passed over).
    $first = @{}
    $earlier = [Collections.Generic.List[string]]::new()
    foreach ($point in @($Points)) {
        $sha = [string] $point.sha
        if (-not $sha) { continue }
        $answer = & $RevList $sha $earlier.ToArray()
        if (-not $answer.Known) { continue }
        foreach ($commit in @($answer.Commits)) { if (-not $first.ContainsKey($commit)) { $first[$commit] = $point } }
        $earlier.Add($sha)
    }
    return $first
}

function Get-Percentile([double[]] $Values, [double] $P) {
    # Linear between the closest ranks (Excel's PERCENTILE.INC), one decimal; $null without values.
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $rank = ($sorted.Count - 1) * $P
    $low = [int] [Math]::Floor($rank)
    $high = [int] [Math]::Ceiling($rank)
    return [Math]::Round($sorted[$low] + ($sorted[$high] - $sorted[$low]) * ($rank - $low), 1, [MidpointRounding]::AwayFromZero)
}

function Get-Summary([double[]] $Values) {
    return [ordered] @{ median = Get-Percentile $Values 0.5; p85 = Get-Percentile $Values 0.85; n = @($Values).Count }
}

function Get-WeekStart([datetime] $Moment) {
    $day = (ConvertTo-Moment $Moment).Date
    return $day.AddDays( - (([int] $day.DayOfWeek + 6) % 7))
}

function Get-CycleTime($History) {
    # From the first column after Todo to the first Done after it, in hours; $null when either is missing.
    $start = @($History | Where-Object { $_.column -ne 'Todo' -and $_.column -ne 'Done' }) | Select-Object -First 1
    if ($null -eq $start) { return $null }
    $done = @($History | Where-Object { $_.column -eq 'Done' -and $_.enteredAt -ge $start.enteredAt }) | Select-Object -First 1
    if ($null -eq $done) { return $null }
    return ($done.enteredAt - $start.enteredAt).TotalHours
}

function Get-WorkItemStats([object[]] $Items, [datetime] $Now, [int] $StatsDays, [int] $Weeks) {
    # $Items: the work items as Build-WorkItem makes them (moments are [datetime]).
    $since = $Now.AddDays(-$StatsDays)
    $wip = [ordered] @{}
    foreach ($column in $script:Columns) { if ($column -ne 'Done') { $wip[$column] = @($Items | Where-Object { $_.column -eq $column }).Count } }

    $cycle = [Collections.Generic.List[double]]::new()
    $lead = [Collections.Generic.List[double]]::new()
    foreach ($item in @($Items)) {
        $done = @($item.columnHistory | Where-Object { $_.column -eq 'Done' }) | Select-Object -First 1
        $hours = Get-CycleTime $item.columnHistory
        if ($null -ne $hours -and $null -ne $done -and $done.enteredAt -ge $since) { $cycle.Add($hours) }
        $prod = $item.environments['prod']
        if ($null -ne $prod -and $null -ne $prod.deployedAt -and $prod.deployedAt -ge $since) { $lead.Add(($prod.deployedAt - $item.createdAt).TotalHours) }
    }

    $current = Get-WeekStart $Now
    $perWeek = [Collections.Generic.List[object]]::new()
    for ($w = $Weeks - 1; $w -ge 0; $w--) {
        $start = $current.AddDays(-7 * $w)
        $end = $start.AddDays(7)
        $merged = @($Items | Where-Object { $null -ne $_.mergedAt -and $_.mergedAt -ge $start -and $_.mergedAt -lt $end }).Count
        $deployed = @($Items | Where-Object { $p = $_.environments['prod']; $null -ne $p -and $null -ne $p.deployedAt -and $p.deployedAt -ge $start -and $p.deployedAt -lt $end }).Count
        $perWeek.Add([ordered] @{ weekStart = $start.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture); merged = $merged; deployedProd = $deployed })
    }

    $tested = @($Items | Where-Object { $_.ftFailures -gt 0 -or $null -ne $_.mergedAt -or @($_.columnHistory | Where-Object { $_.column -in 'Functional Testing', 'Release Queue' }).Count -gt 0 })
    $reworked = @($tested | Where-Object { $_.ftFailures -gt 0 -or $_.reverts -gt 0 }).Count
    $failures = 0; $reverts = 0
    foreach ($item in @($Items)) { $failures += $item.ftFailures; $reverts += $item.reverts }
    return [ordered] @{
        wipByColumn    = $wip
        cycleTimeHours = Get-Summary $cycle.ToArray()
        leadTimeHours  = Get-Summary $lead.ToArray()
        perWeek        = $perWeek.ToArray()
        rework         = [ordered] @{
            ftFailures    = $failures
            reverts       = $reverts
            reworkedItems = $reworked
            testedItems   = $tested.Count
            rate          = if ($tested.Count -gt 0) { [Math]::Round($reworked / $tested.Count, 3) } else { $null }
        }
        cost           = [ordered] @{ totalUsd = $null; note = $script:CostNote }
    }
}

function Get-BotFlow($Items, [datetime] $Now, [int] $StatsDays) {
    # What only the bot items carry: median hours in each column, how many reached Done per agent in the window,
    # and merge-to-prod hours.
    $since = $Now.AddDays(-$StatsDays)
    $hours = @{}
    foreach ($column in $script:Columns) { $hours[$column] = [Collections.Generic.List[double]]::new() }
    $done = @{}
    $toProd = [Collections.Generic.List[double]]::new()
    foreach ($item in @($Items)) {
        foreach ($visit in @($item.columnHistory)) {
            if ($null -eq $visit.hours -or -not $hours.ContainsKey([string] $visit.column)) { continue }
            $hours[$visit.column].Add([double] $visit.hours)
        }
        $reached = @($item.columnHistory | Where-Object { $_.column -eq 'Done' }) | Select-Object -First 1
        if ($null -ne $reached -and $reached.enteredAt -ge $since) {
            $agent = if ($item.agent) { [string] $item.agent } else { 'unknown' }
            if (-not $done.ContainsKey($agent)) { $done[$agent] = 0 }
            $done[$agent]++
        }
        $prod = $item.environments['prod']
        if ($null -ne $item.mergeToProdHours -and $null -ne $prod -and $null -ne $prod.deployedAt -and $prod.deployedAt -ge $since) { $toProd.Add([double] $item.mergeToProdHours) }
    }
    $byColumn = [ordered] @{}
    foreach ($column in $script:Columns) { if ($hours[$column].Count -gt 0) { $byColumn[$column] = Get-Percentile $hours[$column].ToArray() 0.5 } }
    $byAgent = [ordered] @{}
    foreach ($agent in @($done.Keys | Sort-Object)) { $byAgent[$agent] = $done[$agent] }
    return [ordered] @{ hoursByColumn = $byColumn; throughputByAgent = $byAgent; mergeToProdHours = Get-Summary $toProd.ToArray() }
}

function Get-GroupedStats([object[]] $Items, [datetime] $Now, [int] $StatsDays, [int] $Weeks) {
    # stats.all, stats.bot and stats.team, with the keys of stats.all also at the top (the first contract).
    $all = Get-WorkItemStats @($Items) $Now $StatsDays $Weeks
    $botItems = @($Items | Where-Object { $_.worker -eq 'bot' })
    $bot = Get-WorkItemStats $botItems $Now $StatsDays $Weeks
    foreach ($entry in (Get-BotFlow $botItems $Now $StatsDays).GetEnumerator()) { $bot[$entry.Key] = $entry.Value }
    $team = Get-WorkItemStats @($Items | Where-Object { $_.worker -eq 'team' }) $Now $StatsDays $Weeks
    $stats = [ordered] @{}
    foreach ($key in @($all.Keys)) { $stats[$key] = $all[$key] }
    $stats['all'] = $all
    $stats['bot'] = $bot
    $stats['team'] = $team
    return $stats
}

function Build-WorkItem($Issue, [object[]] $PullRequests, $Context) {
    # One work item, its moments as [datetime] (ConvertTo-WorkItemJson formats them). $Context: ProjectNumber,
    # ProjectReadable, Environments (names, in order), FirstRelease (commit to release), FirstPin (environment to:
    # commit to pin), Running (environment to: Commits, a set of commits contained in the one running there),
    # Reverted (pull request numbers), RepositoryUrl.
    $comments = @(Get-Nodes (Get-Value $Issue 'comments'))
    $state = Read-FactoryState $comments
    $reasons = Get-BotEvidence $Issue $PullRequests $state
    $worker = if ($reasons.Count -gt 0) { 'bot' } else { 'team' }

    $prs = [Collections.Generic.List[object]]::new()
    foreach ($pr in @($PullRequests | Sort-Object { [int] (Get-Value $_ 'number') })) {
        $one = [ordered] @{
            number   = [int] (Get-Value $pr 'number')
            url      = [string] (Get-Value $pr 'url')
            state    = ([string] (Get-Value $pr 'state')).ToLowerInvariant()
            mergedAt = ConvertTo-Moment (Get-Value $pr 'mergedAt')
            mergeSha = if ((Get-Value $pr 'state') -eq 'MERGED') { [string] (Get-Value $pr 'mergeCommit', 'oid') } else { $null }
        }
        if ($worker -eq 'bot') { $one.checks = Get-ChecksConclusion $pr }
        $prs.Add($one)
    }
    $statePr = Get-Value $state 'merge', 'pr'
    if ($null -eq $statePr) { $statePr = Get-Value $state 'pr', 'number' }
    if ($null -ne $statePr -and -not @($prs | Where-Object { $_.number -eq [int] $statePr })) {
        # The factory's pull request, not among those read (older than the window): what its state says of it.
        $mergeSha = [string] (Get-Value $state 'merge', 'sha')
        $prs.Add([ordered] @{
                number   = [int] $statePr
                url      = "$($Context.RepositoryUrl)/pull/$statePr"
                state    = if ($mergeSha) { 'merged' } else { 'open' }
                mergedAt = ConvertTo-Moment (Get-Value $state 'merge', 'merged_at')
                mergeSha = if ($mergeSha) { $mergeSha } else { $null }
            })
    }
    $lastMerged = @($prs | Where-Object { $_.mergeSha } | Sort-Object -Stable { $_.mergedAt }) | Select-Object -Last 1
    $firstMerged = @($prs | Where-Object { $_.mergeSha } | Sort-Object -Stable { $_.mergedAt }) | Select-Object -First 1
    $mergeSha = if ($lastMerged) { $lastMerged.mergeSha } else { $null }

    $release = $null
    $environments = [ordered] @{}
    foreach ($environment in $Context.Environments) {
        $environments[$environment] = $null
        if (-not $mergeSha) { continue }
        $running = $Context.Running[$environment]
        if ($null -eq $running -or -not $running.Commits.Contains($mergeSha)) { continue }
        $pin = if ($Context.FirstPin.ContainsKey($environment)) { $Context.FirstPin[$environment][$mergeSha] } else { $null }
        $environments[$environment] = if ($pin) { [ordered] @{ version = $pin.version; deployedAt = $pin.at } } else { [ordered] @{ version = $running.Version; deployedAt = $null } }
    }
    if ($mergeSha -and $Context.FirstRelease.ContainsKey($mergeSha)) {
        $r = $Context.FirstRelease[$mergeSha]
        $release = [ordered] @{ version = $r.version; createdAt = $r.createdAt }
    }

    $status = if ($Context.ProjectReadable) { Get-ProjectStatus $Issue $Context.ProjectNumber } else { $null }
    $timeline = @(Get-Nodes (Get-Value $Issue 'timelineItems'))
    $history = if ($Context.ProjectReadable) { Get-ProjectHistory $timeline $Context.ProjectNumber $status } else { @() }
    $closedAt = ConvertTo-Moment (Get-Value $Issue 'closedAt')
    $issueState = ([string] (Get-Value $Issue 'state')).ToLowerInvariant()
    if ($status) {
        $column = $status
    }
    else {
        # The project's Status is the column. Without it, only cm-ai-ops-bot's journal; a factory-state comment is not one.
        $history = Get-JournalHistory $comments
        $column = if ($history.Count -gt 0) { $history[-1].column } elseif ($issueState -eq 'closed') { 'Done' } else { 'Todo' }
        $prod = $environments['prod']
        $derived = [Collections.Generic.List[object]]::new()
        foreach ($entry in $history) { $derived.Add($entry) }
        if ($column -eq 'Release Queue' -and $null -ne $prod -and $null -ne $prod.deployedAt) {
            # The factory moves a Release Queue item to Done when its release succeeds in prod.
            Add-HistoryEntry $derived 'Done' $prod.deployedAt
            $column = 'Done'
        }
        elseif ($issueState -eq 'closed' -and $column -notin 'Release Queue', 'Done') {
            # Closed without reaching Release Queue: off the board.
            Add-HistoryEntry $derived 'Done' $closedAt
            $column = 'Done'
        }
        $history = Optimize-History $derived.ToArray()
    }
    $asOf = if ($Context -is [Collections.IDictionary] -and $Context.Contains('Now') -and $Context['Now']) { ConvertTo-Moment $Context['Now'] } else { [datetime]::UtcNow }
    if ($worker -eq 'bot') { $history = Add-ColumnSpan $history $asOf }
    $prodAt = $environments['prod']
    $mergeToProd = $null
    if ($worker -eq 'bot' -and $null -ne $lastMerged -and $null -ne $lastMerged.mergedAt -and $null -ne $prodAt -and $null -ne $prodAt.deployedAt) {
        $mergeToProd = [Math]::Round(($prodAt.deployedAt - $lastMerged.mergedAt).TotalHours, 1, [MidpointRounding]::AwayFromZero)
    }

    $assignees = @(Get-Nodes (Get-Value $Issue 'assignees') | ForEach-Object { ConvertTo-Login ([string] (Get-Value $_ 'login')) })
    $assignee = @($assignees | Where-Object { $script:BotAssignees -contains $_ }) + @($assignees) | Select-Object -First 1
    $texts = @([string] (Get-Value $Issue 'body')) + @($comments | ForEach-Object { [string] (Get-Value $_ 'body') })
    foreach ($pr in @($PullRequests)) {
        $texts += [string] (Get-Value $pr 'body')
        $texts += @(Get-Nodes (Get-Value $pr 'comments') | ForEach-Object { [string] (Get-Value $_ 'body') })
    }
    $docsOnly = Get-Value $state 'merge', 'docs_only'
    if ($null -eq $docsOnly) { $docsOnly = Get-Value $state 'design', 'docs_only' }

    $item = [ordered] @{
        number         = [int] (Get-Value $Issue 'number')
        title          = [string] (Get-Value $Issue 'title')
        url            = [string] (Get-Value $Issue 'url')
        state          = $issueState
        createdAt      = ConvertTo-Moment (Get-Value $Issue 'createdAt')
        closedAt       = $closedAt
        column         = $column
        columnSource   = if ($status) { 'project' } else { 'derived' }
        columnHistory  = @($history)
        worker         = $worker
        assignee       = $assignee
        agent          = Get-Agent $Issue $state $PullRequests $reasons
        runtime        = Get-Runtime $Issue
        scopeReasons   = $reasons
        cursorSessions = Get-CursorSessions $texts
        prs            = $prs.ToArray()
        mergedAt       = if ($firstMerged) { $firstMerged.mergedAt } else { $null }
        docsOnly       = if ($null -ne $docsOnly) { [bool] $docsOnly } else { $null }
        releaseCandidate = $release
        environments   = $environments
        ftFailures     = Get-FunctionalTestingFailures $state $comments $history
        reverts        = @($prs | Where-Object { $_.state -eq 'merged' -and $Context.Reverted -contains $_.number }).Count
        costUsd        = $null
    }
    if ($worker -eq 'bot') {
        $item.latestStatusComment = Get-LatestStatusComment $comments
        $item.mergeToProdHours = $mergeToProd
    }
    return $item
}

function Test-InWindow($Item, [datetime] $Since) {
    # Kept: every open item, and a closed one closed, merged or deployed somewhere since $Since.
    if ($Item.state -ne 'closed') { return $true }
    if ($null -ne $Item.closedAt -and $Item.closedAt -ge $Since) { return $true }
    if ($null -ne $Item.mergedAt -and $Item.mergedAt -ge $Since) { return $true }
    foreach ($e in $Item.environments.Values) { if ($null -ne $e -and $null -ne $e.deployedAt -and $e.deployedAt -ge $Since) { return $true } }
    return $false
}

function ConvertTo-Published($Value) {
    # The file's form: moments as "yyyy-MM-ddTHH:mm:ssZ", the rest as it is.
    if ($Value -is [datetime] -or $Value -is [DateTimeOffset]) { return Format-Moment $Value }
    if ($Value -is [Collections.IDictionary]) {
        $out = [ordered] @{}
        foreach ($key in $Value.Keys) { $out[$key] = ConvertTo-Published $Value[$key] }
        return $out
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-Published $_ })
    }
    return $Value
}

function ConvertTo-PublishedItem($Item) {
    # The contract's order; mergedAt stays inside prs.
    $out = ConvertTo-Published $Item
    $out.Remove('mergedAt')
    return $out
}

if ($LoadOnly) { return }

# ---------------------------------------------------------------------------------------------------------------- #
# Reading GitHub (gh, with GH_TOKEN) and git.

function Invoke-Graph([string] $Query, [hashtable] $Variables = @{}) {
    # One GraphQL request; a failure that may pass is asked again, four attempts in all. Answers data and errors.
    $arguments = @('api', 'graphql', '-f', "query=$Query")
    foreach ($key in $Variables.Keys) { if ($null -ne $Variables[$key]) { $arguments += @('-f', "$key=$($Variables[$key])") } }
    for ($attempt = 1; ; $attempt++) {
        $text = (& gh @arguments 2>$null) -join "`n"
        $answer = if ($text) { try { $text | ConvertFrom-Json -AsHashtable -Depth 100 } catch { $null } } else { $null }
        if ($null -ne $answer -and $null -ne (Get-Value $answer 'data')) { return $answer }
        if ($attempt -ge 4) {
            $said = if ($null -ne $answer) { (@(Get-Value $answer 'errors') | ForEach-Object { Get-Value $_ 'message' }) -join '; ' } else { 'no answer' }
            throw "GitHub GraphQL failed after four attempts: $said"
        }
        Start-Sleep -Seconds (5 * $attempt)
    }
}

function Get-Connection([string] $Query, [string[]] $Connection, [hashtable] $Variables, $UpdatedBefore = $null) {
    # Every node of a paged connection ($Connection: its path under data); with $UpdatedBefore, of a list ordered by
    # updatedAt (newest first), until the first node updated before it.
    $nodes = [Collections.Generic.List[object]]::new()
    $cursor = $null
    while ($true) {
        $vars = @{} + $Variables
        $vars['cursor'] = $cursor
        $answer = Invoke-Graph $Query $vars
        $page = Get-Value (Get-Value $answer 'data') $Connection
        $stopped = $false
        foreach ($node in (Get-Nodes $page)) {
            if ($null -ne $UpdatedBefore -and (ConvertTo-Moment (Get-Value $node 'updatedAt')) -lt $UpdatedBefore) { $stopped = $true; break }
            $nodes.Add($node)
        }
        if ($stopped -or -not (Get-Value $page 'pageInfo', 'hasNextPage')) { break }
        $cursor = [string] (Get-Value $page 'pageInfo', 'endCursor')
    }
    return , $nodes.ToArray()
}

$issueFields = @'
number title url state createdAt closedAt updatedAt body
author { login }
labels(first: 50) { nodes { name } }
assignees(first: 10) { nodes { login } }
projectItems(first: 10) { nodes { project { number } fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }
comments(first: 100) { nodes { author { login } createdAt url body } }
timelineItems(first: 100, itemTypes: [ASSIGNED_EVENT, ADDED_TO_PROJECT_V2_EVENT, PROJECT_V2_ITEM_STATUS_CHANGED_EVENT]) {
  nodes {
    __typename
    ... on AssignedEvent { createdAt assignee { ... on User { login } ... on Bot { login } } }
    ... on AddedToProjectV2Event { createdAt project { number } }
    ... on ProjectV2ItemStatusChangedEvent { createdAt previousStatus status project { number } }
  }
}
'@
$pullFields = @'
number title url state createdAt updatedAt mergedAt body headRefName
author { login __typename }
mergeCommit { oid }
commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
closingIssuesReferences(first: 10) { nodes { number } }
comments(first: 100) { nodes { body } }
'@

function Get-Issues([string] $Owner, [string] $Name, [datetime] $Since) {
    $byNumber = [ordered] @{}
    $recent = "query(`$owner: String!, `$name: String!, `$since: DateTime!, `$cursor: String) { repository(owner: `$owner, name: `$name) { issues(first: 25, after: `$cursor, filterBy: { since: `$since }, orderBy: { field: UPDATED_AT, direction: DESC }) { pageInfo { hasNextPage endCursor } nodes { $issueFields } } } }"
    $open = "query(`$owner: String!, `$name: String!, `$cursor: String) { repository(owner: `$owner, name: `$name) { issues(first: 25, after: `$cursor, states: OPEN) { pageInfo { hasNextPage endCursor } nodes { $issueFields } } } }"
    foreach ($issue in (Get-Connection $recent @('repository', 'issues') @{ owner = $Owner; name = $Name; since = (Format-Moment $Since) })) { $byNumber[[string] $issue['number']] = $issue }
    foreach ($issue in (Get-Connection $open @('repository', 'issues') @{ owner = $Owner; name = $Name })) { $byNumber[[string] $issue['number']] = $issue }
    return , @($byNumber.Values)
}

function Get-PullRequests([string] $Owner, [string] $Name, [datetime] $Since) {
    $byNumber = [ordered] @{}
    $recent = "query(`$owner: String!, `$name: String!, `$cursor: String) { repository(owner: `$owner, name: `$name) { pullRequests(first: 50, after: `$cursor, orderBy: { field: UPDATED_AT, direction: DESC }) { pageInfo { hasNextPage endCursor } nodes { $pullFields } } } }"
    $open = "query(`$owner: String!, `$name: String!, `$cursor: String) { repository(owner: `$owner, name: `$name) { pullRequests(first: 50, after: `$cursor, states: OPEN) { pageInfo { hasNextPage endCursor } nodes { $pullFields } } } }"
    foreach ($pr in (Get-Connection $recent @('repository', 'pullRequests') @{ owner = $Owner; name = $Name } $Since)) { $byNumber[[string] $pr['number']] = $pr }
    foreach ($pr in (Get-Connection $open @('repository', 'pullRequests') @{ owner = $Owner; name = $Name })) { $byNumber[[string] $pr['number']] = $pr }
    return , @($byNumber.Values)
}

function Get-Rest([string] $Endpoint, [string] $Jq) {
    # Every page of a REST list, one JSON object per line from --jq.
    for ($attempt = 1; ; $attempt++) {
        $lines = & gh api --paginate $Endpoint --jq $Jq 2>$null
        if ($LASTEXITCODE -eq 0) { return , @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable }) }
        if ($attempt -ge 4) { throw "GitHub refused $Endpoint after four attempts." }
        Start-Sleep -Seconds (5 * $attempt)
    }
}

function Test-ProjectReadable([string] $Owner, [int] $Number) {
    # @{ Readable; Title; Reason }. The node id is project 679; its number is checked so a different project is not
    # read by mistake. It answers only to a token with organization Projects read.
    $id = $script:ProjectNodeId
    $text = (& gh api graphql -f "query=query { node(id: `"$id`") { ... on ProjectV2 { number title } } }" 2>$null) -join "`n"
    try { $answer = $text | ConvertFrom-Json -AsHashtable -Depth 20 } catch { $answer = $null }
    $project = Get-Value $answer 'data', 'node'
    $title = [string] (Get-Value $project 'title')
    if ($title -and [int] (Get-Value $project 'number') -eq $Number) { return @{ Readable = $true; Title = $title; Reason = $null } }
    $said = (@(Get-Value $answer 'errors') | Where-Object { $_ } | ForEach-Object { Get-Value $_ 'message' }) -join '; '
    if ($title) { $said = "node $id is project $([int] (Get-Value $project 'number')) ($title), not project $Number" }
    return @{ Readable = $false; Title = $null; Reason = if ($said) { $said } else { 'no answer' } }
}

function Get-ProjectGap($Access) {
    # Which token was tried (the workflow sets BOARD_TOKEN_SOURCE) and the secret that would read the board.
    $source = if ($env:BOARD_TOKEN_SOURCE) { [string] $env:BOARD_TOKEN_SOURCE } else { 'GH_TOKEN' }
    $secret = 'GH_PROJECT_TOKEN, an Actions secret of clearmeasure-aisf-sample-apps/cmdemo1-system: a token with read access to organization project 679 (node PVT_kwDOD_ESUc4BliGL). No other secret is needed, and none was added'
    return "project $($script:ProjectNodeId) (project 679): not readable with $source ($($Access.Reason)); columns are derived from cm-ai-ops-bot journal comments. The workflow tries $secret, then the cmdemo1-system App with Organization projects: read, then this workflow's own token."
}

$now = [datetime]::UtcNow
$since = $now.AddDays(-$Days)
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$system = Get-Content -LiteralPath (Join-Path $root 'system.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 50
$owner = [string] $system['system']['githubOrg']
$deployableEntry = @($system['deployables'] | Where-Object { $_['name'] -eq $Deployable }) | Select-Object -First 1
if ($null -eq $deployableEntry) { throw "system.json has no deployable '$Deployable'." }
$repoName = [string] $deployableEntry['repository']
$repository = "$owner/$repoName"
$repositoryUrl = "https://github.com/$repository"
$environmentNames = @($system['environments'] | ForEach-Object { [string] $_['name'] } | Where-Object { $null -eq $deployableEntry['environments'] -or @($deployableEntry['environments']) -contains $_ })
$missing = [Collections.Generic.List[string]]::new()

$projectAccess = Test-ProjectReadable $owner $Project
if ($projectAccess.Readable) { Write-Host "Project $Project ($($projectAccess.Title)) is readable: columns come from its Status." }
else {
    Write-Host "Project $Project is not readable ($($projectAccess.Reason)): columns come from cm-ai-ops-bot's journal."
    $missing.Add((Get-ProjectGap $projectAccess))
}

if (-not $Clone) {
    $Clone = Join-Path ([IO.Path]::GetTempPath()) "workitems-$repoName"
    if (Test-Path -LiteralPath $Clone) { Remove-Item -LiteralPath $Clone -Recurse -Force }
    & git clone --quiet --filter=tree:0 --no-checkout "https://github.com/$repository.git" $Clone
    if ($LASTEXITCODE -ne 0) { throw "git clone of $repository failed." }
}
$branch = ((& git -C $Clone symbolic-ref --short HEAD) -join '').Trim()
$commitSubjects = @(& git -C $Clone log --format=%s $branch)
$revList = {
    param([string] $Sha, [string[]] $Earlier)
    & git -C $Clone cat-file -e "$Sha^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { return @{ Known = $false; Commits = @() } }
    $arguments = @('-C', $Clone, 'rev-list', $Sha)
    if ($Earlier.Count -gt 0) { $arguments += '--not'; $arguments += $Earlier }
    return @{ Known = $true; Commits = @(& git @arguments) }
}.GetNewClosure()

Write-Host "Reading the issues and pull requests of $repository since $(Format-Moment $since), and every open one."
$issues = Get-Issues $owner $repoName $since
$pulls = Get-PullRequests $owner $repoName $since.AddDays(-7)
Write-Host "Read $($issues.Count) issues and $($pulls.Count) pull requests."
$runs = Get-Rest "repos/$repository/actions/workflows/build.yml/runs?branch=$branch&per_page=100" '.workflow_runs[] | {run_number, head_sha, event, conclusion, created_at, updated_at, display_title}'
$releaseDeployments = Get-Rest "repos/$repository/deployments?environment=release&per_page=100" '.[] | {sha, created_at}'

$delivery = $null
if ($DeliveryPath -and (Test-Path -LiteralPath $DeliveryPath)) { $delivery = Get-Content -LiteralPath $DeliveryPath -Raw | ConvertFrom-Json -AsHashtable -Depth 50 }
else { $missing.Add('delivery.json: not given; the commit running in each environment is that of its pinned version') }

$pinsByEnvironment = @{}
$pinnedVersions = [Collections.Generic.List[string]]::new()
foreach ($environment in $environmentNames) {
    $lines = @(& git -C $root log --reverse '--format=%cI%x09%s' -- "environments/$environment/versions.json")
    $pins = Read-PinEvents $lines $Deployable
    $pinsByEnvironment[$environment] = @($pins | Where-Object { $_.environment -eq $environment })
    foreach ($pin in $pinsByEnvironment[$environment]) { $pinnedVersions.Add($pin.version) }
    $file = Join-Path $root "environments/$environment/versions.json"
    if (Test-Path -LiteralPath $file) { $current = [string] ((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable)[$Deployable]); if ($current) { $pinnedVersions.Add($current) } }
}
$releases = Get-Releases $releaseDeployments $runs $pinnedVersions.ToArray()
$shaOfVersion = @{}
foreach ($release in $releases) { $shaOfVersion[$release.version] = $release.sha }
Write-Host "Found $($releases.Count) releases of $Deployable."

$firstRelease = Get-FirstContaining $releases $revList
$firstPin = @{}
$running = @{}
foreach ($environment in $environmentNames) {
    $points = Get-PinPoints $pinsByEnvironment[$environment] $environment $shaOfVersion
    $firstPin[$environment] = Get-FirstContaining $points $revList
    $version = $null; $sha = $null
    $deliveryEnvironment = @(Get-Value $delivery 'environments' | Where-Object { (Get-Value $_ 'name') -eq $environment }) | Select-Object -First 1
    $deliveryEntry = @(Get-Value $deliveryEnvironment 'deployables' | Where-Object { (Get-Value $_ 'name') -eq $Deployable }) | Select-Object -First 1
    if ($null -ne $deliveryEntry -and (Get-Value $deliveryEntry 'commit')) { $version = [string] (Get-Value $deliveryEntry 'version'); $sha = [string] (Get-Value $deliveryEntry 'commit') }
    else {
        $file = Join-Path $root "environments/$environment/versions.json"
        if (Test-Path -LiteralPath $file) { $version = [string] ((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable)[$Deployable]) }
        if ($version -and $shaOfVersion.ContainsKey($version)) { $sha = $shaOfVersion[$version] }
    }
    $commits = [Collections.Generic.HashSet[string]]::new()
    if ($sha) {
        $answer = & $revList $sha @()
        foreach ($c in @($answer.Commits)) { [void] $commits.Add($c) }
        if (-not $answer.Known) { $missing.Add("${environment}: the commit it runs ($sha, $Deployable $version) is not on $branch of $repository") }
    }
    else { $missing.Add("${environment}: the commit $Deployable $version runs there is not known") }
    $running[$environment] = @{ Version = $version; Commits = $commits }
}

$pullsByIssue = @{}
foreach ($pr in $pulls) {
    foreach ($number in (Get-LinkedIssueNumbers $pr $repoName)) {
        if (-not $pullsByIssue.ContainsKey($number)) { $pullsByIssue[$number] = [Collections.Generic.List[object]]::new() }
        $pullsByIssue[$number].Add($pr)
    }
}
$context = @{
    ProjectNumber   = $Project
    ProjectReadable = $projectAccess.Readable
    Environments    = $environmentNames
    FirstRelease    = $firstRelease
    FirstPin        = $firstPin
    Running         = $running
    Reverted        = Get-RevertedPullRequests $pulls $commitSubjects
    RepositoryUrl   = $repositoryUrl
}
$items = [Collections.Generic.List[object]]::new()
foreach ($issue in $issues) {
    $number = [int] $issue['number']
    $linked = if ($pullsByIssue.ContainsKey($number)) { $pullsByIssue[$number].ToArray() } else { @() }
    # A factory-state comment names the pull request; one the links did not find is added from the pulls read.
    $state = Read-FactoryState @(Get-Nodes $issue['comments'])
    $statePr = Get-Value $state 'merge', 'pr'
    if ($null -eq $statePr) { $statePr = Get-Value $state 'pr', 'number' }
    if ($null -ne $statePr -and -not @($linked | Where-Object { [int] $_['number'] -eq [int] $statePr })) { $linked = @($linked) + @($pulls | Where-Object { [int] $_['number'] -eq [int] $statePr }) }
    $item = Build-WorkItem $issue $linked $context
    if ($null -ne $item -and (Test-InWindow $item $since)) { $items.Add($item) }
}
$sortedItems = @($items | Sort-Object { $_.number } -Descending)
$botCount = @($sortedItems | Where-Object { $_.worker -eq 'bot' }).Count
$teamCount = @($sortedItems | Where-Object { $_.worker -eq 'team' }).Count
Write-Host "$($sortedItems.Count) work items: $botCount bot, $teamCount team."

$releaseItems = @{}
foreach ($item in $sortedItems) {
    if ($null -eq $item.releaseCandidate) { continue }
    $v = $item.releaseCandidate.version
    if (-not $releaseItems.ContainsKey($v)) { $releaseItems[$v] = [Collections.Generic.List[int]]::new() }
    $releaseItems[$v].Add($item.number)
}
$publishedReleases = @($releases | Where-Object { $_.createdAt -ge $since -or $releaseItems.ContainsKey($_.version) } | Sort-Object { $_.createdAt } -Descending | ForEach-Object {
        [ordered] @{ version = $_.version; sha = $_.sha; createdAt = $_.createdAt; items = @(if ($releaseItems.ContainsKey($_.version)) { $releaseItems[$_.version] | Sort-Object }) }
    })

$document = [ordered] @{
    generatedAt = $now
    scope       = [ordered] @{
        repo         = $repository
        project      = $Project
        projectTitle = $projectAccess.Title
        deployable   = $Deployable
        columnSource = if ($projectAccess.Readable) { 'project' } else { 'derived' }
        columns      = $script:Columns
        window       = [ordered] @{ days = $Days; statsDays = $StatsDays; weeks = $Weeks }
        rules        = @(
            'Every issue of the repository. worker "bot": assigned (now or before) to cm-ai-ops-bot, or a linked pull request by cm-ai-ops-bot, factory-worker-author, cursor, Copilot or another bot account, or a factory label or factory-state comment (the record on the issue). worker "team": everyone else. agent is that identity.'
            "Kept: every open item, and closed items closed, merged or deployed in the last $Days days."
            'Linked pull request: closing reference; "Closes/Fixes/Resolves/Refs #N"; a title ending "(#N)"; branch factory-worker/<N>-* or issue-<N>-*; the pull request named in a factory-state comment.'
            "column: the item's Status on project $Project (node $($script:ProjectNodeId)) when readable, else cm-ai-ops-bot's journal lines only (A → B). A factory-state comment is not a column. A derived Release Queue item whose change runs in prod is Done at that deployment; a closed issue that never reached Release Queue is Done when closed."
            "releaseCandidate: the first release (GitHub deployment 'release', version of its master Build run) whose commit contains the merge commit of the item's last merged pull request."
            "environments.<env>: the first non-reverted pin of $Deployable in that environment whose release contains the merge commit (version, pin time), while the commit running there (delivery.json) still contains it."
            'ftFailures: the most of the fworker''s demotions, its "Functional Testing: FAIL" verdicts and moves from Functional Testing back to an earlier column; reverts: merged pull requests of the item reverted on the default branch.'
        )
    }
    stats       = Get-GroupedStats $sortedItems $now $StatsDays $Weeks
    items       = @($sortedItems | ForEach-Object { ConvertTo-PublishedItem $_ })
    releases    = $publishedReleases
    missing     = $missing.ToArray()
}
$json = (ConvertTo-Published $document) | ConvertTo-Json -Depth 20
Set-Content -LiteralPath $Path -Value $json -Encoding utf8NoBOM
Write-Host "Wrote $Path ($([Math]::Round((Get-Item -LiteralPath $Path).Length / 1KB)) KB)."
