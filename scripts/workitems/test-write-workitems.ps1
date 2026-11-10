#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the parsing and mapping rules of write-workitems.ps1 (pure functions, no network). PASS or FAIL per case;
    exit 1 on a FAIL.
.EXAMPLE
    pwsh -NoProfile -File scripts/workitems/test-write-workitems.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'write-workitems.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $a = ConvertTo-Json -InputObject (ConvertTo-Published $Actual) -Compress -Depth 10
    $e = ConvertTo-Json -InputObject (ConvertTo-Published $Expected) -Compress -Depth 10
    if ($a -ceq $e) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $e, got $a"; $script:failures++ }
}
function Columns($History) { , @($History | ForEach-Object { "$($_.column)@$(Format-Moment $_.enteredAt)" }) }
function New-Comment([string] $Author, [string] $At, [string] $Body) { @{ author = @{ login = $Author }; createdAt = $At; body = $Body } }
function New-StateComment([hashtable] $State, [string] $Worker = 'factory-worker') {
    $json = $State | ConvertTo-Json -Depth 10
    New-Comment 'factory-worker-author' '2026-11-06T16:05:12Z' "<!-- factory-state:$Worker v1 -->`nstate of #1 for ``$Worker`` (machine-read; edits by others are ignored)`n`n``````json`n$json`n```````n"
}

# Factory state
$flowState = @{ schema = 1; item = 1512; updated = '2026-11-06T16:29:19.617Z'
    flow = @(@{ c = 'Technical Design'; at = '2026-11-06T16:05:10.949Z' }, @{ c = 'Development'; at = '2026-11-06T16:07:41.850Z' }, @{ c = 'Functional Testing'; at = '2026-11-06T16:10:35.428Z' })
    dispatched_at = @{ 'Technical Design' = '2026-11-06T16:05:49Z' }
    pr = @{ number = 1513 }; merge = @{ sha = '877684c9'; pr = 1513; merged_at = '2026-11-06T16:11:32.815Z'; done_at = '2026-11-06T16:11:32.815Z'; docs_only = $true }
}
$state = Read-FactoryState @((New-Comment 'someone' '2026-11-06T16:00:00Z' 'hello'), (New-StateComment $flowState))
Test-Case 'factory state is read from its comment' @($state['item'], $state['_worker']) @(1512, 'factory-worker')
Test-Case 'no state comment: no state' (Read-FactoryState @((New-Comment 'factory-worker-author' '2026-11-06T16:00:00Z' 'plain'))) $null
$older = @{ item = 7; updated = '2026-11-01T00:00:00Z'; flow = @() }
$newer = @{ item = 7; updated = '2026-11-02T00:00:00Z'; flow = @(); demotions = 2 }
Test-Case 'two state comments: the newer one' (Read-FactoryState @((New-StateComment $newer), (New-StateComment $older)))['demotions'] 2
Test-Case 'a state comment whose json does not parse is passed over' (Read-FactoryState @((New-Comment 'factory-worker-author' 'x' "<!-- factory-state:w v1 -->`n``````json`n{ not json`n```````n"))) $null

Test-Case 'flow gives the columns, done_at gives Done' (Columns (Get-FactoryHistory $state)) @('Technical Design@2026-11-06T16:05:10Z', 'Development@2026-11-06T16:07:41Z', 'Functional Testing@2026-11-06T16:10:35Z', 'Done@2026-11-06T16:11:32Z')
$dispatched = @{ dispatched_at = @{ 'Functional Testing' = '2026-10-26T14:47:15Z'; 'Technical Design' = '2026-10-26T14:36:42Z'; Development = '2026-10-26T14:45:16Z' }; merge = @{ queued_at = '2026-10-26T15:00:00Z' } }
Test-Case 'without flow: dispatched_at in time order, queued_at is Release Queue' (Columns (Get-FactoryHistory $dispatched)) @('Technical Design@2026-10-26T14:36:42Z', 'Development@2026-10-26T14:45:16Z', 'Functional Testing@2026-10-26T14:47:15Z', 'Release Queue@2026-10-26T15:00:00Z')
Test-Case 'an unknown column is left out' (Columns (Get-FactoryHistory @{ flow = @(@{ c = 'Parked'; at = '2026-10-01T00:00:00Z' }, @{ c = 'Development'; at = '2026-10-01T01:00:00Z' }) })) @('Development@2026-10-01T01:00:00Z')
Test-Case 'no state: no history' (Columns (Get-FactoryHistory $null)) @()

# Journal lines
$journal = @(
    (New-Comment 'cm-ai-ops-bot' '2026-11-09T22:07:44Z' 'Journal: launched a [Cursor agent](https://cursor.com/agents/bc-1) on branch x. Moving this item Todo → In Progress; will report the PR here.')
    (New-Comment 'cm-ai-ops-bot' '2026-11-09T22:23:09Z' 'Journal: checks green. Intended column: Technical Design → Functional Testing (via Development). PASS → squash-merge; FAIL → back to Development.')
    (New-Comment 'jeffreypalermo' '2026-11-09T22:30:00Z' 'Please move it Functional Testing → Done')
    (New-Comment 'cm-ai-ops-bot' '2026-11-09T22:55:31Z' "1. Todo → In Progress → Technical Design → Development: resumed.`n3. Functional Testing → Release Queue: merged.")
)
Test-Case 'journal arrows: chains, (via X), a skipped move, not people, not PASS/FAIL arrows, not a recap' (Columns (Get-JournalHistory $journal)) @(
    'In Progress@2026-11-09T22:07:44Z', 'Development@2026-11-09T22:23:09Z', 'Functional Testing@2026-11-09T22:23:09Z', 'Release Queue@2026-11-09T22:55:31Z')
Test-Case 'journal arrows: a move back from the current column counts' (Columns (Get-JournalHistory @(
            (New-Comment 'cm-ai-ops-bot' '2026-11-01T01:00:00Z' 'Development → Functional Testing'),
            (New-Comment 'cm-ai-ops-bot' '2026-11-01T02:00:00Z' 'FAIL: Functional Testing → Development')))) @('Functional Testing@2026-11-01T01:00:00Z', 'Development@2026-11-01T02:00:00Z')
Test-Case 'ASCII arrow counts too' (Columns (Get-JournalHistory @((New-Comment 'cm-ai-ops-bot' '2026-11-01T00:00:00Z' 'Development -> Functional Testing')))) @('Functional Testing@2026-11-01T00:00:00Z')
Test-Case 'a journal by anyone but cm-ai-ops-bot is not a column' (Columns (Get-JournalHistory @((New-Comment 'cursor' '2026-11-01T00:00:00Z' 'Development -> Functional Testing')))) @()
Test-Case 'a factory-state comment is no journal' (Columns (Get-JournalHistory @((New-StateComment @{ note = 'Todo → Done' })))) @()
Test-Case 'Optimize-History drops a column entered again right after itself' (Columns (Optimize-History @(
            [ordered] @{ column = 'Development'; enteredAt = (ConvertTo-Moment '2026-11-01T02:00:00Z') },
            [ordered] @{ column = 'Development'; enteredAt = (ConvertTo-Moment '2026-11-01T03:00:00Z') },
            [ordered] @{ column = 'Todo'; enteredAt = (ConvertTo-Moment '2026-11-01T01:00:00Z') }, @()))) @('Todo@2026-11-01T01:00:00Z', 'Development@2026-11-01T02:00:00Z')

# Project history (with project access)
$timeline = @(
    @{ __typename = 'AddedToProjectV2Event'; createdAt = '2026-11-01T00:00:00Z'; project = @{ number = 679 } }
    @{ __typename = 'ProjectV2ItemStatusChangedEvent'; createdAt = '2026-11-01T01:00:00Z'; previousStatus = 'Todo'; status = 'In Progress'; project = @{ number = 679 } }
    @{ __typename = 'ProjectV2ItemStatusChangedEvent'; createdAt = '2026-11-01T01:30:00Z'; previousStatus = 'x'; status = 'Done'; project = @{ number = 1 } }
    @{ __typename = 'ProjectV2ItemStatusChangedEvent'; createdAt = '2026-11-01T02:00:00Z'; previousStatus = 'In Progress'; status = 'Technical Design'; project = @{ number = 679 } }
)
Test-Case 'project: added time for the first column, then each change; other projects ignored' (Columns (Get-ProjectHistory $timeline 679 'Technical Design')) @('Todo@2026-11-01T00:00:00Z', 'In Progress@2026-11-01T01:00:00Z', 'Technical Design@2026-11-01T02:00:00Z')
Test-Case 'project: added and never moved is in its Status since then' (Columns (Get-ProjectHistory @($timeline[0]) 679 'Todo')) @('Todo@2026-11-01T00:00:00Z')
$issueOnBoard = @{ projectItems = @{ nodes = @(@{ project = @{ number = 5 }; fieldValueByName = @{ name = 'Done' } }, @{ project = @{ number = 679 }; fieldValueByName = @{ name = 'Development' } }) } }
Test-Case 'project status of the board, not of another project' (Get-ProjectStatus $issueOnBoard 679) 'Development'

# Cursor sessions
Test-Case 'cursor sessions: both forms, once each, in order' (Get-CursorSessions @('see https://cursor.com/agents/bc-154c759e-4686 and https://cursor.com/agents?id=bc-02e5', 'again [x](https://cursor.com/agents/bc-154c759e-4686).', $null)) @('https://cursor.com/agents/bc-154c759e-4686', 'https://cursor.com/agents/bc-02e5')

# Pull request links
$pr = @{ number = 1513; title = 'Docs: note 367 (#1512)'; body = "Refs #1512`nCloses #9 and fixes cmdemo1-workorders#10, not other-repo#11"; headRefName = 'factory-worker/1512-development'; closingIssuesReferences = @{ nodes = @(@{ number = 12 }) } }
Test-Case 'linked issues: closing refs, keywords, own repository, title, branch' (Get-LinkedIssueNumbers $pr 'cmdemo1-workorders') @(9, 10, 12, 1512)
Test-Case 'linked issues: issue-N branch' (Get-LinkedIssueNumbers @{ number = 1561; title = 'Docs'; body = ''; headRefName = 'issue-1560-readme-ai-ops-bot'; closingIssuesReferences = @{ nodes = @() } } 'cmdemo1-workorders') @(1560)
Test-Case 'linked issues: a mention is no link' (Get-LinkedIssueNumbers @{ number = 2; title = 'Tidy'; body = 'like #44 did'; headRefName = 'cm-ai-ops-bot/tidy'; closingIssuesReferences = $null } 'cmdemo1-workorders') @()

Test-Case 'reverted: merged revert PR by body and by title; an unmerged revert and plain titles count nothing; commit subject' (Get-RevertedPullRequests @(
        @{ number = 295; state = 'CLOSED'; title = 'Revert #264: back to three shards'; body = '' }
        @{ number = 300; state = 'MERGED'; title = 'Revert "Add thing"'; body = 'Reverts clearmeasure-aisf-sample-apps/cmdemo1-workorders#280' }
        @{ number = 301; state = 'MERGED'; title = 'Revert #290 (broke master)'; body = '' }
        @{ number = 302; state = 'MERGED'; title = 'Reverting nothing: docs'; body = '' }
    ) @('Revert "Docs: note (#350)" (#351)', 'Add a revert button (#360)')) @(280, 290, 350)

# Scope and agent
$botIssue = @{ number = 1565; assignees = @{ nodes = @() }; labels = @{ nodes = @(@{ name = 'enhancement' }) }; timelineItems = @{ nodes = @(@{ __typename = 'AssignedEvent'; assignee = @{ login = 'cm-ai-ops-bot' } }) } }
Test-Case 'bot: assigned before, though not now' (Get-BotEvidence $botIssue @() $null) @('assigned to cm-ai-ops-bot')
$labelled = @{ assignees = @{ nodes = @() }; labels = @{ nodes = @(@{ name = 'factory worker' }, @{ name = 'worker:cloud-4' }, @{ name = 'Auto Merge' }, @{ name = 'AI Factory' }) }; timelineItems = @{ nodes = @() } }
Test-Case 'bot: factory labels, the record on the issue' (Get-BotEvidence $labelled @() $null) @('label factory worker', 'label worker:cloud-4', 'label AI Factory')
$plain = @{ assignees = @{ nodes = @(@{ login = 'jeffreypalermo' }) }; labels = @{ nodes = @(@{ name = 'enhancement' }) }; timelineItems = @{ nodes = @() } }
Test-Case 'team: a person''s issue has no bot evidence' (Get-BotEvidence $plain @(@{ author = @{ login = 'jeffreypalermo' } }) $null) @()
Test-Case 'bot: a pull request by the factory (gh form of the login)' (Get-BotEvidence $plain @(@{ author = @{ login = 'app/factory-worker-author' } }) $null) @('pull request by factory-worker-author')
Test-Case 'bot: Copilot, and an author GraphQL types as Bot' (Get-BotEvidence $plain @(@{ author = @{ login = 'copilot-swe-agent' } }, @{ author = @{ login = 'some-app'; __typename = 'Bot' } }) $null) @('pull request by copilot-swe-agent', 'pull request by some-app')
Test-Case 'bot: a factory-state comment' (Get-BotEvidence $plain @() @{ _worker = 'factory-worker' }) @('factory state (factory-worker)')
Test-Case 'agent: the factory-state worker when it keeps a state' (Get-Agent $plain @{ _worker = 'factory-worker' } @() @('assigned to cm-ai-ops-bot')) 'factory-worker'
Test-Case 'agent: the assigned bot' (Get-Agent $botIssue $null @() @('assigned to cm-ai-ops-bot')) 'cm-ai-ops-bot'
Test-Case 'agent: the bot of the pull request' (Get-Agent $plain $null @(@{ author = @{ login = 'cursor' } }) @('pull request by cursor')) 'cursor'
Test-Case 'runtime from labels: runtime before worker' (Get-Runtime @{ labels = @{ nodes = @(@{ name = 'worker:cloud-4' }, @{ name = 'runtime:cursor-cloud' }) } }) 'cursor-cloud'

# Rework
$ftHistory = Optimize-History @(
    [ordered] @{ column = 'Development'; enteredAt = (ConvertTo-Moment '2026-11-01T01:00:00Z') }
    [ordered] @{ column = 'Functional Testing'; enteredAt = (ConvertTo-Moment '2026-11-01T02:00:00Z') }
    [ordered] @{ column = 'Development'; enteredAt = (ConvertTo-Moment '2026-11-01T03:00:00Z') }
    [ordered] @{ column = 'Functional Testing'; enteredAt = (ConvertTo-Moment '2026-11-01T04:00:00Z') })
Test-Case 'FT failures: moves back in the history' (Get-FunctionalTestingFailures $null @() $ftHistory) 1
Test-Case 'FT failures: the most of demotions, FAIL verdicts and moves back' (Get-FunctionalTestingFailures @{ demotions = 1 } @(
        (New-Comment 'factory-worker-author' 'x' '🤖 factory-worker: validation verdict for **Functional Testing**: FAIL - layout'),
        (New-Comment 'factory-worker-author' 'y' '🤖 factory-worker: validation verdict for **Functional Testing**: FAIL - again'),
        (New-Comment 'factory-worker-author' 'z' '🤖 factory-worker: validation verdict for **Functional Testing**: PASS')) @()) 2

# Releases and pins
$runs = @(
    @{ run_number = 2024; head_sha = 'c3'; event = 'push'; created_at = '2026-11-09T16:48:37Z'; updated_at = '2026-11-09T16:57:00Z'; display_title = '2.4.2024 • Build • master' }
    @{ run_number = 2021; head_sha = 'c2'; event = 'push'; created_at = '2026-11-09T16:24:53Z'; updated_at = '2026-11-09T16:35:00Z'; display_title = '2.4.2021 • Build • master' }
    @{ run_number = 2030; head_sha = 'c2'; event = 'workflow_dispatch'; created_at = '2026-11-09T18:00:00Z'; updated_at = '2026-11-09T18:10:00Z'; display_title = '2.4.2030 • Build • master' }
    @{ run_number = 2000; head_sha = 'c1'; event = 'push'; created_at = '2026-11-08T10:00:00Z'; updated_at = '2026-11-08T10:10:00Z'; display_title = '2.4.2000 • Build • master' }
    @{ run_number = 1999; head_sha = 'cx'; event = 'pull_request'; created_at = '2026-11-08T09:00:00Z'; updated_at = '2026-11-08T09:10:00Z'; display_title = '2.4.1999 • Build • pr' }
)
$deployments = @(@{ sha = 'c3'; created_at = '2026-11-09T16:58:14Z' }, @{ sha = 'c2'; created_at = '2026-11-09T16:36:24Z' }, @{ sha = 'c2'; created_at = '2026-11-09T18:12:00Z' })
$releases = Get-Releases $deployments $runs @('2.4.2000', '2.4.2024', '2.4.1')
Test-Case 'releases: version of the Build run before the deployment; a pinned version without deployment; oldest first' (@($releases | ForEach-Object { "$($_.version)/$($_.sha)@$(Format-Moment $_.createdAt)" })) @('2.4.2000/c1@2026-11-08T10:10:00Z', '2.4.2021/c2@2026-11-09T16:36:24Z', '2.4.2024/c3@2026-11-09T16:58:14Z', '2.4.2030/c2@2026-11-09T18:12:00Z')

$pinLines = @(
    "2026-11-09T10:00:00Z`tPin ui 2.4.2000 in tdd (Deployments-1)"
    "2026-11-09T10:05:00Z`tPin dashboard 1.0.5 in tdd (Deployments-2)"
    "2026-11-09T17:00:00Z`tPin ui 2.4.2021 in tdd (Deployments-3)"
    "2026-11-09T17:04:00Z`tRevert pin of ui 2.4.2021 in tdd (Deployments-3 failed)"
    "2026-11-09T17:10:00Z`tPin ui 2.4.2024 in tdd (Deployments-4)"
    "2026-11-09T17:20:00Z`tRecord the database schema of tdd after ui 2.4.2024 (Deployments-4)"
)
$pins = Read-PinEvents $pinLines 'ui'
Test-Case 'pins: only the deployable, a failed one is reverted' (@($pins | ForEach-Object { "$($_.version) $($_.deployment) $($_.reverted)" })) @('2.4.2000 Deployments-1 False', '2.4.2021 Deployments-3 True', '2.4.2024 Deployments-4 False')
$pinPoints = Get-PinPoints $pins 'tdd' @{ '2.4.2021' = 'c2'; '2.4.2024' = 'c3' }
Test-Case 'pin points: not the failed one, not one of unknown commit' (@($pinPoints | ForEach-Object { "$($_.version)/$($_.sha)@$(Format-Moment $_.at)" })) @('2.4.2024/c3@2026-11-09T17:10:00Z')
Test-Case 'pin points: another environment has none' (Get-PinPoints $pins 'uat' @{ '2.4.2024' = 'c3' }).Count 0

# A linear history c1 <- c2 <- c3 <- c4, and m2 merged between c1 and c2 (c2's parent).
$parents = @{ c1 = @(); m2 = @('c1'); c2 = @('m2'); c3 = @('c2'); c4 = @('c3') }
$fakeRevList = {
    param([string] $Sha, [string[]] $Earlier)
    if (-not $parents.ContainsKey($Sha)) { return @{ Known = $false; Commits = @() } }
    function Reach([string] $s, $set) { if ($set.Add($s)) { foreach ($p in $parents[$s]) { Reach $p $set } } }
    $reach = [Collections.Generic.HashSet[string]]::new(); Reach $Sha $reach
    $not = [Collections.Generic.HashSet[string]]::new(); foreach ($e in $Earlier) { Reach $e $not }
    @{ Known = $true; Commits = @($reach | Where-Object { -not $not.Contains($_) }) }
}
$points = @(
    [ordered] @{ version = '2.4.1'; sha = 'c1'; at = (ConvertTo-Moment '2026-11-01T00:00:00Z') }
    [ordered] @{ version = '2.4.9'; sha = 'gone'; at = (ConvertTo-Moment '2026-11-01T12:00:00Z') }
    [ordered] @{ version = '2.4.3'; sha = 'c3'; at = (ConvertTo-Moment '2026-11-02T00:00:00Z') }
    [ordered] @{ version = '2.4.2'; sha = 'c2'; at = (ConvertTo-Moment '2026-11-03T00:00:00Z') }
    [ordered] @{ version = '2.4.4'; sha = 'c4'; at = (ConvertTo-Moment '2026-11-04T00:00:00Z') }
)
$first = Get-FirstContaining $points $fakeRevList
Test-Case 'first containing: a merge commit is in the first later point that contains it' (@('c1', 'm2', 'c2', 'c3', 'c4') | ForEach-Object { "$_=$($first[$_].version)" }) @('c1=2.4.1', 'm2=2.4.3', 'c2=2.4.3', 'c3=2.4.3', 'c4=2.4.4')
Test-Case 'first containing: a commit not in the clone is passed over' $first.ContainsKey('gone') $false

# Stats
Test-Case 'percentile: median and p85, linear' @((Get-Percentile @(1, 2, 3, 4) 0.5), (Get-Percentile @(1..21) 0.85), (Get-Percentile @(10, 20) 0.85), (Get-Percentile @() 0.5)) @(2.5, 18.0, 18.5, $null)
Test-Case 'week starts Monday (UTC)' (Get-WeekStart (ConvertTo-Moment '2026-11-09T22:00:00Z')).ToString('yyyy-MM-dd') '2026-11-09'
Test-Case 'week of a Sunday starts the Monday before' (Get-WeekStart (ConvertTo-Moment '2026-11-08T23:59:00Z')).ToString('yyyy-MM-dd') '2026-11-02'
$cycleHistory = Optimize-History @(
    [ordered] @{ column = 'Todo'; enteredAt = (ConvertTo-Moment '2026-11-01T00:00:00Z') }
    [ordered] @{ column = 'In Progress'; enteredAt = (ConvertTo-Moment '2026-11-01T02:00:00Z') }
    [ordered] @{ column = 'Done'; enteredAt = (ConvertTo-Moment '2026-11-01T12:00:00Z') })
Test-Case 'cycle time: first column after Todo to Done' (Get-CycleTime $cycleHistory) 10.0
Test-Case 'cycle time: none without Done' (Get-CycleTime @($cycleHistory[0], $cycleHistory[1])) $null

$now = ConvertTo-Moment '2026-11-09T22:00:00Z'
function New-Item([int] $Number, [string] $Column, $History, $MergedAt, $ProdAt, [int] $Ft = 0, [int] $Reverts = 0) {
    [ordered] @{ number = $Number; column = $Column; createdAt = (ConvertTo-Moment '2026-11-01T00:00:00Z'); columnHistory = $History
        mergedAt = (ConvertTo-Moment $MergedAt); ftFailures = $Ft; reverts = $Reverts
        environments = [ordered] @{ tdd = $null; uat = $null; prod = if ($ProdAt) { [ordered] @{ version = '2.4.9'; deployedAt = (ConvertTo-Moment $ProdAt) } } else { $null } } }
}
$items = @(
    (New-Item 1 'Done' $cycleHistory '2026-11-01T11:00:00Z' '2026-11-03T00:00:00Z')
    (New-Item 2 'Development' @() $null $null 1)
    (New-Item 3 'Release Queue' @() '2026-11-05T00:00:00Z' $null 0 1)
    (New-Item 4 'Todo' @() $null $null)
)
$stats = Get-WorkItemStats $items $now 28 2
Test-Case 'stats: WIP per column, Done left out' $stats.wipByColumn ([ordered] @{ Todo = 1; 'In Progress' = 0; 'Technical Design' = 0; Development = 1; 'Functional Testing' = 0; 'Release Queue' = 1 })
Test-Case 'stats: cycle and lead time' @($stats.cycleTimeHours, $stats.leadTimeHours) @([ordered] @{ median = 10.0; p85 = 10.0; n = 1 }, [ordered] @{ median = 48.0; p85 = 48.0; n = 1 })
Test-Case 'stats: per week, the current one last' $stats.perWeek @([ordered] @{ weekStart = '2026-11-02'; merged = 1; deployedProd = 1 }, [ordered] @{ weekStart = '2026-11-09'; merged = 0; deployedProd = 0 })
Test-Case 'stats: rework over the tested items' $stats.rework ([ordered] @{ ftFailures = 1; reverts = 1; reworkedItems = 2; testedItems = 3; rate = 0.667 })
Test-Case 'stats: cost is null with a note' @($stats.cost.totalUsd, [bool] $stats.cost.note) @($null, $true)

# A whole item: derived columns, release, environments
$parentsContext = @{
    ProjectNumber = 679; ProjectReadable = $false; Environments = @('tdd', 'uat', 'prod'); RepositoryUrl = 'https://github.com/o/r'; Reverted = @()
    FirstRelease = @{ m2 = [ordered] @{ version = '2.4.3'; createdAt = (ConvertTo-Moment '2026-11-02T00:00:00Z') } }
    FirstPin = @{ tdd = @{ m2 = [ordered] @{ version = '2.4.3'; at = (ConvertTo-Moment '2026-11-02T01:00:00Z') } }; uat = @{ m2 = [ordered] @{ version = '2.4.4'; at = (ConvertTo-Moment '2026-11-04T01:00:00Z') } }; prod = @{} }
    Running = @{ tdd = @{ Version = '2.4.4'; Commits = [Collections.Generic.HashSet[string]]::new([string[]] @('c1', 'm2', 'c2', 'c3', 'c4')) }; uat = @{ Version = '2.4.1'; Commits = [Collections.Generic.HashSet[string]]::new([string[]] @('c1')) }; prod = @{ Version = '2.4.1'; Commits = [Collections.Generic.HashSet[string]]::new([string[]] @('c1')) } }
}
$issue = @{ number = 77; title = 'T'; url = 'https://github.com/o/r/issues/77'; state = 'CLOSED'; createdAt = '2026-11-01T00:00:00Z'; closedAt = '2026-11-01T05:00:00Z'; body = ''
    assignees = @{ nodes = @(@{ login = 'cm-ai-ops-bot' }) }; labels = @{ nodes = @() }; timelineItems = @{ nodes = @() }; projectItems = @{ nodes = @() }
    comments = @{ nodes = @((New-Comment 'cm-ai-ops-bot' '2026-11-01T01:00:00Z' 'Todo → In Progress [agent](https://cursor.com/agents/bc-9)'), (New-Comment 'cm-ai-ops-bot' '2026-11-01T04:59:00Z' 'Functional Testing → Release Queue: merged')) } }
$prs = @(@{ number = 78; url = 'https://github.com/o/r/pull/78'; state = 'MERGED'; mergedAt = '2026-11-01T04:58:00Z'; mergeCommit = @{ oid = 'm2' }; author = @{ login = 'cm-ai-ops-bot' }; body = ''; comments = @{ nodes = @() } })
$item = Build-WorkItem $issue $prs $parentsContext
Test-Case 'item: column from the journal; closed is not Done before prod' @($item.column, $item.agent, $item.assignee) @('Release Queue', 'cm-ai-ops-bot', 'cm-ai-ops-bot')
Test-Case 'item: release candidate and environments (uat runs an older commit: not reached)' (ConvertTo-Published @($item.releaseCandidate, $item.environments)) (ConvertTo-Published @([ordered] @{ version = '2.4.3'; createdAt = '2026-11-02T00:00:00Z' }, [ordered] @{ tdd = [ordered] @{ version = '2.4.3'; deployedAt = '2026-11-02T01:00:00Z' }; uat = $null; prod = $null }))
Test-Case 'item: pull request, its checks, and session' (ConvertTo-Published @($item.prs[0], $item.cursorSessions)) (ConvertTo-Published @([ordered] @{ number = 78; url = 'https://github.com/o/r/pull/78'; state = 'merged'; mergedAt = '2026-11-01T04:58:00Z'; mergeSha = 'm2'; checks = $null }, @('https://cursor.com/agents/bc-9')))
Test-Case 'bot item: hours in each column, and the latest status comment' (ConvertTo-Published @($item.worker, $item.columnHistory[0].hours, $item.columnHistory[-1].leftAt, $item.latestStatusComment.kind)) @('bot', 4.0, $null, 'status')
$parentsContext.Running.prod = @{ Version = '2.4.4'; Commits = [Collections.Generic.HashSet[string]]::new([string[]] @('m2')) }
$parentsContext.FirstPin.prod = @{ m2 = [ordered] @{ version = '2.4.4'; at = (ConvertTo-Moment '2026-11-05T00:00:00Z') } }
$inProd = Build-WorkItem $issue $prs $parentsContext
Test-Case 'item: a derived Release Queue item running in prod is Done at that deployment' @($inProd.column, (Format-Moment $inProd.columnHistory[-1].enteredAt)) @('Done', '2026-11-05T00:00:00Z')
$abandoned = @{} + $issue
$abandoned.comments = @{ nodes = @((New-Comment 'cm-ai-ops-bot' '2026-11-01T01:00:00Z' 'Todo → In Progress')) }
Test-Case 'item: closed before Release Queue is Done when closed' ((Build-WorkItem $abandoned @() $parentsContext).column) 'Done'
$person = @{} + $issue
$person.assignees = @{ nodes = @() }
$personItem = Build-WorkItem $person @() $parentsContext
Test-Case 'item: a person''s issue is kept, as team, without the bot detail' @($personItem.worker, ($personItem.columnHistory[0].Keys -contains 'hours'), $personItem.Contains('latestStatusComment')) @('team', $false, $false)
$parentsContext.ProjectReadable = $true
$onBoard = @{} + $issue
$onBoard.projectItems = @{ nodes = @(@{ project = @{ number = 679 }; fieldValueByName = @{ name = 'Functional Testing' } }) }
$boardItem = Build-WorkItem $onBoard $prs $parentsContext
Test-Case 'item: the project Status wins when readable' @($boardItem.column, $boardItem.columnSource) @('Functional Testing', 'project')
Test-Case 'item: not on the board, derived though the project is readable' ((Build-WorkItem $issue $prs $parentsContext).columnSource) 'derived'

Test-Case 'window: open kept, old closed dropped, recently deployed kept' @(
    (Test-InWindow ([ordered] @{ state = 'open'; closedAt = $null; mergedAt = $null; environments = @{} }) $now)
    (Test-InWindow ([ordered] @{ state = 'closed'; closedAt = $now.AddDays(-90); mergedAt = $now.AddDays(-90); environments = @{ prod = $null } }) $now.AddDays(-56))
    (Test-InWindow ([ordered] @{ state = 'closed'; closedAt = $now.AddDays(-90); mergedAt = $now.AddDays(-90); environments = @{ prod = @{ deployedAt = $now.AddDays(-1) } } }) $now.AddDays(-56))
) @($true, $false, $true)

$span = Add-ColumnSpan @(
    [ordered] @{ column = 'Development'; enteredAt = (ConvertTo-Moment '2026-11-01T00:00:00Z') }
    [ordered] @{ column = 'Done'; enteredAt = (ConvertTo-Moment '2026-11-01T01:30:00Z') }
) (ConvertTo-Moment '2026-11-01T02:00:00Z')
Test-Case 'column span: leftAt is the next entry, the current column is open, hours to one decimal' (ConvertTo-Published @($span | ForEach-Object { "$($_.column) $(Format-Moment $_.leftAt) $($_.hours)" })) @('Development 2026-11-01T01:30:00Z 1.5', 'Done  0.5')

Test-Case 'checks: the rollup of the latest commit, lower case' (Get-ChecksConclusion @{ commits = @{ nodes = @(@{ commit = @{ statusCheckRollup = @{ state = 'SUCCESS' } } }) } }) 'success'
Test-Case 'checks: none when the rollup was not read' (Get-ChecksConclusion @{}) $null

$noted = @(
    (New-Comment 'cm-ai-ops-bot' '2026-11-01T01:00:00Z' 'Journal: Todo → In Progress')
    (New-Comment 'cm-ai-ops-bot' '2026-11-01T03:00:00Z' 'Blocker (board only): the project token is refused.')
)
$noted[0].url = 'https://github.com/o/r/issues/1#issuecomment-1'
$noted[1].url = 'https://github.com/o/r/issues/1#issuecomment-2'
Test-Case 'latest status comment: the newer blocker wins' (ConvertTo-Published (Get-LatestStatusComment $noted)) (ConvertTo-Published ([ordered] @{ url = 'https://github.com/o/r/issues/1#issuecomment-2'; at = '2026-11-01T03:00:00Z'; kind = 'blocker' }))

$flowItems = @(
    ([ordered] @{ worker = 'bot'; agent = 'cm-ai-ops-bot'; column = 'Done'; mergedAt = (ConvertTo-Moment '2026-11-01T11:00:00Z'); ftFailures = 0; reverts = 0; createdAt = (ConvertTo-Moment '2026-11-01T00:00:00Z'); mergeToProdHours = 5.0
        columnHistory = @([ordered] @{ column = 'In Progress'; enteredAt = (ConvertTo-Moment '2026-11-01T02:00:00Z'); hours = 2.0 }, [ordered] @{ column = 'Done'; enteredAt = (ConvertTo-Moment '2026-11-01T12:00:00Z'); hours = 1.0 })
        environments = [ordered] @{ prod = [ordered] @{ deployedAt = (ConvertTo-Moment '2026-11-03T00:00:00Z') } } })
    ([ordered] @{ worker = 'team'; agent = 'jeffreypalermo'; column = 'Todo'; mergedAt = $null; ftFailures = 0; reverts = 0; createdAt = (ConvertTo-Moment '2026-11-01T00:00:00Z'); mergeToProdHours = $null; columnHistory = @(); environments = [ordered] @{ prod = $null } })
)
$grouped = Get-GroupedStats $flowItems $now 28 2
Test-Case 'stats: the top level is stats.all' @($grouped.wipByColumn.Todo, $grouped.all.wipByColumn.Todo, $grouped.team.wipByColumn.Todo, $grouped.bot.wipByColumn.Todo) @(1, 1, 1, 0)
Test-Case 'stats.bot: hours per column, throughput, merge to prod' (ConvertTo-Published @($grouped.bot.hoursByColumn, $grouped.bot.throughputByAgent, $grouped.bot.mergeToProdHours)) (ConvertTo-Published @([ordered] @{ 'In Progress' = 2.0; Done = 1.0 }, [ordered] @{ 'cm-ai-ops-bot' = 1 }, [ordered] @{ median = 5.0; p85 = 5.0; n = 1 }))
Test-Case 'cost note says none is connected' $grouped.cost.note 'No cost source is connected yet.'

if ($failures -gt 0) { Write-Host "$failures FAIL"; exit 1 }
Write-Host 'All cases pass.'
