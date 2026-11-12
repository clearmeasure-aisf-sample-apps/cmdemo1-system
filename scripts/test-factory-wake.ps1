#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the decision rules of factory-wake.ps1 (pure functions, no network). PASS or FAIL per case; exit 1 on a FAIL.
.EXAMPLE
    pwsh -NoProfile -File scripts/test-factory-wake.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-wake.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $a = ConvertTo-Json -InputObject @($Actual | ForEach-Object { $_ }) -Compress -Depth 8
    $e = ConvertTo-Json -InputObject @($Expected | ForEach-Object { $_ }) -Compress -Depth 8
    if ($a -ceq $e) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $e, got $a"; $script:failures++ }
}

$now = [datetime]::Parse('2026-11-12T18:00:00Z').ToUniversalTime()
$headDate = [datetime]::Parse('2026-11-12T17:30:00Z').ToUniversalTime()

function New-BotPull([string] $ConclusionLabel = 'green') {
    [ordered] @{
        number         = 600
        state          = 'OPEN'
        body           = 'Closes #585'
        author         = 'cm-ai-ops-bot'
        headCommitDate = $headDate
    }
}

function New-IssueFacts([int] $Number = 585, [object[]] $Assigned = @(), [object[]] $Comments = @()) {
    [ordered] @{
        number         = $Number
        assignedEvents = @($Assigned)
        comments       = @($Comments)
    }
}

# --- Run gate ---
Test-Case 'run: pull_request success on a feature branch is considered' `
    ((Get-RunGate -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main').Action) `
    'consider'
Test-Case 'run: pull_request failure on a feature branch is considered' `
    ((Get-RunGate -Event 'pull_request' -Conclusion 'failure' -HeadBranch 'cm-ai-ops-bot/x' -DefaultBranch 'main').Action) `
    'consider'
Test-Case 'run: default-branch head is skipped' `
    ((Get-RunGate -Event 'pull_request' -Conclusion 'success' -HeadBranch 'main' -DefaultBranch 'main').Action) `
    'skip'
Test-Case 'run: non-pull_request event is skipped' `
    ((Get-RunGate -Event 'push' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/x' -DefaultBranch 'main').Action) `
    'skip'
Test-Case 'run: cancelled conclusion is skipped' `
    ((Get-RunGate -Event 'pull_request' -Conclusion 'cancelled' -HeadBranch 'cm-ai-ops-bot/x' -DefaultBranch 'main').Action) `
    'skip'

# --- Pull request gate ---
Test-Case 'pr: open bot PR is considered' `
    ((Get-PullRequestGate -PullRequest (New-BotPull) -BotLogin 'cm-ai-ops-bot').Action) `
    'consider'
Test-Case 'pr: non-bot author is skipped' `
    ((Get-PullRequestGate -PullRequest ([ordered] @{ number = 1; state = 'OPEN'; author = 'jeffreypalermo'; body = 'Closes #1'; headCommitDate = $headDate }) -BotLogin 'cm-ai-ops-bot').Action) `
    'skip'
Test-Case 'pr: closed bot PR is skipped' `
    ((Get-PullRequestGate -PullRequest ([ordered] @{ number = 1; state = 'CLOSED'; author = 'cm-ai-ops-bot'; body = ''; headCommitDate = $headDate }) -BotLogin 'cm-ai-ops-bot').Action) `
    'skip'
Test-Case 'pr: missing pull request is skipped' `
    ((Get-PullRequestGate -PullRequest $null -BotLogin 'cm-ai-ops-bot').Action) `
    'skip'

# --- Closing issue numbers ---
Test-Case 'closes: GraphQL references win' `
    @(Get-ClosingIssueNumbers -ClosingReferences @(585, 590) -Body 'Closes #1') `
    @(585, 590)
Test-Case 'closes: body Closes #N when GraphQL is empty' `
    @(Get-ClosingIssueNumbers -ClosingReferences @() -Body "See notes.`nCloses #585`n") `
    @(585)
Test-Case 'closes: Fixes #N alone is not enough (Closes only)' `
    @(Get-ClosingIssueNumbers -ClosingReferences @() -Body 'Fixes #12') `
    @()
Test-Case 'closes: none' `
    @(Get-ClosingIssueNumbers -ClosingReferences @() -Body 'no link') `
    @()

# --- Recent assign dedupe ---
$recent = @([ordered] @{ assignee = 'cm-ai-ops-bot'; createdAt = $now.AddMinutes(-3) })
$stale = @([ordered] @{ assignee = 'cm-ai-ops-bot'; createdAt = $now.AddMinutes(-11) })
$other = @([ordered] @{ assignee = 'jeffreypalermo'; createdAt = $now.AddMinutes(-1) })
Test-Case 'dedupe: assign within 10 minutes' (Test-BotAssignedRecently -AssignedEvents $recent -BotLogin 'cm-ai-ops-bot' -Now $now -Minutes 10) $true
Test-Case 'dedupe: assign older than 10 minutes' (Test-BotAssignedRecently -AssignedEvents $stale -BotLogin 'cm-ai-ops-bot' -Now $now -Minutes 10) $false
Test-Case 'dedupe: other assignee within window does not count' (Test-BotAssignedRecently -AssignedEvents $other -BotLogin 'cm-ai-ops-bot' -Now $now -Minutes 10) $false

# --- Review verdict after head ---
$verdictAfter = @([ordered] @{ body = "Review → Merged`nmerge abc"; createdAt = $headDate.AddMinutes(5) })
$verdictBefore = @([ordered] @{ body = 'Review → Done'; createdAt = $headDate.AddMinutes(-5) })
$progressAfter = @([ordered] @{ body = 'Review → In Progress`nfix checks'; createdAt = $headDate.AddMinutes(1) })
$otherComment = @([ordered] @{ body = 'Queued: WIP is full for cmdemo1-system (2).'; createdAt = $headDate.AddMinutes(5) })
Test-Case 'verdict: Review → Merged after head' (Test-ReviewVerdictAfterHead -Comments $verdictAfter -HeadCommitDate $headDate) $true
Test-Case 'verdict: Review → Done before head does not count' (Test-ReviewVerdictAfterHead -Comments $verdictBefore -HeadCommitDate $headDate) $false
Test-Case 'verdict: Review → In Progress after head' (Test-ReviewVerdictAfterHead -Comments $progressAfter -HeadCommitDate $headDate) $true
Test-Case 'verdict: other comment after head does not count' (Test-ReviewVerdictAfterHead -Comments $otherComment -HeadCommitDate $headDate) $false

# --- Full plans: bot green, bot red, non-bot, default branch, 10-minute dedupe ---
$botGreen = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @(585) `
    -Issues @((New-IssueFacts)) -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: bot PR green nudges linked issue' @($botGreen.Action, $botGreen.Issues[0].Action) @('nudge', 'nudge')

$botRed = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'failure' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull 'red') -ClosingReferences @(585) `
    -Issues @((New-IssueFacts)) -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: bot PR red also nudges' @($botRed.Action, $botRed.Issues[0].Action) @('nudge', 'nudge')

$nonBot = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'person/feature' -DefaultBranch 'main' `
    -PullRequest ([ordered] @{ number = 2; state = 'OPEN'; body = 'Closes #10'; author = 'jeffreypalermo'; headCommitDate = $headDate }) `
    -ClosingReferences @(10) -Issues @((New-IssueFacts 10)) -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: non-bot PR skips without touching issues' @($nonBot.Action, @($nonBot.Issues).Count) @('skip', 0)

$onDefault = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'main' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @(585) `
    -Issues @((New-IssueFacts)) -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: default-branch run skips without touching issues' @($onDefault.Action, @($onDefault.Issues).Count) @('skip', 0)

$deduped = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @(585) `
    -Issues @((New-IssueFacts -Assigned $recent)) -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: 10-minute dedupe skips the nudge' @($deduped.Action, $deduped.Issues[0].Action) @('skip', 'skip')

$afterVerdict = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @(585) `
    -Issues @((New-IssueFacts -Comments $verdictAfter)) -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: existing Review verdict after head skips' @($afterVerdict.Action, $afterVerdict.Issues[0].Action) @('skip', 'skip')

$bodyFallback = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @() `
    -Issues @((New-IssueFacts)) -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: body Closes #N is used when GraphQL refs are empty' @($bodyFallback.Action, $bodyFallback.Issues[0].Issue) @('nudge', 585)

if ($failures -gt 0) {
    Write-Host "$failures FAIL(s)"
    exit 1
}
Write-Host 'All factory-wake tests passed.'
exit 0
