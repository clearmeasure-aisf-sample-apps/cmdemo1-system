# Work items feed (`status/workitems.json`)

The work items the system's bots handle on the business repository `cmdemo1-workorders`, for the system dashboard
(`cmdemo1-dashboard`, Blazor WebAssembly, no server). Workflow `workitems` runs `scripts/workitems/write-workitems.ps1`
and publishes the result as `workitems.json` on branch `status`, next to `delivery.json`. The dashboard reads it from
the browser:

```
https://raw.githubusercontent.com/clearmeasure-aisf-sample-apps/cmdemo1-system/status/workitems.json
```

`docs/ops/workitems.sample.json` is an excerpt of a real run (2026-11-09, every stat, 12 of the 735 items, 5 of the
201 releases). Local run, from the repository's root, as whoever `gh` is signed in as:

```
pwsh -NoProfile -File scripts/workitems/write-workitems.ps1 -Path workitems.json -DeliveryPath delivery.json
pwsh -NoProfile -File scripts/workitems/test-write-workitems.ps1
```

## Contract

Times are UTC, `yyyy-MM-ddTHH:mm:ssZ`. Durations are hours, one decimal. `null` means "not known" or "not reached".

```jsonc
{
  "generatedAt": "2026-11-09T23:25:41Z",
  "scope": {
    "repo": "clearmeasure-aisf-sample-apps/cmdemo1-workorders",
    "project": 679,
    "projectTitle": "Clear Measure work orders demo 1",   // null when the project is not readable
    "deployable": "ui",                                   // the deployable of system.json whose repository it is
    "columnSource": "project",                            // "project" | "derived" (see Columns)
    "columns": ["Todo", "In Progress", "Technical Design", "Development", "Functional Testing", "Release Queue", "Done"],
    "window": { "days": 56, "statsDays": 28, "weeks": 8 },
    "rules": ["..."]                                      // the rules below, in words
  },
  "stats": {
    "wipByColumn": { "Todo": 15, "In Progress": 0, "Technical Design": 2, "Development": 0, "Functional Testing": 1, "Release Queue": 11 },
    "cycleTimeHours": { "median": 0.2, "p85": 3.9, "n": 619 },
    "leadTimeHours": { "median": 10.0, "p85": 49.2, "n": 224 },
    "perWeek": [ { "weekStart": "2026-11-02", "merged": 141, "deployedProd": 0 } ],
    "rework": { "ftFailures": 51, "reverts": 0, "reworkedItems": 40, "testedItems": 678, "rate": 0.059 },
    "cost": { "totalUsd": null, "note": "Source unavailable: ..." }
  },
  "items": [
    {
      "number": 1565,
      "title": "AI ops test: unit tests for Employee.HasRole",
      "url": "https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/1565",
      "state": "closed",                                  // "open" | "closed" (the issue)
      "createdAt": "2026-11-09T22:06:23Z",
      "closedAt": "2026-11-09T22:49:43Z",
      "column": "Release Queue",
      "columnSource": "derived",                          // per item: "project" | "derived"
      "columnHistory": [ { "column": "In Progress", "enteredAt": "2026-11-09T22:07:44Z" } ],
      "assignee": "cm-ai-ops-bot",                        // a bot assignee first, else the first assignee; null
      "agent": "cm-ai-ops-bot",                           // who worked it (see Agent); null
      "runtime": null,                                    // runtime:/worker:/agent: label value; null
      "scopeReasons": ["assigned to cm-ai-ops-bot", "pull request by cm-ai-ops-bot"],
      "cursorSessions": ["https://cursor.com/agents/bc-154c759e-4686-5050-b64e-5c71b77937fe"],
      "prs": [ { "number": 1571, "url": "...", "state": "merged", "mergedAt": "2026-11-09T22:49:41Z", "mergeSha": "dfb1740a..." } ],
      "docsOnly": null,                                   // the fworker's merge.docs_only; null when it keeps none
      "releaseCandidate": { "version": "2.4.2060", "createdAt": "2026-11-09T23:02:28Z" },
      "environments": {
        "tdd": null,                                      // { "version", "deployedAt" } once tdd runs it
        "uat": null,
        "prod": null
      },
      "ftFailures": 0,
      "reverts": 0,
      "costUsd": null
    }
  ],
  "releases": [ { "version": "2.4.2060", "sha": "dfb1740a...", "createdAt": "2026-11-09T23:02:28Z", "items": [1560, 1565] } ],
  "missing": [ "project 679: not readable with this token (...); columns are derived ..." ]
}
```

`prs[].state` is `"open"`, `"closed"` (not merged) or `"merged"`; `mergeSha` is the commit the merge made on `master`
(squash), `null` unless merged. `items` is newest issue first; `releases` newest first.

### Differences from the contract first proposed

All of them are additions or a choice the proposal left open; no proposed field is renamed or removed.

| Field | Difference |
|---|---|
| `scope` | Adds `projectTitle`, `deployable`, `columnSource`, `columns`, `window`. `rules` is a list of sentences. |
| item | Adds `createdAt`, `closedAt`, `columnSource`, `runtime`, `scopeReasons`, `docsOnly`, `ftFailures`, `reverts`. `state` and `prs[].state` are lower case. `assignee` and `agent` are strings (or `null`). |
| `environments.<env>.deployedAt` | When the deployment started (its pin commit), not when it finished: the pin history is the only record of every deployment that this workflow can read without Octopus. `null` when the environment runs the change but no pin of it is found (the version is then the one running there). |
| `stats.wipByColumn` | Done is left out: it is not work in progress. |
| `stats.rework` | Adds `reworkedItems` and `testedItems`; `rate` is reworkedItems / testedItems (a share of items, 0 to 1), not failures per item. |
| `releases[]` | Adds `createdAt`; a release that carries no item of the window has `items: []`. |
| top level | Adds `missing`: what could not be read in this run, in words (empty when everything was). |
| containment | Git ancestry in a partial clone of `cmdemo1-workorders` (`git clone --filter=tree:0`: commits only, under a second) instead of one GitHub compare call per commit and release. Same answer as compare's `ahead`/`identical`, and it fails closed the same way: a commit that is not in the clone counts as not contained. |

## Rules

### Scope

An issue of `cmdemo1-workorders` is a work item when any of these hold (its `scopeReasons` say which):

- assigned to `cm-ai-ops-bot`, now or before (an `AssignedEvent` in its timeline: the bot is often unassigned when it
  finishes);
- labelled `factory worker`, `AI Factory`, `agent:*`, `worker:*` or `runtime:*` (the fworker factory's labels);
- it has a `factory-state` comment of the fworker (`<!-- factory-state:<worker> v1 -->`);
- a linked pull request is by `factory-worker-author`, `cursor` or `cm-ai-ops-bot`.

Pull requests by `copilot-swe-agent` or `cmdemo1-aisf` alone do not bring an issue into scope: the factory items they
worked on carry the labels above anyway. Kept in the file: every open item, and a closed one closed, merged or deployed
in the last 56 days.

Seen on 2026-11-09: 773 issues, 735 in scope. 690 have a factory state, 686 the `factory worker` label. The ones out of
scope are people's issues not yet assigned (the "AI ops test" issues before `cm-ai-ops-bot` takes them) and older
issues no bot worked.

### Linked pull requests

A pull request belongs to an issue when it closes it (`closingIssuesReferences`), says `Closes`/`Fixes`/`Resolves`/
`Refs #N` (or `cmdemo1-workorders#N`), has a title that ends `(#N)`, has a branch `factory-worker/<N>-*` or
`issue-<N>-*`, or is the pull request in the issue's factory state (`merge.pr`, `pr.number`). The factory's pull
requests say `Refs #N`, so they have no closing reference.

### Columns

With project access (`columnSource: "project"`): the item's `Status` on project 679, and its history from the issue
timeline (`ProjectV2ItemStatusChangedEvent`; the column before the first change is entered when the item was added).

Without it (`"derived"`), from what the bots write on the issue:

- the fworker's factory state: `flow` (column, time) in order; for states written before `flow` existed,
  `dispatched_at` per column; `merge.queued_at` is Release Queue, `merge.done_at` is Done (a docs-only merge goes to
  Done at the merge; a release goes to Done when it succeeds in prod);
- the journal lines of `cm-ai-ops-bot`, `factory-worker-author` and `cursor`: `Todo → In Progress`,
  `A → B → C`, `X → Y (via Z)` (also `->`), at the comment's time. A move counts when it leaves the column the item is
  in, or goes past it; a recap of earlier moves (the bot's "catch-up" comments) does not count again. People's comments
  are not read;
- a derived Release Queue item whose change runs in prod is Done at that deployment; a closed issue that never reached
  Release Queue is Done when it was closed. A closed issue in Release Queue stays there: the bots close the issue at the
  merge, and it is Done only once prod runs it.

The factory takes items from Todo straight to Technical Design, so their history starts there.

### Release candidate

`release.yml` of `cmdemo1-workorders` creates the Octopus release of every green master Build that has packages, and
GitHub records a deployment `release` for it. A release here is such a deployment: its commit, its time, and the
version of the newest push or dispatched master Build run of that commit before it (`2.4.<run_number>`, the start of
the run's title). A version pinned in an environment that no deployment names is added from its Build run.
`releaseCandidate` is the first release, by time, whose commit contains the merge commit of the item's last merged
pull request. A docs-only merge has no release of its own: its candidate is the next release, which carries it.

### Environments

Per environment of the deployable: the commits "Pin ui <version> in <env> (Deployments-N)" of
`environments/<env>/versions.json` in this repository, without those reverted as failed ("Revert pin of ... (Deployments-N
failed)"). `environments.<env>` is the first of them whose release contains the merge commit (version, pin time), but
only while the commit running there contains it: that commit is `delivery.json`'s (`commit` of the deployable), else the
one of the version `versions.json` pins now. The fworker's range check (cmdemo1-fworker `docs/design/auto-promote.md`)
judges a release by the same rule: a commit is in an environment when it is an ancestor of the commit running there.

### Stats

- `wipByColumn`: items per column, Done left out.
- `cycleTimeHours`: from the first column after Todo (In Progress, or Technical Design for the factory) to Done, of the
  items that reached Done in the last 28 days.
- `leadTimeHours`: from the issue's creation to the start of its prod deployment, of the items deployed to prod in the
  last 28 days.
- `perWeek`: per week (Monday 00:00 UTC), the current one last: `merged`, items whose first pull request merged that
  week; `deployedProd`, items that reached prod that week.
- `rework`: `ftFailures`, Functional Testing failures that sent an item back (per item the most of the fworker's
  `demotions`, its "verdict for **Functional Testing**: FAIL" comments, and moves from Functional Testing to an earlier
  column); `reverts`, merged pull requests of an item reverted on `master` (a merged "Revert ..." pull request, or a
  commit `Revert "... (#N)"`); `reworkedItems`, items with either; `testedItems`, items that reached Functional Testing
  or merged; `rate` = reworkedItems / testedItems.
- `cost`: `totalUsd` and every item's `costUsd` are `null`. No source this workflow can read states the Cursor cost of an
  item: Cursor's API (`api.cursor.com`, usage per agent) needs a Cursor API key, which the fworker keeps in its Azure Key
  Vault and this repository does not store; the fworker gateway's `/api/v1/status` reports token counts (not dollars)
  and answers 401 without the gateway's credential; no issue or pull request comment states a cost.

## When it runs

No timer. The file changes when:

- workflow `delivery` completes after a deployment pinned a version (its `push` trigger) or a person ran it: so every
  deployment is followed once `delivery.json` says what runs where. Its hourly runs start `workitems` too, which skips
  at once (`if:` on the job), so they read nothing and push nothing;
- `repository_dispatch` with type `workitems`, for events of other repositories;
- `workflow_dispatch`.

A merge, a comment or a board move in `cmdemo1-workorders` alone does not run it: the next deployment does (every
release reaches tdd within minutes), or a dispatch. What would send the dispatch, if the owner wants the board live:

- Board moves are no Actions event of a repository (`projects_v2_item` is an organization webhook only), so the bots that
  move cards (the fworker gateway, `cm-ai-ops-bot`) would send it after a move, and `cmdemo1-workorders` could send it on
  `issues` and `pull_request: closed`:
  `gh api repos/clearmeasure-aisf-sample-apps/cmdemo1-system/dispatches -f event_type=workitems`
- The sender needs a token with Contents: write on `cmdemo1-system` (what `POST /repos/{owner}/{repo}/dispatches`
  requires). None of the existing credentials of `cmdemo1-workorders` has that; it would be a new secret there (for
  example a token of this system's App `cmdemo1-system` made from its key), which this change does not add.

## Credentials

- The system's own App `cmdemo1-system` (`system.json` `github.app`, key `SYSTEM_APP_PRIVATE_KEY` in environment
  `capabilities`, as `capabilities.yml` uses it): a token with Organization projects: read only, which reads project
  679 (private). When the App may not read the organization's projects, GitHub gives no token; the step fails without
  failing the run, the run reads with the workflow's own token, and the columns are derived (`missing` and
  `scope.columnSource` say so). To read the board, the organization's owner gives the App the permission
  Organization projects: read, and accepts it on the installation; no secret changes.
- The workflow's own token: reads the public `cmdemo1-workorders` (issues, pull requests, Build runs, deployments) and
  pushes branch `status`.

## Publishing

`workitems.json` is one file of branch `status`, which has one commit and no history. `workitems` replaces it with a
commit of the other files as published plus its new file, and pushes with a lease: if `delivery` replaced the branch
meanwhile, the push is refused and made again on top. `delivery` keeps the published `workitems.json` when it replaces
the branch (it writes none). A file that says what the published one says, `generatedAt` aside, is not pushed, so
`generatedAt` is the time of the last change.
