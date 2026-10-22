#!/usr/bin/env pwsh
#Requires -Version 7.5

<#
.SYNOPSIS
    Sets up the nightly space scorecard in the space's Octopus Deploy (step 2 of the design "Space-level scorecard on
    cmis"): a runner identity, a project with a runbook that runs Invoke-SpaceScorecard.ps1 -StoreFeed, and a daily
    trigger. Idempotent: a rerun changes only what differs, and publishes a new runbook snapshot only then.

.DESCRIPTION
    Run by the operator with the operator's key (OCTOPUS_ADMIN_API_KEY, else the kit's Get-OctopusApiKey): Space manager
    of the space, and the system permissions UserView, UserEdit, UserRoleView and UserRoleEdit (a user role, a service
    account and its API keys are not objects of a space; Space manager alone is refused them). What it makes, in the
    space of the configuration, the names from its "prefix" (cmdemo1 below):

      User role        "cmdemo1 scorecard store feed": FeedView, BuiltInFeedDownload and BuiltInFeedPush, nothing
                       else. No built-in role grants downloading from the built-in feed without much more (Build server
                       also creates releases, deployments and runbook runs and may delete any package; Space manager is
                       all), and Package publisher also pushes and deletes build information.
      Service account  cmdemo1-scorecard-runner (a user without a login), in the team
      Team             "cmdemo1 scorecard runner", of the space only, with the roles
                         Project viewer   (the space's projects, releases, deployments, lifecycles, environments,
                                          tasks: what discovery and cmis read; build information comes with releases)
                         cmdemo1 scorecard store feed (finds, downloads and pushes the store package; a push never
                                          replaces a version, which would need BuiltInFeedAdminister)
                       both unscoped within the space (feed permissions cannot be scoped to a project).
      API key          of the service account, put only into the sensitive project variable Scorecard.OctopusApiKey;
                       never printed. Needed when that variable is missing, the account has no key that is valid for
                       two more weeks (not while the variable holds the operator's own key), or with
                       -RotateOctopusKey. Octopus lets no AI agent's identity make an API key: run by the operator
                       (ai-ops is one), the script says so and a person makes the key in the portal
                       (Configuration > Users > cmdemo1-scorecard-runner > API keys, purpose "Scorecard.OctopusApiKey
                       of cmdemo1-scorecard-space", at most a year) and gives it with -ReadRunnerKey; the older keys are then deleted in the portal. Run with a person's own key, the
                       script makes it (and deletes the older ones of its purpose).
                       Until then, by Jeffrey's decision of 2026-10-22, -UseOperatorKey puts the operator's own key
                       there; the runner account and its team stay, unused.
      Project          cmdemo1-scorecard-space, in the project group and lifecycle of cmdemo1-system.
      Variables        Scorecard.GitHubToken (sensitive): the operator's "gh auth token", read in this process only;
                       set when missing or with -UpdateGitHubToken. Scorecard.SourceRef: the branch, tag or commit of
                       the source repository the runbook runs, prompted with default -SourceRef (main): a manual run
                       may name another to try a change before it merges.
      Runbook          "Refresh space scorecard", environment prod only, one "Run a Script" step on the worker pool
                       "Hosted Ubuntu", on the worker itself (its Ubuntu 24.04 image has PowerShell 7.6; give
                       -ContainerImage, for example octopusdeploy/worker-tools:6.6.5-ubuntu.24.04, should a later one
                       lack PowerShell 7.5), PowerShell: downloads the space-scorecard folder of the source repository at
                       Scorecard.SourceRef through the GitHub API (tarball) and runs
                       Invoke-SpaceScorecard.ps1 -Config space-scorecard/<prefix>.json -StoreFeed (the window: the
                       configuration's historyDays days up to today). Its snapshot is published when anything above
                       changed, when the published one froze another version of the project's variables (its notes
                       name it), with -Publish, or when none is published.
      Trigger          "Nightly space scorecard": every day 00:15 in the configuration's timeZone (-Schedule), the
                       published runbook in prod. Disabled while Scorecard.OctopusApiKey has no key.

    Whoever may run the runbook, or push a branch to the source repository, can run that branch's code with both
    secrets: a manual run may name any ref. Accepted for this demo space (both are the operator and the factory's
    agents); a manual run of another ref also pushes the store the next nightly run restores.

    Nothing secret is printed or written to disk.

.PARAMETER Config
    The space's configuration (space, octopusServer, prefix, timeZone). Default: cmdemo1.json next to this script.
.PARAMETER SourceRepository
    owner/repo of the repository whose space-scorecard folder the runbook runs.
.PARAMETER SourceRef
    The default of Scorecard.SourceRef.
.PARAMETER Environment
    The environment the runbook runs in and the trigger runs it in.
.PARAMETER WorkerPool
    The worker pool of the step.
.PARAMETER ContainerImage
    An execution container for the step; empty (the default): the step runs on the worker itself, which needs PowerShell
    7.5 or later (Hosted Ubuntu had 7.6.2 on 2026-10-22).
.PARAMETER ContainerFeed
    The Docker feed of the container image.
.PARAMETER Schedule
    The trigger's Octopus cron expression (seconds first), in the configuration's timeZone.
.PARAMETER RotateOctopusKey
    Makes a new API key for the runner, puts it in Scorecard.OctopusApiKey and deletes the older ones of its purpose.
    Octopus refuses this to an AI agent's identity (the operator's): use -ReadRunnerKey then.
.PARAMETER ReadRunnerKey
    Reads the runner's API key, made by a person in the Octopus portal, from a masked prompt (or one line of standard
    input), checks that it is the runner's own, and puts it in Scorecard.OctopusApiKey.
.PARAMETER UseOperatorKey
    Puts the operator's own key (the one this script runs with: OCTOPUS_ADMIN_API_KEY, else Get-OctopusApiKey) into
    Scorecard.OctopusApiKey in place of a runner key, by Jeffrey's decision of 2026-10-22 (Octopus lets the operator, an
    AI agent's identity, make no key for the runner). Read in this process only and never printed. The runner account
    and its team stay, unused, for a runner key later (-ReadRunnerKey replaces this one). Run it again after the
    operator's key changes.
.PARAMETER Publish
    Publishes a new runbook snapshot even when nothing changed (after a variable was changed in the portal).
.PARAMETER UpdateGitHubToken
    Puts the operator's current "gh auth token" into Scorecard.GitHubToken.
.PARAMETER KitCommon
    The kit's demo-common.ps1, for Get-OctopusApiKey when OCTOPUS_ADMIN_API_KEY is not set.
.EXAMPLE
    pwsh -NoProfile -File space-scorecard/setup-octopus.ps1
#>
[CmdletBinding()]
param(
    [string] $Config = (Join-Path $PSScriptRoot 'cmdemo1.json'),
    [string] $SourceRepository = 'clearmeasure-aisf-sample-apps/cmdemo1-system',
    [string] $SourceRef = 'main',
    [string] $Environment = 'prod',
    [string] $WorkerPool = 'Hosted Ubuntu',
    [string] $ContainerImage = '',
    [string] $ContainerFeed = 'docker-hub',
    [string] $Schedule = '0 15 0 * * *',
    [switch] $RotateOctopusKey,
    [switch] $ReadRunnerKey,
    [switch] $UseOperatorKey,
    [switch] $Publish,
    [switch] $UpdateGitHubToken,
    [string] $KitCommon = (Join-Path $HOME 'demo-platform-kit/.claude/skills/demo-environment/scripts/demo-common.ps1')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cfg = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json -AsHashtable
foreach ($key in 'space', 'octopusServer', 'prefix', 'timeZone') { if (-not $cfg[$key]) { throw "$Config`: '$key' is required." } }
$space = $cfg.space
if ($UseOperatorKey -and ($ReadRunnerKey -or $RotateOctopusKey)) { throw '-UseOperatorKey excludes -ReadRunnerKey and -RotateOctopusKey.' }
if ($SourceRef -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*\z' -or $SourceRef -match '\.\.') { throw "-SourceRef '$SourceRef' is not a branch, tag or commit name." }
$prefix = $cfg.prefix
$server = $cfg.octopusServer.TrimEnd('/')
$configName = Split-Path -Leaf $Config
$names = @{
    Role = "$prefix scorecard store feed"; Account = "$prefix-scorecard-runner"; Team = "$prefix scorecard runner"
    Project = "$prefix-scorecard-space"; Runbook = 'Refresh space scorecard'; Trigger = 'Nightly space scorecard'
    KeyPurpose = "Scorecard.OctopusApiKey of $prefix-scorecard-space"
}

# The key: in this process only.
$key = $env:OCTOPUS_ADMIN_API_KEY
if (-not $key) {
    if (-not (Test-Path -LiteralPath $KitCommon)) { throw "OCTOPUS_ADMIN_API_KEY is not set and $KitCommon is not there." }
    . $KitCommon
    $key = Get-OctopusApiKey
}

function Invoke-Octopus([string] $Path, [string] $Method = 'Get', $Body = $null) {
    $request = @{ Uri = "$server$Path"; Method = $Method; Headers = @{ 'X-Octopus-ApiKey' = $key } }
    if ($Method -eq 'Get') { $request.MaximumRetryCount = 3; $request.RetryIntervalSec = 10 }
    if ($null -ne $Body) { $request.Body = ConvertTo-Json -InputObject $Body -Depth 30 -Compress; $request.ContentType = 'application/json' }
    try { $content = (Invoke-WebRequest @request).Content }
    catch {
        $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { 0 }
        # The answer's message only: a request body (it may hold a secret) is never part of it.
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Octopus $($Method.ToUpperInvariant()) $Path failed (HTTP $status): $($detail -replace '\s+', ' ')"
    }
    if ($content) { $content | ConvertFrom-Json -AsHashtable -Depth 100 }
}

function Find-One($Items, [string] $Name, [string] $Property = 'Name') {
    $hit = @($Items | Where-Object { $_[$Property] -ceq $Name })
    if ($hit.Count -gt 1) { throw "More than one $Property '$Name'." }
    if ($hit.Count) { $hit[0] } else { $null }
}

function Get-ByName([string] $Path, [string] $Name, [string] $What) {
    $found = Find-One @(Invoke-Octopus $Path) $Name
    if (-not $found) { throw "No $What named '$Name' in $space." }
    $found
}

# An object found by its name is changed only when this script made it (its description or display name says so):
# another one of that name is not ours and stops the setup.
function Assert-Ours($Found, [string] $What, [string] $Text) {
    if ($Text -notmatch 'setup-octopus\.ps1|nightly space scorecard') { throw "$What '$($Found.Name)' ($($Found.Id)) exists and was not made by this script; not touched." }
}

# Two values the same as JSON (key order kept): what decides whether a PUT is needed.
function Test-Same($A, $B) { (ConvertTo-Json -InputObject $A -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject $B -Depth 30 -Compress) }

$changed = $false
$created = [ordered]@{}
$caller = Invoke-Octopus '/api/users/me'

# --- What the setup builds on ----------------------------------------------------------------------------------
$system = Get-ByName "/api/$space/projects/all" "$prefix-system" 'project'
$environmentId = (Get-ByName "/api/$space/environments/all" $Environment 'environment').Id
$workerPoolId = (Get-ByName "/api/$space/workerpools/all" $WorkerPool 'worker pool').Id
$containerFeedId = if ($ContainerImage) { (Get-ByName "/api/$space/feeds/all" $ContainerFeed 'feed').Id } else { $null }
$windowsZone = $null
if (-not [TimeZoneInfo]::TryConvertIanaIdToWindowsId($cfg.timeZone, [ref] $windowsZone)) { $windowsZone = $cfg.timeZone }
Write-Host "Space $space; project group $($system.ProjectGroupId) and lifecycle $($system.LifecycleId) of $($system.Name); $Environment = $environmentId; $WorkerPool = $workerPoolId; time zone $windowsZone"

# --- User role -------------------------------------------------------------------------------------------------
$roleBody = [ordered]@{
    Name = $names.Role
    Description = "Views the feeds of a space, downloads from its built-in feed and pushes new package versions to it (never replaces one). For the $prefix scorecard runner (space-scorecard/setup-octopus.ps1 of $SourceRepository)."
    GrantedSpacePermissions = @('FeedView', 'BuiltInFeedDownload', 'BuiltInFeedPush'); GrantedSystemPermissions = @()
}
$role = Find-One @(Invoke-Octopus '/api/userroles/all') $names.Role
if ($role) { Assert-Ours $role 'User role' $role.Description }
if (-not $role) { $role = Invoke-Octopus '/api/userroles' Post $roleBody; Write-Host "user role: created $($role.Id)" }
elseif (-not (Test-Same @($role.GrantedSpacePermissions | Sort-Object) @($roleBody.GrantedSpacePermissions | Sort-Object)) -or @($role.GrantedSystemPermissions).Count -or $role.Description -cne $roleBody.Description) {
    foreach ($k in 'GrantedSpacePermissions', 'GrantedSystemPermissions', 'Description') { $role[$k] = $roleBody[$k] }
    $role = Invoke-Octopus "/api/userroles/$($role.Id)" Put $role; Write-Host "user role: corrected $($role.Id)"
}
else { Write-Host "user role: $($role.Id) as it should be" }
$created.userRole = $role.Id

# --- Service account -------------------------------------------------------------------------------------------
$account = Find-One @((Invoke-Octopus "/api/users?filter=$([uri]::EscapeDataString($names.Account))&take=100").Items) $names.Account 'Username'
if (-not $account) {
    $account = Invoke-Octopus '/api/users' Post ([ordered]@{ Username = $names.Account; DisplayName = "$prefix scorecard runner (nightly space scorecard)"; IsService = $true; IsActive = $true })
    Write-Host "service account: created $($account.Id)"; $changed = $true
}
else {
    if (-not $account.IsService) { throw "User $($names.Account) ($($account.Id)) exists and is not a service account; not touched." }
    Assert-Ours $account 'Service account' $account.DisplayName
    Write-Host "service account: $($account.Id) there"
}
$created.serviceAccount = $account.Id

# --- Team and its roles ----------------------------------------------------------------------------------------
$team = Find-One @((Invoke-Octopus "/api/$space/teams?partialName=$([uri]::EscapeDataString($names.Team))&take=100").Items | Where-Object { $_.SpaceId -eq $space }) $names.Team
$teamDescription = "The $prefix nightly space scorecard (runbook '$($names.Runbook)' of $($names.Project)): reads the space, keeps its store in the built-in feed. Made by space-scorecard/setup-octopus.ps1."
if ($team) { Assert-Ours $team 'Team' $team.Description }
if (-not $team) {
    $team = Invoke-Octopus "/api/$space/teams" Post ([ordered]@{ Name = $names.Team; Description = $teamDescription; SpaceId = $space; MemberUserIds = @($account.Id); ExternalSecurityGroups = @() })
    Write-Host "team: created $($team.Id)"
}
elseif (-not (Test-Same @($team.MemberUserIds) @($account.Id)) -or $team.Description -cne $teamDescription) {
    $team.MemberUserIds = @($account.Id); $team.Description = $teamDescription
    $team = Invoke-Octopus "/api/$space/teams/$($team.Id)" Put $team; Write-Host "team: $($team.Id) set (members $($account.Id) only, description)"
}
else { Write-Host "team: $($team.Id) there" }
$created.team = $team.Id

$wantedRoles = @('userroles-projectviewer', $role.Id)
$held = @((Invoke-Octopus "/api/$space/teams/$($team.Id)/scopeduserroles?take=100").Items)
foreach ($r in $held) {
    $scoped = @($r.ProjectIds) + @($r.EnvironmentIds) + @($r.TenantIds) + @($r.ProjectGroupIds) | Where-Object { $_ }
    if ($r.UserRoleId -notin $wantedRoles -or $r.SpaceId -ne $space -or $scoped) {
        Invoke-Octopus "/api/$space/scopeduserroles/$($r.Id)" Delete | Out-Null; Write-Host "team role: removed $($r.UserRoleId) ($($r.Id))"
    }
}
$held = @((Invoke-Octopus "/api/$space/teams/$($team.Id)/scopeduserroles?take=100").Items)
$created.teamRoles = [ordered]@{}
foreach ($id in $wantedRoles) {
    $r = $held | Where-Object { $_.UserRoleId -eq $id } | Select-Object -First 1
    if (-not $r) {
        $r = Invoke-Octopus "/api/$space/scopeduserroles" Post ([ordered]@{ TeamId = $team.Id; UserRoleId = $id; SpaceId = $space; ProjectIds = @(); EnvironmentIds = @(); TenantIds = @(); ProjectGroupIds = @() })
        Write-Host "team role: added $id ($($r.Id)), the whole space"
    }
    $created.teamRoles[$id] = $r.Id
}

# --- Project ---------------------------------------------------------------------------------------------------
$projectDescription = "The nightly delivery scorecard of space $space (space-scorecard/ of $SourceRepository): runbook '$($names.Runbook)' harvests every project of the space with cmis, keeps the store as package $prefix-scorecard-store in the built-in feed, and attaches scorecard.html, summary.md and document.json to its task. No deployments; made by space-scorecard/setup-octopus.ps1."
$project = Find-One @(Invoke-Octopus "/api/$space/projects/all") $names.Project
if ($project) { Assert-Ours $project 'Project' $project.Description }
if (-not $project) {
    $project = Invoke-Octopus "/api/$space/projects" Post ([ordered]@{ Name = $names.Project; Description = $projectDescription; ProjectGroupId = $system.ProjectGroupId; LifecycleId = $system.LifecycleId })
    Write-Host "project: created $($project.Id)"; $changed = $true
}
elseif ($project.Description -cne $projectDescription -or $project.ProjectGroupId -ne $system.ProjectGroupId -or $project.LifecycleId -ne $system.LifecycleId) {
    $project.Description = $projectDescription; $project.ProjectGroupId = $system.ProjectGroupId; $project.LifecycleId = $system.LifecycleId
    $project = Invoke-Octopus "/api/$space/projects/$($project.Id)" Put $project; Write-Host "project: $($project.Id) corrected"
}
else { Write-Host "project: $($project.Id) there" }
$created.project = $project.Id

# --- Variables -------------------------------------------------------------------------------------------------
$variableSet = Invoke-Octopus "/api/$space/variables/$($project.VariableSetId)"
$variables = [Collections.Generic.List[object]]::new()
foreach ($v in @($variableSet.Variables)) { $variables.Add($v) }
function Find-ProjectVariable([string] $Name) { $variables | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1 }
$variablesChanged = $false

# The runner's API key. Octopus lets no AI agent's identity (a service account of type Agent, as the operator's
# ai-ops is) generate an API key, so a person makes it: in the Octopus portal (Configuration > Users > the account >
# API keys, the purpose below, at most a year) and gives it to this script with -ReadRunnerKey (a masked prompt, or
# one line on standard input). It is checked to be the runner's own key before it is stored. With a person's own key
# in OCTOPUS_ADMIN_API_KEY the script makes the key itself.
# -UseOperatorKey puts the operator's own key there instead (Jeffrey's decision of 2026-10-22); a variable that holds it
# needs no runner key until -ReadRunnerKey or -RotateOctopusKey replaces it.
$keys = @((Invoke-Octopus "/api/users/$($account.Id)/apikeys?take=100").Items)
$liveKeys = @($keys | Where-Object { -not $_.Expires -or [datetimeoffset] $_.Expires -gt [datetimeoffset]::UtcNow.AddDays(14) })
$keyVariable = Find-ProjectVariable 'Scorecard.OctopusApiKey'
$holdsOperatorKey = $keyVariable -and "$($keyVariable.Description)" -like "*operator's own key*"
$keyNeeded = $RotateOctopusKey -or -not $keyVariable -or (-not $holdsOperatorKey -and -not $liveKeys.Count)
$runnerKey = $null; $runnerKeyNote = $null; $madeKeyId = $null; $keyPending = $false; $keyDescription = $null
if ($UseOperatorKey) {
    $runnerKey = $key
    $keyDescription = "The operator's own key ($($caller.Username), $($caller.Id)), by Jeffrey's decision of 2026-10-22, in place of a key of service account $($names.Account), which Octopus lets no AI agent make; set by setup-octopus.ps1 -UseOperatorKey on $([datetime]::UtcNow.ToString('yyyy-MM-dd'))."
    Write-Host "API key: the operator's own ($($caller.Username)), by Jeffrey's decision of 2026-10-22"
}
elseif ($ReadRunnerKey) {
    $runnerKey = if ([Console]::IsInputRedirected) { "$([Console]::In.ReadLine())".Trim() } else { "$(Read-Host -Prompt "API key of $($names.Account) (purpose '$($names.KeyPurpose)')" -MaskInput)".Trim() }
    if ($runnerKey -cnotmatch '^API-[A-Z0-9]{20,}$') { throw 'That is not an Octopus API key (API-...); nothing stored.' }
    try { $owner = (Invoke-WebRequest -Uri "$server/api/users/me" -Headers @{ 'X-Octopus-ApiKey' = $runnerKey }).Content | ConvertFrom-Json -AsHashtable }
    catch { throw "Octopus does not accept that key (HTTP $(if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { 0 })); nothing stored." }
    if ($owner.Id -ne $account.Id) { throw "That key is $($owner.Username)'s, not $($names.Account)'s; nothing stored." }
    $runnerKeyNote = "given by a person (setup-octopus.ps1 -ReadRunnerKey) on $([datetime]::UtcNow.ToString('yyyy-MM-dd'))"
    Write-Host "API key: given, and it is $($names.Account)'s"
}
elseif ($keyNeeded -and $caller.ServiceAccountType -ceq 'Agent') {
    $keyPending = $true
    Write-Warning "Octopus lets no AI agent's identity ($($caller.Username) is one) make an API key for $($names.Account). A person makes it in the portal and runs this script again with -ReadRunnerKey (see the end)."
}
elseif ($keyNeeded) {
    try {
        $made = Invoke-Octopus "/api/users/$($account.Id)/apikeys" Post ([ordered]@{ Purpose = $names.KeyPurpose; Expires = [datetimeoffset]::UtcNow.AddDays(360).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture) })
        $runnerKey = $made.ApiKey; $madeKeyId = $made.Id
        $runnerKeyNote = "made by setup-octopus.ps1, expires $(([datetimeoffset] $made.Expires).ToString('yyyy-MM-dd'))"
        Write-Host "API key: made $madeKeyId for $($account.Id), expires $(([datetimeoffset] $made.Expires).ToString('yyyy-MM-dd')); only in Scorecard.OctopusApiKey"
        $made = $null
    }
    catch {
        if ("$_" -notmatch 'cannot be generated when authenticated as an AI agent|cannot exceed the expiry of the key used') { throw }
        $keyPending = $true
        Write-Warning "Octopus did not make an API key for $($names.Account) ($("$_" -replace '^.*?"Errors": \[\s*"([^"]+)".*$', '$1')). A person makes it in the portal and runs this script again with -ReadRunnerKey (see the end)."
    }
}
if ($runnerKey) {
    $v = Find-ProjectVariable 'Scorecard.OctopusApiKey'
    if (-not $v) { $v = [ordered]@{ Name = 'Scorecard.OctopusApiKey'; Type = 'Sensitive'; IsSensitive = $true; Scope = @{} }; $variables.Add($v) }
    $v.Value = $runnerKey; $v.Type = 'Sensitive'; $v.IsSensitive = $true
    $v.Description = if ($keyDescription) { $keyDescription } else { "API key of service account $($names.Account) (team '$($names.Team)'), $runnerKeyNote." }
    $variablesChanged = $true
    Remove-Variable v
}
if ($UpdateGitHubToken -or -not (Find-ProjectVariable 'Scorecard.GitHubToken')) {
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $token = (gh auth token 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $token) { throw '"gh auth token" gave no token.' }
        $v = Find-ProjectVariable 'Scorecard.GitHubToken'
        if (-not $v) { $v = [ordered]@{ Name = 'Scorecard.GitHubToken'; Type = 'Sensitive'; IsSensitive = $true; Scope = @{} }; $variables.Add($v) }
        $login = (gh api user --jq .login 2>$null | Out-String).Trim()
        $v.Value = $token; $v.Type = 'Sensitive'; $v.IsSensitive = $true
        $v.Description = "GitHub token of $login (the operator's gh login): reads the repositories of the space, the cmis release and the source of this runbook."
    }
    finally { Remove-Variable token, v -ErrorAction SilentlyContinue }
    $variablesChanged = $true
    Write-Host "GitHub token: set from the gh login of $login"
}
$refVariable = Find-ProjectVariable 'Scorecard.SourceRef'
$prompt = [ordered]@{ Label = 'Source ref'; Description = "Branch, tag or commit of $SourceRepository whose space-scorecard folder runs. The nightly run uses the default."; Required = $false; DisplaySettings = @{ 'Octopus.ControlType' = 'SingleLineText' } }
if (-not $refVariable) {
    $variables.Add([ordered]@{ Name = 'Scorecard.SourceRef'; Value = $SourceRef; Type = 'String'; IsSensitive = $false; Scope = @{}; Prompt = $prompt })
    $variablesChanged = $true
}
elseif ($refVariable.Value -cne $SourceRef -or -not (Test-Same $refVariable.Prompt $prompt)) {
    $refVariable.Value = $SourceRef; $refVariable.Prompt = $prompt; $variablesChanged = $true
}
if ($variablesChanged) {
    # A sensitive variable sent without its value (as Octopus answers it) keeps the value it has.
    $variableSet.Variables = @($variables)
    $saved = Invoke-Octopus "/api/$space/variables/$($project.VariableSetId)" Put $variableSet
    Write-Host "variables: saved ($(@($saved.Variables | ForEach-Object { $_.Name }) -join ', '))"
    $changed = $true
}
else { Write-Host 'variables: as they should be' }
$variableSet = $null; $variables = $null; $keyVariable = $null
$runnerKey = $null

# --- Runbook ---------------------------------------------------------------------------------------------------
$runbooks = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/runbooks?take=100").Items)
$runbook = Find-One $runbooks $names.Runbook
$runbookDescription = "Harvests every project of space $space with cmis (Invoke-SpaceScorecard.ps1 -StoreFeed of $SourceRepository at Scorecard.SourceRef), restores and pushes the store package $prefix-scorecard-store of the built-in feed, attaches scorecard.html, summary.md and document.json."
$runbookFields = [ordered]@{ Description = $runbookDescription; EnvironmentScope = 'Specified'; Environments = @($environmentId); MultiTenancyMode = 'Untenanted'; DefaultGuidedFailureMode = 'Off' }
if (-not $runbook) {
    $body = [ordered]@{ Name = $names.Runbook; ProjectId = $project.Id; RunRetentionPolicy = @{ QuantityToKeep = 30; ShouldKeepForever = $false } } + $runbookFields
    $runbook = Invoke-Octopus "/api/$space/runbooks" Post $body
    Write-Host "runbook: created $($runbook.Id)"; $changed = $true
}
elseif (@($runbookFields.Keys | Where-Object { -not (Test-Same $runbook[$_] $runbookFields[$_]) }).Count) {
    foreach ($k in $runbookFields.Keys) { $runbook[$k] = $runbookFields[$k] }
    $runbook = Invoke-Octopus "/api/$space/runbooks/$($runbook.Id)" Put $runbook; Write-Host "runbook: $($runbook.Id) corrected"; $changed = $true
}
else { Write-Host "runbook: $($runbook.Id) there" }
$created.runbook = $runbook.Id

# The step's script. Runs in the Octopus step (Calamari): the secrets come from the sensitive variables, into this
# process's environment only; the work directory is the step's own, which Octopus removes after the step (the
# artifacts are collected from it first).
$stepScript = @'
$ErrorActionPreference = 'Stop'
$repository = '#{SourceRepository}'
$ref = [string] $OctopusParameters['Scorecard.SourceRef']
if (-not $ref) { $ref = '#{DefaultRef}' }
if ($ref -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*\z' -or $ref -match '\.\.') { throw "Scorecard.SourceRef '$ref' is not a branch, tag or commit name." }
$env:GITHUB_TOKEN = $OctopusParameters['Scorecard.GitHubToken']
$env:OCTOPUS_API_KEY = $OctopusParameters['Scorecard.OctopusApiKey']
if (-not $env:GITHUB_TOKEN -or -not $env:OCTOPUS_API_KEY) { throw 'Scorecard.GitHubToken and Scorecard.OctopusApiKey must both be set (space-scorecard/setup-octopus.ps1).' }
Write-Host "PowerShell $($PSVersionTable.PSVersion) on $([Runtime.InteropServices.RuntimeInformation]::OSDescription)"

$work = Join-Path (Get-Location) 'space-scorecard-run'
$source = Join-Path $work 'source'
New-Item -ItemType Directory -Path $source -Force | Out-Null
$tarball = Join-Path $work 'source.tar.gz'
$headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
Invoke-WebRequest -Uri "https://api.github.com/repos/$repository/tarball/$ref" -Headers $headers -OutFile $tarball -MaximumRetryCount 2 -RetryIntervalSec 5 | Out-Null
tar -xzf $tarball -C $source --strip-components=1 --wildcards '*/space-scorecard/*'
if ($LASTEXITCODE -ne 0) { throw "Unpacking space-scorecard of $repository at $ref failed (exit $LASTEXITCODE)." }
Remove-Item -LiteralPath $tarball -Force

Write-Host "Source $repository at $ref"
& (Join-Path $source 'space-scorecard/Invoke-SpaceScorecard.ps1') -Config (Join-Path $source 'space-scorecard/#{ConfigName}') -WorkDir (Join-Path $work 'run') -StoreFeed
'@
# Line breaks as \n whatever the checkout has, so a CRLF checkout does not change the step on every run.
$stepScript = $stepScript.Replace('#{SourceRepository}', $SourceRepository).Replace('#{ConfigName}', $configName).Replace('#{DefaultRef}', $SourceRef) -replace "`r`n", "`n"

$process = Invoke-Octopus "/api/$space/runbookProcesses/$($runbook.RunbookProcessId)"
$existingStep = @($process.Steps) | Select-Object -First 1
$actionProperties = [ordered]@{
    'Octopus.Action.RunOnServer' = 'true'; 'Octopus.Action.Script.ScriptSource' = 'Inline'; 'Octopus.Action.Script.Syntax' = 'PowerShell'
    'Octopus.Action.Script.ScriptBody' = $stepScript
}
$container = if ($ContainerImage) { [ordered]@{ Image = $ContainerImage; FeedId = $containerFeedId } } else { [ordered]@{ Image = $null; FeedId = $null } }
$wanted = [ordered]@{ Name = $names.Runbook; WorkerPoolId = $workerPoolId; Container = $container; Properties = $actionProperties }
$current = if (@($process.Steps).Count -eq 1 -and @($existingStep.Actions).Count -eq 1) {
    $a = $existingStep.Actions[0]
    [ordered]@{ Name = $a.Name; WorkerPoolId = $a.WorkerPoolId; Container = [ordered]@{ Image = $a.Container.Image; FeedId = $a.Container.FeedId }
        Properties = [ordered]@{ 'Octopus.Action.RunOnServer' = $a.Properties['Octopus.Action.RunOnServer']; 'Octopus.Action.Script.ScriptSource' = $a.Properties['Octopus.Action.Script.ScriptSource']
            'Octopus.Action.Script.Syntax' = $a.Properties['Octopus.Action.Script.Syntax']; 'Octopus.Action.Script.ScriptBody' = $a.Properties['Octopus.Action.Script.ScriptBody'] } }
}
else { $null }
if (-not (Test-Same $current $wanted)) {
    $process.Steps = @([ordered]@{
            Name = $names.Runbook; Condition = 'Success'; StartTrigger = 'StartAfterPrevious'; PackageRequirement = 'LetOctopusDecide'; Properties = @{}
            Actions = @([ordered]@{
                    Name = $names.Runbook; ActionType = 'Octopus.Script'; IsDisabled = $false; IsRequired = $false; CanBeUsedForProjectVersioning = $false
                    WorkerPoolId = $workerPoolId; Container = $container; Environments = @(); ExcludedEnvironments = @(); Channels = @(); TenantTags = @()
                    Packages = @(); Properties = $actionProperties
                })
        })
    $process = Invoke-Octopus "/api/$space/runbookProcesses/$($process.Id)" Put $process
    Write-Host "runbook process: saved (one step, $(if ($ContainerImage) { "container $ContainerImage" } else { 'on the worker' }))"; $changed = $true
}
else { Write-Host 'runbook process: as it should be' }

$runbook = Invoke-Octopus "/api/$space/runbooks/$($runbook.Id)"
# A snapshot freezes the variables: its notes name the version of the project's variables it froze, and one that froze
# another version (a key or token changed here or in the portal, also by a run of this script that stopped before it
# published) is published again.
$variablesVersion = "variables v$((Invoke-Octopus "/api/$space/variables/$($project.VariableSetId)").Version)"
$stale = $true
if ($runbook.PublishedRunbookSnapshotId) {
    $published = Invoke-Octopus "/api/$space/runbookSnapshots/$($runbook.PublishedRunbookSnapshotId)"
    $stale = "$($published.Notes)" -notmatch "\b$([regex]::Escape($variablesVersion))\b"
}
if ($changed -or $Publish -or $stale) {
    $snapshot = Invoke-Octopus "/api/$space/runbookSnapshots?publish=true" Post ([ordered]@{
            ProjectId = $project.Id; RunbookId = $runbook.Id; Name = "Setup $([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
            Notes = "Published by space-scorecard/setup-octopus.ps1; $variablesVersion."
        })
    Write-Host "snapshot: published $($snapshot.Id) ($($snapshot.Name), $variablesVersion)"
    $created.snapshot = $snapshot.Id
}
else { Write-Host "snapshot: $($runbook.PublishedRunbookSnapshotId) published, nothing changed"; $created.snapshot = $runbook.PublishedRunbookSnapshotId }

# The older keys of the runner go only after a snapshot with the new one is published: a run that stops before that
# leaves the published snapshot a key that still works.
if ($madeKeyId) {
    foreach ($old in @($keys | Where-Object { $_.Purpose -ceq $names.KeyPurpose -and $_.Id -ne $madeKeyId })) {
        Invoke-Octopus "/api/users/$($account.Id)/apikeys/$($old.Id)" Delete | Out-Null; Write-Host "API key: deleted the older $($old.Id)"
    }
}

# --- Trigger ---------------------------------------------------------------------------------------------------
# Disabled while Scorecard.OctopusApiKey has no key: every run would fail. Enabled by the run that stores one.
$hasKey = [bool] ((Invoke-Octopus "/api/$space/variables/$($project.VariableSetId)").Variables | Where-Object { $_.Name -ceq 'Scorecard.OctopusApiKey' })
$triggers = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/triggers?take=100").Items)
$trigger = Find-One $triggers $names.Trigger
$filter = [ordered]@{ FilterType = 'CronExpressionSchedule'; CronExpression = $Schedule; Timezone = $windowsZone }
$action = [ordered]@{ ActionType = 'RunRunbook'; RunbookId = $runbook.Id; EnvironmentIds = @($environmentId); TenantIds = @(); TenantTags = @() }
$triggerDescription = "Schedule '$Schedule' (Octopus cron, seconds first) in $($cfg.timeZone): the published '$($names.Runbook)' in $Environment."
if (-not $trigger) {
    $trigger = Invoke-Octopus "/api/$space/projecttriggers" Post ([ordered]@{ Name = $names.Trigger; Description = $triggerDescription; ProjectId = $project.Id; IsDisabled = -not $hasKey; Filter = $filter; Action = $action })
    Write-Host "trigger: created $($trigger.Id) ($Schedule, $windowsZone)$(if (-not $hasKey) { ', disabled until the runner has a key' })"
}
else {
    $same = $trigger.Filter.FilterType -eq $filter.FilterType -and $trigger.Filter.CronExpression -ceq $Schedule -and $trigger.Filter.Timezone -ceq $windowsZone -and
    $trigger.Action.ActionType -eq 'RunRunbook' -and $trigger.Action.RunbookId -eq $runbook.Id -and (Test-Same @($trigger.Action.EnvironmentIds) @($environmentId)) -and [bool] $trigger.IsDisabled -eq (-not $hasKey) -and $trigger.Description -ceq $triggerDescription
    if (-not $same) {
        $trigger.Filter = $filter; $trigger.Action = $action; $trigger.IsDisabled = -not $hasKey; $trigger.Description = $triggerDescription
        $trigger = Invoke-Octopus "/api/$space/projecttriggers/$($trigger.Id)" Put $trigger; Write-Host "trigger: $($trigger.Id) set ($(if ($hasKey) { 'enabled' } else { 'disabled until the runner has a key' }))"
    }
    else { Write-Host "trigger: $($trigger.Id) there" }
}
$created.trigger = $trigger.Id

$key = $null
Write-Host ''
Write-Host (ConvertTo-Json -InputObject $created -Depth 5)
if (-not $hasKey -or $keyPending) {
    Write-Host ''
    Write-Host $(if ($hasKey) { "The runner needs a new key (it has none valid for two more weeks, or -RotateOctopusKey). A person (not an AI agent) makes one in the Octopus portal:" } else { "Not runnable yet: Scorecard.OctopusApiKey has no key. A person (not an AI agent) makes one in the Octopus portal:" })
    Write-Host "  Configuration > Users > $($names.Account) > API keys > New API key; purpose '$($names.KeyPurpose)', expiry at most a year"
    Write-Host "and gives it to this script, which checks it is $($names.Account)'s, stores it, publishes the runbook again and enables the trigger:"
    Write-Host "  pwsh -NoProfile -File $PSCommandPath -ReadRunnerKey"
    Write-Host "or, by Jeffrey's decision of 2026-10-22, puts the operator's own key there (and reruns that after the operator's key changes):"
    Write-Host "  pwsh -NoProfile -File $PSCommandPath -UseOperatorKey"
    exit 3
}
