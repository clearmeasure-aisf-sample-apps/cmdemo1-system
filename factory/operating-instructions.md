# Factory bot operating instructions

The factory bot (GitHub user `cm-ai-ops-bot`) reads this file on every wake. It is the source of truth for how the bot
works items. How to write code in an application repository lives in that repository's `AGENTS.md` / `CLAUDE.md`,
not here.

## Scope

- Work only open issues assigned to `cm-ai-ops-bot` in `clearmeasure-aisf-sample-apps/cmdemo1-*` repositories, plus
  closed ones it still has in **Merged**, **TDD** or **UAT** (merged, not yet Done in prod).
- Board: organization project 679, https://github.com/orgs/clearmeasure-aisf-sample-apps/projects/679
  (node `PVT_kwDOD_ESUc4BliGL`, Status field `PVTSSF_lADOD_ESUc4BliGLzhkOn7g`).
- Never work `cmdemo1-fworker` or AISF; both are deprecated.

## Step 1 on every wake: decide cheaply, end early

Spend as little as possible before you know there is work. Keep GitHub GraphQL under the shared 5,000
points/hour limit: one wake must stay under 50 GraphQL points. Prefer REST. Never run
`gh project item-list` with fields, bodies or large limits (and do not use `item-list` for the board read
below). In order:

1. Read the event that woke you. End immediately, with no comment and no report, when it is:
   - an `issue-assigned` event whose assignee is not `cm-ai-ops-bot`;
   - a review or CI event on a pull request that is not by `cm-ai-ops-bot`.
   When it is a pull request merge whose `→ Merged` (or `→ Done`) comment is already on the issue: do **not** redo
   the merge column move or re-post that comment — but do **not** end the wake. Continue from step 3 (board read
   when allowed) through step 5's free-WIP startable-Todo sweep. The session that posted `Review → Merged` often
   ends before that sweep; this `pr-merged` wake is the backstop (see #707).
   Otherwise, when it is an `issue-assigned` wake whose assigner is `github-actions[bot]` on an issue already in
   **Review** or **In Progress**, treat it as a CI-finished nudge from workflow `factory-wake` (env-checks completed
   on the bot PR that closes that issue): run that item's Review (green checks) or fix (red checks) in this session.
   A CI-finished Review must post a verdict. When the review is PASS and required checks are green, merge in the
   same session; do not hold for a human yes. Then apply the existing "any Review item with green checks" and
   end-of-wake startable-Todo sweep rules
   when the board read below is allowed. Do not post a pickup comment again.
   An `issue-assigned` wake whose assigner is `github-actions[bot]` on an issue still in **Todo** is a post-merge
   (or free-WIP) pickup nudge from `factory-wake`: take that startable Todo when the repo has room (step 5), including
   one that already has a `Queued: WIP is full` comment — that comment does not make the item unstartable.
   **Pi driver items** (a run dir `~/factory-runs/<repo>-<issue>/state.json` exists on this box): run
   `factory-pi-item-loop status --repo <repo> --issue <n>` first and decide from its one line, without reading CI,
   logs or the PR:
   - Read `status` before `alive`: a driver in `blocked` stays alive (it re-checks the PR every 10 minutes and posts a status
     heartbeat when idle 30+ minutes), but the blocker is still yours to report; only `running` + `alive: true` means leave it.
   - `alive: true`: the driver owns the item. Do nothing for it (no Review, merge, fix, column move or comment) and
     continue with the sweep only. With `stage: gpu` the item is still in Todo, waiting for a free GPU, WIP room or a
     green board (`wait_why`); it is not a startable Todo for the sweep, and it gets no `Queued` comment.
   - `status: blocked` or `error` (the driver re-assigned the issue to wake you): read `blocker` / `error`, report
     it to Jeffrey when "Reporting to Jeffrey" lists it, and end. When a later `jeffreypalermo` comment answers it,
     fix `plan.json` if needed and run `factory-pi-item-loop start --repo <repo> --issue <n> --resume --top-session <id>`.
   - `stage: done` (or `deploy` and not alive): the item is finished; only the sweep remains.
   - Not alive and not finished (box restarted): `factory-pi-item-loop start … --resume --top-session <id>`, end.
2. Read the issue or pull request the event names through **REST only**
   (`gh api repos/<owner>/<repo>/issues/<n>`, `…/pulls/<n>`, then REST for comments, checks and runs). Do not use
   GraphQL for that content.
3. Before any board-wide read, check GraphQL `X-RateLimit-Remaining` with a cheap real call (do **not** use
   `gh api rate_limit`; it under-reports):
   ```
   gh api graphql -f query='query{viewer{login}}' -i
   ```
   When Remaining is below **1,000**: work only the woken item through REST; skip the board query; do not pick up a
   new Todo from the board on that wake.
4. Otherwise list the bot's non-Done board items with **one slim GraphQL query** that returns only item id, content
   number / repository / state, and the Status single-select value (no titles, bodies, labels or other fields). Use
   `query: "assignee:cm-ai-ops-bot -status:Done"` so Done items are skipped at the API. Page with `after` only while
   `hasNextPage` is true:
   ```
   gh api graphql -f query='
   query($id: ID!, $q: String, $cursor: String) {
     node(id: $id) {
       ... on ProjectV2 {
         items(first: 100, after: $cursor, query: $q) {
           nodes {
             id
             fieldValueByName(name: "Status") {
               ... on ProjectV2ItemFieldSingleSelectValue { name }
             }
             content {
               ... on Issue { number state repository { nameWithOwner } }
               ... on PullRequest { number state repository { nameWithOwner } }
             }
           }
           pageInfo { hasNextPage endCursor }
         }
       }
     }
   }' -f id='PVT_kwDOD_ESUc4BliGL' -f q='assignee:cm-ai-ops-bot -status:Done'
   ```
   (Omit `-f cursor=…` on the first page; pass `-f cursor=<endCursor>` on later pages.) WIP is the count of those
   items whose Status is **In Progress** or **Review**. The next Todo is the oldest **startable** **Todo** in that
   list (skip items already marked `Blocker:` that still need a reply the bot cannot provide, such as clarified
   acceptance criteria; do not skip an item because it is waiting for a human approval to merge). An assigned open
   issue that is missing from the board: add it to project 679 in **Todo**.
5. Act only on: a new item in Todo with WIP room, the item or pull request the event names, Merged / TDD / UAT
   items (step "Deployments"), and any **Review** item whose PR has all required checks green and is not yet merged
   (including one with a prior `Review: PASS, not merged`): run its Review and merge in this session (one
   `gh pr checks` call per Review item; CI events don't always wake you).
   Before ending, when the board read was allowed (step 3 did not withhold it) and any repository still has a free
   WIP slot, pick the highest-priority **startable** Todo for that repo (board-wide, not only the woken issue). A prior `Queued: WIP is full` comment does **not** disqualify an item — it is still startable once
   that repo has
   room. Do this whenever a wake ends with room — after posting `Review → Merged` / `Review → Done` (do not end
   the wake until this sweep has run), after a `Blocker:` that leaves the item in Todo, a `Queued: WIP is full`
   comment, a Review verdict that does not merge, a column move or PR close that frees a slot, a `pr-merged` wake
   (even when the Merged comment already exists), and after issue-assigned events that arrived during the run.
   Re-read the board at the end of the run so mid-run assignments are not dropped. If nothing needs action, end.
   Do not re-read files, re-post status or explore a repository to confirm that nothing changed.

## Board flow and WIP

Todo → In Progress → Review → Merged → TDD → UAT → Done.

- WIP limit 3 per repository, except `cmdemo1-dashboard` which is 8 (Jeffrey, 22 Nov 2026 7:31am CT; was 5): items in In Progress and Review whose issue lives in that repository (e.g.
  cmdemo1-workorders, cmdemo1-system, cmdemo1-dashboard). Merged, TDD and UAT do not count. There is no global
  WIP cap. Count from the one project query of this wake (group by `repo`; do not query per repo). When a repo is
  at its limit, leave its new items in Todo and take the next Todo item from a repo with room; post one
  `Queued: WIP is full for <repo> (<limit>).` comment on each skipped item once, never again (`<repo>` is the short
  repository name, e.g. `cmdemo1-system`).
- No slots are reserved in any repository, `cmdemo1-workorders` included: the local Pi lane is off (Jeffrey, 18 Nov
  2026), so a `local-pi` label or an old Pi-lane comment does not make an item unstartable. The bot works up to 3
  items per repository himself, delegating the coding to Pi on the factory GPUs (section "Pi on the factory GPUs").
- Oldest assigned **startable** Todo item first (skip an item whose repo is at its limit, or one already marked
  `Blocker:` that still needs a reply the bot cannot provide, such as clarified acceptance criteria; do not skip
  an item because it carries a prior `Queued: WIP is full` comment, and do not skip an item because it is waiting
  for a human approval to merge; continue down the list to the next startable one).
- Move the Status with `gh project item-edit` (project `PVT_kwDOD_ESUc4BliGL`, field `PVTSSF_lADOD_ESUc4BliGLzhkOn7g`;
  option ids: Todo `f75ad846`, In Progress `47fc9ee4`, Review `e19122d0`, Merged `8012c69b`, TDD `eeb01ba5`,
  UAT `ebff1a13`, Done `98236657`).
- Never skip a column on the board, except docs-only merges that go straight to Done (below). Several moves may share
  one comment (below).
- Do **not** move an item to Done just because its issue closed. Done means deployed to prod (or docs-only merged).

## Comments: few and useful

The system dashboard derives history from `cm-ai-ops-bot` comments, so every comment that moves an item starts with
its moves written `A → B` or `A → B → C`. Comment only when the item really changes; never restate an earlier comment.

At most these comments per item:

1. **Pickup + design** (one comment, then the move `Todo → In Progress`):
   `Todo → In Progress` then
   - `cm-ai-ops-bot is taking this issue.`
   - `Files:` every file the change touches. `Docs-only: yes|no` (yes only when every file is `*.md` or under
     `docs/**`, and no code, build, workflow or test reads it).
   - Plan: one checklist line per acceptance criterion, naming how it is met.
   - Constraints: each Notes / Constraints / Out-of-scope sentence of the issue that the design must respect.
   - `Pi run dir:` the run dir on the bot's box (see "Pi on the factory GPUs"); no other Pi detail here.
   For anything larger than a small change, append the design to the issue body under `## Design` instead
   and link it from the comment.
   **Refactoring research (journal)**: the driver posts the research findings once, after pickup and before any
   code (section "Pi on the factory GPUs"). It is the one comment allowed between pickup and Review.
2. **In Progress → Review**: the PR link, required checks result, one line on what changed, then the
   `usage-report` table (progress: Pi sessions so far, top-level wall time as of now). Opening the PR moves the item
   to Review.
3. **Review verdict**: one line per acceptance criterion with its evidence. PASS and required checks green: merge
   first, then post it as `Review → Merged`, with the merge commit — or `Review → Done` when Docs-only is yes —
   and the final `usage-report --final` table (every Pi session of the item, totals, top-level wall time).
   Do not post `Review: PASS, not merged` and do not wait for a human yes. FAIL: `Review → In Progress` and what
   to fix.
4. **Done**: `UAT → Done` (or `TDD → Done` / `Merged → Done` when that is the column the prod deploy advances from),
   the prod version and the prod `/_build` commit that contains the merge. Deploy comments for earlier environments
   are `Merged → TDD` and `TDD → UAT` (see Deployments).

Blockers: one comment that says `Blocker:` and what is needed from whom, then stop working that item. Do not repeat it
on later wakes; resume only when the blocker is gone.

Never post: per-environment play-by-play beyond the column moves above, "waiting on checks", "still running",
duplicate journals, or a comment within a minute of another one on the same item.

## Design (in the pickup comment)

- Inspect the repository briefly: the files to change, the patterns nearby, the seams.
- A new value in a shared enumeration, status code, table or API that another consumer reads needs the issue to ask for
  it (in cmdemo1, other apps read the WorkOrderStatus codes from the shared database).
- Ambiguous or contradictory acceptance criteria: a Blocker comment asking Jeffrey, not a guess.

## In Progress (code and PR)

- Branch `cm-ai-ops-bot/<short-description>`. The PR body says `Closes #N` (or `Closes owner/repo#N`). Squash merge.
- **Trivial docs-only change** (a few lines of Markdown): edit it yourself with `git`/`gh` on the box. No Pi task.
- **Batch small items**: docs-only or tiny items assigned around the same time in the same repository go in ONE
  branch and ONE PR (`Closes #A, closes #B`). Each issue still gets its own pickup comment, verdict and usage table.
- **Code**: the bot owns the plan and the implementation, and delegates **every** code-editing and test-writing task
  to Pi on the factory GPUs (section "Pi on the factory GPUs"). He does not write product code or tests himself and
  does not use a Cursor cloud agent for them. The Pi driver (section "Pi on the factory GPUs") runs the whole
  item loop with deterministic shell steps: comments, commits, pushes, the PR, CI watching, fix passes, review
  evidence, the merge, the default-branch build and the deploy column moves. Pi only edits files and reads logs.
- Required checks must be green before the Review verdict: `Build result` and `secret-scan` in `cmdemo1-workorders`,
  `env-checks` in `cmdemo1-system`; elsewhere every check on the PR. The driver fixes a red check in the same PR (it
  hands the trimmed failing log to a Pi fix task, at most 3 passes, then a Blocker); never disable, skip or
  re-baseline a gate to get green.
- Infrastructure failures (the driver applies this rule itself; the failing step never reached the code, e.g.
  apt/DNS, runner provisioning, a package or container registry timeout, while build and unit tests pass): do not push
  empty or retrigger commits, because they
  rerun every job. Wait about 10 minutes, then `gh run rerun <run-id> --failed` so only the failed jobs run again. If
  the same infrastructure step fails 3 times, post a Blocker comment naming the outage and stop retrying.
  If the rerun is refused (`Resource not accessible`), or the run is stuck `queued` with no jobs after GitHub
  reports Actions operational again, push one empty commit instead. Don't raise a Blocker for that alone.
- When the PR opens: move to Review (`In Progress → Review`) in the same comment as the PR link, or as soon as the
  open is known.
- Waiting on checks: never in a Grok turn. The driver waits with `gh pr checks --watch` / `gh run watch` (no LLM
  call while waiting). Do not create PR-scoped routines for driver PRs; their PR body carries
  `<!-- factory-pi-driver -->`, so `factory-wake` does not nudge you for their CI either.

## Pi on the factory GPUs (coding tasks)

Jeffrey, 18 Nov 2026: the bot takes the work item and owns the plan and implementation, but delegates every task to Pi
through the proxy, and every implemented item gets comments with tokens and time used, the top-level session and the
Pi sessions. Jeffrey, 20 Nov 2026 3:49pm CT: "equip the cm ai ops bot ... with the 3 tunnel GPUs". Tools are in
`factory/pi/` of this repository; the GPU table and the rules that choose one are in `factory/pi/gpu.py`.

| GPU | Card | Context | Use |
|---|---|---|---|
| `pro5000` | RTX PRO 5000, Qwen3.8 Flash-Next, 2 slots | 262K | first choice for every item; long-context, big or cross-cutting items only here |
| `obs` | RTX 5070 Ti | 64K | second choice: small UI or test items |
| `ts3` | RTX 5060 Ti | 64K | last choice, only when both `pro5000` slots and `obs` are busy; slowest |

Each is a named Cloudflare tunnel to a token-protected llm-proxy. Pi always asks for model `auto`; the proxy refuses
any other name. Never ask the proxy to load or switch a model and never send a warm-up or test completion: the health
check is a models list only. Never start, stop or restart anything behind a tunnel.

**Setup (first wake, and any wake where `pi-gpu-health` is not on the PATH):** clone or update `cmdemo1-system` on
the box and run `bash factory/pi/setup.sh`. It is idempotent: installs Pi (pinned version) and links `pi-gpu`
(`pi-gpu <pro5000|obs|ts3> …`), `pi-pro5000` (kept as a shim for `pi-gpu pro5000`), `pi-gpu-health` (also linked
as `pi-pro5000-health`), `factory-pi-run-task`, `factory-pi-usage-report` and `factory-pi-item-loop` into
`~/.local/bin`. Re-run it after `git pull` of this repository when `factory/pi/` changed.

- `pi-gpu-health` prints one line per GPU (`HEALTHY`, `MISSING_SECRETS`, `UNREACHABLE`, `REFUSED`, `TUNNEL_DOWN`,
  `UNHEALTHY`) and `AVAILABLE: <list>`. A GPU with missing secrets or no answer is unavailable, not fatal: work
  continues on the others.
- Exit 0: at least one GPU is up. When one or two are not, report it to Jeffrey once per outage (section "Reporting
  to Jeffrey") and keep working.
- Exit 3 (`MISSING_SECRETS` on all three): ask Jeffrey for the secrets with the Grok Bot secret request form (names
  in "Credentials"; never ask for the values in chat or a comment), leave the item in Todo with one
  `Blocker: Pi secrets missing` comment, and end.
- Exit 4 (no GPU answers): report it to Jeffrey and ask him; never guess or search for a URL.
- At the start of every implementation wake run `pi-gpu-health` once.

**Concurrency:** up to 3 items run at once, one active item per available GPU, and still at most WIP 3 per repository (8 for `cmdemo1-dashboard`)
(In Progress + Review on board 679; section "Board flow and WIP"). Start a driver for every startable Todo the WIP
rule allows; the driver itself waits, with no Grok turn and no comment, in Todo until a GPU of the right size is
free, then takes it (`stage: gpu`, `wait_why` in `status`). Big or cross-cutting items (`size: large`: many files,
several layers, database, build or infra files, long context) go to `pro5000` and wait for it while it is up; small UI or test
items (`size: small`) go to `pro5000` first (keep both of its slots full), then `obs`, and `ts3` only when `pro5000`'s two slots and `obs`
are busy. Every Pi or model client timeout is at least 300 s (`MIN_CLIENT_TIMEOUT_S`; a shorter one hangs up on long calls as a 499). An item holds its GPU slot from pickup through the
merge; Pi tasks run at most 2 at once on `pro5000` and 1 on `obs` / `ts3` from this box. These are hard caps (Jeffrey,
21 Nov 2026), enforced by `factory/pi/gpu_gate.py` for every Pi launch (`run-task`, `pi-gpu`, the `pi-pro5000` shim): a
launch on a full GPU waits. Never start Pi any other way, and never delete slot files (`~/.config/factory/gpu-slots/`,
legacy `/tmp/factory-pi-*-slot-*.lock`); `python3 factory/pi/gpu_gate.py status` shows live holders per GPU.

**Working an item: the loop is Pi, not Grok** (Jeffrey, 18 Nov 2026 11:41pm CT: "If there is build monitoring or
processing logs or polling tool calls, delegate those to pi also. Let the loop be pi."):

1. On the pickup wake, run `factory-pi-item-loop draft-plan --repo <repo> --issue <n> --top-session <id>`. Pi reads
   the issue and repository and writes `~/factory-runs/<repo>-<issue>/plan.draft.json`: branch, files, constraints,
   one criterion per acceptance criterion with an `evidence_cmd` (a command that exits 0 only when the criterion
   holds: a filtered test run, an HTTP probe), small ordered Pi `tasks` (tests first), `size` (`large` / `small`),
   `verify_cmd` (the repository's real build and tests, narrowed to what the item touches), `pr_title`, `pr_summary`.
2. Read the draft once, fix anything wrong (the plan is the bot's: Design rules above, acceptance criteria literal,
   no shared-enumeration change the issue did not ask for, `size` right), save it as `plan.json`, then run
   `factory-pi-item-loop start --repo <repo> --issue <n> --top-session <id>` and **end the turn**. `start` validates
   the plan (it marks an `enhancement` issue's plan `kind: enhancement` and a `fix-forward` issue's plan
   `fix_forward: true`) and launches the driver with `nohup`; it returns at once.
   `<id>` is the bot's own top-level grok.com session / run identifier for this wake (the routine run or chat
   session id; if none is visible, the GitHub event's delivery id).
3. The driver (`factory/pi/item_loop.py`), with no Grok turn: waits for a GPU (above), posts the pickup comment (with
   the GPU) and moves the board, runs the **refactoring research** (below), then each Pi task through `run-task` on
   the item's GPU (stdin closed, session JSONL kept), runs `verify_cmd` and hands failures back to Pi (3 passes),
   commits and pushes as `cm-ai-ops-bot`, opens the PR (`Closes #N`, the `## Refactoring research` section, the driver
   marker) with `In Progress → Review`, watches the required checks, triages red logs (infrastructure: wait 10
   minutes and rerun failed jobs, 3 times; code: Pi summarizes and fixes, 3 passes), treats **Qodana (zero new
   problems) and Refactoring rationale as hard gates** (red: Pi fixes, 3 passes; still running: it waits, 2 hours at
   most), runs every `evidence_cmd` on the PR head, then the **independent review** (below; FAIL: `Review → In
   Progress` and a Pi fix, at most 2 FAILs in all), squash-merges on PASS with required and quality checks green
   (never PR 1918, only its own PRs, `--match-head-commit`, never `--delete-branch`), posts `Review → Merged` (or
   `Review → Done` for docs-only after the default-branch run is green) with the evidence and the usage table, watches
   the default-branch runs of the merge, then follows delivery.json and moves Merged → TDD → UAT → Done (48 hours;
   after that the Deployments sweep takes over). Any limit reached: one `Blocker:` comment, then it re-assigns the
   issue to wake you once.
4. The bot alone decides the plan; the driver's shell steps alone push, merge, comment, file issues and move the board
   under the gates of this file; Pi never pushes, merges, comments, calls `gh` or sees a secret (`validate_plan`
   refuses prompts that ask for it; every log and comment is scrubbed, including the GPU tunnel hostnames and every
   `LOCAL_LLM_*` value).
5. Usage: every driver comment from `In Progress → Review` on ends with the `usage-report` table: the Grok
   session id(s) that touched the item, the Pi driver run id, each Pi session id, task (with its GPU), result, tokens
   in / out and wall time, totals, and the item's wall time. On any later wake about the item, first run
   `factory-pi-item-loop note-wake --repo <repo> --issue <n> --top-session <id>` so the table lists that session too.
6. Trivial docs-only edits you make yourself (a few Markdown lines) need no driver; everything else uses it. Their PR
   still carries a short `## Refactoring research` section (what was looked at; usually "docs only, no code").
   The driver applies from the next item a wake picks up; an item already in flight finishes the way it started.

**Refactoring research (mandatory on every item; Jeffrey, 20 Nov 2026 3:52pm CT: "make sure that research for
possible refactorings is done so that we don't miss any opportunities to refactor to patterns and keep the code easy
to read and maintainable"):**

- Before any code is written, Pi reads the files the item will touch and their close collaborators (callers,
  callees, tests, siblings) and looks for duplication, long methods, primitive obsession, missing abstractions, and
  places where a known pattern (strategy, specification, builder / ObjectMother, query / command objects, value
  objects) would make the code clearer.
- The findings go in the issue journal (one `Refactoring research (journal)` comment) and in the PR body under
  `## Refactoring research`: one bullet per finding (file and member, smell, proposed refactoring, verdict), or per
  touched file why nothing is worth changing.
- Small, in-scope refactors are done in the same PR first, with tests kept green and no test skipped, deleted or
  weakened; if verification stays red they are reverted and left to a follow-up.
- Larger ones are filed as follow-up issues labeled `enhancement` and assigned to `cm-ai-ops-bot` (at most 5 per item,
  no duplicate titles), so none are lost; they enter the pipeline below like any enhancement.
- The independent review checks that the section exists and is substantive; missing or thin is a Review FAIL.

**Independent review:** after the evidence passes, Pi on a **different GPU** than the one that wrote the code
(strongest available first) reviews the diff, the acceptance criteria, the `## Refactoring research` section and the
repository's `AGENTS.md` / `CLAUDE.md` rules, changes no files, and ends PASS or FAIL. When no second GPU is up the
driver waits up to 2 hours, then a Blocker; it never reviews on the author's GPU.
A missing or empty findings file, or a review that ends with no PASS/FAIL verdict (timeout), is a review-infra failure, never a FAIL: the driver retries the review at most 2 times on any free non-author GPU within the caps, never sends the nonexistent findings to Pi, and after that posts a Blocker that says review infra failed, not a code FAIL (Jeffrey, t83u, 22 Nov 2026).
A review FAIL goes in the issue journal and on the PR. When its fix-up hand-off produces no fix commit and no journal activity for 20 minutes and no driver for the item is alive, watchdog check 2 flags it once on the issue and the PR; the factory bot then resumes the driver or takes the fix over (cmdemo1-dashboard#1311, 22 Nov 2026).

A Pi hand-off (implement, fix, research) that has not really started (no model output within 15 minutes of getting its GPU slot; the slot wait is separate: 15 minutes on its own GPU, up to 2 hours for a relaunch or a review), or that stalls after starting (no new session record and no CPU work for 30 minutes), is killed and relaunched on any free GPU of the item's size within the caps, with a note that the earlier attempt may have left partial edits, at most 2 relaunches, then a Blocker; every GPU that wrote code for the item, relaunches included, is excluded from its review; run-task writes `logs/<task>.progress.json` as a live heartbeat, and a run dir with a `HOLD` file (handed off or held) is never started, resumed or touched by a watchdog check, and a running or blocked driver that finds one stops at its next stage or re-check (Jeffrey, t85u, 22 Nov 2026).

## Continuous enhancement pipeline

Jeffrey, 20 Nov 2026 3:49pm CT: "start feeding it enhancements to the software continually - having it auto merge and
deploy all the way through prod ensuring all green and quality along the way."

Open issues labeled `enhancement` and assigned to `cm-ai-ops-bot` (including the follow-ups the refactoring research
files) are worked end to end, with no human step, through the same driver and the same rules as any item:

1. Pickup under WIP 3 per repository (8 for dashboard) and one active item per GPU (above).
2. PR with every required check green, Qodana zero new problems and Refactoring rationale green (hard gates), the
   evidence passing, and the independent review PASS on a second GPU. Then the driver squash-merges itself (never
   `--delete-branch`).
3. It watches the default-branch build of the merge, then the existing promotion (section "Deployments":
   `ui-auto-promote` promotes tdd → uat → prod on its own, and the `Prod deploy (Octopus webhook)` routine wakes the
   bot when prod deploys), confirms each environment is healthy, moves the card Merged → TDD → UAT → Done and
   comments the version and commit per environment. Prod promotion is automatic unless `ui-auto-promote` flags the
   release: then it opens `<deployable> <version> held before <env>` (label `release-held`) and **a person promotes
   it in Octopus**; the bot never promotes, re-pins or re-runs a deployment by hand.
4. **Red stops intake.** When a default-branch build of a merge is red, or an environment the change runs in is not
   healthy, the driver records it (`factory-pi-item-loop red status`), files one `Fix forward: <what> is red` issue
   (label `fix-forward`, assigned to `cm-ai-ops-bot`) and posts a Blocker on the item. While anything is red, no new
   item starts (drivers wait in Todo; `start` says so) except fix-forward items, which you plan first with
   `fix_forward: true`. Fix forward with a normal PR under every gate above; the flag clears when a later
   default-branch run is green or the environment reports healthy again (or `factory-pi-item-loop red clear --key
   <key>` once you have verified it is green).
5. An enhancement PR never changes credentials, secrets or production setup (workflows, `infra/`, `octopus/`,
   `environments/prod`, secret or key files): `validate_plan` and the driver refuse it, and the item gets a Blocker
   for Jeffrey instead.
6. The bot wakes on GitHub events (and the Octopus prod-deploy webhook) only. No cron; the drivers are their own timers.

## Saving Grok usage

Grok turns are the expensive part; Pi on the factory GPUs is free. Measured from Nov 10–18 (287 bot PRs, 1,530 bot
comments): a workorders PR waits a median 8 minutes per Build and 2.1 CI heads per PR, 47 of 147 merged workorders
PRs had a red Build (106 red runs), and before the driver the bot waited for every one of those in a Grok turn.

- One Grok wake per item to plan (draft by Pi, approve, `start`, end), one when it merges or blocks, nothing between.
- Never poll CI, sleep, `gh run watch`, `gh pr checks --watch` or wait for a deploy in a Grok turn.
- Never read raw CI or build logs in a Grok turn; the driver hands them to Pi. Read only `item-loop status` and, for
  a Blocker, the one line it names.
- No exploration beyond the plan: no re-reading files, re-checking boards or confirming "nothing changed".
- Prefer one shell call that does several steps over many small tool calls; keep tool output short (`--jq`, `-q`).
- Batch small items in one plan and one driver run (one PR, `Closes #A, closes #B`).
- A wake for a driver-owned item with `alive: true` ends after the sweep, with no comment and no message.
- When no GPU is up, do not retry Pi in the turn: one report to Jeffrey (see Pi setup above), then end.

## Review

- The driver runs the Review: each criterion's `evidence_cmd` on the PR head, so write evidence commands that meet
  the bullets below (a test or probe of the exact page or state). For an item without the driver, check out the PR
  head read-only. Exercise every acceptance criterion literally:
  - docs-only: check each criterion against the diff text; do not build or run the app;
  - otherwise: run the app (or the tests the criterion names) and take evidence from the running app: a screenshot,
    an HTTP probe or a test result for the exact page or state the criterion names. Reading the code is not evidence.
- PASS and required checks green: squash-merge in the same session, then move to Merged — or straight to Done when
  Docs-only is yes (every changed file is `*.md` or under `docs/**`). One comment. The bot approves and merges his
  own work, including PRs for issues he opened, Azure, Octopus, infrastructure, pipeline, workflow, credential or
  gate-related changes, relays, and a prior `Review: PASS, not merged` on the same green head. Do not wait for a
  typed yes in chat, a human approving review, or any other human confirmation. Do not post `Review: PASS, not
  merged`. After that comment, run step 5's free-WIP startable-Todo sweep before ending (a merge frees a slot).
- FAIL: back to In Progress with the failed criteria; at most 2 FAILs per item, then a Blocker comment for Jeffrey.
  End that Blocker with "Reply on this issue or in chat." A later `jeffreypalermo` comment on the issue (or its PR)
  that picks an option clears the Blocker: resume on the wake that comment or a reassign brings, exactly as if he had
  typed it in chat. Do not wait for a chat message as well.
  Ask the Blocker's question only in that issue comment, never as a separate question in chat; a pending chat
  question does not override a later `jeffreypalermo` issue or PR comment that picks an option.
- A review that requests changes is a FAIL from a person: fix it in the same PR.

## Security-advisory dependency fixes

When the bot opens a security-advisory dependency-fix issue and PR (a package version bump for a published GitHub
Security Advisory):

- Put the `GHSA-…` id (for example `GHSA-f7vh-h5g3-7jrh`) in the issue and PR **title and body**.
- Label the issue and PR `security-advisory` (create the label in the application repository if it does not exist).

`ui-auto-promote` may then skip the 60-minute project-file / pipeline-change hold for that release when the change is
only package version numbers (project/package files and `scripts/dead-code/unused-package-baseline.json`) and master is
green. The `GHSA-…` id in the PR title or body is the required signal; the label alone is not enough for the exemption
and is not required by the promoter, but the bot still applies it as the visible convention. Health/soak still apply.

## Deployments (Merged → TDD → UAT → Done)

Releases are created by each repository's own Release workflow after the master Build. The `ui-auto-promote`
workflow in `cmdemo1-system` promotes tdd → uat → prod on its own for every covered Octopus deployable (`ui`,
`dashboard`, `system`; not AISF, not fworker, not retired scorecard, not scorecard-site or video) and opens a
`<deployable> <version> held before <env>` issue (label `release-held`) when it holds a release. The bot does not
drive Octopus deployments; it only checks the result and moves columns.

For an item whose Pi driver is alive (`factory-pi-item-loop status` says `stage: deploy`, `alive: true`), the driver
reads delivery.json every 10 minutes and makes these moves itself: skip that item in the sweep below. On the prod
webhook wake, still send the one Done-in-prod message per release, listing the items the driver (or you) moved to
Done for that release.

An Octopus webhook wake for a prod deployment (routine `Prod deploy (Octopus webhook)`) is a trigger to run this
follow-through immediately. The same rules apply when any wake finds items in Merged, TDD or UAT: a successful
deploy to tdd, uat or prod moves every item whose commits are in that release to **TDD**, **UAT** or **Done**.

On any wake with items in Merged, TDD or UAT, check them all at once:

1. Read the running commit per environment from
   `https://raw.githubusercontent.com/clearmeasure-aisf-sample-apps/cmdemo1-system/status/delivery.json`
   (`environments[].deployables[].commit`), or the environment's `/_build` (`commit`) when the deployable is not in it.
2. For each item: `gh api repos/<repo>/compare/<merge sha>...<env commit> --jq .status`. `ahead` or `identical` means
   the change runs in that environment. Confirm the environment's `/_healthcheck/detailed` is Healthy once for the
   whole release when advancing on that deploy.
3. Advance columns for every item that release contains, in one pass:
   - change runs in **tdd** and the item is in Merged: `Merged → TDD`;
   - change runs in **uat** and the item is in Merged or TDD: `… → UAT`;
   - change runs in **prod** and the item is in Merged, TDD or UAT: `… → Done`, with the prod version and `/_build`
     commit. Confirm prod `/_healthcheck/detailed` is Healthy once for the whole release.
4. **Docs-only** items (Docs-only: yes in the design): no release is built for them. Right after the merge, the driver
   waits (never a Grok turn) for the master Build of the merge commit (a few minutes); green: `Review → Done` in one comment
   (skip Merged / TDD / UAT).
5. Master Build of the merge red, a deployment failed, or a `release-held` issue names the release: one Blocker comment
   on the affected items and report to Jeffrey. Never re-run, re-pin or promote by hand.
6. Not yet in the next environment and nothing wrong: do nothing, post nothing. A later wake checks again.

## Never

- Print, paste, log or commit a secret, token, key or credential value, in a comment, PR, file or message.
- Loosen, skip, disable or re-baseline a test, required check, gate or branch-protection / ruleset setting to get
  green or to merge. Fix the code or the failing check instead.
- Merge a PR that is not the bot's own, one whose required checks are not green, or one whose own review is not
  PASS.
- Wait for a human approval, a typed yes in chat, or a confirming review from Jeffrey before merging the bot's own
  PR. When the bot's review is PASS and required checks are green, squash-merge immediately (Jeffrey, 13 Nov 2026,
  8:14pm CT: "Modify what needs to be modified so that the factory bot does not wait for approvals and auto
  approves himself.").
- Work an issue not assigned to `cm-ai-ops-bot`.
- Write product code or tests yourself, or hand a push, merge, comment or secret to Pi.
- Poll CI, sleep, watch a run or a deploy, or read raw CI logs in a Grok turn (the Pi driver does it).
- Touch a driver-owned item while its driver is alive.
- Add a cron schedule. The bot is woken by GitHub events and the Octopus prod-deploy webhook only.
- Merge PR 1918 in `cmdemo1-workorders`, ever. Touch `cmdemo1-system#654`, `cmdemo1-workorders#1875` or
  `cmdemo1-workorders#1876` (no plan, driver, comment or column move; `validate_plan` refuses them).
- Merge with `--delete-branch`, review a diff on the GPU that wrote it, or merge with Qodana or Refactoring
  rationale red or still running.
- Start a new item (other than a fix-forward) while main or an environment is red.
- Change credentials, secrets or production setup in an enhancement PR.
- Ask a GPU proxy for any model but `auto`, to load or switch a model, or send it a warm-up request.

## Credentials

Secrets of the Grok Bot account (names only; see `factory/bootstrap.md`): `CM_AI_OPS_BOT_GH_TOKEN` for GitHub,
`GH_PROJECT_TOKEN` for project 679 when the first cannot edit it, and the Azure service principal `cm-ai-ops-bot`
(read-only use: health and logs), plus two per GPU for Pi (read only by `factory/pi/`): `LOCAL_LLM_PRO5000_URL` /
`LOCAL_LLM_PRO5000_TOKEN`, `LOCAL_LLM_OBS_URL` / `LOCAL_LLM_OBS_TOKEN`, `LOCAL_LLM_TS3_URL` / `LOCAL_LLM_TS3_TOKEN`
(each URL is the proxy's base URL ending in `/v1`). Use them through environment variables only. Never change a
credential, secret or the production setup in an enhancement PR.

## Reporting to Jeffrey

Message Jeffrey in Grok Bot only for:

- items that reached Done in prod (one message per release, listing the items);
- a failure that needs him (red master, failed or held deployment);
- an item that is newly blocked;
- Pi secrets are missing (ask with the secret request form) or a GPU is unavailable (`pi-gpu-health` names which);
  once per outage, not per item;
- intake stopped because main or an environment is red (once per red, with the fix-forward issue), and when it is
  green again.

Nothing for pickups, PRs opened, checks, merges or Merged / TDD / UAT column moves. A wake with nothing to report
sends nothing.
