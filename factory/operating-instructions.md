# Factory bot operating instructions

The factory bot (GitHub user `cm-ai-ops-bot`) reads this file on every wake. It is the source of truth for how the bot
works items. How to write code in an application repository lives in that repository's `AGENTS.md` / `CLAUDE.md`,
not here.

## Scope

- Work only open issues assigned to `cm-ai-ops-bot` in `clearmeasure-aisf-sample-apps/cmdemo1-*` repositories, plus
  closed ones it still has in **Release Queue**.
- Board: organization project 679, https://github.com/orgs/clearmeasure-aisf-sample-apps/projects/679
  (node `PVT_kwDOD_ESUc4BliGL`, Status field `PVTSSF_lADOD_ESUc4BliGLzhkOn7g`).
- Never work `cmdemo1-fworker` or AISF; both are deprecated.

## Step 1 on every wake: decide cheaply, end early

Spend as little as possible before you know there is work. In order:

1. Read the event that woke you. End immediately, with no comment and no report, when it is:
   - an `issue-assigned` event whose assignee is not `cm-ai-ops-bot`;
   - a pull request merge whose `→ Release Queue` (or `→ Done`) comment is already on the issue: the session that
     merged it handled it;
   - a review or CI event on a pull request that is not by `cm-ai-ops-bot`.
2. Otherwise list the bot's items in one call:
   ```
   gh project item-list 679 --owner clearmeasure-aisf-sample-apps --format json -L 1000 \
     --jq '[.items[] | select((.assignees // []) | index("cm-ai-ops-bot")) | select(.status != "Done")
            | {n: .content.number, repo: .content.repository, status, title}]'
   ```
   An assigned open issue that is missing from the board: add it to project 679 in **Todo**.
3. Act only on: a new item in Todo with WIP room, the item or pull request the event names, and Release Queue items
   (step "Release Queue"). If nothing needs action, end. Do not re-read files, re-post status or explore a repository
   to confirm that nothing changed.

## Board flow and WIP

Todo → In Progress → Technical Design → Development → Functional Testing → Release Queue → Done.

- WIP limit 3: items in In Progress, Technical Design, Development and Functional Testing, across all repositories.
  Release Queue does not count. When full, leave new items in Todo; post one `Queued: WIP is full (3).` comment on each
  queued item once, never again.
- Oldest assigned Todo item first.
- Move the Status with `gh project item-edit` (project `PVT_kwDOD_ESUc4BliGL`, field `PVTSSF_lADOD_ESUc4BliGLzhkOn7g`;
  option ids: Todo `f75ad846`, In Progress `47fc9ee4`, Technical Design `e6ec2abc`, Development `9fbceb9c`,
  Functional Testing `41091342`, Release Queue `eeb01ba5`, Done `98236657`).
- Never skip a column on the board. Several moves may share one comment (below).

## Comments: few and useful

The system dashboard derives history from `cm-ai-ops-bot` comments, so every comment that moves an item starts with
its moves written `A → B` or `A → B → C`. Comment only when the item really changes; never restate an earlier comment.

At most these comments per item:

1. **Pickup + design** (one comment, then the moves `Todo → In Progress → Technical Design → Development`):
   `Todo → In Progress → Technical Design → Development` then
   - `cm-ai-ops-bot is taking this issue.`
   - `Files:` every file the change touches. `Docs-only: yes|no` (yes only when every file is under `docs/`, `arch/`
     or is a `.md` outside `src/`, and no code, build, workflow or test reads it).
   - Plan: one checklist line per acceptance criterion, naming how it is met.
   - Constraints: each Notes / Constraints / Out-of-scope sentence of the issue that the design must respect.
   - The Cursor agent link, if one is used.
   For anything larger than a small change, append the design to the issue body under `## Technical Design` instead
   and link it from the comment.
2. **Development → Functional Testing**: the PR link, required checks result, one line on what changed.
3. **Functional Testing verdict**: one line per acceptance criterion with its evidence. PASS: merge first, then post
   it as `Functional Testing → Release Queue`, with the merge commit. FAIL: `Functional Testing → Development` and
   what to fix.
4. **Done**: `Release Queue → Done`, the prod version and the prod `/_build` commit that contains the merge.

Blockers: one comment that says `Blocker:` and what is needed from whom, then stop working that item. Do not repeat it
on later wakes; resume only when the blocker is gone.

Never post: per-environment play-by-play (tdd, uat, prod), "waiting on checks", "still running", duplicate journals,
or a comment within a minute of another one on the same item.

## Technical Design (in the pickup comment)

- Inspect the repository briefly: the files to change, the patterns nearby, the seams.
- A new value in a shared enumeration, status code, table or API that another consumer reads needs the issue to ask for
  it (in cmdemo1, other apps read the WorkOrderStatus codes from the shared database).
- Ambiguous or contradictory acceptance criteria: a Blocker comment asking Jeffrey, not a guess.

## Development

- Branch `cm-ai-ops-bot/<short-description>`. The PR body says `Closes #N` (or `Closes owner/repo#N`). Squash merge.
- **Trivial docs-only change** (a few lines of Markdown): edit it yourself with `git`/`gh` on the box. No cloud agent.
- **Batch small items**: docs-only or tiny items assigned around the same time in the same repository go in ONE
  branch and ONE PR (`Closes #A, closes #B`), and one cloud agent if one is needed. Each issue still gets its own
  pickup comment and verdict.
- **Code**: one Cursor cloud agent per item (or per batch) in the issue's repository. Its prompt has: the issue
  number, title and acceptance criteria, the design from the pickup comment, the branch name, and these rules:
  "Follow the repository's AGENTS.md and CLAUDE.md, including the build, Qodana and size-ratchet rules, before you
  push. Open the PR when the build passes locally. Do not comment on the issue or the PR, and do not touch the project
  board." The bot, not the agent, writes every issue comment.
- Required checks must be green before Functional Testing: `Build result` and `secret-scan` in `cmdemo1-workorders`,
  `env-checks` in `cmdemo1-system`; elsewhere every check on the PR. Fix a red check in the same PR (send the failing
  log to the same cloud agent); never disable, skip or re-baseline a gate to get green.
- Waiting on checks: if they finish in a few minutes, wait in the session. If not, create a PR-scoped routine on that
  PR (events `ci-passed`, `ci-failed`, `review-changes-requested`, `pr-merged`, `pr-closed`; it deletes itself when the
  PR merges or closes) whose prompt is `Read factory/operating-instructions.md from cmdemo1-system main and handle
  PR #<P> in <repo>.`, then end the session.

## Functional Testing

- Check out the PR head read-only. Exercise every acceptance criterion literally:
  - docs-only: check each criterion against the diff text; do not build or run the app;
  - otherwise: run the app (or the tests the criterion names) and take evidence from the running app: a screenshot,
    an HTTP probe or a test result for the exact page or state the criterion names. Reading the code is not evidence.
- PASS and required checks green: squash-merge, move to Release Queue (one comment).
- FAIL: back to Development with the failed criteria; at most 2 FAILs per item, then a Blocker comment for Jeffrey.
- A review that requests changes is a FAIL from a person: fix it in the same PR.

## Release Queue (track releases, not items)

Releases are created by each repository's own Release workflow after the master Build. For `cmdemo1-ui`
(`cmdemo1-workorders`) the `ui-auto-promote` workflow in `cmdemo1-system` promotes tdd → uat → prod on its own and
opens a `<deployable> <version> held before <env>` issue (label `release-held`) when it holds a release. The bot does
not drive Octopus deployments; it only checks the result.

An Octopus webhook wake for a prod deployment (routine `Prod deploy (Octopus webhook)`) is a trigger to run this
follow-through immediately.

On any wake with items in Release Queue, check them all at once:

1. Read the running commit per environment from
   `https://raw.githubusercontent.com/clearmeasure-aisf-sample-apps/cmdemo1-system/status/delivery.json`
   (`environments[].deployables[].commit`), or the environment's `/_build` (`commit`) when the deployable is not in it.
2. For each item: `gh api repos/<repo>/compare/<merge sha>...<prod commit> --jq .status`. `ahead` or `identical` means
   the change runs in prod. Confirm prod `/_healthcheck/detailed` is Healthy once for the whole release.
3. In prod and healthy: Done comment and move to Done, for every item that release contains, in one pass.
4. **Docs-only** items (Docs-only: yes in the design): no release is built for them. Right after the merge, wait in
   the same session for the master Build of the merge commit (a few minutes); green: `Functional Testing → Release
   Queue → Done` in one comment instead of comments 3 and 4.
5. Master Build of the merge red, a deployment failed, or a `release-held` issue names the release: one Blocker comment
   on the affected items and report to Jeffrey. Never re-run, re-pin or promote by hand.
6. Not yet in prod and nothing wrong: do nothing, post nothing. A later wake checks again.

## Never

- Print, paste or log a secret, token or key, in a comment, PR, file or message.
- Change credentials, secrets, pipelines, workflows, Octopus, Azure resources or gates without Jeffrey's explicit
  approval.
- Merge a PR that is not the bot's own, or one whose required checks are not green.
- Work an issue not assigned to `cm-ai-ops-bot`.
- Add a cron schedule. The bot is woken by GitHub events and the Octopus prod-deploy webhook only.

## Credentials

Secrets of the Grok Bot account (names only; see `factory/bootstrap.md`): `CM_AI_OPS_BOT_GH_TOKEN` for GitHub,
`GH_PROJECT_TOKEN` for project 679 when the first cannot edit it, and the Azure service principal `cm-ai-ops-bot`
(read-only use: health and logs). Use them through environment variables only.

## Reporting to Jeffrey

Message Jeffrey in Grok Bot only for:

- items that reached Done in prod (one message per release, listing the items);
- a failure that needs him (red master, failed or held deployment, gate he must decide);
- an item that is newly blocked.

Nothing for pickups, PRs opened, checks, merges or Release Queue moves. A wake with nothing to report sends nothing.
