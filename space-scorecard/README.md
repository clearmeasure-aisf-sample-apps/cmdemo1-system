# Space scorecard

The delivery scorecard of a whole Octopus Deploy space, as one static page. Every project of the space is paired with
its GitHub repository, each pair is harvested with cmis (Clear Measure Intelligence Scorecard) as a `GitHubDelivery`
connection, and the weekly numbers of the space and of each project are written to `scorecard.html` and `summary.md`.

Step 1 of the design "Space-level scorecard on cmis": discovery, cmis harvest and a static page, run by hand. Step 2:
the same run every night as an Octopus runbook of the space, its store kept as a package in the space's built-in feed
(see [Every night in Octopus](#every-night-in-octopus)). Nothing in Azure is changed.

| File | What |
|---|---|
| `Invoke-SpaceScorecard.ps1` | The run: get cmis, discover, connections, harvest, compute, render |
| `cmdemo1.json` | The configuration of the cmdemo1 space (Spaces-355) |
| `test-space-scorecard.ps1` | Tests without network: discovery order, the release-notes address, connection ids, rendering, the store package |
| `setup-octopus.ps1` | Sets up the nightly runbook in the space (runner identity, project, variables, runbook, trigger); idempotent |

## Run it

Needs PowerShell 7.5 or later, Linux x64, a GitHub token (`GITHUB_TOKEN`, else the one of `gh auth token`: it downloads
cmis and checks repository names through the GitHub REST API; `gh` itself is not needed), and an Octopus API key that
can read the space's projects and deployments (with `-StoreFeed` also view and download from the built-in feed and push
to it).

```powershell
$env:OCTOPUS_API_KEY = '<key>'          # read access to the space; never written anywhere
pwsh -NoProfile -File space-scorecard/Invoke-SpaceScorecard.ps1 -Config space-scorecard/cmdemo1.json -WorkDir /var/tmp/space-scorecard/run
```

| Parameter | What |
|---|---|
| `-Config` | The space's configuration file |
| `-WorkDir` | Where everything goes; keep it between runs, a rerun syncs instead of harvesting again |
| `-Since`, `-Until` | The window, `yyyy-MM-dd`. Default: `Until` = today in `timeZone`, the window `historyDays` days long |
| `-SkipHarvest` | Compute and render from what the store holds, for the projects of the last full run (`discovery.json`): asks neither GitHub nor Octopus for anything and changes no connection |
| `-StoreFeed` | Keep the store in the space's built-in feed: restore the newest `<prefix>-scorecard-store` package before the harvest, push a new version after a run that succeeded (see below). Not with `-SkipHarvest` |

The GitHub token is `GITHUB_TOKEN`, else `gh auth token`. Each connection reads its credentials from
`CMIS_<ID>_TOKEN` and `CMIS_<ID>_OCTOPUS_TOKEN` (`<ID>` = the connection id upper-cased, `-` as `_`); the script sets
them in its own process only.

What lands in the work directory:

| Path | What |
|---|---|
| `scorecard.html` | The page: one file, no script, no external request; dark and light; readable on a phone |
| `summary.md` | The space's weekly table, one line per project for the last full week, what is measured and what not |
| `scorecard-data.json` | Every number and item list the page is rendered from (no item titles) |
| `document.json` | `cmis connections document` over all connections: metrics per local day of `timeZone`, item timelines |
| `discovery.json` | Each project of the space: its repository and where the pairing came from, or why it is not measured |
| `bin/`, `workspace/`, `store/` | cmis itself, its workspace and its data store |
| `harvest-state.json` | The first day each connection was harvested from |

Tests: `pwsh -NoProfile -File space-scorecard/test-space-scorecard.ps1` (PASS or FAIL per case, exit 1 on a FAIL).

## What it does

1. **Get cmis.** Downloads `cmis-<cmisVersion>-linux-x64.tar.gz` and `SHA256SUMS.txt` of release `v<cmisVersion>`
   from `cmisRepo` through the GitHub REST API with the token, checks the SHA-256, unpacks into `bin/`. A binary there
   that already reports that version is reused.
   With `-StoreFeed`, the store is then **restored**: the newest version of `<prefix>-scorecard-store` in the space's
   built-in feed (by its four numbers) replaces `store/`, `workspace/`, `harvest-state.json` and `discovery.json` of
   the work directory. It is unpacked beside the work directory first and swapped in only when that worked; a package
   with an entry outside those four is refused. A package that cannot be restored is a warning and the next older one
   is tried (three at most); when none of them can be restored, the run fails. When the feed has none yet, the run starts from what the work
   directory holds (nothing, on a fresh one), so the first run harvests the whole window.
2. **Discover.** Lists the projects of the space through the Octopus REST API. The repository of each project is the
   first of:
   1. `projects.<name>.repo` of the configuration (`config`);
   2. the `VcsRoot` of the build information of the newest release (`build information`);
   3. the first `github.com/<owner>/<repo>` address in the newest release's notes (`release notes`);
   4. a repository in `githubOwner` named like the project's slug, else like its name, when GitHub has one (`name`).

   An address found in Octopus counts only when GitHub has that repository; otherwise the next rule is tried. Only
   GitHub's 404 means "no such repository": any other failure stops the run. A disabled project, one in `exclude`
   and one with none of these are not measured; the page says why.
3. **Connections.** One cmis `GitHubDelivery` connection per measured project, id = the project's slug, coordinates
   `owner`, `repo`, `octopusServer`, `octopusSpace`, `octopusProject`, `environments`, `itemNumberBase` and the
   automation rules. Added once, then `connections update`, so a rerun changes nothing (`connections add --replace`
   when a coordinate is to be dropped from a connection that holds no data: update cannot drop one). `itemNumberBase` keeps the item
   numbers of the repositories apart when cmis scores them together (cmis knows an item by its number alone): a multiple
   of 1,000,000, kept once given (also for a connection no longer measured), new projects get the lowest free one in
   the order of their Octopus ids. cmis refuses to
   harvest or score a connection whose stored history came from other coordinates and has no command that forgets one
   connection's history; so when the coordinates of a connection that holds data change (the configuration changed),
   the workspace and the store start again and everything is harvested anew, with a warning.
4. **Harvest.** Per connection: `connections harvest` over the window when the store holds nothing of it, else
   `connections sync` from its watermark (from `Since` when `Since` lies before the first day harvested, which
   `harvest-state.json` keeps). The harvest reaches one UTC day past `Until`, so the last local day of a zone west of
   UTC is covered. A connection that fails is listed as not measured (the console says why); the others go on.
5. **Compute.** `connections score --period week` for the space (all connections) and for each project;
   `connections document`; `connections score-drill` for every weekly cell of Work in process, Items started and Items
   delivered that is not zero. A drill list whose length differs from its number, a drill that fails, and a space
   number that is not the sum of its projects', are warnings on the page.
6. **Render.** Rows Work in process, Items started, Items delivered, Mean time to delivery (MTTD), and in a folded panel
   Throughput (stage moves), Rework, Net throughput; weeks as columns, newest on the right. Every number of the first
   three rows links to its item list at the end of the page: the issue or pull request number, its kind, its stage
   move and when. No titles. A direct commit or branch item has no GitHub address of its own in cmis (no commit id or
   branch name), so it is listed by its cmis item number, without a link. The lists are always shown: a hidden list
   is not opened on every browser when the page is opened at a list's address, and the page has no script.
   The render step is one function, `Write-ScorecardFiles`, that reads only the computed data, so another renderer can
   take its place.
7. **Inside Octopus** (the script runs in an Octopus step: `$OctopusParameters` or `New-OctopusArtifact` is there):
   `scorecard.html`, `summary.md` and `document.json` become artifacts of the task, and one line is highlighted: the
   space's numbers of the last full week, how many projects are measured and how many harvests failed, the store
   version pushed. A highlight that fails is a warning: the store is pushed by then.
8. **Push** (`-StoreFeed`), last: `store/` (cmis's store directory as cmis writes it, which cmis and Scorecard.Web
   both read), `workspace/`, `harvest-state.json` and `discovery.json` as `<prefix>-scorecard-store.<version>.zip` to
   the built-in feed (`POST /api/<space>/packages/raw?overwriteMode=FailIfExists`, no redirect followed, so the key
   goes to `octopusServer` only). The version is `yyyy.M.d.HHmmss` of the time in UTC, the time of day as one number
   without leading zeros (00:15:00 is `1500`, 09:05:07 is `90507`; 00:00:00 is `1`, as a feed may shorten a version
   ending in `.0`), so the four numbers order as the times do. A run that fails before this point pushes nothing, and the next run starts again from the
   last package that was pushed. A project whose harvest failed is a warning, not a failure: the others are pushed.
   The feed deletes a package no release uses after the days its retention says (30 in Spaces-355): a store not
   pushed for that long is gone, and the next run harvests the whole window again.

Weeks are cmis's weekly periods: ISO weeks, Monday 00:00 UTC to the next (the calendar of cmdemo1-scorecard's page).
Leading weeks in which nothing happened are left out; a week the window does not cover whole is marked `*`. MTTD reads
as cmdemo1-scorecard writes it: minutes under 90 minutes, hours with one decimal under 48 hours, else days.

## Configuration

| Key | What |
|---|---|
| `space` | The Octopus space id, for example `Spaces-355` |
| `prefix` | Lower case letters, digits, `-`: begins the names of the space's own objects, the store package `<prefix>-scorecard-store` and those `setup-octopus.ps1` makes. Needed by `-StoreFeed` |
| `octopusServer` | The Octopus server address, `https://` (the API key is sent to it) |
| `githubOwner` | The GitHub organization or user of the repositories (for `projects.<name>.repo` without an owner, and the name rule) |
| `timeZone` | IANA zone of "today" and of the local days of `document.json`. Default `UTC` |
| `historyDays` | The default window length in days, 1 or more. Default 90 |
| `cmisVersion` | The cmis release to use, without the `v` of its tag |
| `cmisRepo` | The GitHub repository of the cmis releases |
| `automation.authors` | Logins of automation accounts (case and a trailing `[bot]` ignored): a pull request of theirs that belongs to no issue is an automation item, still counted; a commit of theirs pushed straight to the default branch is no work item |
| `automation.branches` | Regular expressions over a whole head branch name (case ignored): a pull request from such a branch that belongs to no issue, and a branch item of such a name, is an automation item, still counted |
| `automation.commitMessages` | Regular expressions over the whole first line of a commit message (case ignored): such a commit pushed straight to the default branch (a pin, a template sync) is no work item |
| `projects.<name>.repo` | The repository of the project (by Octopus project name or slug): `repo` in `githubOwner`, or `owner/repo` |
| `projects.<name>.environments` | `auto` (the project's lifecycle, read at harvest; its last environment is Delivered) or ordered `environment:Stage` pairs, for example `tdd:TDD,uat:UAT,prod:Delivered` |
| `exclude` | Project names or slugs that are not measured |

The three automation lists are trimmed and taken without blanks and repeats, as cmdemo1-scorecard reads its own.

The automation rules and the two project settings of `cmdemo1.json` are those of cmdemo1-scorecard
(`Scorecard.Web/appsettings.json` of clearmeasure-aisf-sample-apps/cmdemo1-scorecard), so both count the same items.

`cmdemo1.json` excludes `cmdemo1-scorecard-space`, the project of the nightly runbook: it has no repository and no
deliveries.

## Every night in Octopus

`setup-octopus.ps1`, run by the operator (`OCTOPUS_ADMIN_API_KEY`, else the kit's `Get-OctopusApiKey`: Space manager
of the space plus the system permissions UserView, UserEdit, UserRoleView and UserRoleEdit) with `gh` logged in, sets
up in the configuration's space (names from `prefix`). An object of one of these names that the script did not make
stops it:

| What | Name | Notes |
|---|---|---|
| User role | `cmdemo1 scorecard store feed` | `FeedView`, `BuiltInFeedDownload`, `BuiltInFeedPush` only (a push never replaces a version). No built-in role lets an account download from the built-in feed without much more (Build server also creates releases, deployments and runbook runs, and deletes packages; Package publisher also pushes and deletes build information) |
| Service account | `cmdemo1-scorecard-runner` | No login; its API key goes only into `Scorecard.OctopusApiKey`, expires after a year. Octopus lets no AI agent's identity (the operator's ai-ops is one) make an API key: a person makes it in the portal and gives it with `-ReadRunnerKey` (older keys are then deleted in the portal); with a person's own key `-RotateOctopusKey` makes a new one and deletes the older. Until the variable has a key the script ends with exit code 3 and the trigger stays disabled. **In use instead (Jeffrey's decision of 2026-10-22):** `-UseOperatorKey` puts the operator's own key (ai-ops, the key the script runs with) into `Scorecard.OctopusApiKey`, and its description says so; the account and its team are kept, unused, for a runner key later (`-ReadRunnerKey` replaces the operator's). Rerun `-UseOperatorKey` when the operator's key changes: nothing detects an old one, and the nightly runs then fail |
| Team | `cmdemo1 scorecard runner` | Of the space; the account only; roles Project viewer and the store feed role, unscoped within the space |
| Project | `cmdemo1-scorecard-space` | Project group and lifecycle of `cmdemo1-system`; no deployment process |
| Variables | `Scorecard.OctopusApiKey`, `Scorecard.GitHubToken` (sensitive), `Scorecard.SourceRef` (prompted, default `main`) | The GitHub token is the operator's `gh auth token`, set when missing or with `-UpdateGitHubToken` |
| Runbook | `Refresh space scorecard` | prod only; one "Run a Script" step on `Hosted Ubuntu`, on the worker itself (Ubuntu 24.04 with PowerShell 7.6.2; `-ContainerImage` runs it in an execution container instead); its snapshot is published when anything changed |
| Trigger | `Nightly space scorecard` | Every day 00:15 in `timeZone` (America/Chicago; `-Schedule`), the published runbook in prod |

The step downloads the `space-scorecard` folder of this repository at `Scorecard.SourceRef` through the GitHub API
(tarball), sets `GITHUB_TOKEN` and `OCTOPUS_API_KEY` from the sensitive variables in its own process, and runs
`Invoke-SpaceScorecard.ps1 -Config space-scorecard/cmdemo1.json -WorkDir <the step's folder> -StoreFeed` (the window:
`historyDays` days up to today in `timeZone`). A manual run may name another branch in `Scorecard.SourceRef`, to try a
change before it merges; the nightly run takes `main`. The page, the summary and the document are artifacts of each
run's task.

Accepted for this demo space, and to reconsider before another:

- Whoever may run the runbook, or push a branch to this repository, can run that branch's code with both secrets. A
  manual run of another ref also pushes the store that the next nightly run restores.
- The GitHub token is the operator's own login (broad scopes), not a read-only credential of its own.
- The Octopus key is the operator's own (Space manager of the space and more), by Jeffrey's decision of 2026-10-22,
  not the runner's least-privilege key: anything that runs in the step can act with it.
- `BuiltInFeedPush` cannot be limited to one package id: the runner's key may push a new version of any package of
  the built-in feed (never replace one).
- The store package holds data harvested from the space's repositories; everyone with `BuiltInFeedDownload` in the
  space can download it.

A rerun of `setup-octopus.ps1` changes only what differs from the above and says what it did; it prints ids, never a
key or a token.
