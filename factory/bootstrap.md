# Connect a Grok Bot account as the factory bot

Everything the bot does is in `factory/operating-instructions.md`. The account holds only secrets, connectors and two
routines whose prompts point at that file, so a new account is connected in a few minutes and a change to how the bot
works is a pull request here, not an edit in grok.com.

## 1. Secrets (names only; values never go in a repository, a comment or a chat)

| Secret name in the Grok Bot account | What it is | Where the value comes from |
|---|---|---|
| `CM_AI_OPS_BOT_GH_TOKEN` | GitHub token of user `cm-ai-ops-bot`: repo contents, pull requests, issues, Actions read on the `cmdemo1-*` repositories | Jeffrey creates it as `cm-ai-ops-bot` |
| `GH_PROJECT_TOKEN` | Token that can edit organization project 679 (fallback when the first cannot) | Jeffrey |
| Azure service principal `cm-ai-ops-bot` (client id, tenant id, client secret) | Contributor on `rg-cmdemo1-nonprod` and `rg-cmdemo1-prod`; the bot uses it read-only (health, logs) | Entra ID app registration `cm-ai-ops-bot` |
| Octopus API key (optional) | Octopus user Users-922, team Teams-423, space `Spaces-355`; read-only use. Not needed for the normal flow, which reads `status/delivery.json` | The system's Key Vault; Octopus lets no AI identity mint its own key, so a person makes it |

Sign `gh` in on the bot's box with `CM_AI_OPS_BOT_GH_TOKEN` (`gh auth login --with-token`), and use
`cm-ai-ops-bot <jeffrey+ai-ops@clear-measure.com>` as the git author.

## 2. Connectors

- GitHub (the account's Cursor connection): routine listeners fire through it.
- Cursor cloud agents: for coding work in the application repositories.

## 3. Routines

Two routines with the same prompt. GitHub listeners take one repository each and a routine holds at most 8 listeners,
so the repositories are split across two routines. No cron: the bot is woken by GitHub events only.

Each listener (one per repository) has these events, no `userAllowlist`:

- `issue-assigned`: new work (the bot ends at once when the assignee is not `cm-ai-ops-bot`).
- `review-changes-requested`: a person asks for changes on a bot PR.
- `pr-merged`: starts or advances release follow-through (any author's merge is a cheap moment to check Release Queue).

Not subscribed, on purpose: `ci-passed` / `ci-failed` on the default branch (they fired on every master run, hundreds a
day, almost always with nothing to do), `pr-opened` (the bot opens its own PRs), `review-approved` (no approval is
required). CI on a bot PR is followed by a PR-scoped routine the bot creates for that PR (`ci-passed`, `ci-failed`,
`review-changes-requested`, `pr-merged`, `pr-closed`), which deletes itself when the PR merges or closes.

**Routine 1: `Factory bot: workorders, system, dashboard, scorecard-site`**

| Repository | Events |
|---|---|
| `clearmeasure-aisf-sample-apps/cmdemo1-workorders` | issue-assigned, review-changes-requested, pr-merged |
| `clearmeasure-aisf-sample-apps/cmdemo1-system` | issue-assigned, review-changes-requested, pr-merged |
| `clearmeasure-aisf-sample-apps/cmdemo1-dashboard` | issue-assigned, review-changes-requested, pr-merged |
| `clearmeasure-aisf-sample-apps/cmdemo1-scorecard-site` | issue-assigned, review-changes-requested, pr-merged |

**Routine 2: `Factory bot: scorecard, video`**

| Repository | Events |
|---|---|
| `clearmeasure-aisf-sample-apps/cmdemo1-scorecard` | issue-assigned, review-changes-requested, pr-merged |
| `clearmeasure-aisf-sample-apps/cmdemo1-video` | issue-assigned, review-changes-requested, pr-merged |

**Prompt of both routines** (exactly):

```
You are the cmdemo1 factory bot (GitHub user cm-ai-ops-bot). Read factory/operating-instructions.md from the main
branch of clearmeasure-aisf-sample-apps/cmdemo1-system (gh api repos/clearmeasure-aisf-sample-apps/cmdemo1-system/contents/factory/operating-instructions.md -H "Accept: application/vnd.github.raw")
and follow it for the GitHub event that woke you. If the event needs no action, end without commenting or messaging.
Report to Jeffrey Palermo in this chat only for what that file's "Reporting to Jeffrey" section lists; otherwise send
nothing.
```

To add a repository: add a listener with the same three events to a routine with room (or a third routine with the
same prompt).

## 4. Check it works

1. Assign a small docs-only test issue in `cmdemo1-workorders` to `cm-ai-ops-bot`.
2. Expect: one pickup comment with the moves `Todo → In Progress → Technical Design → Development`, a PR, then a
   single `Functional Testing → Release Queue → Done` comment, and the board item in Done.
3. Assign an issue to someone else: the bot wakes, posts nothing and ends.

## Known gap

Release Queue items move to Done on the bot's next wake after prod has the change (an assignment, a review or any
merge in these repositories), not the moment prod deploys. If that lag matters, the event-driven fix is an Octopus
subscription on cmdemo1-ui prod deployments that POSTs to a third routine with a webhook trigger and the same prompt;
that is an Octopus change and needs Jeffrey's approval.
