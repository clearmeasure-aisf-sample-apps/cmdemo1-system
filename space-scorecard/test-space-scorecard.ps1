#!/usr/bin/env pwsh
#Requires -Version 7.5

<#
.SYNOPSIS
    Tests Invoke-SpaceScorecard.ps1 without network: discovery's resolution order (fake Octopus answers), the
    release-notes address rule, the connection ids and coordinates, the page and summary rendered from a small
    fixture, the store package (version, which one is restored, what it holds, restore against a fake feed), and the
    export and published site (release commit, content types, upload order, stale files, secrets kept out, the zip).
    PASS or FAIL per case; exit 1 on a FAIL.
.EXAMPLE
    pwsh -NoProfile -File space-scorecard/test-space-scorecard.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-SpaceScorecard.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $a = ConvertTo-Json -InputObject @($Actual | Where-Object { $null -ne $_ }) -Compress -Depth 5; $e = ConvertTo-Json -InputObject @($Expected | Where-Object { $null -ne $_ }) -Compress -Depth 5
    if ($a -ceq $e) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $e, got $a"; $script:failures++ }
}

$spaceConfig = @{
    space = 'Spaces-1'; octopusServer = 'https://octo.example/'; githubOwner = 'acme'; timeZone = 'America/Chicago'; historyDays = 90
    automation = @{ authors = @('github-actions[bot]', 'dependabot[bot]'); branches = @('^dependabot/.*$', '^a,b$'); commitMessages = @('^Pin \S+$', '^Template sync: .*$') }
    projects = @{ 'shop-ui' = @{ repo = 'shop-web' }; 'other-org' = @{ repo = 'partner/tool' }; 'shop-env' = @{ environments = 'tdd:TDD,prod:Delivered' } }
    exclude = @('Legacy', 'old-slug')
}

# --- Release-notes address -------------------------------------------------------------------------------------
function Repo($text) { $r = Get-GitHubRepositoryFromText $text; if ($r) { "$($r.Owner)/$($r.Repo)" } }
Test-Case 'notes: actions run address' (Repo 'Build https://github.com/acme/shop-api/actions/runs/123 of abc, committed 2026-10-14') 'acme/shop-api'
Test-Case 'notes: the first address wins' (Repo 'see https://github.com/acme/one and https://github.com/acme/two') 'acme/one'
Test-Case 'notes: .git is dropped' (Repo 'clone https://github.com/acme/shop.api.git') 'acme/shop.api'
Test-Case 'notes: a full stop ending the sentence is dropped' (Repo 'Built from https://github.com/acme/shop.') 'acme/shop'
Test-Case 'notes: in parentheses' (Repo '(https://github.com/acme/shop)') 'acme/shop'
Test-Case 'notes: in Markdown link' (Repo '[run](https://github.com/acme/shop-ui/pull/7)') 'acme/shop-ui'
Test-Case 'notes: http and capitals' (Repo 'HTTP://GitHub.com/Acme/Shop') 'Acme/Shop'
Test-Case 'notes: www.github.com' (Repo 'https://www.github.com/acme/shop') 'acme/shop'
Test-Case 'notes: ssh form' (Repo 'git@github.com:acme/shop.git') 'acme/shop'
Test-Case 'notes: project board address is skipped for the next' (Repo 'board https://github.com/orgs/acme/projects/1, code https://github.com/acme/shop') 'acme/shop'
Test-Case 'notes: gist is not a repository' (Repo 'https://gist.github.com/acme/abc') $null
Test-Case 'notes: other host is not GitHub' (Repo 'https://notgithub.com/acme/shop') $null
Test-Case 'notes: owner only' (Repo 'https://github.com/acme') $null
Test-Case 'notes: commit text without address' (Repo 'Commit 9ab3bdb: Kit templates (#245)') $null
Test-Case 'notes: empty' (Repo '') $null

# --- Discovery -------------------------------------------------------------------------------------------------
$releases = @{
    'Projects-1' = @{ Items = @(@{ Version = '1.0.1'; BuildInformation = @(@{ VcsRoot = 'https://github.com/acme/from-build.git' }); ReleaseNotes = 'https://github.com/acme/from-notes' }) }
    'Projects-2' = @{ Items = @(@{ Version = '2.0.0'; BuildInformation = @(); ReleaseNotes = 'Build https://github.com/acme/shop-api/actions/runs/9 of abc' }) }
    'Projects-3' = @{ Items = @(@{ Version = '1.0.134'; BuildInformation = @(); ReleaseNotes = 'Commit 9ab3: Kit templates (#245)' }) }
    'Projects-4' = @{ Items = @() }
    'Projects-5' = @{ Items = @(@{ Version = '3.1.0'; BuildInformation = $null; ReleaseNotes = $null }) }
    'Projects-6' = @{ Items = @(@{ Version = '1.0.0'; BuildInformation = @(); ReleaseNotes = 'https://github.com/acme/never-read' }) }
    'Projects-9' = @{ Items = @(@{ Version = '1.0.0'; BuildInformation = @(@{ VcsRoot = 'https://dev.azure.com/acme/_git/x' }, @{ VcsRoot = 'https://github.com/acme/second-build' }); ReleaseNotes = '' }) }
    'Projects-10' = @{ Items = @() }
    'Projects-12' = @{ Items = @(@{ Version = '4.0.0'; BuildInformation = @(); ReleaseNotes = 'Build https://github.com/acme/shop-old-name/actions/runs/5' }) }
    'Projects-13' = @{ Items = @(@{ Version = '1.2.0'; BuildInformation = @(); ReleaseNotes = 'see https://github.com/acme/ghost' }) }
    'Projects-14' = @{ Items = @(@{ Version = '1.0.0'; BuildInformation = @(); ReleaseNotes = 'nothing' }) }
    'Projects-15' = @{ Items = @() }
}
$projectsAnswer = @(
    @{ Id = 'Projects-1'; Name = 'shop-built'; Slug = 'shop-built'; IsDisabled = $false }
    @{ Id = 'Projects-2'; Name = 'shop-api'; Slug = 'shop-api'; IsDisabled = $false }
    @{ Id = 'Projects-3'; Name = 'shop-system'; Slug = 'shop-system'; IsDisabled = $false }
    @{ Id = 'Projects-4'; Name = 'shop-orphan'; Slug = 'shop-orphan'; IsDisabled = $false }
    @{ Id = 'Projects-5'; Name = 'shop-env'; Slug = 'shop-env'; IsDisabled = $false }
    @{ Id = 'Projects-6'; Name = 'shop-ui'; Slug = 'shop-ui'; IsDisabled = $false }
    @{ Id = 'Projects-7'; Name = 'Legacy'; Slug = 'legacy'; IsDisabled = $false }
    @{ Id = 'Projects-8'; Name = 'Retired'; Slug = 'retired'; IsDisabled = $true }
    @{ Id = 'Projects-9'; Name = 'shop-multi'; Slug = 'shop-multi'; IsDisabled = $false }
    @{ Id = 'Projects-10'; Name = 'Old Name'; Slug = 'old-slug'; IsDisabled = $false }
    @{ Id = 'Projects-11'; Name = 'other-org'; Slug = 'other-org'; IsDisabled = $false }
    @{ Id = 'Projects-12'; Name = 'shop-renamed'; Slug = 'shop-renamed'; IsDisabled = $false }
    @{ Id = 'Projects-13'; Name = 'shop-ghost'; Slug = 'shop-ghost'; IsDisabled = $false }
    @{ Id = 'Projects-14'; Name = 'shop-silent'; Slug = 'shop-silent'; IsDisabled = $false }
    @{ Id = 'Projects-15'; Name = 'Shop Display'; Slug = 'shop-display'; IsDisabled = $false }
)
$apiCalls = [Collections.Generic.List[string]]::new()
$fakeApi = {
    param($Path)
    $apiCalls.Add($Path)
    if ($Path -eq '/api/Spaces-1/projects/all') { return $projectsAnswer }
    if ($Path -match '^/api/Spaces-1/projects/(Projects-\d+)/releases\?take=1$') { return $releases[$Matches[1]] }
    throw "unexpected path $Path"
}.GetNewClosure()
$repoCalls = [Collections.Generic.List[string]]::new()
$fakeGitHub = { param($Owner, $Repo) $repoCalls.Add("$Owner/$Repo"); "$Owner/$Repo" -in 'acme/shop-system', 'acme/shop-env', 'acme/from-build', 'acme/second-build', 'acme/shop-api', 'acme/shop-renamed', 'acme/shop-display' }.GetNewClosure()
$found = @(Get-SpaceProjects $spaceConfig $fakeApi $fakeGitHub)
function Of([string] $Name) { @($found | Where-Object { $_.project -eq $Name })[0] }
function Mapping([string] $Name) { $p = Of $Name; if ($p.measured) { "$($p.owner)/$($p.repo) $($p.source)" } else { "not measured: $($p.reason)" } }

Test-Case 'discovery: every project listed, ordered by name' @($found | ForEach-Object { $_.project }) @('Legacy', 'Old Name', 'other-org', 'Retired', 'Shop Display', 'shop-api', 'shop-built', 'shop-env', 'shop-ghost', 'shop-multi', 'shop-orphan', 'shop-renamed', 'shop-silent', 'shop-system', 'shop-ui')
Test-Case 'discovery: configuration first, even with an address in the notes' (Mapping 'shop-ui') 'acme/shop-web config'
Test-Case 'discovery: configuration owner/repo form' (Mapping 'other-org') 'partner/tool config'
Test-Case 'discovery: configured repository asks nothing of Octopus' @($apiCalls | Where-Object { $_ -match 'Projects-(6|11)/' }) @()
Test-Case 'discovery: build information before release notes' (Mapping 'shop-built') 'acme/from-build build information'
Test-Case 'discovery: the first GitHub build information' (Mapping 'shop-multi') 'acme/second-build build information'
Test-Case 'discovery: release notes when no build information' (Mapping 'shop-api') 'acme/shop-api release notes'
Test-Case 'discovery: name when the notes have no address' (Mapping 'shop-system') 'acme/shop-system name'
Test-Case 'discovery: name when the release has neither' (Mapping 'shop-env') 'acme/shop-env name'
Test-Case 'discovery: no release and no repository of that name' (Mapping 'shop-orphan') 'not measured: no repository: not in the configuration, it has no release, and acme has no repository named shop-orphan'
Test-Case 'discovery: a release without an address and no repository of that name' (Mapping 'shop-silent') 'not measured: no repository: not in the configuration, release 1.0.0 has no build information or GitHub address in its notes, and acme has no repository named shop-silent'
Test-Case 'discovery: an address of a repository GitHub does not have falls through to the name' (Mapping 'shop-renamed') 'acme/shop-renamed name'
Test-Case 'discovery: an address GitHub does not have, and no name either' (Mapping 'shop-ghost') 'not measured: no repository: not in the configuration, acme/ghost of its release notes does not exist, and acme has no repository named shop-ghost'
Test-Case 'discovery: the name rule tries the slug first' (Mapping 'Shop Display') 'acme/shop-display name'
Test-Case 'discovery: what is asked of GitHub, in order' @($repoCalls) @('acme/shop-display', 'acme/shop-api', 'acme/from-build', 'acme/shop-env', 'acme/ghost', 'acme/shop-ghost', 'acme/second-build', 'acme/shop-orphan', 'acme/shop-old-name', 'acme/shop-renamed', 'acme/shop-silent', 'acme/shop-system')
Test-Case 'discovery: a failing GitHub check stops discovery' $(try { Resolve-ProjectRepository $spaceConfig @{ Id = 'Projects-4'; Name = 'x'; Slug = 'x' } $fakeApi { throw 'rate limited' } | Out-Null; 'went on' } catch { 'stopped' }) 'stopped'
Test-Case 'discovery: disabled project' (Mapping 'Retired') 'not measured: disabled in Octopus'
Test-Case 'discovery: excluded by name' (Mapping 'Legacy') 'not measured: excluded by the configuration'
Test-Case 'discovery: excluded by slug' (Mapping 'Old Name') 'not measured: excluded by the configuration'
Test-Case 'discovery: excluded and disabled projects ask nothing' @($apiCalls | Where-Object { $_ -match 'Projects-(7|8|10)/' }) @()
Test-Case 'discovery: environments from the configuration' ((Of 'shop-env').environments) 'tdd:TDD,prod:Delivered'
Test-Case 'discovery: environments auto by default' ((Of 'shop-api').environments) 'auto'
Test-Case 'discovery: connection id is the slug' ((Of 'shop-api').connectionId) 'shop-api'
Test-Case 'discovery: not measured has no connection' ((Of 'Retired').connectionId) $null

# --- Connection ids, credentials, coordinates ------------------------------------------------------------------
Test-Case 'id: slug kept' (ConvertTo-ConnectionId 'cmdemo1-ui') 'cmdemo1-ui'
Test-Case 'id: lower case' (ConvertTo-ConnectionId 'CmDemo1-UI') 'cmdemo1-ui'
Test-Case 'credential prefix: dashes to underscores, upper case' (ConvertTo-CredentialPrefix 'cmdemo1-ui') 'CMIS_CMDEMO1_UI'
Test-Case 'credential prefix: digits kept' (ConvertTo-CredentialPrefix 'app2-ui-3') 'CMIS_APP2_UI_3'
$entries = @(
    [ordered]@{ connectionId = 'b'; projectId = 'Projects-982' }
    [ordered]@{ connectionId = 'a'; projectId = 'Projects-1046' }
    [ordered]@{ connectionId = 'c'; projectId = 'Projects-981' }
)
$fresh = Get-ItemNumberBases $entries @{}
Test-Case 'bases: fresh, in project id order' @($fresh['c'], $fresh['b'], $fresh['a']) @(1000000, 2000000, 3000000)
$kept = Get-ItemNumberBases $entries @{ a = 1000000; b = 3000000 }
Test-Case 'bases: existing kept, a new one gets the lowest free' @($kept['a'], $kept['b'], $kept['c']) @(1000000, 3000000, 2000000)
$reserved = Get-ItemNumberBases $entries @{ a = 1000000; gone = 2000000 }
Test-Case 'bases: the base of a connection no longer measured stays taken' @($reserved['a'], $reserved['c'], $reserved['b']) @(1000000, 3000000, 4000000)
$entry = [ordered]@{ owner = 'acme'; repo = 'shop-web'; slug = 'shop-ui'; environments = 'auto' }
$coordinates = Get-ConnectionCoordinates $spaceConfig $entry 2000000
Test-Case 'coordinates: keys' @($coordinates.Keys) @('owner', 'repo', 'octopusServer', 'octopusSpace', 'octopusProject', 'environments', 'itemNumberBase', 'automationAuthors', 'automationBranches', 'automationCommitMessages')
Test-Case 'coordinates: server without trailing slash, project slug' @($coordinates.octopusServer, $coordinates.octopusProject, $coordinates.itemNumberBase) @('https://octo.example', 'shop-ui', '2000000')
Test-Case 'coordinates: logins joined with commas' $coordinates.automationAuthors 'github-actions[bot],dependabot[bot]'
Test-Case 'coordinates: patterns one per line (a pattern may hold a comma)' $coordinates.automationBranches "^dependabot/.*`$`n^a,b`$"
Test-Case 'coordinates: commit messages one per line' $coordinates.automationCommitMessages "^Pin \S+`$`n^Template sync: .*`$"
Test-Case 'coordinates: same' (Test-SameCoordinates (@{} + $coordinates) $coordinates) $true
$other = [ordered]@{} + $coordinates; $other.environments = 'tdd:TDD'
Test-Case 'coordinates: a changed value differs' (Test-SameCoordinates $other $coordinates) $false
$less = [ordered]@{} + $coordinates; $less.Remove('automationAuthors')
Test-Case 'coordinates: a missing key differs' (Test-SameCoordinates $less $coordinates) $false
Test-Case 'action: new connection is added' (Get-ConnectionAction $null $coordinates $false) 'add'
Test-Case 'action: same coordinates are an update (no change)' (Get-ConnectionAction (@{} + $coordinates) $coordinates $true) 'update'
Test-Case 'action: a changed value without data is an update' (Get-ConnectionAction $other $coordinates $false) 'update'
Test-Case 'action: a key to drop without data is a replace' (Get-ConnectionAction $coordinates $less $false) 'replace'
Test-Case 'action: a key to add without data is a replace' (Get-ConnectionAction $less $coordinates $false) 'replace'
Test-Case 'action: other coordinates with data start the store again' (Get-ConnectionAction $other $coordinates $true) 'restart'
$hw = @{ Since = '2026-09-13'; Until = '2026-10-21'; HarvestUntil = '2026-10-22' }
Test-Case 'harvest: nothing stored is a harvest of the window' (Get-HarvestArguments 'x' $false '' $hw) @('connections', 'harvest', '--connection', 'x', '--since', '2026-09-13', '--until', '2026-10-22', '--on-failure', 'strict')
Test-Case 'harvest: stored, same Since is a sync from the watermark' (Get-HarvestArguments 'x' $true '2026-09-13' $hw) @('connections', 'sync', '--connection', 'x', '--until', '2026-10-22', '--on-failure', 'strict')
Test-Case 'harvest: stored, later Since is a sync from the watermark' (Get-HarvestArguments 'x' $true '2026-09-01' $hw) @('connections', 'sync', '--connection', 'x', '--until', '2026-10-22', '--on-failure', 'strict')
Test-Case 'harvest: stored, earlier Since widens the sync' (Get-HarvestArguments 'x' $true '2026-10-01' $hw) @('connections', 'sync', '--connection', 'x', '--since', '2026-09-13', '--until', '2026-10-22', '--on-failure', 'strict')
Test-Case 'harvest: stored, first day unknown syncs from Since' (Get-HarvestArguments 'x' $true '' $hw) @('connections', 'sync', '--connection', 'x', '--since', '2026-09-13', '--until', '2026-10-22', '--on-failure', 'strict')

# --- Small rules -----------------------------------------------------------------------------------------------
$sums = "bea6  x`nbea6bc4b011bbc3e0c4307821b832671bb3befbf30c8f6da0643dddfa29f9960  cmis-1-linux-x64.tar.gz`n7A15FC992A96B1BA27FEF0E9E8787AAE07A09C01AFD18074E959755679544939 *cmis-1-win-x64.zip"
Test-Case 'checksum: text mode line' (Get-ExpectedSha256 $sums 'cmis-1-linux-x64.tar.gz') 'bea6bc4b011bbc3e0c4307821b832671bb3befbf30c8f6da0643dddfa29f9960'
Test-Case 'checksum: binary mode line, lower-cased' (Get-ExpectedSha256 $sums 'cmis-1-win-x64.zip') '7a15fc992a96b1ba27fef0e9e8787aae07a09c01afd18074e959755679544939'
Test-Case 'checksum: no line' (Get-ExpectedSha256 $sums 'cmis-1-osx.tar.gz') $null
$w = Resolve-Window $spaceConfig '' '' ([datetime]::new(2026, 10, 22, 2, 30, 0, [DateTimeKind]::Utc))
Test-Case 'window: today in the zone, history days long, harvest one day further' @($w.Since, $w.Until, $w.HarvestUntil) @('2026-07-24', '2026-10-21', '2026-10-22')
$w = Resolve-Window $spaceConfig '2026-09-13' '2026-10-21'
Test-Case 'window: as given' @($w.Since, $w.Until, $w.HarvestUntil) @('2026-09-13', '2026-10-21', '2026-10-22')
Test-Case 'duration: none' (Format-Duration $null) '–'
Test-Case 'duration: seconds' (Format-Duration (30 / 604800)) '30 s'
Test-Case 'duration: 87 minutes' (Format-Duration (87 / 10080)) '87 min'
Test-Case 'duration: 90 minutes is hours' (Format-Duration (90 / 10080)) '1.5 h'
Test-Case 'duration: cmis weeks to hours (cmdemo1-workorders, Sep 28)' (Format-Duration 0.03436200677910053) '5.8 h'
Test-Case 'duration: 48 hours is days' (Format-Duration (2 / 7)) '2.0 d'
$periods = @(
    @{ periodStart = '2026-09-07T00:00:00+00:00'; label = 'W37 2026-09-07'; itemsStarted = 0; itemsDelivered = 0; workInProcess = 0; throughput = 0; rework = 0; meanTimeToDelivery = $null }
    @{ periodStart = '2026-09-14T00:00:00+00:00'; label = 'W38 2026-09-14'; itemsStarted = 2; itemsDelivered = 0; workInProcess = 2; throughput = 1; rework = 0; meanTimeToDelivery = $null }
    @{ periodStart = '2026-09-21T00:00:00+00:00'; label = 'W39 2026-09-21'; itemsStarted = 0; itemsDelivered = 0; workInProcess = 2; throughput = 0; rework = 0; meanTimeToDelivery = $null }
)
$weeks = Get-PageWeeks $periods @{ Since = '2026-09-13'; Until = '2026-09-23' }
Test-Case 'weeks: leading empty weeks left out' @($weeks | ForEach-Object { $_.start }) @('2026-09-14', '2026-09-21')
Test-Case 'weeks: a week past Until is partial' @($weeks | ForEach-Object { $_.partial }) @($false, $true)
Test-Case 'weeks: a week before Since is partial' @((Get-PageWeeks $periods @{ Since = '2026-09-16'; Until = '2026-09-27' })[0].partial) @($true)

# --- Drill items and locating them -----------------------------------------------------------------------------
$located = @([ordered]@{ owner = 'acme'; repo = 'one'; itemNumberBase = 1000000 }, [ordered]@{ owner = 'acme'; repo = 'two'; itemNumberBase = 2000000 })
$item = ConvertTo-DrillItem @{ itemNumber = 2000042; title = 'Secret plan'; sourceWorkItemType = 'Pull Request'; oldStatus = 'UAT'; newStatus = 'Delivered'; revisionDate = '2026-10-03T09:02:11.966+00:00' } $located
Test-Case 'drill item: repository and own number from the base' @($item.repo, $item.number, $item.kind) @('two', 42, 'pull request')
Test-Case 'drill item: no title kept' ($item.Contains('title')) $false
Test-Case 'drill item: issue kind' (ConvertTo-DrillItem @{ itemNumber = 1000007; sourceWorkItemType = ''; oldStatus = ''; newStatus = 'Created'; revisionDate = '' } $located).kind 'issue'
Test-Case 'drill item: commit kind' (ConvertTo-DrillItem @{ itemNumber = 1961170; sourceWorkItemType = 'Commit'; oldStatus = ''; newStatus = 'Created'; revisionDate = '' } $located).kind 'direct commit'

# --- Rendering from a fixture ----------------------------------------------------------------------------------
$fixtureProject = [ordered]@{ project = 'shop-api'; slug = 'shop-api'; owner = 'acme'; repo = 'shop-api'; source = 'release notes'; environments = 'auto'; measured = $true; reason = $null; connectionId = 'shop-api'; itemNumberBase = 1000000 }
$fixture = @{
    space = 'Spaces-1'; octopusServer = 'https://octo.example'; githubOwner = 'acme'; timeZone = 'America/Chicago'
    since = '2026-09-28'; until = '2026-10-14'; generatedUtc = '2026-10-15T01:00:00Z'
    cmis = @{ version = '1.0.3713-delivery.3'; commit = '5319666f4561c2be5a9a521c2d470ea910fd24a4' }
    projects = @(
        $fixtureProject
        @{ project = 'Retired'; slug = 'retired'; owner = $null; repo = $null; source = $null; environments = $null; measured = $false; reason = 'disabled in Octopus'; connectionId = $null }
    )
    weeks = @(@{ start = '2026-09-28'; label = 'W40 2026-09-28'; partial = $false }, @{ start = '2026-10-05'; label = 'W41 2026-10-05'; partial = $false }, @{ start = '2026-10-12'; label = 'W42 2026-10-12'; partial = $true })
    scopes = @(
        @{ id = '_space'; title = 'Space Spaces-1'
            periods = @{
                '2026-09-28' = @{ workInProcess = 1; itemsStarted = 3; itemsDelivered = 2; meanTimeToDelivery = (87 / 10080); throughput = 11; rework = 1; netThroughput = 10 }
                '2026-10-05' = @{ workInProcess = 0; itemsStarted = 0; itemsDelivered = 1; meanTimeToDelivery = 0.03436200677910053; throughput = 4; rework = 0; netThroughput = 4 }
                '2026-10-12' = @{ workInProcess = 0; itemsStarted = 0; itemsDelivered = 0; meanTimeToDelivery = $null; throughput = 0; rework = 0; netThroughput = 0 }
            }
            drills = @{
                # As the compute step makes it from a cmis drill item, which carries a title.
                'workInProcess|2026-09-28' = @(ConvertTo-DrillItem @{ itemNumber = 1000012; title = 'Secret plan'; sourceWorkItemType = 'Pull Request'; oldStatus = 'Development'; newStatus = 'In Review'; revisionDate = '2026-10-04T20:53:26+00:00' } @($fixtureProject))
                'itemsStarted|2026-09-28' = @(
                    @{ owner = 'acme'; repo = 'shop-api'; number = 12; kind = 'pull request'; from = ''; to = 'Created'; at = '2026-09-29T10:00:00+00:00' }
                    @{ owner = 'acme'; repo = 'shop-api'; number = 13; kind = 'issue'; from = ''; to = 'Created'; at = '2026-09-30T10:00:00+00:00' }
                    @{ owner = 'acme'; repo = 'shop-api'; number = 961170; kind = 'direct commit'; from = ''; to = 'Created'; at = '2026-09-30T11:00:00+00:00' })
                'itemsDelivered|2026-09-28' = @(
                    @{ owner = 'acme'; repo = 'shop-api'; number = 13; kind = 'issue'; from = 'UAT'; to = 'Delivered'; at = '2026-10-01T10:00:00+00:00' }
                    @{ owner = 'acme'; repo = 'shop-api'; number = 961170; kind = 'direct commit'; from = 'UAT'; to = 'Delivered'; at = '2026-10-01T11:00:00+00:00' })
                'itemsDelivered|2026-10-05' = @(@{ owner = 'acme'; repo = 'shop-api'; number = 12; kind = 'pull request'; from = 'UAT'; to = 'Delivered'; at = '2026-10-06T10:00:00+00:00' })
            }
        }
        @{ id = 'shop-api'; title = 'shop-api'
            periods = @{ '2026-09-28' = @{ workInProcess = 1; itemsStarted = 3; itemsDelivered = 2; meanTimeToDelivery = (87 / 10080); throughput = 11; rework = 1; netThroughput = 10 } }
            drills = @{ 'itemsDelivered|2026-09-28' = @(@{ owner = 'acme'; repo = 'shop-api'; number = 13; kind = 'issue'; from = 'UAT'; to = 'Delivered'; at = '2026-10-01T10:00:00+00:00' }, @{ owner = 'acme'; repo = 'shop-api'; number = 961170; kind = 'direct commit'; from = 'UAT'; to = 'Delivered'; at = '2026-10-01T11:00:00+00:00' }) }
        }
    )
    warnings = @()
}
$html = ConvertTo-ScorecardHtml $fixture
$hrefs = @([regex]::Matches($html, 'href="#([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$ids = @([regex]::Matches($html, '\sid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
Test-Case 'page: every in-page link has its anchor' @($hrefs | Where-Object { $_ -notin $ids }) @()
Test-Case 'page: anchors are unique' ($ids.Count -eq @($ids | Sort-Object -Unique).Count) $true
Test-Case 'page: the space numbers link to their lists' @('d-_space-wip-2026-09-28', 'd-_space-started-2026-09-28', 'd-_space-delivered-2026-09-28', 'd-_space-delivered-2026-10-05' | Where-Object { $html -notmatch "<a href=`"#$_`">\d+</a>" }) @()
Test-Case 'page: a number shows its value' ($html -match '<a href="#d-_space-started-2026-09-28">3</a>') $true
Test-Case 'page: a zero has no link' ($html -match 'href="#d-_space-started-2026-10-05"') $false
Test-Case 'page: a project week without numbers is a dash' ($html -match 'Items delivered</th><td><a href="#d-shop-api-delivered-2026-09-28">2</a></td><td class="none">–</td><td class="none">–</td></tr>') $true
Test-Case 'page: a project number without a list has no link' ($html -match 'Items started</th><td>3</td><td class="none">–</td>') $true
Test-Case 'page: MTTD under 90 minutes in minutes' ($html -match '<td>87 min</td>') $true
Test-Case 'page: MTTD in hours' ($html -match '<td>5.8 h</td>') $true
Test-Case 'page: rework in the folded panel' ($html -match '<details class="detail"><summary>Flow detail[^<]*</summary><div class="scroll"><table>[\s\S]*?Rework</th><td>1</td>') $true
Test-Case 'page: item links to its issue address' ($html -match '<a href="https://github.com/acme/shop-api/issues/13">shop-api#13</a>') $true
Test-Case 'page: project list names its own numbers' ($html -match '<a href="https://github.com/acme/shop-api/issues/13">#13</a>') $true
Test-Case 'page: a direct commit has no issue link' ($html -match 'issues/961170') $false
Test-Case 'page: a direct commit is named by its item number' ($html -match '<span>shop-api item 961170</span> <span class="kind">direct commit</span>') $true
Test-Case 'page: the item made from a drill item links to its pull request' ($html -match '<a href="https://github.com/acme/shop-api/issues/12">shop-api#12</a> <span class="kind">pull request</span> <span class="move">Development → In Review</span>') $true
Test-Case 'page: partial week marked' ($html -match 'Oct 12\*</th>') $true
Test-Case 'page: not measured with its reason' ($html -match 'Retired: not measured, disabled in Octopus') $true
Test-Case 'page: mapping source shown' ($html -match 'repository from release notes') $true
Test-Case 'page: cmis version and commit' ($html -match 'cmis 1\.0\.3713-delivery\.3 \(5319666f4561\)') $true
Test-Case 'page: no title of any item' ($html -match 'Secret plan') $false
Test-Case 'data: no title of any item' ((ConvertTo-Json -InputObject $fixture -Depth 20) -match 'Secret plan') $false
Test-Case 'page: no script, no external stylesheet or image' ($html -match '<script|<link |<img |@import|url\(') $false
Test-Case 'page: dark and light' ($html -match 'prefers-color-scheme: dark') $true
Test-Case 'page: phone width' ($html -match 'name="viewport"') $true
$md = ConvertTo-SummaryMarkdown $fixture
Test-Case 'summary: no title of any item' ($md -match 'Secret plan') $false
Test-Case 'summary: space table row' ($md -match '\| Items started \| 3 \| 0 \| 0 \|') $true
Test-Case 'summary: MTTD row' ($md -match '\| Mean time to delivery \(MTTD\) \| 87 min \| 5\.8 h \| – \|') $true
Test-Case 'summary: one line per project, last full week' ($md -match '- shop-api \(acme/shop-api\): started 0, delivered 0, WIP 0, MTTD –') $true
Test-Case 'summary: last full week is the one before the partial one' ($md -match '## Projects, week of 2026-10-05') $true
Test-Case 'summary: measured and not measured' @(($md -match '- shop-api: measured, acme/shop-api \(from release notes\)'), ($md -match '- Retired: not measured, disabled in Octopus')) @($true, $true)

# --- Week headings, Markdown text, configuration --------------------------------------------------------------
Test-Case 'week labels: the year where it changes' @(Get-WeekLabels @(@{ start = '2026-12-21'; partial = $false }, @{ start = '2026-12-28'; partial = $false }, @{ start = '2027-01-04'; partial = $true })) @('Dec 21', 'Dec 28', 'Jan 4 2027*')
Test-Case 'markdown: one line, table and emphasis characters escaped' (ConvertTo-MarkdownText "a|b *c*`nd_e") 'a\|b \*c\* d\_e'
$configFile = Join-Path ([IO.Path]::GetTempPath()) "space-scorecard-test-$([guid]::NewGuid().ToString('N')).json"
function Read-Fixture([hashtable] $Override) {
    $c = @{ space = 'Spaces-1'; octopusServer = 'https://octo.example'; githubOwner = 'acme'; cmisVersion = '1'; cmisRepo = 'o/r'; automation = @{ authors = @(' bot ', 'bot', ''); branches = @('^a$') } }
    foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
    ConvertTo-Json -InputObject $c -Depth 5 | Set-Content -LiteralPath $configFile
    try { Read-SpaceConfig $configFile } catch { "refused: $($_.Exception.Message -replace '^.*?: ', '')" }
}
$read = Read-Fixture @{}
Test-Case 'config: defaults' @($read.timeZone, $read.historyDays, $read.exclude.Count, $read.automation.commitMessages.Count) @('UTC', 90, 0, 0)
Test-Case 'config: automation lists trimmed, without blanks and repeats' @($read.automation.authors) @('bot')
Test-Case 'config: an http server is refused' (Read-Fixture @{ octopusServer = 'http://octo.example' }) "refused: 'octopusServer' must be an https:// address (the API key is sent to it)."
Test-Case 'config: zero history days is refused' (Read-Fixture @{ historyDays = 0 }) "refused: 'historyDays' must be a whole number of days, 1 or more."
Test-Case 'config: an invalid pattern is refused' (Read-Fixture @{ automation = @{ branches = @('([') } }) 'refused: automation.branches holds an invalid regular expression: (['
Test-Case 'config: a prefix that cannot begin a package id is refused' (Read-Fixture @{ prefix = 'Cm Demo' }) "refused: 'prefix' must be lower case letters, digits and '-' (it begins a package id)."
Test-Case 'config: prefix kept' (Read-Fixture @{ prefix = 'cmdemo1' }).prefix 'cmdemo1'
$scorecard = @{ scorecardVersion = '1.0.40'; scorecardRepo = 'acme/scorecard'; scorecardProject = 'acme-scorecard' }
Test-Case 'config: scorecard release kept' (Read-Fixture $scorecard).scorecardVersion '1.0.40'
Test-Case 'config: a scorecard version that is no release number is refused' (Read-Fixture @{ scorecardVersion = 'latest'; scorecardRepo = 'acme/scorecard'; scorecardProject = 'p' }) "refused: 'scorecardVersion' must be a release number such as 1.0.40."
Test-Case 'config: a scorecard version without its repository is refused' (Read-Fixture @{ scorecardVersion = '1.0.40'; scorecardProject = 'p' }) "refused: 'scorecardRepo' (owner/repo) is required with 'scorecardVersion'."
Test-Case 'config: a scorecard version without its project is refused' (Read-Fixture @{ scorecardVersion = '1.0.40'; scorecardRepo = 'acme/scorecard' }) "refused: 'scorecardProject' (the Octopus project of the release) is required with 'scorecardVersion'."
Test-Case 'config: site kept' (Read-Fixture ($scorecard + @{ site = @{ account = 'stacme01'; container = 'scorecard' } })).site.container 'scorecard'
Test-Case 'config: a site without a scorecard version is refused' (Read-Fixture @{ site = @{ account = 'stacme01'; container = 'scorecard' } }) "refused: 'site' needs 'scorecardVersion': the published pages are the export's."
Test-Case 'config: a site account with capitals is refused' (Read-Fixture @{ site = @{ account = 'StAcme'; container = 'scorecard' } }) "refused: 'site' needs 'account' (a storage account name) and 'container' (a blob container name)."
Test-Case 'config: a site without container is refused' (Read-Fixture @{ site = @{ account = 'stacme01' } }) "refused: 'site' needs 'account' (a storage account name) and 'container' (a blob container name)."
Remove-Item -LiteralPath $configFile -Force

# --- Store in the built-in feed --------------------------------------------------------------------------------
function Utc([int] $Y, [int] $Mo, [int] $D, [int] $H, [int] $Mi, [int] $Se = 0) { [datetime]::new($Y, $Mo, $D, $H, $Mi, $Se, [DateTimeKind]::Utc) }
Test-Case 'store id: prefix and -scorecard-store' (Get-StorePackageId @{ prefix = 'cmdemo1' }) 'cmdemo1-scorecard-store'
Test-Case 'store id: no prefix is refused' $(try { Get-StorePackageId @{} } catch { 'refused' }) 'refused'
Test-Case 'store version: yyyy.M.d.HHmmss in UTC' (Get-StorePackageVersion (Utc 2026 10 22 5 15 7)) '2026.10.22.51507'
Test-Case 'store version: no leading zeros (00:15:00 is 1500)' (Get-StorePackageVersion (Utc 2027 1 2 0 15)) '2027.1.2.1500'
Test-Case 'store version: midnight is 1, never .0' (Get-StorePackageVersion (Utc 2026 10 22 0 0)) '2026.10.22.1'
Test-Case 'store version: last second of the day' (Get-StorePackageVersion (Utc 2026 12 31 23 59 59)) '2026.12.31.235959'
Test-Case 'store version: two runs in one minute differ' ((Get-StorePackageVersion (Utc 2026 10 22 0 15 1)) -ne (Get-StorePackageVersion (Utc 2026 10 22 0 15 2))) $true
Test-Case 'store version: a time that is not UTC is refused' $(try { Get-StorePackageVersion ([datetime]::new(2026, 10, 22, 5, 15, 0, [DateTimeKind]::Local)) } catch { 'refused' }) 'refused'
$v0015 = [version] (Get-StorePackageVersion (Utc 2026 10 22 0 15)); $v0905 = [version] (Get-StorePackageVersion (Utc 2026 10 22 9 5))
$vLate = [version] (Get-StorePackageVersion (Utc 2026 10 9 23 15)); $vNext = [version] (Get-StorePackageVersion (Utc 2026 10 10 0 15))
$v0959 = [version] (Get-StorePackageVersion (Utc 2026 10 22 0 9 59)); $v1000 = [version] (Get-StorePackageVersion (Utc 2026 10 22 0 10 0))
Test-Case 'store version: later times order after earlier ones' @(($v0015 -lt $v0905), ($vLate -lt $vNext), ($v0959 -lt $v1000)) @($true, $true, $true)
function Pkg([string] $Version) { @{ Id = "packages-cmdemo1-scorecard-store.$Version"; Version = $Version } }
Test-Case 'restore choice: none listed starts empty' (Select-StorePackage @()) $null
Test-Case 'restore choice: the newest by its numbers, not as text' (Select-StorePackage @((Pkg '2026.10.9.2315'), (Pkg '2026.10.10.15'), (Pkg '2026.10.10.5'))).Version '2026.10.10.15'
Test-Case 'restore choice: whatever order the feed answers in' (Select-StorePackage @((Pkg '2026.10.10.15'), (Pkg '2026.10.22.515'), (Pkg '2026.10.22.15'))).Version '2026.10.22.515'
Test-Case 'restore choice: versions that are not ours are left alone' (Select-StorePackage @((Pkg '9999.1.1'), (Pkg '9999.1.1.1-pre'), (Pkg '2026.10.22.15'))).Version '2026.10.22.15'
Test-Case 'restore choice: only versions that are not ours start empty' (Select-StorePackage @((Pkg '1.0.0'))) $null
Test-Case 'restore choice: a trailing line break is not ours' (Select-StorePackage @((Pkg "2026.10.22.1500`n"))) $null
Test-Case 'restore order: newest first' @(Get-StorePackageOrder @((Pkg '2026.10.9.231500'), (Pkg '2026.10.10.1500'), (Pkg '1.0'), (Pkg '2026.10.10.500')) | ForEach-Object { $_.Version }) @('2026.10.10.1500', '2026.10.10.500', '2026.10.9.231500')

$tmp = Join-Path ([IO.Path]::GetTempPath()) "space-scorecard-test-$([guid]::NewGuid().ToString('N'))"
$runDir = Join-Path $tmp 'run'; $restoreDir = Join-Path $tmp 'restore'
foreach ($d in "$runDir/store/raw/GitHubDelivery/x", "$runDir/workspace/.cmis", "$runDir/bin", "$restoreDir/store", "$restoreDir/workspace") { New-Item -ItemType Directory -Path $d -Force | Out-Null }
Set-Content -LiteralPath "$runDir/store/normalized.db" -Value 'db'; Set-Content -LiteralPath "$runDir/store/raw/GitHubDelivery/x/1.json" -Value '{}'
Set-Content -LiteralPath "$runDir/workspace/.cmis/work-tracking.json" -Value '{}'; Set-Content -LiteralPath "$runDir/harvest-state.json" -Value '{}'
Set-Content -LiteralPath "$runDir/discovery.json" -Value '[]'; Set-Content -LiteralPath "$runDir/bin/cmis" -Value 'binary'; Set-Content -LiteralPath "$runDir/scorecard.html" -Value 'page'
$zipPath = Join-Path $tmp 'store.zip'
New-StoreArchive $runDir $zipPath
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath); $entries = @($archive.Entries | ForEach-Object { $_.FullName } | Sort-Object); $archive.Dispose()
Test-Case 'store archive: store, workspace (hidden .cmis too) and the state files; not bin or the outputs' $entries @('discovery.json', 'harvest-state.json', 'store/normalized.db', 'store/raw/GitHubDelivery/x/1.json', 'workspace/.cmis/work-tracking.json')

Test-Case 'store archive: holds no foreign entry' @(Get-ForeignStoreEntries $zipPath) @()
$badZip = Join-Path $tmp 'bad.zip'
$bad = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
foreach ($n in 'store/ok.db', 'bin/cmis', 'store/../../escape', 'harvest-state.json/x', 'notes.txt') { [void] $bad.CreateEntry($n) }
$bad.Dispose()
Test-Case 'store archive: entries outside the store parts are foreign' @(Get-ForeignStoreEntries $badZip) @('bin/cmis', 'store/../../escape', 'harvest-state.json/x', 'notes.txt')

# Restore against a fake feed: the newest package replaces what the work directory held.
Set-Content -LiteralPath "$restoreDir/store/stale.db" -Value 'old'; Set-Content -LiteralPath "$restoreDir/harvest-state.json" -Value 'old'
$feedCalls = [Collections.Generic.List[string]]::new()
$script:feedVersions = @((Pkg '2026.10.9.231500'), (Pkg '2026.10.10.1500'))
$script:newestBad = $false
function Invoke-OctopusRequest([hashtable] $Config, [string] $Path) {
    $feedCalls.Add("Get $Path")
    if ($Path -like '*/feeds?feedType=BuiltIn*') { return @{ Items = @(@{ Id = 'Feeds-9' }) } }
    if ($Path -like '*/feeds/Feeds-9/packages/versions?packageId=cmdemo1-scorecard-store*') { return @{ Items = $script:feedVersions } }
    throw "unexpected Get $Path"
}
function Invoke-OctopusTransfer([hashtable] $Config, [string] $Path, [string] $UploadFile, [string] $OutFile) {
    $feedCalls.Add("Transfer $Path")
    if (-not $OutFile) { throw "unexpected push $Path" }
    $source = if ($Path -like '*2026.10.10.1500*' -and $script:newestBad) { $badZip } else { $zipPath }
    Copy-Item -LiteralPath $source -Destination $OutFile
}
$restoreConfig = @{ space = 'Spaces-1'; octopusServer = 'https://octo.example'; prefix = 'cmdemo1' }
$restoredVersion = Restore-StoreFromFeed $restoreConfig $restoreDir 6>$null
Test-Case 'restore: the newest version' $restoredVersion '2026.10.10.1500'
Test-Case 'restore: downloads that package' ($feedCalls[-1]) 'Transfer /api/Spaces-1/packages/packages-cmdemo1-scorecard-store.2026.10.10.1500/raw'
Test-Case 'restore: replaces the store and the state' @((Test-Path "$restoreDir/store/stale.db"), (Test-Path "$restoreDir/store/normalized.db"), (Get-Content -LiteralPath "$restoreDir/harvest-state.json" -Raw).Trim(), (Test-Path "$restoreDir/workspace/.cmis/work-tracking.json")) @($false, $true, '{}', $true)
Test-Case 'restore: leaves no staging behind' @(Get-ChildItem -LiteralPath $tmp -Force -Filter '.restore-*').Count 0

$script:newestBad = $true
Set-Content -LiteralPath "$restoreDir/store/stale.db" -Value 'old'
$restoredVersion = Restore-StoreFromFeed $restoreConfig $restoreDir 6>$null 3>$null
Test-Case 'restore: a newest package with foreign entries is skipped for the next one' @($restoredVersion, (Test-Path "$restoreDir/store/stale.db"), (Test-Path "$restoreDir/bin/cmis")) @('2026.10.9.231500', $false, $false)
$script:feedVersions = @((Pkg '2026.10.10.1500'))
Set-Content -LiteralPath "$restoreDir/store/kept.db" -Value 'kept'
$failedRestore = try { Restore-StoreFromFeed $restoreConfig $restoreDir 6>$null 3>$null; 'restored' } catch { 'refused' }
Test-Case 'restore: no package that can be restored fails and changes nothing' @($failedRestore, (Test-Path "$restoreDir/store/kept.db")) @('refused', $true)
$script:newestBad = $false

$script:feedVersions = @()
Test-Case 'restore: none in the feed keeps the work directory as it is' @((Restore-StoreFromFeed $restoreConfig $restoreDir 6>$null), (Test-Path "$restoreDir/store/kept.db")) @($null, $true)

# Push against a fake feed: a redirect answer counts only when the feed lists the version afterwards.
$pushTime = Utc 2026 10 22 5 15 7
$script:pushAnswer = $null; $script:listedAfterPush = @()
function Invoke-OctopusTransfer([hashtable] $Config, [string] $Path, [string] $UploadFile, [string] $OutFile) {
    if (-not $UploadFile -or -not (Test-Path -LiteralPath $UploadFile)) { throw "unexpected transfer $Path" }
    $feedCalls.Add("Push $Path $(Split-Path -Leaf $UploadFile)")
    $script:pushAnswer
}
function Invoke-OctopusRequest([hashtable] $Config, [string] $Path) {
    if ($Path -like '*/feeds?feedType=BuiltIn*') { return @{ Items = @(@{ Id = 'Feeds-9' }) } }
    if ($Path -like '*/packages/versions*') { return @{ Items = $script:listedAfterPush } }
    throw "unexpected Get $Path"
}
Test-Case 'push: created' (Publish-StoreToFeed $restoreConfig $runDir $pushTime 6>$null) '2026.10.22.51507'
Test-Case 'push: posts the zip named by id and version' ($feedCalls[-1]) 'Push /api/Spaces-1/packages/raw?overwriteMode=FailIfExists cmdemo1-scorecard-store.2026.10.22.51507.zip'
$script:pushAnswer = 'redirect to http://octo.example/api/Spaces-1/packages/x (HTTP 303)'; $script:listedAfterPush = @((Pkg '2026.10.22.51507'))
Test-Case 'push: a redirect answer with the version listed counts' (Publish-StoreToFeed $restoreConfig $runDir $pushTime 6>$null) '2026.10.22.51507'
$script:listedAfterPush = @((Pkg '2026.10.22.1500'))
Test-Case 'push: a redirect answer without the version listed fails' $(try { Publish-StoreToFeed $restoreConfig $runDir $pushTime 6>$null; 'pushed' } catch { 'refused' }) 'refused'
Remove-Item -LiteralPath $tmp -Recurse -Force

# --- Export and the published site ----------------------------------------------------------------------------
Test-Case 'release commit: from the release notes' (Get-ReleaseCommit 'Build https://github.com/acme/s/actions/runs/39732855846 of b6f970025e683bffc3ed0f33424f5c2d7a01d420, committed 2026-10-22T06:15:43Z') 'b6f970025e683bffc3ed0f33424f5c2d7a01d420'
Test-Case 'release commit: notes without a full commit id' (Get-ReleaseCommit 'Build of b6f9700, committed today') $null
Test-Case 'release commit: no notes' (Get-ReleaseCommit $null) $null
Test-Case 'site: address of the pages' (Get-SiteUrl @{ account = 'stacme01'; container = 'scorecard' }) 'https://stacme01.blob.core.windows.net/scorecard/index.html'
Test-Case 'site: content types by extension' @((Get-SiteContentType '.html'), (Get-SiteContentType '.CSS'), (Get-SiteContentType '.woff2'), (Get-SiteContentType '.png'), (Get-SiteContentType '.bin'), (Get-SiteContentType '')) @('text/html; charset=utf-8', 'text/css; charset=utf-8', 'font/woff2', 'image/png', 'application/octet-stream', 'application/octet-stream')
Test-Case 'site: assets first, then the pages, index.html last' @((Get-SiteUploadOrder 'css/site.css'), (Get-SiteUploadOrder 'drill/a.html'), (Get-SiteUploadOrder 'split.html'), (Get-SiteUploadOrder 'index.html'), (Get-SiteUploadOrder 'drill/index.html')) @(1, 2, 2, 3, 2)
Test-Case 'site: what the export no longer has is deleted' @(Get-StaleBlobs @('index.html', 'drill/old.html', 'css/a.css', 'Drill/x.html') @('index.html', 'css/a.css', 'drill/x.html')) @('drill/old.html', 'Drill/x.html')
Test-Case 'site: nothing to delete from an empty container' @(Get-StaleBlobs @() @('index.html')) @()
$savedAzure = $env:AZURE_CONFIG_DIR
$env:CMIS_SHOP_API_TOKEN = 'secret-a'; $env:OCTOPUS_API_KEY = 'secret-b'; $env:AZURE_CONFIG_DIR = '/tmp/az-signed-in'; $env:SPACE_SCORECARD_TEST = 'kept'
$inside = Invoke-WithoutSecrets { @([bool] $env:CMIS_SHOP_API_TOKEN, [bool] $env:OCTOPUS_API_KEY, [bool] $env:AZURE_CONFIG_DIR, $env:SPACE_SCORECARD_TEST) }
Test-Case 'secrets: out of the environment of the build and the export' @($inside) @($false, $false, $false, 'kept')
Test-Case 'secrets: back after it' @($env:CMIS_SHOP_API_TOKEN, $env:OCTOPUS_API_KEY, $env:AZURE_CONFIG_DIR) @('secret-a', 'secret-b', '/tmp/az-signed-in')
$back = try { Invoke-WithoutSecrets { throw 'export failed' } } catch { $env:CMIS_SHOP_API_TOKEN }
Test-Case 'secrets: back after a failure too' $back 'secret-a'
Remove-Item env:CMIS_SHOP_API_TOKEN, env:OCTOPUS_API_KEY, env:SPACE_SCORECARD_TEST
$env:AZURE_CONFIG_DIR = $savedAzure
$siteDir = Join-Path ([IO.Path]::GetTempPath()) "space-scorecard-site-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path "$siteDir/site/drill" -Force | Out-Null
Set-Content -LiteralPath "$siteDir/site/index.html" -Value 'i'; Set-Content -LiteralPath "$siteDir/site/drill/a.html" -Value 'a'
New-SiteArchive "$siteDir/site" "$siteDir/scorecard-site.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead("$siteDir/scorecard-site.zip")
Test-Case 'site zip: the files by their paths in the site' @($zip.Entries | ForEach-Object { $_.FullName -replace '\\', '/' } | Sort-Object) @('drill/a.html', 'index.html')
$zip.Dispose()
Remove-Item -LiteralPath $siteDir -Recurse -Force

# --- Inside Octopus --------------------------------------------------------------------------------------------
Test-Case 'octopus: not inside an Octopus step here' (Test-InsideOctopus) $false
Test-Case 'highlight: last full week of the space, measured, store version' (Get-HighlightLine $fixture '2026.10.22.51500') 'Space Spaces-1, 2026-09-28 to 2026-10-14: week of 2026-10-05 started 0, delivered 1, WIP 0, MTTD 5.8 h; 1 of 2 projects measured; store 2026.10.22.51500'
Test-Case 'highlight: and where the pages are' (Get-HighlightLine $fixture '2026.10.22.51500' 'pages at https://stacme01.blob.core.windows.net/scorecard/index.html') 'Space Spaces-1, 2026-09-28 to 2026-10-14: week of 2026-10-05 started 0, delivered 1, WIP 0, MTTD 5.8 h; 1 of 2 projects measured; store 2026.10.22.51500; pages at https://stacme01.blob.core.windows.net/scorecard/index.html'

# --- More than one space: everything of a space comes from its configuration -------------------------------------
$configFile = Join-Path ([IO.Path]::GetTempPath()) "space-scorecard-test-$([guid]::NewGuid().ToString('N')).json"
Test-Case 'config: scorecard space kept' (Read-Fixture ($scorecard + @{ scorecardSpace = 'Spaces-355' })).scorecardSpace 'Spaces-355'
Test-Case 'config: a scorecard space that is no space id is refused' (Read-Fixture ($scorecard + @{ scorecardSpace = '../Spaces-355' })) "refused: 'scorecardSpace' must be an Octopus space id such as Spaces-355."
Test-Case 'config: a scorecard space that is no text is refused' (Read-Fixture ($scorecard + @{ scorecardSpace = 355 })) "refused: 'scorecardSpace' must be an Octopus space id such as Spaces-355."
Remove-Item -LiteralPath $configFile -Force
Test-Case 'scorecard space: the space of the configuration by default' (Get-ScorecardSpace @{ space = 'Spaces-1' }) 'Spaces-1'
Test-Case 'scorecard space: scorecardSpace when given' (Get-ScorecardSpace @{ space = 'Spaces-2'; scorecardSpace = 'Spaces-1' }) 'Spaces-1'

# The release of the scorecard deployable is read in scorecardSpace, the projects of the space in space.
$webCalls = [Collections.Generic.List[string]]::new()
function Invoke-OctopusRequest([hashtable] $Config, [string] $Path) {
    $webCalls.Add($Path)
    if ($Path -like '*/projects?partialName=*') { return @{ Items = @(@{ Id = 'Projects-7'; Name = 'acme-scorecard' }, @{ Id = 'Projects-8'; Name = 'acme-scorecard-space' }) } }
    if ($Path -like '*/projects/Projects-7/releases/1.0.40') { return @{ ReleaseNotes = 'no commit named here' } }
    throw "unexpected Get $Path"
}
$webDir = Join-Path ([IO.Path]::GetTempPath()) "space-scorecard-web-$([guid]::NewGuid().ToString('N'))"
function Get-WebFailure([hashtable] $Config) { try { Get-ScorecardWeb $Config $webDir; 'built' } catch { $_.Exception.Message } }
$webConfig = $scorecard + @{ space = 'Spaces-2' }
Test-Case 'export: release looked up in the space by default' @(@(Get-WebFailure $webConfig) + @($webCalls)) @('The notes of release 1.0.40 of acme-scorecard name no commit.', '/api/Spaces-2/projects?partialName=acme-scorecard&take=100', '/api/Spaces-2/projects/Projects-7/releases/1.0.40')
$webCalls.Clear()
Test-Case 'export: release looked up in scorecardSpace' @(@(Get-WebFailure ($webConfig + @{ scorecardSpace = 'Spaces-1' })) + @($webCalls)) @('The notes of release 1.0.40 of acme-scorecard name no commit.', '/api/Spaces-1/projects?partialName=acme-scorecard&take=100', '/api/Spaces-1/projects/Projects-7/releases/1.0.40')

# The configurations in this folder: each reads, and each names its own space, store and runbook project.
$cmdemo1 = Read-SpaceConfig (Join-Path $PSScriptRoot 'cmdemo1.json')
$cmdemo2 = Read-SpaceConfig (Join-Path $PSScriptRoot 'cmdemo2.json')
Test-Case 'cmdemo1.json: space, store, scorecard release in its own space' @($cmdemo1.space, (Get-StorePackageId $cmdemo1), (Get-ScorecardSpace $cmdemo1), $cmdemo1.site.container) @('Spaces-355', 'cmdemo1-scorecard-store', 'Spaces-355', 'scorecard')
Test-Case 'cmdemo2.json: space, store, scorecard release in the space of cmdemo1' @($cmdemo2.space, (Get-StorePackageId $cmdemo2), (Get-ScorecardSpace $cmdemo2), ($cmdemo2.exclude -join ",")) @('Spaces-356', 'cmdemo2-scorecard-store', 'Spaces-355', 'cmdemo2-scorecard-space')
$coordinates = Get-ConnectionCoordinates $cmdemo2 @{ owner = 'clearmeasure-aisf-sample-apps'; repo = 'cmdemo2-workorders'; slug = 'cmdemo2-ui'; environments = 'auto' } 0
Test-Case 'cmdemo2.json: coordinates name its own space' @($coordinates.octopusServer, $coordinates.octopusSpace, $coordinates.octopusProject) @('https://clearmeasure.octopus.app', 'Spaces-356', 'cmdemo2-ui')
# cmdemo1's coordinates as cmis stored them before the configuration was generalized: a change here harvests again.
$coordinates = Get-ConnectionCoordinates $cmdemo1 @{ owner = 'clearmeasure-aisf-sample-apps'; repo = 'cmdemo1-workorders'; slug = 'cmdemo1-ui'; environments = 'auto' } 0
Test-Case 'cmdemo1.json: coordinates unchanged' (ConvertTo-Json -InputObject $coordinates -Compress) '{"owner":"clearmeasure-aisf-sample-apps","repo":"cmdemo1-workorders","octopusServer":"https://clearmeasure.octopus.app","octopusSpace":"Spaces-355","octopusProject":"cmdemo1-ui","environments":"auto","itemNumberBase":"0","automationAuthors":"github-actions[bot],github-actions,dependabot[bot]","automationBranches":"^kit-templates.*$\n^template-sync-.*$\n^dependabot/.*$","automationCommitMessages":"^Pin \\S+ \\S+ in \\S+ \\(Deployments-\\d+\\)$\n^Revert pin of \\S+ \\S+ in \\S+ \\(Deployments-\\d+ failed\\)$\n^Template sync: .*$\n^Kit (templates|workflows)\\b.*$"}'

# setup-octopus.ps1: what it builds on and the names it makes, from the configuration alone.
$setupScript = Join-Path $PSScriptRoot 'setup-octopus.ps1'
function Get-Setup([string] $Path, [hashtable] $Override = @{}, [string] $Source) {
    & {
        . $setupScript -LoadOnly
        $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in $Override.Keys) { if ($null -eq $Override[$k]) { $c.Remove($k) } else { $c[$k] = $Override[$k] } }
        try { Get-SetupSettings $c $Path $Source } catch { "refused: $($_.Exception.Message -replace '^.*?: ', '')" }
    }
}
$one = Get-Setup (Join-Path $PSScriptRoot 'cmdemo1.json')
Test-Case 'setup cmdemo1: as before the generalization' @($one.Space, $one.SourceRepository, $one.SystemProject, $one.StorePackage, $one.ConfigName) @('Spaces-355', 'clearmeasure-aisf-sample-apps/cmdemo1-system', 'cmdemo1-system', 'cmdemo1-scorecard-store', 'cmdemo1.json')
Test-Case 'setup cmdemo1: names as before' @($one.Names.Role, $one.Names.Account, $one.Names.Team, $one.Names.Project, $one.Names.KeyPurpose, $one.Names.AzureAccount) @('cmdemo1 scorecard store feed', 'cmdemo1-scorecard-runner', 'cmdemo1 scorecard runner', 'cmdemo1-scorecard-space', 'Scorecard.OctopusApiKey of cmdemo1-scorecard-space', 'azure-cmdemo1-scorecard-site')
$two = Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json')
Test-Case 'setup cmdemo2: its own space, the code of cmdemo1-system' @($two.Space, $two.SourceRepository, $two.SystemProject, $two.StorePackage, $two.ConfigName) @('Spaces-356', 'clearmeasure-aisf-sample-apps/cmdemo1-system', 'cmdemo2-system', 'cmdemo2-scorecard-store', 'cmdemo2.json')
Test-Case 'setup cmdemo2: its own names, no Azure account without a site' @($two.Names.Role, $two.Names.Account, $two.Names.Team, $two.Names.Project, $two.Names.AzureAccount) @('cmdemo2 scorecard store feed', 'cmdemo2-scorecard-runner', 'cmdemo2 scorecard runner', 'cmdemo2-scorecard-space', $null)
Test-Case 'setup: -SourceRepository wins' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json') @{} 'acme/fork').SourceRepository 'acme/fork'
Test-Case 'setup: no source repository is refused' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json') @{ sourceRepository = $null }) "refused: 'sourceRepository' (owner/repo whose space-scorecard folder the runbook runs) is required, or -SourceRepository."
Test-Case 'setup: systemProject when given' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json') @{ systemProject = 'platform' }).SystemProject 'platform'
Test-Case 'setup: an empty systemProject is refused' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json') @{ systemProject = ' ' }) "refused: 'systemProject' must be the name of an Octopus project."
Test-Case 'setup: site.octopusAccount when given' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo1.json') @{ site = @{ account = 'stacme01'; container = 'scorecard'; octopusAccount = 'azure-shared-site' } }).Names.AzureAccount 'azure-shared-site'
Test-Case 'setup: a space that is no space id is refused' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json') @{ space = 'Spaces-356/../x' }) "refused: 'space' must be an Octopus space id such as Spaces-355."
Test-Case 'setup: a site that is no object is refused' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json') @{ site = 'stacme01' }) "refused: 'site' must be an object (account, container, resourceGroup, identity)."
Test-Case 'setup: no prefix is refused' (Get-Setup (Join-Path $PSScriptRoot 'cmdemo2.json') @{ prefix = $null }) "refused: 'prefix' is required."

# --- Harvest: a connection is tried again; the cause of a failure is shown ----------------------------------------
$harvestEnvelope = @{ ok = $false; error = @{ code = 'general'; cause = 'Every configured connection failed (shop-api).' }; data = @{ connections = @(@{ connectionId = 'shop-api'; succeeded = $false; error = 'GitHub GraphQL query failed: Something went wrong' }) } }
Test-Case 'cmis failure: the connection error after the cause' (Get-CmisFailure $harvestEnvelope 1 '') 'general: Every configured connection failed (shop-api). [shop-api: GitHub GraphQL query failed: Something went wrong]'
Test-Case 'cmis failure: a sync without data gives the cause only' (Get-CmisFailure @{ ok = $false; data = $null; error = @{ code = 'general'; cause = 'Every configured connection failed (shop-api).' } } 1 '') 'general: Every configured connection failed (shop-api).'
Test-Case 'cmis failure: no envelope gives exit code and standard error' (Get-CmisFailure $null 134 'Unhandled exception') 'exit 134; Unhandled exception'
$harvestDir = Join-Path ([IO.Path]::GetTempPath()) "space-scorecard-harvest-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path "$harvestDir/store" -Force | Out-Null
$runsLog = "$harvestDir/store/harvest-runs.jsonl"
Set-Content -LiteralPath $runsLog -Value '{"StartedUtc":"2026-10-22T14:10:07.88+00:00","Connections":[{"ConnectionId":"shop-api","Error":"InvalidOperationException: GitHub GraphQL query failed"},{"ConnectionId":"shop-ui","Error":null}]}'
Test-Case 'last harvest error: of that connection' (Get-LastHarvestError "$harvestDir/store" 'shop-api' ([DateTimeOffset]::Parse('2026-10-22T14:10:00Z'))) 'InvalidOperationException: GitHub GraphQL query failed'
Test-Case 'last harvest error: none for a connection without one' (Get-LastHarvestError "$harvestDir/store" 'shop-ui' ([DateTimeOffset]::Parse('2026-10-22T14:10:00Z'))) $null
Test-Case 'last harvest error: an older run does not count' (Get-LastHarvestError "$harvestDir/store" 'shop-api' ([DateTimeOffset]::Parse('2026-10-22T14:11:00Z'))) $null
Test-Case 'last harvest error: no log' (Get-LastHarvestError "$harvestDir/none" 'shop-api' ([DateTimeOffset]::Parse('2026-10-22T14:10:00Z'))) $null
Remove-Item -LiteralPath $runsLog -Force
$savedAttempts = $script:HarvestAttempts; $savedPause = $script:HarvestRetrySeconds
$script:HarvestRetrySeconds = 0
$cmisCalls = [Collections.Generic.List[string]]::new()
# Per connection, the failures still to come, in order: 'band' answers ok with the connection failed in its data,
# 'log' writes cmis's run log and fails the command without data (as a sync does), 'auth' fails for good.
$script:cmisFailures = @{}
function Invoke-Cmis([string] $Cmis, [string[]] $Arguments, [string] $Workspace, [string] $Store) {
    if ($Arguments[1] -eq 'inventory') { return @{ connections = @() } }
    $id = $Arguments[3]
    $cmisCalls.Add("$($Arguments[1]) $id")
    $queue = $script:cmisFailures[$id]
    if ($queue -and $queue.Count) {
        $kind = $queue[0]; $script:cmisFailures[$id] = @($queue | Select-Object -Skip 1)
        switch ($kind) {
            'band' { return @{ connections = @(@{ connectionId = $id; succeeded = $false; error = 'GitHub GraphQL query failed: Something went wrong while executing your query (in band)' }) } }
            'log' {
                Set-Content -LiteralPath (Join-Path $Store 'harvest-runs.jsonl') -Value (ConvertTo-Json -Compress -InputObject @{ StartedUtc = [DateTimeOffset]::UtcNow.ToString('o'); Connections = @(@{ ConnectionId = $id; Error = 'InvalidOperationException: Something went wrong while executing your query (logged)' }) })
                throw "cmis connections harvest failed: general: Every configured connection failed ($id)."
            }
            default { throw "cmis connections harvest failed: general: Every configured connection failed ($id). [${id}: Bad credentials]" }
        }
    }
    @{ connections = @(@{ connectionId = $id; succeeded = $true }); workItemsPulled = 1; revisionsPulled = 2; apiRequestCount = 3 }
}
$harvestPaths = @{ Workspace = "$harvestDir/workspace"; Store = "$harvestDir/store"; HarvestState = "$harvestDir/harvest-state.json" }
$harvestWindow = @{ Since = '2026-07-25'; Until = '2026-10-22'; HarvestUntil = '2026-10-23' }
$entries = @([ordered]@{ connectionId = 'shop-api'; measured = $true; reason = $null }, [ordered]@{ connectionId = 'shop-ui'; measured = $true; reason = $null }, [ordered]@{ connectionId = 'shop-db'; measured = $true; reason = $null })
$script:HarvestAttempts = 3
$script:cmisFailures = @{ 'shop-api' = @('band', 'log'); 'shop-ui' = @('band', 'band', 'band'); 'shop-db' = @('auth') }
$said = @(& { Invoke-Harvest 'cmis' $entries $harvestWindow $harvestPaths } 6>&1 3>&1 | ForEach-Object { "$_" })
function Count-Calls([string] $Call) { @($cmisCalls | Where-Object { $_ -eq $Call }).Count }
Test-Case 'harvest: tried three times, the third succeeds' @((Count-Calls 'harvest shop-api'), $entries[0].measured) @(3, $true)
Test-Case 'harvest: a failure in the data is tried again, with its cause' (@($said | Where-Object { $_ -like 'shop-api: harvest failed (try 1 of 3)*(in band)' }).Count) 1
Test-Case 'harvest: a failure without data shows the error of the run log' (@($said | Where-Object { $_ -like 'shop-api: harvest failed (try 2 of 3)*`[shop-api: InvalidOperationException: Something went wrong while executing your query (logged)`]' }).Count) 1
Test-Case 'harvest: as many failures as tries and the connection is not measured' @((Count-Calls 'harvest shop-ui'), $entries[1].measured, $entries[1].reason) @(3, $false, "harvest failed (the run's output says why)")
Test-Case 'harvest: a failure that is not passing is not tried again' @((Count-Calls 'harvest shop-db'), $entries[2].measured, (@($said | Where-Object { $_ -like 'shop-db: harvest failed: *Bad credentials*' }).Count)) @(1, $false, 1)
Test-Case 'harvest: the state names only the connection that succeeded' @((Get-Content -LiteralPath $harvestPaths.HarvestState -Raw | ConvertFrom-Json -AsHashtable).Keys) @('shop-api')
$script:HarvestAttempts = $savedAttempts; $script:HarvestRetrySeconds = $savedPause
Remove-Item -LiteralPath $harvestDir -Recurse -Force

if ($failures) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'All passed'
