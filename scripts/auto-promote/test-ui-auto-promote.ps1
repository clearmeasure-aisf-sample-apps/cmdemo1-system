#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the decision rules of ui-auto-promote.ps1 (pure functions, no network). PASS or FAIL per case; exit 1 on a FAIL.
.EXAMPLE
    pwsh -NoProfile -File scripts/auto-promote/test-ui-auto-promote.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ui-auto-promote.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $a = ConvertTo-Json -InputObject @($Actual | Where-Object { $null -ne $_ }) -Compress -Depth 5; $e = ConvertTo-Json -InputObject @($Expected | Where-Object { $null -ne $_ }) -Compress -Depth 5
    if ($a -ceq $e) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $e, got $a"; $script:failures++ }
}
$t0 = [datetime]::Parse('2026-10-14T04:00:00Z').ToUniversalTime()
function New-Facts([hashtable] $Override = @{}) {
    $f = @{
        Checks = @(@{ Name = 'Build result'; State = 'success'; Url = 'u1' }, @{ Name = 'Security Scan'; State = 'skipped'; Url = 'u2' })
        PathsKnown = $true; Paths = @('src/UI/Server/Program.cs'); HoldItems = @(@{ Number = 5; Url = 'i5'; Labels = @('bug') })
        PreviousState = 'Success'; LogFindings = @(); Finished = $t0; Now = $t0.AddMinutes(12)
        HealthReads = @(@{ At = $t0.AddMinutes(3); Status = 'Healthy' }, @{ At = $t0.AddMinutes(11); Status = 'Healthy' })
        HoldUnknown = @(); HealthAddressKnown = $true; PathsReason = $null
    }
    foreach ($k in $Override.Keys) { $f[$k] = $Override[$k] }
    $f
}
function Flags($facts) { @((Get-PromotionDecision -Facts $facts).Flags | ForEach-Object Flag) }

Test-Case 'nothing flags: promote' (Get-PromotionDecision -Facts (New-Facts)).Decision 'promote'
Test-Case 'skipped check passes' (Flags (New-Facts)) @()

# Flag 1
Test-Case 'failed check flags' (Flags (New-Facts @{ Checks = @(@{ Name = 'CRAP'; State = 'failure'; Url = 'x' }) })) @('Red build or tests')
Test-Case 'pending check waits, no flag' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @(@{ Name = 'Qodana'; State = 'pending'; Url = 'x' }) })).Decision 'wait'
Test-Case 'no check at all waits' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @() })).Decision 'wait'
Test-Case 'failed and pending: hold' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @(@{ Name = 'a'; State = 'failure'; Url = '' }, @{ Name = 'b'; State = 'pending'; Url = '' }) })).Decision 'hold'
Test-Case 'cancelled run maps to failure' (ConvertTo-CheckState 'completed' 'cancelled') 'failure'
Test-Case 'in progress maps to pending' (ConvertTo-CheckState 'in_progress' '') 'pending'
Test-Case 'neutral maps to skipped' (ConvertTo-CheckState 'completed' 'neutral') 'skipped'

# Flag 2
Test-Case 'previous deployment failed flags' (Flags (New-Facts @{ PreviousState = 'Failed' })) @('Deployment or health failed')
Test-Case 'log warning flags' (Flags (New-Facts @{ LogFindings = @('04:01 Warning | x') })) @('Deployment or health failed')
Test-Case 'unhealthy read flags' (Flags (New-Facts @{ HealthReads = @(@{ At = $t0.AddMinutes(2); Status = 'Degraded' }, @{ At = $t0.AddMinutes(11); Status = 'Healthy' }) })) @('Deployment or health failed')
Test-Case 'unhealthy read before the deployment finished is ignored' (Flags (New-Facts @{ HealthReads = @(@{ At = $t0.AddMinutes(-3); Status = 'Unhealthy' }, @{ At = $t0.AddMinutes(4); Status = 'Healthy' }, @{ At = $t0.AddMinutes(11); Status = 'Healthy' }) })) @()
Test-Case 'health: only 8 minutes since finish waits' (Get-HealthVerdict $t0 $t0.AddMinutes(8) @(@{ At = $t0.AddMinutes(1); Status = 'Healthy' }, @{ At = $t0.AddMinutes(8); Status = 'Healthy' })) 'wait'
Test-Case 'health: one read waits' (Get-HealthVerdict $t0 $t0.AddMinutes(12) @(@{ At = $t0.AddMinutes(12); Status = 'Healthy' })) 'wait'
Test-Case 'health: reads 3 minutes apart wait' (Get-HealthVerdict $t0 $t0.AddMinutes(12) @(@{ At = $t0.AddMinutes(9); Status = 'Healthy' }, @{ At = $t0.AddMinutes(12); Status = 'Healthy' })) 'wait'
Test-Case 'health: two reads 5 minutes apart, last after 10 minutes: ok' (Get-HealthVerdict $t0 $t0.AddMinutes(15) @(@{ At = $t0.AddMinutes(10); Status = 'Healthy' }, @{ At = $t0.AddMinutes(15); Status = 'Healthy' })) 'ok'
Test-Case 'health: waiting is not a flag' (Get-PromotionDecision -Facts (New-Facts @{ Now = $t0.AddMinutes(6); HealthReads = @(@{ At = $t0.AddMinutes(6); Status = 'Healthy' }) })).Decision 'wait'

# Health read retry (a fake reader: $null is unreachable or timed out, a throw too)
function New-Reader([object[]] $Answers) {
    $q = [Collections.Generic.Queue[object]]::new(); foreach ($x in $Answers) { $q.Enqueue($x) }
    $calls = [ref] 0
    @{ Calls = $calls; Reader = { $calls.Value++; $x = $q.Dequeue(); if ($x -eq 'throw') { throw 'timed out' }; $x }.GetNewClosure() }
}
$pauses = [ref] 0; $noPause = { $pauses.Value++ }.GetNewClosure()
$f = New-Reader @($null, 'throw', 'Healthy')
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'health read: unreachable then Healthy records Healthy' @($r.Status, $r.Attempts, $pauses.Value) @('Healthy', 3, 2)
$pauses.Value = 0; $f = New-Reader @($null, 'throw', $null, '')
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'health read: four unreachable attempts record Unreachable' @($r.Status, $f.Calls.Value, $pauses.Value) @('Unreachable', 4, 3)
$pauses.Value = 0; $f = New-Reader @('Unhealthy', 'Healthy')
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'health read: an answered Unhealthy is not retried' @($r.Status, $f.Calls.Value, $pauses.Value) @('Unhealthy', 1, 0)
$pauses.Value = 0; $f = New-Reader @('Healthy')
Test-Case 'health read: Healthy at once' @((Invoke-HealthRead -Reader $f.Reader -Pause $noPause).Status, $pauses.Value) @('Healthy', 0)

# Flag 3
Test-Case 'workflow change flags' (Flags (New-Facts @{ Paths = @('.github/workflows/build.yml') })) @('Pipeline or infra change')
Test-Case 'Dockerfile at root flags' (Flags (New-Facts @{ Paths = @('Dockerfile') })) @('Pipeline or infra change')
Test-Case 'script outside src flags' (Flags (New-Facts @{ Paths = @('build.ps1', 'src/UI/Server/Program.cs') })) @('Pipeline or infra change')
Test-Case 'csproj in src flags' (Flags (New-Facts @{ Paths = @('src/UI/Server/Server.csproj') })) @('Pipeline or infra change')
Test-Case 'Directory.Build.props in src flags' (Flags (New-Facts @{ Paths = @('src/Directory.Build.props') })) @('Pipeline or infra change')
Test-Case 'global.json flags' (Flags (New-Facts @{ Paths = @('global.json') })) @('Pipeline or infra change')
Test-Case 'database migration does not flag' (Flags (New-Facts @{ Paths = @('src/Database/scripts/Update/033_Risks.sql') })) @()
Test-Case 'database project file does not flag' (Flags (New-Facts @{ Paths = @('src/Database/Database.csproj') })) @()
Test-Case 'kit private-build script does not flag' (Flags (New-Facts @{ Paths = @('.github/private-build/add-private-build.ps1') })) @()
Test-Case 'docs folder does not flag' (Flags (New-Facts @{ Paths = @('docs/a/b.png') })) @()
Test-Case 'arch folder does not flag' (Flags (New-Facts @{ Paths = @('arch/x.puml') })) @()
Test-Case 'root markdown does not flag' (Flags (New-Facts @{ Paths = @('CLAUDE.md') })) @()
Test-Case 'markdown in src does not flag' (Flags (New-Facts @{ Paths = @('src/UI/README.md') })) @()
Test-Case 'markdown plus a workflow flags once' (Get-PipelineEvidence -Paths @('README.md', '.github/x.yml')) @('.github/x.yml (outside src/)')
Test-Case 'application code and tests do not flag' (Flags (New-Facts @{ Paths = @('src/Core/A.cs', 'src/UnitTests/ATests.cs') })) @()
Test-Case 'no change at all does not flag' (Flags (New-Facts @{ Paths = @() })) @()
Test-Case 'unknown comparison flags' (Flags (New-Facts @{ PathsKnown = $false })) @('Pipeline or infra change')

# Flag 4
Test-Case 'Hold label flags' (Flags (New-Facts @{ HoldItems = @(@{ Number = 7; Url = 'i7'; Labels = @('Hold') }) })) @('Hold label')
Test-Case 'hold label ignores case' (Flags (New-Facts @{ HoldItems = @(@{ Number = 7; Url = 'i7'; Labels = @('hold') }) })) @('Hold label')
Test-Case 'other labels do not flag' (Flags (New-Facts @{ HoldItems = @(@{ Number = 7; Url = 'i7'; Labels = @('Holding', 'on hold') }) })) @()
Test-Case 'no items does not flag' (Flags (New-Facts @{ HoldItems = @() })) @()

# Several flags are all listed.
Test-Case 'two flags listed' (Flags (New-Facts @{ PreviousState = 'Failed'; Paths = @('Dockerfile') })) @('Deployment or health failed', 'Pipeline or infra change')


# --- Added after the pre-commit review ---
# Check states
Test-Case 'timed_out maps to failure' (ConvertTo-CheckState 'completed' 'timed_out') 'failure'
Test-Case 'action_required maps to failure' (ConvertTo-CheckState 'completed' 'action_required') 'failure'
Test-Case 'stale maps to failure' (ConvertTo-CheckState 'completed' 'stale') 'failure'
Test-Case 'completed without conclusion maps to failure' (ConvertTo-CheckState 'completed' $null) 'failure'
Test-Case 'null status and conclusion map to pending' (ConvertTo-CheckState $null $null) 'pending'
Test-Case 'status pending is pending' (ConvertTo-StatusState 'pending') 'pending'
Test-Case 'status failure is failure' (ConvertTo-StatusState 'failure') 'failure'
Test-Case 'status error is failure' (ConvertTo-StatusState 'error') 'failure'
Test-Case 'status success is success' (ConvertTo-StatusState 'success') 'success'
Test-Case 'failed commit status flags' (Flags (New-Facts @{ Checks = @(@{ Name = 'ci/x'; State = (ConvertTo-StatusState 'error'); Url = '' }) })) @('Red build or tests')
Test-Case 'pending commit status waits' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @(@{ Name = 'ci/x'; State = (ConvertTo-StatusState 'pending'); Url = '' }) })).Decision 'wait'
Test-Case 'wait plus flag together: hold with the wait listed' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @(@{ Name = 'a'; State = 'failure'; Url = '' }, @{ Name = 'b'; State = 'pending'; Url = '' }) })).Waiting.Count 1

# Globs
Test-Case 'docs/x.ps1 is exempt' (Get-PipelineEvidence -Paths @('docs/x.ps1')) @()
Test-Case '.github/x.md is exempt (*.md anywhere)' (Get-PipelineEvidence -Paths @('.github/x.md')) @()
Test-Case '.github/x.yml is not exempt' (Get-PipelineEvidence -Paths @('.github/x.yml')) @('.github/x.yml (outside src/)')
Test-Case 'a docs-like name outside docs/ is not exempt' (Get-PipelineEvidence -Paths @('mydocs/x.ps1')) @('mydocs/x.ps1 (outside src/)')

# Health address and hold lookup
Test-Case 'unknown health address waits with its reason' (Get-PromotionDecision -Facts (New-Facts @{ HealthAddressKnown = $false })).Waiting @('health address unknown: the address of ui in the previous environment could not be read')
Test-Case 'unknown health address does not flag' (Flags (New-Facts @{ HealthAddressKnown = $false })) @()
Test-Case 'unreadable hold lookup waits' (Get-PromotionDecision -Facts (New-Facts @{ HoldUnknown = @('#4 not read') })).Decision 'wait'
Test-Case 'incomplete comparison flags with its reason' (Get-PromotionDecision -Facts (New-Facts @{ PathsKnown = $false; PathsReason = '300 files' })).Flags[0].Evidence @('comparison incomplete: 300 files')

# Task log
$logLines = (1..30 | ForEach-Object { "12:00:0$($_ % 10)   Info     |   line $_" }) -join "`n"
$okLog = "Task ID:        ServerTasks-1`nTask status:    Success`n$logLines"
Test-Case 'clean log has no finding' (Get-LogFindings -Raw $okLog -TaskId 'ServerTasks-1') @()
Test-Case 'empty log is unreadable' (Get-LogFindings -Raw '' -TaskId 'ServerTasks-1') @('task log unreadable')
Test-Case 'short log is unreadable' (Get-LogFindings -Raw "Task ID:        ServerTasks-1`nx" -TaskId 'ServerTasks-1') @('task log unreadable')
Test-Case 'log of another task is unreadable' (Get-LogFindings -Raw $okLog -TaskId 'ServerTasks-2') @('task log unreadable')
Test-Case 'Warning line is found' (Get-LogFindings -Raw "$okLog`n12:01:00   Warning  |   careful" -TaskId 'ServerTasks-1') @('12:01:00   Warning  |   careful')
Test-Case 'Fatal line is found (a real failed ui task logs it)' (Get-LogFindings -Raw "$okLog`n12:01:00   Fatal    |   boom" -TaskId 'ServerTasks-1') @('12:01:00   Fatal    |   boom')
Test-Case 'Error word inside a Verbose line is not a finding' (Get-LogFindings -Raw "$okLog`n12:01:00   Verbose  |   Error handling is on" -TaskId 'ServerTasks-1') @()
Test-Case 'SuccessWithWarning step is a finding' (Get-LogFindings -Raw $okLog -TaskId 'ServerTasks-1' -WarnedSteps @('Seed')) @('steps SuccessWithWarning: Seed')

# Busy detection
$busyA = @{ Kind = 'deployment'; ProjectId = 'P-other'; EnvironmentId = 'E-prod' }
Test-Case 'another project to the target blocks' ([bool] (Get-BusyReason @($busyA) 'E-prod' 'E-tdd' 'P-ui')) $true
Test-Case 'a runbook run to the target blocks' ([bool] (Get-BusyReason @(@{ Kind = 'runbook'; ProjectId = 'P-other'; EnvironmentId = 'E-uat' }) 'E-uat' 'E-tdd' 'P-ui')) $true
Test-Case 'ui in uat blocks a prod promotion' ([bool] (Get-BusyReason @(@{ Kind = 'deployment'; ProjectId = 'P-ui'; EnvironmentId = 'E-uat' }) 'E-prod' 'E-tdd' 'P-ui')) $true
Test-Case 'ui in tdd does not block' ([bool] (Get-BusyReason @(@{ Kind = 'deployment'; ProjectId = 'P-ui'; EnvironmentId = 'E-tdd' }) 'E-uat' 'E-tdd' 'P-ui')) $false
Test-Case 'another project elsewhere does not block' ([bool] (Get-BusyReason @($busyA) 'E-uat' 'E-tdd' 'P-ui')) $false
Test-Case 'nothing active does not block' ([bool] (Get-BusyReason @() 'E-uat' 'E-tdd' 'P-ui')) $false

# Candidate selection
$envs3 = @(@{ Id = 'E1'; Name = 'tdd' }, @{ Id = 'E2'; Name = 'uat' }, @{ Id = 'E3'; Name = 'prod' })
function New-Rel($id, $ver, $hour) { @{ Id = $id; Version = $ver; Assembled = "2026-10-14T0${hour}:00:00+00:00" } }
function New-Dep($rel, $env, $min, $task) { @{ Id = "D-$rel-$env-$task"; ReleaseId = $rel; EnvironmentId = $env; TaskId = $task; Created = "2026-10-14T05:$min`:00+00:00" } }
function Select-With($rels, $deps, $states) {
    Select-Candidate -Environments $envs3 -Releases $rels -GetDeployments { param($id) @($deps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState { param($d) $states[$d.TaskId] }.GetNewClosure()
}
$r1 = New-Rel 'R1' '1' 1; $r2 = New-Rel 'R2' '2' 2; $r3 = New-Rel 'R3' '3' 3
$c = Select-With @($r1, $r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '20' 't2u'), (New-Dep 'R2' 'E3' '30' 't2p')) @{ t3 = 'Success'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success' }
Test-Case 'newest in tdd goes to uat' @($c.Release.Id, $c.Target.Name) @('R3', 'uat')
$c = Select-With @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u')) @{ t3 = 'Success'; t3u = 'Success'; t2 = 'Success'; t2u = 'Success' }
Test-Case 'a release through uat goes to prod' @($c.Release.Id, $c.Target.Name) @('R3', 'prod')
# The release running in an environment: a waiting deployment of a newer one is not it (fworker 1.0.260, 2026-10-16).
$rdeps = @((New-Dep 'R3' 'E2' '20' 'w3'), (New-Dep 'R2' 'E2' '10' 's2'), (New-Dep 'R1' 'E2' '05' 's1'))
$rstates = @{ w3 = 'Queued'; s2 = 'Success'; s1 = 'Success' }
$run = Get-RunningRelease -Target $envs3[1] -Releases @($r1, $r2, $r3) -GetDeployments { param($id) @($rdeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState { param($d) $rstates[$d.TaskId] }.GetNewClosure()
Test-Case 'running release: a queued newer deployment is not running' $run.Id 'R2'
$run = Get-RunningRelease -Target $envs3[2] -Releases @($r1, $r2, $r3) -GetDeployments { param($id) @($rdeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState { param($d) $rstates[$d.TaskId] }.GetNewClosure()
Test-Case 'running release: none deployed there is none' ($null -eq $run) $true
$c = Select-With @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R3' 'E3' '30' 't3p')) @{ t3 = 'Success'; t3u = 'Success'; t3p = 'Success' }
Test-Case 'everything promoted: no candidate' $c.Release $null
$c = Select-With @($r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u')) @{ t3 = 'Success'; t3u = 'Canceled' }
Test-Case 'a canceled uat deployment is not recreated' $c.Release $null
$c = Select-With @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R2' 'E1' '05' 't2')) @{ t3 = 'Failed'; t2 = 'Success' }
Test-Case 'older release is promoted when the newest failed, and the note says so' @($c.Release.Id, $c.Notes.Count, ($c.Notes[0] -like '*3 ended Failed in tdd*')) @('R2', 1, $true)
$c = Select-With @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u'), (New-Dep 'R2' 'E3' '07' 't2p')) @{ t3 = 'Success'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success' }
Test-Case 'R3 goes to uat even though R2 is in prod' $c.Release.Id 'R3'
$c = Select-With @($r2, $r3) @((New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '11' 't3u'), (New-Dep 'R3' 'E3' '12' 't3p')) @{ t2 = 'Success'; t3 = 'Success'; t3u = 'Success'; t3p = 'Success' }
Test-Case 'a release older than the one running is not promoted' $c.Release $null
$c = Select-With @($r3, $r1, $r2) @((New-Dep 'R1' 'E1' '05' 't1')) @{ t1 = 'Success' }
Test-Case 'releases are sorted by Assembled, not by the order given' $c.Release.Id 'R1'
# Release order: version first (releases can be assembled out of order), Assembled when versions are equal.
$late = @{ Id = 'R459'; Version = '2.4.459'; Assembled = '2026-10-14T22:53:00+00:00' }
$early = @{ Id = 'R467'; Version = '2.4.467'; Assembled = '2026-10-14T22:51:00+00:00' }
Test-Case 'a higher version assembled earlier sorts first' @(Get-ReleasesNewestFirst @($late, $early) | ForEach-Object Id) @('R467', 'R459')
$c = Select-With @($late, $early) @((New-Dep 'R459' 'E1' '10' 't459'), (New-Dep 'R467' 'E1' '05' 't467')) @{ t459 = 'Success'; t467 = 'Success' }
Test-Case 'a higher version assembled earlier is the candidate' $c.Release.Id 'R467'
$c = Select-With @($late, $early) @((New-Dep 'R459' 'E1' '10' 't459'), (New-Dep 'R467' 'E1' '05' 't467'), (New-Dep 'R467' 'E2' '20' 't467u')) @{ t459 = 'Success'; t467 = 'Success'; t467u = 'Success' }
Test-Case 'a lower version assembled later is not promoted over a higher one running' $c.Release.Id 'R467'
Test-Case 'equal versions fall back to Assembled' @(Get-ReleasesNewestFirst @(@{ Id = 'A'; Version = '2.4.5'; Assembled = '2026-10-14T01:00:00Z' }, @{ Id = 'B'; Version = '2.4.5'; Assembled = '2026-10-14T02:00:00Z' }) | ForEach-Object Id) @('B', 'A')
Test-Case 'an unparsable version sorts below a parsable one, even assembled later' @(Get-ReleasesNewestFirst @(@{ Id = 'A'; Version = '2.4.9'; Assembled = '2026-10-14T01:00:00Z' }, @{ Id = 'B'; Version = 'hotfix'; Assembled = '2026-10-14T02:00:00Z' }) | ForEach-Object Id) @('A', 'B')
Test-Case 'two unparsable versions fall back to Assembled' @(Get-ReleasesNewestFirst @(@{ Id = 'A'; Version = 'hotfix-a'; Assembled = '2026-10-14T01:00:00Z' }, @{ Id = 'B'; Version = 'hotfix-b'; Assembled = '2026-10-14T02:00:00Z' }) | ForEach-Object Id) @('B', 'A')
$v10 = @{ Id = '2.4.10'; Version = '2.4.10'; Assembled = '2026-10-14T00:00:00Z' }
$v9 = @{ Id = '2.4.9'; Version = '2.4.9'; Assembled = '2026-10-14T02:00:00Z' }
$hf = @{ Id = 'hotfix'; Version = 'hotfix'; Assembled = '2026-10-14T01:00:00Z' }
foreach ($order in @(@($v10, $v9, $hf), @($hf, $v9, $v10), @($v9, $hf, $v10))) {
    Test-Case "order is total: $(@($order | ForEach-Object Id) -join ', ') sorts 2.4.10, 2.4.9, hotfix" @(Get-ReleasesNewestFirst $order | ForEach-Object Id) @('2.4.10', '2.4.9', 'hotfix')
}
Test-Case '2.4.10 is newer than 2.4.9 (numeric, not text)' ((Compare-Release @{ Version = '2.4.10'; Assembled = '2026-10-14T01:00:00Z' } @{ Version = '2.4.9'; Assembled = '2026-10-14T02:00:00Z' }) -gt 0) $true
$c = Select-With @($r3) @((New-Dep 'R3' 'E1' '10' 't3')) @{ t3 = 'Running' }
Test-Case 'a deployment still running in tdd is not a success' $c.Release $null

function Merge-Hash($a, $b) { $c = $a.Clone(); foreach ($k in $b.Keys) { $c[$k] = $b[$k] }; $c }
# Sign-off targeting
$so = @{ Type = 'ManualIntervention'; TaskId = 'T1'; Title = 'Sign-off'; IsPending = $true; ResponsibleUserId = $null; HasResponsibility = $false; Id = 'I1' }
Test-Case 'pending Sign-off is answered' (Get-SignOffAction @($so) 'T1').Action 'answer'
Test-Case 'a guided failure is never answered' (Get-SignOffAction @(@{ Type = 'GuidedFailure'; TaskId = 'T1'; Title = 'Sign-off'; IsPending = $true; ResponsibleUserId = $null; HasResponsibility = $false; Id = 'I2' }) 'T1').Action 'none'
Test-Case 'another manual step is never answered' (Get-SignOffAction @(@{ Type = 'ManualIntervention'; TaskId = 'T1'; Title = 'Approve cost'; IsPending = $true; ResponsibleUserId = $null; HasResponsibility = $false; Id = 'I3' }) 'T1').Action 'none'
Test-Case 'a Sign-off of another task is never answered' (Get-SignOffAction @($so) 'T2').Action 'none'
Test-Case 'a person holding responsibility is yielded to' (Get-SignOffAction @((Merge-Hash $so @{ ResponsibleUserId = 'Users-9'; HasResponsibility = $false })) 'T1').Action 'yield'
Test-Case 'our own responsibility is answered' (Get-SignOffAction @((Merge-Hash $so @{ ResponsibleUserId = 'Users-8'; HasResponsibility = $true })) 'T1').Action 'answer'
Test-Case 'answered Sign-off is not answered again' (Get-SignOffAction @((Merge-Hash $so @{ IsPending = $false })) 'T1').Action 'answered'

# Compare pages
function New-Page($n, $files, $total, $status = 'ahead') { @{ status = $status; total_commits = $total; files = @($files | ForEach-Object { [pscustomobject] @{ filename = $_ } }); commits = @(1..$n | ForEach-Object { [pscustomobject] @{ sha = "s$($_)p$($files.Count)$total" } }) } }
$m = Merge-ComparePages @((New-Page 3 @('src/a.cs') 3))
Test-Case 'complete comparison is known' @($m.Known, $m.Paths) @($true, @('src/a.cs'))
$m = Merge-ComparePages @((New-Page 100 @('src/a.cs') 120))
Test-Case 'half-read commits are unknown' $m.Known $false
$m = Merge-ComparePages @((New-Page 100 @('src/a.cs') 251))
Test-Case 'more than 250 commits is unknown' $m.Reason '251 commits (more than 250)'
$m = Merge-ComparePages @((New-Page 3 (1..300 | ForEach-Object { "src/f$_.cs" }) 3))
Test-Case '300 files is unknown' $m.Known $false
$page = @{ status = 'ahead'; total_commits = 1; files = @([pscustomobject] @{ filename = 'new.cs'; previous_filename = 'old.cs' }); commits = @([pscustomobject] @{ sha = 'a' }) }
Test-Case 'a rename counts both names' (Merge-ComparePages @($page)).Paths @('new.cs', 'old.cs')

# References and hold extraction
Test-Case 'plain and cross-repository references' @(Get-ReferencedNumbers 'Closes #5, org/other#7 and AB#60 in http://x/y#8' 'org/app' | ForEach-Object { "$($_.Repo)#$($_.Number)" }) @('org/app#5', 'org/other#7')
$commit = [pscustomobject] @{ sha = 'c1'; commit = [pscustomobject] @{ message = 'Change (#58) refs #16' } }
$pr = [pscustomobject] @{ number = 58; title = 't'; body = 'Closes #16'; html_url = 'pr58'; labels = @([pscustomobject] @{ name = 'Hold' }) }
$h = Get-HoldFacts -Commits @($commit) -Repo 'org/app' -GetPulls { param($s) @($pr) } -GetClosing { param($n) @(@{ Repo = 'org/app'; Number = 16 }) } -GetItem { param($r, $n) @{ Number = $n; Url = "i$n"; Labels = @('ok') } }
Test-Case 'hold facts: pull request and issue collected, nothing unknown' @($h.Items.Count, $h.Unknown.Count) @(2, 0)
Test-Case 'hold facts: the PR label is kept' (@($h.Items | Where-Object Number -eq 58)[0].Labels) @('Hold')
$h = Get-HoldFacts -Commits @($commit) -Repo 'org/app' -GetPulls { param($s) throw 'x' } -GetClosing { param($n) @() } -GetItem { param($r, $n) @{ Number = $n; Url = ''; Labels = @() } }
Test-Case 'hold facts: failed pulls read is unknown' $h.Unknown @('pull requests of c1 not read')
$h = Get-HoldFacts -Commits @($commit) -Repo 'org/app' -GetPulls { param($s) @($pr) } -GetClosing { param($n) throw 'x' } -GetItem { param($r, $n) @{ Number = $n; Url = ''; Labels = @() } }
Test-Case 'hold facts: failed closing references are unknown' $h.Unknown @('closing references of #58 not read')
$h = Get-HoldFacts -Commits @($commit) -Repo 'org/app' -GetPulls { param($s) @() } -GetClosing { param($n) @() } -GetItem { param($r, $n) throw 'gone' }
Test-Case 'hold facts: unreadable issue is unknown' $h.Unknown @('org/app#16 not read', 'org/app#58 not read')
$cross = [pscustomobject] @{ sha = 'c2'; commit = [pscustomobject] @{ message = 'see org/other#9' } }
$seen = [Collections.Generic.List[string]]::new()
$h = Get-HoldFacts -Commits @($cross) -Repo 'org/app' -GetPulls { param($s) @() } -GetClosing { param($n) @() } -GetItem { param($r, $n) $seen.Add("$r#$n"); @{ Number = $n; Url = ''; Labels = @('Hold') } }
Test-Case 'hold facts: cross-repository reference is read in its own repository' @($seen) @('org/other#9')
$many = [pscustomobject] @{ sha = 'c3'; commit = [pscustomobject] @{ message = ((1..5 | ForEach-Object { "#$_" }) -join ' ') } }
$h = Get-HoldFacts -Commits @($many) -Repo 'org/app' -GetPulls { param($s) @() } -GetClosing { param($n) @() } -GetItem { param($r, $n) @{ Number = $n; Url = ''; Labels = @() } } -Max 3
Test-Case 'hold facts: more than the cap is unknown' @($h.Items.Count, $h.Unknown.Count) @(3, 1)

# State
$tmp = Join-Path ([IO.Path]::GetTempPath()) "uap-$([guid]::NewGuid()).json"
Test-Case 'missing state file is empty' (Read-State $tmp).Count 0
'not json {' | Set-Content $tmp
Test-Case 'corrupt state file is empty' (Read-State $tmp).Count 0
'{"D-1":[{"at":"2026-10-14T05:00:00Z","status":"Healthy"}]}' | Set-Content $tmp
Test-Case 'good state file is read' (Read-State $tmp).ContainsKey('D-1') $true
Remove-Item $tmp
Test-Case 'evidence hash is stable' (Get-EvidenceHash 'a') (Get-EvidenceHash 'a')

# Pipeline-only override (owner rule 2026-10-14): a known pipeline change is the only flag.
function New-Pipe([double] $Minutes, [string] $Master, [hashtable] $More = @{}) {
    $f = New-Facts (@{ Paths = @('.github/workflows/build.yml'); Now = $t0.AddMinutes([math]::Max($Minutes, 12))
        PipelineOverride = @{ Minutes = $Minutes; MasterState = $Master; MasterEvidence = @() } })
    foreach ($k in $More.Keys) { $f[$k] = $More[$k] }
    $f
}
$d = Get-PromotionDecision -Facts (New-Pipe 59 'green')
Test-Case 'pipeline only, 59 minutes: hold with the promised time' @($d.Decision, ($d.Note -like '*promoted automatically after 2026-10-14 05:00 UTC if master*')) @('hold', $true)
$d = Get-PromotionDecision -Facts (New-Pipe 60 'green')
Test-Case 'pipeline only, 60 minutes, master green: promote by the override' @($d.Decision, $d.Reason, $d.Note) @('promote', 'pipeline-override')
Test-Case 'override Sign-off note names the rule' ((Format-PromotionReason -Decision $d -Previous 'uat' -RunUrl 'r1') -like 'Auto-promoted after 60 minutes: pipeline change accepted (owner rule 2026-10-14), master green, no other flag;*run r1') $true
$d = Get-PromotionDecision -Facts (New-Pipe 60 'pending')
Test-Case 'pipeline only, 60 minutes, master pending: hold with the promised time' @($d.Decision, ($d.Note -like '*after 2026-10-14 05:00 UTC if master*pending*')) @('hold', $true)
$d = Get-PromotionDecision -Facts (New-Pipe 60 'red')
Test-Case 'pipeline only, 60 minutes, master red: hold and say so' @($d.Decision, ($d.Note -like '*master is red*')) @('hold', $true)
$d = Get-PromotionDecision -Facts (New-Pipe 60 'unknown')
Test-Case 'pipeline only, 60 minutes, master unknown: hold and say so' @($d.Decision, ($d.Note -like '*could not be read*')) @('hold', $true)
Test-Case 'pipeline only, no override facts: hold (unknown)' (Get-PromotionDecision -Facts (New-Facts @{ Paths = @('Dockerfile') })).Decision 'hold'
Test-Case 'pipeline plus failed deployment, 600 minutes, master green: hold' (Get-PromotionDecision -Facts (New-Pipe 600 'green' @{ PreviousState = 'Failed' })).Decision 'hold'
Test-Case 'pipeline plus red checks, 600 minutes, master green: hold' (Get-PromotionDecision -Facts (New-Pipe 600 'green' @{ Checks = @(@{ Name = 'CRAP'; State = 'failure'; Url = 'x' }) })).Decision 'hold'
Test-Case 'pipeline plus Hold label, 600 minutes, master green: hold' (Get-PromotionDecision -Facts (New-Pipe 600 'green' @{ HoldItems = @(@{ Number = 7; Url = 'i7'; Labels = @('Hold') }) })).Decision 'hold'
Test-Case 'incomplete comparison, 600 minutes, master green: hold (no override)' (Get-PromotionDecision -Facts (New-Pipe 600 'green' @{ PathsKnown = $false })).Decision 'hold'
Test-Case 'pipeline only, 600 minutes, master green, a wait open: hold' (Get-PromotionDecision -Facts (New-Pipe 600 'green' @{ HoldUnknown = @('#4 not read') })).Decision 'hold'
$d = Get-PromotionDecision -Facts (New-Facts)
Test-Case 'no flag: promote as today' @($d.Decision, $d.Reason) @('promote', 'no-flag')
Test-Case 'no flag Sign-off note unchanged' (Format-PromotionReason -Decision $d -Previous 'tdd' -RunUrl 'r1') 'Auto-promoted: no flag. checks green (2 passed), deployment and health ok in tdd, no pipeline change, no Hold label; run r1'
Test-Case 'master: all passed is green' (Get-MasterState @(@{ Name = 'a'; State = 'success'; Url = '' }, @{ Name = 'b'; State = 'skipped'; Url = '' })).State 'green'
Test-Case 'master: one pending is pending' (Get-MasterState @(@{ Name = 'a'; State = 'success'; Url = '' }, @{ Name = 'b'; State = 'pending'; Url = '' })).State 'pending'
Test-Case 'master: one failed is red' (Get-MasterState @(@{ Name = 'a'; State = 'failure'; Url = '' }, @{ Name = 'b'; State = 'pending'; Url = '' })).State 'red'
Test-Case 'master: no check is not green' (Get-MasterState @()).State 'pending'

# --- Per-deployable settings (owner's decision 2026-10-15: fworker under the same rules as ui) ---
Test-Case 'settings: ui and fworker are promoted' @($DeployableSettings.Keys | Sort-Object) @('fworker', 'ui')
foreach ($n in $DeployableSettings.Keys) {
    $s = $DeployableSettings[$n]
    Test-Case "settings: $n has every key" @(@('ApplicationPaths', 'UnflaggedFolders', 'HealthPath', 'HealthRead') | Where-Object { -not $s.ContainsKey($_) }) @()
    Test-Case "settings: $n HealthRead is known" ($s.HealthRead -in 'overallStatus', 'ready') $true
}
Test-Case 'settings: loaded for ui by default' @($Deployable, $Settings.HealthPath) @('ui', '/_healthcheck/detailed')

# Flag 3 for the fworker repository layout
$fw = $DeployableSettings.fworker
function FwPipe([string[]] $Paths) { @(Get-PipelineEvidence -Paths $Paths -Application $fw.ApplicationPaths -Unflagged $fw.UnflaggedFolders) }
$fwOutside = '(outside gateway/, plugin/, tests/, config/instance.json)'
Test-Case 'fworker: gateway code does not flag' (FwPipe @('gateway/Program.cs', 'gateway/Plant.PassMerge.cs')) @()
Test-Case 'fworker: plugin scripts, skills and agents do not flag' (FwPipe @('plugin/scripts/lib/Core.ps1', 'plugin/scripts/models.default.json', 'plugin/skills/factory-operator/SKILL.md', 'plugin/agents/factory-reviewer.md', 'plugin/launcher/fworker-loop.sh', 'plugin/.claude-plugin/plugin.json')) @()
Test-Case 'fworker: tests do not flag' (FwPipe @('tests/scenarios/qc.ps1', 'tests/FakeGitHub/Program.cs', 'tests/smoke.ps1')) @()
Test-Case 'fworker: the instance configuration does not flag' (FwPipe @('config/instance.json')) @()
Test-Case 'fworker: documentation does not flag' (FwPipe @('README.md', 'docs/design/plant-manager.md', 'docs/deploy/activate-prod.sh')) @()
Test-Case 'fworker: the gateway project file flags' (FwPipe @('gateway/Gateway.csproj')) @('gateway/Gateway.csproj (build or project file)')
Test-Case 'fworker: a project file in the plugin flags' (FwPipe @('plugin/tools/shot/Shot.csproj')) @('plugin/tools/shot/Shot.csproj (build or project file)')
Test-Case 'fworker: Dockerfile flags with the application paths named' (FwPipe @('Dockerfile')) @("Dockerfile $fwOutside")
Test-Case 'fworker: workflows, .dockerignore, run scripts and tools flag' (FwPipe @('.github/workflows/release.yml', '.dockerignore', 'run-gateway.sh', 'tools/github-app-setup/serve.ps1')).Count 4
Test-Case 'fworker: deploy overrides flag' (FwPipe @('config/deploy.overrides.json', 'config/apply-overrides.ps1')) @("config/deploy.overrides.json $fwOutside", "config/apply-overrides.ps1 $fwOutside")
Test-Case 'fworker: a src/ path is not its application' (FwPipe @('src/Core/A.cs')) @("src/Core/A.cs $fwOutside")
Test-Case 'fworker: ui exemptions do not apply' (FwPipe @('.github/private-build/x.ps1')) @(".github/private-build/x.ps1 $fwOutside")
Test-Case 'ui unchanged: a gateway path is outside src/' (Get-PipelineEvidence -Paths @('gateway/Program.cs')) @('gateway/Program.cs (outside src/)')

# /ready of fworker
Test-Case 'ready: 200 ok is Healthy' (ConvertTo-ReadyStatus 200 'ok') 'Healthy'
Test-Case 'ready: 503 with ready false is NotReady' (ConvertTo-ReadyStatus 503 '{"ready":false,"waitingFor":"revocations","attempts":0}') 'NotReady'
Test-Case 'ready: 503 without the JSON answer is not answered (retried)' (ConvertTo-ReadyStatus 503 '<html>Service Unavailable</html>') ''
Test-Case 'ready: 502 is not answered (retried)' (ConvertTo-ReadyStatus 502 '') ''
Test-Case 'ready: 404 is not answered (retried)' (ConvertTo-ReadyStatus 404 'Not Found') ''
$pauses.Value = 0; $f = New-Reader @((ConvertTo-ReadyStatus 503 '{"ready":false}'), 'Healthy')
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'ready: NotReady while starting, then 200 is Healthy' @($r.Status, $f.Calls.Value, $pauses.Value) @('Healthy', 2, 1)
$pauses.Value = 0; $f = New-Reader @('NotReady', 'NotReady', 'NotReady', 'NotReady')
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'ready: NotReady on every attempt is NotReady' @($r.Status, $r.Attempts, $pauses.Value) @('NotReady', 4, 3)
$pauses.Value = 0; $f = New-Reader @('NotReady', 'throw', 'NotReady', '')
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'ready: NotReady mixed with no answer is Unreachable' @($r.Status, $r.Attempts) @('Unreachable', 4)
$pauses.Value = 0; $f = New-Reader @((ConvertTo-ReadyStatus 502 ''), 'throw', (ConvertTo-ReadyStatus 200 'ok'))
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'ready: unreachable twice then 200 is Healthy after 3 attempts' @($r.Status, $r.Attempts, $pauses.Value) @('Healthy', 3, 2)
$d = Get-PromotionDecision -Facts (New-Facts @{ HealthReads = @(@{ At = $t0.AddMinutes(2); Status = 'NotReady' }, @{ At = $t0.AddMinutes(11); Status = 'Healthy' }) }) -Name 'fworker' -HealthPath '/ready'
Test-Case 'fworker: a NotReady read flags, naming /ready' @($d.Decision, $d.Flags[0].Evidence[0]) @('hold', 'health: /ready was not Healthy: NotReady at 2026-10-14 04:02:00Z')
Test-Case 'fworker: unknown address names fworker' (Get-PromotionDecision -Facts (New-Facts @{ HealthAddressKnown = $false }) -Name 'fworker').Waiting @('health address unknown: the address of fworker in the previous environment could not be read')
Test-Case 'ui unchanged: the health flag names /_healthcheck/detailed' (Get-PromotionDecision -Facts (New-Facts @{ HealthReads = @(@{ At = $t0.AddMinutes(2); Status = 'Degraded' }) })).Flags[0].Evidence[0] 'health: /_healthcheck/detailed was not Healthy: Degraded at 2026-10-14 04:02:00Z'

# Held issue titles and evidence
Test-Case 'held title of ui unchanged' (Get-HeldTitle '2.4.470' 'prod') 'ui 2.4.470 held before prod'
Test-Case 'held title of fworker' (Get-HeldTitle '1.0.232' 'uat' 'fworker') 'fworker 1.0.232 held before uat'
Test-Case 'held title parts of fworker' @((Get-HeldTitleParts 'fworker 1.0.232 held before uat' 'fworker').Values | Sort-Object) @('1.0.232', 'uat')
Test-Case 'ui does not read an fworker issue' (Get-HeldTitleParts 'fworker 1.0.232 held before uat' 'ui') $null
Test-Case 'fworker does not read a ui issue' (Get-HeldTitleParts 'ui 2.4.470 held before prod' 'fworker') $null
Test-Case 'ui does not read an app2-ui issue' (Get-HeldTitleParts 'app2-ui 1.2.3 held before uat' 'ui') $null
Test-Case 'held evidence names fworker' ((Format-HeldEvidence -Version '1.0.232' -Sha 'c1' -Target 'uat' -Flags @() -Name 'fworker') -like 'fworker 1.0.232 (commit c1) is not promoted to uat automatically.*') $true
Test-Case 'held evidence of ui unchanged' ((Format-HeldEvidence -Version '2.4.1' -Sha 'c1' -Target 'uat' -Flags @()) -like 'ui 2.4.1 (commit c1) is not promoted to uat automatically.*') $true
Test-Case 'busy reason names fworker' (Get-BusyReason @(@{ Kind = 'deployment'; ProjectId = 'P-fw'; EnvironmentId = 'E-uat' }) 'E-prod' 'E-tdd' 'P-fw' 'fworker') 'a fworker deployment is not finished in another environment'

# State keys per deployable
Test-Case 'state key names the deployable' @((Get-StateKey 'Deployments-9' 'fworker'), (Get-StateKey 'Deployments-9')) @('fworker/Deployments-9', 'ui/Deployments-9')
$st = @{ 'Deployments-1' = @(@{ at = 'a'; status = 'Healthy' }); 'fworker/Deployments-2' = @(@{ at = 'b'; status = 'NotReady' }); 'ui/Deployments-2' = @(@{ at = 'c'; status = 'Healthy' }) }
Test-Case 'state: ui still finds its reads stored under the bare key' @(Read-StateReads $st 'Deployments-1' | ForEach-Object { $_.at }) @('a')
Test-Case 'state: fworker does not read a bare key' @(Read-StateReads $st 'Deployments-1' 'fworker').Count 0
Test-Case 'state: the same deployment id of two deployables does not collide' @(@(Read-StateReads $st 'Deployments-2' 'fworker')[0].at, @(Read-StateReads $st 'Deployments-2' 'ui')[0].at) @('b', 'c')

# Loaded for fworker: the defaults follow -Deployable.
. (Join-Path $PSScriptRoot 'ui-auto-promote.ps1') -LoadOnly -Deployable fworker
Test-Case 'loaded for fworker: settings' @($Settings.HealthPath, $Settings.HealthRead) @('/ready', 'ready')
Test-Case 'loaded for fworker: pipeline rules by default' (Get-PipelineEvidence -Paths @('gateway/A.cs', 'Dockerfile')) @("Dockerfile $fwOutside")
Test-Case 'loaded for fworker: held title by default' (Get-HeldTitle '1.0.1' 'prod') 'fworker 1.0.1 held before prod'
Test-Case 'loaded for fworker: health flag names /ready' (Get-PromotionDecision -Facts (New-Facts @{ HealthReads = @(@{ At = $t0.AddMinutes(2); Status = 'NotReady' }) })).Flags[0].Evidence[0] 'health: /ready was not Healthy: NotReady at 2026-10-14 04:02:00Z'
$threw = try { . (Join-Path $PSScriptRoot 'ui-auto-promote.ps1') -LoadOnly -Deployable aisf; $false } catch { $_.Exception.Message -like 'deployable aisf is not promoted automatically*' }
Test-Case 'a deployable without settings stops the script' $threw $true

if ($failures -gt 0) { Write-Host "$failures case(s) failed."; exit 1 }
Write-Host 'All cases passed.'
