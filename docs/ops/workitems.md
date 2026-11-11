# Work items feed (`status/workitems.json`)

Every issue of the business repository `cmdemo1-workorders`, for the system dashboard (`cmdemo1-dashboard`, Blazor
WebAssembly, no server). Each item is tagged `bot` or `team`. Workflow `workitems` runs
`scripts/workitems/write-workitems.ps1` and publishes `workitems.json` on branch `status`, next to `delivery.json`.
The dashboard reads it from the browser:

```
https://raw.githubusercontent.com/clearmeasure-aisf-sample-apps/cmdemo1-system/status/workitems.json
```

`docs/ops/workitems.sample.json` is an excerpt of a real run on 2026-11-10: every stat, 4 of the 773 items
(735 bot, 38 team) and 3 of the releases. The project was not readable with the token that ran it, so those columns
are derived and `missing` says so. Local run, from the repository's root, as whoever `gh`
is signed in as:

```
pwsh -NoProfile -File scripts/workitems/write-workitems.ps1 -Path workitems.json -DeliveryPath delivery.json
pwsh -NoProfile -File scripts/workitems/test-write-workitems.ps1
```

The top-level `stats` keys are the numbers for every item, which is what the dashboard's Work items view reads
(cmdemo1-dashboard PR #12). `stats.all` is those same numbers, `stats.bot` and `stats.team` split them.

## Contract

Times are UTC, `yyyy-MM-ddTHH:mm:ssZ`. Durations are hours, one decimal. `null` means "not known" or "not reached".

```jsonc
{
  "generatedAt": "2026-11-10T00:13:10Z",
  "scope": {
    "repo": "clearmeasure-aisf-sample-apps/cmdemo1-workorders",
    "project": 679,
    "projectTitle": "Clear Measure work orders demo 1",   // null when the project is not readable
    "deployable": "ui",
    "columnSource": "project",                            // "project" | "derived"
    "columns": ["Todo", "In Progress", "Review", "Merged", "TDD", "UAT", "Done"],
    "window": { "days": 56, "statsDays": 28, "weeks": 8 },
    "rules": ["..."]
  },
  "stats": {
    "wipByColumn": { "Todo": 0 },                         // equal to stats.all; Done is left out
    "cycleTimeHours": { "median": 0.2, "p85": 3.9, "n": 0 },
    "leadTimeHours": { "median": 10.0, "p85": 49.2, "n": 0 },
    "perWeek": [ { "weekStart": "2026-11-02", "merged": 0, "deployedProd": 0 } ],
    "rework": { "ftFailures": 0, "reverts": 0, "reworkedItems": 0, "testedItems": 0, "rate": 0.0 },
    "cost": { "totalUsd": null, "note": "No cost source is connected yet." },
    "all": { "wipByColumn": {}, "cycleTimeHours": {}, "leadTimeHours": {}, "perWeek": [], "rework": {}, "cost": {} },
    "bot": {
      "wipByColumn": {}, "cycleTimeHours": {}, "leadTimeHours": {}, "perWeek": [], "rework": {}, "cost": {},
      "hoursByColumn": { "In Progress": 0.4, "Review": 0.1 },
      "throughputByAgent": { "cm-ai-ops-bot": 4, "factory-worker": 120 },
      "mergeToProdHours": { "median": 1.2, "p85": 6.0, "n": 40 }
    },
    "team": { "wipByColumn": {}, "cycleTimeHours": {}, "leadTimeHours": {}, "perWeek": [], "rework": {}, "cost": {} }
  },
  "items": [
    {
      "number": 1565,
      "title": "AI ops test: unit tests for Employee.HasRole",
      "url": "https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/1565",
      "state": "closed",                                  // "open" | "closed"
      "createdAt": "2026-11-09T22:06:23Z",
      "closedAt": "2026-11-09T22:49:43Z",
      "column": "Merged",
      "columnSource": "derived",                          // "project" | "derived", per item
      "columnHistory": [ { "column": "In Progress", "enteredAt": "2026-11-09T22:07:44Z", "leftAt": "2026-11-09T22:11:39Z", "hours": 0.1 } ],
      "worker": "bot",                                    // "bot" | "team"
      "assignee": "cm-ai-ops-bot",
      "agent": "cm-ai-ops-bot",                           // the specific identity; a person for a team item
      "runtime": null,
      "scopeReasons": ["assigned to cm-ai-ops-bot"],
      "cursorSessions": ["https://cursor.com/agents/bc-154c759e-4686-5050-b64e-5c71b77937fe"],
      "prs": [ { "number": 1571, "url": "...", "state": "merged", "mergedAt": "...", "mergeSha": "...", "checks": "success" } ],
      "docsOnly": null,
      "releaseCandidate": { "version": "2.4.2060", "createdAt": "2026-11-09T23:02:28Z" },
      "environments": { "tdd": { "version": "2.4.2062", "deployedAt": "2026-11-09T23:20:00Z" }, "uat": null, "prod": null },
      "ftFailures": 0,
      "reverts": 0,
      "costUsd": null,
      "latestStatusComment": { "url": "https://github.com/.../issues/1565#issuecomment-1", "at": "2026-11-09T22:53:22Z", "kind": "status" },
      "mergeToProdHours": null
    }
  ],
  "releases": [ { "version": "2.4.2060", "sha": "dfb1740a...", "createdAt": "2026-11-09T23:02:28Z", "items": [1560, 1565] } ],
  "missing": [ "project PVT_kwDOD_ESUc4BliGL (project 679): not readable with ...; columns are derived from cm-ai-ops-bot journal comments. ..." ]
}
```

`prs[].state` is `open`, `closed` or `merged`. `items` is newest issue first; `releases` newest first. A team item has
the same fields except `columnHistory` entries have no `leftAt` or `hours`, its pull requests have no `checks`, and it
has no `latestStatusComment` or `mergeToProdHours`.

### What changed, and what the dashboard keeps reading

cmdemo1-dashboard PR #12 reads `stats.wipByColumn`, `stats.cycleTimeHours`, `stats.leadTimeHours`, `stats.perWeek`,
`stats.rework` (`ftFailures`, `reverts`, `rate`) and `stats.cost` (`totalUsd`, `note`), and per item `number`, `title`,
`url`, `state`, `column`, `columnHistory[].column`, `columnHistory[].enteredAt`, `assignee`, `agent`,
`cursorSessions`, `prs` (`number`, `url`, `state`, `mergedAt`, `mergeSha`), `releaseCandidate`, `environments`
(`tdd`/`uat`/`prod` of `version` and `deployedAt`) and `costUsd`. Those still mean the same thing. `stats.wipByColumn`
and the rest are every item, which is `stats.all`. Anything the view does not know is ignored.

| Addition | Meaning |
|---|---|
| `worker` | `bot` or `team` |
| `stats.all`, `stats.bot`, `stats.team` | The same stats for every item, for bot items, and for team items |
| `stats.bot.hoursByColumn` | Median hours a bot item spent in each column |
| `stats.bot.throughputByAgent` | Bot items that reached Done in the last 28 days, by `agent` |
| `stats.bot.mergeToProdHours` | Median, p85 and count of bot items' merge-to-prod hours whose prod deployment is in the last 28 days |
| bot `columnHistory` | Also `leftAt` (null while it is the current column) and `hours` (up to now, for the current column) |
| bot `prs[].checks` | The check rollup of the pull request's latest commit: `success`, `failure`, `pending`, `error`, `expected`, or null |
| bot `latestStatusComment` | `{ url, at, kind }` with `kind` `status` or `blocker` |
| bot `mergeToProdHours` | Hours from its last merged pull request to the start of its prod deployment; null until both exist |
| `environments.<env>.deployedAt` | When the deployment started (the pin commit). Null when the environment runs the change but no pin of it was found |

## Rules

### Who is in the file

Every issue of `cmdemo1-workorders`. Kept: every open issue, and a closed one closed, merged or deployed in the last
56 days. The repository's issues all fall inside that window today.

`worker` is `bot` when any of these hold (`scopeReasons` says which), and `team` otherwise:

- assigned to `cm-ai-ops-bot`, now or before;
- a linked pull request by `cm-ai-ops-bot`, `factory-worker-author`, `cursor`, `copilot-swe-agent` (Copilot), or any
  other bot account (a GitHub App, a login ending `[bot]`, or an author of type Bot);
- a factory label (`factory worker`, `AI Factory`, `agent:*`, `worker:*`, `runtime:*`) or a `factory-state` comment.
  Both are the record a bot wrote on the issue. Nothing is read from a factory gateway, its Key Vault, or any other
  service of it.

`agent` is the specific identity: the worker named in a factory-state comment, else `cm-ai-ops-bot` when it was
assigned, else the bot that wrote the pull request, else `factory-worker` when only a label says so. For a team item it
is the assignee, else the pull request's author, else whoever opened the issue.

### Columns

The column is the item's Status on organization project 679, node `PVT_kwDOD_ESUc4BliGL`, and the history is that
project's status changes. The workflow tries, in order, the Actions secret `GH_PROJECT_TOKEN` (only when this
repository already has it), then the `cmdemo1-system` App with Organization projects: read, then the workflow's own
token.

When none of those can read the project, `columnSource` is `derived` and `missing` names the source that failed and
the secret that would read the board. Cycle time, hours per column and throughput then cover only the items whose
moves were journaled, which is why their `n` is small until the project can be read. The column comes only from
`cm-ai-ops-bot`'s comments: `Todo → In Progress`,
`A → B → C`, `X → Y (via Z)` (also `->`), at the comment's time. A move counts when it leaves the column the item is
in or goes past it, so a comment that restates earlier moves does not count twice. A factory-state comment is not a
column source. Derived advances fill gaps when journals lag: PR opened → Review; merged → Merged (docs-only → Done);
tdd/uat/prod deploy → TDD/UAT/Done. A closed issue that never reached Merged is Done when it was closed.

### Bot detail

For a bot item, each column visit also has `leftAt` and `hours`. Its pull requests carry `checks`. `latestStatusComment`
is the newest comment that is a blocker (it says "blocker") or a status report (a journal, a `→` move, or a verdict,
from `cm-ai-ops-bot`, `factory-worker-author` or `cursor`). `mergeToProdHours` is the last merge to the prod pin.
`environments.<env>.deployedAt` is on every item.

### Release candidate and environments

A release is a GitHub deployment `release` of `cmdemo1-workorders`, which `release.yml` creates together with the
Octopus release. Its version is `2.4.<run_number>` of the master Build run of that commit. `releaseCandidate` is the
first release, by time, whose commit contains the merge commit of the item's last merged pull request.

Per environment, `environments.<env>` is the first pin of `ui` (`Pin ui <version> in <env>`, skipping a pin that was
reverted because the deployment failed) whose release contains that merge commit, and only while the commit running
there still contains it. The running commit is `delivery.json`'s, else the commit of the version pinned now. Containment
is git ancestry in a commits-only clone of the repository, the same answer as GitHub's compare.

### Stats

Computed three times, over every item, the bot items and the team items. The top-level keys repeat the every-item
numbers.

- `wipByColumn`: items per column, Done left out.
- `cycleTimeHours`: first column after Todo to Done, for items that reached Done in the last 28 days.
- `leadTimeHours`: created to the prod deployment, for items deployed to prod in the last 28 days.
- `perWeek`: per week (Monday 00:00 UTC), the current one last. `merged` is items whose first pull request merged that
  week; `deployedProd` is items that reached prod that week.
- `rework.rate` is reworked items divided by tested items, from 0 to 1. A reworked item had a Review failure (the most
  of the `demotions` recorded on the issue, its "Review: FAIL" verdicts, and moves from Review back to an earlier
  column) or a merged pull request reverted on `master`.
- `cost.totalUsd` and every item's `costUsd` are null. No cost source is connected yet.
- `stats.bot.hoursByColumn`: the median of the hours bot items spent in each column, including the current column up
  to the run.
- `stats.bot.throughputByAgent`: bot items whose column history records Done in the last 28 days, counted by `agent`.
- `stats.bot.mergeToProdHours`: median, p85 and count of `mergeToProdHours` for bot items deployed to prod in the last
  28 days.

## When it runs

No timer. It runs when workflow `delivery` completes after a deployment or a person started it (the hourly `delivery`
run starts it too, and the job skips at once), on `repository_dispatch` of type `workitems`, and by hand.

A merge or a board move in `cmdemo1-workorders` does not start it. The next deployment does. To run it from there,
`gh api repos/clearmeasure-aisf-sample-apps/cmdemo1-system/dispatches -f event_type=workitems` needs a token with
Contents: write on this repository, which `cmdemo1-workorders` does not have.

## Credentials

No new secret. For the project, in order:

1. `GH_PROJECT_TOKEN`, an Actions secret of `clearmeasure-aisf-sample-apps/cmdemo1-system`, used only when it is
   already there. It needs read access to organization project 679 (node `PVT_kwDOD_ESUc4BliGL`). This repository does
   not have that secret today.
2. The system's App `cmdemo1-system` (`system.json` `github.app`, key `SYSTEM_APP_PRIVATE_KEY` in environment
   `capabilities`), asking only for Organization projects: read. When the App may not, GitHub gives no token and the
   step does not fail the run.
3. The workflow's own token, which reads the public repository and not the private project.

Whichever is tried, a project it cannot read is named in `missing` and the columns are derived. To read the board, put
`GH_PROJECT_TOKEN` on this repository, or give the App Organization projects: read and accept it on installation
170295030. Neither changes a secret that already exists.

## Publishing

`workitems.json` is one file of branch `status`. `workitems` replaces the branch with the other files as published
plus its new file, and pushes with a lease so a `delivery` run that moved the branch meanwhile is not overwritten.
`delivery` keeps the published `workitems.json` when it replaces the branch. A file that says what the published one
says, `generatedAt` aside, is not pushed.
