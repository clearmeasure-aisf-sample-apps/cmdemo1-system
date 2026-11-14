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
$PSNativeCommandUseErrorActionPreference = $true
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
$systemRepo = 'clearmeasure-aisf-sample-apps/cmdemo1-system'
$workordersRepo = 'clearmeasure-aisf-sample-apps/cmdemo1-workorders'

function New-BotPull([string] $ConclusionLabel = 'green') {
    [ordered] @{
        number         = 600
        state          = 'OPEN'
        body           = 'Closes #585'
        author         = 'cm-ai-ops-bot'
        headCommitDate = $headDate
    }
}

function New-IssueFacts([int] $Number = 585, [string] $Repository = 'clearmeasure-aisf-sample-apps/cmdemo1-system', [object[]] $Assigned = @(), [object[]] $Comments = @()) {
    [ordered] @{
        number         = $Number
        repository     = $Repository
        assignedEvents = @($Assigned)
        comments       = @($Comments)
    }
}

function New-ClosingRef([int] $Number, [string] $Repository) {
    [ordered] @{ number = $Number; repository = $Repository }
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

# --- Closing issues (number + repository) ---
$fromGraphql = @(Get-ClosingIssues -ClosingReferences @((New-ClosingRef 585 $systemRepo), (New-ClosingRef 590 $systemRepo)) -Body 'Closes #1' -DefaultRepository $systemRepo)
Test-Case 'closes: GraphQL references win' @($fromGraphql | ForEach-Object { "$($_.repository)#$($_.number)" }) @("$systemRepo#585", "$systemRepo#590")
$fromBody = @(Get-ClosingIssues -ClosingReferences @() -Body "See notes.`nCloses #585`n" -DefaultRepository $systemRepo)
Test-Case 'closes: body Closes #N when GraphQL is empty' @($fromBody | ForEach-Object { "$($_.repository)#$($_.number)" }) @("$systemRepo#585")
$fromCrossBody = @(Get-ClosingIssues -ClosingReferences @() -Body "Closes $workordersRepo#1657" -DefaultRepository $systemRepo)
Test-Case 'closes: body Closes owner/name#N is cross-repo' @($fromCrossBody | ForEach-Object { "$($_.repository)#$($_.number)" }) @("$workordersRepo#1657")
Test-Case 'closes: Fixes #N alone is not enough (Closes only)' `
    @(Get-ClosingIssues -ClosingReferences @() -Body 'Fixes #12' -DefaultRepository $systemRepo | ForEach-Object { "$($_.repository)#$($_.number)" }) `
    @()
Test-Case 'closes: none' `
    @(Get-ClosingIssues -ClosingReferences @() -Body 'no link' -DefaultRepository $systemRepo | ForEach-Object { "$($_.repository)#$($_.number)" }) `
    @()
$crossRef = @(Get-ClosingIssues -ClosingReferences @((New-ClosingRef 1657 $workordersRepo)) -Body '' -DefaultRepository $systemRepo)
Test-Case 'closes: GraphQL cross-repo reference keeps its repository' @($crossRef | ForEach-Object { "$($_.repository)#$($_.number)" }) @("$workordersRepo#1657")

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
$passNotMerged = @([ordered] @{ body = "Review: PASS, not merged`nheld for Jeffrey"; createdAt = $headDate.AddMinutes(2) })
Test-Case 'verdict: Review: PASS, not merged after head' (Test-ReviewVerdictAfterHead -Comments $passNotMerged -HeadCommitDate $headDate) $true

# --- Full plans: bot green, bot red, non-bot, default branch, 10-minute dedupe ---
$botGreen = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 585 $systemRepo)) `
    -Issues @((New-IssueFacts)) -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: bot PR green nudges linked issue' @($botGreen.Action, $botGreen.Issues[0].Action) @('nudge', 'nudge')

$botRed = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'failure' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull 'red') -ClosingReferences @((New-ClosingRef 585 $systemRepo)) `
    -Issues @((New-IssueFacts)) -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: bot PR red also nudges' @($botRed.Action, $botRed.Issues[0].Action) @('nudge', 'nudge')

$nonBot = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'person/feature' -DefaultBranch 'main' `
    -PullRequest ([ordered] @{ number = 2; state = 'OPEN'; body = 'Closes #10'; author = 'jeffreypalermo'; headCommitDate = $headDate }) `
    -ClosingReferences @((New-ClosingRef 10 $systemRepo)) -Issues @((New-IssueFacts 10)) `
    -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: non-bot PR skips without touching issues' @($nonBot.Action, @($nonBot.Issues).Count) @('skip', 0)

$onDefault = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'main' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 585 $systemRepo)) `
    -Issues @((New-IssueFacts)) -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: default-branch run skips without touching issues' @($onDefault.Action, @($onDefault.Issues).Count) @('skip', 0)

$ciFinishedRecent = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 585 $systemRepo)) `
    -Issues @((New-IssueFacts -Assigned $recent)) -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: CI finished ignores 10-minute assign debounce' `
    @($ciFinishedRecent.Action, $ciFinishedRecent.Issues[0].Action, $ciFinishedRecent.Issues[0].Reason) `
    @('nudge', 'nudge', "re-assign cm-ai-ops-bot on ${systemRepo}#585 (CI finished)")

$afterVerdict = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 585 $systemRepo)) `
    -Issues @((New-IssueFacts -Comments $verdictAfter)) -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: existing Review verdict after head skips' @($afterVerdict.Action, $afterVerdict.Issues[0].Action) @('skip', 'skip')

$afterPassHeld = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 585 $systemRepo)) `
    -Issues @((New-IssueFacts -Assigned $recent -Comments $passNotMerged)) -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: Review: PASS, not merged after head skips even with recent assign' `
    @($afterPassHeld.Action, $afterPassHeld.Issues[0].Action) @('skip', 'skip')

# Direct decision: non-CI wake reason still honors the assign debounce.
$nonCiDedupe = Get-IssueNudgeDecision `
    -IssueNumber 585 -Repository $systemRepo -AssignedEvents $recent -Comments @() -HeadCommitDate $headDate `
    -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10 -WakeReason 'manual'
Test-Case 'decision: non-CI wake reason still applies 10-minute assign debounce' `
    @($nonCiDedupe.Action, $nonCiDedupe.Reason) `
    @('skip', "cm-ai-ops-bot was assigned on ${systemRepo}#585 within the last 10 minutes")

$bodyFallback = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @() `
    -Issues @((New-IssueFacts)) -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: body Closes #N is used when GraphQL refs are empty' @($bodyFallback.Action, $bodyFallback.Issues[0].Issue) @('nudge', 585)

# --- Issue #649: GraphQL NOT_FOUND vs unexpected errors; cross-repo / missing skip; same-repo nudge ---
Test-Case 'graphql: only NOT_FOUND is treated as not-found' `
    (Test-GhGraphqlNotFoundOnly ([ordered] @{
            data   = [ordered] @{ repository = [ordered] @{ issue = $null } }
            errors = @([ordered] @{ type = 'NOT_FOUND'; path = @('repository', 'issue') })
        })) `
    $true
Test-Case 'graphql: FORBIDDEN is not treated as not-found' `
    (Test-GhGraphqlNotFoundOnly ([ordered] @{
            data   = [ordered] @{ repository = $null }
            errors = @([ordered] @{ type = 'FORBIDDEN'; path = @('repository') })
        })) `
    $false
Test-Case 'graphql: INSUFFICIENT_SCOPES is not treated as not-found' `
    (Test-GhGraphqlNotFoundOnly ([ordered] @{
            data   = [ordered] @{ repository = [ordered] @{ issue = $null } }
            errors = @([ordered] @{ type = 'INSUFFICIENT_SCOPES' })
        })) `
    $false
Test-Case 'graphql: mixed NOT_FOUND and FORBIDDEN is not treated as not-found' `
    (Test-GhGraphqlNotFoundOnly ([ordered] @{
            errors = @(
                [ordered] @{ type = 'NOT_FOUND' },
                [ordered] @{ type = 'FORBIDDEN' }
            )
        })) `
    $false
Test-Case 'graphql: empty errors is not treated as not-found' `
    (Test-GhGraphqlNotFoundOnly ([ordered] @{ data = [ordered] @{ repository = $null }; errors = @() })) `
    $false
Test-Case 'graphql: null parse is not treated as not-found' (Test-GhGraphqlNotFoundOnly $null) $false

$missingCross = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/retry-dotnet-sdk-download' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 1657 $workordersRepo)) `
    -Issues @() -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: missing cross-repo issue is skipped (#649)' `
    @($missingCross.Action, $missingCross.Issues[0].Action, $missingCross.Issues[0].Repository, $missingCross.Issues[0].Reason) `
    @('skip', 'skip', $workordersRepo, "issue ${workordersRepo}#1657 was not found")

$sameRepoNudge = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/factory-wake' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 585 $systemRepo)) `
    -Issues @((New-IssueFacts -Number 585 -Repository $systemRepo)) `
    -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: same-repo linked issue is nudged in its repository (#649)' `
    @($sameRepoNudge.Action, $sameRepoNudge.Issues[0].Action, $sameRepoNudge.Issues[0].Repository, $sameRepoNudge.Issues[0].Issue) `
    @('nudge', 'nudge', $systemRepo, 585)

$crossRepoNudge = Get-FactoryWakePlan `
    -Event 'pull_request' -Conclusion 'success' -HeadBranch 'cm-ai-ops-bot/retry-dotnet-sdk-download' -DefaultBranch 'main' `
    -PullRequest (New-BotPull) -ClosingReferences @((New-ClosingRef 1657 $workordersRepo)) `
    -Issues @((New-IssueFacts -Number 1657 -Repository $workordersRepo)) `
    -DefaultRepository $systemRepo -BotLogin 'cm-ai-ops-bot' -Now $now -DedupeMinutes 10
Test-Case 'plan: cross-repo linked issue is nudged in its actual repository (#649)' `
    @($crossRepoNudge.Action, $crossRepoNudge.Issues[0].Action, $crossRepoNudge.Issues[0].Repository, $crossRepoNudge.Issues[0].Issue) `
    @('nudge', 'nudge', $workordersRepo, 1657)

# --- Invoke-GhApi error classification (#649 review): mock gh stdout/stderr + exit code ---
function Invoke-WithMockGh {
    param(
        [int] $ExitCode,
        [string] $Stdout = '',
        [string] $Stderr = '',
        [scriptblock] $Script
    )
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('mock-gh-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $ghPath = Join-Path $dir 'gh'
    @'
#!/usr/bin/env bash
if [ -n "${MOCK_GH_STDOUT+x}" ]; then printf '%s' "$MOCK_GH_STDOUT"; fi
if [ -n "${MOCK_GH_STDERR+x}" ]; then printf '%s' "$MOCK_GH_STDERR" >&2; fi
exit "${MOCK_GH_EXIT:-0}"
'@ | Set-Content -LiteralPath $ghPath -Encoding utf8NoBOM
    & chmod +x $ghPath
    $oldPath = $env:PATH
    $env:PATH = "$dir$([IO.Path]::PathSeparator)$oldPath"
    $env:MOCK_GH_STDOUT = $Stdout
    $env:MOCK_GH_STDERR = $Stderr
    $env:MOCK_GH_EXIT = "$ExitCode"
    try {
        & $Script
    }
    finally {
        $env:PATH = $oldPath
        Remove-Item Env:\MOCK_GH_STDOUT, Env:\MOCK_GH_STDERR, Env:\MOCK_GH_EXIT -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$notFoundOnlyJson = '{"data":{"repository":{"issue":null}},"errors":[{"type":"NOT_FOUND","path":["repository","issue"],"message":"Could not resolve to an Issue with the number of 1657."}]}'
$notFoundResult = Invoke-WithMockGh -ExitCode 1 -Stdout $notFoundOnlyJson -Stderr 'gh: GraphQL: Could not resolve to an Issue with the number of 1657.' -Script {
    Invoke-GhApi graphql -f 'query=q'
}
Test-Case 'gh: NOT_FOUND only returns payload for skip' `
    @([string] $notFoundResult.errors[0].type, ($null -eq $notFoundResult.data.repository.issue)) `
    @('NOT_FOUND', $true)

$forbiddenJson = '{"data":{"repository":null},"errors":[{"type":"FORBIDDEN","path":["repository"],"message":"Resource not accessible by integration"}]}'
$forbiddenThrew = $false
try {
    Invoke-WithMockGh -ExitCode 1 -Stdout $forbiddenJson -Stderr 'gh: GraphQL: Resource not accessible by integration' -Script {
        Invoke-GhApi graphql -f 'query=q'
    } | Out-Null
}
catch { $forbiddenThrew = $true }
Test-Case 'gh: FORBIDDEN with data throws' $forbiddenThrew $true

$mixedJson = '{"data":{"repository":{"issue":null}},"errors":[{"type":"NOT_FOUND","message":"missing issue"},{"type":"FORBIDDEN","message":"no access"}]}'
$mixedThrew = $false
try {
    Invoke-WithMockGh -ExitCode 1 -Stdout $mixedJson -Stderr 'gh: GraphQL: mixed errors' -Script {
        Invoke-GhApi graphql -f 'query=q'
    } | Out-Null
}
catch { $mixedThrew = $true }
Test-Case 'gh: NOT_FOUND mixed with FORBIDDEN throws' $mixedThrew $true

$noDataThrew = $false
try {
    Invoke-WithMockGh -ExitCode 1 -Stdout '{"errors":[{"type":"INSUFFICIENT_SCOPES","message":"token lacks scope"}]}' -Stderr 'gh: API error' -Script {
        Invoke-GhApi graphql -f 'query=q'
    } | Out-Null
}
catch { $noDataThrew = $true }
Test-Case 'gh: non-zero with no skippable not-found (no data) throws' $noDataThrew $true

$rest404Json = '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/issues/issues#get-an-issue","status":"404"}'
$rest404Result = Invoke-WithMockGh -ExitCode 1 -Stdout $rest404Json -Stderr 'gh: Not Found (HTTP 404)' -Script {
    Invoke-GhApi --method DELETE 'repos/o/r/issues/1/assignees' -f 'assignees[]=bot'
}
Test-Case 'gh: REST HTTP 404 returns payload for skip' ([string] $rest404Result.status) '404'

if ($failures -gt 0) {
    Write-Host "$failures FAIL(s)"
    exit 1
}
Write-Host 'All factory-wake tests passed.'
# Nested mock-gh exits leave LASTEXITCODE non-zero; Actions' pwsh shell would fail the step without this.
$global:LASTEXITCODE = 0
exit 0
