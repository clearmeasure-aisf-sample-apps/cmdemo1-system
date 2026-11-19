# factory/

Version-controlled instructions for the cmdemo1 factory bot: the Grok Bot account that works issues assigned to GitHub
user `cm-ai-ops-bot` across the `cmdemo1-*` repositories on organization project 679.

| File | For |
|---|---|
| [operating-instructions.md](operating-instructions.md) | What the bot does on every wake: scope, board flow, WIP, comments, releases, reporting. Read by the bot each wake; keep it short. |
| [pi/](pi/) | `setup.sh` (installs Pi and the `pi-pro5000` wrapper on the bot's box), `health.sh`, `run-task` (one Pi task, usage recorded), `usage-report` (tokens-and-time table for the issue). No secret values; they come from the account's secrets. |
| [bootstrap.md](bootstrap.md) | Connecting a new Grok Bot account: secrets (names only), connectors, the three routines and their exact triggers and prompts. |

How to write code in an application repository is not here: it is in that repository's `AGENTS.md` and `CLAUDE.md`,
which any agent, local or cloud, reads. Change the bot's behavior with a pull request to this folder; the routines'
prompts only point here and do not change.

Nothing here deploys: `system.yml` ignores `**/*.md` and `factory/**`, so merging a change here builds no release.
