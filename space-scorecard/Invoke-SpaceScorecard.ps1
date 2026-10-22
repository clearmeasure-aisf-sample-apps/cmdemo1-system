#!/usr/bin/env pwsh
#Requires -Version 7.5

<#
.SYNOPSIS
    The delivery scorecard of a whole Octopus Deploy space: every project of the space paired with its GitHub
    repository, harvested with cmis (Clear Measure Intelligence Scorecard), written as one static page.

.DESCRIPTION
    Steps 1 and 2 of the design "Space-level scorecard on cmis". One run, in this order (each step a function below):

      Get cmis      The release the configuration pins (cmisVersion) from cmisRepo, through the GitHub REST API with the
                    GitHub token, its SHA-256 checked against the release's SHA256SUMS.txt, unpacked into <WorkDir>/bin.
                    Reused when the binary there already reports that version.
      Restore       With -StoreFeed: the newest version of package <prefix>-scorecard-store of the space's built-in
                    feed is unpacked into <WorkDir> (store, workspace, harvest-state.json, discovery.json), replacing
                    what is there; when the feed has none yet, the run starts from what <WorkDir> holds (empty on a
                    fresh one).
      Discover      The projects of the space (Octopus REST API, key in OCTOPUS_API_KEY). The repository of each,
                    first that answers: the configuration (projects.<name>.repo); the build information of its
                    newest release (VcsRoot); the first github.com/<owner>/<repo> address in the newest release's
                    notes; a repository in githubOwner named like the project's slug, else its name. An address
                    from Octopus counts only when GitHub has that repository. A disabled project, one in "exclude"
                    and one without a repository are listed as not measured, with the reason.
      Connections   One cmis GitHubDelivery connection per measured project, id = the project slug, in
                    <WorkDir>/workspace with the store <WorkDir>/store. Added once, then "connections update" (a rerun
                    changes nothing; "add --replace" when a key is to be dropped from one without data). cmis keeps one source per stored history: when the coordinates of a connection
                    that holds data change, cmis refuses to harvest or score it, so the workspace and the store are
                    started again and everything is harvested anew (said in a warning).
      Harvest       Per connection: "connections harvest" over the window when the store holds nothing of it, else
                    "connections sync" (differential, from the watermark; from Since when Since lies before the
                    first harvested day). A connection that fails is not measured; the others go on.
      Compute       "connections score --period week" per connection and over all of them, "connections document"
                    over all of them (document.json), and "connections score-drill" for every weekly cell of
                    Items started, Items delivered and Work in process that is not zero (the item lists). A space
                    number that is not the sum of its projects', and a list whose length is not its number, are
                    warnings on the page.
      Render        scorecard.html (one file, no external request, no script) and summary.md, from
                    scorecard-data.json, the numbers and lists the compute step gathered (no item titles). One function
                    (Write-ScorecardFiles), apart from harvest and compute, so another renderer can take its place.
      Octopus       Inside an Octopus step (OctopusParameters or New-OctopusArtifact is there): scorecard.html,
                    summary.md and document.json become artifacts of the task, and a line of the space's last full
                    week is highlighted.
      Push          With -StoreFeed, after everything above succeeded: store, workspace, harvest-state.json and
                    discovery.json as <prefix>-scorecard-store.<version>.zip to the built-in feed (never replacing a
                    version), version yyyy.M.d.HHmmss in UTC. A run that fails pushes nothing.

    Weeks are cmis's weekly periods: ISO weeks, Monday 00:00 UTC to the next, as cmdemo1-scorecard's page shows them.
    timeZone only sets the calendar days of document.json and what "today" is.

    Credentials stay in this process: CMIS_<ID>_TOKEN (GITHUB_TOKEN, else "gh auth token") and
    CMIS_<ID>_OCTOPUS_TOKEN (OCTOPUS_API_KEY) per connection, ID = the connection id upper-cased with "-" as "_".
    Nothing is written to disk or printed. The Octopus key also reads and pushes the store package (-StoreFeed).

.PARAMETER Config
    The space's configuration file (see README.md), for example space-scorecard/cmdemo1.json.
.PARAMETER WorkDir
    Where the binary, the cmis workspace and store, and the outputs go. Kept between runs: a rerun syncs.
.PARAMETER Since
    First day of the window, yyyy-MM-dd. Default: the first of historyDays days that end with Until.
.PARAMETER Until
    Last day of the window, yyyy-MM-dd. Default: today in timeZone.
.PARAMETER SkipHarvest
    Asks neither Octopus nor GitHub for anything and changes no connection: computes and renders from what the
    store holds, for the projects of the last full run (<WorkDir>/discovery.json).
.PARAMETER StoreFeed
    Keeps the store in the space's built-in Octopus feed: restored from the newest <prefix>-scorecard-store package
    before the harvest, pushed as a new version after a run that succeeded. Needs "prefix" in the configuration and an
    Octopus key that may view and download from the built-in feed and push to it. Not with -SkipHarvest.
.PARAMETER LoadOnly
    Defines the functions and stops (for the tests).
.EXAMPLE
    $env:OCTOPUS_API_KEY = '...'; pwsh -NoProfile -File space-scorecard/Invoke-SpaceScorecard.ps1 -Config space-scorecard/cmdemo1.json -WorkDir /var/tmp/space-scorecard/run
#>
[CmdletBinding()]
param(
    [string] $Config,
    [string] $WorkDir,
    [string] $Since,
    [string] $Until,
    [switch] $SkipHarvest,
    [switch] $StoreFeed,
    [switch] $LoadOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Invariant = [Globalization.CultureInfo]::InvariantCulture
# The distance between the item number bases of two connections: cmis identifies a work item by its number alone
# when it scores several connections together, and every repository numbers from 1 (a direct commit or a branch gets a
# number of its own, in the hundred thousands). The same spacing as cmdemo1-scorecard.
$script:ItemNumberSpacing = 1000000
# The three metrics whose weekly cells list their items, as score names them and as score-drill takes them.
# The id of the space's own block: "_" is in no Octopus slug, so no project's block can have it.
$script:SpaceScopeId = '_space'
$script:DrillMetrics = [ordered]@{ workInProcess = 'wip'; itemsStarted = 'itemsstarted'; itemsDelivered = 'itemsdelivered' }
# The GitHub token once read (Get-GitHubToken); in memory only.
$script:GitHubToken = $null

# ---------------------------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------------------------

function Read-SpaceConfig([string] $Path) {
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in 'space', 'octopusServer', 'githubOwner', 'cmisVersion', 'cmisRepo') {
        if (-not ($c[$key] -is [string] -and $c[$key].Trim())) { throw "$Path`: '$key' is required (a text)." }
    }
    if ($c['octopusServer'] -notmatch '^https://') { throw "$Path`: 'octopusServer' must be an https:// address (the API key is sent to it)." }
    if ($c['prefix'] -and -not ($c['prefix'] -is [string] -and $c['prefix'] -cmatch '^[a-z0-9][a-z0-9-]*\z')) { throw "$Path`: 'prefix' must be lower case letters, digits and '-' (it begins a package id)." }
    if (-not $c['timeZone']) { $c['timeZone'] = 'UTC' }
    if ($null -eq $c['historyDays']) { $c['historyDays'] = 90 }
    if (-not ($c['historyDays'] -is [long] -or $c['historyDays'] -is [int]) -or $c['historyDays'] -lt 1) { throw "$Path`: 'historyDays' must be a whole number of days, 1 or more." }
    if (-not $c['automation']) { $c['automation'] = @{} }
    # Trimmed, without blanks and repeats, as cmdemo1-scorecard reads its own lists: the same settings give the same coordinates.
    foreach ($key in 'authors', 'branches', 'commitMessages') { $c.automation[$key] = @($c.automation[$key] | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique) }
    if (-not $c['projects']) { $c['projects'] = @{} }
    $c['exclude'] = @($c['exclude'] | Where-Object { $_ })
    # A pattern cmis cannot use fails the whole run here, by the name of its setting, not once per connection later.
    foreach ($key in 'branches', 'commitMessages') {
        foreach ($pattern in $c.automation[$key]) {
            try { [void] [regex]::new($pattern) } catch { throw "$Path`: automation.$key holds an invalid regular expression: $pattern" }
        }
    }
    [void] [TimeZoneInfo]::FindSystemTimeZoneById($c.timeZone)
    $c
}

# The settings of one project in the configuration: by its name, else by its slug; an empty table when it has none.
function Get-ProjectSettings([hashtable] $Config, [string] $Name, [string] $Slug) {
    foreach ($key in $Name, $Slug) { if ($key -and $Config.projects.ContainsKey($key)) { return $Config.projects[$key] } }
    @{}
}

# The window: Until defaults to today in the configured zone, Since to the first of historyDays days ending with Until.
function Resolve-Window([hashtable] $Config, [string] $Since, [string] $Until, [datetime] $UtcNow = [datetime]::UtcNow) {
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById($Config.timeZone)
    $u = if ($Until) { [datetime]::ParseExact($Until, 'yyyy-MM-dd', $script:Invariant) } else { [TimeZoneInfo]::ConvertTimeFromUtc($UtcNow, $zone).Date }
    $s = if ($Since) { [datetime]::ParseExact($Since, 'yyyy-MM-dd', $script:Invariant) } else { $u.AddDays(1 - [int] $Config.historyDays) }
    if ($s -gt $u) { throw "Since ($($s.ToString('yyyy-MM-dd'))) is after Until ($($u.ToString('yyyy-MM-dd')))." }
    @{ Since = $s.ToString('yyyy-MM-dd'); Until = $u.ToString('yyyy-MM-dd')
        # The harvest reaches one UTC day past Until: the last local day of a zone west of UTC ends on the next UTC day,
        # and cmis refuses a document over days the harvest does not cover. A date in the future is accepted.
        HarvestUntil = $u.AddDays(1).ToString('yyyy-MM-dd') }
}

# ---------------------------------------------------------------------------------------------------------------
# GitHub and Octopus requests
# ---------------------------------------------------------------------------------------------------------------

# The HTTP status of a failed web request; 0 when no answer came (name, connection, TLS).
function Get-HttpStatus([Management.Automation.ErrorRecord] $ErrorRecord) {
    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) { return [int] $response.Value.StatusCode }
    0
}

# The GitHub token: GITHUB_TOKEN, else "gh auth token" when gh is there (a person's shell). Read once, kept in memory.
function Get-GitHubToken {
    if ($script:GitHubToken) { return $script:GitHubToken }
    $token = $env:GITHUB_TOKEN
    if (-not $token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        $PSNativeCommandUseErrorActionPreference = $false
        $token = (gh auth token 2>$null | Out-String).Trim()
    }
    if (-not $token) { throw 'No GitHub token: GITHUB_TOKEN is not set and "gh auth token" gave none.' }
    $script:GitHubToken = $token
    $token
}

# One GET of the GitHub REST API (a path of https://api.github.com) with the token. -OutFile saves the answer: a
# release asset answers with a redirect to another host, which is followed without the token (PowerShell drops the
# Authorization header on a redirect). Otherwise the answer's text is returned.
function Invoke-GitHubGet([string] $Path, [string] $Accept = 'application/vnd.github+json', [string] $OutFile) {
    $request = @{ Uri = "https://api.github.com$Path"; Headers = @{ Authorization = "Bearer $(Get-GitHubToken)"; Accept = $Accept; 'X-GitHub-Api-Version' = '2022-11-28' } }
    if ($OutFile) { Invoke-WebRequest @request -OutFile $OutFile -MaximumRetryCount 2 -RetryIntervalSec 5 | Out-Null; return }
    (Invoke-WebRequest @request).Content
}

# Whether GitHub has a repository: true, false on GitHub's 404, and a failure on anything else, so a GitHub outage
# or a lost login is not reported as "no repository".
function Test-GitHubRepository([string] $Owner, [string] $Repo) {
    try { Invoke-GitHubGet "/repos/$([uri]::EscapeDataString($Owner))/$([uri]::EscapeDataString($Repo))" | Out-Null; return $true }
    catch {
        $status = Get-HttpStatus $_
        if ($status -eq 404) { return $false }
        throw "GitHub did not say whether $Owner/$Repo exists: $(if ($status) { "HTTP $status" } else { $_.Exception.Message })"
    }
}

# One GET of the Octopus REST API (a path of octopusServer) with OCTOPUS_API_KEY, tried again on a failure that may
# pass; the parsed JSON answer.
function Invoke-OctopusRequest([hashtable] $Config, [string] $Path) {
    $request = @{ Uri = $Config.octopusServer.TrimEnd('/') + $Path; Headers = @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY }; MaximumRetryCount = 3; RetryIntervalSec = 10 }
    $content = (Invoke-WebRequest @request).Content
    if ($content) { $content | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100 }
}

# A package to or from the Octopus REST API with OCTOPUS_API_KEY, through HttpClient without following redirects: the
# key goes to octopusServer only. -UploadFile POSTs the file as a multipart form (field "file"), once (a push that may
# have arrived is not sent twice); Octopus Cloud may answer a push that arrived with a redirect to the package (to an
# http address), which is returned as the text "redirect to <where>" for the caller to check. -OutFile GETs into that
# file, tried three times; a redirect to octopusServer's own host is asked again over https with the key (three such
# at most), one to another https host (where Octopus may keep the file) is followed without the key. A redirect
# otherwise, or a status that is no success, is a failure that names the status and, for a redirect, where it led
# (scheme, host and path; no query).
function Invoke-OctopusTransfer([hashtable] $Config, [string] $Path, [string] $UploadFile, [string] $OutFile) {
    $uri = [uri] ($Config.octopusServer.TrimEnd('/') + $Path)
    $serverHost = $uri.Host
    $hops = 0
    $method = if ($UploadFile) { 'POST' } else { 'GET' }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [timespan]::FromMinutes(30)
    try {
        $attempts = if ($UploadFile) { 1 } else { 3 }
        for ($attempt = 1; ; $attempt++) {
            $message = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method), $uri)
            [void] $message.Headers.TryAddWithoutValidation('X-Octopus-ApiKey', $env:OCTOPUS_API_KEY)
            $stream = $null
            if ($UploadFile) {
                $stream = [IO.File]::OpenRead($UploadFile)
                $form = [Net.Http.MultipartFormDataContent]::new()
                $file = [Net.Http.StreamContent]::new($stream)
                $file.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
                $form.Add($file, 'file', (Split-Path -Leaf $UploadFile))
                $message.Content = $form
            }
            try {
                $response = $client.SendAsync($message, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $status = [int] $response.StatusCode
                if ($status -ge 300 -and $status -lt 400) {
                    $location = $response.Headers.Location
                    if ($location -and -not $location.IsAbsoluteUri) { $location = [uri]::new($uri, $location) }
                    $where = if ($location) { "$($location.Scheme)://$($location.Host)$($location.AbsolutePath)" } else { 'no address' }
                    if ($OutFile -and $location -and $location.Host -ieq $serverHost -and $hops -lt 3) {
                        $uri = [uri] "https://$serverHost$($location.PathAndQuery)"; $hops++; $attempt--
                        continue
                    }
                    if ($OutFile -and $location -and $location.Scheme -eq 'https' -and $location.Host -ine $serverHost) {
                        try { Invoke-WebRequest -Uri $location -OutFile $OutFile | Out-Null }
                        catch { throw "Downloading from $where failed (HTTP $(Get-HttpStatus $_))." }
                        return
                    }
                    if ($UploadFile) { return "redirect to $where (HTTP $status)" }
                    throw "Octopus answered $method $($uri.AbsolutePath) with HTTP $status, a redirect to $where (not followed)."
                }
                if ($status -lt 200 -or $status -ge 300) {
                    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
                    throw "Octopus $method $($uri.AbsolutePath) failed (HTTP $status): $($text -replace '\s+', ' ')"
                }
                if ($OutFile) {
                    $target = [IO.File]::Create($OutFile)
                    try { $response.Content.ReadAsStream().CopyTo($target) } finally { $target.Dispose() }
                }
                return
            }
            catch {
                $retry = $attempt -lt $attempts -and ("$_" -notmatch 'HTTP (4\d\d|3\d\d)')
                if (-not $retry) { throw }
                Start-Sleep -Seconds 10
            }
            finally {
                $message.Dispose()
                if ($stream) { $stream.Dispose() }
            }
        }
    }
    finally { $client.Dispose() }
}

# ---------------------------------------------------------------------------------------------------------------
# Get cmis
# ---------------------------------------------------------------------------------------------------------------

# The line of SHA256SUMS.txt for one file: "<sha256>  <name>" (sha256sum's format, a "*" before the name in binary mode).
function Get-ExpectedSha256([string] $SumsText, [string] $FileName) {
    foreach ($line in $SumsText -split "`r?`n") {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(\S.*?)\s*$' -and $Matches[2] -ceq $FileName) { return $Matches[1].ToLowerInvariant() }
    }
    $null
}

# What a cmis binary says it is; $null when it cannot be run or says nothing usable (it is then downloaded again).
function Get-CmisVersion([string] $Cmis) {
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $text = & $Cmis --version --json 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { return $null }
        $full = [string] (($text | ConvertFrom-Json -AsHashtable)['data'])['version']
    }
    catch { return $null }
    if (-not $full) { return $null }
    $version, $commit = $full -split '\+', 2
    @{ Version = $version; Commit = $commit }
}

function Get-Cmis([hashtable] $Config, [string] $BinDir) {
    if (-not $IsLinux -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
        throw 'Only the linux-x64 build of cmis is fetched; run this on Linux x64.'
    }
    $cmis = Join-Path $BinDir 'cmis'
    $present = if (Test-Path -LiteralPath $cmis) { Get-CmisVersion $cmis } else { $null }
    if ($present -and $present.Version -ceq $Config.cmisVersion) {
        Write-Host "cmis $($Config.cmisVersion): reused from $BinDir"
        return $cmis
    }
    $asset = "cmis-$($Config.cmisVersion)-linux-x64.tar.gz"
    $download = Join-Path ([IO.Path]::GetTempPath()) "cmis-download-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $download | Out-Null
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $tag = "v$($Config.cmisVersion)"
        $release = Invoke-GitHubGet "/repos/$($Config.cmisRepo)/releases/tags/$([uri]::EscapeDataString($tag))" | ConvertFrom-Json -AsHashtable
        foreach ($name in $asset, 'SHA256SUMS.txt') {
            $found = @($release['assets'] | Where-Object { $_['name'] -ceq $name })
            if (-not $found.Count) { throw "Release $tag of $($Config.cmisRepo) has no asset $name." }
            Invoke-GitHubGet ([uri] $found[0]['url']).AbsolutePath 'application/octet-stream' (Join-Path $download $name)
        }
        $expected = Get-ExpectedSha256 (Get-Content -LiteralPath (Join-Path $download 'SHA256SUMS.txt') -Raw) $asset
        if (-not $expected) { throw "SHA256SUMS.txt of v$($Config.cmisVersion) has no line for $asset." }
        $actual = (Get-FileHash -LiteralPath (Join-Path $download $asset) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "$asset does not match SHA256SUMS.txt (expected $expected, got $actual): not unpacked." }
        if (Test-Path -LiteralPath $BinDir) { Remove-Item -LiteralPath $BinDir -Recurse -Force }
        New-Item -ItemType Directory -Path $BinDir | Out-Null
        tar -xzf (Join-Path $download $asset) -C $BinDir | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unpacking $asset failed (exit $LASTEXITCODE)." }
    }
    finally { Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue }
    $found = Get-CmisVersion $cmis
    if (-not $found -or $found.Version -cne $Config.cmisVersion) { throw "The unpacked cmis does not report version $($Config.cmisVersion)." }
    Write-Host "cmis $($Config.cmisVersion): downloaded from the GitHub API and checked against SHA256SUMS.txt"
    $cmis
}

# One cmis command with its JSON envelope. ok:false is a failure, with cmis's own cause; the data is returned.
function Invoke-Cmis([string] $Cmis, [string[]] $Arguments, [string] $Workspace, [string] $Store) {
    $PSNativeCommandUseErrorActionPreference = $false
    $errors = [IO.Path]::GetTempFileName()
    try {
        $text = & $Cmis @Arguments --json --workspace $Workspace --store $Store 2> $errors | Out-String
        $exit = $LASTEXITCODE
        $envelope = $null
        try { $envelope = $text | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100 } catch { $envelope = $null }
        if ($envelope -isnot [Collections.IDictionary] -or $envelope['ok'] -ne $true) {
            $problem = if ($envelope -is [Collections.IDictionary]) { $envelope['error'] } else { $null }
            $cause = if ($problem -is [Collections.IDictionary]) { "$($problem['code']): $($problem['cause'])" } else { "exit $exit; $((Get-Content -LiteralPath $errors -Raw) ?? '')".Trim() }
            throw "cmis $($Arguments[0..1] -join ' ') failed: $cause"
        }
        $envelope['data']
    }
    finally { Remove-Item -LiteralPath $errors -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------------------------
# Discover
# ---------------------------------------------------------------------------------------------------------------

# The first github.com/<owner>/<repo> address in a text: owner and repository, or $null. The repository name stops
# at the next "/", whitespace or punctuation that cannot be part of it; ".git" and a sentence's full stop are dropped.
function Get-GitHubRepositoryFromText([string] $Text) {
    if (-not $Text) { return $null }
    # Addresses of GitHub's own pages (an organization's project board, a user's profile) are not repositories.
    $notOwners = 'orgs', 'users', 'apps', 'settings', 'marketplace', 'sponsors', 'topics', 'collections', 'features', 'enterprise',
    'login', 'notifications', 'issues', 'pulls', 'search', 'advisories', 'new', 'explore', 'codespaces', 'security', 'organizations',
    'trending', 'pricing', 'about', 'readme', 'site', 'contact', 'events', 'stars', 'watching', 'dashboard'
    foreach ($m in [regex]::Matches($Text, '(?i)(?:https?://|\bgit@)(?:www\.)?github\.com[/:](?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/(?<repo>[A-Za-z0-9._-]+)')) {
        if ($notOwners -contains $m.Groups['owner'].Value) { continue }
        $repo = $m.Groups['repo'].Value -replace '\.git$', '' -replace '\.+$', ''
        if ($repo) { return @{ Owner = $m.Groups['owner'].Value; Repo = $repo } }
    }
    $null
}

# The repository of one project and where the pairing came from, or the reason there is none.
#   $GetJson    { param($Path) } the parsed answer of an Octopus API path (/api/...)
#   $RepoExists { param($Owner, $Repo) } true when GitHub has that repository, false when it answers 404; it throws
#               on any other failure, so a GitHub outage is not reported as "no repository".
# An address found in Octopus is used only when GitHub has that repository (a release note may name a page of GitHub
# that is not one, or a repository since renamed); otherwise the next rule is tried.
function Resolve-ProjectRepository([hashtable] $Config, [hashtable] $Project, [scriptblock] $GetJson, [scriptblock] $RepoExists) {
    $settings = Get-ProjectSettings $Config $Project.Name $Project.Slug
    if ($settings['repo']) {
        $owner, $repo = if ($settings['repo'] -match '^([^/]+)/([^/]+)$') { $Matches[1], $Matches[2] } else { $Config.githubOwner, $settings['repo'] }
        return @{ Owner = $owner; Repo = $repo; Source = 'config' }
    }
    $releases = & $GetJson "/api/$($Config.space)/projects/$($Project.Id)/releases?take=1"
    $newest = @($releases['Items']) | Select-Object -First 1
    $skipped = [Collections.Generic.List[string]]::new()
    if ($newest) {
        $candidates = @(foreach ($build in @($newest['BuildInformation'] | Where-Object { $_ })) {
                if ($found = Get-GitHubRepositoryFromText ([string] $build['VcsRoot'])) { $found + @{ Source = 'build information' } }
            })
        if ($found = Get-GitHubRepositoryFromText ([string] $newest['ReleaseNotes'])) { $candidates += $found + @{ Source = 'release notes' } }
        foreach ($c in $candidates) {
            if (& $RepoExists $c.Owner $c.Repo) { return $c }
            $skipped.Add("$($c.Owner)/$($c.Repo) of its $($c.Source) does not exist")
        }
    }
    # The slug first: a project name may hold spaces or capitals that no repository name has.
    $names = @($Project.Slug, $Project.Name | Where-Object { $_ } | Select-Object -Unique)
    foreach ($name in $names) {
        if (& $RepoExists $Config.githubOwner $name) { return @{ Owner = $Config.githubOwner; Repo = $name; Source = 'name' } }
    }
    $where = if (-not $newest) { 'it has no release' }
    elseif ($skipped.Count) { $skipped -join ', ' }
    else { "release $($newest['Version']) has no build information or GitHub address in its notes" }
    @{ Reason = "no repository: not in the configuration, $where, and $($Config.githubOwner) has no repository named $($names -join ' or ')" }
}

# Every project of the space, ordered by name: what is measured and with which repository, what is not and why.
function Get-SpaceProjects([hashtable] $Config, [scriptblock] $GetJson, [scriptblock] $RepoExists) {
    $all = @(& $GetJson "/api/$($Config.space)/projects/all")
    foreach ($p in @($all | Sort-Object { $_['Name'] })) {
        $entry = [ordered]@{
            project = $p['Name']; slug = $p['Slug']; projectId = $p['Id']; owner = $null; repo = $null; source = $null
            environments = $null; measured = $false; reason = $null; connectionId = $null
        }
        $settings = Get-ProjectSettings $Config $p['Name'] $p['Slug']
        if ($p['IsDisabled']) { $entry.reason = 'disabled in Octopus' }
        elseif ($Config.exclude -contains $p['Name'] -or $Config.exclude -contains $p['Slug']) { $entry.reason = 'excluded by the configuration' }
        else {
            $found = Resolve-ProjectRepository $Config @{ Id = $p['Id']; Name = $p['Name']; Slug = $p['Slug'] } $GetJson $RepoExists
            if ($found['Reason']) { $entry.reason = $found.Reason }
            else {
                $entry.owner = $found.Owner; $entry.repo = $found.Repo; $entry.source = $found.Source; $entry.measured = $true
                $entry.environments = if ($settings['environments']) { $settings.environments } else { 'auto' }
                $entry.connectionId = ConvertTo-ConnectionId $p['Slug']
            }
        }
        $entry
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------------------------------------------

# The connection id of a project: its slug (Octopus slugs are lower case letters, digits and "-").
function ConvertTo-ConnectionId([string] $Slug) {
    $id = $Slug.Trim().ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    if (-not $id) { throw "Project slug '$Slug' gives no connection id." }
    $id
}

# The prefix of a connection's credential variables as cmis reads them: CMIS_<ID>_TOKEN, CMIS_<ID>_OCTOPUS_TOKEN.
function ConvertTo-CredentialPrefix([string] $ConnectionId) {
    'CMIS_' + ($ConnectionId.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
}

# The coordinates of one connection as cmis stores them. Every value is a text; lists are joined the way
# cmdemo1-scorecard joins them: logins with ",", patterns one per line (a pattern may hold a comma).
function Get-ConnectionCoordinates([hashtable] $Config, $Entry, [long] $ItemNumberBase) {
    $c = [ordered]@{
        owner = $Entry.owner; repo = $Entry.repo
        octopusServer = $Config.octopusServer.TrimEnd('/'); octopusSpace = $Config.space; octopusProject = $Entry.slug
        environments = $Entry.environments; itemNumberBase = $ItemNumberBase.ToString($script:Invariant)
    }
    if ($Config.automation.authors.Count) { $c.automationAuthors = $Config.automation.authors -join ',' }
    if ($Config.automation.branches.Count) { $c.automationBranches = $Config.automation.branches -join "`n" }
    if ($Config.automation.commitMessages.Count) { $c.automationCommitMessages = $Config.automation.commitMessages -join "`n" }
    $c
}

function Test-SameCoordinates($Existing, $Desired) {
    if ($null -eq $Existing -or $Existing.Count -ne $Desired.Count) { return $false }
    foreach ($key in $Desired.Keys) { if (-not $Existing.Contains($key) -or [string] $Existing[$key] -cne [string] $Desired[$key]) { return $false } }
    $true
}

# The item number base of every measured project: the one its connection already has, else the lowest free multiple
# of the spacing, given in the order of the Octopus project ids (creation order), so a new project never moves another.
# Every base the workspace holds stays taken, also that of a connection no longer measured (excluded, disabled): if
# it comes back, it keeps its own.
function Get-ItemNumberBases($Entries, [hashtable] $ExistingBases) {
    $bases = @{}
    $used = [Collections.Generic.HashSet[long]]::new()
    foreach ($id in $ExistingBases.Keys) { [void] $used.Add([long] $ExistingBases[$id]) }
    foreach ($e in $Entries) { if ($ExistingBases.ContainsKey($e.connectionId)) { $bases[$e.connectionId] = [long] $ExistingBases[$e.connectionId] } }
    $k = 1
    foreach ($e in @($Entries | Sort-Object { [int] ($_.projectId -replace '\D', '') })) {
        if ($bases.ContainsKey($e.connectionId)) { continue }
        while ($used.Contains([long] $k * $script:ItemNumberSpacing)) { $k++ }
        $bases[$e.connectionId] = [long] $k * $script:ItemNumberSpacing; [void] $used.Add($bases[$e.connectionId])
    }
    $bases
}

# What to do with one connection, given its coordinates in the workspace ($null: none) and whether the store holds data:
#   add      not there yet
#   update   there; the same keys (cmis's update overwrites the keys it is given and keeps the others)
#   replace  there without data, but a key is to be dropped or added: update cannot drop one, add --replace starts it anew
#   restart  there with data from other coordinates: cmis refuses to harvest, sync or score it and cannot forget one
#            connection's history, so the workspace and the store start again
function Get-ConnectionAction($Existing, $Desired, [bool] $HoldsData) {
    if ($null -eq $Existing) { return 'add' }
    if (Test-SameCoordinates $Existing $Desired) { return 'update' }
    if ($HoldsData) { return 'restart' }
    $sameKeys = $Existing.Count -eq $Desired.Count -and @($Desired.Keys | Where-Object { -not $Existing.Contains($_) }).Count -eq 0
    if ($sameKeys) { 'update' } else { 'replace' }
}

function Set-Connections([string] $Cmis, [hashtable] $Config, $Entries, [hashtable] $Paths) {
    $listed = @((Invoke-Cmis $Cmis @('connections', 'list') $Paths.Workspace $Paths.Store)['connections'])
    $inventory = @((Invoke-Cmis $Cmis @('connections', 'inventory') $Paths.Workspace $Paths.Store)['connections'])
    $existing = @{}; foreach ($c in $listed) { $existing[$c['id']] = $c['coordinates'] }
    $known = @{}; foreach ($id in $existing.Keys) { if ($existing[$id]['itemNumberBase']) { $known[$id] = [long] $existing[$id]['itemNumberBase'] } }
    $bases = Get-ItemNumberBases $Entries $known
    $holding = @{}; foreach ($c in $inventory) { if (-not $c['isEmpty']) { $holding[$c['connectionId']] = $true } }

    $restart = @($Entries | Where-Object { (Get-ConnectionAction $existing[$_.connectionId] (Get-ConnectionCoordinates $Config $_ $bases[$_.connectionId]) ([bool] $holding[$_.connectionId])) -eq 'restart' } | ForEach-Object { $_.connectionId })
    if ($restart.Count) {
        Write-Warning "The coordinates of $($restart -join ', ') changed; cmis keeps one source per stored history, so the workspace and the store start again and every connection is harvested anew."
        foreach ($dir in $Paths.Workspace, $Paths.Store) { Remove-Item -LiteralPath $dir -Recurse -Force; New-Item -ItemType Directory -Path $dir | Out-Null }
        Remove-Item -LiteralPath $Paths.HarvestState -Force -ErrorAction SilentlyContinue
        $existing = @{}; $holding = @{}
        $bases = Get-ItemNumberBases $Entries @{}
    }

    foreach ($e in $Entries) {
        $coordinates = Get-ConnectionCoordinates $Config $e $bases[$e.connectionId]
        $arguments = @(foreach ($key in $coordinates.Keys) { '--coordinate'; "$key=$($coordinates[$key])" })
        $action = Get-ConnectionAction $existing[$e.connectionId] $coordinates ([bool] $holding[$e.connectionId])
        switch ($action) {
            'update' {
                $r = Invoke-Cmis $Cmis (@('connections', 'update', '--id', $e.connectionId, '--name', $e.project) + $arguments) $Paths.Workspace $Paths.Store
                Write-Host "connection $($e.connectionId): $(if ($r['diff'] -and $r['diff'] -ne '(no change)') { 'updated' } else { 'unchanged' })"
            }
            default {
                $replace = if ($action -eq 'replace') { @('--replace', '--yes') } else { @() }
                Invoke-Cmis $Cmis (@('connections', 'add', '--id', $e.connectionId, '--name', $e.project, '--tracker', 'GitHubDelivery') + $replace + $arguments) $Paths.Workspace $Paths.Store | Out-Null
                Write-Host "connection $($e.connectionId): $(if ($replace) { 'replaced' } else { 'added' }) ($($e.owner)/$($e.repo))"
            }
        }
        $e.itemNumberBase = $bases[$e.connectionId]
    }
}

# The item number base of every connection as the workspace holds it (for -SkipHarvest, which changes nothing).
function Read-ConnectionBases([string] $Cmis, $Entries, [hashtable] $Paths) {
    $listed = @((Invoke-Cmis $Cmis @('connections', 'list') $Paths.Workspace $Paths.Store)['connections'])
    foreach ($e in $Entries) {
        $c = @($listed | Where-Object { $_['id'] -ceq $e.connectionId })
        if (-not $c.Count -or -not $c[0]['coordinates']['itemNumberBase']) { throw "-SkipHarvest: the workspace has no connection $($e.connectionId); run without -SkipHarvest first." }
        $e.itemNumberBase = [long] $c[0]['coordinates']['itemNumberBase']
    }
}

# The credentials of every connection, in this process's environment only.
function Set-ConnectionCredentials($Entries) {
    if (-not $env:OCTOPUS_API_KEY) { throw 'OCTOPUS_API_KEY is not set.' }
    $github = Get-GitHubToken
    foreach ($e in $Entries) {
        $prefix = ConvertTo-CredentialPrefix $e.connectionId
        [Environment]::SetEnvironmentVariable("$($prefix)_TOKEN", $github)
        [Environment]::SetEnvironmentVariable("$($prefix)_OCTOPUS_TOKEN", $env:OCTOPUS_API_KEY)
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Harvest
# ---------------------------------------------------------------------------------------------------------------

# The cmis command that brings one connection up to date. Nothing stored: harvest the window. Stored, and Since is
# before the first day this script harvested it from (or that day is not known, the state file being lost): sync
# from Since, which widens the stored window. Else a differential sync from the watermark. All reach HarvestUntil.
function Get-HarvestArguments([string] $Id, [bool] $Stored, [string] $From, [hashtable] $Window) {
    if (-not $Stored) { return @('connections', 'harvest', '--connection', $Id, '--since', $Window.Since, '--until', $Window.HarvestUntil, '--on-failure', 'strict') }
    if (-not $From -or [string]::CompareOrdinal($Window.Since, $From) -lt 0) { return @('connections', 'sync', '--connection', $Id, '--since', $Window.Since, '--until', $Window.HarvestUntil, '--on-failure', 'strict') }
    @('connections', 'sync', '--connection', $Id, '--until', $Window.HarvestUntil, '--on-failure', 'strict')
}

# Harvest or sync per connection. A connection that fails is not measured; the others go on. Its cause goes to the
# console only: the page and the data file are meant to be shared. <WorkDir>/harvest-state.json keeps the first day
# each connection was harvested from, written after each one.
function Invoke-Harvest([string] $Cmis, $Entries, [hashtable] $Window, [hashtable] $Paths) {
    $state = if (Test-Path -LiteralPath $Paths.HarvestState) { Get-Content -LiteralPath $Paths.HarvestState -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    if ($null -eq $state) { $state = @{} }
    $inventory = @((Invoke-Cmis $Cmis @('connections', 'inventory') $Paths.Workspace $Paths.Store)['connections'])
    $timings = [ordered]@{}
    $all = [Diagnostics.Stopwatch]::StartNew()
    foreach ($e in $Entries) {
        $id = $e.connectionId
        $stored = @($inventory | Where-Object { $_['connectionId'] -ceq $id -and -not $_['isEmpty'] }).Count -gt 0
        $arguments = Get-HarvestArguments $id $stored ([string] $state[$id]) $Window
        $mode = $arguments[1]
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-Cmis $Cmis $arguments $Paths.Workspace $Paths.Store
            $run = if ($mode -eq 'sync') { $r['harvest'] } else { $r }
            $failed = @($run['connections'] | Where-Object { -not $_['succeeded'] })
            if ($failed.Count) { throw "cmis connections $mode failed: $($failed[0]['error'])" }
            if ($arguments -contains '--since') { $state[$id] = $Window.Since }
            $state | ConvertTo-Json | Set-Content -LiteralPath $Paths.HarvestState
            $timings[$id] = [ordered]@{ mode = $mode; seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1); itemsPulled = $run['workItemsPulled']; revisionsPulled = $run['revisionsPulled']; requests = $run['apiRequestCount'] }
            Write-Host ("{0}: {1} in {2:n1} s ({3} items, {4} revisions pulled, {5} requests)" -f $id, $mode, $clock.Elapsed.TotalSeconds, $run['workItemsPulled'], $run['revisionsPulled'], $run['apiRequestCount'])
        }
        catch {
            $e.measured = $false; $e.reason = "$mode failed (the run's output says why)"
            $timings[$id] = [ordered]@{ mode = $mode; seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1); failed = $true }
            Write-Warning "$id`: $mode failed: $($_.Exception.Message)"
        }
    }
    [ordered]@{ seconds = [math]::Round($all.Elapsed.TotalSeconds, 1); connections = $timings }
}

# ---------------------------------------------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------------------------------------------

function ConvertTo-WeekKey([string] $PeriodStart) {
    [DateTimeOffset]::Parse($PeriodStart, $script:Invariant).UtcDateTime.ToString('yyyy-MM-dd')
}

# The numbers of one weekly period as the page uses them.
function ConvertTo-PeriodNumbers($Period) {
    [ordered]@{
        workInProcess = $Period['workInProcess']; itemsStarted = $Period['itemsStarted']; itemsDelivered = $Period['itemsDelivered']
        meanTimeToDelivery = $Period['meanTimeToDelivery']; throughput = $Period['throughput']; rework = $Period['rework']; netThroughput = $Period['netThroughput']
    }
}

# The weeks the page shows: the periods of the space's score, oldest first, without the leading weeks in which nothing
# at all happened (the window may start long before the first repository did). A week that the window does not cover
# whole is partial.
function Get-PageWeeks($Periods, [hashtable] $Window) {
    $since = [datetime]::ParseExact($Window.Since, 'yyyy-MM-dd', $script:Invariant)
    $end = [datetime]::ParseExact($Window.Until, 'yyyy-MM-dd', $script:Invariant).AddDays(1)
    $ordered = @($Periods | Sort-Object { ConvertTo-WeekKey $_['periodStart'] })
    $first = 0
    while ($first -lt $ordered.Count - 1) {
        $p = $ordered[$first]
        if ($p['itemsStarted'] -or $p['itemsDelivered'] -or $p['workInProcess'] -or $p['throughput'] -or $p['rework'] -or $null -ne $p['meanTimeToDelivery']) { break }
        $first++
    }
    @(for ($i = $first; $i -lt $ordered.Count; $i++) {
            $start = [datetime]::ParseExact((ConvertTo-WeekKey $ordered[$i]['periodStart']), 'yyyy-MM-dd', $script:Invariant)
            [ordered]@{ start = $start.ToString('yyyy-MM-dd'); label = $ordered[$i]['label']; partial = ($start -lt $since -or $start.AddDays(7) -gt $end) }
        })
}

# The connection an item number of a score over several connections belongs to, and the item's own number: the
# connection with the highest base that is not above the number.
function Find-ItemConnection([long] $ItemNumber, $Entries) {
    $hit = @($Entries | Where-Object { $_.itemNumberBase -le $ItemNumber } | Sort-Object { $_.itemNumberBase } -Descending | Select-Object -First 1)
    if (-not $hit) { return $null }
    @{ Entry = $hit[0]; Number = $ItemNumber - $hit[0].itemNumberBase }
}

# One item of a drill list as the page shows it: repository, number, kind, the stage move and when. No title.
function ConvertTo-DrillItem($Item, $Entries) {
    $located = Find-ItemConnection ([long] $Item['itemNumber']) $Entries
    $source = [string] $Item['sourceWorkItemType']
    $kind = switch ($source) { '' { 'issue' } 'Pull Request' { 'pull request' } 'Commit' { 'direct commit' } 'Branch' { 'branch' } default { $source.ToLowerInvariant() } }
    [ordered]@{
        owner = if ($located) { $located.Entry.owner } else { $null }; repo = if ($located) { $located.Entry.repo } else { $null }
        number = if ($located) { $located.Number } else { [long] $Item['itemNumber'] }; kind = $kind
        from = [string] $Item['oldStatus']; to = [string] $Item['newStatus']; at = [string] $Item['revisionDate']
    }
}

# The numbers and item lists of one block of the page. $Score: the score of these connections when already read.
# A drill that fails is a warning and its number is shown without a link; it does not stop the run.
function Get-ScopeModel([string] $Cmis, [hashtable] $Paths, [hashtable] $Window, [string] $Id, [string] $Title, $ScopeEntries, $AllEntries, $Weeks, [Collections.Generic.List[string]] $Warnings, $Score = $null) {
    $connections = @(foreach ($e in $ScopeEntries) { '--connection'; $e.connectionId })
    $common = $connections + @('--since', $Window.Since, '--until', $Window.Until, '--period', 'week')
    $score = if ($null -ne $Score) { $Score } else { Invoke-Cmis $Cmis (@('connections', 'score') + $common) $Paths.Workspace $Paths.Store }
    $periods = [ordered]@{}
    foreach ($p in $score['periods']) { $periods[(ConvertTo-WeekKey $p['periodStart'])] = ConvertTo-PeriodNumbers $p }
    $labels = @{}; foreach ($p in $score['periods']) { $labels[(ConvertTo-WeekKey $p['periodStart'])] = $p['label'] }
    $drills = [ordered]@{}
    foreach ($w in $Weeks) {
        $numbers = $periods[$w.start]
        if (-not $numbers) { continue }
        foreach ($metric in $script:DrillMetrics.Keys) {
            $count = [int] ($numbers[$metric] ?? 0)
            if ($count -eq 0) { continue }
            try { $d = Invoke-Cmis $Cmis (@('connections', 'score-drill') + $common + @('--period-label', $labels[$w.start], '--metric', $script:DrillMetrics[$metric])) $Paths.Workspace $Paths.Store }
            catch {
                Write-Warning "$Title, $metric, week of $($w.start): $($_.Exception.Message)"
                $Warnings.Add("$Title, $metric, week of $($w.start): the drill failed; the number has no list.")
                continue
            }
            $items = @($d['items'] | ForEach-Object { ConvertTo-DrillItem $_ $AllEntries })
            if ($items.Count -ne $count) { $Warnings.Add("$Title, $metric, week of $($w.start): the score says $count, its drill lists $($items.Count) items.") }
            $drills["$metric|$($w.start)"] = $items
        }
    }
    [ordered]@{ id = $Id; title = $Title; periods = $periods; drills = $drills }
}

# One number of one week of a scope; 0 when the scope has no such week or no such number.
function Get-PeriodNumber($Scope, [string] $WeekStart, [string] $Metric) {
    $numbers = $Scope.periods[$WeekStart]
    if ($null -eq $numbers -or $null -eq $numbers[$Metric]) { return 0 }
    [long] $numbers[$Metric]
}

function Get-ScorecardData([string] $Cmis, [hashtable] $Config, $Projects, [hashtable] $Window, [hashtable] $Paths, $HarvestRun) {
    $measured = @($Projects | Where-Object { $_.measured })
    if (-not $measured.Count) { throw 'No project of the space is measured; nothing to compute.' }
    $warnings = [Collections.Generic.List[string]]::new()
    $version = Get-CmisVersion $Cmis
    if (-not $version) { $version = @{ Version = 'unknown'; Commit = $null } }

    $connections = @(foreach ($e in $measured) { '--connection'; $e.connectionId })
    Invoke-Cmis $Cmis (@('connections', 'document') + $connections + @('--from', $Window.Since, '--to', $Window.Until, '--time-zone', $Config.timeZone, '--out', $Paths.Document)) $Paths.Workspace $Paths.Store | Out-Null

    # The weeks come from the space's own score; the per-project scores have the same periods (same window).
    $spaceScore = Invoke-Cmis $Cmis (@('connections', 'score') + $connections + @('--since', $Window.Since, '--until', $Window.Until, '--period', 'week')) $Paths.Workspace $Paths.Store
    $weeks = Get-PageWeeks $spaceScore['periods'] $Window
    $scopes = [Collections.Generic.List[object]]::new()
    $space = Get-ScopeModel $Cmis $Paths $Window $script:SpaceScopeId "Space $($Config.space)" $measured $measured $weeks $warnings $spaceScore
    $scopes.Add($space)
    foreach ($e in $measured) {
        $scopes.Add((Get-ScopeModel $Cmis $Paths $Window $e.connectionId $e.project @($e) $measured $weeks $warnings))
    }
    # The space's additive numbers are the sum of its projects': a difference means two connections share item numbers.
    foreach ($w in $weeks) {
        foreach ($metric in 'workInProcess', 'itemsStarted', 'itemsDelivered', 'throughput', 'rework') {
            $sum = 0; foreach ($s in $scopes | Select-Object -Skip 1) { $sum += Get-PeriodNumber $s $w.start $metric }
            $total = Get-PeriodNumber $space $w.start $metric
            if ($sum -ne $total) { $warnings.Add("Week of $($w.start), $metric`: the space says $total, its projects add up to $sum.") }
        }
    }

    [ordered]@{
        space = $Config.space; octopusServer = $Config.octopusServer; githubOwner = $Config.githubOwner; timeZone = $Config.timeZone
        since = $Window.Since; until = $Window.Until; generatedUtc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        cmis = [ordered]@{ version = $version.Version; commit = $version.Commit; repo = $Config.cmisRepo }
        projects = @($Projects); weeks = @($weeks); scopes = @($scopes); warnings = @($warnings); harvest = $HarvestRun
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------------------------------------------

# A mean time to delivery (cmis gives weeks) as a person reads it, the rules of cmdemo1-scorecard's page: seconds,
# minutes under 90 minutes, hours with one decimal under 48 hours, else days.
function Format-Duration($Weeks) {
    if ($null -eq $Weeks) { return '–' }
    $d = [TimeSpan]::FromDays([double] $Weeks * 7)
    if ($d -lt [TimeSpan]::Zero) { $d = [TimeSpan]::Zero }
    if ($d.TotalMinutes -lt 1) { return [string]::Format($script:Invariant, '{0:0} s', $d.TotalSeconds) }
    if ($d.TotalMinutes -lt 90) { return [string]::Format($script:Invariant, '{0:0} min', $d.TotalMinutes) }
    if ($d.TotalHours -lt 48) { return [string]::Format($script:Invariant, '{0:0.0} h', $d.TotalHours) }
    [string]::Format($script:Invariant, '{0:0.0} d', $d.TotalDays)
}

function ConvertTo-HtmlText([string] $Text) { [Net.WebUtility]::HtmlEncode($Text) }

# The anchor of one drill list.
function Get-DrillAnchor([string] $ScopeId, [string] $Metric, [string] $WeekStart) {
    $short = @{ workInProcess = 'wip'; itemsStarted = 'started'; itemsDelivered = 'delivered' }[$Metric]
    'd-' + ($ScopeId -replace '[^A-Za-z0-9_-]', '-') + "-$short-$WeekStart"
}

# The heading of a week's column: "Oct 5", with the year ("Jan 4 2027") where it differs from the week before, as
# cmdemo1-scorecard writes it.
function Get-WeekShortLabel([string] $WeekStart, [string] $Previous) {
    $day = [datetime]::ParseExact($WeekStart, 'yyyy-MM-dd', $script:Invariant)
    $withYear = $Previous -and [datetime]::ParseExact($Previous, 'yyyy-MM-dd', $script:Invariant).Year -ne $day.Year
    $day.ToString($(if ($withYear) { 'MMM d yyyy' } else { 'MMM d' }), $script:Invariant)
}

# The headings of all week columns, the partial ones marked "*".
function Get-WeekLabels($Weeks) {
    $previous = $null
    foreach ($w in $Weeks) { (Get-WeekShortLabel $w.start $previous) + $(if ($w.partial) { '*' } else { '' }); $previous = $w.start }
}

# The rows of the page, in its order; Detail rows go in the folded panel.
$script:PageRows = @(
    @{ Key = 'workInProcess'; Label = 'Work in process'; Drill = $true; Hint = 'items between start and delivery at the end of the week' }
    @{ Key = 'itemsStarted'; Label = 'Items started'; Drill = $true; Hint = 'items created in the week' }
    @{ Key = 'itemsDelivered'; Label = 'Items delivered'; Drill = $true; Hint = 'items that reached the delivered stage for the first time in the week' }
    @{ Key = 'meanTimeToDelivery'; Label = 'Mean time to delivery (MTTD)'; Duration = $true; Hint = 'mean time from creation to delivery of the items delivered in the week' }
    @{ Key = 'throughput'; Label = 'Throughput (stage moves)'; Detail = $true; Hint = 'forward stage moves before delivery' }
    @{ Key = 'rework'; Label = 'Rework'; Detail = $true; Hint = 'backward stage moves' }
    @{ Key = 'netThroughput'; Label = 'Net throughput'; Detail = $true; Hint = 'throughput less rework' }
)

function Get-CellHtml($Scope, $Row, $Week) {
    $numbers = $Scope.periods[$Week.start]
    if ($null -eq $numbers) { return '<td class="none">–</td>' }
    $value = $numbers[$Row.Key]
    if ($Row['Duration']) { return "<td>$(ConvertTo-HtmlText (Format-Duration $value))</td>" }
    if ($null -eq $value) { return '<td class="none">–</td>' }
    $text = ([long] $value).ToString($script:Invariant)
    if ($Row['Drill'] -and $value -ne 0 -and $Scope.drills.Contains("$($Row.Key)|$($Week.start)")) {
        return "<td><a href=`"#$(Get-DrillAnchor $Scope.id $Row.Key $Week.start)`">$text</a></td>"
    }
    if ($value -eq 0) { return "<td class=`"none`">$text</td>" }
    "<td>$text</td>"
}

function Get-TableHtml($Scope, $Weeks, [bool] $Detail) {
    $labels = @(Get-WeekLabels $Weeks)
    $head = (@(for ($i = 0; $i -lt @($Weeks).Count; $i++) {
                $w = @($Weeks)[$i]
                $title = "Week of $($w.start) (Monday 00:00 UTC to the next)$(if ($w.partial) { ', not covered whole by the window' })"
                "<th scope=`"col`" title=`"$(ConvertTo-HtmlText $title)`">$(ConvertTo-HtmlText $labels[$i])</th>"
            })) -join ''
    $rows = foreach ($r in $script:PageRows | Where-Object { [bool] $_['Detail'] -eq $Detail }) {
        "<tr><th scope=`"row`" title=`"$(ConvertTo-HtmlText $r.Hint)`">$(ConvertTo-HtmlText $r.Label)</th>$(($Weeks | ForEach-Object { Get-CellHtml $Scope $r $_ }) -join '')</tr>"
    }
    "<div class=`"scroll`"><table><thead><tr><th scope=`"col`">Week of</th>$head</tr></thead><tbody>$($rows -join '')</tbody></table></div>"
}

function Get-ItemHtml($Item, [bool] $ShowRepository) {
    $name = if ($ShowRepository) { "$($Item.repo)#$($Item.number)" } else { "#$($Item.number)" }
    # cmis keeps no commit id or branch name with a direct-commit or branch item, so it has no GitHub address of its own.
    $link = if ($Item.kind -in 'issue', 'pull request' -and $Item.owner -and $null -ne $Item.number) {
        "<a href=`"https://github.com/$(ConvertTo-HtmlText $Item.owner)/$(ConvertTo-HtmlText $Item.repo)/issues/$($Item.number)`">$(ConvertTo-HtmlText $name)</a>"
    }
    else { "<span>$(ConvertTo-HtmlText $(if ($ShowRepository) { "$($Item.repo) item $($Item.number)" } else { "item $($Item.number)" }))</span>" }
    $move = if ($Item.from) { "$($Item.from) → $($Item.to)" } else { $Item.to }
    $at = if ($Item.at) { [DateTimeOffset]::Parse($Item.at, $script:Invariant).UtcDateTime.ToString('yyyy-MM-dd HH:mm', $script:Invariant) + ' UTC' } else { '' }
    "<li>$link <span class=`"kind`">$(ConvertTo-HtmlText $Item.kind)</span> <span class=`"move`">$(ConvertTo-HtmlText $move)</span> <time>$at</time></li>"
}

function Get-DrillsHtml($Scope, $Weeks) {
    $labels = @{ workInProcess = 'Work in process'; itemsStarted = 'Items started'; itemsDelivered = 'Items delivered' }
    $parts = foreach ($w in $Weeks) {
        foreach ($metric in $script:DrillMetrics.Keys) {
            $key = "$metric|$($w.start)"
            if (-not $Scope.drills.Contains($key)) { continue }
            $items = @($Scope.drills[$key])
            $heading = "$($Scope.title): $($labels[$metric]), week of $($w.start) ($($items.Count))"
            "<section class=`"drill`" id=`"$(Get-DrillAnchor $Scope.id $metric $w.start)`"><h4>$(ConvertTo-HtmlText $heading)</h4><ul>$(($items | ForEach-Object { Get-ItemHtml $_ ($Scope.id -eq $script:SpaceScopeId) }) -join '')</ul><a class=`"back`" href=`"#s-$($Scope.id)`">back to the table</a></section>"
        }
    }
    if (-not $parts) { return '' }
    # Visible, after all the tables: a hidden list (a closed <details>, or display:none until :target) is not opened
    # or not scrolled to by every browser when the page is opened at its address, and without a script nothing opens it.
    "<section class=`"lists`"><h3>$(ConvertTo-HtmlText $Scope.title): item lists</h3>$($parts -join '')</section>"
}

function Get-ScopeHtml($Scope, $Data, $Project) {
    $sub = if ($Project) {
        "<p class=`"meta`"><a href=`"https://github.com/$(ConvertTo-HtmlText $Project.owner)/$(ConvertTo-HtmlText $Project.repo)`">$(ConvertTo-HtmlText "$($Project.owner)/$($Project.repo)")</a> · repository from $(ConvertTo-HtmlText $Project.source) · environments $(ConvertTo-HtmlText $Project.environments)</p>"
    }
    else { '<p class="meta">All measured projects together.</p>' }
    $heading = if ($Project) { $Project.project } else { $Scope.title }
    @"
<section class="scope" id="s-$($Scope.id)">
<h2>$(ConvertTo-HtmlText $heading)</h2>
$sub
$(Get-TableHtml $Scope $Data.weeks $false)
<details class="detail"><summary>Flow detail: stage moves, not items</summary>$(Get-TableHtml $Scope $Data.weeks $true)</details>
</section>
"@
}

function ConvertTo-ScorecardHtml($Data) {
    $measured = @($Data.projects | Where-Object { $_.measured })
    $notMeasured = @($Data.projects | Where-Object { -not $_.measured })
    $projectList = ($Data.projects | ForEach-Object {
            if ($_.measured) { "<li><a href=`"#s-$($_.connectionId)`">$(ConvertTo-HtmlText $_.project)</a> → $(ConvertTo-HtmlText "$($_.owner)/$($_.repo)") <span class=`"kind`">($(ConvertTo-HtmlText $_.source))</span></li>" }
            else { "<li class=`"off`">$(ConvertTo-HtmlText $_.project): not measured, $(ConvertTo-HtmlText $_.reason)</li>" }
        }) -join ''
    $blocks = foreach ($s in $Data.scopes) {
        $project = if ($s.id -eq $script:SpaceScopeId) { $null } else { @($Data.projects | Where-Object { $_.connectionId -eq $s.id })[0] }
        Get-ScopeHtml $s $Data $project
    }
    $partial = if (@($Data.weeks | Where-Object { $_.partial }).Count) { '<p class="meta">* a week the window does not cover whole.</p>' } else { '' }
    $warnings = if (@($Data.warnings).Count) { "<details class=`"detail`"><summary>Warnings ($(@($Data.warnings).Count))</summary><ul>$(($Data.warnings | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join '')</ul></details>" } else { '' }
    $commit = if ($Data.cmis.commit) { " ($($Data.cmis.commit.Substring(0, [Math]::Min(12, $Data.cmis.commit.Length))))" } else { '' }
    @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Space scorecard $(ConvertTo-HtmlText $Data.space)</title>
<style>
:root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1f23; --muted: #6a6f78; --line: #d9dce1; --head: #f3f4f6; --link: #0b5cad; --mark: #fff4c2; }
@media (prefers-color-scheme: dark) { :root { --bg: #15171b; --fg: #e6e7ea; --muted: #9aa0a9; --line: #343842; --head: #1f2228; --link: #7db4f0; --mark: #3d3518; } }
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg); font: 15px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 1100px; margin: 0 auto; }
h1 { font-size: 1.4rem; margin: 0 0 .25rem; } h2 { font-size: 1.15rem; margin: 2rem 0 .25rem; } h4 { font-size: .95rem; margin: .75rem 0 .25rem; }
a { color: var(--link); } .meta, .kind, time, .none, .off { color: var(--muted); }
.meta { margin: .2rem 0 .6rem; font-size: .9rem; }
.scroll { overflow-x: auto; max-width: 100%; }
table { border-collapse: collapse; font-variant-numeric: tabular-nums; min-width: 100%; }
th, td { border-bottom: 1px solid var(--line); padding: .3rem .55rem; text-align: right; white-space: nowrap; }
th[scope=row], thead th:first-child { text-align: left; position: sticky; left: 0; background: var(--bg); }
thead th { background: var(--head); font-weight: 600; }
details { margin: .5rem 0; } summary { cursor: pointer; color: var(--muted); }
ul { margin: .25rem 0; padding-left: 1.2rem; } li { margin: .1rem 0; }
.drill { margin: .5rem 0; padding: .25rem .6rem; border-left: 3px solid var(--line); }
.drill:target { background: var(--mark); border-left-color: var(--link); }
h3 { font-size: 1rem; margin: 1.5rem 0 .25rem; }
.back { font-size: .85rem; }
.projects li { overflow-wrap: anywhere; }
</style>
</head>
<body>
<main>
<header>
<h1>Delivery scorecard of space $(ConvertTo-HtmlText $Data.space)</h1>
<p class="meta">$(ConvertTo-HtmlText $Data.octopusServer) · window $($Data.since) to $($Data.until) · weeks are ISO weeks, Monday 00:00 UTC to the next · generated $($Data.generatedUtc) · cmis $(ConvertTo-HtmlText $Data.cmis.version)$(ConvertTo-HtmlText $commit)</p>
<p class="meta">$($measured.Count) project(s) measured, $($notMeasured.Count) not measured. A number links to the list of its items, at the end of the page. Every change counts, automation included; commits that automation makes (pins, template syncs) are not work items.</p>
<ul class="projects">$projectList</ul>
$partial
$warnings
</header>
$($blocks -join "`n")
<h2 id="lists">Item lists</h2>
<p class="meta">The items behind each number above, newest week last. Issue and pull request numbers link to GitHub; no titles.</p>
$(($Data.scopes | ForEach-Object { Get-DrillsHtml $_ $Data.weeks }) -join "`n")
</main>
</body>
</html>
"@
}

function Get-MarkdownTable($Scope, $Weeks) {
    $lines = [Collections.Generic.List[string]]::new()
    if (-not @($Weeks).Count) { return 'No week with any number.' }
    $lines.Add('| Week of | ' + (@(Get-WeekLabels $Weeks) -join ' | ') + ' |')
    $lines.Add('|---|' + (($Weeks | ForEach-Object { '---:' }) -join '|') + '|')
    foreach ($r in $script:PageRows) {
        $cells = foreach ($w in $Weeks) {
            $n = $Scope.periods[$w.start]
            if ($null -eq $n) { '–' } elseif ($r['Duration']) { Format-Duration $n[$r.Key] } elseif ($null -eq $n[$r.Key]) { '–' } else { ([long] $n[$r.Key]).ToString($script:Invariant) }
        }
        $lines.Add("| $($r.Label) | $($cells -join ' | ') |")
    }
    $lines -join "`n"
}

# A name or reason as Markdown text: one line, and nothing in it that Markdown would read as table, emphasis, code or link.
function ConvertTo-MarkdownText([string] $Text) {
    ($Text -replace '\r?\n', ' ') -replace '([\\|*_`\[\]<>#])', '\$1'
}

function ConvertTo-SummaryMarkdown($Data) {
    $space = @($Data.scopes | Where-Object { $_.id -eq $script:SpaceScopeId })[0]
    $full = @($Data.weeks | Where-Object { -not $_.partial })
    $last = if ($full.Count) { $full[-1] } else { $null }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# Delivery scorecard of space $($Data.space)")
    $lines.Add('')
    $lines.Add("Window $($Data.since) to $($Data.until); ISO weeks (Monday 00:00 UTC); generated $($Data.generatedUtc) with cmis $($Data.cmis.version).")
    $lines.Add('')
    $lines.Add((Get-MarkdownTable $space $Data.weeks))
    $lines.Add('')
    if (@($Data.weeks | Where-Object { $_.partial }).Count) { $lines.Add('\* a week the window does not cover whole.'); $lines.Add('') }
    if ($last) {
        $lines.Add("## Projects, week of $($last.start)")
        $lines.Add('')
        foreach ($s in $Data.scopes | Where-Object { $_.id -ne $script:SpaceScopeId }) {
            $n = $s.periods[$last.start]
            $mttd = if ($null -eq $n) { $null } else { $n['meanTimeToDelivery'] }
            $p = @($Data.projects | Where-Object { $_.connectionId -eq $s.id })[0]
            $lines.Add("- $(ConvertTo-MarkdownText $p.project) ($(ConvertTo-MarkdownText "$($p.owner)/$($p.repo)")): started $(Get-PeriodNumber $s $last.start 'itemsStarted'), delivered $(Get-PeriodNumber $s $last.start 'itemsDelivered'), WIP $(Get-PeriodNumber $s $last.start 'workInProcess'), MTTD $(Format-Duration $mttd)")
        }
        $lines.Add('')
    }
    $lines.Add('## Projects of the space')
    $lines.Add('')
    foreach ($p in $Data.projects) {
        $name = ConvertTo-MarkdownText $p.project
        $lines.Add($(if ($p.measured) { "- $name`: measured, $(ConvertTo-MarkdownText "$($p.owner)/$($p.repo)") (from $($p.source))" } else { "- $name`: not measured, $(ConvertTo-MarkdownText $p.reason)" }))
    }
    if (@($Data.warnings).Count) { $lines.Add(''); $lines.Add('## Warnings'); $lines.Add(''); foreach ($w in $Data.warnings) { $lines.Add("- $(ConvertTo-MarkdownText $w)") } }
    ($lines -join "`n") + "`n"
}

# The render step: scorecard-data.json, scorecard.html and summary.md in the work directory, from the data the compute
# step gathered. Reads nothing else (not the store, not Octopus, not GitHub), so another renderer can take its place.
function Write-ScorecardFiles($Data, [string] $Directory) {
    $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Directory 'scorecard-data.json')
    ConvertTo-ScorecardHtml $Data | Set-Content -LiteralPath (Join-Path $Directory 'scorecard.html') -NoNewline
    ConvertTo-SummaryMarkdown $Data | Set-Content -LiteralPath (Join-Path $Directory 'summary.md') -NoNewline
}

# ---------------------------------------------------------------------------------------------------------------
# Store in the built-in feed (-StoreFeed)
# ---------------------------------------------------------------------------------------------------------------

# What a store package holds, relative to the work directory: cmis's store directory as cmis writes it (so cmis and
# Scorecard.Web can both read it), the workspace with the connections, and the two files the harvest step reads.
$script:StoreParts = @('store', 'workspace', 'harvest-state.json', 'discovery.json')

# The id of the store's package in the space's built-in feed: <prefix>-scorecard-store.
function Get-StorePackageId([hashtable] $Config) {
    if (-not $Config['prefix']) { throw "-StoreFeed needs 'prefix' in the configuration: the package is <prefix>-scorecard-store." }
    "$($Config.prefix)-scorecard-store"
}

# The version of a store package pushed at $UtcNow: yyyy.M.d.HHmmss in UTC, the time of day as one number (00:15:00
# is 1500, 09:05:07 is 90507): the parts of a package version have no leading zeros, and the four numbers order as the
# times. Seconds, so two runs in one minute do not make the same version (the feed refuses the second).
function Get-StorePackageVersion([datetime] $UtcNow) {
    if ($UtcNow.Kind -ne [DateTimeKind]::Utc) { throw 'Get-StorePackageVersion takes a UTC time.' }
    # 00:00:00 is 1, not 0: a feed may shorten a version that ends in .0 to three numbers.
    $time = [math]::Max(1, $UtcNow.Hour * 10000 + $UtcNow.Minute * 100 + $UtcNow.Second)
    [string]::Format($script:Invariant, '{0}.{1}.{2}.{3}', $UtcNow.Year, $UtcNow.Month, $UtcNow.Day, $time)
}

# The store packages of the versions the feed lists, newest first by their four numbers (not as text: 2026.10.10.1500
# is newer than 2026.10.9.231500), whatever order the feed answers in; a version that is not four numbers is not one
# of ours and is left alone.
function Get-StorePackageOrder($Packages) {
    $ours = @(foreach ($p in @($Packages | Where-Object { $_ })) {
            $v = $null
            if ([string] $p['Version'] -match '^\d+\.\d+\.\d+\.\d+\z' -and [version]::TryParse([string] $p['Version'], [ref] $v)) { @{ Package = $p; Version = $v } }
        })
    @($ours | Sort-Object { $_.Version } -Descending | ForEach-Object { $_.Package })
}

# The package to restore: the newest of Get-StorePackageOrder. $null when there is none: the run starts empty.
function Select-StorePackage($Packages) {
    $ordered = @(Get-StorePackageOrder $Packages)
    if ($ordered.Count) { $ordered[0] } else { $null }
}

# The id of the space's built-in feed.
function Get-BuiltInFeedId([hashtable] $Config) {
    $feeds = @((Invoke-OctopusRequest $Config "/api/$($Config.space)/feeds?feedType=BuiltIn&take=1")['Items'])
    if (-not $feeds.Count) { throw "Space $($Config.space) has no built-in feed (or the key may not view feeds)." }
    $feeds[0]['Id']
}

# The entries of a store package that are not under one of the store parts, or that would leave the directory: a
# package with any is not restored.
function Get-ForeignStoreEntries([string] $ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        @($zip.Entries | ForEach-Object { $_.FullName } | Where-Object {
                $parts = @(($_ -replace '\\', '/') -split '/')
                $parts -contains '..' -or $parts[0] -eq '' -or $parts[0] -cnotin $script:StoreParts -or ($parts.Count -gt 1 -and $parts[0] -cnotin 'store', 'workspace')
            })
    }
    finally { $zip.Dispose() }
}

# Restore: the newest store package of the feed replaces the store, workspace and state files of the work directory.
# It is unpacked beside the work directory first and swapped in only when that worked, so a package that cannot be
# restored changes nothing, and the next older one is tried (three at most; when none can be restored the run fails). Returns the version restored, or $null
# when the feed has none (the work directory is then left as it is).
function Restore-StoreFromFeed([hashtable] $Config, [string] $Directory) {
    $id = Get-StorePackageId $Config
    $feed = Get-BuiltInFeedId $Config
    $listed = Invoke-OctopusRequest $Config "/api/$($Config.space)/feeds/$feed/packages/versions?packageId=$([uri]::EscapeDataString($id))&take=100"
    $candidates = @(Get-StorePackageOrder @($listed['Items']) | Select-Object -First 3)
    if (-not $candidates.Count) { Write-Host "store: the built-in feed has no $id yet; starting from what $Directory holds"; return $null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($package in $candidates) {
        $staging = Join-Path (Split-Path -Parent $Directory) ".restore-$([guid]::NewGuid().ToString('N'))"
        $zip = "$staging.zip"
        try {
            Invoke-OctopusTransfer $Config "/api/$($Config.space)/packages/$([uri]::EscapeDataString($package['Id']))/raw" -OutFile $zip
            $foreign = @(Get-ForeignStoreEntries $zip)
            if ($foreign.Count) { throw "it holds $($foreign.Count) entries outside the store parts (first: $($foreign[0]))" }
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)
            foreach ($part in $script:StoreParts) {
                $path = Join-Path $Directory $part
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
                $unpacked = Join-Path $staging $part
                if (Test-Path -LiteralPath $unpacked) { Move-Item -LiteralPath $unpacked -Destination $path }
            }
            Write-Host ("store: restored {0} {1} ({2:n1} MB)" -f $id, $package['Version'], ((Get-Item -LiteralPath $zip -Force).Length / 1MB))
            return [string] $package['Version']
        }
        catch { Write-Warning "store: $id $($package['Version']) not restored: $($_.Exception.Message)" }
        finally {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    throw "store: none of the newest $($candidates.Count) versions of $id could be restored."
}

# The store package as a zip: every file of the store parts that the work directory has, by its path relative to it.
# Written entry by entry (Compress-Archive leaves out hidden files, and cmis keeps the workspace in .cmis).
function New-StoreArchive([string] $Directory, [string] $ZipPath) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $root = (Resolve-Path -LiteralPath $Directory).Path.TrimEnd('/') + '/'
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($part in $script:StoreParts) {
            $path = Join-Path $Directory $part
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $files = if (Test-Path -LiteralPath $path -PathType Container) { @(Get-ChildItem -LiteralPath $path -Recurse -File -Force) } else { @(Get-Item -LiteralPath $path -Force) }
            foreach ($f in $files) {
                [void] [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $f.FullName.Substring($root.Length), [IO.Compression.CompressionLevel]::Optimal)
            }
        }
    }
    finally { $zip.Dispose() }
}

# Push: the store package of this run to the built-in feed, as a new version (overwriteMode=FailIfExists: a version
# is never overwritten). Returns the version pushed.
function Publish-StoreToFeed([hashtable] $Config, [string] $Directory, [datetime] $UtcNow = [datetime]::UtcNow) {
    $id = Get-StorePackageId $Config
    $version = Get-StorePackageVersion $UtcNow
    $folder = Join-Path ([IO.Path]::GetTempPath()) "space-scorecard-push-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $folder | Out-Null
    try {
        $zip = Join-Path $folder "$id.$version.zip"
        New-StoreArchive $Directory $zip
        $redirect = Invoke-OctopusTransfer $Config "/api/$($Config.space)/packages/raw?overwriteMode=FailIfExists" -UploadFile $zip
        if ($redirect) {
            # The answer was a redirect, not "created": the push counts only when the feed lists that version now.
            $feed = Get-BuiltInFeedId $Config
            $listed = Invoke-OctopusRequest $Config "/api/$($Config.space)/feeds/$feed/packages/versions?packageId=$([uri]::EscapeDataString($id))&take=100"
            if (-not @($listed['Items'] | Where-Object { [string] $_['Version'] -ceq $version }).Count) { throw "Octopus answered the push of $id $version with a $redirect, and the feed does not list that version." }
            Write-Host "store: Octopus answered the push with a $redirect; the feed lists $id $version"
        }
        Write-Host ("store: pushed {0} {1} ({2:n1} MB)" -f $id, $version, ((Get-Item -LiteralPath $zip).Length / 1MB))
    }
    finally { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
    $version
}

# ---------------------------------------------------------------------------------------------------------------
# Inside Octopus
# ---------------------------------------------------------------------------------------------------------------

# Whether this runs in an Octopus step: Calamari defines $OctopusParameters and New-OctopusArtifact.
function Test-InsideOctopus {
    [bool] ((Get-Variable -Name OctopusParameters -ErrorAction SilentlyContinue) -or (Get-Command New-OctopusArtifact -ErrorAction SilentlyContinue))
}

# The line the task log highlights: the space's numbers of the last full week, what is measured, the store version.
function Get-HighlightLine($Data, [string] $StoreVersion) {
    $space = @($Data.scopes | Where-Object { $_.id -eq $script:SpaceScopeId }) | Select-Object -First 1
    $full = @($Data.weeks | Where-Object { -not $_.partial })
    $measured = @($Data.projects | Where-Object { $_.measured }).Count
    $line = "Space $($Data.space), $($Data.since) to $($Data.until): "
    if ($full.Count -and $space) {
        $w = $full[-1].start
        $n = $space.periods[$w]
        $mttd = if ($null -eq $n) { $null } else { $n['meanTimeToDelivery'] }
        $line += "week of $w started $(Get-PeriodNumber $space $w 'itemsStarted'), delivered $(Get-PeriodNumber $space $w 'itemsDelivered'), WIP $(Get-PeriodNumber $space $w 'workInProcess'), MTTD $(Format-Duration $mttd); "
    }
    else { $line += 'no full week yet; ' }
    $line += "$measured of $(@($Data.projects).Count) projects measured"
    $failed = @($Data.projects | Where-Object { -not $_.measured -and "$($_.reason)" -like '* failed *' }).Count
    if ($failed) { $line += ", $failed harvest(s) failed" }
    if (@($Data.warnings).Count) { $line += ", $(@($Data.warnings).Count) warning(s)" }
    if ($StoreVersion) { $line += "; store $StoreVersion" }
    $line
}

# The page, the summary and the document as artifacts of the Octopus task.
function Publish-OctopusArtifacts([string] $Directory) {
    foreach ($name in 'scorecard.html', 'summary.md', 'document.json') {
        $path = Join-Path $Directory $name
        if (Test-Path -LiteralPath $path) { New-OctopusArtifact -Path $path -Name $name }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------------------------------

if ($LoadOnly) { return }
if (-not $Config -or -not $WorkDir) { throw 'Both -Config and -WorkDir are required.' }
if ($StoreFeed -and $SkipHarvest) { throw '-StoreFeed and -SkipHarvest exclude each other: -SkipHarvest asks Octopus for nothing.' }

$started = [Diagnostics.Stopwatch]::StartNew()
$cfg = Read-SpaceConfig $Config
if ($StoreFeed) { [void] (Get-StorePackageId $cfg) }
$window = Resolve-Window $cfg $Since $Until
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$paths = @{
    Bin = Join-Path $WorkDir 'bin'; Workspace = Join-Path $WorkDir 'workspace'; Store = Join-Path $WorkDir 'store'
    HarvestState = Join-Path $WorkDir 'harvest-state.json'; Document = Join-Path $WorkDir 'document.json'
}
foreach ($dir in $paths.Workspace, $paths.Store) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Write-Host "Space $($cfg.space), window $($window.Since) to $($window.Until) ($($cfg.timeZone))"

if (-not $SkipHarvest -and -not $env:OCTOPUS_API_KEY) { throw 'OCTOPUS_API_KEY is not set.' }
$cmis = Get-Cmis $cfg $paths.Bin
$discovery = Join-Path $WorkDir 'discovery.json'

if ($SkipHarvest) {
    # Asks neither Octopus nor GitHub and changes no connection: the projects of the last full run, the workspace as is.
    if (-not (Test-Path -LiteralPath $discovery)) { throw "-SkipHarvest needs $discovery of an earlier run; run without -SkipHarvest first." }
    $projects = @(Get-Content -LiteralPath $discovery -Raw | ConvertFrom-Json -AsHashtable)
    $measured = @($projects | Where-Object { $_.measured })
    if (-not $measured.Count) { throw 'No project of the space is measured.' }
    Read-ConnectionBases $cmis $measured $paths
    $harvest = [ordered]@{ skipped = $true }
}
else {
    $restored = if ($StoreFeed) { Restore-StoreFromFeed $cfg $WorkDir } else { $null }
    foreach ($dir in $paths.Workspace, $paths.Store) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Not a closure: a closure would not see the functions of this script.
    $getJson = { param($Path) Invoke-OctopusRequest $cfg $Path }
    # Only GitHub's 404 means "no such repository"; any other failure (network, rate limit, login) stops the run.
    $repoExists = { param($Owner, $Repo) Test-GitHubRepository $Owner $Repo }
    $projects = @(Get-SpaceProjects $cfg $getJson $repoExists)
    foreach ($p in $projects) {
        Write-Host $(if ($p.measured) { "  $($p.project) -> $($p.owner)/$($p.repo) (from $($p.source), environments $($p.environments))" } else { "  $($p.project): not measured, $($p.reason)" })
    }
    $measured = @($projects | Where-Object { $_.measured })
    if (-not $measured.Count) { throw 'No project of the space is measured.' }
    Set-Connections $cmis $cfg $measured $paths
    Set-ConnectionCredentials $measured
    $harvest = Invoke-Harvest $cmis $measured $window $paths
    # Written after the harvest: a project whose harvest failed is listed as not measured.
    ConvertTo-Json -InputObject @($projects) -Depth 5 | Set-Content -LiteralPath $discovery
}

$data = Get-ScorecardData $cmis $cfg $projects $window $paths $harvest
if ($StoreFeed) { $data.store = [ordered]@{ package = Get-StorePackageId $cfg; restored = $restored } }
Write-ScorecardFiles $data $WorkDir
foreach ($w in $data.warnings) { Write-Warning $w }
$inOctopus = Test-InsideOctopus
if ($inOctopus) { Publish-OctopusArtifacts $WorkDir }
# Last: only a run that got this far pushes its store.
$pushed = if ($StoreFeed) { Publish-StoreToFeed $cfg $WorkDir } else { $null }
# The store is pushed by now: a highlight that fails is a warning, not a failed run.
if ($inOctopus) {
    try { Write-Highlight (Get-HighlightLine $data $pushed) }
    catch { Write-Warning "No highlight: $($_.Exception.Message)" }
}
Write-Host ("Done in {0:n1} s: {1}" -f $started.Elapsed.TotalSeconds, (Join-Path $WorkDir 'scorecard.html'))
