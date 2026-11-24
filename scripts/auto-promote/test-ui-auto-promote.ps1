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

Test-Case 'Copilot agent run by name is ignored' (Test-AgentCheckRun 'Running Copilot cloud agent' '') $true
Test-Case 'Copilot agent run by app is ignored' (Test-AgentCheckRun 'agent' 'copilot-swe-agent') $true
Test-Case 'Copilot agent job named copilot is ignored' (Test-AgentCheckRun 'copilot' 'github-actions') $true
Test-Case 'real CI check is not ignored' (Test-AgentCheckRun 'Build result' 'github-actions') $false
# a failed Copilot agent run on the release commit does not hold it: filtered out before the decision, real checks pass
$realChecks = @(@(@{ n = 'Running Copilot cloud agent'; a = 'copilot-swe-agent'; s = 'failure' }, @{ n = 'Build result'; a = 'github-actions'; s = 'success' }) | Where-Object { -not (Test-AgentCheckRun $_.n $_.a) } | ForEach-Object { @{ Name = $_.n; State = $_.s; Url = '' } })
Test-Case 'failed Copilot agent run does not hold the release' (Get-PromotionDecision -Facts (New-Facts @{ Checks = $realChecks })).Decision 'promote'

# ui-auto-promote's own runs are not a build or test (issue #610). The workflow is what identifies them, not the job name.
Test-Case 'promoter workflow is not a build' (Test-PromoterCheckRun -WorkflowName 'ui-auto-promote' -WorkflowPath '.github/workflows/ui-auto-promote.yml') $true
Test-Case 'promoter path alone is not a build' (Test-PromoterCheckRun -WorkflowName '' -WorkflowPath '.github/workflows/ui-auto-promote.yml') $true
Test-Case 'capabilities workflow is a real check' (Test-PromoterCheckRun -WorkflowName 'capabilities' -WorkflowPath '.github/workflows/capabilities.yml') $false
Test-Case 'system workflow is a real check' (Test-PromoterCheckRun -WorkflowName 'system' -WorkflowPath '.github/workflows/system.yml') $false
Test-Case 'env-checks workflow is a real check' (Test-PromoterCheckRun -WorkflowName 'env-checks' -WorkflowPath '.github/workflows/env-checks.yml') $false
Test-Case 'a job named promote in another workflow is a real check' (Test-PromoterCheckRun -WorkflowName 'build' -WorkflowPath '.github/workflows/build.yml') $false
Test-Case 'actions run id from a check url' (Get-ActionsRunId 'https://github.com/o/r/actions/runs/43240281337/job/131258510940') '43240281337'
Test-Case 'no actions run id outside an actions url' (Get-ActionsRunId 'https://github.com/o/r/commit/abc') ''
function Select-ReleaseChecks([object[]] $Runs) {
    @($Runs | Where-Object { -not (Test-PromoterCheckRun -WorkflowName $_.Workflow -WorkflowPath $_.Path) -and -not (Test-MonitorCheckRun -WorkflowPath $_.Path) } | ForEach-Object { @{ Name = $_.Name; State = $_.State; Url = $_.Url } })
}
$onlyPromoter = Select-ReleaseChecks @(
    @{ Name = 'promote'; State = 'failure'; Url = 'https://github.com/o/r/actions/runs/1/job/2'; Workflow = 'ui-auto-promote'; Path = '.github/workflows/ui-auto-promote.yml' }
    @{ Name = 'publish'; State = 'failure'; Url = 'https://github.com/o/r/actions/runs/1/job/3'; Workflow = 'ui-auto-promote'; Path = '.github/workflows/ui-auto-promote.yml' }
    @{ Name = 'Build result'; State = 'success'; Url = 'b'; Workflow = 'build'; Path = '.github/workflows/build.yml' }
)
Test-Case 'only the promoter workflow red: promote' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @($onlyPromoter) })).Decision 'promote'
$promoterAndCapabilities = Select-ReleaseChecks @(
    @{ Name = 'promote'; State = 'failure'; Url = 'p'; Workflow = 'ui-auto-promote'; Path = '.github/workflows/ui-auto-promote.yml' }
    @{ Name = 'capabilities / capabilities'; State = 'failure'; Url = 'c'; Workflow = 'capabilities'; Path = '.github/workflows/capabilities.yml' }
)
Test-Case 'failed scheduled capabilities run no longer holds (owner 2026-11-21)' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @($promoterAndCapabilities) })).Decision 'wait'
$capabilitiesFromSystem = Select-ReleaseChecks @(
    @{ Name = 'promote'; State = 'failure'; Url = 'p'; Workflow = 'ui-auto-promote'; Path = '.github/workflows/ui-auto-promote.yml' }
    @{ Name = 'capabilities / capabilities'; State = 'failure'; Url = 'c'; Workflow = 'system'; Path = '.github/workflows/system.yml' }
)
Test-Case 'failed promoter run does not hide a failed capabilities check called from system.yml' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @($capabilitiesFromSystem) })).Decision 'hold'

# Monitoring workflows are not a build or test (owner, Jeffrey Palermo 2026-11-21). By workflow file, never by job name.
foreach ($wf in 'capabilities', 'deployments', 'delivery', 'workitems', 'drift', 'fleet-findings', 'kit-templates', 'pool-manager', 'pool-reset', 'factory-wake') {
    Test-Case "monitor workflow $wf is not a build" (Test-MonitorCheckRun -WorkflowPath ".github/workflows/$wf.yml") $true
}
foreach ($wf in 'system', 'env-checks', 'build', 'release', 'refactoring-rationale', 'ui-auto-promote') {
    Test-Case "workflow $wf is not a monitor" (Test-MonitorCheckRun -WorkflowPath ".github/workflows/$wf.yml") $false
}
Test-Case 'unreadable workflow is not a monitor' (Test-MonitorCheckRun -WorkflowPath '') $false
Test-Case 'monitor file name outside .github/workflows is not a monitor' (Test-MonitorCheckRun -WorkflowPath 'other/deployments.yml') $false
$monitorsRedAndPending = Select-ReleaseChecks @(
    @{ Name = 'capabilities / report'; State = 'failure'; Url = 'c'; Workflow = 'capabilities'; Path = '.github/workflows/capabilities.yml' }
    @{ Name = 'deployments'; State = 'pending'; Url = 'd'; Workflow = 'deployments'; Path = '.github/workflows/deployments.yml' }
    @{ Name = 'workitems'; State = 'pending'; Url = 'w'; Workflow = 'workitems'; Path = '.github/workflows/workitems.yml' }
    @{ Name = 'system-release'; State = 'success'; Url = 's'; Workflow = 'system'; Path = '.github/workflows/system.yml' }
)
Test-Case 'red and pending monitors with a green build: promote' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @($monitorsRedAndPending) })).Decision 'promote'
Test-Case 'red and pending monitors with a green build: master green' (Get-MasterState -Checks @($monitorsRedAndPending)).State 'green'
$monitorsAndRedBuild = Select-ReleaseChecks @(
    @{ Name = 'deployments'; State = 'success'; Url = 'd'; Workflow = 'deployments'; Path = '.github/workflows/deployments.yml' }
    @{ Name = 'Build result'; State = 'failure'; Url = 'b'; Workflow = 'Build'; Path = '.github/workflows/build.yml' }
)
Test-Case 'a real red build still holds next to green monitors' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @($monitorsAndRedBuild) })).Decision 'hold'
Test-Case 'a real red build still makes master red' (Get-MasterState -Checks @($monitorsAndRedBuild)).State 'red'
$promoterAndSystem = Select-ReleaseChecks @(
    @{ Name = 'promote'; State = 'pending'; Url = 'p'; Workflow = 'ui-auto-promote'; Path = '.github/workflows/ui-auto-promote.yml' }
    @{ Name = 'system-release'; State = 'failure'; Url = 's'; Workflow = 'system'; Path = '.github/workflows/system.yml' }
)
Test-Case 'a pending promoter run does not hide a failed system check' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @($promoterAndSystem) })).Decision 'hold'
$pendingPromoterOnly = Select-ReleaseChecks @(
    @{ Name = 'promote'; State = 'pending'; Url = 'p'; Workflow = 'ui-auto-promote'; Path = '' }
    @{ Name = 'Build result'; State = 'success'; Url = 'b'; Workflow = 'build'; Path = '.github/workflows/build.yml' }
)
Test-Case 'a pending promoter run does not make the release wait' (Get-PromotionDecision -Facts (New-Facts @{ Checks = @($pendingPromoterOnly) })).Decision 'promote'

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
# Test projects are not a pipeline change (owner, Jeffrey Palermo 2026-11-21)
Test-Case 'test project file does not flag' (Flags (New-Facts @{ Paths = @('src/Dashboard.Tests/Dashboard.Tests.csproj') })) @()
Test-Case 'unit test project file does not flag' (Flags (New-Facts @{ Paths = @('src/UnitTests/UnitTests.csproj') })) @()
Test-Case 'test project props does not flag' (Flags (New-Facts @{ Paths = @('src/AcceptanceTests/Directory.Build.props') })) @()
Test-Case 'test source does not flag' (Flags (New-Facts @{ Paths = @('src/IntegrationTests/Api/X.cs') })) @()
Test-Case 'root tests folder does not flag' (Flags (New-Facts @{ Paths = @('tests/smoke/run.ps1') })) @()
Test-Case 'nested *.Tests.* project does not flag' (Flags (New-Facts @{ Paths = @('src/Dashboard.Tests.Shared/Shared.csproj') })) @()
Test-Case 'test project Dockerfile still flags' (Flags (New-Facts @{ Paths = @('src/AcceptanceTests/Dockerfile') })) @('Pipeline or infra change')
Test-Case 'script test file still flags' (Flags (New-Facts @{ Paths = @('scripts/acceptance/Protect-PrAcceptanceArtifactBundle.Tests.ps1') })) @('Pipeline or infra change')
Test-Case 'scripts tests folder still flags' (Flags (New-Facts @{ Paths = @('scripts/tests/x.ps1') })) @('Pipeline or infra change')
Test-Case 'github workflow under a tests folder still flags' (Flags (New-Facts @{ Paths = @('.github/tests/x.yml') })) @('Pipeline or infra change')
Test-Case 'product csproj next to a test project still flags' (Flags (New-Facts @{ Paths = @('src/Dashboard.Tests/X.cs', 'src/Dashboard/Dashboard.csproj') })) @('Pipeline or infra change')
Test-Case 'a folder merely containing Test still flags' (Flags (New-Facts @{ Paths = @('src/Contest/Contest.csproj') })) @('Pipeline or infra change')
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
# Busy reason names the unfinished Octopus task (#701) so a stall can be diagnosed from the run log.
Test-Case 'busy reason names task release and state to the target' (
    Get-BusyReason @(@{
            Kind = 'deployment'; ProjectId = 'Projects-981'; EnvironmentId = 'E-prod'
            TaskId = 'ServerTasks-99'; ReleaseVersion = '1.0.211'; State = 'Executing'
        }) 'E-prod' 'E-tdd' 'P-system' 'system'
) 'a deployment of project Projects-981 to the target environment is not finished (task ServerTasks-99, release 1.0.211, state Executing)'
Test-Case 'busy reason names task release and state in another environment' (
    Get-BusyReason @(@{
            Kind = 'deployment'; ProjectId = 'P-system'; EnvironmentId = 'E-uat'
            TaskId = 'ServerTasks-100'; ReleaseVersion = '1.0.211'; State = 'Waiting'
        }) 'E-prod' 'E-tdd' 'P-system' 'system'
) 'a system deployment is not finished in another environment (task ServerTasks-100, release 1.0.211, state Waiting)'
Test-Case 'busy reason without task fields keeps the short message' (
    Get-BusyReason @(@{ Kind = 'deployment'; ProjectId = 'P-other'; EnvironmentId = 'E-prod' }) 'E-prod' 'E-tdd' 'P-ui'
) 'a deployment of project P-other to the target environment is not finished'

# Refused Sign-off is a hold, not a workflow failure (#569)
function New-DeniedError([string] $Message) {
    [System.Management.Automation.ErrorRecord]::new([Exception]::new($Message), 'OctopusDenied', 'NotSpecified', $null)
}
Test-Case 'permission denied: HTTP 403 message is refused' (Test-OctopusPermissionDenied (New-DeniedError 'Response status code does not indicate success: 403 (Forbidden).')) $true
Test-Case 'permission denied: HTTP 401 message is refused' (Test-OctopusPermissionDenied (New-DeniedError 'Response status code does not indicate success: 401 (Unauthorized).')) $true
Test-Case 'permission denied: Octopus team wording is refused' (Test-OctopusPermissionDenied (New-DeniedError 'You must be in a team that has permissions to take this interruption.')) $true
Test-Case 'permission denied: not in any team wording is refused' (Test-OctopusPermissionDenied (New-DeniedError 'The current user is not in any team with permissions to perform this action.')) $true
Test-Case 'permission denied: a 503 is not refused' (Test-OctopusPermissionDenied (New-DeniedError 'Response status code does not indicate success: 503 (Service Unavailable).')) $false
Test-Case 'permission denied: a network error is not refused' (Test-OctopusPermissionDenied (New-DeniedError 'Unable to connect to the remote server')) $false
Test-Case 'permission denied: do not have permission / TaskCancel wording is refused' (Test-OctopusPermissionDenied (New-DeniedError 'You do not have permission to perform this action. The TaskCancel permission is required.')) $true

# Real Sign-off path (#589): Invoke-SignOffOctopusCalls calls script-scope Invoke-Octopus (not an injected
# scriptblock). A GetNewClosure wrapper around those calls would hide the function when Actions runs the
# script with &, so this stub must live at script scope for the harness to catch that class of bug.
$script:signOffOctopusCalls = [System.Collections.Generic.List[hashtable]]::new()
function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    $script:signOffOctopusCalls.Add(@{ Path = $Path; Method = $Method; Body = $Body })
}
$script:signOffOctopusCalls.Clear()
$signed = Invoke-SignOffOctopusCalls -Space 'Spaces-1' -InterruptionId 'Interruptions-9' -Reason 'promote' -NeedTakeResponsibility $true
Test-Case 'sign-off calls: success returns signed' $signed 'signed'
Test-Case 'sign-off calls: script-scope Invoke-Octopus takes responsibility then submits' @(
    $script:signOffOctopusCalls.Count
    $script:signOffOctopusCalls[0].Method
    $script:signOffOctopusCalls[0].Path
    $script:signOffOctopusCalls[1].Method
    $script:signOffOctopusCalls[1].Path
    $script:signOffOctopusCalls[1].Body.Notes
    $script:signOffOctopusCalls[1].Body.Result
) @(2, 'Put', '/api/Spaces-1/interruptions/Interruptions-9/responsible', 'Post', '/api/Spaces-1/interruptions/Interruptions-9/submit', 'promote', 'Proceed')

function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    if ($Path -like '*/responsible') { throw (New-DeniedError 'You must be in a team that has permissions') }
    throw 'submit should not run'
}
$refusedTake = Invoke-SignOffOctopusCalls -Space 'Spaces-1' -InterruptionId 'Interruptions-9' -Reason 'promote' -NeedTakeResponsibility $true
Test-Case 'sign-off calls: permission denied on take-responsibility returns refused' $refusedTake 'refused'

function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    throw (New-DeniedError 'Response status code does not indicate success: 403 (Forbidden).')
}
$refusedSubmit = Invoke-SignOffOctopusCalls -Space 'Spaces-1' -InterruptionId 'Interruptions-9' -Reason 'promote' -NeedTakeResponsibility $false
Test-Case 'sign-off calls: permission denied on submit returns refused' $refusedSubmit 'refused'

function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    throw (New-DeniedError 'Response status code does not indicate success: 500 (Internal Server Error).')
}
$otherErr = try { Invoke-SignOffOctopusCalls -Space 'Spaces-1' -InterruptionId 'Interruptions-9' -Reason 'promote' -NeedTakeResponsibility $false; 'no throw' } catch { $_.Exception.Message }
Test-Case 'sign-off calls: any other error still throws' $otherErr 'Response status code does not indicate success: 500 (Internal Server Error).'

# Already-held responsibility: only submit is called (script-scope Invoke-Octopus, not a parameter).
$script:signOffOctopusCalls = [System.Collections.Generic.List[hashtable]]::new()
function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    $script:signOffOctopusCalls.Add(@{ Path = $Path; Method = $Method; Body = $Body })
}
$signedNoTake = Invoke-SignOffOctopusCalls -Space 'Spaces-1' -InterruptionId 'Interruptions-9' -Reason 'recover' -NeedTakeResponsibility $false
Test-Case 'sign-off calls: when responsibility is held only submit runs' @(
    $signedNoTake
    $script:signOffOctopusCalls.Count
    $script:signOffOctopusCalls[0].Method
    $script:signOffOctopusCalls[0].Path
) @('signed', 1, 'Post', '/api/Spaces-1/interruptions/Interruptions-9/submit')

$refusedEv = New-SignOffRefusedEvaluation -Sha 'abc' -ProjectName 'cmdemo1-dashboard' -ReleaseVersion '1.0.31' -EnvironmentName 'uat' -Detail 'HTTP 403'
Test-Case 'refused Sign-off hold names the flag' $refusedEv.Decision.Flags[0].Flag $SignOffPermissionDeniedFlag
Test-Case 'refused Sign-off hold evidence names project release environment' @(
    ($refusedEv.Decision.Flags[0].Evidence[0] -like '*cmdemo1-dashboard*'),
    ($refusedEv.Decision.Flags[0].Evidence[0] -like '*1.0.31*'),
    ($refusedEv.Decision.Flags[0].Evidence[0] -like '*uat*'),
    (Test-SignOffRefusedHoldBody (Format-HeldEvidence -Version '1.0.31' -Sha 'abc' -Target 'uat' -Flags $refusedEv.Decision.Flags -Name 'dashboard'))
) @($true, $true, $true, $true)
$heldBody = Format-HeldEvidence -Version '1.0.31' -Sha 'abc' -Target 'uat' -Flags $refusedEv.Decision.Flags -DeploymentNote 'waits at Sign-off' -Name 'dashboard'
Test-Case 'refused Sign-off does not throw: hold is recorded as release-held evidence' @(
    ($heldBody -like '*Sign-off permission denied*'),
    ($heldBody -like '*dashboard 1.0.31*'),
    ($heldBody -like '*uat*')
) @($true, $true, $true)

$refusedBusy = @{ Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'; SignOffRefused = $true }
Test-Case 'refused Sign-off does not block another project to that environment' ([bool] (Get-BusyReason @($refusedBusy) 'E-uat' 'E-tdd' 'P-ui')) $false
Test-Case 'a running deployment to the target still blocks' ([bool] (Get-BusyReason @(@{ Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'; SignOffRefused = $false }) 'E-uat' 'E-tdd' 'P-ui')) $true
Test-Case 'a runbook in the target still blocks beside a refused Sign-off' ([bool] (Get-BusyReason @($refusedBusy, @{ Kind = 'runbook'; ProjectId = 'P-other'; EnvironmentId = 'E-uat'; SignOffRefused = $false }) 'E-uat' 'E-tdd' 'P-ui')) $true

$markItems = @(@{ Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'; Deployment = @{ ReleaseId = 'R-31' }; SignOffRefused = $false })
$markHolds = @(@{ number = 12; title = 'dashboard 1.0.31 held before uat'; body = $heldBody })
Set-SignOffRefusedOnBusyItems -Items $markItems -HeldIssues $markHolds -ProjectIdByDeployableName @{ dashboard = 'P-dash' } -EnvironmentIdByName @{ uat = 'E-uat' } -GetReleaseVersion { param($b) '1.0.31' }
Test-Case 'open refused hold marks the busy deployment SignOffRefused' $markItems[0].SignOffRefused $true
Test-Case 'marked refused hold no longer blocks ui to uat' ([bool] (Get-BusyReason $markItems 'E-uat' 'E-tdd' 'P-ui')) $false

# Superseded Sign-off/MI cancel (#731): cancel older waiting tasks when a newer release is the candidate.
$candidate35 = @{ Version = '1.0.40'; Assembled = [datetimeoffset]'2026-11-14T00:00:00Z' }
$live38 = @{ Version = '1.0.38'; Assembled = [datetimeoffset]'2026-11-12T00:00:00Z' }
$older35 = @{
    Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'
    TaskId = 'ServerTasks-12244352'; ReleaseVersion = '1.0.35'; State = 'Waiting'
    Deployment = @{ Id = 'Deployments-58090'; ReleaseId = 'R-35' }
}
$candidateBusy = @{
    Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'
    TaskId = 'ServerTasks-12261451'; ReleaseVersion = '1.0.40'; State = 'Queued'
    Deployment = @{ Id = 'Deployments-58286'; ReleaseId = 'R-40' }
}
$liveBusy = @{
    Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'
    TaskId = 'ServerTasks-live'; ReleaseVersion = '1.0.38'; State = 'Waiting'
    Deployment = @{ Id = 'Deployments-live'; ReleaseId = 'R-38' }
}
$waitsAlways = { param([string] $taskId) $true }.GetNewClosure()
$waitsNever = { param([string] $taskId) $false }.GetNewClosure()
$waitsOnly35 = { param([string] $taskId) $taskId -eq 'ServerTasks-12244352' }.GetNewClosure()

Test-Case '731: pending ManualIntervention is detected' (
    Test-PendingManualIntervention @(@{ Type = 'ManualIntervention'; TaskId = 'ServerTasks-1'; IsPending = $true; Title = 'Sign-off' }) 'ServerTasks-1'
) $true
Test-Case '731: GuidedFailure is not a pending MI' (
    Test-PendingManualIntervention @(@{ Type = 'GuidedFailure'; TaskId = 'ServerTasks-1'; IsPending = $true; Title = 'Sign-off' }) 'ServerTasks-1'
) $false
Test-Case '731: answered MI is not pending' (
    Test-PendingManualIntervention @(@{ Type = 'ManualIntervention'; TaskId = 'ServerTasks-1'; IsPending = $false; Title = 'Sign-off' }) 'ServerTasks-1'
) $false

$selected = @(Select-SupersededWaitingBusyItems -Items @($older35, $candidateBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $candidate35 -LiveRelease $live38 -CandidateTaskId 'ServerTasks-12261451' -TestWaitsAtManualIntervention $waitsOnly35)
Test-Case '731: selects the older Sign-off task' @($selected.Count, $selected[0].TaskId) @(1, 'ServerTasks-12244352')

$neverCandidate = @(Select-SupersededWaitingBusyItems -Items @($candidateBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $candidate35 -LiveRelease $live38 -CandidateTaskId 'ServerTasks-12261451' -TestWaitsAtManualIntervention $waitsAlways)
Test-Case '731: never cancels the candidate own task' $neverCandidate.Count 0

$neverLive = @(Select-SupersededWaitingBusyItems -Items @($liveBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $candidate35 -LiveRelease $live38 -CandidateTaskId '' -TestWaitsAtManualIntervention $waitsAlways)
Test-Case '731: never cancels the live release task' $neverLive.Count 0

$notWaiting = @(Select-SupersededWaitingBusyItems -Items @($older35) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $candidate35 -LiveRelease $live38 -CandidateTaskId '' -TestWaitsAtManualIntervention $waitsNever)
Test-Case '731: skips an older task not waiting at MI' $notWaiting.Count 0

$newerThanCandidate = @{
    Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'
    TaskId = 'ServerTasks-newer'; ReleaseVersion = '1.0.42'; State = 'Waiting'
}
$notOlder = @(Select-SupersededWaitingBusyItems -Items @($newerThanCandidate) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $candidate35 -LiveRelease $live38 -CandidateTaskId '' -TestWaitsAtManualIntervention $waitsAlways)
Test-Case '731: skips a newer-than-candidate waiting task' $notOlder.Count 0

Test-Case '731: cancel log names the superseded task' (
    Format-SupersededCancelLog -TaskId 'ServerTasks-12244352' -ReleaseVersion '1.0.35' -EnvironmentName 'uat' -CandidateVersion '1.0.40' -Name 'dashboard' -InterruptionTitle 'Sign-off'
) 'Cancelling superseded task ServerTasks-12244352 (dashboard 1.0.35 waits at its Sign-off in uat) so candidate 1.0.40 can run.'

Test-Case '731: missing permission TaskCancel is extracted' (
    Get-OctopusMissingPermission (New-DeniedError 'You do not have permission to perform this action. The TaskCancel permission is required.')
) 'TaskCancel'
Test-Case '731: missing permission with backticks is extracted' (
    Get-OctopusMissingPermission (New-DeniedError 'The `TaskCancel` permission is required to perform this action.')
) 'TaskCancel'
Test-Case '731: no named permission yields null' (Get-OctopusMissingPermission (New-DeniedError 'Response status code does not indicate success: 403 (Forbidden).')) $null

$script:cancelOctopusCalls = [System.Collections.Generic.List[hashtable]]::new()
function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    $script:cancelOctopusCalls.Add(@{ Path = $Path; Method = $Method; Body = $Body })
}
$script:cancelOctopusCalls.Clear()
$canceled = Invoke-CancelOctopusTask -Space 'Spaces-1' -TaskId 'ServerTasks-12244352'
Test-Case '731: cancel calls script-scope Invoke-Octopus POST cancel' @(
    $canceled.Outcome
    $script:cancelOctopusCalls.Count
    $script:cancelOctopusCalls[0].Method
    $script:cancelOctopusCalls[0].Path
) @('canceled', 1, 'Post', '/api/Spaces-1/tasks/ServerTasks-12244352/cancel')

function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    throw (New-DeniedError 'You do not have permission to perform this action. The TaskCancel permission is required.')
}
$refusedCancel = Invoke-CancelOctopusTask -Space 'Spaces-1' -TaskId 'ServerTasks-12244352'
Test-Case '731: refused cancel returns refused and TaskCancel' @($refusedCancel.Outcome, $refusedCancel.Permission) @('refused', 'TaskCancel')

function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    throw (New-DeniedError 'Response status code does not indicate success: 500 (Internal Server Error).')
}
$cancelOther = try { Invoke-CancelOctopusTask -Space 'Spaces-1' -TaskId 'ServerTasks-1'; 'no throw' } catch { $_.Exception.Message }
Test-Case '731: non-permission cancel error still throws' $cancelOther 'Response status code does not indicate success: 500 (Internal Server Error).'

$cancelEv = New-TaskCancelRefusedEvaluation -Sha 'abc' -ProjectName 'cmdemo1-dashboard' -ReleaseVersion '1.0.35' -EnvironmentName 'uat' -TaskId 'ServerTasks-12244352' -Permission 'TaskCancel'
Test-Case '731: refused cancel hold names the flag' $cancelEv.Decision.Flags[0].Flag $TaskCancelPermissionDeniedFlag
Test-Case '731: refused cancel hold names TaskCancel and the task' @(
    ($cancelEv.Decision.Flags[0].Evidence[0] -like '*TaskCancel*'),
    ($cancelEv.Decision.Flags[0].Evidence[0] -like '*ServerTasks-12244352*'),
    ($cancelEv.Decision.Flags[0].Evidence[0] -like '*1.0.35*'),
    (Test-TaskCancelRefusedHoldBody (Format-HeldEvidence -Version '1.0.35' -Sha 'abc' -Target 'uat' -Flags $cancelEv.Decision.Flags -Name 'dashboard'))
) @($true, $true, $true, $true)

Test-Case '731: candidate busy task id is found' (
    Get-CandidateBusyTaskId -Items @($older35, $candidateBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' -CandidateVersion '1.0.40'
) 'ServerTasks-12261451'
Test-Case '731: candidate busy task id empty when absent' (
    Get-CandidateBusyTaskId -Items @($older35) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' -CandidateVersion '1.0.40'
) ''

# Queued candidate already deployed (#733): newest busy deployment is Queued; cancel older Sign-off behind it.
Test-Case '733: newest busy deployment is the queued 1.0.40' (
    (Get-NewestBusyDeploymentItem -Items @($older35, $candidateBusy, $liveBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat').TaskId
) 'ServerTasks-12261451'
Test-Case '733: queued candidate is returned when newest is Queued' (
    (Get-QueuedCandidateBusyItem -Items @($older35, $candidateBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat').TaskId
) 'ServerTasks-12261451'
Test-Case '733: no queued candidate when newest is Waiting at Sign-off' (
    $null -eq (Get-QueuedCandidateBusyItem -Items @($older35) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat')
) $true
Test-Case '733: no queued candidate in another environment' (
    $null -eq (Get-QueuedCandidateBusyItem -Items @($older35, $candidateBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-prod')
) $true
Test-Case '733: no queued candidate for another project' (
    $null -eq (Get-QueuedCandidateBusyItem -Items @($older35, $candidateBusy) -ProjectId 'P-ui' -TargetEnvironmentId 'E-uat')
) $true

$queuedSelected = @(Select-SupersededWaitingBusyItems -Items @($older35, $candidateBusy, $liveBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $candidate35 -LiveRelease $live38 -CandidateTaskId 'ServerTasks-12261451' -TestWaitsAtManualIntervention $waitsOnly35)
Test-Case '733: queued-candidate path selects only the older Sign-off' @($queuedSelected.Count, $queuedSelected[0].TaskId) @(1, 'ServerTasks-12244352')
Test-Case '733: queued-candidate path never selects the queued newer task' (
    @($queuedSelected | Where-Object { $_.TaskId -eq 'ServerTasks-12261451' }).Count
) 0
Test-Case '733: queued-candidate path never selects the live release task' (
    @($queuedSelected | Where-Object { $_.TaskId -eq 'ServerTasks-live' }).Count
) 0

$onlyQueued = @(Select-SupersededWaitingBusyItems -Items @($candidateBusy) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $candidate35 -LiveRelease $live38 -CandidateTaskId 'ServerTasks-12261451' -TestWaitsAtManualIntervention $waitsAlways)
Test-Case '733: only a queued deployment yields nothing to cancel' $onlyQueued.Count 0

$waitingNewest = @{
    Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'
    TaskId = 'ServerTasks-waiting-new'; ReleaseVersion = '1.0.41'; State = 'Waiting'
    Deployment = @{ Id = 'Deployments-waiting-new'; ReleaseId = 'R-41' }
}
Test-Case '733: Waiting newer than an older Sign-off is not a queued candidate' (
    $null -eq (Get-QueuedCandidateBusyItem -Items @($older35, $waitingNewest) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat')
) $true

# Stale Queued / not-running busy hold (#747): surface Queued blockers after 20 minutes; never hold a Running task.
$now747 = [datetime]::Parse('2026-11-15T04:00:00Z', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
$queuedUnder20 = @{
    Kind = 'deployment'; ProjectId = 'Projects-1035'; EnvironmentId = 'E-prod'
    TaskId = 'ServerTasks-12262326'; ReleaseVersion = '1.0.46'; State = 'Queued'
    QueueTime = $now747.AddMinutes(-10)
    Deployment = @{ Id = 'Deployments-58326'; Created = $now747.AddMinutes(-10) }
}
$queuedOver20 = @{
    Kind = 'deployment'; ProjectId = 'Projects-1035'; EnvironmentId = 'E-prod'
    TaskId = 'ServerTasks-12262326'; ReleaseVersion = '1.0.46'; State = 'Queued'
    QueueTime = $now747.AddMinutes(-65)
    Deployment = @{ Id = 'Deployments-58326'; Created = $now747.AddMinutes(-65) }
}
$runningLong = @{
    Kind = 'deployment'; ProjectId = 'Projects-1035'; EnvironmentId = 'E-prod'
    TaskId = 'ServerTasks-running'; ReleaseVersion = '1.0.46'; State = 'Executing'
    QueueTime = $now747.AddMinutes(-90)
}
Test-Case '747: Queued is not-running' (Test-BusyItemNotRunning $queuedUnder20) $true
Test-Case '747: Waiting is not-running' (Test-BusyItemNotRunning @{ State = 'Waiting' }) $true
Test-Case '747: Executing is running' (Test-BusyItemNotRunning $runningLong) $false
Test-Case '747: Cancelling is running' (Test-BusyItemNotRunning @{ State = 'Cancelling' }) $false
Test-Case '747: Queued under 20 min does not need a hold' (Test-StaleQueuedHoldNeeded $queuedUnder20 $now747) $false
Test-Case '747: Queued over 20 min needs a hold' (Test-StaleQueuedHoldNeeded $queuedOver20 $now747) $true
Test-Case '747: Running task never needs a hold' (Test-StaleQueuedHoldNeeded $runningLong $now747) $false
Test-Case '747: age minutes from QueueTime' (Get-BusyItemQueuedAgeMinutes $queuedOver20 $now747) 65.0

$blocker747 = Get-BlockingBusyItem -Items @($queuedOver20) -TargetEnvironmentId 'E-prod' -FirstEnvironmentId 'E-tdd' -ProjectId 'P-ui'
Test-Case '747: blocking item is the Queued dashboard task' $blocker747.TaskId 'ServerTasks-12262326'
Test-Case '747: behind summary with no peers names concurrency/worker stall' (
    Format-QueuedBehindSummary -Items @($queuedOver20) -EnvironmentId 'E-prod' -ExcludeTaskId 'ServerTasks-12262326'
) 'no other active task in this environment is visible (likely the per-environment concurrency tag or a worker/pool stall)'
$peerRunning = @{
    Kind = 'deployment'; ProjectId = 'P-ui'; EnvironmentId = 'E-prod'
    TaskId = 'ServerTasks-peer'; ReleaseVersion = '2.4.1'; State = 'Executing'
}
Test-Case '747: behind summary names the other active task' (
    (Format-QueuedBehindSummary -Items @($queuedOver20, $peerRunning) -EnvironmentId 'E-prod' -ExcludeTaskId 'ServerTasks-12262326') -like '*ServerTasks-peer*Executing*'
) $true

$staleEv747 = New-QueuedTaskStaleEvaluation -Sha 'abc' -ProjectName 'cmdemo1-dashboard' -ReleaseVersion '1.0.46' `
    -EnvironmentName 'prod' -TaskId 'ServerTasks-12262326' -State 'Queued' -AgeMinutes 65 `
    -BehindSummary 'no other active task in this environment is visible (likely the per-environment concurrency tag or a worker/pool stall)'
Test-Case '747: hold names the Queued task flag' $staleEv747.Decision.Flags[0].Flag $QueuedTaskStaleFlag
$staleBody747 = Format-HeldEvidence -Version '1.0.46' -Sha 'abc' -Target 'prod' -Flags $staleEv747.Decision.Flags -Name 'dashboard' `
    -DeploymentNote 'The deployment Deployments-58326 is still Queued and blocks promotion.'
Test-Case '747: hold issue text names the task' @(
    ($staleBody747 -like '*ServerTasks-12262326*'),
    ($staleBody747 -like '*1.0.46*'),
    ($staleBody747 -like '*Queued*'),
    (Test-QueuedTaskStaleHoldBody $staleBody747)
) @($true, $true, $true, $true)

Test-Case '747: same live version safely supersedes Queued' (
    Test-QueuedBusySafelySupersededByLive -QueuedItem $queuedOver20 -LiveRelease @{ Version = '1.0.46' }
) $true
Test-Case '747: newer live version safely supersedes Queued' (
    Test-QueuedBusySafelySupersededByLive -QueuedItem $queuedOver20 -LiveRelease @{ Version = '1.0.50' }
) $true
Test-Case '747: older live version does not supersede Queued' (
    Test-QueuedBusySafelySupersededByLive -QueuedItem $queuedOver20 -LiveRelease @{ Version = '1.0.44' }
) $false
Test-Case '747: Executing is never safely superseded for cancel' (
    Test-QueuedBusySafelySupersededByLive -QueuedItem $runningLong -LiveRelease @{ Version = '1.0.50' }
) $false

# Superseded Sign-off recovery when comparison is behind (#739): older release waits at Sign-off, newer already in
# that environment (behind, 0 commits). Must not throw on missing Decision; cancel (or named TaskCancel hold).
$behindSha739 = '76b668f100000000000000000000000000000000'
$baseSha739 = '75ae843c00000000000000000000000000000000'
$behindEv739 = New-BehindEvaluation -Sha $behindSha739 -BaseSha $baseSha739
Test-Case '739: behind evaluation sets Behind' $behindEv739.Behind $true
Test-Case '739: behind evaluation always sets Decision' @(
    ($null -ne $behindEv739.Decision)
    $behindEv739.Decision.Decision
    ($behindEv739.Decision.Waiting[0] -like "*$behindSha739*behind*$baseSha739*")
) @($true, 'wait', $true)
Test-Case '739: StrictMode can read Decision on behind evaluation' @(
    $behindEv739.Decision.Decision
    @($behindEv739.Decision.Waiting).Count
) @('wait', 1)

# Exact production shape before the fix: Behind with no Decision (StrictMode threw in recovery).
$legacyBehind739 = @{ Behind = $true; Sha = $behindSha739; BaseSha = $baseSha739 }
Test-Case '739: Test-EvaluationBehind sees Behind without Decision' (Test-EvaluationBehind $legacyBehind739) $true
Test-Case '739: Get-EvaluationDecision is null on the legacy shape' ($null -eq (Get-EvaluationDecision $legacyBehind739)) $true
$legacyDisp739 = Get-RecoverySignOffDisposition -Evaluation $legacyBehind739
Test-Case '739: behind without Decision: disposition is cancel-superseded (no throw)' $legacyDisp739.Action 'cancel-superseded'
$behindDisp739 = Get-RecoverySignOffDisposition -Evaluation $behindEv739
Test-Case '739: behind with Decision: disposition is cancel-superseded' $behindDisp739.Action 'cancel-superseded'

Test-Case '739: promote disposition answers Sign-off' (
    (Get-RecoverySignOffDisposition -Evaluation @{ Behind = $false; Decision = @{ Decision = 'promote'; Waiting = @() } }).Action
) 'answer'
Test-Case '739: hold disposition holds' (
    (Get-RecoverySignOffDisposition -Evaluation @{ Behind = $false; Decision = @{ Decision = 'hold'; Waiting = @(); Flags = @() } }).Action
) 'hold'
$waitDisp739 = Get-RecoverySignOffDisposition -Evaluation @{ Behind = $false; Decision = @{ Decision = 'wait'; Waiting = @('pending check') } }
Test-Case '739: wait disposition leaves waiting' @($waitDisp739.Action, $waitDisp739.Waiting[0]) @('wait', 'pending check')
$missingDecision739 = try { Get-RecoverySignOffDisposition -Evaluation @{ Behind = $false }; 'no throw' } catch { 'threw' }
Test-Case '739: missing Decision when not Behind fails closed' $missingDecision739 'threw'

# Older 1.0.35 at Sign-off, newer 1.0.40 already live in uat (the run 43658626359 case): select for cancel.
$live40 = @{ Version = '1.0.40'; Assembled = [datetimeoffset]'2026-11-14T18:00:00Z' }
$selected739 = @(Select-SupersededWaitingBusyItems -Items @($older35) -ProjectId 'P-dash' -TargetEnvironmentId 'E-uat' `
        -CandidateRelease $live40 -LiveRelease $live40 -CandidateTaskId '' -TestWaitsAtManualIntervention $waitsOnly35)
Test-Case '739: older Sign-off selected against live newer release' @($selected739.Count, $selected739[0].TaskId) @(1, 'ServerTasks-12244352')
Test-Case '739: cancel log names ServerTasks-12244352 for the behind recovery case' (
    Format-SupersededCancelLog -TaskId 'ServerTasks-12244352' -ReleaseVersion '1.0.35' -EnvironmentName 'uat' -CandidateVersion '1.0.40' -Name 'dashboard' -InterruptionTitle 'Sign-off'
) 'Cancelling superseded task ServerTasks-12244352 (dashboard 1.0.35 waits at its Sign-off in uat) so candidate 1.0.40 can run.'
# Refused TaskCancel still yields a named hold (same path Cancel-SupersededWaitingTasks uses after disposition).
$cancelHold739 = New-TaskCancelRefusedEvaluation -Sha 'abc' -ProjectName 'cmdemo1-dashboard' -ReleaseVersion '1.0.35' -EnvironmentName 'uat' -TaskId 'ServerTasks-12244352' -Permission 'TaskCancel'
Test-Case '739: refused cancel hold names TaskCancel and the stale task' @(
    ($cancelHold739.Decision.Flags[0].Evidence[0] -like '*TaskCancel*'),
    ($cancelHold739.Decision.Flags[0].Evidence[0] -like '*ServerTasks-12244352*'),
    (Test-TaskCancelRefusedHoldBody (Format-HeldEvidence -Version '1.0.35' -Sha 'abc' -Target 'uat' -Flags $cancelHold739.Decision.Flags -Name 'dashboard'))
) @($true, $true, $true)

# Restore Invoke-Octopus stub used by later Sign-off-style cases (none) — leave a no-op that records nothing.
function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) { }

# Runbook wait-and-retry when the only busy reason is a short-lived runbook in the target (#583)
Test-Case 'only a runbook to the target is waitable' (Test-BusyOnlyRunbookToTarget @(@{ Kind = 'runbook'; ProjectId = 'P-sys'; EnvironmentId = 'E-uat'; TaskId = 'T-rb' }) 'E-uat' 'E-tdd' 'P-ui') $true
Test-Case 'a deployment to the target is not waitable' (Test-BusyOnlyRunbookToTarget @(@{ Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat' }) 'E-uat' 'E-tdd' 'P-ui') $false
Test-Case 'ui in another environment is not waitable' (Test-BusyOnlyRunbookToTarget @(@{ Kind = 'deployment'; ProjectId = 'P-ui'; EnvironmentId = 'E-uat' }) 'E-prod' 'E-tdd' 'P-ui') $false
Test-Case 'refused Sign-off beside a runbook stays waitable' (Test-BusyOnlyRunbookToTarget @($refusedBusy, @{ Kind = 'runbook'; ProjectId = 'P-sys'; EnvironmentId = 'E-uat'; TaskId = 'T-rb' }) 'E-uat' 'E-tdd' 'P-ui') $true
Test-Case 'nothing active is not waitable' (Test-BusyOnlyRunbookToTarget @() 'E-uat' 'E-tdd' 'P-ui') $false

$runbookWaitState = @{ PauseCount = 0; RelistCalled = $false; Logs = [Collections.Generic.List[string]]::new() }
$noopPause = { param([int] $Seconds) $runbookWaitState.PauseCount++ }.GetNewClosure()
$captureLog = { param([string] $Message) $runbookWaitState.Logs.Add($Message) }.GetNewClosure()

$runbookWaitState.PauseCount = 0; $runbookWaitState.Logs.Clear()
$runbookThenClear = [Collections.Queue]::new()
$runbookThenClear.Enqueue(@())
$waitClear = Wait-BusyRunbookClear -Items @(@{ Kind = 'runbook'; ProjectId = 'Projects-982'; EnvironmentId = 'E-uat'; TaskId = 'ServerTasks-1' }) `
    -TargetEnvironmentId 'E-uat' -FirstEnvironmentId 'E-tdd' -ProjectId 'P-ui' -EnvironmentName 'uat' `
    -GetBusyItems { $runbookThenClear.Dequeue() }.GetNewClosure() -Pause $noopPause -RetrySeconds 1 -RetryLimit 3 -WriteLog $captureLog
Test-Case 'runbook wait then clear: Cleared' $waitClear.Cleared $true
Test-Case 'runbook wait then clear: no Busy' ([bool] $waitClear.Busy) $false
Test-Case 'runbook wait then clear: paused once' $runbookWaitState.PauseCount 1
Test-Case 'runbook wait then clear: log names project environment task' @(
    ($runbookWaitState.Logs[0] -like '*Projects-982*'),
    ($runbookWaitState.Logs[0] -like '*uat*'),
    ($runbookWaitState.Logs[0] -like '*ServerTasks-1*')
) @($true, $true, $true)

$runbookWaitState.PauseCount = 0; $runbookWaitState.Logs.Clear()
$stillRunning = @(@{ Kind = 'runbook'; ProjectId = 'Projects-982'; EnvironmentId = 'E-uat'; TaskId = 'ServerTasks-2' })
$waitExhaustedThrew = $false
$waitExhausted = $null
try {
    $waitExhausted = Wait-BusyRunbookClear -Items $stillRunning -TargetEnvironmentId 'E-uat' -FirstEnvironmentId 'E-tdd' -ProjectId 'P-ui' -EnvironmentName 'uat' `
        -GetBusyItems { $stillRunning }.GetNewClosure() -Pause $noopPause -RetrySeconds 1 -RetryLimit 3 -WriteLog $captureLog
} catch { $waitExhaustedThrew = $true }
Test-Case 'runbook still busy after budget: does not throw' $waitExhaustedThrew $false
Test-Case 'runbook still busy after budget: Exhausted' $waitExhausted.Exhausted $true
Test-Case 'runbook still busy after budget: Busy kept' $waitExhausted.Busy 'a runbook of project Projects-982 to the target environment is not finished (task ServerTasks-2)'
Test-Case 'runbook still busy after budget: paused RetryLimit times' $runbookWaitState.PauseCount 3

$runbookWaitState.PauseCount = 0; $runbookWaitState.Logs.Clear(); $runbookWaitState.RelistCalled = $false
$waitDeploy = Wait-BusyRunbookClear -Items @(@{ Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat'; TaskId = 'ServerTasks-3' }) `
    -TargetEnvironmentId 'E-uat' -FirstEnvironmentId 'E-tdd' -ProjectId 'P-ui' -EnvironmentName 'uat' `
    -GetBusyItems { $runbookWaitState.RelistCalled = $true; @() }.GetNewClosure() `
    -Pause { param([int] $Seconds) $runbookWaitState.PauseCount++; throw 'pause must not run for a deployment' }.GetNewClosure() `
    -RetrySeconds 1 -RetryLimit 3 -WriteLog $captureLog
Test-Case 'running deployment blocks at once: not Cleared' $waitDeploy.Cleared $false
Test-Case 'running deployment blocks at once: not Exhausted' $waitDeploy.Exhausted $false
Test-Case 'running deployment blocks at once: Busy names deployment' $waitDeploy.Busy 'a deployment of project P-dash to the target environment is not finished (task ServerTasks-3)'
Test-Case 'running deployment blocks at once: no pause' $runbookWaitState.PauseCount 0
Test-Case 'running deployment blocks at once: no re-list' $runbookWaitState.RelistCalled $false

# Real re-list path: script-scope Octopus helpers (not passed in). A GetNewClosure on GetBusyItems would hide them (#589).
$space = 'Spaces-test'
$heldIssues = @()
$projectIdByDeployable = @{}
$environmentIdByName = @{ uat = 'E-uat' }
$releaseVersionCache = @{}
$script:octopusRelistPhase = 0
function Get-OctopusAll([string] $Path) {
    if ($Path -notlike '*/tasks?*') { throw "unexpected Get-OctopusAll $Path" }
    if ($Path -like '*states=Cancelling*') { return @() }
    $script:octopusRelistPhase++
    if ($script:octopusRelistPhase -eq 1) {
        return @(@{
                Id        = 'ServerTasks-rb'
                Name      = 'RunbookRun'
                State     = 'Executing'
                Arguments = @{ RunbookRunId = 'RunbookRuns-1' }
            })
    }
    @()
}
function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    if ($Path -eq '/api/Spaces-test/runbookRuns/RunbookRuns-1') {
        return @{ ProjectId = 'Projects-982'; EnvironmentId = 'E-uat' }
    }
    throw "unexpected Invoke-Octopus $Path"
}
$listedOnce = Get-ActiveBusyItems
Test-Case 'Get-ActiveBusyItems: kind project task from script-scope Octopus' @(
    $listedOnce.Items[0].Kind, $listedOnce.Items[0].ProjectId, $listedOnce.Items[0].TaskId, $listedOnce.ActiveTaskIds[0]
) @('runbook', 'Projects-982', 'ServerTasks-rb', 'ServerTasks-rb')
Test-Case 'Get-ActiveBusyItems: copies State onto the busy item' $listedOnce.Items[0].State 'Executing'

# Deploy path: TaskId, State and ReleaseVersion are filled so Get-BusyReason can name them (#701).
$script:octopusRelistPhase = 0
function Get-OctopusAll([string] $Path) {
    if ($Path -notlike '*/tasks?*') { throw "unexpected Get-OctopusAll $Path" }
    if ($Path -like '*states=Cancelling*') { return @() }
    @(@{
            Id        = 'ServerTasks-dep'
            Name      = 'Deploy'
            State     = 'Waiting'
            QueueTime = '2026-11-15T01:00:00.000Z'
            Arguments = @{ DeploymentId = 'Deployments-1' }
        })
}
function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    if ($Path -eq '/api/Spaces-test/deployments/Deployments-1') {
        return @{ ProjectId = 'Projects-981'; EnvironmentId = 'E-prod'; ReleaseId = 'Releases-211' }
    }
    if ($Path -eq '/api/Spaces-test/releases/Releases-211') {
        return @{ Version = '1.0.211' }
    }
    throw "unexpected Invoke-Octopus $Path"
}
$listedDeploy = Get-ActiveBusyItems
Test-Case 'Get-ActiveBusyItems: deploy item names task state and release' @(
    $listedDeploy.Items[0].Kind, $listedDeploy.Items[0].TaskId, $listedDeploy.Items[0].State, $listedDeploy.Items[0].ReleaseVersion
) @('deployment', 'ServerTasks-dep', 'Waiting', '1.0.211')
Test-Case 'Get-ActiveBusyItems: copies QueueTime onto the busy item' $listedDeploy.Items[0].QueueTime '2026-11-15T01:00:00.000Z'
Test-Case 'Get-ActiveBusyItems: deploy busy reason includes task release state' (
    Get-BusyReason -Items $listedDeploy.Items -TargetEnvironmentId 'E-prod' -FirstEnvironmentId 'E-tdd' -ProjectId 'P-system' -Name 'system'
) 'a deployment of project Projects-981 to the target environment is not finished (task ServerTasks-dep, release 1.0.211, state Waiting)'

# Restore the runbook stub for the re-list wait test below.
$script:octopusRelistPhase = 0
function Get-OctopusAll([string] $Path) {
    if ($Path -notlike '*/tasks?*') { throw "unexpected Get-OctopusAll $Path" }
    if ($Path -like '*states=Cancelling*') { return @() }
    $script:octopusRelistPhase++
    if ($script:octopusRelistPhase -eq 1) {
        return @(@{
                Id        = 'ServerTasks-rb'
                Name      = 'RunbookRun'
                State     = 'Executing'
                Arguments = @{ RunbookRunId = 'RunbookRuns-1' }
            })
    }
    @()
}
function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    if ($Path -eq '/api/Spaces-test/runbookRuns/RunbookRuns-1') {
        return @{ ProjectId = 'Projects-982'; EnvironmentId = 'E-uat' }
    }
    throw "unexpected Invoke-Octopus $Path"
}

$script:octopusRelistPhase = 0
$runbookWaitState.PauseCount = 0; $runbookWaitState.Logs.Clear()
$waitScriptScopeThrew = $false
$waitScriptScope = $null
try {
    # Same shape as the main flow: plain scriptblock calling Get-ActiveBusyItemsMarked (no GetNewClosure).
    $waitScriptScope = Wait-BusyRunbookClear -Items @(@{ Kind = 'runbook'; ProjectId = 'Projects-982'; EnvironmentId = 'E-uat'; TaskId = 'ServerTasks-rb' }) `
        -TargetEnvironmentId 'E-uat' -FirstEnvironmentId 'E-tdd' -ProjectId 'P-ui' -EnvironmentName 'uat' `
        -GetBusyItems { @((Get-ActiveBusyItemsMarked).Items) } -Pause $noopPause -RetrySeconds 1 -RetryLimit 3 -WriteLog $captureLog
} catch { $waitScriptScopeThrew = $true; $waitScriptScope = @{ Cleared = $false; Busy = $_.Exception.Message } }
Test-Case 'runbook re-list via script-scope helpers: does not throw' $waitScriptScopeThrew $false
Test-Case 'runbook re-list via script-scope helpers: Cleared after Octopus empty' $waitScriptScope.Cleared $true
Test-Case 'runbook re-list via script-scope helpers: no Busy' ([bool] $waitScriptScope.Busy) $false
Test-Case 'runbook re-list via script-scope helpers: paused twice (still busy then clear)' $runbookWaitState.PauseCount 2

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

# Failed retry (2026-11-24, dashboard 1.0.839 prod failed on a transient npm ECONNRESET): every deployment to the target
# Failed or TimedOut, at most $FailedDeploymentRetryLimit of them: offered again. Canceled stays a person's no.
function Select-Retry($rels, $deps, $states, $blocker = '') {
    Select-Candidate -Environments $envs3 -Releases $rels -GetDeployments { param($id) @($deps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState { param($d) $states[$d.TaskId] }.GetNewClosure() -GetRetryBlocker { param($d) $blocker }.GetNewClosure()
}
Test-Case 'failed retry: one failed is retried' (Get-FailedTargetRetry -TargetStates @('Failed')).Retry $true
Test-Case 'failed retry: timed out counts as failed' (Get-FailedTargetRetry -TargetStates @('TimedOut', 'Failed')).Retry $true
Test-Case 'failed retry: limit reached is not retried' (Get-FailedTargetRetry -TargetStates @('Failed', 'Failed', 'Failed')).Retry $false
Test-Case 'failed retry: a canceled one is a no' (Get-FailedTargetRetry -TargetStates @('Failed', 'Canceled')).Retry $false
Test-Case 'failed retry: an executing one is not retried' (Get-FailedTargetRetry -TargetStates @('Failed', 'Executing')).Retry $false
Test-Case 'failed retry: success is not retried' (Get-FailedTargetRetry -TargetStates @('Success')).Retry $false
Test-Case 'failed retry: none is not a retry' (Get-FailedTargetRetry -TargetStates @()).Retry $false
$c = Select-Retry @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R3' 'E3' '30' 't3p'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u'), (New-Dep 'R2' 'E3' '07' 't2p')) @{ t3 = 'Success'; t3u = 'Success'; t3p = 'Failed'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success' }
Test-Case 'failed prod deployment: offered to prod again' @($c.Release.Id, $c.Target.Name, $c.Retry) @('R3', 'prod', 1)
Test-Case 'failed prod deployment: the note says retry 1' (@($c.Notes | Where-Object { $_ -like '*offered to prod again after 1 failed deployment there (retry 1 of 2)*' }).Count) 1
$c = Select-Retry @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R3' 'E3' '30' 't3p'), (New-Dep 'R3' 'E3' '35' 't3p2'), (New-Dep 'R3' 'E3' '40' 't3p3'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u'), (New-Dep 'R2' 'E3' '07' 't2p')) @{ t3 = 'Success'; t3u = 'Success'; t3p = 'Failed'; t3p2 = 'Failed'; t3p3 = 'TimedOut'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success' }
Test-Case 'three failed prod deployments: not offered again, nothing newer for uat' $c.Release $null
Test-Case 'three failed prod deployments: the note names the limit' (@($c.Notes | Where-Object { $_ -like '*retry limit (2) is reached*' }).Count) 1
$c = Select-Retry @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R3' 'E3' '30' 't3p'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u'), (New-Dep 'R2' 'E3' '07' 't2p')) @{ t3 = 'Success'; t3u = 'Success'; t3p = 'Canceled'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success' }
Test-Case 'canceled prod deployment: still not recreated' $c.Release $null
$c = Select-Retry @($r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u')) @{ t3 = 'Success'; t3u = 'Failed' }
Test-Case 'failed uat deployment: offered to uat again' @($c.Release.Id, $c.Target.Name, $c.Retry) @('R3', 'uat', 1)
$c = Select-Retry @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R2' 'E1' '05' 't2')) @{ t3 = 'Success'; t2 = 'Success' }
Test-Case 'a fresh candidate has Retry 0' $c.Retry 0

$c = Select-Retry @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R3' 'E3' '30' 't3p'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u'), (New-Dep 'R2' 'E3' '07' 't2p')) @{ t3 = 'Success'; t3u = 'Success'; t3p = 'Failed'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success' } "its Sign-off was answered 'Abort'"
Test-Case 'failed prod deployment a person aborted: not offered again' $c.Release $null
Test-Case 'failed prod deployment a person aborted: the note says why' (@($c.Notes | Where-Object { $_ -like "*not offered again: its Sign-off was answered 'Abort'*" }).Count) 1
$c = Select-With @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R3' 'E3' '30' 't3p'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u'), (New-Dep 'R2' 'E3' '07' 't2p')) @{ t3 = 'Success'; t3u = 'Success'; t3p = 'Failed'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success' }
Test-Case 'failed prod deployment without a blocker check: not retried (fail closed)' $c.Release $null
$c = Select-Retry @($r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R3' 'E2' '25' 't3u2')) @{ t3 = 'Success'; t3u = 'Failed'; t3u2 = 'Success' }
Test-Case 'failed then succeeded in uat: goes on to prod, not to uat again' @($c.Release.Id, $c.Target.Name, $c.Retry) @('R3', 'prod', 0)
# Get-RetryBlocker: only this workflow's deployment whose only interruption is its Sign-off answered Proceed.
$ownDep = @{ Id = 'Deployments-59369'; Comments = "${PromotionMarker}: https://example/run"; TaskId = 'ServerTasks-1' }
$signOff = { param($result, $pending = $false) [pscustomobject] @{ Type = 'ManualIntervention'; Title = 'Sign-off'; IsPending = $pending; Form = [pscustomobject] @{ Values = [pscustomobject] @{ Result = $result; Notes = 'x' } } } }
Test-Case 'retry blocker: own deployment, Sign-off Proceed: none' (Get-RetryBlocker -Deployment $ownDep -Interruptions @((& $signOff 'Proceed'))) ''
Test-Case 'retry blocker: own deployment, no interruption: none' (Get-RetryBlocker -Deployment $ownDep -Interruptions @()) ''
Test-Case 'retry blocker: Sign-off answered Abort' (Get-RetryBlocker -Deployment $ownDep -Interruptions @((& $signOff 'Abort'))) "its Sign-off was answered 'Abort'"
Test-Case 'retry blocker: Sign-off still pending' (Get-RetryBlocker -Deployment $ownDep -Interruptions @((& $signOff '' $true))) 'its Sign-off is still pending'
Test-Case 'retry blocker: guided failure' (Get-RetryBlocker -Deployment $ownDep -Interruptions @((& $signOff 'Proceed'), [pscustomobject] @{ Type = 'GuidedFailure'; Title = 'Deploy failed'; IsPending = $false; Form = $null })) "its task has the interruption 'Deploy failed' (GuidedFailure)"
Test-Case 'retry blocker: another manual intervention' (Get-RetryBlocker -Deployment $ownDep -Interruptions @([pscustomobject] @{ Type = 'ManualIntervention'; Title = 'Approve'; IsPending = $false; Form = $null })) "its task has the interruption 'Approve' (ManualIntervention)"
Test-Case 'retry blocker: a person created the deployment' (Get-RetryBlocker -Deployment @{ Id = 'Deployments-1'; Comments = 'by hand' } -Interruptions @()) 'deployment Deployments-1 was not created by this workflow'
Test-Case 'retry blocker: no comments at all' (Get-RetryBlocker -Deployment @{ Id = 'Deployments-2' } -Interruptions @()) 'deployment Deployments-2 was not created by this workflow'

# Health window first (2026-11-24): tdd got a new dashboard release every 5 to 10 minutes and the newest was always the
# candidate, so its 10-minute window never closed. The newest release whose window is complete wins; else the newest.
function Select-Window($rels, $deps, $states, $complete, $prefer = @()) {
    Select-Candidate -Environments $envs3 -Releases $rels -GetDeployments { param($id) @($deps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState { param($d) $states[$d.TaskId] }.GetNewClosure() -PreferHeld $prefer -GetWindowComplete { param($r, $p) [bool] $complete[$r.Id] }.GetNewClosure()
}
$wDeps = @((New-Dep 'R1' 'E1' '01' 't1'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R3' 'E1' '10' 't3'))
$wStates = @{ t1 = 'Success'; t2 = 'Success'; t3 = 'Success' }
$c = Select-Window @($r1, $r2, $r3) $wDeps $wStates @{ R1 = $true; R2 = $true; R3 = $false }
Test-Case 'window first: newest complete release goes to uat' @($c.Release.Id, $c.Target.Name) @('R2', 'uat')
Test-Case 'window first: the note names the newer one in its window' (@($c.Notes | Where-Object { $_ -like 'newer 3 in tdd still in the health window: 2, whose window is complete*' }).Count) 1
$c = Select-Window @($r1, $r2, $r3) $wDeps $wStates @{ R1 = $false; R2 = $false; R3 = $false }
Test-Case 'window first: none complete takes the newest (it takes the reads)' $c.Release.Id 'R3'
Test-Case 'window first: none complete adds no window note' (@($c.Notes | Where-Object { $_ -like '*still in the health window*' }).Count) 0
$c = Select-Window @($r1, $r2, $r3) $wDeps $wStates @{ R1 = $true; R2 = $true; R3 = $true }
Test-Case 'window first: newest complete is the newest' $c.Release.Id 'R3'
$c = Select-Window @($r1, $r2, $r3) @((New-Dep 'R1' 'E1' '01' 't1'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '07' 't2u'), (New-Dep 'R2' 'E3' '08' 't2p'), (New-Dep 'R3' 'E1' '10' 't3')) @{ t1 = 'Success'; t2 = 'Success'; t2u = 'Success'; t2p = 'Success'; t3 = 'Success' } @{ R1 = $true; R2 = $true; R3 = $false }
Test-Case 'window first: never older than what runs in uat (falls back to the newest)' @($c.Release.Id, $c.Target.Name) @('R3', 'uat')
$c = Select-Window @($r1, $r2, $r3) $wDeps $wStates @{ R1 = $true; R2 = $true; R3 = $false } @(@{ Version = '3'; Environment = 'uat' })
Test-Case 'window first: a preferred pipeline hold keeps its place' $c.Release.Id 'R3'
$c = Select-Window @($r2, $r3) @((New-Dep 'R3' 'E1' '10' 't3'), (New-Dep 'R3' 'E2' '20' 't3u'), (New-Dep 'R2' 'E1' '05' 't2'), (New-Dep 'R2' 'E2' '06' 't2u')) @{ t3 = 'Success'; t3u = 'Success'; t2 = 'Success'; t2u = 'Success' } @{ R2 = $true; R3 = $false }
Test-Case 'window first: the uat window decides prod too' @($c.Release.Id, $c.Target.Name) @('R2', 'prod')

# Stored-read window (no new read) and the pause when the window passed but the verdict still waits.
Test-Case 'stored window: health none is complete' (Test-HealthWindowComplete -HealthRequired $false -Finished $null -Now $t0 -Reads @()) $true
Test-Case 'stored window: no finish time is not complete' (Test-HealthWindowComplete -HealthRequired $true -Finished $null -Now $t0 -Reads @()) $false
Test-Case 'stored window: two Healthy reads 5 min apart, later after 10 min' (Test-HealthWindowComplete -HealthRequired $true -Finished $t0 -Now $t0.AddMinutes(20) -Reads @(@{ At = $t0.AddMinutes(4); Status = 'Healthy' }, @{ At = $t0.AddMinutes(11); Status = 'Healthy' })) $true
Test-Case 'stored window: later read seconds before 10 min is not complete' (Test-HealthWindowComplete -HealthRequired $true -Finished $t0 -Now $t0.AddMinutes(20) -Reads @(@{ At = $t0.AddMinutes(0.1); Status = 'Healthy' }, @{ At = $t0.AddMinutes(9.9); Status = 'Healthy' })) $false
Test-Case 'stored window: an Unhealthy read is not complete' (Test-HealthWindowComplete -HealthRequired $true -Finished $t0 -Now $t0.AddMinutes(20) -Reads @(@{ At = $t0.AddMinutes(4); Status = 'Healthy' }, @{ At = $t0.AddMinutes(11); Status = 'Unhealthy' })) $false
# dashboard 1.0.855 (2026-11-24): reads 15:39:01 and 15:48:48 UTC, deployment finished about 15:38:55: no wait before.
$f855 = [datetime]::Parse('2026-11-24T15:38:55Z').ToUniversalTime()
$reads855 = @(@{ At = [datetime]::Parse('2026-11-24T15:39:01Z').ToUniversalTime(); Status = 'Healthy' }, @{ At = [datetime]::Parse('2026-11-24T15:48:48Z').ToUniversalTime(); Status = 'Healthy' })
Test-Case 'health wait: 1.0.855, later read seconds early: wait to the window end' (Get-HealthWaitSeconds -Finished $f855 -Now ([datetime]::Parse('2026-11-24T15:48:49Z').ToUniversalTime()) -Reads $reads855 -MaxSeconds 600) 11
Test-Case 'health wait: one read 3 min in: wait to 10 min' (Get-HealthWaitSeconds -Finished $t0 -Now $t0.AddMinutes(3) -Reads @(@{ At = $t0.AddMinutes(3); Status = 'Healthy' }) -MaxSeconds 600) 425
Test-Case 'health wait: one read 9 min in: wait for the 5-minute gap' (Get-HealthWaitSeconds -Finished $t0 -Now $t0.AddMinutes(9) -Reads @(@{ At = $t0.AddMinutes(9); Status = 'Healthy' }) -MaxSeconds 600) 305
Test-Case 'health wait: two reads 2 min apart after the window: wait for the gap' (Get-HealthWaitSeconds -Finished $t0 -Now $t0.AddMinutes(13) -Reads @(@{ At = $t0.AddMinutes(11); Status = 'Healthy' }, @{ At = $t0.AddMinutes(13); Status = 'Healthy' }) -MaxSeconds 600) 185
Test-Case 'health wait: one read just after finishing: too long for the budget' (Get-HealthWaitSeconds -Finished $t0 -Now $t0 -Reads @(@{ At = $t0; Status = 'Healthy' }) -MaxSeconds 300) (-1)
Test-Case 'health wait: no budget left: no wait' (Get-HealthWaitSeconds -Finished $t0 -Now $t0.AddMinutes(9) -Reads @(@{ At = $t0.AddMinutes(9); Status = 'Healthy' }) -MaxSeconds 0) (-1)
Test-Case 'health wait: verdict ok: no wait' (Get-HealthWaitSeconds -Finished $t0 -Now $t0.AddMinutes(12) -Reads @(@{ At = $t0.AddMinutes(4); Status = 'Healthy' }, @{ At = $t0.AddMinutes(12); Status = 'Healthy' }) -MaxSeconds 600) (-1)
Test-Case 'health wait: an Unhealthy read: no wait (it flags)' (Get-HealthWaitSeconds -Finished $t0 -Now $t0.AddMinutes(12) -Reads @(@{ At = $t0.AddMinutes(12); Status = 'Unhealthy' }) -MaxSeconds 600) (-1)
Test-Case 'health wait: no read since finishing (not live): no wait' (Get-HealthWaitSeconds -Finished $t0 -Now $t0.AddMinutes(4) -Reads @(@{ At = $t0.AddMinutes(-3); Status = 'Healthy' }) -MaxSeconds 600) (-1)
# Environment window (2026-11-24, second fix): tdd gets a new dashboard release every 5 to 10 minutes, so a release's own
# reads never span 10 minutes (runs 45442775877 and 45445735479 skipped every read of 1.0.875 and 1.0.877). Its own
# reads plus the environment's reads since it finished decide, once it was read Healthy while live.
$own1 = @(@{ At = $t0.AddMinutes(2); Status = 'Healthy' })
$env1 = @(@{ At = $t0.AddMinutes(-4); Status = 'Unhealthy'; Commit = 'old' }, @{ At = $t0.AddMinutes(7); Status = 'Healthy'; Commit = 'newer' }, @{ At = $t0.AddMinutes(12); Status = 'Healthy'; Commit = 'newest' })
Test-Case 'window reads: own and environment since finishing, in order' @(Get-WindowReads -Own $own1 -Environment $env1 -Finished $t0 | ForEach-Object { $_.At.ToString('HH:mm') }) @('04:02', '04:07', '04:12')
Test-Case 'window reads: a release superseded in tdd closes its window on the environment reads' (Get-HealthVerdict -Finished $t0 -Now $t0.AddMinutes(13) -Reads @(Get-WindowReads -Own $own1 -Environment $env1 -Finished $t0)) 'ok'
Test-Case 'window reads: an Unhealthy environment read since finishing fails it' (Get-HealthVerdict -Finished $t0 -Now $t0.AddMinutes(13) -Reads @(Get-WindowReads -Own $own1 -Environment (@($env1) + @(@{ At = $t0.AddMinutes(13); Status = 'Unhealthy'; Commit = 'newest' })) -Finished $t0)) 'fail'
Test-Case 'window reads: an older Unhealthy read before finishing does not count' (@(Get-WindowReads -Own @() -Environment $env1 -Finished $t0 | Where-Object { $_.Status -ne 'Healthy' }).Count) 0
Test-Case 'live seen: an own Healthy read since finishing' (Test-LiveHealthSeen -Own $own1 -Environment @() -Finished $t0 -Commit 'abc') $true
Test-Case 'live seen: an environment read naming its commit' (Test-LiveHealthSeen -Own @() -Environment @(@{ At = $t0.AddMinutes(1); Status = 'Healthy'; Commit = 'abc' }) -Finished $t0 -Commit 'abc') $true
Test-Case 'live seen: only newer commits read: not seen' (Test-LiveHealthSeen -Own @() -Environment $env1 -Finished $t0 -Commit 'abc') $false
Test-Case 'live seen: its own read before finishing does not count' (Test-LiveHealthSeen -Own @(@{ At = $t0.AddMinutes(-1); Status = 'Healthy' }) -Environment @() -Finished $t0 -Commit 'abc') $false
Test-Case 'live seen: an Unhealthy own read is not seen' (Test-LiveHealthSeen -Own @(@{ At = $t0.AddMinutes(1); Status = 'Unhealthy' }) -Environment @() -Finished $t0 -Commit 'abc') $false
Test-Case 'live seen: no commit known: environment reads do not count' (Test-LiveHealthSeen -Own @() -Environment @(@{ At = $t0.AddMinutes(1); Status = 'Healthy'; Commit = '' }) -Finished $t0 -Commit '') $false
Test-Case 'environment reads: the last day only' @(Limit-EnvironmentReads -Reads @(@{ At = $t0.AddHours(-25); Status = 'Healthy' }, @{ At = $t0.AddHours(-1); Status = 'Healthy' }) -Now $t0 | ForEach-Object { $_.At.ToString('HH:mm') }) @('03:00')
Test-Case 'decision: window closed but never read live: wait' (Get-PromotionDecision -Facts (New-Facts @{ LiveHealthSeen = $false })).Decision 'wait'
Test-Case 'decision: never read live names why' ((Get-PromotionDecision -Facts (New-Facts @{ LiveHealthSeen = $false })).Waiting -join '|') 'health window: no Healthy read of this release while it was live in the previous environment'
Test-Case 'decision: read live and window closed: promote' (Get-PromotionDecision -Facts (New-Facts @{ LiveHealthSeen = $true })).Decision 'promote'
Test-Case 'decision: health not required ignores live seen' (Get-PromotionDecision -Facts (New-Facts @{ LiveHealthSeen = $false; HealthRequired = $false })).Decision 'promote'
# Stream: a release every 6 minutes, a promoter read every 5 minutes. Before, no release ever closed its window. Now the
# newest release read live whose window is closed by the environment reads qualifies within about 15 minutes.
$streamEnv = [Collections.Generic.List[object]]::new(); $streamOwn = @{}
$finishedOf = @{}; for ($k = 0; $k -lt 8; $k++) { $finishedOf["S$k"] = $t0.AddMinutes(6 * $k) }
function Get-LiveRelease([datetime] $at) { $live = 'S0'; foreach ($k in 0..7) { if ($finishedOf["S$k"] -le $at) { $live = "S$k" } }; $live }
$qualifiedAt = $null; $qualified = $null
for ($m = 1; $m -le 45; $m += 5) {
    $at = $t0.AddMinutes($m); $live = Get-LiveRelease $at
    $streamEnv.Add(@{ At = $at; Status = 'Healthy'; Commit = $live })
    if (-not $streamOwn.ContainsKey($live)) { $streamOwn[$live] = @() }
    $streamOwn[$live] = @($streamOwn[$live]) + @(@{ At = $at; Status = 'Healthy' })
    $ownOnly = @($finishedOf.Keys | Where-Object { $streamOwn.ContainsKey($_) -and (Get-HealthVerdict -Finished $finishedOf[$_] -Now $at -Reads @($streamOwn[$_])) -eq 'ok' })
    if ($ownOnly.Count -gt 0) { $ownOnlyOk = $true }
    $ok = @($finishedOf.Keys | Sort-Object { $finishedOf[$_] } -Descending | Where-Object {
            (Test-LiveHealthSeen -Own @($streamOwn[$_] | Where-Object { $_ }) -Environment @($streamEnv) -Finished $finishedOf[$_] -Commit $_) -and
            (Test-HealthWindowComplete -HealthRequired $true -Finished $finishedOf[$_] -Now $at -Reads @(Get-WindowReads -Own @($streamOwn[$_] | Where-Object { $_ }) -Environment @($streamEnv) -Finished $finishedOf[$_]))
        } | Select-Object -First 1)
    if ($ok.Count -gt 0 -and -not $qualifiedAt) { $qualifiedAt = $m; $qualified = $ok[0] }
}
Test-Case 'stream: own reads alone never close a window' ([bool] (Get-Variable ownOnlyOk -ValueOnly -ErrorAction SilentlyContinue)) $false
Test-Case 'stream: a release qualifies on the environment window within 16 minutes' @($qualified, ($qualifiedAt -le 16)) @('S0', $true)
# A read counts for a release only while its commit runs in the previous environment.
Test-Case 'live commit: same commit matches' (Test-LiveCommitMatches -BuildPath '/build-facts.json' -LiveCommit 'abc' -ReleaseCommit 'abc') $true
Test-Case 'live commit: a newer tdd release runs: no read' (Test-LiveCommitMatches -BuildPath '/build-facts.json' -LiveCommit 'def' -ReleaseCommit 'abc') $false
Test-Case 'live commit: unreadable: no read' (Test-LiveCommitMatches -BuildPath '/_build' -LiveCommit '' -ReleaseCommit 'abc') $false
Test-Case 'live commit: no build path (system): read' (Test-LiveCommitMatches -BuildPath '' -LiveCommit '' -ReleaseCommit 'abc') $true
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

# Default channel only (issue #655): Pull requests channel releases are never promoted or treated as current.
$chDefault = 'Channels-Default'
$chPr = 'Channels-PR'
Test-Case 'Default channel ids come from channels named Default' @(Get-DefaultChannelIds @(@{ Id = $chDefault; Name = 'Default' }, @{ Id = $chPr; Name = 'Pull requests' })) @($chDefault)
Test-Case 'no Default channel yields no ids' @(Get-DefaultChannelIds @(@{ Id = $chPr; Name = 'Pull requests' })).Count 0
Test-Case 'Default channel release is kept' (Test-DefaultChannelRelease @{ Id = 'R1'; ChannelId = $chDefault; Version = '2.4.100' } @($chDefault)) $true
Test-Case 'Pull requests channel release is ignored' (Test-DefaultChannelRelease @{ Id = 'R2'; ChannelId = $chPr; Version = '2.4.999-pr.12' } @($chDefault)) $false
Test-Case 'release without ChannelId is ignored' (Test-DefaultChannelRelease @{ Id = 'R3'; Version = '2.4.100' } @($chDefault)) $false
Test-Case 'PR version string still parses as Major.Minor.Patch (why channel filter matters)' ((ConvertTo-ReleaseVersion '2.4.999-pr.12').ToString()) '2.4.999'
$rPr655 = @{ Id = 'Rpr'; Version = '2.4.999-pr.12'; ChannelId = $chPr; Assembled = '2026-10-14T09:00:00+00:00' }
$rDef655 = @{ Id = 'Rdef'; Version = '2.4.100'; ChannelId = $chDefault; Assembled = '2026-10-14T08:00:00+00:00' }
$rUat655 = @{ Id = 'Ruat'; Version = '2.4.90'; ChannelId = $chDefault; Assembled = '2026-10-14T07:00:00+00:00' }
Test-Case 'Select-DefaultChannelReleases drops Pull requests channel' @(Select-DefaultChannelReleases @($rPr655, $rDef655, $rUat655) @($chDefault) | ForEach-Object Id) @('Rdef', 'Ruat')
$onlyDefault655 = @(Select-DefaultChannelReleases @($rPr655, $rDef655, $rUat655) @($chDefault))
$c = Select-With $onlyDefault655 @((New-Dep 'Rdef' 'E1' '10' 'td'), (New-Dep 'Ruat' 'E1' '05' 'tu'), (New-Dep 'Ruat' 'E2' '06' 'uu'), (New-Dep 'Ruat' 'E3' '07' 'up')) @{ td = 'Success'; tu = 'Success'; uu = 'Success'; up = 'Success' }
Test-Case 'PR-channel release is not promoted; Default channel candidate wins' @($c.Release.Id, $c.Target.Name) @('Rdef', 'uat')
$c = Select-With @($rPr655, $rDef655) @((New-Dep 'Rpr' 'E1' '10' 'tpr'), (New-Dep 'Rdef' 'E1' '05' 'tdef')) @{ tpr = 'Success'; tdef = 'Success' }
Test-Case 'without channel filter a PR version would sort ahead (proves callers must filter)' $c.Release.Id 'Rpr'

# The running release older than the listed releases (issue #314: fworker 1.0.587 held before uat, "no base commit",
# while 1.0.474, about 113 versions back, ran in uat and prod).
$r474 = New-Rel 'Releases-50899' '1.0.474' 1; $r587 = New-Rel 'Releases-51076' '1.0.587' 9
$oldDeps = @((New-Dep 'Releases-50899' 'E2' '20' 'o474u'), (New-Dep 'Releases-50899' 'E3' '30' 'o474p'), (New-Dep 'Releases-50870' 'E2' '10' 'o470u'))
$allDeps = @($oldDeps) + @((New-Dep 'Releases-51076' 'E1' '40' 't587'))
$allStates = @{ o474u = 'Success'; o474p = 'Success'; o470u = 'Success'; t587 = 'Success' }
$allReleases = @{ 'Releases-50899' = $r474; 'Releases-50870' = (New-Rel 'Releases-50870' '1.0.470' 1) }
function New-EnvLookup($deps, $states, $rels, [int] $Total = -1) {
    # GetEnvironmentDeployments, GetRelease and GetTaskState over fixed data; Total: what the listing says it holds.
    @{
        GetEnvironmentDeployments = { param($e, $take) $i = @($deps | Where-Object { $_.EnvironmentId -eq $e } | Sort-Object { [datetimeoffset] $_.Created } -Descending | Select-Object -First $take); @{ Items = $i; Total = $(if ($Total -ge 0) { $Total } else { @($deps | Where-Object { $_.EnvironmentId -eq $e }).Count }) } }.GetNewClosure()
        GetRelease                = { param($id) if (-not $rels.ContainsKey($id)) { throw "404 $id" }; $rels[$id] }.GetNewClosure()
        GetTaskState              = { param($d) $states[$d.TaskId] }.GetNewClosure()
    }
}
$lk = New-EnvLookup $allDeps $allStates $allReleases
# Issue #655: a successful Pull requests channel deployment is not the environment's current Default version.
$prRunningDeps = @((New-Dep 'Rpr' 'E2' '20' 'pru'), (New-Dep 'Ruat' 'E2' '10' 'du'))
$lkPr = New-EnvLookup $prRunningDeps @{ pru = 'Success'; du = 'Success' } @{ 'Rpr' = $rPr655; 'Ruat' = $rUat655 }
$runDef = Get-RunningReleaseByEnvironment -Target $envs3[1] -GetEnvironmentDeployments $lkPr.GetEnvironmentDeployments -GetRelease $lkPr.GetRelease -GetTaskState $lkPr.GetTaskState -DefaultChannelIds @($chDefault)
Test-Case 'running lookup skips Pull requests channel for Default current version' $runDef.Id 'Ruat'
$runUnfiltered = Get-RunningReleaseByEnvironment -Target $envs3[1] -GetEnvironmentDeployments $lkPr.GetEnvironmentDeployments -GetRelease $lkPr.GetRelease -GetTaskState $lkPr.GetTaskState
Test-Case 'running lookup without DefaultChannelIds still returns the newest success' $runUnfiltered.Id 'Rpr'
# The function travels as a value: a closure does not see the script's own functions (run 40239181124).
$byEnvironment = ${function:Get-RunningReleaseByEnvironment}
$outsideLookup = { param($t) & $byEnvironment -Max 100 -Target $t -GetEnvironmentDeployments $lk.GetEnvironmentDeployments -GetRelease $lk.GetRelease -GetTaskState $lk.GetTaskState }.GetNewClosure()
$c = Select-Candidate -Environments $envs3 -Releases @($r587) -GetDeployments { param($id) @($allDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState $lk.GetTaskState -GetRunningOutside $outsideLookup
Test-Case 'running release older than the list: candidate goes to uat with the running release as the base' "$($c.Release.Version)|$($c.Target.Name)|$($c.RunningReleaseId)|$($c.Running.Version)|$($null -eq $c.RunningUnknown)" '1.0.587|uat|Releases-50899|1.0.474|True'
Test-Case 'running release older than the list: the note says how it was found' (@($c.Notes | Where-Object { $_ -like '*running in uat, 1.0.474, is older than the listed releases*' }).Count) 1
# Through uat: prod runs the same old release.
$uatDeps = @($allDeps) + @((New-Dep 'Releases-51076' 'E2' '50' 'u587'))
$lkp = New-EnvLookup $uatDeps ($allStates + @{ u587 = 'Success' }) $allReleases
$c = Select-Candidate -Environments $envs3 -Releases @($r587) -GetDeployments { param($id) @($uatDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState $lkp.GetTaskState -GetRunningOutside { param($t) & $byEnvironment -Max 100 -Target $t -GetEnvironmentDeployments $lkp.GetEnvironmentDeployments -GetRelease $lkp.GetRelease -GetTaskState $lkp.GetTaskState }.GetNewClosure()
Test-Case 'running release older than the list: then prod, against the same old release' @($c.Release.Version, $c.Target.Name, $c.Running.Version) @('1.0.587', 'prod', '1.0.474')
# An old release found outside the list that is newer by version than the candidate still stops it.
$c = Select-Candidate -Environments $envs3 -Releases @($r474) -GetDeployments { param($id) @((New-Dep 'Releases-50899' 'E1' '01' 'x1')) | Where-Object { $_.ReleaseId -eq $id } } -GetTaskState { param($d) 'Success' } -GetRunningOutside { param($t) $r587 }.GetNewClosure()
Test-Case 'running release outside the list that is newer: no candidate' $c.Release $null
# The lookup fails: the candidate is still evaluated, and the evaluation flags "comparison incomplete" with the reason.
$c = Select-Candidate -Environments $envs3 -Releases @($r587) -GetDeployments { param($id) @($allDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState $lk.GetTaskState -GetRunningOutside { param($t) throw "the release running in $($t.Name) was not found: boom" }
Test-Case 'running release lookup that fails: running unknown, with the reason' "$($c.Release.Version)|$($null -eq $c.RunningReleaseId)|$($null -eq $c.Running)|$($c.RunningUnknown)" '1.0.587|True|True|the release running in uat was not found: boom'
$msg = try { Select-Candidate -Environments $envs3 -Releases @($r587) -GetDeployments { param($id) @($allDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState $lk.GetTaskState -GetRunningOutside { param($t) throw 'Response status code does not indicate success: 503' }; 'no throw' } catch { $_.Exception.Message }
Test-Case 'running release lookup whose call fails: the run stops (no hold issue)' $msg 'Response status code does not indicate success: 503'
# Without the lookup (the old behaviour): no running release known.
$c = Select-Candidate -Environments $envs3 -Releases @($r587) -GetDeployments { param($id) @($allDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState $lk.GetTaskState
Test-Case 'running release older than the list, no lookup: unknown base' "$($c.Release.Version)|$($null -eq $c.RunningReleaseId)" '1.0.587|True'

# Get-RunningReleaseByEnvironment
function Run-Lookup($lookup, $target, [int] $Max = 100) { Get-RunningReleaseByEnvironment -Target $target -GetEnvironmentDeployments $lookup.GetEnvironmentDeployments -GetRelease $lookup.GetRelease -GetTaskState $lookup.GetTaskState -Max $Max }
Test-Case 'environment lookup: the newest successful deployment names the running release' (Run-Lookup $lk $envs3[1]).Version '1.0.474'
$lkq = New-EnvLookup (@($allDeps) + @((New-Dep 'Releases-51076' 'E2' '55' 'q587'), (New-Dep 'Releases-51075' 'E2' '54' 'f586'))) ($allStates + @{ q587 = 'Queued'; f586 = 'Failed' }) $allReleases
Test-Case 'environment lookup: newer queued and failed deployments are not running' (Run-Lookup $lkq $envs3[1]).Version '1.0.474'
Test-Case 'environment lookup: nothing deployed there is none' ($null -eq (Run-Lookup $lk @{ Id = 'E9'; Name = 'dev' })) $true
$lkn = New-EnvLookup @((New-Dep 'Releases-50899' 'E2' '20' 'n1')) @{ n1 = 'Failed' } $allReleases
Test-Case 'environment lookup: no success in a whole listing is none' ($null -eq (Run-Lookup $lkn $envs3[1])) $true
$lkb = New-EnvLookup @((New-Dep 'Releases-50899' 'E2' '20' 'b1'), (New-Dep 'Releases-50899' 'E2' '10' 'b2')) @{ b1 = 'Failed'; b2 = 'Success' } $allReleases
$msg = try { Run-Lookup $lkb $envs3[1] -Max 1; 'no throw' } catch { $_.Exception.Message }
Test-Case 'environment lookup: no success among the newest Max of more throws, naming the bound' $msg 'the release running in uat was not found: none of the newest 1 of 2 deployments there succeeded'
$lkr = New-EnvLookup @((New-Dep 'Releases-404' 'E2' '20' 'g1')) @{ g1 = 'Success' } $allReleases
$msg = try { Run-Lookup $lkr $envs3[1]; 'no throw' } catch { $_.Exception.Message }
Test-Case 'environment lookup: a failed release read throws its own error (the run stops)' $msg '404 Releases-404'
$lke = New-EnvLookup @((New-Dep 'Releases-50899' 'E2' '20' 'g2')) @{ g2 = 'Success' } @{ 'Releases-50899' = @{ Version = '1.0.474' } }
$msg = try { Run-Lookup $lke $envs3[1]; 'no throw' } catch { $_.Exception.Message }
Test-Case 'environment lookup: an answer without a release throws a lookup error' $msg 'the release running in uat could not be read: release Releases-50899 of deployment D-Releases-50899-E2-g2'
Test-Case 'environment lookup: the default bound' $RunningLookupDeployments 100
# Recovery: the release that ran before a waiting deployment, outside the list.
$run = Get-RunningRelease -Target $envs3[1] -Releases @($r587) -GetDeployments { param($id) @($allDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState $lk.GetTaskState -GetRunningOutside $outsideLookup
Test-Case 'running release (recovery): found outside the list' $run.Version '1.0.474'
$run = Get-RunningRelease -Target $envs3[1] -Releases @($r587) -GetDeployments { param($id) @($allDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() -GetTaskState $lk.GetTaskState
Test-Case 'running release (recovery): without the lookup none' ($null -eq $run) $true

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

# Comparison from the clone (git diff --name-only --no-renames -z, git log --format=%H%x1f%B%x1e)
function New-Sha([int] $i) { '{0:x40}' -f $i }
function New-GitLog([int] $n) { ((1..$n | ForEach-Object { "$(New-Sha $_)$([char] 0x1f)Change $_ (#$_)`n$([char] 0x1e)" }) -join "`n") + "`n" }
$m = ConvertFrom-GitComparison -NameOnly "src/a.cs`0" -Log (New-GitLog 3) -Count 3 -Status 'ahead'
Test-Case 'complete comparison is known' @($m.Known, $m.Paths, $m.Status) @($true, @('src/a.cs'), 'ahead')
Test-Case 'commits keep their sha and message' @($m.Commits[1].sha, $m.Commits[1].commit.message.Trim()) @((New-Sha 2), 'Change 2 (#2)')
$m = ConvertFrom-GitComparison -NameOnly "src/a.cs`0" -Log (New-GitLog 2) -Count 3 -Status 'ahead'
Test-Case 'fewer commits read than counted is unknown' @($m.Known, $m.Reason) @($false, '2 of 3 commits read')
# ui 2.4.1120 to 2.4.2060: 405 commits and 687 files, over GitHub compare's 250 commits and 300 files
$m = ConvertFrom-GitComparison -NameOnly ((1..687 | ForEach-Object { "src/f$_.cs" }) -join "`0") -Log (New-GitLog 405) -Count 405 -Status 'ahead'
Test-Case 'a 405-commit, 687-file comparison is known whole' @($m.Known, @($m.Commits).Count, @($m.Paths).Count) @($true, 405, 687)
Test-Case 'a rename (no rename detection) counts both names' (ConvertFrom-GitComparison -NameOnly "new.cs`0old.cs`0" -Log (New-GitLog 1) -Count 1 -Status 'ahead').Paths @('new.cs', 'old.cs')
Test-Case 'a path with spaces is kept' (ConvertFrom-GitComparison -NameOnly "docs/a b.md`0" -Log (New-GitLog 1) -Count 1 -Status 'ahead').Paths @('docs/a b.md')
Test-Case 'an empty comparison is known' @((ConvertFrom-GitComparison -NameOnly '' -Log '' -Count 0 -Status 'identical').Known) @($true)
Test-Case 'a message with a separator-like line keeps one commit' @((ConvertFrom-GitComparison -NameOnly '' -Log "$(New-Sha 1)$([char] 0x1f)subject`n`nbody`n$([char] 0x1e)`n" -Count 1 -Status 'ahead').Commits).Count 1

# Pull requests of commits (one batched GraphQL answer)
function New-PullNode($n, [string[]] $labels = @(), $closes = @(), $labelTotal = $null) {
    [pscustomobject] @{ number = $n; title = "t$n"; body = "b$n"; url = "pr$n"
        labels = [pscustomobject] @{ totalCount = ($labelTotal ?? $labels.Count); nodes = @($labels | ForEach-Object { [pscustomobject] @{ name = $_ } }) }
        closingIssuesReferences = [pscustomobject] @{ nodes = @($closes | ForEach-Object { [pscustomobject] @{ number = $_; repository = [pscustomobject] @{ nameWithOwner = 'org/app' } } }) } }
}
$repoNode = [pscustomobject] @{
    c0 = [pscustomobject] @{ associatedPullRequests = [pscustomobject] @{ totalCount = 1; nodes = @(New-PullNode 58 @('Hold') @(16)) } }
    c1 = [pscustomobject] @{ associatedPullRequests = [pscustomobject] @{ totalCount = 0; nodes = @() } }
    c2 = $null
    c3 = [pscustomobject] @{ associatedPullRequests = [pscustomobject] @{ totalCount = 7; nodes = @(1..5 | ForEach-Object { New-PullNode $_ }) } }
    c4 = [pscustomobject] @{ associatedPullRequests = [pscustomobject] @{ totalCount = 1; nodes = @(New-PullNode 60 @('a') @() 80) } }
}
$g = ConvertFrom-CommitPullsGraph -Repository $repoNode -Shas @('s0', 's1', 's2', 's3', 's4')
Test-Case 'graph: a pull request is answered like GET commits/<sha>/pulls' @($g['s0'].Pulls[0].number, $g['s0'].Pulls[0].html_url, $g['s0'].Pulls[0].labels[0].name, $g['s0'].Error) @(58, 'pr58', 'Hold', $null)
Test-Case 'graph: closing references by pull request' @($g['s0'].Closing[58] | ForEach-Object { "$($_.Repo)#$($_.Number)" }) @('org/app#16')
Test-Case 'graph: a commit without a pull request has none and no error' @(@($g['s1'].Pulls).Count, $g['s1'].Error) @(0, $null)
Test-Case 'graph: an unknown commit is an error' $g['s2'].Error 'commit s2 not found'
Test-Case 'graph: more pull requests than read is an error' $g['s3'].Error '7 pull requests of s3 (more than 5)'
Test-Case 'graph: labels not read whole is an error' $g['s4'].Error 'labels of #60 not read whole'
$h = Get-HoldFacts -Commits @([pscustomobject] @{ sha = 's0'; commit = [pscustomobject] @{ message = 'x' } }) -Repo 'org/app' -GetPulls { param($s) $e = $g[$s]; if ($e.Error) { throw $e.Error }; $e.Pulls } -GetClosing { param($n) $g['s0'].Closing[[int] $n] } -GetItem { param($r, $n) @{ Number = $n; Url = "i$n"; Labels = @() } }
Test-Case 'graph answers feed the hold facts: the Hold pull request flags' (Flags (New-Facts @{ HoldItems = $h.Items })) @('Hold label')
$h = Get-HoldFacts -Commits @([pscustomobject] @{ sha = 's3'; commit = [pscustomobject] @{ message = 'x' } }) -Repo 'org/app' -GetPulls { param($s) $e = $g[$s]; if ($e.Error) { throw $e.Error }; $e.Pulls } -GetClosing { param($n) @() } -GetItem { param($r, $n) $null }
Test-Case 'graph: a commit whose pull requests are not known waits' (Get-PromotionDecision -Facts (New-Facts @{ HoldItems = $h.Items; HoldUnknown = $h.Unknown })).Decision 'wait'

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
# A #N the application repository answers 404 for is no item (fworker PR bodies name cmdemo1-workorders items as #N, 1.0.587).
$h = Get-HoldFacts -Commits @($commit) -Repo 'org/app' -GetPulls { param($s) @() } -GetClosing { param($n) @() } -GetItem { param($r, $n) if ($n -eq 16) { $null } else { @{ Number = $n; Url = "i$n"; Labels = @() } } }
Test-Case 'hold facts: an item that does not exist is neither an item nor unknown' "$(@($h.Items | ForEach-Object Number) -join ',') $($h.Unknown.Count)" '58 0'
# The application repository's Hold items listed once (Get-RepoHeld): its references need no read and no cap.
$seen = [Collections.Generic.List[string]]::new()
$wide = [pscustomobject] @{ sha = 'c4'; commit = [pscustomobject] @{ message = ((1..400 | ForEach-Object { "#$_" }) -join ' ') + ' org/other#9' } }
$h = Get-HoldFacts -Commits @($wide) -Repo 'org/app' -GetPulls { param($s) @() } -GetClosing { param($n) @() } -GetItem { param($r, $n) $seen.Add("$r#$n"); @{ Number = $n; Url = ''; Labels = @() } } -RepoHeld @{ 77 = @{ Number = 77; Url = 'i77'; Labels = @('HOLD') } }
Test-Case 'repo held: only other repositories are read' @($seen) @('org/other#9')
Test-Case 'repo held: 400 references of the repository are not over the cap' $h.Unknown.Count 0
Test-Case 'repo held: a listed Hold item flags (case ignored)' (Flags (New-Facts @{ HoldItems = $h.Items })) @('Hold label')
$h = Get-HoldFacts -Commits @($commit) -Repo 'org/app' -GetPulls { param($s) @() } -GetClosing { param($n) @() } -GetItem { param($r, $n) throw 'no read expected' } -RepoHeld @{}
Test-Case 'repo held: an empty listing holds nothing and reads nothing' @(@($h.Items).Count, $h.Unknown.Count) @(0, 0)
$notFound = '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/issues/issues#get-an-issue","status":"404"}'
Test-Case 'issue read: 404 of the application repository is no item' ($null -eq (ConvertFrom-IssueRead -ExitCode 1 -Output $notFound -Repo 'Org/App' -Number 406 -AppRepo 'org/app')) $true
$msg = try { ConvertFrom-IssueRead -ExitCode 1 -Output $notFound -Repo 'org/other' -Number 9 -AppRepo 'org/app'; 'no throw' } catch { $_.Exception.Message }
Test-Case 'issue read: 404 of another repository is not read' $msg 'org/other#9 not read (gh exit 1, HTTP 404)'
$msg = try { ConvertFrom-IssueRead -ExitCode 1 -Output '{"message":"Server Error","status":"502"}' -Repo 'org/app' -Number 5 -AppRepo 'org/app'; 'no throw' } catch { $_.Exception.Message }
Test-Case 'issue read: another failure of the application repository is not read' $msg 'org/app#5 not read (gh exit 1, HTTP 502)'
$msg = try { ConvertFrom-IssueRead -ExitCode 1 -Output '' -Repo 'org/app' -Number 5 -AppRepo 'org/app'; 'no throw' } catch { $_.Exception.Message }
Test-Case 'issue read: no answer at all is not read' $msg 'org/app#5 not read (gh exit 1)'
$ok = ConvertFrom-IssueRead -ExitCode 0 -Output '{"html_url":"https://x/16","labels":[{"name":"Hold"},{"name":"bug"}]}' -Repo 'org/app' -Number 16 -AppRepo 'org/app'
Test-Case 'issue read: an answered issue keeps its labels' "$($ok.Number) $($ok.Url) $($ok.Labels -join ',')" '16 https://x/16 Hold,bug'
$msg = try { ConvertFrom-IssueRead -ExitCode 0 -Output 'garbage' -Repo 'org/app' -Number 5 -AppRepo 'org/app'; 'no throw' } catch { $_.Exception.Message }
Test-Case 'issue read: an answer that is not an issue is not read' $msg 'org/app#5 not read (no issue in the answer)'

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

# Issue #688: a pipeline-change hold keeps its candidate; a newer tdd release must not restart the 60-minute clock.
$pipeHoldBody = @"
ui 2.4.2292 (commit abc) is not promoted to uat automatically. Flags:

**Pipeline or infra change**
- .github/workflows/build.yml (outside src/)

Pipeline change is the only flag: promoted automatically after 2026-11-14 07:27 UTC if master of the application repository is green (owner rule 2026-10-14).
"@
Test-Case 'pipeline hold body is recognized' (Test-PipelineChangeHoldBody $pipeHoldBody) $true
Test-Case 'non-pipeline hold body is not preferred' (Test-PipelineChangeHoldBody "**Red build or tests**`n- CRAP") $false
$mixedDeployHoldBody = @"
ui 2.4.2292 (commit abc) is not promoted to uat automatically. Flags:

**Deployment or health failed**
- the deployment to the previous environment ended Failed

**Pipeline or infra change**
- .github/workflows/build.yml (outside src/)
"@
$mixedRedHoldBody = @"
ui 2.4.2292 (commit abc) is not promoted to uat automatically. Flags:

**Red build or tests**
- CRAP https://example/x

**Pipeline or infra change**
- .github/workflows/build.yml (outside src/)
"@
Test-Case 'pipeline plus deployment failed hold body is not preferred' (Test-PipelineChangeHoldBody $mixedDeployHoldBody) $false
Test-Case 'pipeline plus red build hold body is not preferred' (Test-PipelineChangeHoldBody $mixedRedHoldBody) $false
$heldPrefer = @(Get-HeldPipelinePrefer -HeldIssues @(
        @{ number = 684; title = 'ui 2.4.2292 held before uat'; body = $pipeHoldBody },
        @{ number = 686; title = 'ui 2.4.2296 held before uat'; body = $pipeHoldBody.Replace('2.4.2292', '2.4.2296') },
        @{ number = 9; title = 'dashboard 1.0.1 held before uat'; body = $pipeHoldBody }
    ))
Test-Case 'prefer held: oldest pipeline hold per environment, this deployable only' @($heldPrefer.Count, $heldPrefer[0].Version, $heldPrefer[0].Environment) @(1, '2.4.2292', 'uat')
$rHeld = New-Rel 'R2292' '2.4.2292' 5; $rNewer = New-Rel 'R2298' '2.4.2298' 6; $rUat = New-Rel 'R2237' '2.4.2237' 1
# Same shape as the starvation case: 2.4.2237 already in uat and prod; held and newer only in tdd.
$keepDeps = @(
    (New-Dep 'R2237' 'E1' '01' 't2237'),
    (New-Dep 'R2237' 'E2' '02' 'u2237'),
    (New-Dep 'R2237' 'E3' '03' 'p2237'),
    (New-Dep 'R2292' 'E1' '10' 't2292'),
    (New-Dep 'R2298' 'E1' '20' 't2298')
)
$keepStates = @{ t2237 = 'Success'; u2237 = 'Success'; p2237 = 'Success'; t2292 = 'Success'; t2298 = 'Success' }
$c = Select-Candidate -Environments $envs3 -Releases @($rHeld, $rNewer, $rUat) `
    -GetDeployments { param($id) @($keepDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() `
    -GetTaskState { param($d) $keepStates[$d.TaskId] }.GetNewClosure() `
    -PreferHeld @(@{ Version = '2.4.2292'; Environment = 'uat' })
Test-Case '688 (1): held pipeline release is not superseded by newer tdd' @($c.Release.Id, $c.Target.Name, ($c.Notes[0] -like '*kept as the candidate (issue #688)*2.4.2298*')) @('R2292', 'uat', $true)
$d = Get-PromotionDecision -Facts (New-Pipe 60 'green')
Test-Case '688 (1): that held release promotes when its window passes' @($d.Decision, $d.Reason) @('promote', 'pipeline-override')
# After the held release has been promoted through uat (and on to prod), the newer tdd release is compared to that
# uat commit: pipeline paths are already there, so no new 60-minute hold.
$afterDeps = $keepDeps + @((New-Dep 'R2292' 'E2' '30' 'u2292'), (New-Dep 'R2292' 'E3' '40' 'p2292'))
$afterStates = $keepStates + @{ u2292 = 'Success'; p2292 = 'Success' }
$c = Select-Candidate -Environments $envs3 -Releases @($rHeld, $rNewer, $rUat) `
    -GetDeployments { param($id) @($afterDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() `
    -GetTaskState { param($d) $afterStates[$d.TaskId] }.GetNewClosure()
Test-Case '688 (2): after held promotes, newer tdd is the candidate' @($c.Release.Id, $c.Target.Name) @('R2298', 'uat')
$d = Get-PromotionDecision -Facts (New-Facts @{ Paths = @('src/UI/Server/Program.cs') })
Test-Case '688 (2): newer with no new pipeline paths vs uat promotes without a hold' @($d.Decision, $d.Reason, @(Flags (New-Facts @{ Paths = @('src/UI/Server/Program.cs') }))) @('promote', 'no-flag', @())
$d = Get-PromotionDecision -Facts (New-Pipe 60 'green' @{ PreviousState = 'Failed' })
Test-Case '688 (3): held release whose own deployment failed still holds' @($d.Decision, @(Flags (New-Pipe 60 'green' @{ PreviousState = 'Failed' }))) @('hold', @('Deployment or health failed', 'Pipeline or infra change'))
$d = Get-PromotionDecision -Facts (New-Pipe 60 'green' @{ HealthReads = @(@{ At = $t0.AddMinutes(3); Status = 'Unhealthy' }, @{ At = $t0.AddMinutes(11); Status = 'Unhealthy' }) })
Test-Case '688 (3): held release whose own deployment turns unhealthy still holds' @($d.Decision, @(Flags (New-Pipe 60 'green' @{ HealthReads = @(@{ At = $t0.AddMinutes(3); Status = 'Unhealthy' }, @{ At = $t0.AddMinutes(11); Status = 'Unhealthy' }) }))) @('hold', @('Deployment or health failed', 'Pipeline or infra change'))
# Mixed-flag holds must not pin the version: Get-PromotionDecision refuses them, Close-HeldIssues skips the candidate,
# and a newer healthy tdd release would starve if preference still matched on any Pipeline heading.
$preferMixedDeploy = @(Get-HeldPipelinePrefer -HeldIssues @(
        @{ number = 684; title = 'ui 2.4.2292 held before uat'; body = $mixedDeployHoldBody }
    ))
Test-Case 'mixed deploy+pipeline hold is not preferred' $preferMixedDeploy.Count 0
$c = Select-Candidate -Environments $envs3 -Releases @($rHeld, $rNewer, $rUat) `
    -GetDeployments { param($id) @($keepDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() `
    -GetTaskState { param($d) $keepStates[$d.TaskId] }.GetNewClosure() `
    -PreferHeld $preferMixedDeploy
Test-Case 'mixed deploy+pipeline hold: newer tdd is the candidate' @($c.Release.Id, $c.Target.Name) @('R2298', 'uat')
$preferMixedRed = @(Get-HeldPipelinePrefer -HeldIssues @(
        @{ number = 684; title = 'ui 2.4.2292 held before uat'; body = $mixedRedHoldBody }
    ))
Test-Case 'mixed red+pipeline hold is not preferred' $preferMixedRed.Count 0
$c = Select-Candidate -Environments $envs3 -Releases @($rHeld, $rNewer, $rUat) `
    -GetDeployments { param($id) @($keepDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() `
    -GetTaskState { param($d) $keepStates[$d.TaskId] }.GetNewClosure() `
    -PreferHeld $preferMixedRed
Test-Case 'mixed red+pipeline hold: newer tdd is the candidate' @($c.Release.Id, $c.Target.Name) @('R2298', 'uat')
$c = Select-Candidate -Environments $envs3 -Releases @($rHeld, $rNewer, $rUat) `
    -GetDeployments { param($id) @($keepDeps | Where-Object { $_.ReleaseId -eq $id }) }.GetNewClosure() `
    -GetTaskState { param($d) $keepStates[$d.TaskId] }.GetNewClosure()
Test-Case 'without a prefer list, newest tdd is still the candidate' $c.Release.Id 'R2298'
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

# Security-advisory exemption (owner rule 2026-11-11): skip the 60-minute project-file hold for GHSA package bumps.
$csprojPath = 'src/ChurchBulletin.AppHost/ChurchBulletin.AppHost.csproj'
$baselinePath = 'scripts/dead-code/unused-package-baseline.json'
$versionOnlyCsproj = @"
--- a/$csprojPath
+++ b/$csprojPath
@@ -1,4 +1,4 @@
-<Project Sdk="Aspire.AppHost.Sdk/13.1.2">
+<Project Sdk="Aspire.AppHost.Sdk/13.6.5">
 
   <PropertyGroup>
     <OutputType>Exe</OutputType>
@@ -10,7 +10,7 @@
   <ItemGroup>
-    <PackageReference Include="Aspire.Hosting.Redis" Version="13.1.2" />
+    <PackageReference Include="Aspire.Hosting.Redis" Version="13.6.5" />
   </ItemGroup>
"@
$baselineOnly = @"
--- a/$baselinePath
+++ b/$baselinePath
@@ -1,6 +1,3 @@
-    {
-      "package": "Old.Package",
-      "project": "$csprojPath"
-    },
"@
$noWarnCsproj = @"
--- a/$csprojPath
+++ b/$csprojPath
@@ -1,8 +1,9 @@
-<Project Sdk="Aspire.AppHost.Sdk/13.1.2">
+<Project Sdk="Aspire.AppHost.Sdk/13.6.5">
   <PropertyGroup>
     <OutputType>Exe</OutputType>
+    <NoWarn>`$(NoWarn);ASPIRE010</NoWarn>
   </PropertyGroup>
"@
$workflowPatch = @"
--- a/.github/workflows/build.yml
+++ b/.github/workflows/build.yml
@@ -1,2 +1,3 @@
 name: build
+env: { X: 1 }
"@
function New-AdvisoryPull([string] $Title, [string] $Body, [object[]] $Files, [string] $Error = '') {
    @{ Number = 1610; Title = $Title; Body = $Body; Files = @($Files); Error = $Error }
}
function New-AdvisoryFiles([string] $CsprojPatch = $versionOnlyCsproj, [string] $BaselinePatch = $baselineOnly) {
    @(@{ Filename = $csprojPath; Patch = $CsprojPatch }, @{ Filename = $baselinePath; Patch = $BaselinePatch })
}
Test-Case 'GHSA id is read from title' (Get-GhsaIds 'Bump Aspire (NU1903 GHSA-f7vh-h5g3-7jrh)') @('GHSA-F7VH-H5G3-7JRH')
Test-Case 'GHSA id is read from body' (Get-GhsaIds 'Fixes GHSA-abcd-efgh-ijkl today') @('GHSA-ABCD-EFGH-IJKL')
Test-Case 'no GHSA id when absent' @(Get-GhsaIds 'just a bump').Count 0
Test-Case 'advisory path: csproj qualifies' (Test-SecurityAdvisoryPackagePath $csprojPath) $true
Test-Case 'advisory path: Directory.Packages.props qualifies' (Test-SecurityAdvisoryPackagePath 'Directory.Packages.props') $true
Test-Case 'advisory path: unused-package baseline qualifies' (Test-SecurityAdvisoryPackagePath $baselinePath) $true
Test-Case 'advisory path: Dockerfile does not' (Test-SecurityAdvisoryPackagePath 'Dockerfile') $false
Test-Case 'advisory path: workflow does not' (Test-SecurityAdvisoryPackagePath '.github/workflows/build.yml') $false
Test-Case 'version-only csproj patch qualifies' (Test-PackageVersionOnlyPatch -Path $csprojPath -Patch $versionOnlyCsproj) $true
Test-Case 'NoWarn in csproj does not qualify' (Test-PackageVersionOnlyPatch -Path $csprojPath -Patch $noWarnCsproj) $false
Test-Case 'null patch fails closed' (Test-PackageVersionOnlyPatch -Path $csprojPath -Patch $null) $false
Test-Case 'baseline patch qualifies' (Test-PackageVersionOnlyPatch -Path $baselinePath -Patch $baselineOnly) $true
$qualifyingPull = New-AdvisoryPull 'Bump Aspire to 13.6.5 (NU1903 GHSA-f7vh-h5g3-7jrh)' 'Closes #1609' (New-AdvisoryFiles)
$qualifyingByPath = @{ $csprojPath = $qualifyingPull; $baselinePath = $qualifyingPull }
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @($csprojPath, $baselinePath) -PullByPath $qualifyingByPath
Test-Case 'exemption: qualifying package bump + baseline + GHSA' @($ex.Qualifies, $ex.GhsaIds) @($true, @('GHSA-F7VH-H5G3-7JRH'))
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @($csprojPath, $baselinePath) -PullByPath @{
    $csprojPath = (New-AdvisoryPull 'Bump without advisory id' '' (New-AdvisoryFiles)); $baselinePath = (New-AdvisoryPull 'Bump without advisory id' '' (New-AdvisoryFiles))
}
Test-Case 'exemption: no GHSA id does not qualify' $ex.Qualifies $false
$mixedPull = New-AdvisoryPull 'GHSA-f7vh-h5g3-7jrh and a workflow' '' (@(New-AdvisoryFiles) + @{ Filename = '.github/workflows/build.yml'; Patch = $workflowPatch })
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @($csprojPath) -PullByPath @{ $csprojPath = $mixedPull }
Test-Case 'exemption: workflow in the same PR does not qualify' $ex.Qualifies $false
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @($csprojPath) -PullByPath @{
    $csprojPath = (New-AdvisoryPull 'GHSA-f7vh-h5g3-7jrh' '' @(@{ Filename = $csprojPath; Patch = $noWarnCsproj }))
}
Test-Case 'exemption: more than version numbers does not qualify' $ex.Qualifies $false
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @('Dockerfile') -PullByPath @{
    'Dockerfile' = (New-AdvisoryPull 'GHSA-f7vh-h5g3-7jrh' '' @(@{ Filename = 'Dockerfile'; Patch = $workflowPatch }))
}
Test-Case 'exemption: Dockerfile flagged path does not qualify' $ex.Qualifies $false
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @($csprojPath) -PullByPath @{
    $csprojPath = (New-AdvisoryPull 'GHSA-f7vh-h5g3-7jrh' '' @(@{ Filename = $csprojPath; Patch = $null }))
}
Test-Case 'exemption: unreadable diff fails closed' $ex.Qualifies $false
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @($csprojPath) -PullByPath @{}
Test-Case 'exemption: missing PR lookup fails closed' $ex.Qualifies $false
$ex = Test-SecurityAdvisoryExemption -FlaggedPaths @($csprojPath) -PullByPath @{
    $csprojPath = @{ Number = 1; Title = 'GHSA-f7vh-h5g3-7jrh'; Body = ''; Files = @(); Error = 'labels not read whole' }
}
Test-Case 'exemption: incomplete PR lookup fails closed' $ex.Qualifies $false

function New-AdvisoryPipe([double] $Minutes, [string] $Master, [hashtable] $More = @{}) {
    $f = New-Pipe $Minutes $Master (@{
            Paths = @($csprojPath, $baselinePath)
            SecurityAdvisoryOverride = @{ Qualifies = $true; GhsaIds = @('GHSA-F7VH-H5G3-7JRH'); Paths = @($csprojPath, $baselinePath); Why = '' }
        })
    foreach ($k in $More.Keys) { $f[$k] = $More[$k] }
    $f
}
$d = Get-PromotionDecision -Facts (New-AdvisoryPipe 5 'green')
Test-Case 'advisory: qualifying under 60 minutes, master green: promote immediately' @($d.Decision, $d.Reason) @('promote', 'security-advisory-override')
Test-Case 'advisory Sign-off note names the rule' ((Format-PromotionReason -Decision $d -Previous 'uat' -RunUrl 'r1') -like 'Auto-promoted immediately: security-advisory dependency fix skipped the project-file hold (owner rule 2026-11-11), master green, no other flag;*run r1') $true
$d = Get-PromotionDecision -Facts (New-AdvisoryPipe 60 'pending')
Test-Case 'advisory: qualifying, master pending: hold' @($d.Decision, ($d.Note -like '*Security-advisory dependency fix*pending*')) @('hold', $true)
$d = Get-PromotionDecision -Facts (New-AdvisoryPipe 5 'red')
Test-Case 'advisory: qualifying, master red: hold' @($d.Decision, ($d.Note -like '*master is red*')) @('hold', $true)
$d = Get-PromotionDecision -Facts (New-AdvisoryPipe 5 'unknown')
Test-Case 'advisory: qualifying, master unknown: hold' @($d.Decision, ($d.Note -like '*could not be read*')) @('hold', $true)
$d = Get-PromotionDecision -Facts (New-AdvisoryPipe 5 'green' @{ HoldUnknown = @('#4 not read') })
Test-Case 'advisory: qualifying, a wait open: hold' $d.Decision 'hold'
$d = Get-PromotionDecision -Facts (New-AdvisoryPipe 5 'green' @{ PathsKnown = $false })
Test-Case 'advisory: incomplete comparison is not exempt' $d.Decision 'hold'
$d = Get-PromotionDecision -Facts (New-AdvisoryPipe 5 'green' @{ Checks = @(@{ Name = 'CRAP'; State = 'failure'; Url = 'x' }) })
Test-Case 'advisory: other flags are not exempt' $d.Decision 'hold'
$d = Get-PromotionDecision -Facts (New-Pipe 5 'green' @{
        Paths = @($csprojPath, $baselinePath)
        SecurityAdvisoryOverride = @{ Qualifies = $false; GhsaIds = @(); Paths = @($csprojPath); Why = 'no GHSA id' }
    })
Test-Case 'advisory: non-qualifying still held under 60 minutes' @($d.Decision, $d.Reason) @('hold', $null)
$d = Get-PromotionDecision -Facts (New-Pipe 5 'green' @{ Paths = @('.github/workflows/build.yml') })
Test-Case 'advisory: workflow-only change still held under 60 minutes' $d.Decision 'hold'
$d = Get-PromotionDecision -Facts (New-Pipe 60 'green' @{
        Paths = @($csprojPath)
        SecurityAdvisoryOverride = @{ Qualifies = $false; GhsaIds = @(); Paths = @($csprojPath); Why = 'no GHSA id' }
    })
Test-Case 'advisory: non-qualifying at 60 minutes still uses pipeline-override' @($d.Decision, $d.Reason) @('promote', 'pipeline-override')
Test-Case 'evidence path strips the outside reason' (ConvertFrom-PipelineEvidencePath 'scripts/dead-code/unused-package-baseline.json (outside src/)') $baselinePath
Test-Case 'evidence path strips the build-file reason' (ConvertFrom-PipelineEvidencePath "$csprojPath (build or project file)") $csprojPath

Test-Case 'master: all passed is green' (Get-MasterState @(@{ Name = 'a'; State = 'success'; Url = '' }, @{ Name = 'b'; State = 'skipped'; Url = '' })).State 'green'
Test-Case 'master: one pending is pending' (Get-MasterState @(@{ Name = 'a'; State = 'success'; Url = '' }, @{ Name = 'b'; State = 'pending'; Url = '' })).State 'pending'
Test-Case 'master: one failed is red' (Get-MasterState @(@{ Name = 'a'; State = 'failure'; Url = '' }, @{ Name = 'b'; State = 'pending'; Url = '' })).State 'red'
Test-Case 'master: no check is not green' (Get-MasterState @()).State 'pending'

# Issue #697: when master is only pending (none failed), wait in the same run then decide (injectable poll/timeout).
function New-Master([string] $State, [object[]] $Evidence = @(), [string] $Sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', [string] $Branch = 'master') {
    @{ State = $State; Evidence = @($Evidence); Sha = $Sha; Branch = $Branch }
}
$masterWait = @{ PauseCount = 0; Logs = [Collections.Generic.List[string]]::new() }
$masterNoPause = { param([int] $Seconds) $masterWait.PauseCount++ }.GetNewClosure()
$masterLog = { param([string] $Message) $masterWait.Logs.Add($Message) }.GetNewClosure()

$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$pendingThenGreen = [Collections.Queue]::new()
$pendingThenGreen.Enqueue((New-Master 'green'))
$waitGreen = Wait-MasterPendingClear -Initial (New-Master 'pending' @('deployments')) `
    -ReadAgain { $pendingThenGreen.Dequeue() }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 3 -WriteLog $masterLog
$d = Get-PromotionDecision -Facts (New-Pipe 60 $waitGreen.State)
Test-Case '697: pending then green: wait state is green' $waitGreen.State 'green'
Test-Case '697: pending then green: promotes by the override' @($d.Decision, $d.Reason) @('promote', 'pipeline-override')
Test-Case '697: pending then green: paused once' $masterWait.PauseCount 1
Test-Case '697: pending then green: log shows the wait-then-decide path' @(
    ($masterWait.Logs[0] -like '*Waiting for master*checks*'),
    ($masterWait.Logs[-1] -like '*green after waiting*')
) @($true, $true)

$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$pendingThenRed = [Collections.Queue]::new()
$pendingThenRed.Enqueue((New-Master 'red' @('delivery https://example/x')))
$waitRed = Wait-MasterPendingClear -Initial (New-Master 'pending' @('delivery')) `
    -ReadAgain { $pendingThenRed.Dequeue() }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 3 -WriteLog $masterLog
$d = Get-PromotionDecision -Facts (New-Pipe 60 'red' @{ PipelineOverride = @{ Minutes = 60; MasterState = 'red'; MasterEvidence = @($waitRed.Evidence) } })
Test-Case '697: pending then failure: wait state is red' $waitRed.State 'red'
Test-Case '697: pending then failure: holds' $d.Decision 'hold'
Test-Case '697: pending then failure: note names master is red' ($d.Note -like '*master is red*delivery*') $true
Test-Case '697: pending then failure: log shows wait then red' @(
    ($masterWait.Logs[0] -like '*Waiting for master*'),
    ($masterWait.Logs[-1] -like '*red after waiting*')
) @($true, $true)

$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$stillPending = New-Master 'pending' @('deployments', 'workitems')
$waitTimeout = Wait-MasterPendingClear -Initial (New-Master 'pending' @('deployments')) `
    -ReadAgain { $stillPending }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 3 -WriteLog $masterLog
$d = Get-PromotionDecision -Facts (New-Pipe 60 'pending' @{ PipelineOverride = @{ Minutes = 60; MasterState = 'pending'; MasterEvidence = @($waitTimeout.Evidence) } })
Test-Case '697: pending past timeout: still pending' $waitTimeout.State 'pending'
Test-Case '697: pending past timeout: holds' $d.Decision 'hold'
Test-Case '697: pending past timeout: note keeps the promised time and pending' ($d.Note -like '*after 2026-10-14 05:00 UTC if master*pending*') $true
Test-Case '697: pending past timeout: paused TimeoutSeconds/PollSeconds times' $masterWait.PauseCount 3
Test-Case '697: pending past timeout: log shows still pending after timeout' ($masterWait.Logs[-1] -like '*still pending after 3s*') $true

# Read-MasterState wires the wait: first pending answer is waited out via ReadAgain.
$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$readOnceQ = [Collections.Queue]::new()
$readOnceQ.Enqueue((New-Master 'pending' @('no check has reported yet')))
$readOnceQ.Enqueue((New-Master 'green'))
$readViaWait = Read-MasterState -ReadAgain { $readOnceQ.Dequeue() }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 2 -WriteLog $masterLog
Test-Case '697: Read-MasterState waits then returns green' $readViaWait.State 'green'
Test-Case '697: Read-MasterState wait was logged' ($masterWait.Logs[0] -like '*Waiting for master*') $true
# Already green: no wait.
$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$greenMaster = New-Master 'green'
$readGreen = Read-MasterState -ReadAgain { $greenMaster }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 2 -WriteLog $masterLog
Test-Case '697: Read-MasterState green skips the wait' @($readGreen.State, $masterWait.PauseCount, $masterWait.Logs.Count) @('green', 0, 0)
# Already red: no wait (a failed check must still hold without polling).
$redMaster = New-Master 'red' @('Build result')
$readRed = Read-MasterState -ReadAgain { $redMaster }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 2 -WriteLog $masterLog
Test-Case '697: Read-MasterState red skips the wait' @($readRed.State, $masterWait.PauseCount) @('red', 0)

# PR #698 review: remaining-time budget so the wait never risks the 55-minute promote job timeout.
Test-Case '698: reserve covers Sign-off, health pause and runbook wait' $MasterPendingJobReserveSeconds (900 + $HealthPauseSeconds + ($RunbookBusyRetrySeconds * $RunbookBusyRetryLimit))
Test-Case '698: job timeout minutes match the workflow' $MasterPendingJobTimeoutMinutes 55
$budgetClock = @{ Now = $t0 }
$budgetGetNow = { $budgetClock.Now }.GetNewClosure()
$budgetStart = '2026-10-14T04:00:00Z'
$budgetDeadline = Get-MasterPendingDeadline -StartedAt $budgetStart -JobTimeoutMinutes 55 -ReserveSeconds 1360
Test-Case '698: deadline is start + timeout − reserve' $budgetDeadline $t0.AddMinutes(55).AddSeconds(-1360)
Test-Case '698: no start time means no deadline' (Get-MasterPendingDeadline -StartedAt '') $null

# Budget exhausted: skip wait, stay pending, hold (never promote).
$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$budgetClock.Now = $t0
$stillPendingBudget = New-Master 'pending' @('deployments')
$waitBudgetOut = Wait-MasterPendingClear -Initial (New-Master 'pending' @('deployments')) `
    -ReadAgain { $stillPendingBudget }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 10 `
    -Deadline $t0.AddSeconds(-1) -GetNow $budgetGetNow -WriteLog $masterLog
$d = Get-PromotionDecision -Facts (New-Pipe 60 'pending' @{ PipelineOverride = @{ Minutes = 60; MasterState = 'pending'; MasterEvidence = @($waitBudgetOut.Evidence) } })
Test-Case '698: budget exhausted: no wait' $masterWait.PauseCount 0
Test-Case '698: budget exhausted: still pending' $waitBudgetOut.State 'pending'
Test-Case '698: budget exhausted: holds' $d.Decision 'hold'
Test-Case '698: budget exhausted: note keeps pending hold wording' ($d.Note -like '*after 2026-10-14 05:00 UTC if master*pending*') $true
Test-Case '698: budget exhausted: log says skipping wait' ($masterWait.Logs[0] -like '*Skipping wait*not enough job time*') $true

# Small budget shortens the wait below TimeoutSeconds (injectable clock + deadline).
$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$budgetClock.Now = $t0
$stillPendingBudgetShort = New-Master 'pending' @('deployments')
$waitBudgetShort = Wait-MasterPendingClear -Initial (New-Master 'pending' @('deployments')) `
    -ReadAgain { $stillPendingBudgetShort }.GetNewClosure() -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 10 `
    -Deadline $t0.AddSeconds(2) -GetNow $budgetGetNow -WriteLog $masterLog
Test-Case '698: small budget: still pending' $waitBudgetShort.State 'pending'
Test-Case '698: small budget: pauses only remaining seconds' $masterWait.PauseCount 2
Test-Case '698: small budget: log uses the shortened timeout' ($masterWait.Logs[-1] -like '*still pending after 2s*') $true

# Read-MasterState honours an injected deadline (budget exhausted → pending, no pause).
$masterWait.PauseCount = 0; $masterWait.Logs.Clear()
$budgetClock.Now = $t0
$pendingBudgetOut = New-Master 'pending' @('deployments')
$readBudgetOut = Read-MasterState -ReadAgain { $pendingBudgetOut }.GetNewClosure() `
    -Pause $masterNoPause -PollSeconds 1 -TimeoutSeconds 10 -Deadline $t0.AddSeconds(-5) -GetNow $budgetGetNow -WriteLog $masterLog
Test-Case '698: Read-MasterState budget exhausted skips wait' @($readBudgetOut.State, $masterWait.PauseCount) @('pending', 0)

# Release notes commit (#574): apps say "Build … of <sha>", system says "Commit <sha>: …" (system.yml).
$sha40 = '875cf235b557b570b11ade1ce9f02ac381a92469'
Test-Case 'commit: app Build … of <sha>' (Get-Commit @{ ReleaseNotes = "Build https://github.com/o/r/actions/runs/1 of $sha40, committed 2026-11-11T20:00:00Z" }) $sha40
Test-Case 'commit: system Commit <sha>: …' (Get-Commit @{ ReleaseNotes = "Commit ${sha40}: Skip the project-file hold (#565)" }) $sha40
Test-Case 'commit: bare 40-char sha still found' (Get-Commit @{ ReleaseNotes = "packaged $sha40 only" }) $sha40
Test-Case 'commit: empty notes' (Get-Commit @{ ReleaseNotes = '' }) $null
Test-Case 'commit: null release' (Get-Commit $null) $null

# No commit in release notes is a hold, not a workflow failure (#621)
$emptyNotesRel = @{ Version = '1.0.35.1'; ReleaseNotes = '' }
$noCommitResolved = Get-EvaluationCommitOrHold $emptyNotesRel -Name 'dashboard' -TargetName 'uat'
Test-Case 'no-commit empty notes: hold recorded, no throw' @(
    [bool] $noCommitResolved.Hold
    $noCommitResolved.Hold.Decision.Decision
    $noCommitResolved.Sha
    $noCommitResolved.Hold.Decision.Flags[0].Flag
) @($true, 'hold', $null, $NoCommitInNotesFlag)
Test-Case 'no-commit empty notes: does not promote' ($noCommitResolved.Hold.Decision.Decision -eq 'promote') $false
Test-Case 'no-commit hold title' (Get-NoCommitHeldTitle '1.0.35.1' 'dashboard') 'dashboard 1.0.35.1 held: release notes name no commit'
Test-Case 'no-commit held issue title omits environment' (Get-HeldIssueTitle -Version '1.0.35.1' -Environment 'uat' -Flags $noCommitResolved.Hold.Decision.Flags -Name 'dashboard') 'dashboard 1.0.35.1 held: release notes name no commit'
$noCommitBody = Format-HeldEvidence -Version '1.0.35.1' -Sha $noCommitResolved.Hold.Sha -Target 'uat' -Flags $noCommitResolved.Hold.Decision.Flags -Name 'dashboard'
Test-Case 'no-commit hold evidence names the flag and release' @(
    (Test-NoCommitHoldBody $noCommitBody),
    ($noCommitBody -like '*dashboard 1.0.35.1*'),
    ($noCommitBody -like '*release notes name no commit*')
) @($true, $true, $true)
$withCommitResolved = Get-EvaluationCommitOrHold @{ Version = '1.0.36'; ReleaseNotes = "Commit ${sha40}: fix" } -Name 'dashboard' -TargetName 'uat'
Test-Case 'no-commit: notes with a sha still evaluate' @([bool] $withCommitResolved.Hold, $withCommitResolved.Sha) @($false, $sha40)
Test-Case 'held before title unchanged when flags are not no-commit' (Get-HeldIssueTitle -Version '1.0.27' -Environment 'uat' -Flags @() -Name 'dashboard') 'dashboard 1.0.27 held before uat'

# --- Per-deployable settings (ui; dashboard and system 2026-11-10 #560; fworker and aisf excluded) ---
Test-Case 'settings: covered deployables' @($DeployableSettings.Keys | Sort-Object) @('dashboard', 'system', 'ui')
Test-Case 'settings: promote order' $PromoteOrder @('ui', 'dashboard', 'system')
foreach ($n in $DeployableSettings.Keys) {
    $s = $DeployableSettings[$n]
    Test-Case "settings: $n has every key" @(@('ApplicationPaths', 'UnflaggedFolders', 'HealthPath', 'HealthRead', 'BuildPath') | Where-Object { -not $s.ContainsKey($_) }) @()
    Test-Case "settings: $n HealthRead is known" ($s.HealthRead -in 'overallStatus', 'ready', 'httpOk', 'none') $true
}
Test-Case 'settings: loaded for ui by default' @($Deployable, $Settings.HealthPath, $Settings.BuildPath) @('ui', '/_healthcheck/detailed', '/_build')
Test-Case 'settings: aisf is not promoted' ($DeployableSettings.ContainsKey('aisf')) $false
Test-Case 'settings: fworker is not promoted' ($DeployableSettings.ContainsKey('fworker')) $false
Test-Case 'settings: scorecard is not promoted' ($DeployableSettings.ContainsKey('scorecard')) $false
Test-Case 'settings: promote order excludes fworker' ($PromoteOrder -contains 'fworker') $false
Test-Case 'settings: promote order excludes aisf' ($PromoteOrder -contains 'aisf') $false
Test-Case 'ui unchanged: a gateway path is outside src/' (Get-PipelineEvidence -Paths @('gateway/Program.cs')) @('gateway/Program.cs (outside src/)')
Test-Case 'ui unchanged: the health flag names /_healthcheck/detailed' (Get-PromotionDecision -Facts (New-Facts @{ HealthReads = @(@{ At = $t0.AddMinutes(2); Status = 'Degraded' }) })).Flags[0].Evidence[0] 'health: /_healthcheck/detailed was not Healthy: Degraded at 2026-10-14 04:02:00Z'

# /ready helper (HealthRead ready; kept for Invoke-HealthRead NotReady retry semantics)
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

# Held issue titles and evidence (names are isolated per deployable)
Test-Case 'held title of ui unchanged' (Get-HeldTitle '2.4.470' 'prod') 'ui 2.4.470 held before prod'
Test-Case 'held title of dashboard' (Get-HeldTitle '1.0.27' 'uat' 'dashboard') 'dashboard 1.0.27 held before uat'
Test-Case 'held title parts of dashboard' @((Get-HeldTitleParts 'dashboard 1.0.27 held before uat' 'dashboard').Values | Sort-Object) @('1.0.27', 'uat')
Test-Case 'ui does not read a dashboard issue' (Get-HeldTitleParts 'dashboard 1.0.27 held before uat' 'ui') $null
Test-Case 'dashboard does not read a ui issue' (Get-HeldTitleParts 'ui 2.4.470 held before prod' 'dashboard') $null
Test-Case 'ui does not read an app2-ui issue' (Get-HeldTitleParts 'app2-ui 1.2.3 held before uat' 'ui') $null
Test-Case 'held evidence names dashboard' ((Format-HeldEvidence -Version '1.0.27' -Sha 'c1' -Target 'uat' -Flags @() -Name 'dashboard') -like 'dashboard 1.0.27 (commit c1) is not promoted to uat automatically.*') $true
Test-Case 'held evidence of ui unchanged' ((Format-HeldEvidence -Version '2.4.1' -Sha 'c1' -Target 'uat' -Flags @()) -like 'ui 2.4.1 (commit c1) is not promoted to uat automatically.*') $true
Test-Case 'busy reason names dashboard' (Get-BusyReason @(@{ Kind = 'deployment'; ProjectId = 'P-dash'; EnvironmentId = 'E-uat' }) 'E-prod' 'E-tdd' 'P-dash' 'dashboard') 'a dashboard deployment is not finished in another environment'

# State keys per deployable
Test-Case 'state key names the deployable' @((Get-StateKey 'Deployments-9' 'dashboard'), (Get-StateKey 'Deployments-9')) @('dashboard/Deployments-9', 'ui/Deployments-9')
$st = @{ 'Deployments-1' = @(@{ at = 'a'; status = 'Healthy' }); 'dashboard/Deployments-2' = @(@{ at = 'b'; status = 'Unhealthy' }); 'ui/Deployments-2' = @(@{ at = 'c'; status = 'Healthy' }) }
Test-Case 'state: ui still finds its reads stored under the bare key' @(Read-StateReads $st 'Deployments-1' | ForEach-Object { $_.at }) @('a')
Test-Case 'state: dashboard does not read a bare key' @(Read-StateReads $st 'Deployments-1' 'dashboard').Count 0
Test-Case 'state: the same deployment id of two deployables does not collide' @(@(Read-StateReads $st 'Deployments-2' 'dashboard')[0].at, @(Read-StateReads $st 'Deployments-2' 'ui')[0].at) @('b', 'c')

# --- dashboard (static web app) and system (#560) ---
# Before excluded-deployable LoadOnly (it assigns $Settings = $null then throws): keep $Settings loaded.
$dash = $DeployableSettings.dashboard
function DashPipe([string[]] $Paths) { @(Get-PipelineEvidence -Paths $Paths -Application $dash.ApplicationPaths -Unflagged $dash.UnflaggedFolders) }
Test-Case 'dashboard: settings' @($dash.HealthPath, $dash.HealthRead, $dash.BuildPath) @('/', 'httpOk', '/build-facts.json')
Test-Case 'dashboard: application code does not flag' (DashPipe @('src/Dashboard/App.razor', 'src/Dashboard.Tests/A.cs')) @()
Test-Case 'dashboard: workflow and project file flag' (DashPipe @('.github/workflows/build.yml', 'src/Dashboard/Dashboard.csproj')).Count 2
Test-Case 'httpOk: 200 is Healthy' (ConvertTo-HttpOkStatus 200) 'Healthy'
Test-Case 'httpOk: 204 is Healthy' (ConvertTo-HttpOkStatus 204) 'Healthy'
Test-Case 'httpOk: 404 is Unhealthy' (ConvertTo-HttpOkStatus 404) 'Unhealthy'
Test-Case 'httpOk: 0 is not answered' (ConvertTo-HttpOkStatus 0) ''
$pauses.Value = 0; $f = New-Reader @((ConvertTo-HttpOkStatus 0), 'Healthy')
$r = Invoke-HealthRead -Reader $f.Reader -Pause $noPause
Test-Case 'httpOk: unanswered then Healthy' @($r.Status, $f.Calls.Value, $pauses.Value) @('Healthy', 2, 1)
$d = Get-PromotionDecision -Facts (New-Facts @{ HealthReads = @(@{ At = $t0.AddMinutes(2); Status = 'Unhealthy' }) }) -Name 'dashboard' -HealthPath '/'
Test-Case 'dashboard: Unhealthy flags naming /' @($d.Decision, $d.Flags[0].Evidence[0]) @('hold', 'health: / was not Healthy: Unhealthy at 2026-10-14 04:02:00Z')

$sys = $DeployableSettings.system
function SysPipe([string[]] $Paths) { @(Get-PipelineEvidence -Paths $Paths -Application $sys.ApplicationPaths -Unflagged $sys.UnflaggedFolders) }
Test-Case 'system: settings' @($sys.HealthRead, $sys.BuildPath, $sys.HealthPath) @('none', '', '')
Test-Case 'system: GitOps paths do not flag' (SysPipe @('infra/main.bicep', 'octopus/projects.tf', 'environments/tdd/versions.json', 'scripts/write-delivery.ps1', 'system.json', 'factory/operating-instructions.md')) @()
Test-Case 'system: a workflow change flags' (SysPipe @('.github/workflows/delivery.yml')) @('.github/workflows/delivery.yml (outside environments/, infra/, octopus/, scripts/, bootstrap/, factory/, space-scorecard/, system.json, .gitignore)')
Test-Case 'system: held title' (Get-HeldTitle '1.0.180' 'prod' 'system') 'system 1.0.180 held before prod'
. (Join-Path $PSScriptRoot 'ui-auto-promote.ps1') -LoadOnly -Deployable dashboard
Test-Case 'loaded for dashboard: settings' @($Settings.HealthPath, $Settings.HealthRead, $Settings.BuildPath) @('/', 'httpOk', '/build-facts.json')
Test-Case 'loaded for dashboard: held title by default' (Get-HeldTitle '1.0.27' 'uat') 'dashboard 1.0.27 held before uat'
. (Join-Path $PSScriptRoot 'ui-auto-promote.ps1') -LoadOnly -Deployable system
Test-Case 'loaded for system: settings' @($Settings.HealthRead, $Settings.BuildPath) @('none', '')
Test-Case 'loaded for system: held title by default' (Get-HeldTitle '1.0.1' 'uat') 'system 1.0.1 held before uat'
Test-Case 'loaded for system: pipeline by default' @(Get-PipelineEvidence -Paths @('infra/main.bicep', '.github/workflows/x.yml')).Count 1
Test-Case 'system: no HTTP health required: promote' (Get-PromotionDecision -Facts (New-Facts @{ HealthRequired = $false; HealthAddressKnown = $false; HealthReads = @(); Paths = @('infra/main.bicep') })).Decision 'promote'
Test-Case 'system: health skip still flags a failed deployment' (Get-PromotionDecision -Facts (New-Facts @{ HealthRequired = $false; PreviousState = 'Failed'; Paths = @() })).Decision 'hold'

# containers.json has no system (or other non-container) address: StrictMode must not throw (#598).
$containersLikeStatus = [pscustomobject] @{
    tdd  = [pscustomobject] @{ ui = 'https://tdd-ui.example'; dashboard = 'https://tdd-dash.example' }
    uat  = [pscustomobject] @{ ui = 'https://uat-ui.example'; dashboard = 'https://uat-dash.example'; aisf = 'https://uat-aisf.example'; fworker = 'https://uat-fw.example' }
    prod = [pscustomobject] @{ ui = 'https://prod-ui.example'; dashboard = 'https://prod-dash.example' }
}
Test-Case 'address: missing system key is empty (no throw)' (Get-ContainerAddress $containersLikeStatus 'uat' 'system') ''
Test-Case 'address: present ui is returned' (Get-ContainerAddress $containersLikeStatus 'uat' 'ui') 'https://uat-ui.example'
Test-Case 'address: missing environment is empty' (Get-ContainerAddress $containersLikeStatus 'lab' 'ui') ''
Test-Case 'address: null containers is empty' (Get-ContainerAddress $null 'uat' 'system') ''
$threwMissingSystem = $false
try {
    $null = Get-ContainerAddress $containersLikeStatus 'tdd' 'system'
    $null = Get-ContainerAddress $containersLikeStatus 'uat' 'system'
    $null = Get-ContainerAddress $containersLikeStatus 'prod' 'system'
} catch {
    $threwMissingSystem = $true
}
Test-Case 'address: candidate evaluation path does not throw when deployable is absent' $threwMissingSystem $false
# Hashtable form (ConvertFrom-Json -AsHashtable) is also safe.
$asHash = @{ uat = @{ ui = 'https://uat-ui.example' } }
Test-Case 'address: hashtable missing deployable is empty' (Get-ContainerAddress $asHash 'uat' 'system') ''
Test-Case 'address: hashtable present deployable' (Get-ContainerAddress $asHash 'uat' 'ui') 'https://uat-ui.example'

$threwAisf = try { . (Join-Path $PSScriptRoot 'ui-auto-promote.ps1') -LoadOnly -Deployable aisf; $false } catch { $_.Exception.Message -like 'deployable aisf is not promoted automatically*' }
Test-Case 'aisf is not promoted: LoadOnly stops the script' $threwAisf $true
$threwFworker = try { . (Join-Path $PSScriptRoot 'ui-auto-promote.ps1') -LoadOnly -Deployable fworker; $false } catch { $_.Exception.Message -like 'deployable fworker is not promoted automatically*' }
Test-Case 'fworker is not promoted: LoadOnly stops the script' $threwFworker $true

# Issue #646: GitHub Actions' pwsh shell appends `exit $LASTEXITCODE` to every step. A leftover non-zero from an
# expected gh/git refusal must not turn a successful promote red; a real throw must still exit non-zero.
function Invoke-LikeActionsPwshStep([string] $StepBody) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ui-auto-promote-exit-" + [guid]::NewGuid().ToString('n') + '.ps1')
    # Same wrap as actions/runner ScriptHandlerHelpers for pwsh.
    @(
        "`$ErrorActionPreference = 'stop'"
        $StepBody
        "if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }"
    ) -join [Environment]::NewLine | Set-Content -LiteralPath $tmp -Encoding utf8
    # LoadOnly set $PSNativeCommandUseErrorActionPreference; a nested pwsh that exits 1 must not throw here.
    $prevNative = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        & pwsh -NoProfile -Command ". '$($tmp.Replace('''', ''''''))'" *> $null
        return [int] $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNative
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
$promoteScript = (Join-Path $PSScriptRoot 'ui-auto-promote.ps1').Replace('''', '''''')
$successExit = Invoke-LikeActionsPwshStep @"
`$PSNativeCommandUseErrorActionPreference = `$false
bash -c 'exit 1'
. '$promoteScript' -LoadOnly
Complete-AutoPromoteSuccess
"@
Test-Case 'success path exits 0 despite leftover LASTEXITCODE (#646)' $successExit 0
$throwExit = Invoke-LikeActionsPwshStep @"
. '$promoteScript' -LoadOnly
throw 'simulated promote failure'
"@
Test-Case 'throw still exits non-zero (#646)' ($throwExit -ne 0) $true

# Ripe hold elsewhere gets the free slot first (system kept losing the single prod slot to ui and dashboard).
$ripeNow = [datetime]::Parse('2026-11-21T16:00:00Z').ToUniversalTime()
function New-RipeHold($n, $title, $minutes, $body = $pipeHoldBody) { @{ number = $n; title = $title; body = $body; createdAt = $ripeNow.AddMinutes(-$minutes).ToString('o') } }
$r = Get-RipeHeldElsewhere -HeldIssues @((New-RipeHold 834 'system 1.0.250 held before prod' 96)) -Now $ripeNow -Name 'ui'
Test-Case 'ripe hold elsewhere: system past its window is yielded to' @($r.Deployable, $r.Version, $r.Number) @('system', '1.0.250', 834)
Test-Case 'ripe hold elsewhere: still inside the window is not' ($null -eq (Get-RipeHeldElsewhere -HeldIssues @((New-RipeHold 834 'system 1.0.250 held before prod' 30)) -Now $ripeNow -Name 'ui')) $true
Test-Case 'ripe hold elsewhere: mixed-flag hold (needs a person) is not' ($null -eq (Get-RipeHeldElsewhere -HeldIssues @((New-RipeHold 834 'system 1.0.250 held before prod' 96 $mixedRedHoldBody)) -Now $ripeNow -Name 'ui')) $true
Test-Case 'ripe hold elsewhere: older than the cap is not (no starvation)' ($null -eq (Get-RipeHeldElsewhere -HeldIssues @((New-RipeHold 834 'system 1.0.250 held before prod' 300)) -Now $ripeNow -Name 'ui')) $true
Test-Case 'ripe hold elsewhere: own deployable hold is not' ($null -eq (Get-RipeHeldElsewhere -HeldIssues @((New-RipeHold 834 'system 1.0.250 held before prod' 96)) -Now $ripeNow -Name 'system')) $true
$r = Get-RipeHeldElsewhere -HeldIssues @((New-RipeHold 9 'dashboard 1.0.1 held before prod' 70), (New-RipeHold 834 'system 1.0.250 held before prod' 96)) -Now $ripeNow -Name 'ui'
Test-Case 'ripe hold elsewhere: longest waiting wins' $r.Deployable 'system'

if ($failures -gt 0) { Write-Host "$failures case(s) failed."; exit 1 }
Write-Host 'All cases passed.'
# Actions' pwsh shell would otherwise exit with a leftover LASTEXITCODE from the nested probes above.
exit 0
