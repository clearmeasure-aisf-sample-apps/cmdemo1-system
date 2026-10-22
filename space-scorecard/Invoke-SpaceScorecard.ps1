#!/usr/bin/env pwsh
#Requires -Version 7.5

<#
.SYNOPSIS
    The delivery scorecard of a whole Octopus Deploy space: every project of the space paired with its GitHub
    repository, harvested with cmis (Clear Measure Intelligence Scorecard), written as one static page.

.DESCRIPTION
    Steps 1 to 3 of the design "Space-level scorecard on cmis". One run, in this order (each step a function below):

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
                    first harvested day). A connection that fails for a passing cause is tried again (HarvestAttempts
                    tries, 30 s apart: GitHub's GraphQL API times out now and then); one that still fails is not
                    measured; the others go on.
      Compute       "connections score --period week" per connection and over all of them, "connections document"
                    over all of them (document.json), and "connections score-drill" for every weekly cell of
                    Items started, Items delivered and Work in process that is not zero (the item lists). A space
                    number that is not the sum of its projects', and a list whose length is not its number, are
                    warnings on the page.
      Render        scorecard.html (one file, no external request, no script) and summary.md, from
                    scorecard-data.json, the numbers and lists the compute step gathered (no item titles). One function
                    (Write-ScorecardFiles), apart from harvest and compute, so another renderer can take its place.
      Export        With scorecardVersion in the configuration: the pages of Scorecard.Web (of scorecardRepo) as
                    static files in <WorkDir>/site (index.html, split.html, people.html, split-people.html, drill/,
                    css/, fonts/), the same pages as the live scorecard, from this run's store, and the site as
                    scorecard-site.zip. Scorecard.Web is built here from the commit release scorecardVersion of the
                    Octopus project scorecardProject (in scorecardSpace, default the space) names (its notes), or
                    the commit scorecardCommit pins, with the .NET SDK of the machine. When the build or the export
                    fails, a warning, and scorecard.html is the page.
      Publish       With -PublishSite: the exported site into the public blob container site.container of storage
                    account site.account as the signed-in az identity (in Octopus, the step's Azure account); files
                    the export no longer has are deleted. The address is in the summary and the highlight. A
                    failure fails the run at its end, after the push.
      Pages         With -PublishPages: the exported site with a data layer for AI tools (llms.txt at the root,
                    data/: every number, the items behind each, every item's title and stage history, cmis's
                    status) as one commit without history, force-pushed to branch site.pages.branch of the GitHub
                    repository site.pages.repo, which GitHub Pages serves at site.pages.url. A failure fails the
                    run at its end, after the push, as -PublishSite's does.
      Octopus       Inside an Octopus step (OctopusParameters or New-OctopusArtifact is there): summary.md,
                    document.json and the pages (scorecard-site.zip and index.html; scorecard.html without an export)
                    become artifacts of the task, and a line of the space's last full week is highlighted.
      Push          With -StoreFeed, after everything above succeeded: store, workspace, harvest-state.json and
                    discovery.json as <prefix>-scorecard-store.<version>.zip to the built-in feed (never replacing a
                    version), version yyyy.M.d.HHmmss in UTC. A run that fails pushes nothing.

    cmis and Scorecard.Web run culture-invariant (DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1): Scorecard.Web rebuilds a
    store that cmis wrote under another culture from its raw files.

    Weeks are cmis's weekly periods: ISO weeks, Monday 00:00 UTC to the next, as cmdemo1-scorecard's page shows them.
    timeZone only sets the calendar days of document.json and what "today" is.

    Credentials stay in this process: CMIS_<ID>_TOKEN (GITHUB_TOKEN, else "gh auth token") and
    CMIS_<ID>_OCTOPUS_TOKEN (OCTOPUS_API_KEY) per connection, ID = the connection id upper-cased with "-" as "_".
    Nothing is written to disk or printed. The Octopus key also reads and pushes the store package (-StoreFeed).

.PARAMETER Config
    The space's configuration file (see README.md), for example space-scorecard/cmdemo1.json or cmdemo2.json.
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
.PARAMETER PublishSite
    Publishes the exported site to the configuration's blob container (needs site.account, site.container and
    scorecardVersion, and az signed in as an identity that may write that container).
.PARAMETER PublishPages
    Publishes the exported site and its data layer to the configuration's GitHub Pages branch (needs site.pages and
    scorecardVersion, git on the PATH, and a GitHub token that may push to site.pages.repo).
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
    [switch] $PublishSite,
    [switch] $PublishPages,
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
# How often one connection's harvest or sync is tried, and the pause between two tries: GitHub's GraphQL API answers
# "Something went wrong while executing your query" now and then (a query that times out on its side), and the same
# query works moments later.
$script:HarvestAttempts = 4
$script:HarvestRetrySeconds = 30
# The failures worth another try: GitHub's own timeouts and server errors, and secondary rate limits. A bad token, a
# repository that is not there or a configuration error fails the same way again at once.
$script:TransientHarvestError = 'Something went wrong while executing your query|timed? ?out|timeout|\b50[0234]\b|secondary rate limit'

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
    # The pages through Scorecard.Web's export: the release of the deployable's Octopus project names the commit.
    if ($c['scorecardVersion']) {
        if (-not ($c['scorecardVersion'] -is [string] -and $c['scorecardVersion'] -cmatch '^\d+\.\d+\.\d+\z')) { throw "$Path`: 'scorecardVersion' must be a release number such as 1.0.40." }
        if (-not ($c['scorecardRepo'] -is [string] -and $c['scorecardRepo'] -cmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+\z')) { throw "$Path`: 'scorecardRepo' (owner/repo) is required with 'scorecardVersion'." }
        # The commit pinned: the release's notes are not read, so the Octopus project need not exist any more.
        if ($null -ne $c['scorecardCommit']) {
            if (-not ($c['scorecardCommit'] -is [string] -and $c['scorecardCommit'] -cmatch '^[0-9a-f]{40}\z')) { throw "$Path`: 'scorecardCommit' must be a full commit id (40 lower-case hex digits)." }
        }
        elseif (-not ($c['scorecardProject'] -is [string] -and $c['scorecardProject'].Trim())) { throw "$Path`: 'scorecardProject' (the Octopus project of the release) is required with 'scorecardVersion' when 'scorecardCommit' does not pin the commit." }
    }
    # The space of scorecardProject when the deployable belongs to another system's space (it goes into a request path).
    if ($null -ne $c['scorecardSpace'] -and -not ($c['scorecardSpace'] -is [string] -and $c['scorecardSpace'] -cmatch '^Spaces-\d+\z')) { throw "$Path`: 'scorecardSpace' must be an Octopus space id such as Spaces-355." }
    if ($c['site']) {
        $s = $c['site']
        if ($s -isnot [Collections.IDictionary]) { throw "$Path`: 'site' needs 'account' (a storage account name) and 'container' (a blob container name), or 'pages'." }
        # A blob container (account and container), GitHub Pages (pages), or both while one replaces the other.
        if ($s.Contains('account') -or $s.Contains('container') -or -not $s.Contains('pages')) {
            if (-not ("$($s['account'])" -cmatch '^[a-z0-9]{3,24}\z') -or -not ("$($s['container'])" -cmatch '^[a-z0-9](?!.*--)[a-z0-9-]{1,61}[a-z0-9]\z')) {
                throw "$Path`: 'site' needs 'account' (a storage account name) and 'container' (a blob container name)."
            }
        }
        if ($s.Contains('pages')) {
            $g = $s['pages']
            if ($g -isnot [Collections.IDictionary] -or -not ("$($g['repo'])" -cmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+\z') -or -not ("$($g['url'])" -cmatch '^https://[^/\s]+(/\S*)?\z')) {
                throw "$Path`: 'site.pages' needs 'repo' (owner/repo) and 'url' (the https:// address GitHub Pages serves it at)."
            }
            if (-not $g['branch']) { $g['branch'] = 'gh-pages' }
            if (-not ("$($g['branch'])" -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*\z') -or "$($g['branch'])" -match '\.\.|\.lock\z|/\z') { throw "$Path`: 'site.pages.branch' must be a branch name." }
            if (-not $g['url'].EndsWith('/')) { $g['url'] += '/' }
        }
        if (-not $c['scorecardVersion']) { throw "$Path`: 'site' needs 'scorecardVersion': the published pages are the export's." }
    }
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
            throw "cmis $($Arguments[0..1] -join ' ') failed: $(Get-CmisFailure $envelope $exit "$((Get-Content -LiteralPath $errors -Raw) ?? '')")"
        }
        $envelope['data']
    }
    finally { Remove-Item -LiteralPath $errors -Force -ErrorAction SilentlyContinue }
}

# Why a cmis command failed, from its envelope: cmis's code and cause, and the first failed connection's own error
# (harvest: data.connections, sync: data.harvest.connections), which the cause only points at. Without an envelope,
# the exit code and standard error.
function Get-CmisFailure($Envelope, [int] $Exit, [string] $StandardError) {
    $problem = if ($Envelope -is [Collections.IDictionary]) { $Envelope['error'] } else { $null }
    if ($problem -isnot [Collections.IDictionary]) { return "exit $Exit; $StandardError".Trim() }
    $cause = "$($problem['code']): $($problem['cause'])"
    $data = $Envelope['data']
    if ($data -is [Collections.IDictionary]) {
        $runs = @($data, $data['harvest']) | Where-Object { $_ -is [Collections.IDictionary] }
        $failed = @(foreach ($run in $runs) { @($run['connections']) | Where-Object { $_ -is [Collections.IDictionary] -and $_['error'] } }) | Select-Object -First 1
        if ($failed) { $cause += " [$($failed['connectionId']): $($failed['error'])]" }
    }
    $cause
}

# A normalized store that cmis wrote under a culture (en-US, before this script ran cmis culture-invariant) cannot be
# opened culture-invariant: cmis stops with CultureNotFoundException. It is then rebuilt from the raw harvest, offline
# ("connections renormalize": no tracker is asked, the numbers stay the same). Returns whether it was rebuilt.
function Repair-StoreCulture([string] $Cmis, [hashtable] $Paths) {
    $db = Join-Path $Paths.Store 'normalized.db'
    if (-not (Test-Path -LiteralPath $db)) { return $false }
    try { Invoke-Cmis $Cmis @('connections', 'inventory') $Paths.Workspace $Paths.Store | Out-Null; return $false }
    catch { if ("$_" -notmatch 'CultureNotFoundException|is an invalid culture identifier') { throw } }
    # Kept aside until the rebuild worked: a failed one leaves the store as it was.
    $aside = "$db.culture-$([guid]::NewGuid().ToString('N'))"
    Move-Item -LiteralPath $db -Destination $aside
    try { $rebuilt = Invoke-Cmis $Cmis @('connections', 'renormalize') $Paths.Workspace $Paths.Store }
    catch {
        Remove-Item -LiteralPath $db -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $aside -Destination $db
        throw
    }
    Remove-Item -LiteralPath $aside -Force
    Write-Host "store: normalized.db was written under another culture; rebuilt culture-invariant from the raw harvest ($(@($rebuilt['connections']).Count) connections)"
    $true
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

# The error of one connection in the last run cmis logged in <store>/harvest-runs.jsonl, when that run started at or
# after <After> ($null when it has none, is older, or the log cannot be read): a failed sync answers data: null, so this
# is where its cause is.
function Get-LastHarvestError([string] $Store, [string] $ConnectionId, [DateTimeOffset] $After) {
    $log = Join-Path $Store 'harvest-runs.jsonl'
    if (-not (Test-Path -LiteralPath $log)) { return $null }
    try {
        $line = @(Get-Content -LiteralPath $log -Tail 1)[0]
        $record = $line | ConvertFrom-Json -AsHashtable -DateKind String
        if ([DateTimeOffset]::Parse([string] $record['StartedUtc'], $script:Invariant) -lt $After) { return $null }
        $hit = @(@($record['Connections']) | Where-Object { $_ -is [Collections.IDictionary] -and $_['ConnectionId'] -ceq $ConnectionId -and $_['Error'] })
        if ($hit.Count) { [string] $hit[0]['Error'] } else { $null }
    }
    catch { $null }
}

# Harvest or sync per connection, each tried up to HarvestAttempts times. A connection that fails is not measured; the
# others go on. Its cause goes to the
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
            for ($attempt = 1; ; $attempt++) {
                $tried = [DateTimeOffset]::UtcNow
                try {
                    $r = Invoke-Cmis $Cmis $arguments $Paths.Workspace $Paths.Store
                    $run = if ($mode -eq 'sync') { $r['harvest'] } else { $r }
                    $failed = @($run['connections'] | Where-Object { -not $_['succeeded'] })
                    if ($failed.Count) { throw "cmis connections $mode failed: $($failed[0]['error'])" }
                    break
                }
                catch {
                    $message = $_.Exception.Message
                    $last = Get-LastHarvestError $Paths.Store $id $tried.AddSeconds(-1)
                    if ($last -and -not $message.Contains($last)) { $message += " [$id`: $last]" }
                    if ($attempt -ge $script:HarvestAttempts -or $message -notmatch $script:TransientHarvestError) { throw $message }
                    Write-Host "$id`: $mode failed (try $attempt of $($script:HarvestAttempts)), again in $($script:HarvestRetrySeconds) s: $message"
                    Start-Sleep -Seconds $script:HarvestRetrySeconds
                }
            }
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

# One item of a drill list as the page shows it: repository, number, kind, the stage move and when. No title. The
# connection it belongs to joins it to the item's stage history (the data layer of -PublishPages).
function ConvertTo-DrillItem($Item, $Entries) {
    $located = Find-ItemConnection ([long] $Item['itemNumber']) $Entries
    $source = [string] $Item['sourceWorkItemType']
    $kind = switch ($source) { '' { 'issue' } 'Pull Request' { 'pull request' } 'Commit' { 'direct commit' } 'Branch' { 'branch' } default { $source.ToLowerInvariant() } }
    [ordered]@{
        connection = if ($located) { $located.Entry['connectionId'] } else { $null }
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

# What cmis's score says its numbers are: per metric its definition, unit and how periods add up, and the interval
# and calendar of the periods. Empty when the score has none.
function Get-ScoreSemantics($Score) {
    $semantics = if ($Score -is [Collections.IDictionary]) { $Score['semantics'] } else { $null }
    if ($semantics -isnot [Collections.IDictionary]) { return [ordered]@{ metrics = @(); interval = $null; calendar = $null } }
    [ordered]@{
        metrics = @(foreach ($m in @($semantics['metrics'])) { if ($m -is [Collections.IDictionary]) { [ordered]@{ name = $m['name']; unit = $m['unit']; aggregation = $m['aggregation']; definition = $m['definition'] } } })
        interval = $semantics['interval']; calendar = $semantics['calendar']
    }
}

function Get-ScorecardData([string] $Cmis, [hashtable] $Config, $Projects, [hashtable] $Window, [hashtable] $Paths, $HarvestRun, [switch] $IncludeTitles) {
    $measured = @($Projects | Where-Object { $_.measured })
    if (-not $measured.Count) { throw 'No project of the space is measured; nothing to compute.' }
    $warnings = [Collections.Generic.List[string]]::new()
    $version = Get-CmisVersion $Cmis
    if (-not $version) { $version = @{ Version = 'unknown'; Commit = $null } }

    $connections = @(foreach ($e in $measured) { '--connection'; $e.connectionId })
    # With the items' titles for the data layer of -PublishPages (the exported pages show them too).
    Invoke-Cmis $Cmis (@('connections', 'document') + $connections + @('--from', $Window.Since, '--to', $Window.Until, '--time-zone', $Config.timeZone) + $(if ($IncludeTitles) { @('--include-titles') } else { @() }) + @('--out', $Paths.Document)) $Paths.Workspace $Paths.Store | Out-Null

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
        # What cmis says each number is (its score's "semantics"): the definitions the data layer quotes.
        semantics = Get-ScoreSemantics $spaceScore
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
# Export through Scorecard.Web
# ---------------------------------------------------------------------------------------------------------------

# The commit a release of the scorecard deployable was built from: its release workflow writes the notes
# "Build <run address> of <40 hex digits>, committed <time>". $null when the notes name none.
function Get-ReleaseCommit([string] $Notes) {
    if ("$Notes" -cmatch '\bof ([0-9a-f]{40})\b') { return $Matches[1] }
    $null
}

# Runs a script block with the secrets of this process (GITHUB_TOKEN, OCTOPUS_API_KEY, every CMIS_*_TOKEN, and
# AZURE_CONFIG_DIR, where Octopus signed az in as the site's identity) taken out of its environment, and puts them back
# after: the build and the export of Scorecard.Web need none of them, and the processes they start inherit the
# environment. Not an isolation boundary (they run as the same user), but nothing they start finds a credential in its
# environment. Returns what the block returns.
function Invoke-WithoutSecrets([scriptblock] $Script) {
    $names = @(Get-ChildItem env: | Where-Object { $_.Name -cin 'GITHUB_TOKEN', 'OCTOPUS_API_KEY', 'AZURE_CONFIG_DIR' -or $_.Name -cmatch '^CMIS_.+_TOKEN\z' } | ForEach-Object { $_.Name })
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
    try { & $Script }
    finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
}

# The Octopus space of scorecardProject: scorecardSpace, else the space of the configuration (the scorecard deployable
# may belong to another system, whose space then needs to be readable with the same key).
function Get-ScorecardSpace([hashtable] $Config) {
    if ($Config['scorecardSpace']) { [string] $Config['scorecardSpace'] } else { [string] $Config.space }
}

# Scorecard.Web of release scorecardVersion of the Octopus project scorecardProject (in scorecardSpace), framework-dependent, in
# <Directory>: the release's notes name the commit (scorecardCommit, when the configuration pins it, instead: Octopus
# is not asked); its source comes through the GitHub REST API (tarball of
# scorecardRepo) and "dotnet publish" builds Scorecard.Web/Scorecard.Web.csproj (a .NET SDK of the project's
# framework on the PATH: Hosted Ubuntu has one). Built as the image of that release is (Release, no app host, the
# release number as the version), without NuGet's vulnerability audit: an advisory published after the release would
# otherwise stop the build of a commit that built before. Reused when <Directory> holds that build. Returns the path
# of Scorecard.Web.dll.
function Get-ScorecardWeb([hashtable] $Config, [string] $Directory) {
    $version = $Config.scorecardVersion
    $dll = Join-Path $Directory 'Scorecard.Web.dll'
    $marker = Join-Path $Directory 'space-scorecard-build.json'
    if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $marker)) {
        $built = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -AsHashtable
        if ($built['version'] -ceq $version -and $built['repository'] -ceq $Config.scorecardRepo -and (-not $Config['scorecardCommit'] -or $built['commit'] -ceq $Config['scorecardCommit'])) {
            Write-Host "Scorecard.Web $version`: reused from $Directory (commit $($built['commit']))"
            return $dll
        }
    }
    $started = [Diagnostics.Stopwatch]::StartNew()
    $commit = Get-ScorecardCommit $Config

    $work = Join-Path ([IO.Path]::GetTempPath()) "scorecard-web-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $tarball = Join-Path $work 'source.tar.gz'
        Invoke-GitHubGet "/repos/$($Config.scorecardRepo)/tarball/$commit" 'application/vnd.github+json' $tarball
        $source = Join-Path $work 'source'
        New-Item -ItemType Directory -Path $source | Out-Null
        $PSNativeCommandUseErrorActionPreference = $false
        tar -xzf $tarball -C $source --strip-components=1
        if ($LASTEXITCODE -ne 0) { throw "Unpacking $($Config.scorecardRepo) at $commit failed (exit $LASTEXITCODE)." }
        $csproj = Join-Path $source 'Scorecard.Web/Scorecard.Web.csproj'
        if (-not (Test-Path -LiteralPath $csproj)) { throw "$($Config.scorecardRepo) at $commit has no Scorecard.Web/Scorecard.Web.csproj." }
        if (Test-Path -LiteralPath $Directory) { Remove-Item -LiteralPath $Directory -Recurse -Force }
        $log = Join-Path $work 'publish.log'
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
        $exit = Invoke-WithoutSecrets {
            dotnet publish $csproj --configuration Release --output $Directory -p:UseAppHost=false "-p:Version=$version" -p:NuGetAudit=false *> $log
            $LASTEXITCODE
        }
        if ($exit -ne 0 -or -not (Test-Path -LiteralPath $dll)) {
            $tail = @(Get-Content -LiteralPath $log -Tail 15 -ErrorAction SilentlyContinue) -join "`n"
            throw "dotnet publish of Scorecard.Web $version ($commit) failed (exit $exit):`n$tail"
        }
        ConvertTo-Json -InputObject ([ordered]@{ version = $version; repository = $Config.scorecardRepo; commit = $commit }) | Set-Content -LiteralPath $marker
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ("Scorecard.Web {0}: built from {1} at {2} in {3:n0} s" -f $version, $Config.scorecardRepo, $commit, $started.Elapsed.TotalSeconds)
    $dll
}

# The commit of Scorecard.Web to build: scorecardCommit when the configuration pins it, else the one the notes of release
# scorecardVersion of the Octopus project scorecardProject (in scorecardSpace) name.
function Get-ScorecardCommit([hashtable] $Config) {
    if ($Config['scorecardCommit']) { return [string] $Config['scorecardCommit'] }
    $version = $Config.scorecardVersion
    $name = $Config.scorecardProject
    $space = Get-ScorecardSpace $Config
    $projects = @(@((Invoke-OctopusRequest $Config "/api/$space/projects?partialName=$([uri]::EscapeDataString($name))&take=100")['Items']) | Where-Object { $_ -and $_['Name'] -ceq $name })
    if ($projects.Count -ne 1) { throw "Space $space has $($projects.Count) projects named $name." }
    $release = Invoke-OctopusRequest $Config "/api/$space/projects/$($projects[0]['Id'])/releases/$([uri]::EscapeDataString($version))"
    $commit = Get-ReleaseCommit ([string] $release['ReleaseNotes'])
    if (-not $commit) { throw "The notes of release $version of $name name no commit." }
    $commit
}

# The export: the pages Scorecard.Web serves, as static files in <OutDir> (index.html, split.html, people.html,
# split-people.html, drill/, css/, fonts/, logo, icon), from the cmis store and the workspace's connections. Weeks as
# Scorecard.Web's own page shows them by default (the first to the last week with data). Throws when the export
# fails or writes no index.html.
function Export-ScorecardSite([string] $WebDll, [hashtable] $Paths, [string] $Title, [string] $OutDir) {
    $connections = Join-Path $Paths.Workspace '.cmis/work-tracking.json'
    if (-not (Test-Path -LiteralPath $connections)) { throw "There is no $connections to export from." }
    if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
    $arguments = @($WebDll, 'export', '--store', $Paths.Store, '--connections', $connections, '--out', $OutDir, '--title', $Title)
    $result = Invoke-WithoutSecrets {
        $PSNativeCommandUseErrorActionPreference = $false
        $lines = @(dotnet @arguments 2>&1 | ForEach-Object { "$_" })
        @{ Lines = $lines; Exit = $LASTEXITCODE }
    }
    foreach ($line in $result.Lines) { Write-Host "  export: $line" }
    if ($result.Exit -ne 0) { throw "Scorecard.Web export failed (exit $($result.Exit))." }
    if (-not (Test-Path -LiteralPath (Join-Path $OutDir 'index.html'))) { throw "Scorecard.Web export wrote no index.html." }
}

# What the pages say they cover: the configuration's "title", else the Octopus space's name, else its id.
function Get-SiteTitle([hashtable] $Config) {
    if ($Config['title']) { return [string] $Config['title'] }
    if ($env:OCTOPUS_API_KEY) {
        try { $name = [string] (Invoke-OctopusRequest $Config "/api/spaces/$($Config.space)")['Name']; if ($name) { return $name } }
        catch { Write-Warning "The space's name could not be read ($($_.Exception.Message)); the pages say $($Config.space)." }
    }
    $Config.space
}

# The exported site as one zip, its files by their paths relative to the site's folder.
function New-SiteArchive([string] $SiteDir, [string] $ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($SiteDir, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
}

# ---------------------------------------------------------------------------------------------------------------
# The published site (-PublishSite)
# ---------------------------------------------------------------------------------------------------------------

# The address of the published pages: the blob container's public index.html.
function Get-SiteUrl([hashtable] $Site) { "https://$($Site.account).blob.core.windows.net/$($Site.container)/index.html" }

# The Content-Type of a file of the site, by its extension: set on upload, as what az guesses depends on its Python.
function Get-SiteContentType([string] $Extension) {
    $types = @{
        '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'
        '.ico' = 'image/x-icon'; '.woff' = 'font/woff'; '.woff2' = 'font/woff2'; '.ttf' = 'font/ttf'; '.otf' = 'font/otf'
        '.txt' = 'text/plain; charset=utf-8'; '.map' = 'application/json; charset=utf-8'; '.xml' = 'application/xml'
        '.gif' = 'image/gif'; '.webp' = 'image/webp'; '.webmanifest' = 'application/manifest+json'
    }
    $type = $types[$Extension.ToLowerInvariant()]
    if ($type) { $type } else { 'application/octet-stream' }
}

# The upload order of a file of the site: what the pages load first (1), then the pages other than index.html (2),
# index.html last (3), so a page opened meanwhile finds every file it names.
function Get-SiteUploadOrder([string] $Blob) {
    if ($Blob -ceq 'index.html') { 3 } elseif ($Blob.EndsWith('.html', [StringComparison]::OrdinalIgnoreCase)) { 2 } else { 1 }
}

# The blobs the container held before the upload that this export does not have: deleted after it.
function Get-StaleBlobs($Before, $Names) {
    $keep = [Collections.Generic.HashSet[string]]::new([string[]] @($Names | Where-Object { $_ }), [StringComparer]::Ordinal)
    @($Before | Where-Object { $_ -and -not $keep.Contains([string] $_) })
}

# One az command: its lines on standard output. A failure (exit code, or an ERROR line, which upload-batch writes for
# a file it did not upload while it still ends with 0) throws with az's own words.
function Invoke-Az([string[]] $Arguments) {
    $PSNativeCommandUseErrorActionPreference = $false
    $errors = [IO.Path]::GetTempFileName()
    try {
        $out = @(az @Arguments --only-show-errors 2> $errors | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        $text = "$(Get-Content -LiteralPath $errors -Raw)"
        if ($code -ne 0 -or $text -cmatch '(?m)^ERROR') { throw "az $($Arguments[0..2] -join ' ') failed (exit $code): $(($text -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '' -replace '\s+', ' ').Trim())" }
        $out
    }
    finally { Remove-Item -LiteralPath $errors -Force -ErrorAction SilentlyContinue }
}

# Publish: the exported site into the blob container site.container of storage account site.account, as the signed-in
# az identity (Microsoft Entra ID: the account takes no shared key; in Octopus the step's Azure account). Every file is
# uploaded again (Cache-Control no-cache: the names stay from run to run), by Content-Type, in Get-SiteUploadOrder's
# order; then what the container held that this export does not have is deleted, and the container is checked to hold
# exactly the export, and index.html to be served as text/html to anyone. Returns the address of the pages.
function Publish-ScorecardSite([hashtable] $Site, [string] $SiteDir) {
    $login = @('--account-name', $Site.account, '--auth-mode', 'login')
    # '--num-results=*' as one word: PowerShell on Linux expands a lone * passed to a native command to the files of the
    # current directory.
    $list = @('storage', 'blob', 'list', '--container-name', $Site.container, '--num-results=*', '--query=[].name', '--output', 'tsv') + $login
    # A role assigned moments ago can take minutes to reach the data plane.
    $deadline = [datetime]::UtcNow.AddMinutes(10)
    while ($true) {
        try { $before = @(Invoke-Az $list | Where-Object { $_ }); break }
        catch {
            if ("$_" -notmatch 'AuthorizationPermissionMismatch|AuthorizationFailure|required permissions' -or [datetime]::UtcNow -gt $deadline) { throw }
            Write-Host "site: $($Site.account)/$($Site.container) cannot be listed yet (a role assigned moments ago?); again in 30 s"
            Start-Sleep -Seconds 30
        }
    }
    $names = [Collections.Generic.List[string]]::new()
    $batches = [ordered]@{}
    $stage = Join-Path ([IO.Path]::GetTempPath()) "scorecard-site-$([guid]::NewGuid().ToString('N'))"
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $SiteDir -Recurse -File -Force)) {
            $blob = [IO.Path]::GetRelativePath($SiteDir, $file.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
            $names.Add($blob)
            $order = Get-SiteUploadOrder $blob
            $type = Get-SiteContentType $file.Extension
            $key = "$order $type"
            if (-not $batches.Contains($key)) { $batches[$key] = @{ Order = $order; Type = $type; Folder = (Join-Path $stage "$($batches.Count)"); Files = 0 } }
            $batch = $batches[$key]
            $target = Join-Path $batch.Folder $blob
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target
            $batch.Files++
        }
        foreach ($batch in @($batches.Values | Sort-Object { $_.Order }, { $_.Type })) {
            Invoke-Az (@('storage', 'blob', 'upload-batch', '--destination', $Site.container, '--source', $batch.Folder, '--content-type', $batch.Type, '--content-cache-control', 'no-cache', '--overwrite', 'true', '--max-connections', '8', '--no-progress', '--output', 'none') + $login) | Out-Null
            Write-Host "site: uploaded $($batch.Files) file(s) as $($batch.Type)"
        }
    }
    finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    $stale = @(Get-StaleBlobs $before $names)
    foreach ($blob in $stale) { Invoke-Az (@('storage', 'blob', 'delete', '--container-name', $Site.container, '--name', $blob, '--output', 'none') + $login) | Out-Null }
    if ($stale.Count) { Write-Host "site: deleted $($stale.Count) file(s) this export no longer has" }
    $held = @(Invoke-Az $list | Where-Object { $_ })
    $missing = @(Get-StaleBlobs $names $held)
    $extra = @(Get-StaleBlobs $held $names)
    if ($missing.Count -or $extra.Count) { throw "$($Site.account)/$($Site.container) does not hold exactly the export: $($missing.Count) missing ($(@($missing | Select-Object -First 3) -join ', ')), $($extra.Count) not of it ($(@($extra | Select-Object -First 3) -join ', '))." }
    $url = Get-SiteUrl $Site
    $answer = Invoke-WebRequest -Uri $url -Method Head -SkipHttpErrorCheck -MaximumRetryCount 3 -RetryIntervalSec 10
    $type = [string] @($answer.Headers['Content-Type'])[0]
    if ([int] $answer.StatusCode -ne 200 -or -not $type.StartsWith('text/html', [StringComparison]::OrdinalIgnoreCase)) { throw "$url answers HTTP $([int] $answer.StatusCode) with Content-Type '$type' to an anonymous request." }
    Write-Host "site: $($names.Count) file(s) at $url"
    $url
}

# ---------------------------------------------------------------------------------------------------------------
# The published Pages site and its data layer (-PublishPages)
# ---------------------------------------------------------------------------------------------------------------

# The most bytes of JSON one data file holds before its list goes on in a next part: an AI tool fetches a page whole,
# and many stop reading near 100 KB.
$script:DataFileBudget = 90000
# Every path in the data files is from the site's root, the folder of llms.txt.
$script:PathsNote = 'Paths are relative to the site root (the folder of llms.txt).'
# The numbers of the page, in its order: the key in the data, the row of the page, what the page says the row is (the
# hints of Scorecard.Web's ScorecardColumns and WeeklyTable), cmis's name, and whether its weekly cells list their items.
$script:PageMetrics = @(
    [ordered]@{ key = 'workInProcess'; row = 'Work in process'; page = 'every item not yet delivered at the end of the week, including the backlog'; cmis = 'WorkInProcess'; lists = $true }
    [ordered]@{ key = 'itemsStarted'; row = 'Items started'; page = 'items created in the week'; cmis = 'ItemsStarted'; lists = $true }
    [ordered]@{ key = 'itemsDelivered'; row = 'Items delivered'; page = 'items that reached the delivered stage in the week'; cmis = 'ItemsDelivered'; lists = $true }
    [ordered]@{ key = 'meanTimeToDelivery'; row = 'Mean time to delivery (MTTD)'; page = 'mean time from creation to delivery of the items delivered in the week'; cmis = 'MeanTimeToDelivery'; lists = $false }
    [ordered]@{ key = 'throughput'; row = 'Throughput (stage moves)'; page = 'forward stage moves in the week. This counts moves, not items: an item that moved forward through three stages in the week counts three times'; cmis = 'Throughput'; lists = $false }
    [ordered]@{ key = 'rework'; row = 'Rework'; page = 'backward stage moves in the week (moves, not items)'; cmis = 'Rework'; lists = $false }
    [ordered]@{ key = 'netThroughput'; row = 'Net throughput'; page = 'forward minus backward stage moves in the week (moves, not items)'; cmis = 'NetThroughput'; lists = $false }
)

# What an item is and its GitHub address. The drill lists know the kind (cmis's source type); for an item no list names,
# its number says it (cmis's DeliveryProcessDefinition): a branch from 500,000, a direct commit from 900,000 (numbers
# cmis derives from the name or commit id, without an address), below that an issue or a pull request (GitHub's own
# numbers). GitHub answers the issue address of a pull request with the pull request.
function Get-ItemAddress([string] $Owner, [string] $Repo, [long] $Number, [string] $Kind) {
    if (-not $Kind) { $Kind = if ($Number -ge 900000) { 'direct commit' } elseif ($Number -ge 500000) { 'branch' } else { 'issue or pull request' } }
    $url = $null
    if ($Owner -and $Repo -and $Kind -cin 'issue', 'pull request', 'issue or pull request') {
        $url = "https://github.com/$Owner/$Repo/$(if ($Kind -ceq 'pull request') { 'pull' } else { 'issues' })/$Number"
    }
    @{ Kind = $Kind; Url = $url }
}

# The connection a drill item belongs to: its own (ConvertTo-DrillItem), else the measured project of its repository.
function Get-DrillConnection($Item, $Data) {
    if ($Item['connection']) { return [string] $Item['connection'] }
    $hit = @($Data.projects | Where-Object { $_.measured -and $_.owner -ceq $Item['owner'] -and $_.repo -ceq $Item['repo'] })
    if ($hit.Count) { [string] $hit[0].connectionId } else { $null }
}

# The time of a stage entry as cmis writes it (ISO 8601 with an offset).
function ConvertTo-Instant([string] $Text) { [DateTimeOffset]::Parse($Text, $script:Invariant) }

# Every item of the document (cmis connections document --include-titles) by connection, as the data layer lists it:
# its own number in its repository, kind, title, GitHub address, when it was created and first delivered, where it
# stands, and its stages in the order it entered them. The kinds come from the drill lists of $Data.
function Get-PagesItems($Document, $Data) {
    $entries = @{}
    foreach ($p in @($Data.projects | Where-Object { $_.measured })) { $entries[$p.connectionId] = $p }
    $kinds = @{}
    foreach ($scope in $Data.scopes) { foreach ($list in $scope.drills.Values) { foreach ($i in @($list)) { $c = Get-DrillConnection $i $Data; if ($c) { $kinds["$c|$($i['number'])"] = $i['kind'] } } } }
    $delivered = @{}
    foreach ($c in @($Document['connections'])) { $delivered[[string] $c['id']] = @($c['deliveredStages']) }
    $byConnection = [ordered]@{}
    foreach ($e in $entries.Values | Sort-Object { $_.connectionId }) { $byConnection[$e.connectionId] = [Collections.Generic.List[object]]::new() }
    foreach ($item in @($Document['items'])) {
        $id = [string] $item['connection']
        $e = $entries[$id]
        if (-not $e) { continue }
        $number = [long] $item['number'] - [long] $e.itemNumberBase
        $address = Get-ItemAddress $e.owner $e.repo $number $kinds["$id|$number"]
        $first = $null; $firstText = $null
        foreach ($s in @($item['stages'])) {
            if ([string] $s['stage'] -cin @($delivered[$id])) {
                $at = ConvertTo-Instant $s['enteredUtc']
                if ($null -eq $first -or $at -lt $first) { $first = $at; $firstText = [string] $s['enteredUtc'] }
            }
        }
        $byConnection[$id].Add([ordered]@{
                number = $number; kind = $address.Kind; title = $item['title']; url = $address.Url
                createdUtc = [string] $item['createdUtc']; deliveredUtc = $firstText; currentStage = $item['currentStage']
                stages = @(foreach ($s in @($item['stages'])) { [ordered]@{ stage = $s['stage']; enteredUtc = [string] $s['enteredUtc'] } })
                cmisNumber = [long] $item['number']
            })
    }
    $byConnection
}

# Items in parts of at most $Budget bytes of JSON each, in their order; one part (perhaps empty) when they fit.
function Split-ByJsonSize($Items, [int] $Budget) {
    $parts = [Collections.Generic.List[object]]::new()
    $current = [Collections.Generic.List[object]]::new()
    $size = 0
    foreach ($i in @($Items)) {
        $n = [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $i -Depth 20 -Compress)) + 1
        if ($current.Count -and $size + $n -gt $Budget) { $parts.Add($current.ToArray()); $current = [Collections.Generic.List[object]]::new(); $size = 0 }
        $current.Add($i); $size += $n
    }
    $parts.Add($current.ToArray())
    Write-Output -NoEnumerate $parts.ToArray()
}

# One data file, its list in parts when it is large: <Path>.json holds the first part, <Path>.2.json and on the rest;
# each says which part it is and names them all. $Head: what every part says before its list. Returns the files'
# paths from the root.
function Write-DataFile([string] $Root, [string] $Path, $Head, $Items, [string] $ItemsKey = 'items') {
    $parts = Split-ByJsonSize $Items $script:DataFileBudget
    $names = @(for ($k = 1; $k -le $parts.Count; $k++) { if ($k -eq 1) { "$Path.json" } else { "$Path.$k.json" } })
    for ($k = 0; $k -lt $parts.Count; $k++) {
        $doc = [ordered]@{}
        foreach ($key in $Head.Keys) { $doc[$key] = $Head[$key] }
        if ($names.Count -gt 1) { $doc['part'] = $k + 1; $doc['parts'] = $names.Count; $doc['partFiles'] = $names }
        $doc[$ItemsKey] = @($parts[$k])
        $file = Join-Path $Root $names[$k]
        New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
        ConvertTo-Json -InputObject $doc -Depth 20 -Compress | Set-Content -LiteralPath $file -NoNewline
    }
    $names
}

# One object as a data file of the root, compact JSON.
function Write-DataObject([string] $Root, [string] $Path, $Object) {
    $file = Join-Path $Root $Path
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    ConvertTo-Json -InputObject $Object -Depth 30 -Compress | Set-Content -LiteralPath $file -NoNewline
}

# The file name of a repository's items: the repository's name, with the connection's id when two connections share it.
function Get-ItemFileNames($Projects) {
    $measured = @($Projects | Where-Object { $_.measured })
    $names = @{}
    foreach ($p in $measured) {
        $shared = @($measured | Where-Object { $_.repo -ceq $p.repo }).Count -gt 1
        $names[$p.connectionId] = "data/items/$(if ($shared) { "$($p.repo)--$($p.connectionId)" } else { $p.repo })"
    }
    $names
}

# The definition of each number of the page: the page's own words and cmis's (unit, how periods add up).
function Get-MetricDefinitions($Data) {
    $cmis = @{}
    foreach ($m in @($Data['semantics'] ? $Data.semantics.metrics : @())) { $cmis[[string] $m['name']] = $m }
    @(foreach ($m in $script:PageMetrics) {
            $c = $cmis[$m.cmis]
            [ordered]@{
                key = $m.key; row = $m.row; page = $m.page; cmisName = $m.cmis
                cmis = if ($c) { $c['definition'] } else { $null }; unit = if ($c) { $c['unit'] } else { $null }; aggregation = if ($c) { $c['aggregation'] } else { $null }
                lists = $m.lists
            }
        })
}

# The numbers of the weeks recomputed from the items' stage histories, by the rules llms.txt gives, compared with the
# numbers of the run: the cells that differ ("<scope> <week> <metric>: <run> vs <recomputed>"); none when the rules hold.
function Test-RecomputedNumbers($Data, $Items, $Document) {
    $delivered = @{}
    foreach ($c in @($Document['connections'])) { $delivered[[string] $c['id']] = @($c['deliveredStages']) }
    $differences = [Collections.Generic.List[string]]::new()
    foreach ($scope in $Data.scopes) {
        $ids = if ($scope.id -ceq $script:SpaceScopeId) { @($Items.Keys) } else { @($scope.id) }
        $list = @(foreach ($id in $ids) { if ($Items.Contains($id)) { $Items[$id] } })
        foreach ($w in $Data.weeks) {
            $n = $scope.periods[$w.start]
            if ($null -eq $n) { continue }
            $from = [DateTimeOffset]::new([datetime]::ParseExact($w.start, 'yyyy-MM-dd', $script:Invariant), [TimeSpan]::Zero)
            $to = $from.AddDays(7)
            $started = 0; $deliveredCount = 0; $wip = 0; $sum = 0.0
            foreach ($i in $list) {
                $created = ConvertTo-Instant $i.createdUtc
                $done = if ($i.deliveredUtc) { ConvertTo-Instant $i.deliveredUtc } else { $null }
                if ($created -ge $from -and $created -lt $to) { $started++ }
                if ($done -and $done -ge $from -and $done -lt $to) { $deliveredCount++; $sum += ($done - $created).TotalDays / 7 }
                $last = $null
                foreach ($s in $i.stages) { if ((ConvertTo-Instant $s.enteredUtc) -lt $to) { $last = $s.stage } }
                if ($created -lt $to -and -not ($done -and $done -lt $to) -and $last -cne 'Closed') { $wip++ }
            }
            $mean = if ($deliveredCount) { $sum / $deliveredCount } else { $null }
            foreach ($pair in @(@('itemsStarted', $started), @('itemsDelivered', $deliveredCount), @('workInProcess', $wip))) {
                if ([long] ($n[$pair[0]] ?? 0) -ne $pair[1]) { $differences.Add("$($scope.id) $($w.start) $($pair[0]): $($n[$pair[0]]) vs $($pair[1])") }
            }
            $run = $n['meanTimeToDelivery']
            if (($null -eq $run) -ne ($null -eq $mean) -or ($null -ne $run -and [math]::Abs([double] $run - $mean) -gt 1e-6)) { $differences.Add("$($scope.id) $($w.start) meanTimeToDelivery: $run vs $mean") }
        }
    }
    $differences
}

# What cmis says of its connections and its store: the connections, what the store holds, the last harvest runs (one
# per connection: each is harvested on its own) and the work streams. Read-only commands; one that fails is named.
function Get-CmisStatus([string] $Cmis, [hashtable] $Paths, [int] $Runs) {
    $status = [ordered]@{}
    $commands = [ordered]@{
        connections = @('connections', 'list'); inventory = @('connections', 'inventory')
        lastRuns = @('connections', 'last-run', '--take', [string] [math]::Max(1, $Runs)); workStreams = @('config', 'workstream', 'list')
    }
    foreach ($key in $commands.Keys) {
        try {
            $d = Invoke-Cmis $Cmis $commands[$key] $Paths.Workspace $Paths.Store
            $field = @{ connections = 'connections'; inventory = 'connections'; lastRuns = 'runs'; workStreams = 'workStreams' }[$key]
            $status[$key] = @($d[$field] | Where-Object { $null -ne $_ })
        }
        catch { $status[$key] = [ordered]@{ error = "cmis $($commands[$key] -join ' ') failed: $($_.Exception.Message)" } }
    }
    $status
}

# The data layer in <Root>/data: summary.json (every number per scope and week, with the lists behind them), drill/
# (the items behind each number), items/ (every item's title, address and stage history), days.json (per local day),
# cmis.json (cmis's status), full/ (the run's own two files). Returns what llms.txt names.
function Write-PagesDataLayer($Data, $Document, $CmisStatus, $Web, [hashtable] $Config, [string] $Root, [string] $Title) {
    $items = Get-PagesItems $Document $Data
    $itemFiles = Get-ItemFileNames $Data.projects
    $repoOf = @{}; foreach ($p in @($Data.projects | Where-Object { $_.measured })) { $repoOf[$p.connectionId] = "$($p.owner)/$($p.repo)" }
    # An item of a list by its connection and number.
    $byKey = @{}
    foreach ($id in $items.Keys) { foreach ($i in $items[$id]) { $byKey["$id|$($i.number)"] = $i } }
    $definitions = Get-MetricDefinitions $Data

    # The items of each repository.
    $written = [ordered]@{}
    foreach ($id in $items.Keys) {
        $p = @($Data.projects | Where-Object { $_.connectionId -ceq $id })[0]
        $connection = @($Document['connections'] | Where-Object { $_['id'] -ceq $id }) | Select-Object -First 1
        $head = [ordered]@{
            paths = $script:PathsNote; project = $p.project; connectionId = $id; repository = $repoOf[$id]; itemNumberBase = $p.itemNumberBase
            stages = @(if ($connection) { $connection['stages'] }); deliveredStages = @(if ($connection) { $connection['deliveredStages'] }); window = [ordered]@{ since = $Data.since; until = $Data.until }
            count = $items[$id].Count
            note = 'Every item with activity in the window. number: an issue or pull request number of the repository; a branch (from 500000) or a direct commit (from 900000) has a number cmis derives from its name or commit id and no GitHub address. cmisNumber: the number plus the connection''s itemNumberBase, as cmis knows the item across repositories. stages: in the order entered, times in UTC. deliveredUtc: its first entry into a delivered stage. Closed: closed without delivery.'
        }
        $written[$id] = @(Write-DataFile $Root $itemFiles[$id] $head $items[$id])
    }

    # The items behind each number, and the summary of every number.
    $lists = [ordered]@{}
    $scopes = foreach ($scope in $Data.scopes) {
        $isSpace = $scope.id -ceq $script:SpaceScopeId
        $lists[$scope.id] = [ordered]@{}
        $weeks = foreach ($w in $Data.weeks) {
            $n = $scope.periods[$w.start]
            $cell = [ordered]@{ week = $w.start; label = $w.label; partial = $w.partial }
            foreach ($m in $script:PageMetrics) { if ($m.key -cne 'meanTimeToDelivery') { $cell[$m.key] = if ($null -eq $n) { $null } else { $n[$m.key] } } }
            $mttd = if ($null -eq $n) { $null } else { $n['meanTimeToDelivery'] }
            $cell['meanTimeToDelivery'] = $mttd
            $cell['meanTimeToDeliveryHours'] = if ($null -eq $mttd) { $null } else { [math]::Round([double] $mttd * 168, 2) }
            $cell['meanTimeToDeliveryText'] = Format-Duration $mttd
            $cellLists = [ordered]@{}
            foreach ($m in $script:PageMetrics | Where-Object { $_.lists }) {
                $drill = $scope.drills["$($m.key)|$($w.start)"]
                if ($null -eq $drill) { continue }
                $listed = @(foreach ($d in @($drill)) {
                        $known = $byKey["$(Get-DrillConnection $d $Data)|$($d['number'])"]
                        [ordered]@{
                            repository = if ($d['owner']) { "$($d['owner'])/$($d['repo'])" } else { $null }; number = $d['number']; kind = $d['kind']
                            title = if ($known) { $known.title } else { $null }; url = if ($known) { $known.url } else { (Get-ItemAddress $d['owner'] $d['repo'] $d['number'] $d['kind']).Url }
                            from = $d['from']; to = $d['to']; at = $d['at']
                        }
                    })
                $repositories = [ordered]@{}
                foreach ($d in @($drill)) { $c = Get-DrillConnection $d $Data; if ($c -and $itemFiles[$c]) { $repositories["$($d['owner'])/$($d['repo'])"] = "$($itemFiles[$c]).json" } }
                $head = [ordered]@{
                    paths = $script:PathsNote; scope = $scope.id; scopeTitle = $(if ($isSpace) { "All projects of $Title" } else { $scope.title }); repository = $(if ($isSpace) { $null } else { $repoOf[$scope.id] })
                    week = $w.start; weekLabel = $w.label; partial = $w.partial; metric = $m.key; row = $m.row; definition = $m.page
                    count = $(if ($null -eq $n) { 0 } else { $n[$m.key] }); listed = $listed.Count
                    move = 'from, to, at: the stage move that put the item in this list and when (UTC)'
                    itemFiles = $repositories
                }
                $names = @(Write-DataFile $Root "data/drill/$($scope.id)/$($w.start)/$($m.key)" $head $listed)
                $cellLists[$m.key] = $names[0]
                $lists[$scope.id]["$($w.start)|$($m.key)"] = $names
            }
            $cell['lists'] = $cellLists
            $cell
        }
        [ordered]@{
            id = $scope.id; title = $(if ($isSpace) { "All projects of $Title" } else { $scope.title })
            repository = $(if ($isSpace) { $null } else { $repoOf[$scope.id] }); items = $(if ($isSpace) { $null } else { "$($itemFiles[$scope.id]).json" })
            weeks = @($weeks)
        }
    }
    $differences = @(Test-RecomputedNumbers $Data $items $Document)
    $summary = [ordered]@{
        paths = $script:PathsNote; title = $Title; space = $Data.space; octopusServer = $Data.octopusServer; generatedUtc = $Data.generatedUtc
        window = [ordered]@{ since = $Data.since; until = $Data.until; timeZone = $Data.timeZone }
        weeksAre = 'ISO weeks, Monday 00:00 UTC to the next Monday. partial: the window does not cover the whole week (the page marks it *). null: the scope has no data that week (the page shows a dash).'
        meanTimeToDeliveryIs = 'meanTimeToDelivery in weeks as cmis gives it; meanTimeToDeliveryHours the same in hours; meanTimeToDeliveryText as the page writes it (minutes under 90 minutes, hours with one decimal under 48 hours, else days).'
        cmis = $Data.cmis; scorecardWeb = $Web
        metrics = @($definitions)
        projects = @(foreach ($p in $Data.projects) {
                [ordered]@{
                    project = $p.project; connectionId = $p.connectionId; repository = $(if ($p.measured) { "$($p.owner)/$($p.repo)" } else { $null }); measured = $p.measured; reason = $p.reason
                    pairedBy = $p.source; environments = $p.environments; items = $(if ($p.measured) { "$($itemFiles[$p.connectionId]).json" } else { $null })
                }
            })
        scopes = @($scopes)
        recomputed = $(if ($differences.Count) { "The rules of llms.txt give other numbers in $($differences.Count) cell(s): $(@($differences | Select-Object -First 5) -join '; ')" } else { 'The rules of llms.txt give every started, delivered, work in process and MTTD number of these weeks from the item files.' })
        warnings = @($Data.warnings)
        files = [ordered]@{ llms = 'llms.txt'; days = 'data/days.json'; cmis = 'data/cmis.json'; fullScorecardData = 'data/full/scorecard-data.json'; fullDocument = 'data/full/document.json' }
    }
    Write-DataObject $Root 'data/summary.json' $summary

    $daysHead = [ordered]@{
        paths = $script:PathsNote; timeZone = $Document['timeZone']; from = $Document['from']; to = $Document['to']
        note = "Per local day of the time zone, all projects together, as cmis's connections document computes them (its own rules for a day). The weekly numbers of the page are in data/summary.json."
    }
    $days = @(Write-DataFile $Root 'data/days' $daysHead @($Document['days']) 'days')
    Write-DataObject $Root 'data/cmis.json' ([ordered]@{ paths = $script:PathsNote; version = $Data.cmis['version']; commit = $Data.cmis['commit']; repo = $Data.cmis['repo']; generatedUtc = $Data.generatedUtc } + $CmisStatus)
    [ordered]@{ Summary = $summary; Lists = $lists; ItemFiles = $written; Days = $days; Differences = $differences; Stages = @($Document['connections']) }
}

# Markdown as one line of text: nothing in it that Markdown would read as a link or emphasis.
function ConvertTo-LlmsText([string] $Text) { ($Text -replace '\s+', ' ' -replace '([\[\]\*_`|])', '\$1').Trim() }

# llms.txt (https://llmstxt.org): what the scorecard is, what each number means, the projects, and a link to every
# data file, with the rules that recompute a number for another window from the items' stage histories.
function Get-LlmsText($Layer, [hashtable] $Config) {
    $s = $Layer.Summary
    $b = [Text.StringBuilder]::new()
    function Line([string] $Text = '') { [void] $b.Append($Text).Append("`n") }
    $measured = @($s.projects | Where-Object { $_.measured })
    Line "# Delivery scorecard of $(ConvertTo-LlmsText $s.title)"
    Line
    Line "> The weekly delivery scorecard of Octopus Deploy space $($s.space) ($(ConvertTo-LlmsText $s.title)): $($measured.Count) project(s), each paired with its GitHub repository and measured from its issues, pull requests, commits and Octopus deployments with cmis (Clear Measure Intelligence Scorecard) $($s.cmis.version), from $($s.window.since) to $($s.window.until) ($($s.window.timeZone)). Generated $($s.generatedUtc). The pages ([index.html](index.html)) are Scorecard.Web's$(if ($s.scorecardWeb) { " $($s.scorecardWeb.version) (commit $($s.scorecardWeb.commit) of $($s.scorecardWeb.repository))" }); this file and data/ hold the same numbers, and the items behind them, as JSON."
    Line
    Line "All paths are relative to this file. The window is $($s.window.since) to $($s.window.until), both days included (today in $($s.window.timeZone) the last); the data is what GitHub and Octopus held when the run harvested, shortly before $($s.generatedUtc). Weeks are ISO weeks, Monday 00:00 UTC to the next Monday, named by their Monday (yyyy-MM-dd); a week the window does not cover whole is partial (the page marks it *). The weeks before the first week in which anything happened are left out (the window may begin before the first repository did); summary.json lists the weeks shown. Every time is UTC unless a file says otherwise. Updated every night: this branch holds one commit, the last run."
    Line
    Line '## Numbers'
    Line
    foreach ($m in $s.metrics) {
        Line "- **$($m.row)** (``$($m.key)``): $(ConvertTo-LlmsText $m.page).$(if ($m.cmis) { " cmis: $(ConvertTo-LlmsText $m.cmis) Unit: $($m.unit); several periods: $($m.aggregation)." })$(if ($m.lists) { ' Each weekly number lists its items.' })"
    }
    Line
    Line 'The page shows Work in process, Items started, Items delivered and MTTD; Throughput, Rework and Net throughput are in its folded "Flow detail" panel. MTTD: summary.json has it in weeks (meanTimeToDelivery, as cmis gives a weekly period), in hours rounded to two decimals, and as the page writes it. Every kind of item counts in every number: issues, pull requests that belong to no issue, branches and direct commits.'
    Line
    Line '## Stages'
    Line
    $sequences = @($Layer.Stages | ForEach-Object { "$(@($_['stages']) -join ' > ') (delivered: $(@($_['deliveredStages']) -join ', '))" } | Select-Object -Unique)
    foreach ($q in $sequences) { Line "- $(ConvertTo-LlmsText $q)" }
    Line '- Closed: closed without being delivered (an issue closed with no merged pull request, or a pull request that belongs to no issue closed without merging). cmis keeps it off the board: neither in process nor delivered, a move into or out of it neither throughput nor rework. The item files list it among an item''s stages, with when it was entered, and as its currentStage.'
    Line
    Line "A work item is a GitHub issue of the repository, or a pull request that belongs to no issue; also a branch with no pull request that names no issue, and a commit pushed straight to the default branch. Each stage is entered by a signal from GitHub (Created: the issue created; Development: the first commit of its pull request; In Review: the pull request opened; Merged: the pull request merged) or from Octopus Deploy (each later stage: the first successful deployment to that environment, the last one Delivered). So says cmis's delivery process (GitHubDelivery)."
    Line
    Line '## Projects'
    Line
    Line 'An Octopus project and its repository may have different names: the item files are named by repository, data/drill by project (its connection id); the list below pairs them.'
    Line
    foreach ($p in $s.projects) {
        if ($p.measured) { Line "- $(ConvertTo-LlmsText $p.project): repository [$($p.repository)](https://github.com/$($p.repository)), items [$($p.items)]($($p.items))$(if (@($Layer.ItemFiles[$p.connectionId]).Count -gt 1) { " (continued in $(@($Layer.ItemFiles[$p.connectionId] | Select-Object -Skip 1 | ForEach-Object { "[$_]($_)" }) -join ', '))" })" }
        else { Line "- $(ConvertTo-LlmsText $p.project): not measured, $(ConvertTo-LlmsText $p.reason)" }
    }
    Line
    Line '## Data'
    Line
    Line '- [data/summary.json](data/summary.json): every number per scope (all projects together, and each project) and week, the definitions, the projects, and the path of the list behind each number'
    Line "- [data/days.json](data/days.json): the numbers per local day of $($s.window.timeZone) (not UTC days), all projects together, as cmis computes a day (MTTD in days)$(if (@($Layer.Days).Count -gt 1) { "; continued in $(@($Layer.Days | Select-Object -Skip 1 | ForEach-Object { "[$_]($_)" }) -join ', ')" })"
    Line '- [data/cmis.json](data/cmis.json): cmis status: its connections, what its store holds, the last harvest of each connection, the work streams'
    Line '- [data/full/scorecard-data.json](data/full/scorecard-data.json): the run''s whole model in one file (about 1 MB, a download)'
    Line '- [data/full/document.json](data/full/document.json): cmis connections document of the run (every item with its title and stage history, every day) in one file (a download)'
    Line
    Line '## Item lists behind the numbers'
    Line
    Line 'Each list holds the items behind one number: repository, number, kind, title, GitHub address, and the stage move that put it there (from, to, at). A list longer than about 90 KB of JSON goes on in parts named in its partFiles. A number that is 0 has no list, and a week a scope has no data for has none either: data/summary.json tells the two apart (0 or null).'
    foreach ($scope in $s.scopes) {
        Line
        Line "### $(ConvertTo-LlmsText $scope.title)$(if ($scope.repository) { " ($($scope.repository))" })"
        Line
        foreach ($w in $scope.weeks) {
            $links = @(foreach ($key in $w.lists.Keys) {
                    $names = @($Layer.Lists[$scope.id]["$($w.week)|$key"])
                    "[$key]($($names[0])) $($w[$key])$(if ($names.Count -gt 1) { " (parts $(@(for ($k = 1; $k -lt $names.Count; $k++) { "[$($k + 1)]($($names[$k]))" }) -join ', '))" })"
                })
            if ($links.Count) { Line "- Week of $($w.week)$(if ($w.partial) { ' (partial)' }): $($links -join ', ')" }
        }
    }
    Line
    Line '## Recomputing a number for another window'
    Line
    Line 'Each item file lists every item of one repository with activity in the window: createdUtc, deliveredUtc (its first entry into a delivered stage, null when not delivered), currentStage, and its stages with the time each was entered, in the order entered. For a window from F (inclusive) to T (exclusive), UTC, over the items of one project or of all (the space):'
    Line
    Line '- Items started: the items with F <= createdUtc < T.'
    Line '- Items delivered: the items with F <= deliveredUtc < T.'
    Line '- Mean time to delivery: the mean of (deliveredUtc - createdUtc) over the items delivered in the window.'
    Line '- Work in process at an instant T: the items with createdUtc < T, not delivered before T, whose last stage entered before T is not Closed (an item reopened later counts again). A week''s number is the work in process at its end, the next Monday 00:00 UTC.'
    Line '- Throughput, Rework, Net throughput: stage moves, which the item files do not hold completely; take them per week from data/summary.json.'
    Line
    Line "$($s.recomputed) Over several weeks cmis's own score adds the weekly started and delivered numbers, takes the work in process of the last week, and averages the weekly MTTDs without weights; the MTTD rule above weighs every item the same. An item's local day in $($s.window.timeZone): convert its UTC times."
    Line
    Line '## Pages'
    Line
    Line '- [index.html](index.html): the scorecard, all repositories together; [split.html](split.html): by repository; [people.html](people.html) and [split-people.html](split-people.html): the "People and factory" setting (automation items left out). Their drill/ pages list the items behind every cell, also of rows data/ does not hold (time per stage, deployments, waste, closed without delivery).'
    Line
    Line '## Not published'
    Line
    Line "- The raw harvest (cmis's store/raw): the GitHub and Octopus answers as harvested, which hold more than the scorecard shows: whole commit messages, the names of commit authors and committers, every branch, and Octopus deployment records (who deployed, form values, error messages, release notes). (The title of a direct commit item here is the first line of its message, and of a branch item its name.)"
    Line "- normalized.db: cmis's LiteDB file of the same items and stage moves, a binary a web fetch cannot read; data/items holds what it adds to the numbers (titles, stages)."
    Line "- Both stay in the store package $($Config.prefix)-scorecard-store of the space's built-in Octopus feed."
    $b.ToString()
}

# index.html with a link to llms.txt: one in its head for tools, one in its footer, small, for people.
function Add-LlmsLink([string] $Html) {
    $Html = [regex]::new('</head>').Replace($Html, "    <link rel=`"alternate`" type=`"text/markdown`" href=`"llms.txt`" title=`"Data for AI tools`" />`n</head>", 1)
    $link = '<span><a href="llms.txt" title="What the scorecard is, every number and the items behind it as JSON: for AI tools">Data (llms.txt)</a></span>'
    if ($Html.Contains('</footer>')) { [regex]::new('</footer>').Replace($Html, "    $link`n        </footer>", 1) }
    else { [regex]::new('</body>').Replace($Html, "$link`n</body>", 1) }
}

# The Pages site in <OutDir>: the exported site, its index.html with a link to llms.txt, .nojekyll (GitHub Pages serves
# the files as they are), the data layer and llms.txt. Returns the data layer's model.
function New-PagesSite($Data, [hashtable] $Paths, [string] $Cmis, [hashtable] $Config, [string] $SiteDir, [string] $OutDir, [string] $Title) {
    if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
    Copy-Item -LiteralPath $SiteDir -Destination $OutDir -Recurse
    $index = Join-Path $OutDir 'index.html'
    Set-Content -LiteralPath $index -Value (Add-LlmsLink (Get-Content -LiteralPath $index -Raw)) -NoNewline
    New-Item -ItemType File -Path (Join-Path $OutDir '.nojekyll') -Force | Out-Null
    $document = Get-Content -LiteralPath $Paths.Document -Raw | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100
    $runs = @($Data.projects | Where-Object { $_.measured }).Count
    $status = Get-CmisStatus $Cmis $Paths $runs
    $marker = Join-Path $Paths.Web 'space-scorecard-build.json'
    $web = if (Test-Path -LiteralPath $marker) { Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -AsHashtable } else { $null }
    $layer = Write-PagesDataLayer $Data $document $status $web $Config $OutDir $Title
    New-Item -ItemType Directory -Path (Join-Path $OutDir 'data/full') -Force | Out-Null
    Copy-Item -LiteralPath $Paths.Document -Destination (Join-Path $OutDir 'data/full/document.json')
    Copy-Item -LiteralPath $Paths.Data -Destination (Join-Path $OutDir 'data/full/scorecard-data.json')
    Set-Content -LiteralPath (Join-Path $OutDir 'llms.txt') -Value (Get-LlmsText $layer $Config) -NoNewline
    foreach ($d in $layer.Differences) { Write-Warning "pages: recomputed from the items, $d" }
    $large = @(Get-ChildItem -LiteralPath (Join-Path $OutDir 'data') -Recurse -File | Where-Object { $_.Length -gt 100000 -and [IO.Path]::GetRelativePath($OutDir, $_.FullName).Replace('\', '/') -notlike 'data/full/*' })
    foreach ($f in $large) { Write-Warning "pages: $([IO.Path]::GetRelativePath($OutDir, $f.FullName)) is $($f.Length) bytes, more than an AI tool may read" }
    $layer
}

# One git command (git on the PATH): its lines on standard output; a failure throws with git's own words.
function Invoke-Git([string[]] $Arguments) {
    $PSNativeCommandUseErrorActionPreference = $false
    $errors = [IO.Path]::GetTempFileName()
    try {
        $out = @(git @Arguments 2> $errors | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            # The command's name: the first argument after git's own options (each of which takes a value).
            $i = 0; while ($i -lt $Arguments.Count -and $Arguments[$i] -cin '-c', '--git-dir', '--work-tree') { $i += 2 }
            throw "git $(if ($i -lt $Arguments.Count) { $Arguments[$i] }) failed (exit $LASTEXITCODE): $((("$(Get-Content -LiteralPath $errors -Raw)") -replace '\s+', ' ').Trim())"
        }
        $out
    }
    finally { Remove-Item -LiteralPath $errors -Force -ErrorAction SilentlyContinue }
}

# GitHub builds the pages of a pushed branch on its own. Waits until its latest Pages build is of this commit and done:
# "built" is success, "errored" a failure; still not done after $Minutes, a warning (the push is what this run owns).
function Wait-PagesBuild([hashtable] $Pages, [string] $Commit, [int] $Minutes = 10) {
    $deadline = [datetime]::UtcNow.AddMinutes($Minutes)
    while ($true) {
        $build = $null
        try { $build = Invoke-GitHubGet "/repos/$($Pages.repo)/pages/builds/latest" | ConvertFrom-Json -AsHashtable } catch { $build = $null }
        if ($build -and $build['commit'] -ceq $Commit) {
            if ($build['status'] -ceq 'built') { Write-Host "pages: GitHub built $Commit"; return 'built' }
            if ($build['status'] -ceq 'errored') { throw "GitHub's Pages build of $Commit failed: $(if ($build['error']) { $build['error']['message'] })" }
        }
        if ([datetime]::UtcNow -gt $deadline) { Write-Warning "pages: GitHub had not built $Commit after $Minutes minutes; it may still"; return 'pending' }
        Start-Sleep -Seconds 15
    }
}

# Publish to GitHub Pages: <Directory> as the only commit of branch site.pages.branch of site.pages.repo, force-pushed
# (the branch keeps no history: the site of one run, some 70 MB, would pile up every night). git signs in with the
# GitHub token through GIT_ASKPASS, a script that prints it from this process's environment: the token is in no command
# line, remote address, file or log. Then the branch is checked to be that commit and GitHub's build of it awaited.
# Returns the address of the pages.
function Publish-ScorecardPages([hashtable] $Pages, [string] $Directory, [string] $Message) {
    $work = Join-Path ([IO.Path]::GetTempPath()) "scorecard-pages-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    $askPass = Join-Path $work 'askpass.sh'
    Set-Content -LiteralPath $askPass -Value "#!/bin/sh`ncase `"`$1`" in Username*) echo x-access-token ;; *) printf '%s\n' `"`$SCORECARD_PAGES_TOKEN`" ;; esac`n" -NoNewline
    if (-not $IsWindows) { chmod 700 $askPass }
    $remote = "https://github.com/$($Pages.repo).git"
    $names = 'SCORECARD_PAGES_TOKEN', 'GIT_ASKPASS', 'GIT_TERMINAL_PROMPT'
    $saved = @{}; foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    try {
        $env:SCORECARD_PAGES_TOKEN = Get-GitHubToken; $env:GIT_ASKPASS = $askPass; $env:GIT_TERMINAL_PROMPT = '0'
        # No credential helper of the machine's, no line-ending conversion: the files go as the export wrote them.
        $git = @('-c', 'credential.helper=', '-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false', '--git-dir', (Join-Path $work 'git'), '--work-tree', $Directory)
        Invoke-Git ($git + @('init', '--quiet', "--initial-branch=$($Pages.branch)")) | Out-Null
        Invoke-Git ($git + @('add', '--all')) | Out-Null
        Invoke-Git ($git + @('-c', 'user.name=space-scorecard', '-c', 'user.email=space-scorecard@users.noreply.github.com', 'commit', '--quiet', '--no-verify', '--message', $Message)) | Out-Null
        $commit = @(Invoke-Git ($git + @('rev-parse', 'HEAD')))[0]
        $files = @(Invoke-Git ($git + @('ls-files'))).Count
        for ($attempt = 1; ; $attempt++) {
            try { Invoke-Git ($git + @('push', '--force', '--quiet', $remote, "HEAD:refs/heads/$($Pages.branch)")) | Out-Null; break }
            catch {
                if ($attempt -ge 3) { throw }
                Write-Host "pages: push failed (try $attempt of 3), again in 30 s: $($_.Exception.Message)"
                Start-Sleep -Seconds 30
            }
        }
        $held = "$(@(Invoke-Git ($git + @('ls-remote', $remote, "refs/heads/$($Pages.branch)")))[0])" -split '\s+' | Select-Object -First 1
        if ($held -cne $commit) { throw "Branch $($Pages.branch) of $($Pages.repo) is $held after the push, not $commit." }
        Write-Host "pages: $files file(s) as commit $commit, force-pushed to $($Pages.branch) of $($Pages.repo)"
    }
    finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    [void] (Wait-PagesBuild $Pages $commit)
    $Pages.url
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

# The line the task log highlights: the space's numbers of the last full week, what is measured, the store version,
# and where the pages are published (or why they are not).
function Get-HighlightLine($Data, [string] $StoreVersion, [string] $SiteNote) {
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
    if ($SiteNote) { $line += "; $SiteNote" }
    $line
}

# The artifacts of the Octopus task: the summary and the document, and the pages: the exported site as
# scorecard-site.zip and its index.html alone, or, when there is no export, the script's own scorecard.html.
function Publish-OctopusArtifacts([string] $Directory, [string] $SiteDir) {
    $files = [ordered]@{ 'summary.md' = Join-Path $Directory 'summary.md'; 'document.json' = Join-Path $Directory 'document.json' }
    if ($SiteDir) { $files['scorecard-site.zip'] = Join-Path $Directory 'scorecard-site.zip'; $files['index.html'] = Join-Path $SiteDir 'index.html' }
    else { $files['scorecard.html'] = Join-Path $Directory 'scorecard.html' }
    foreach ($name in $files.Keys) {
        if (Test-Path -LiteralPath $files[$name]) { New-OctopusArtifact -Path $files[$name] -Name $name }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------------------------------

if ($LoadOnly) { return }
if (-not $Config -or -not $WorkDir) { throw 'Both -Config and -WorkDir are required.' }
if ($StoreFeed -and $SkipHarvest) { throw '-StoreFeed and -SkipHarvest exclude each other: -SkipHarvest harvests nothing.' }

$started = [Diagnostics.Stopwatch]::StartNew()
$cfg = Read-SpaceConfig $Config
if ($PublishSite -and -not ($cfg['site'] -and $cfg.site['account'] -and $cfg['scorecardVersion'])) { throw "-PublishSite needs 'site' (account, container) and 'scorecardVersion' in $Config." }
if ($PublishPages -and -not ($cfg['site'] -and $cfg.site['pages'] -and $cfg['scorecardVersion'])) { throw "-PublishPages needs 'site.pages' and 'scorecardVersion' in $Config." }
# cmis writes its store under the culture of its process, and Scorecard.Web reads it culture-invariant: a store written
# under another culture it rebuilds from the raw files on every export. So cmis runs culture-invariant too (the
# processes this script starts inherit the variable).
$env:DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = '1'
# The site's storage token now, while the sign-in Octopus made at the start of the step is fresh: az keeps it (about an
# hour) for the upload after harvest, build and export. A failure here is the run's failure at its end, as a failed
# upload is: the store is still pushed.
$publishFailure = $null
if ($PublishSite) {
    try { Invoke-Az @('account', 'get-access-token', '--resource', 'https://storage.azure.com/', '--output', 'none') | Out-Null; Write-Host 'site: az holds a storage token' }
    catch { $publishFailure = "no storage token: $($_.Exception.Message)"; Write-Warning "The pages will not be published, $publishFailure" }
}
# git pushes the Pages: without it nothing is published, and the run fails at its end (the store is still pushed).
$pagesFailure = $null
if ($PublishPages -and -not (Get-Command git -ErrorAction SilentlyContinue)) { $pagesFailure = 'git is not on the PATH'; Write-Warning "The Pages will not be published: $pagesFailure" }
if ($StoreFeed) { [void] (Get-StorePackageId $cfg) }
$window = Resolve-Window $cfg $Since $Until
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$paths = @{
    Bin = Join-Path $WorkDir 'bin'; Workspace = Join-Path $WorkDir 'workspace'; Store = Join-Path $WorkDir 'store'
    HarvestState = Join-Path $WorkDir 'harvest-state.json'; Document = Join-Path $WorkDir 'document.json'
    Web = Join-Path $WorkDir 'web'; Site = Join-Path $WorkDir 'site'; Pages = Join-Path $WorkDir 'pages'; Data = Join-Path $WorkDir 'scorecard-data.json'
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
    [void] (Repair-StoreCulture $cmis $paths)
    Read-ConnectionBases $cmis $measured $paths
    $harvest = [ordered]@{ skipped = $true }
}
else {
    $restored = if ($StoreFeed) { Restore-StoreFromFeed $cfg $WorkDir } else { $null }
    foreach ($dir in $paths.Workspace, $paths.Store) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [void] (Repair-StoreCulture $cmis $paths)
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

$data = Get-ScorecardData $cmis $cfg $projects $window $paths $harvest -IncludeTitles:$PublishPages
if ($StoreFeed) { $data.store = [ordered]@{ package = Get-StorePackageId $cfg; restored = $restored } }
Write-ScorecardFiles $data $WorkDir
foreach ($w in $data.warnings) { Write-Warning $w }

# The pages through Scorecard.Web's export; when that fails, the script's own scorecard.html (written above) stands in.
$siteDir = $null
$siteNote = $null
$siteTitle = Get-SiteTitle $cfg
if ($cfg['scorecardVersion']) {
    try {
        $web = Get-ScorecardWeb $cfg $paths.Web
        Export-ScorecardSite $web $paths $siteTitle $paths.Site
        New-SiteArchive $paths.Site (Join-Path $WorkDir 'scorecard-site.zip')
        $siteDir = $paths.Site
        Write-Host "site: exported with Scorecard.Web $($cfg.scorecardVersion) to $siteDir"
    }
    catch {
        $siteNote = 'no Scorecard.Web export, the page is scorecard.html'
        Write-Warning "No Scorecard.Web export; the page is the script's own scorecard.html: $($_.Exception.Message)"
    }
}

# Published before the store is pushed, and a failure is the run's failure only at its end: the store is pushed and the
# artifacts are attached either way.
if ($PublishSite) {
    $url = Get-SiteUrl $cfg.site
    if ($publishFailure) { $siteNote = "pages NOT published to $url" }
    elseif ($siteDir) {
        try { $siteNote = "pages at $(Publish-ScorecardSite $cfg.site $siteDir)" }
        catch {
            $publishFailure = $_.Exception.Message
            $siteNote = "pages NOT published to $url"
            Write-Warning "The pages were not published to $url`: $publishFailure"
        }
    }
    else { $siteNote = "no Scorecard.Web export, so nothing published; $url keeps the last pages" }
    Add-Content -LiteralPath (Join-Path $WorkDir 'summary.md') -Value "`n## Published pages`n`n$(if ($publishFailure -or -not $siteDir) { $siteNote } else { "The pages of this run: <$url>" })"
}

# The Pages and their data layer, also before the store is pushed; a failure fails the run at its end, as above.
$pagesNote = $null
if ($PublishPages) {
    $pagesUrl = $cfg.site.pages.url
    if ($pagesFailure) { $pagesNote = "Pages NOT published to $pagesUrl" }
    elseif ($siteDir) {
        try {
            [void] (New-PagesSite $data $paths $cmis $cfg $siteDir $paths.Pages $siteTitle)
            $message = "Space scorecard of $siteTitle ($($cfg.space)), $($data.since) to $($data.until), generated $($data.generatedUtc) with cmis $($data.cmis.version) and Scorecard.Web $($cfg.scorecardVersion)"
            $pagesNote = "Pages at $(Publish-ScorecardPages $cfg.site.pages $paths.Pages $message)"
        }
        catch {
            $pagesFailure = $_.Exception.Message
            $pagesNote = "Pages NOT published to $pagesUrl"
            Write-Warning "The Pages were not published to $pagesUrl`: $pagesFailure"
        }
    }
    else { $pagesNote = "no Scorecard.Web export, so nothing published; $pagesUrl keeps the last pages" }
    Add-Content -LiteralPath (Join-Path $WorkDir 'summary.md') -Value "`n## GitHub Pages`n`n$(if ($pagesFailure -or -not $siteDir) { $pagesNote } else { "The pages of this run, with their data for AI tools ($($pagesUrl)llms.txt): <$pagesUrl> (private: members of the organization who may read $($cfg.site.pages.repo))" })"
}

$inOctopus = Test-InsideOctopus
if ($inOctopus) { Publish-OctopusArtifacts $WorkDir $siteDir }
# Last: only a run that got this far pushes its store.
$pushed = if ($StoreFeed) { Publish-StoreToFeed $cfg $WorkDir } else { $null }
# The store is pushed by now: a highlight that fails is a warning, not a failed run.
if ($inOctopus) {
    try { Write-Highlight (Get-HighlightLine $data $pushed (@($siteNote, $pagesNote | Where-Object { $_ }) -join '; ')) }
    catch { Write-Warning "No highlight: $($_.Exception.Message)" }
}
if ($publishFailure -or $pagesFailure) {
    throw (@($(if ($publishFailure) { "The pages were not published to $(Get-SiteUrl $cfg.site): $publishFailure" }), $(if ($pagesFailure) { "The Pages were not published to $($cfg.site.pages.url): $pagesFailure" }) | Where-Object { $_ }) -join ' ')
}
Write-Host ("Done in {0:n1} s: {1}" -f $started.Elapsed.TotalSeconds, $(if ($siteDir) { Join-Path $siteDir 'index.html' } else { Join-Path $WorkDir 'scorecard.html' }))
