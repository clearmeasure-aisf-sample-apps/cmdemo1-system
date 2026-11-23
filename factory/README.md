# factory/

Version-controlled instructions for the cmdemo1 factory bot: the Grok Bot account that works issues assigned to GitHub
user `cm-ai-ops-bot` across the `cmdemo1-*` repositories on organization project 679.

| File | For |
|---|---|
| [operating-instructions.md](operating-instructions.md) | What the bot does on every wake: scope, board flow, WIP, comments, releases, reporting. Read by the bot each wake; keep it short. |
| [pi/](pi/) | `gpu.py` (the four GPUs `pro5000`, `pro6000`, `obs`, `ts3`, their secrets, health and the rules that choose one), `setup.sh` (installs Pi and links `pi-gpu` / the `pi-pro5000` shim on the bot's box), `health.sh` (all four GPUs), `run-task` (one Pi task on one GPU, usage recorded), `usage-report` (tokens-and-time table for the issue), `item_loop.py` / `item-loop` (the per-item Pi driver: GPU → pickup → refactoring research → Pi edits → build → PR → CI and quality gates → evidence + independent review on another GPU → merge → main build → deploy moves, with red stopping intake; no Grok turns while it runs) and its tests `test_item_loop.py`, `watchdog.py` (the shared
watchdog checks and their hard-rule guards — excluded items, WIP cap, live-driver skip, scrubbed and spaced comments —
plus check 1 GPU health and check 2 stalled fix-up hand-offs (a review FAIL 20+ min old with no fix commit, no
activity and no live driver gets one flag on the issue and the PR); `python3 factory/pi/watchdog.py run` runs them once, and `item_loop` runs them once at the end
of every driver run; no schedule) and its tests `test_watchdog.py`. No secret values; they come from the account's secrets. |
| [bootstrap.md](bootstrap.md) | Connecting a new Grok Bot account: secrets (names only), connectors, the three routines and their exact triggers and prompts. |

How to write code in an application repository is not here: it is in that repository's `AGENTS.md` and `CLAUDE.md`,
which any agent, local or cloud, reads. Change the bot's behavior with a pull request to this folder; the routines'
prompts only point here and do not change.

Nothing here deploys: `system.yml` ignores `**/*.md` and `factory/**`, so merging a change here builds no release.
