#!/usr/bin/env python3
"""Factory Pi item driver: one long-running, LLM-free loop per work item, so the factory bot (Grok) spends turns
only on the plan and on the wake that follows the result.

    item-loop draft-plan --repo R --issue N [--top-session ID]        Pi drafts plan.json from the issue (bot approves)
    item-loop start      --repo R --issue N [--top-session ID]        validate plan.json, launch `run` under nohup, return
    item-loop run        --repo R --issue N [--dry-run]               the loop itself (start launches it)
    item-loop status     --repo R --issue N                           one-line state for the bot's wake
    item-loop note-wake  --repo R --issue N --top-session ID          record a later bot wake on the item

Run dir: ~/factory-runs/<repo>-<issue>/ (plan.json, state.json, driver.log, tasks.jsonl, pi-sessions/). Every
decision that changes GitHub (push, PR, merge, board, comment, rerun) is a deterministic shell step under the gates of
factory/operating-instructions.md; Pi only edits files and summarizes logs. Waiting on CI is `gh pr checks --watch`
and `gh run watch` (no LLM call while waiting). Pi tasks go through run-task on the item's GPU (gpu.py: pro5000, pro6000, obs,
ts3; one active item per GPU slot, so up to 5 items at once). Every item starts with a refactoring-research pass, and its
Review includes an independent Pi diff review on a different GPU than the one that wrote the code. While anything is
red (a default-branch build or an environment), intake stops: only fix-forward items start. Secrets never reach a log,
comment or Pi prompt (scrubbed).

    item-loop red        status | set --key K --what TEXT | clear --key K      the intake-stop flags (~/factory-runs/red.json)
"""
from collections import Counter
from enum import StrEnum
import argparse, datetime as dt, fcntl, json, os, re, shlex, subprocess, sys, time, urllib.request, uuid
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gpu as G

# String enums for check states and failure types (values are string literals for JSON compatibility).
class CheckState(StrEnum):
    GREEN = "GREEN"
    RED = "RED"
    PENDING = "PENDING"

class FailureClass(StrEnum):
    INFRA = "infra"
    CODE = "code"

ORG = "clearmeasure-aisf-sample-apps"
BOT = "cm-ai-ops-bot"
BOT_GIT = ["-c", f"user.name={BOT}", "-c", "user.email=jeffrey+ai-ops@clear-measure.com"]
PROJECT = "PVT_kwDOD_ESUc4BliGL"
STATUS_FIELD = "PVTSSF_lADOD_ESUc4BliGLzhkOn7g"
STATUS = {"Todo": "f75ad846", "In Progress": "47fc9ee4", "Review": "e19122d0", "Merged": "8012c69b",
          "TDD": "eeb01ba5", "UAT": "ebff1a13", "Done": "98236657"}
# Board columns an item moves through after merge, in order (an item only moves forward, one column per healthy env).
BOARD_ORDER = ["Merged", "TDD", "UAT", "Done"]
REQUIRED = {"cmdemo1-workorders": ["Build result", "secret-scan"], "cmdemo1-system": ["env-checks"]}
DEPLOYABLE = {"cmdemo1-workorders": "ui", "cmdemo1-dashboard": "dashboard", "cmdemo1-system": "system"}
DELIVERY = f"https://raw.githubusercontent.com/{ORG}/cmdemo1-system/status/delivery.json"
NEVER_MERGE = {("cmdemo1-workorders", 1918)}
# Jeffrey: leave these alone (no plan, no driver, no comment).
HANDS_OFF = {("cmdemo1-system", 654), ("cmdemo1-workorders", 1875), ("cmdemo1-workorders", 1876)}
WIP_LIMIT = 3             # per repository: In Progress + Review (default)
WIP_LIMITS = {"cmdemo1-dashboard": 8}   # Jeffrey, 22 Nov 2026 7:31am CT: dashboard 8, workorders and system stay 3 (was 5 per 21 Nov 8:30am CT)
def wip_limit(repo): return WIP_LIMITS.get(repo, WIP_LIMIT)
# Stages in which an item holds its GPU (In Progress / Review). Waiting for a GPU, blocked, main, deploy and done do not.
ACTIVE_STAGES = ("pickup", "research", "implement", "local-verify", "pr", "ci", "review", "merge")
# Never changed by an enhancement PR: credentials, secrets and production setup.
PROTECTED_RE = re.compile(r"(?i)(^|/)(\.github/workflows|environments/prod|infra|octopus)/|(^|/)\.env(\.|$)|secret|"
                          r"credential|\.(pem|pfx|key)$|appsettings\.prod|keyvault|(^|/)nuget\.config$")
FOLLOWUP_MAX = 5          # follow-up refactoring issues one item may file
RESEARCH_MIN_CHARS = 300
DRIVER_MARK = "<!-- factory-pi-driver -->"
# Existing limits (operating-instructions): 2 Review FAILs, 3 infrastructure reruns; then a Blocker.
LIMITS = {"local_fix": 3, "ci_fix": 3, "review_fail": 2, "infra_rerun": 3, "quality_fix": 3, "merge_gate": 3, "research": 2, "review_infra": 2, "pi_relaunch": 2}
HANDOFF_START_S = 900     # a Pi hand-off with no model output 15 min after it got its slot is killed and relaunched (t85u)
HANDOFF_STALL_S = 1800    # ... or, once started, no session record and no CPU work in its process group for 30 min
HANDOFF_SLOT_WAIT_S = 900 # the first attempt waits this long for its own GPU's slot, then relaunches on any free GPU
ANY_SLOT_WAIT_S = 2 * 3600  # a relaunch (any free GPU) or a review waits up to 2 h for a slot: a busy queue is no failure
DRAFT_PLAN_TIMEOUT_S = 2700  # the draft-plan Pi pass: cold prompt reads on pro5000 made every 1500 s draft-plan time out (cmdemo1-system#884)
RESEARCH_TIMEOUT_S = 1500    # the mandatory refactoring-research Pi pass
PI_TASK_TIMEOUT_S = 1800     # the default timeout for one plan task run through task_passes
# Not required to merge, but a red one still stalls the PR: route to Pi instead of waiting on it (no-idle-stall).
QUALITY_CHECKS = ("qodana", "refactoring rationale")
HEARTBEAT_MIN = 30        # no progress for this long -> one short status comment
BLOCKED_HEARTBEAT_MIN = 120
RECHECK_S = 600           # a blocked driver re-reads its PR this often (no cron: the driver is its own timer)
BLOCKED_HOLD_H = 24
GPU_WAIT_S = 300          # a driver waiting for a free GPU re-checks this often (health is a models list, cached)
GPU_WAIT_H = 24
QUALITY_WAIT_MIN = 120    # Qodana / Refactoring rationale still pending after required checks are green
REVIEWER_WAIT_H = 2       # no second GPU up for the independent review
# Waits for a rate-limited gh reply - backoff first, then a fixed wait until the limit resets.
GH_RETRY_BACKOFF = (60, 120, 240)
GH_RETRY_RESET_WAIT = 600
GH_RETRY_MAX_ATTEMPTS = 8      # retries after the first try; then the gh call fails like any other
GH_RETRY_MAX_WAIT_S = 3600     # total sleep across those retries; a retry that would pass this is not made
GH_RETRY_TICK_S = 60           # while waiting, state.json is re-saved this often so the driver still looks alive
HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")

# Tokens, temporary and named tunnel hosts (the GPUs' clearmeasure.ai tunnels, with or without a scheme), bearer headers.
SECRET_RE = re.compile(r"(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|https?://[^\s'\"]*trycloudflare\.com[^\s'\"]*"
                       r"|(?:https?://)?[A-Za-z0-9.-]*\b(?:pro\d{4}|\d{4}ti)\.clearmeasure\.ai\b[^\s'\"]*"
                       r"|Bearer\s+\S+|(?i:(?:password|secret|token|apikey|api_key)\s*[=:]\s*)\S+)")
INFRA_RE = re.compile(r"(?i)(could not resolve host|temporary failure in name resolution|tls handshake timeout|"
                      r"connection reset by peer|econnreset|etimedout|503 service unavailable|502 bad gateway|"
                      r"toomanyrequests|rate limit exceeded|no space left on device|runner .* lost communication|"
                      r"the runner has received a shutdown signal|unable to (access|connect)|failed to fetch|"
                      r"apt-get .* failed|error response from daemon|context deadline exceeded)")
CODE_RE = re.compile(r"(?i)(error CS\d+|error [A-Z]{2,}\d+|\bFailed\b.*\btest|\bFAIL\b|Assert|Exception:|"
                     r"warning CS\d+|expected .* but|npm ERR!|Traceback)")


def now(): return dt.datetime.now(dt.timezone.utc)
def iso(t=None): return (t or now()).isoformat(timespec="seconds")

def scrub(s):
    s = SECRET_RE.sub("[redacted]", s or "")
    if _app_tok["v"] and len(_app_tok["v"]) > 6: s = s.replace(_app_tok["v"], "[redacted]")
    for name in (*G.secret_env_names(), "GH_TOKEN", "GITHUB_TOKEN", "CM_AI_OPS_BOT_GH_TOKEN", "GH_PROJECT_TOKEN"):
        v = os.environ.get(name)
        if v and len(v) > 6: s = s.replace(v, "[redacted]")
    return s

# ---------------------------------------------------------------- pure helpers (unit-tested)

# ---- GitHub App token for gh (own API quota). Opt-in: set GH_APP_TOKEN_CMD to a command that prints an installation token.
GH_APP_TOKEN_TTL_S = 50 * 60   # installation tokens last 1h; refresh before that
_APP_DENIED_RE = re.compile(r"HTTP 40[13]\b|Resource not accessible|Forbidden|Bad credentials|API rate limit|Repository rule violations|not authorized to push|protected branch", re.I)   # clear authorization refusals only
GH_APP_USER_ONLY = {("pr", "create"), ("issue", "create")}   # authored objects stay the bot user's: the merge gate requires PR author == BOT
GH_APP_MINT_RETRY_S = 5 * 60   # a failed mint is not retried on every gh call
_app_tok = {"v": None, "at": 0.0}

def app_denied(output):
    """True when gh's output says the App token was refused (401/403, missing permission, branch rule, App rate limit)."""
    return bool(_APP_DENIED_RE.search("\n".join((output or "").splitlines()[-8:])))

def app_token(env=None, clock=time.time, runner=subprocess.run):
    """Cached App installation token from $GH_APP_TOKEN_CMD, or None when unset / the command fails (callers then use the user login).
    Never logged: scrub() redacts it (ghs_ pattern and its exact value) and it is only passed to gh through GH_TOKEN."""
    env = os.environ if env is None else env
    cmd = env.get("GH_APP_TOKEN_CMD")
    if not cmd: return None
    age = clock() - _app_tok["at"]
    if _app_tok["v"] and age < GH_APP_TOKEN_TTL_S: return _app_tok["v"]
    if not _app_tok["v"] and _app_tok["at"] and age < GH_APP_MINT_RETRY_S: return None   # recent failed mint: negative cache
    try:
        r = runner(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
        tok = (r.stdout or "").strip() if r.returncode == 0 else ""
    except Exception: tok = ""
    _app_tok.update(v=tok or None, at=clock())
    return tok or None
# gh's own error line for a GitHub rate-limit reply, e.g. "GraphQL: API rate limit already exceeded for user ID 1.",
# "HTTP 403: API rate limit exceeded for ...", "HTTP 403: You have exceeded a secondary rate limit ...". Anchored at a
# line start and only looked for in the last lines gh printed, so a log dump that merely mentions a rate limit is not one.
RATE_LIMIT_RE = re.compile(r"(?i)^(?:graphql|http 403|http 429)\b[^:\n]*:\s.*\b(?:api rate limit (?:already )?exceeded|secondary rate limit)")
RATE_LIMIT_TAIL_LINES = 3
def is_rate_limit(text):
    """True when gh's closing error line(s) are a GitHub rate-limit reply (primary, GraphQL or secondary)."""
    lines = [l.strip() for l in (text or "").splitlines() if l.strip()][-RATE_LIMIT_TAIL_LINES:]
    return any(RATE_LIMIT_RE.search(l) for l in lines)

def gh_retry_wait(attempt, waited):
    """Seconds to wait before retry number `attempt` (0-based) after `waited` seconds so far, or None to give up."""
    if attempt >= GH_RETRY_MAX_ATTEMPTS: return None
    wait = GH_RETRY_BACKOFF[attempt] if attempt < len(GH_RETRY_BACKOFF) else GH_RETRY_RESET_WAIT
    return wait if waited + wait <= GH_RETRY_MAX_WAIT_S else None

def pr_number(text):
    t = str(text or "").strip()
    return int(t) if t.isdigit() else None

def classify_failure(log_text):
    """'infra' when the failure never reached the code (network, registry, runner), else 'code'."""
    if CODE_RE.search(log_text or ""): return FailureClass.CODE
    return FailureClass.INFRA if INFRA_RE.search(log_text or "") else FailureClass.CODE

def trim_log(text, limit=12000):
    """Keep the lines that explain a failure (errors, failed tests, assertion text) plus the tail."""
    text = re.sub(r"\x1b\[[0-9;]*m|\^\[\[[0-9;]*m", "", scrub(text))
    text = re.sub(r"(?m)^[^\t\n]*\t[^\t\n]*\t\ufeff?\d{4}-\d\d-\d\dT[\d:.]+Z ", "", text)   # gh's job / step / timestamp columns
    lines = [l for l in text.splitlines() if l.strip()]
    keep = [l for l in lines if CODE_RE.search(l) or INFRA_RE.search(l) or re.search(r"(?i)\berror\b|##\[error\]", l)]
    out = "\n".join(keep[-150:]) + "\n--- tail ---\n" + "\n".join(lines[-60:])
    return out[-limit:]

def checks_state(checks, required):
    """checks: [{name, bucket}] from `gh pr checks --json`. required: names, or None = every check."""
    st = {}
    for c in checks:
        b = c.get("bucket") or "pending"
        if st.get(c["name"]) in ("pass", "skipping") and b not in ("pass", "skipping"): continue
        st[c["name"]] = b
    names = required or list(st)
    if not names: return CheckState.PENDING
    rs = [st.get(n, "pending") for n in names]
    if any(b in ("fail", "cancel") for b in rs): return CheckState.RED
    if all(b in ("pass", "skipping") for b in rs): return CheckState.GREEN
    return CheckState.PENDING

def quality_states(checks):
    """name -> bucket for the Qodana / Refactoring-rationale checks (latest attempt of each name wins)."""
    st = {}
    for c in checks:
        if any(q in c["name"].lower() for q in QUALITY_CHECKS): st[c["name"]] = c.get("bucket") or "pending"
    return st

def quality_failures(checks):
    """Names of failing Qodana / Refactoring-rationale checks (latest attempt of each name wins)."""
    return sorted(n for n, b in quality_states(checks).items() if b in ("fail", "cancel"))

def heartbeat_due(progress_at, last_heartbeat, at, minutes=HEARTBEAT_MIN):
    """True when nothing progressed for `minutes` and no heartbeat was posted in the last `minutes` (ISO strings)."""
    def age(x): return (at - dt.datetime.fromisoformat(x)).total_seconds() / 60 if x else None
    a, h = age(progress_at), age(last_heartbeat)
    return a is not None and a >= minutes and (h is None or h >= minutes)

# The plan rules as data: PLAN_CHECKS is one (predicate, message) spec per rule a plan must satisfy, in the order the
# checks ran. A predicate is true when the plan satisfies its spec; the message is the error text, a string or a
# callable taking the plan when the text is computed (the enhancement's protected-file list, the bad criteria / task
# entries). validate_plan returns the messages of the specs the plan fails, in list order.
def _required(k):
    """Spec for one required plan key: present, and not None / "" / []."""
    return (lambda p: k in p and p[k] not in (None, "", [])), f"missing {k}"

def _entry_fields(field, *keys):
    """Spec for one plan list (criteria, tasks): every entry carries all of `keys`. The message is today's per-entry
    text; a plan with more than one bad entry gets those texts joined with '; '."""
    def bad(p): return [i for i, e in enumerate(p.get(field) or []) if not all(e.get(k) for k in keys)]
    return (lambda p: not bad(p)), lambda p: "; ".join(f"{field}[{i}] needs {' and '.join(keys)}" for i in bad(p))

def _no_secret_values(p):
    blob = json.dumps(p)
    return scrub(blob) == blob

def _prompts_do_not_touch_github(p):
    """No Pi task prompt asks Pi to commit, push or call gh: every GitHub write is the driver's."""
    return not re.search(r"git\s+(push|commit)|gh\s+(pr|issue|api)", " ".join(t.get("prompt", "") for t in p.get("tasks") or []))

PLAN_CHECKS = [
    *[_required(k) for k in ("repo", "issue", "branch", "files", "criteria", "tasks", "verify_cmd", "pr_title")],
    (lambda p: str(p.get("branch", "")).startswith(f"{BOT}/"), f"branch must start with {BOT}/"),
    _entry_fields("criteria", "text", "evidence_cmd"),
    _entry_fields("tasks", "name", "prompt"),
    (lambda p: (p.get("repo"), p.get("issue")) not in NEVER_MERGE, "this item's PR is never merged"),
    (lambda p: (p.get("repo"), p.get("issue")) not in HANDS_OFF, "this item is hands-off (Jeffrey); do not work it"),
    (lambda p: p.get("size") in (None, "large", "small"), "size must be large or small"),
    (lambda p: p.get("kind") != "enhancement" or not protected_files(p.get("files") or []),
     lambda p: "an enhancement may not change credentials, secrets or production setup: "
               f"{', '.join(protected_files(p.get('files') or []))}"),
    (_no_secret_values, "plan contains a secret-looking value"),
    (_prompts_do_not_touch_github, "Pi task prompts must not ask Pi to commit, push or call gh"),
]

def validate_plan(p):
    return [(m(p) if callable(m) else m) for ok, m in PLAN_CHECKS if not ok(p)]

def protected_files(files):
    return [f for f in files if PROTECTED_RE.search(f)]

def merge_base(sh, wt, default):
    """Merge base of HEAD and origin/<default>: the commit the branch forked from, which is what the PR diff shows.
    When git cannot resolve it, falls back to the old origin/<default> comparison, so the gate is never made more
    permissive than it was (a branch behind main may still show a false protected file, never a missed one)."""
    r = sh(["git", "merge-base", "HEAD", f"origin/{default}"], cwd=wt, check=False)
    base = (r.stdout or "").strip()
    return f"origin/{default}" if r.returncode or not base else base

def staged_files(sh, wt, default):
    """Paths staged in the worktree's index relative to merge_base(sh, wt, default): the branch's own staged
    changes, never commits main made after the branch forked off."""
    return sh(["git", "diff", "--cached", "--name-only", merge_base(sh, wt, default)], cwd=wt, check=False).stdout.split()

def gate_state(checks, required):
    """Merge gate: required checks GREEN and the quality checks (Qodana zero new problems, Refactoring rationale)
    passed. RED when either is red, PENDING while either is still running, else GREEN."""
    req = checks_state(checks, required)
    if req == CheckState.RED or quality_failures(checks): return CheckState.RED
    if req == CheckState.PENDING or quality_pending(checks): return CheckState.PENDING
    return CheckState.GREEN

def quality_pending(checks):
    return sorted(n for n, b in quality_states(checks).items() if b not in ("pass", "skipping", "fail", "cancel"))

def merge_args(full, pr, head):
    """Squash merge pinned to the reviewed head. Never --delete-branch (the branch stays for the record)."""
    return ["pr", "merge", str(pr), "-R", full, "--squash", "--match-head-commit", head]

RESEARCH_HEAD = "## Refactoring research"
RESEARCH_FILE = "refactoring-research.md"      # the driver's research artifact (run dir, not the worktree)
FOLLOWUPS_FILE = "refactoring-followups.json"  # the driver's follow-ups artifact (run dir, not the worktree)
PLAN_DRAFT_FILE = "plan.draft.json"            # Pi's draft of the item plan, before the bot copies it to PLAN_FILE
PLAN_FILE = "plan.json"                        # the item plan artifact the driver validates and runs from (run dir, not the worktree)

# H2s the driver itself writes after the research: the research section ends at the next of these, so an H2 written
# inside the research (`## Findings`, cmdemo1-dashboard#651) belongs to the section instead of truncating it and
# producing a false Blocker after LIMITS['research'] passes.
RESEARCH_TAIL = ("## Refactoring plan",)

_RESEARCH_HEAD_LINE = re.compile(r"(?m)^" + re.escape(RESEARCH_HEAD) + r"[ \t]*\r?$")

def research_head(text):
    """Offset of the first `## Refactoring research` heading LINE in `text` (the heading alone on its line), or -1.
    An inline mention in prose or backticks (`the `## Refactoring research` section`) is not the heading, so a PR
    summary that talks about the section is never mistaken for it (cmdemo1-system#890's own body was cut that way)."""
    m = _RESEARCH_HEAD_LINE.search(text or "")
    return m.start() if m else -1

def research_section(text):
    """The `## Refactoring research` section of a Markdown body: everything after the first heading line (see
    research_head) up to the next heading the driver itself writes (a line starting with a RESEARCH_TAIL heading), or the end
    of the body; "" when the heading is absent. Any other `## ` line (`## Findings`) stays part of the section."""
    text = text or ""
    i = research_head(text)
    if i < 0: return ""
    sec = text[i + len(RESEARCH_HEAD):]; n = 0
    for line in sec.splitlines(keepends=True):
        if line.startswith(RESEARCH_TAIL): return sec[:n]   # `## Refactoring plan` and `## Refactoring plan (size baseline)`
        n += len(line)
    return sec

def research_ok(text, files):
    """The `## Refactoring research` section is present and substantive: long enough, names at least one file the
    item touches, and names what it found (or why there is nothing) in at least two bullet lines."""
    if not text or research_head(text) < 0: return False
    sec = research_section(text)
    bullets = [l for l in sec.splitlines() if l.strip().startswith(("-", "*", "|")) and len(l.strip()) > 10]
    names = {f.rsplit("/", 1)[-1] for f in files or []} | set(files or [])
    return len(sec.strip()) >= RESEARCH_MIN_CHARS and len(bullets) >= 2 and (not names or any(n in sec for n in names))

def normalize_research(text):
    """Research text as it enters the PR body: the `## Refactoring research` heading stays H2 and every other H2
    inside that section is demoted to `### `, so whatever headings the research pass wrote (`## Findings`,
    cmdemo1-dashboard#651) the research is one top-level section of the body. `####` and deeper headings, the text
    outside the section and the leading/trailing whitespace are left as they are; the text is returned unchanged when
    the heading is absent, and normalizing twice is the same as normalizing once."""
    text = text or ""
    i = research_head(text)
    if i < 0: return text
    start = i + len(RESEARCH_HEAD)                      # the section starts after the heading line
    sec = research_section(text)                        # "" when the heading is absent, else up to the driver's next H2
    return text[:start] + re.sub(r"(?m)^##(?=[^#])", "###", sec) + text[start + len(sec):]

def with_research(body, research):
    """PR body with exactly one `## Refactoring research` section (replaced when present): the research goes in with
    its own subheadings demoted, and the driver's H2s after it (`## Refactoring plan`) stay H2."""
    research = normalize_research(research.strip())
    h = research_head(research)
    research = research[h:] if h > 0 else research if h == 0 else RESEARCH_HEAD + "\n\n" + research   # drop any preamble
    body = body or ""
    i = research_head(body)
    if i < 0:
        return body.rstrip() + "\n\n" + research + "\n"
    end = i + len(RESEARCH_HEAD) + len(research_section(body))   # where the old research section ends (its next driver H2)
    rest = body[end:]
    return body[:i] + research + ("\n\n" + rest if rest else "\n")   # keep the blank line before the driver's next H2

def new_followups(items, existing_titles, limit=FOLLOWUP_MAX):
    """Follow-up refactoring issues to file: valid ones (title + body), not already open by title, at most `limit`."""
    seen = {t.strip().lower() for t in existing_titles}; out = []
    for it in items or []:
        t = str(it.get("title") or "").strip(); b = str(it.get("body") or "").strip()
        if not t or not b or t.lower() in seen: continue
        seen.add(t.lower()); out.append({"title": t[:120], "body": b})
        if len(out) == limit: break
    return out

def resume_target(state):
    """(stage, clear_gpu) where a paused item (status `blocked` or `error`) resumes, from the state dict alone.
    Blocked: `resume_stage` when set, else `ci` when a PR exists, else `implement`; the GPU is never cleared.
    Error: resume the saved stage (falling back to implement when no stage is saved); a gpu/pickup error maps to the
    gpu stage with the recorded GPU cleared."""
    st = state or {}
    if st.get("status") == "error":
        stage = st.get("stage")
        if stage in ("gpu", "pickup"):
            return "gpu", True
        return stage or "implement", False
    return st.get("resume_stage") or ("ci" if st.get("pr") else "implement"), False

def apply_resume(state):
    """Resume a paused item (status `blocked` or `error`) from the state dict alone and return the new state: the
    target stage from resume_target (the saved stage for an error, falling back to implement when none is saved,
    `resume_stage` / ci / implement for a blocked),
    with the `error` (or `blocker`) field dropped, the recorded GPU cleared only when the saved stage was gpu or
    pickup, and the fix counts reset to zero."""
    st = dict(state or {})
    if st.get("status") in ("blocked", "error"):
        stage, clear_gpu = resume_target(st)
        st["stage"] = stage
        st.pop("blocker" if st.get("status") == "blocked" else "error", None)
        if clear_gpu: st.pop("gpu", None)
        st["counts"] = {k: 0 for k in LIMITS}
    return st

def busy_gpus(states, me=None, alive=lambda pid: False):
    """GPUs whose slots are all held by other live items in an active stage (pro5000 has 2, pro6000, obs and ts3 have 1).
    states: [(key, state dict)]."""
    held = Counter(s.get("gpu") for k, s in states
                   if k != me and s.get("gpu") and s.get("stage") in ACTIVE_STAGES and alive(s.get("pid")))
    return {g for g, n in held.items() if n >= G.GPUS.get(g, {}).get("slots", 1)}

def gpu_for_item(rec, size, up, busy):
    """(gpu, wait_why) for the gpu stage. A resumed item keeps the GPU recorded in state: take it when it is up,
    otherwise wait for that GPU (never re-pick, never fall back to the pro5000 default). A new item picks a free
    GPU of the right size; gpu=None means wait, and wait_why says for what."""
    if rec:
        if rec in up: return rec, None
        return None, f"waiting for the recorded GPU {rec} (up: {', '.join(up) or 'none'})"
    g = G.pick_gpu(size, up, busy)
    return g, None if g else f"no free GPU for a {size} item (up: {', '.join(up) or 'none'})"

def repo_wip(states, repo, me=None, alive=lambda pid: False):
    """Driver items of `repo` in In Progress or Review (active stages) on this box, live or blocked mid-review."""
    return sum(1 for k, s in states if k != me and s.get("repo") == repo and
               ((s.get("stage") in ACTIVE_STAGES and s.get("stage") != "pickup" and alive(s.get("pid")))
                or (s.get("stage") == "blocked" and s.get("resume_stage") in ACTIVE_STAGES and s.get("resume_stage") != "pickup")))

def hold_resumes(blocker):
    """Whether a Blocker may clear itself when the PR's checks turn green. A Review FAIL blocker never does: its checks
    were already green, so resuming only re-ran the same failing review (a loop that held a GPU and a WIP slot for hours)."""
    return not str(blocker or "").lstrip().lower().startswith(("review fail", "independent review fail", "independent review infra",
                                                               "pi hand-off"))

def review_verdict(result, findings):
    """(ok, text) for one independent-review run. ok None = an infrastructure failure, never a code FAIL (t83u, #1944 / #820):
    no findings file (findings None), an empty / whitespace-only one, or a reply with no PASS / FAIL verdict (timeout,
    crash). Those are retried on any free GPU and never handed to Pi as findings."""
    if findings is None: return None, f"the reviewer wrote no findings file (run result: {result})"
    if not findings.strip(): return None, f"the reviewer's findings file is empty (run result: {result})"
    if result not in ("PASS", "FAIL"): return None, f"the review ended with no PASS/FAIL verdict (run result: {result})"
    return result == "PASS", findings

def intake_open(red, plan):
    """While anything is red only fix-forward items start."""
    return not red or bool(plan.get("fix_forward"))

def env_red(environment, dep):
    """An environment is red for a deployable when its last health report is not healthy (system has no HTTP health)."""
    if dep == "system": return False
    for a in ((environment.get("health") or {}).get("containerApps") or []):
        if a.get("name") == dep and (a.get("last") or {}).get("result") not in (None, "healthy"): return True
    return False

def docs_only(files):
    return bool(files) and all(f.endswith(".md") or f.startswith("docs/") for f in files)

# Paths each deployable's release pipeline ignores (cmdemo1-system: .github/workflows/system.yml paths-ignore). A merge
# that changes only these builds no release, so there is no deploy to wait for (#914).
RELEASE_SKIP_RE = {"cmdemo1-system": re.compile(r"^(factory/.*|docs/.*|.*\.md|environments/[^/]+/(versions|nodes|database)\.json)$")}

def release_skipped(repo, files):
    """True when every changed file is one the repo's release pipeline ignores (never for no files or an unknown repo)."""
    rx = RELEASE_SKIP_RE.get(repo)
    return bool(rx and files) and all(rx.match(f) for f in files)

def deploy_moves(column, in_env):
    """column: current board column; in_env: {'tdd': bool, 'uat': bool, 'prod': bool}. Returns the moves to make."""
    target = "Done" if in_env.get("prod") else "UAT" if in_env.get("uat") else "TDD" if in_env.get("tdd") else column
    if column not in BOARD_ORDER or BOARD_ORDER.index(target) <= BOARD_ORDER.index(column): return []
    return BOARD_ORDER[BOARD_ORDER.index(column) + 1: BOARD_ORDER.index(target) + 1]

def pickup_comment(p, run_id, run_dir):
    plan = "\n".join(f"  - [ ] {c['text']} — {c.get('how') or 'evidence: `' + c['evidence_cmd'] + '`'}" for c in p["criteria"])
    cons = "; ".join(f'"{c}"' for c in p.get("constraints") or []) or "none stated"
    return (f"Todo → In Progress\n\n{BOT} is taking this issue.\n\n"
            f"- `Files:` {', '.join('`' + f + '`' for f in p['files'])}. `Docs-only: {'yes' if docs_only(p['files']) else 'no'}`.\n"
            f"- Plan:\n{plan}\n- Constraints: {cons}\n"
            f"- `Pi driver:` run `{run_id}` (`{run_dir.replace(HOME, '~')}`); Pi tasks: {', '.join(t['name'] for t in p['tasks'])}.")

# ---------------------------------------------------------------- box-wide state (red flags, other drivers)
def _runs_dir(): return os.path.join(HOME, "factory-runs")

def held(repo, issue):
    """The text of <run dir>/HOLD (an item handed off or held by Jeffrey), or None. A held item is never started,
    resumed or touched by a watchdog check (t85u: #1944 handed to FactoryBot1)."""
    try: return open(os.path.join(_runs_dir(), f"{repo}-{int(issue)}", "HOLD")).read().strip() or "held"
    except (OSError, TypeError, ValueError): return None

RELAUNCH_NOTE = ("\n\nNote: an earlier attempt at this task (`{name}`) was stopped because it never started or stalled. It "
                 "may have left partial edits in this working tree: check `git status` and `git diff` first, keep what is "
                 "correct and finish the task.")

def relaunch_gpus(size, up):
    """GPUs, in PRIORITY order, a stalled hand-off may be relaunched on. A large item (or one of unknown size) stays on
    pro5000 / pro6000 while either is up (it needs the long context, as in pick_gpu); otherwise any healthy GPU. The gate
    holds the caps."""
    up = [g for g in G.PRIORITY if g in up]
    large = [g for g in up if g in G.LARGE_GPUS]
    if size != "small" and large: return large
    return up

READ_ONLY_TASKS = ("independent-review", "draft-plan", "refactoring-research")   # told to change no repo files
def writes_code(name):
    """True for a Pi call that may edit the worktree; plan drafting, research and reviews change no files, so their
    GPU is not an author GPU (a review on it stays allowed)."""
    return not name.startswith(READ_ONLY_TASKS)

class PiHeld(Exception):
    """The item got a HOLD file mid-pass: stop before any further GitHub write."""

class PiNotStarted(Exception):
    """A Pi hand-off still did not start after LIMITS['pi_relaunch'] relaunches: the stage ends in a Blocker."""

def red_load():
    try: return json.load(open(os.path.join(_runs_dir(), "red.json")))
    except Exception: return {}

def _red_write(fn):
    os.makedirs(_runs_dir(), exist_ok=True)
    with open(os.path.join(_runs_dir(), "red.lock"), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX); r = red_load(); fn(r)
        tmp = os.path.join(_runs_dir(), "red.json.tmp"); json.dump(r, open(tmp, "w"), indent=1)
        os.replace(tmp, os.path.join(_runs_dir(), "red.json"))

def red_set(key, what): _red_write(lambda r: r.setdefault(key, {"what": scrub(what), "at": iso()}))
def red_clear(key): _red_write(lambda r: r.pop(key, None))

def pid_alive(pid):
    try: os.kill(int(pid), 0); return True
    except Exception: return False

def all_states():
    out = []
    try: names = os.listdir(_runs_dir())
    except FileNotFoundError: return out
    for n in names:
        sp = os.path.join(_runs_dir(), n, "state.json")
        try: out.append((n, json.load(open(sp))))
        except Exception: pass
    return out

_HEALTH = {"at": 0, "h": {}}
def gpu_health(max_age=600):
    if time.time() - _HEALTH["at"] > max_age: _HEALTH.update(at=time.time(), h=G.health())
    return _HEALTH["h"]

# ---------------------------------------------------------------- side-effect layer
def _json_or_none(line):
    try: return json.loads(line)
    except ValueError: return None

class UnknownStage(Exception):
    """The state file names a stage with no handler: the driver records it and wakes the bot (cmdemo1-system#829)."""

STAGES = {"gpu": "st_gpu", "pickup": "st_pickup", "research": "st_research", "implement": "st_implement",
          "local-verify": "st_local_verify", "pr": "st_pr", "ci": "st_ci", "review": "st_review",
          "merge": "st_merge", "main": "st_main", "deploy": "st_deploy"}
TERMINAL_STAGES = ("done", "blocked", "dry-run-done")

def stage_handler(driver, stage):
    """The driver's bound method for a stage name. Resolved on the instance every call, so tests (and a driver that
    swaps a stage out at runtime) can patch d.st_review; never capture the bound methods at import time."""
    if stage not in STAGES:
        raise UnknownStage(f"unknown stage {stage!r}; known stages: " + ", ".join(sorted(STAGES)))
    return getattr(driver, STAGES[stage])

class Driver:
    def __init__(self, repo, issue, dry_run=False, top_session=None):
        self.repo, self.issue, self.dry = repo, int(issue), dry_run
        self.run_dir = os.path.join(HOME, "factory-runs", f"{repo}-{issue}")
        os.makedirs(os.path.join(self.run_dir, "logs"), exist_ok=True)
        self.state_p = os.path.join(self.run_dir, "state.json")
        self.s = json.load(open(self.state_p)) if os.path.exists(self.state_p) else {}
        self.s.setdefault("repo", repo); self.s.setdefault("issue", self.issue)
        self.s.setdefault("counts", {k: 0 for k in LIMITS})
        if top_session: self.s["top_session"] = top_session
        self.full = f"{ORG}/{repo}"; self.last_task = {}

    # state / log
    def save(self, **kw):
        self.s.update(kw); self.s["updated"] = iso(); self.s["pid"] = os.getpid()
        tmp = self.state_p + ".tmp"; json.dump(self.s, open(tmp, "w"), indent=1); os.replace(tmp, self.state_p)
    def progress(self): self.save(progress_at=iso())
    def heartbeat(self, minutes=HEARTBEAT_MIN):
        """Short status comment when the item has made no progress for `minutes`; never silent, never spammy."""
        if self.dry or not heartbeat_due(self.s.get("progress_at") or self.s.get("start"), self.s.get("heartbeat_at"), now(), minutes): return
        self.save(heartbeat_at=iso())
        self.comment(f"Status: no progress for {minutes}+ min. Stage `{self.s.get('stage')}`, status `{self.s.get('status')}`"
                     + (f", PR #{self.s['pr']}" if self.s.get("pr") else "") + ". The driver is alive and re-checking on its own timer"
                     + (f"; waiting on: {self.s['blocker']}" if self.s.get("blocker") else "") + ".")
    def log(self, msg):
        line = f"{iso()} {scrub(msg)}"
        print(line, flush=True)
        open(os.path.join(self.run_dir, "driver.log"), "a").write(line + "\n")

    def sh(self, cmd, cwd=None, check=True, timeout=None, write=False):
        """write=True marks a GitHub- or remote-changing step: skipped (logged) in dry-run."""
        shown = cmd if isinstance(cmd, str) else " ".join(shlex.quote(c) for c in cmd)
        if write and self.dry:
            self.log(f"DRY-RUN skip: {shown[:300]}"); return subprocess.CompletedProcess(cmd, 0, "", "")
        is_gh = (isinstance(cmd, list) and cmd and cmd[0] == "gh") or (isinstance(cmd, str) and cmd.startswith("gh "))
        attempt = waited = 0
        while True:
            r = None
            tok = app_token() if is_gh and not (isinstance(cmd, list) and tuple(cmd[1:3]) in GH_APP_USER_ONLY) else None
            if tok:   # App quota first; any refusal (403 / permission / branch rule) re-runs the same call on the user login
                r = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), text=True, timeout=timeout, env={**os.environ, "GH_TOKEN": tok},
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                if r.returncode and app_denied(r.stdout):
                    if re.search(r"HTTP 401|Bad credentials", r.stdout): _app_tok.update(v=None, at=0.0)   # expired: re-mint next call (at=0: no negative cache)
                    self.log("gh: App token refused; retrying this call with the user login"); r = None
            if r is None:
                r = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), text=True, timeout=timeout,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if not (is_gh and r.returncode and is_rate_limit(r.stdout)):
                break
            wait = gh_retry_wait(attempt, waited)
            if wait is None:
                self.log(f"gh rate-limited (exit {r.returncode}); giving up after {attempt} retries / {waited}s")
                break
            self.log(f"gh rate-limited (exit {r.returncode}); retry {attempt + 1} in {wait}s")
            self.wait_alive(wait, f"gh rate limit, retry {attempt + 1}")
            waited += wait; attempt += 1
        if is_gh and "gh_wait" in self.s: self.s.pop("gh_wait"); self.save()
        if check and r.returncode:
            raise RuntimeError(f"failed ({r.returncode}): {shown[:300]}\n{scrub(r.stdout)[-2000:]}")
        return r
    def gh(self, *a, write=False, check=True, timeout=None): return self.sh(list(("gh", *a)), check=check, timeout=timeout, write=write)
    def wait_alive(self, seconds, why):
        """Sleep in GH_RETRY_TICK_S steps, re-saving state.json each step (pid, `updated`, `gh_wait`) so a driver waiting
        out a rate limit stays visibly alive. No comment here: that would itself be a rate-limited gh call."""
        left = seconds
        while left > 0:
            step = min(GH_RETRY_TICK_S, left)
            self.save(gh_wait={"why": why, "until": iso(now() + dt.timedelta(seconds=left))})
            time.sleep(step); left -= step

    # GitHub actions (all deterministic)
    def comment(self, body, pr=False):
        last = self.s.get("last_comment_at")
        if last and not self.dry:
            wait = 65 - (now() - dt.datetime.fromisoformat(last)).total_seconds()
            if wait > 0: time.sleep(wait)   # never two comments within a minute on one item
        p = os.path.join(self.run_dir, "logs", f"comment-{int(time.time())}.md")
        open(p, "w").write(scrub(body))
        target = str(self.s["pr"]) if pr else str(self.issue)
        self.gh("pr" if pr else "issue", "comment", target, "-R", self.full, "--body-file", p, write=True)
        self.save(last_comment_at=iso()); self.log(f"comment {'drafted (dry-run)' if self.dry else 'posted'}: {p}")

    def review_fail_comment(self, body):
        """A review FAIL goes in the issue journal AND on the PR, so the PR never looks clean while its review failed
        (cmdemo1-dashboard#1311: the FAIL was on the issue only and the PR sat green and idle for two hours)."""
        self.comment(body)
        if self.s.get("pr"): self.comment(body, pr=True)

    def move(self, col):
        if not self.s.get("item_id"):
            q = ('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){'
                 'projectItems(first:10){nodes{id project{id}}}}}}')
            r = self.gh("api", "graphql", "-f", f"query={q}", "-f", f"o={ORG}", "-f", f"r={self.repo}", "-F", f"n={self.issue}", check=False)
            try:
                nodes = json.loads(r.stdout)["data"]["repository"]["issue"]["projectItems"]["nodes"]
                self.save(item_id=next(n["id"] for n in nodes if n["project"]["id"] == PROJECT))
            except Exception:
                self.log("board item not found; skipping move"); return
        self.gh("project", "item-edit", "--id", self.s["item_id"], "--project-id", PROJECT, "--field-id", STATUS_FIELD,
                "--single-select-option-id", STATUS[col], write=True)
        self.save(column=col); self.log(f"board -> {col}")

    def wake_bot(self, reason):
        """Fire the bot's issue-assigned listener once (unassign + assign) so he reads state.json."""
        self.save(wake_reason=reason)
        self.gh("api", "-X", "DELETE", f"repos/{self.full}/issues/{self.issue}/assignees", "-f", f"assignees[]={BOT}", write=True, check=False)
        self.gh("api", "-X", "POST", f"repos/{self.full}/issues/{self.issue}/assignees", "-f", f"assignees[]={BOT}", write=True, check=False)
        self.log(f"woke the bot: {reason}")

    def blocker(self, what, who="Jeffrey"):
        self.comment(f"Blocker: {what} Needed from {who}. The Pi driver stopped (run `{self.s.get('run_id')}`). "
                     f"Reply on this issue or in chat.\n\n{self.usage()}")
        self.save(resume_stage=self.s.get("stage") if self.s.get("stage") != "blocked" else self.s.get("resume_stage"),
                  stage="blocked", status="blocked", blocker=what); self.wake_bot("blocked")

    def usage(self, final=False):
        a = [os.path.join(HERE, "usage-report"), "--run-dir", self.run_dir] + (["--final"] if final else [])
        return self.sh(a, check=False).stdout.strip()

    # Pi
    def gpu(self):
        g = self.s.get("gpu")
        if not g:
            raise RuntimeError(f"no GPU is recorded for this item ({self.full}#{self.issue}); it must pass the gpu stage first")
        return g
    def gpu_label(self, g=None): return G.GPUS[g or self.gpu()]["label"]

    def pi(self, name, prompt, timeout=1800, gpu=None):
        pf = os.path.join(self.run_dir, "logs", f"{name}.prompt.md")
        suffix = ("\n\nRules: follow the repository's AGENTS.md and CLAUDE.md (read them if this task touches code, tests or "
                  "the build). Make only the change asked. Do not run git commit, git push or gh, and do not read or print "
                  "credentials. When done, run the narrowest relevant build/test, then end your reply with PASS or FAIL as "
                  "the last line.")
        open(pf, "w").write(scrub(prompt) + suffix)
        timeout = max(int(timeout), G.MIN_CLIENT_TIMEOUT_S)
        review = name.startswith("independent-review")   # a review keeps its non-author GPUs; no-start = infra retry
        task, g = name, gpu or self.gpu()
        for k in range(LIMITS["pi_relaunch"] + 1):
            slot_wait = ANY_SLOT_WAIT_S if review or k else HANDOFF_SLOT_WAIT_S
            r = self.sh([os.path.join(HERE, "run-task"), "--run-dir", self.run_dir, "--cwd", self.s["wt"], "--task", task,
                         "--prompt-file", pf, "--timeout", str(timeout), "--gpu", g, "--start-timeout", str(HANDOFF_START_S),
                         "--stall-timeout", str(HANDOFF_STALL_S), "--slot-wait", str(slot_wait)], check=False)
            self.log(f"pi {task}: " + (r.stdout.splitlines() or ["?"])[0][:300]); self.progress()
            self.last_task = next((rec for rec in map(_json_or_none, (r.stdout or "").splitlines()) if isinstance(rec, dict)),
                                  {"result": f"exit {r.returncode}"})
            if writes_code(name) and self.last_task.get("result") != "no-start":   # no model output = no edits
                self.note_author_gpu(self.last_task.get("gpu"))
            if review or self.last_task.get("result") not in ("no-start", "stalled"): return r.returncode == 0
            if k == LIMITS["pi_relaunch"]: break
            up = G.available(gpu_health()) or list(G.PRIORITY)
            task, g = f"{name}-relaunch-{k + 1}", ",".join(relaunch_gpus(self.s.get("size"), up))   # a free GPU of the item's size
            pf = os.path.join(self.run_dir, "logs", f"{task}.prompt.md")
            open(pf, "w").write(scrub(prompt) + RELAUNCH_NOTE.format(name=name) + suffix)
            self.log(f"Pi hand-off {name} {self.last_task.get('result')} (start {HANDOFF_START_S} s / stall {HANDOFF_STALL_S} s / "
                     f"slot {slot_wait} s); relaunch {k + 1} of {LIMITS['pi_relaunch']} on any free GPU ({g})")
        raise PiNotStarted(f"Pi hand-off `{name}` did not start or stalled ({self.last_task.get('result')}: no GPU slot, no model "
                           f"output within {HANDOFF_START_S // 60} min of getting one, or no activity for {HANDOFF_STALL_S // 60} min) "
                           f"after {LIMITS['pi_relaunch']} relaunches on any free GPU.")

    def note_author_gpu(self, g):
        """Record a GPU that ran an authoring Pi call (any non-review call, a relaunch on another GPU included): the
        independent review must run on none of them (operating-instructions: never on the author's GPU)."""
        if g in G.GPUS and g not in self.s.get("author_gpus", []):
            self.save(author_gpus=self.s.get("author_gpus", []) + [g])

    def author_gpus(self):
        """The item's GPU plus every GPU a (relaunched) authoring call actually ran on."""
        return [self.gpu()] + [g for g in self.s.get("author_gpus", []) if g != self.gpu()]

    def task_passes(self, t):
        """Run one plan task through Pi; retry a failure up to LIMITS['local_fix'] times under distinct names
        (`<name>-retry-<k>`, at most LIMITS['local_fix'] + 1 pi calls), then Blocker. True only when the task passed."""
        prompt = t["prompt"]
        for k in range(LIMITS["local_fix"] + 1):
            name = t["name"] if not k else f"{t['name']}-retry-{k}"
            if k: prompt = t["prompt"] + "\nNote: a previous attempt at this task failed; fix what it left broken."
            if self.pi(name, prompt, int(t.get("timeout", PI_TASK_TIMEOUT_S))): return True
        self.blocker(f"Pi task `{t['name']}` still failed after {LIMITS['local_fix'] + 1} attempts (last attempt `{name}`).")
        return False

    def verify(self, name):
        log = os.path.join(self.run_dir, "logs", f"verify-{name}.log"); t0 = time.time()
        r = subprocess.run(["bash", "-o", "pipefail", "-c", self.s["plan"]["verify_cmd"]], cwd=self.s["wt"], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        open(log, "w").write(scrub(r.stdout))
        self.s["verify_runs"] = self.s.get("verify_runs", 0) + 1
        self.s["verify_s"] = self.s.get("verify_s", 0) + time.time() - t0; self.save()
        self.log(f"verify {name}: exit {r.returncode} in {time.time() - t0:.0f}s")
        return r.returncode, r.stdout

    def bump(self, key):
        self.s["counts"][key] = self.s["counts"].get(key, 0) + 1; self.save()
        return self.s["counts"][key] <= LIMITS[key]

    def local_green(self, label):
        for k in range(LIMITS["local_fix"] + 1):
            rc, out = self.verify(f"{label}-{k}")
            if rc == 0: return True
            if k == LIMITS["local_fix"]: return False
            self.pi(f"{label}-fix-{k + 1}", f"The verification command `{self.s['plan']['verify_cmd']}` fails in this working tree.\n"
                    f"Relevant output:\n```\n{trim_log(out)}\n```\nFix the root cause with the smallest change. Do not skip, "
                    "delete, weaken or retry-wrap tests or gates, and add no baseline entries.")
        return False

    def commit_push(self, msg):
        self.check_held()
        wt = self.s["wt"]
        self.sh(["git", "add", "-A"], cwd=wt)
        if self.sh(["git", "diff", "--cached", "--quiet"], cwd=wt, check=False).returncode:
            self.sh(["git", *BOT_GIT, "commit", "-q", "-m", msg + f"\n\nCode by Pi ({self.gpu_label()}); planned by the factory bot; "
                     f"Pi driver run {self.s['run_id']}."], cwd=wt)
        self.sh(["git", "push", "-q", "origin", f"HEAD:refs/heads/{self.s['plan']['branch']}"], cwd=wt, write=True)
        head = self.sh(["git", "rev-parse", "HEAD"], cwd=wt).stdout.strip(); self.save(head=head)
        if not self.dry and self.s.get("pr"): time.sleep(90)   # let the PR's checks move to the new head before reading them
        return head

    def pr_checks(self):
        r = self.gh("pr", "checks", str(self.s["pr"]), "-R", self.full, "--json", "name,bucket,link", check=False)
        try: cs = json.loads(r.stdout or "[]")
        except Exception: cs = []
        return checks_state(cs, REQUIRED.get(self.repo)), cs

    def wait_ci(self, max_s=4 * 3600):
        """Zero-LLM wait: gh's own watch; falls back to a sleep loop until checks exist."""
        t_end = time.time() + max_s
        while time.time() < t_end:
            state, cs = self.pr_checks()
            if cs and state != CheckState.PENDING: return state, cs
            if cs:
                try:
                    self.gh("pr", "checks", str(self.s["pr"]), "-R", self.full, "--watch", "--interval", "60",
                            *(["--required"] if self.repo in REQUIRED else []), check=False, timeout=600)
                except subprocess.TimeoutExpired: pass   # short slices so the heartbeat below runs
            self.heartbeat(); time.sleep(60)
        return CheckState.PENDING, []

    def failed_logs(self, cs):
        out, runs = [], set()
        for c in cs:
            if c.get("bucket") in ("fail", "cancel"):
                m = re.search(r"/actions/runs/(\d+)", c.get("link") or "")
                if m: runs.add(m.group(1))
        for rid in sorted(runs):
            r = self.gh("run", "view", rid, "-R", self.full, "--log-failed", check=False)
            out.append(f"### run {rid}\n" + trim_log(r.stdout, 8000))
        return runs, "\n".join(out)[-16000:]

    # ---------------------------------------------------------------- stages
    def setup_worktree(self):
        p = self.s["plan"]; clone = os.path.join(HOME, "factory-clones", self.repo)
        if not os.path.isdir(os.path.join(clone, ".git")):
            os.makedirs(os.path.dirname(clone), exist_ok=True)
            self.gh("repo", "clone", self.full, clone, "--", "-q")
        self.sh(["git", "fetch", "-q", "origin"], cwd=clone)
        default = self.gh("repo", "view", self.full, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name").stdout.strip()
        wt = os.path.join(HOME, "factory-wt", f"{self.repo}-{self.issue}")
        if os.path.isdir(wt + "-plan"): self.sh(["git", "worktree", "remove", "--force", wt + "-plan"], cwd=clone, check=False)
        if not os.path.isdir(wt):
            remote = self.sh(["git", "ls-remote", "--heads", "origin", p["branch"]], cwd=clone).stdout.strip()
            base = f"origin/{p['branch']}" if remote else f"origin/{default}"
            if remote: self.sh(["git", "fetch", "-q", "origin", f"{p['branch']}:refs/remotes/origin/{p['branch']}"], cwd=clone)
            self.sh(["git", "worktree", "prune"], cwd=clone)
            self.sh(["git", "worktree", "add", "-q", "-B", p["branch"], wt, base], cwd=clone)
        self.save(wt=wt, default=default, clone=clone)

    def plan_worktree(self):
        """Detached worktree at the default branch for Pi to read while drafting the plan (no branch is created)."""
        clone = os.path.join(HOME, "factory-clones", self.repo)
        if not os.path.isdir(os.path.join(clone, ".git")):
            os.makedirs(os.path.dirname(clone), exist_ok=True)
            self.gh("repo", "clone", self.full, clone, "--", "-q")
        self.sh(["git", "fetch", "-q", "origin"], cwd=clone)
        default = self.gh("repo", "view", self.full, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name").stdout.strip()
        wt = os.path.join(HOME, "factory-wt", f"{self.repo}-{self.issue}-plan")
        if os.path.isdir(wt): self.sh(["git", "worktree", "remove", "--force", wt], cwd=clone, check=False)
        self.sh(["git", "worktree", "add", "-q", "--detach", wt, f"origin/{default}"], cwd=clone)
        self.save(wt=wt, default=default, clone=clone)

    def run(self):
        lock = open(os.path.join(self.run_dir, "driver.lock"), "w")
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: print("driver already running for this item"); sys.exit(0)
        self.s.setdefault("run_id", now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
        self.s.setdefault("start", iso()); self.s.setdefault("stage", "gpu")
        self.s["plan"] = json.load(open(os.path.join(self.run_dir, PLAN_FILE)))
        self.save(status="running")
        meta_p = os.path.join(self.run_dir, "run.json")
        meta = json.load(open(meta_p)) if os.path.exists(meta_p) else {"start": self.s["start"]}
        meta.update(driver_run_id=self.s["run_id"], top_sessions=self.s.get("top_sessions") or [self.s.get("top_session", "unnamed")])
        meta.setdefault("top_session", self.s.get("top_session", "unnamed"))
        meta.setdefault("pi_version", self.sh(["pi", "--version"], check=False).stdout.strip().splitlines()[-1:] and
                        self.sh(["pi", "--version"], check=False).stdout.strip().splitlines()[-1])
        json.dump(meta, open(meta_p, "w"), indent=1)
        self.progress()
        try:
            while True:
                while self.s["stage"] not in TERMINAL_STAGES:
                    if self.stop_if_held(): break
                    stage = self.s["stage"]; self.log(f"stage {stage}")
                    try: stage_handler(self, stage)()
                    except PiNotStarted as e: self.blocker(str(e))
                    except PiHeld:   # HOLD appeared mid-pass: stop before the push / merge (no comment)
                        self.stop_if_held(); break
                    self.progress()
                if self.s.get("status") == "held" or self.s["stage"] != "blocked" or not self.hold_blocked(): break
        except Exception as e:  # unexpected: record, wake the bot once, never guess
            self.log(f"driver error: {e}")
            self.save(status="error", error=scrub(str(e))[-1500:]); self.wake_bot("driver error")
            watchdog_exit(self)
            raise
        self.save(status="held" if self.s.get("status") == "held" else self.s["stage"], end=iso())
        watchdog_exit(self)

    def stop_if_held(self):
        """True (and status `held`) when the run dir has a HOLD file: an item handed off or held while this driver runs
        is not touched again (no stage, no resume, no push or merge, no comment); the driver exits cleanly (t85u)."""
        h = held(self.repo, self.issue)
        if not h: return False
        self.log(f"HOLD file found ({h[:200]}); stopping without touching the item")
        self.save(status="held", held=scrub(h)[:500]); return True

    def hold_blocked(self):
        """After a Blocker the driver stays up (status stays `blocked`, the bot was woken) and re-checks the PR every
        RECHECK_S for BLOCKED_HOLD_H. When the PR turns clean on its own (or Jeffrey's fix landed) it clears the
        Blocker and resumes; otherwise it posts a heartbeat. Returns True when it resumed."""
        if not self.s.get("pr") or self.s.get("resume_stage") not in ("ci", "review", "merge") or self.dry: return False
        if not hold_resumes(self.s.get("blocker")): return False
        t_end = time.time() + BLOCKED_HOLD_H * 3600
        while time.time() < t_end:
            time.sleep(RECHECK_S)
            if self.stop_if_held(): return False   # handed off while blocked: never clear the Blocker or resume
            state, cs = self.pr_checks()
            if gate_state(cs, REQUIRED.get(self.repo)) == CheckState.GREEN:
                self.log("blocked PR is clean now; resuming")
                self.comment("Status: checks are green now (including Qodana and Refactoring rationale); the driver cleared its "
                             "Blocker and is resuming the Review.")
                self.s["counts"] = {k: 0 for k in LIMITS}; self.s.pop("blocker", None)
                self.save(stage="review", status="running"); self.progress(); return True
            self.heartbeat(BLOCKED_HEARTBEAT_MIN)
        return False

    def st_gpu(self):
        """Wait (no Grok turn, no comment; the item stays in Todo) until intake is open, the repo has WIP room on this
        box and a GPU of the right size is free; then take it. One active item per GPU slot (pro5000 has 2), so up to 5 items at once."""
        p = self.s["plan"]; size = G.classify_size(p); t_end = time.time() + GPU_WAIT_H * 3600; me = os.path.basename(self.run_dir)
        while time.time() < t_end:
            red = red_load()
            if not intake_open(red, p): why = "intake stopped while red: " + "; ".join(f"{k}: {v['what']}" for k, v in red.items())
            else:
                with open(os.path.join(_runs_dir(), "gpu.lock"), "w") as lk:
                    fcntl.flock(lk, fcntl.LOCK_EX); states = all_states()
                    up = G.available(gpu_health())
                    if repo_wip(states, self.repo, me, pid_alive) >= wip_limit(self.repo): why = f"WIP is full for {self.repo} ({wip_limit(self.repo)})"
                    else:
                        g, why = gpu_for_item(self.s.get("gpu"), size, up, busy_gpus(states, me, pid_alive))
                        if g:
                            self.save(gpu=g, size=size, stage="pickup"); self.log(f"GPU {g} ({self.gpu_label(g)}) for a {size} item")
                            return
            if self.dry:
                g = self.s.get("gpu") or G.LARGE_GPU
                self.log(f"DRY-RUN: {why}; taking {g}"); return self.save(gpu=g, size=size, stage="pickup")
            if self.s.get("wait_why") != why: self.save(wait_why=why); self.log(f"waiting: {why}")
            time.sleep(GPU_WAIT_S)
        self.blocker(f"waited {GPU_WAIT_H} hours to start ({self.s.get('wait_why')}).")

    def st_pickup(self):
        p = self.s["plan"]; self.setup_worktree()
        if not self.s.get("pickup_posted"):
            self.move("In Progress"); self.comment(pickup_comment(p, self.s["run_id"], self.run_dir) +
                                                   f"\n- `GPU:` {self.gpu()} ({self.gpu_label()}), {self.s.get('size', 'large')} item.")
            self.save(pickup_posted=True)
        self.save(stage="research")

    def research_prompt(self):
        p = self.s["plan"]; out = os.path.join(self.run_dir, RESEARCH_FILE); fu = os.path.join(self.run_dir, FOLLOWUPS_FILE)
        return out, fu, (
            f"Refactoring research for {self.repo}#{self.issue} ({p['pr_title']}). Change NO files in this repository: this is "
            "research before any code is written.\n\nRead the files this item will touch and their close collaborators "
            "(callers, callees, tests, sibling classes):\n" + "\n".join(f"- {f}" for f in p["files"]) + "\n\n"
            "Look for: duplication, long methods, primitive obsession, missing abstractions, and places where a known pattern "
            "(strategy, specification, builder / ObjectMother, query / command objects, value objects, etc.) would make the "
            "code clearer and easier to maintain.\n\n"
            f"Write the findings as Markdown to {out}, starting with the line `{RESEARCH_HEAD}`, then one bullet per finding: "
            "file and member, the smell, the proposed refactoring or pattern, and the verdict `in scope` (small, safe, inside "
            "the files above: done in this PR) or `follow-up` (larger: filed as its own issue). When a file has nothing worth "
            "refactoring, say so in a bullet naming the file and why. End with `In scope:` and `Follow-up:` summary lines. Under "
            "it use only `###` subheadings - never `## `, which the driver reads as the end of the research section and would "
            "drop your findings.\n\n"
            f"Write {fu} as JSON: {{\"in_scope\": [{{\"name\": \"refactor-<slug>\", \"prompt\": \"<one small refactoring Pi can do "
            "with tests kept green>\"}}], \"followups\": [{\"title\": \"Refactor: <what>\", \"body\": \"<the smell, the files, the "
            "proposed pattern, and acceptance criteria: behavior unchanged, tests green>\"}]}. Use empty lists when there is "
            "none. End your reply with PASS when both files are written.")

    def st_research(self):
        """Mandatory on every item (Jeffrey, 20 Nov 2026): refactoring research before any code, findings in the issue
        journal and the PR body, small in-scope refactors in this PR (tests green), larger ones filed as follow-ups."""
        out, fu, prompt = self.research_prompt(); p = self.s["plan"]
        text = self.research_text()
        while not research_ok(text, p["files"]):
            if not self.bump("research"):
                return self.blocker("the refactoring research is missing or not substantive after "
                                    f"{LIMITS['research']} Pi passes (`{RESEARCH_HEAD}` with findings per touched file).")
            self.pi(f"refactoring-research-{self.s['counts']['research']}", prompt, RESEARCH_TIMEOUT_S)
            self.sh(["git", "checkout", "--", "."], cwd=self.s["wt"], check=False); self.sh(["git", "clean", "-fdq"], cwd=self.s["wt"], check=False)
            text = self.research_text()
        try: extra = json.load(open(fu))
        except Exception: extra = {}
        if not self.s.get("research_posted"):
            self.comment(f"Refactoring research (journal)\n\n{text.strip()}"); self.save(research_posted=True)
        if not self.s.get("followups_filed"):
            self.file_followups(extra.get("followups") or []); self.save(followups_filed=True)
        refs = [t for t in (extra.get("in_scope") or []) if t.get("name") and t.get("prompt")][:3]
        if refs and not self.s.get("refactors_done"):
            for t in refs:
                self.pi(re.sub(r"[^A-Za-z0-9._-]", "-", str(t["name"]))[:60], t["prompt"] + "\n\nBehavior must not change. Keep every "
                        "test green; never skip, delete or weaken a test. If this refactoring turns out larger than a small, "
                        "safe change inside the item's files, change nothing and end with FAIL.")
            if not self.local_green("refactor"):
                self.sh(["git", "reset", "-q", "--hard"], cwd=self.s["wt"]); self.sh(["git", "clean", "-fdq"], cwd=self.s["wt"])
                open(out, "a").write("\n- In-scope refactors were reverted: verification stayed red after the fix passes; "
                                     "they are left to a follow-up.\n")
                self.log("in-scope refactors reverted (red)")
            self.save(refactors_done=True)
        self.save(stage="implement")

    def file_followups(self, items):
        r = self.gh("api", f"repos/{self.full}/issues?state=open&labels=enhancement&per_page=100", "--jq", "[.[].title]", check=False)
        try: titles = json.loads(r.stdout or "[]")
        except Exception: titles = []
        made = []
        for it in new_followups(items, titles):
            body = os.path.join(self.run_dir, "logs", f"followup-{len(made)}.md")
            open(body, "w").write(scrub(f"{it['body']}\n\nFound by the refactoring research of #{self.issue}. "
                                        "Behavior unchanged; tests green; no test weakened.\n"))
            x = self.gh("issue", "create", "-R", self.full, "--title", it["title"], "--body-file", body, "--label", "enhancement",
                        "--assignee", BOT, write=True, check=False)
            if x.returncode == 0 and x.stdout.strip(): made.append(x.stdout.strip().rsplit("/", 1)[-1])
        if made: self.save(followups=made); self.log(f"follow-up refactoring issues: {', '.join(made)}")

    def st_implement(self):
        done = set(self.s.get("tasks_done", []))
        for t in self.s["plan"]["tasks"]:
            if t["name"] in done: continue
            if not self.task_passes(t): return   # the Blocker is already raised; never mark a failed task done
            done.add(t["name"]); self.save(tasks_done=sorted(done))
        self.save(stage="local-verify")

    def st_local_verify(self):
        if not self.local_green("local"):
            return self.blocker(f"local verification `{self.s['plan']['verify_cmd']}` is still red after "
                                f"{LIMITS['local_fix']} Pi fix passes.")
        if self.dry:
            self.sh(["git", "add", "-A"], cwd=self.s["wt"])
            self.log("DRY-RUN: local verification green; stopping before commit/push/PR.\n"
                     + self.sh(["git", "diff", "--cached", "--stat"], cwd=self.s["wt"]).stdout)
            return self.save(stage="dry-run-done")
        self.save(stage="pr")

    def research_text(self):
        f = os.path.join(self.run_dir, RESEARCH_FILE)
        return open(f).read() if os.path.exists(f) else ""

    def merge_base(self):
        """Merge base of HEAD and origin/<default>, or origin/<default> when git cannot resolve it."""
        return merge_base(self.sh, self.s["wt"], self.s["default"])

    def enhancement_blocker(self):
        """Blocker text when the enhancement's own staged changes touch credentials, secrets or production setup, else
        None. The index is compared with merge_base(), so commits main made after the branch forked off never block."""
        self.sh(["git", "add", "-A"], cwd=self.s["wt"])
        bad = protected_files(staged_files(self.sh, self.s["wt"], self.s["default"]))
        return (f"the change touches credentials, secrets or production setup ({', '.join(bad)}); "
                "an enhancement PR may not.") if bad else None

    def find_open_pr(self):
        """Number of the PR already open for this branch, or None (gh prints a plain message, not a number, when there
        is none)."""
        p = self.s["plan"]
        r = self.gh("pr", "list", "-R", self.full, "--head", p["branch"], "--state", "open", "--json", "number", "-q", ".[0].number", check=False)
        return pr_number(r.stdout)

    def create_pr(self, head):
        """Open the PR (research section in the body), move the board to Review and say so on the issue."""
        p = self.s["plan"]
        body = os.path.join(self.run_dir, "logs", "pr-body.md")
        open(body, "w").write(scrub(with_research(f"Closes #{self.issue}\n\n{p.get('pr_summary', '')}\n\nCode by Pi on the {self.gpu_label()}; "
                                    f"planned, verified and merged by the factory bot's Pi driver (run `{self.s['run_id']}`).\n\n{DRIVER_MARK}\n",
                                    self.research_text())))
        r = self.gh("pr", "create", "-R", self.full, "--head", p["branch"], "--base", self.s["default"],
                    "--title", p["pr_title"], "--body-file", body, write=True)
        self.save(pr=int(r.stdout.strip().rstrip("/").split("/")[-1]))
        self.move("Review")
        self.comment(f"In Progress → Review\n\nPR #{self.s['pr']} (head `{head[:8]}`). Required checks: running "
                     f"(local verification green, {self.s.get('verify_runs', 0)} runs). Change: {p.get('pr_summary', p['pr_title'])}\n\n{self.usage()}")

    def st_pr(self):
        p = self.s["plan"]
        if p.get("kind") == "enhancement":
            if (why := self.enhancement_blocker()): return self.blocker(why)
        head = self.commit_push(p["pr_title"])
        if not self.s.get("pr"):
            if (n := self.find_open_pr()) is not None: self.save(pr=n)
        if not self.s.get("pr"): self.create_pr(head)
        self.save(stage="ci")

    def st_ci(self):
        state, cs = self.wait_ci()
        self.log(f"required checks {state}")
        bad = quality_failures(cs)
        if state == CheckState.GREEN and not bad:
            if quality_pending(cs):   # hard gate: Qodana and Refactoring rationale must finish green, never skipped
                since = self.s.setdefault("quality_wait_since", iso()); self.save()
                if (now() - dt.datetime.fromisoformat(since)).total_seconds() > QUALITY_WAIT_MIN * 60:
                    return self.blocker(f"{', '.join(quality_pending(cs))} did not finish within {QUALITY_WAIT_MIN} minutes.")
                self.heartbeat(); time.sleep(120); return
            self.s.pop("quality_wait_since", None)
            return self.save(stage="review")
        if state == CheckState.GREEN: return self.fix_quality(bad, cs)
        if state == CheckState.PENDING: return self.blocker("required checks did not finish within 4 hours.")
        runs, logs = self.failed_logs(cs)
        if classify_failure(logs) == FailureClass.INFRA:
            if not self.bump("infra_rerun"):
                return self.blocker(f"the same infrastructure step failed {LIMITS['infra_rerun']} times (runs {', '.join(runs)}).")
            time.sleep(600)
            for rid in runs:
                r = self.gh("run", "rerun", rid, "-R", self.full, "--failed", write=True, check=False)
                if r.returncode:   # refused: one empty commit instead (operating-instructions)
                    self.sh(["git", *BOT_GIT, "commit", "-q", "--allow-empty", "-m", "Re-run CI after an infrastructure failure"], cwd=self.s["wt"])
                    self.commit_push("Re-run CI"); break
            return
        if not self.bump("ci_fix"):
            return self.blocker(f"required checks still red after {LIMITS['ci_fix']} Pi fix passes.")
        n = self.s["counts"]["ci_fix"]
        self.pi(f"ci-fix-{n}", "Required CI checks failed on this branch. Failing job output (trimmed):\n```\n" + logs +
                "\n```\nFirst write three lines: the root cause, the file, the fix. Then fix the root cause with the smallest "
                "change. Never skip, delete, weaken or retry-wrap a test or gate, and add no baseline entries.")
        if not self.local_green(f"ci{n}"):
            return self.blocker(f"local verification red after CI fix pass {n}.")
        self.commit_push(f"Fix CI ({n})")

    def fix_quality(self, bad, cs):
        """Qodana / Refactoring-rationale red while required checks are green: hand the findings to Pi, never idle."""
        if not self.bump("quality_fix"):
            return self.blocker(f"{', '.join(bad)} still red after {LIMITS['quality_fix']} Pi fix passes.")
        n = self.s["counts"]["quality_fix"]
        links = "\n".join(f"- {c['name']}: {c.get('link') or 'no link'}" for c in cs if c["name"] in bad)
        _, logs = self.failed_logs([c for c in cs if c["name"] in bad])
        self.comment(f"Status: {', '.join(bad)} failed on PR #{self.s['pr']}; sending the findings to Pi (fix pass {n} of {LIMITS['quality_fix']}).")
        self.pi(f"quality-fix-{n}", f"These non-required checks failed and block the PR: {', '.join(bad)}.\n{links}\n"
                f"Findings (trimmed):\n```\n{logs or '(open the check link; no Actions log)'}\n```\n"
                "Qodana: fix every new problem in the code, with no baseline entries. Refactoring rationale: the PR description "
                "needs a `## Refactoring plan` section when a size-baselined file changes; write it to refactoring-plan.md in the "
                "repo root of this tree (the driver pastes it into the PR body) and shrink the file when you can. Smallest change.")
        if not self.local_green(f"quality{n}"): return self.blocker(f"local verification red after quality fix pass {n}.")
        plan = os.path.join(self.s["wt"], "refactoring-plan.md")
        if os.path.exists(plan):
            body = os.path.join(self.run_dir, "logs", "pr-body-plan.md")
            cur = self.gh("pr", "view", str(self.s["pr"]), "-R", self.full, "--json", "body", "-q", ".body").stdout
            if "## Refactoring plan" not in cur:
                open(body, "w").write(scrub(cur.rstrip() + "\n\n" + open(plan).read().strip() + "\n"))
                self.gh("pr", "edit", str(self.s["pr"]), "-R", self.full, "--body-file", body, write=True)
            os.remove(plan)
        self.commit_push(f"Fix {', '.join(bad)} ({n})")

    def st_review(self):
        p = self.s["plan"]; ev, failed = [], []
        for i, c in enumerate(p["criteria"], 1):
            r = subprocess.run(["bash", "-o", "pipefail", "-c", c["evidence_cmd"]], cwd=self.s["wt"], text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3600)
            out = scrub(r.stdout); open(os.path.join(self.run_dir, "logs", f"evidence-{i}.log"), "w").write(out)
            last = ([l for l in out.splitlines() if l.strip()][-1:] or [""])[0][:200]
            (ev if r.returncode == 0 else failed).append((c, last, r.returncode))
        if failed:
            if not self.bump("review_fail"):
                return self.blocker("Review FAIL twice: " + "; ".join(f"{c['text']} (exit {rc})" for c, _, rc in failed))
            self.move("In Progress")
            self.review_fail_comment("Review → In Progress\n\nReview: FAIL.\n\n" + "\n".join(f"- {c['text']}: evidence `{c['evidence_cmd']}` exit {rc}: {last}" for c, last, rc in failed)
                                     + "\n\nSending the failed criteria to Pi.")
            self.pi(f"review-fix-{self.s['counts']['review_fail']}", "These acceptance criteria fail their evidence commands:\n" +
                    "\n".join(f"- {c['text']}: `{c['evidence_cmd']}` -> {last}" for c, last, _ in failed) + "\nFix the code so each passes.")
            if not self.local_green(f"review{self.s['counts']['review_fail']}"):
                return self.blocker("local verification red after a review fix.")
            self.commit_push("Fix review findings"); self.move("Review")
            return self.save(stage="ci")
        self.save(evidence=[[c["text"], c["evidence_cmd"], last] for c, last, _ in ev])
        verdict = self.independent_review()
        while verdict is not None and verdict[0] is None:   # review infra failure: retry, never a FAIL, never sent to Pi
            if not self.bump("review_infra"):
                return self.blocker(f"independent review infra failed {LIMITS['review_infra'] + 1} times ({verdict[1]}); "
                                    "this is not a code FAIL and no findings were sent to Pi. Check the review GPUs, then resume.")
            self.log(f"independent review infra failure: {verdict[1]}; retry {self.s['counts']['review_infra']} of "
                     f"{LIMITS['review_infra']} on any free GPU")
            verdict = self.independent_review()
        if verdict is None: return
        ok, findings = verdict
        self.s["counts"]["review_infra"] = 0; self.save()
        if not ok:
            if not self.bump("review_fail"):
                return self.blocker("independent review FAIL twice: " + findings[:600])
            n = self.s["counts"]["review_fail"]
            self.move("In Progress")
            self.review_fail_comment(f"Review → In Progress\n\nReview: FAIL (independent review on the {self.gpu_label(self.s.get('reviewer_gpu'))}).\n\n"
                                     f"{findings[:3000]}\n\nSending the findings to Pi.")
            if not self.s.get("research_in_body"):   # the section is the driver's to write: redo the research, fix the body
                if not research_ok(self.research_text(), p["files"]):
                    self.s["counts"]["research"] = 0; self.save(stage="research", refactors_done=True)
                    self.st_research()
                    if self.s.get("stage") == "blocked": return
                    self.save(stage="review")
                self.sync_pr_research()
                self.comment("Research re-done after the review FAIL; the PR body's `## Refactoring research` section is updated.")   # journal activity: no commit on this path
            else:
                self.pi(f"review-fix-{n}", "An independent review of this branch failed. Findings:\n" + findings[:6000] +
                        "\nFix each finding with the smallest change. Never skip, delete or weaken a test or gate.")
                if not self.local_green(f"review{n}"): return self.blocker("local verification red after an independent-review fix.")
                self.commit_push("Fix independent review findings")
            self.move("Review")
            return self.save(stage="ci")
        self.save(stage="merge")

    def sync_pr_research(self):
        cur = self.gh("pr", "view", str(self.s["pr"]), "-R", self.full, "--json", "body", "-q", ".body", check=False).stdout
        new = with_research(cur, self.research_text())
        if new.strip() != (cur or "").strip():
            body = os.path.join(self.run_dir, "logs", "pr-body-research.md"); open(body, "w").write(scrub(new))
            self.gh("pr", "edit", str(self.s["pr"]), "-R", self.full, "--body-file", body, write=True)

    def independent_review(self):
        """Pi on a different GPU than the author reviews the diff, the issue's criteria and the `## Refactoring
        research` section of the PR body (missing or not substantive = FAIL). Returns (ok, findings), or None after a
        Blocker when no second GPU came up. ok is None for a review-infra failure (review_verdict): no / empty findings
        file or no verdict. The review runs on whichever non-author GPU has a free slot first."""
        p = self.s["plan"]
        body = self.gh("pr", "view", str(self.s["pr"]), "-R", self.full, "--json", "body", "-q", ".body", check=False).stdout
        if not research_ok(body, p["files"]):
            self.save(research_in_body=False)
            return False, (f"- The PR body has no substantive `{RESEARCH_HEAD}` section (findings per touched file, in-scope "
                           "refactors done, follow-ups filed). Every item needs it.")
        self.save(research_in_body=True)
        t_end = time.time() + REVIEWER_WAIT_H * 3600
        while True:
            rv = G.reviewer_gpus(self.author_gpus(), G.available(gpu_health(0 if self.s.get("reviewer_waited") else 600)))
            if rv or self.dry or time.time() > t_end: break
            self.save(reviewer_waited=True); self.heartbeat(); time.sleep(RECHECK_S)
        if not rv and not self.dry:
            self.blocker(f"no second GPU is up for the independent review of code written on {', '.join(self.gpu_label(g) for g in self.author_gpus())}."); return None
        rv = rv or [self.gpu()]; self.save(reviewer_gpu=rv[0])
        diff = self.sh(["git", "diff", f"{self.merge_base()}...HEAD"], cwd=self.s["wt"], check=False).stdout
        limit = 60000 if all(g in G.LARGE_GPUS for g in rv) else 24000   # any small GPU may take it: size the prompt for the smallest
        out = os.path.join(self.run_dir, "independent-review.md")
        if os.path.exists(out): os.remove(out)
        crit = "\n".join(f"- {c['text']}" for c in p["criteria"])
        sec = research_section(body)
        if len(sec) > 24000:   # the reviewer must read every verdict: whole section, or a line-boundary cut that says so
            sec = sec[:24000].rsplit("\n", 1)[0].rstrip() + "\n(the section is longer than this prompt copy; the full text is in the PR body)"
        k = self.s["counts"].get("review_infra", 0)
        self.pi(f"independent-review-{self.s['counts'].get('review_fail', 0) + 1}" + (f"-retry-{k}" if k else ""),
                     f"Independent code review of {self.repo}#{self.issue} ({p['pr_title']}). You did not write this code. Change NO "
                     "files.\n\nAcceptance criteria:\n" + crit + "\n\nThe PR's refactoring research:\n" + sec +
                     f"\n\nDiff against {self.s['default']} (read any file in this tree for context):\n```diff\n{scrub(diff)[:limit]}\n```\n\n"
                     "Check: every criterion is met by the code and its tests; tests are real (none skipped, deleted or weakened); "
                     "the repository's AGENTS.md / CLAUDE.md rules hold; the code is easy to read (names, small methods, no "
                     "duplication) and the refactoring research is substantive and its in-scope items are done; no secret, "
                     f"credential or production-setup change. Write one bullet per problem to {out} (or `- No findings.`). "
                     "End your reply with PASS when there is no blocking problem, otherwise FAIL.", 1800, gpu=",".join(rv))
        rv = self.last_task.get("gpu") or rv[0]; self.save(reviewer_gpu=rv)
        if self.sh(["git", "status", "--porcelain"], cwd=self.s["wt"], check=False).stdout.strip():
            self.log("reviewer changed files; discarding them"); self.sh(["git", "reset", "-q", "--hard"], cwd=self.s["wt"])
            self.sh(["git", "clean", "-fdq"], cwd=self.s["wt"])
        ok, findings = review_verdict(self.last_task.get("result"), scrub(open(out).read()) if os.path.exists(out) else None)
        self.log(f"independent review on {rv}: {'INFRA (retry)' if ok is None else 'PASS' if ok else 'FAIL'}")
        return ok, findings

    def check_held(self):
        """Raise PiHeld when a HOLD file appeared during a long stage pass (CI wait, review wait, deploy watch)."""
        if held(self.repo, self.issue): raise PiHeld(f"{self.full}#{self.issue} is held")

    def st_merge(self):
        self.check_held()
        pr = int(self.s["pr"]); _, cs = self.pr_checks(); state = gate_state(cs, REQUIRED.get(self.repo))
        info = json.loads(self.gh("pr", "view", str(pr), "-R", self.full, "--json", "author,headRefOid,state").stdout)
        if (self.repo, pr) in NEVER_MERGE or info["author"]["login"] != BOT or state != CheckState.GREEN or info["headRefOid"] != self.s["head"]:
            self.log(f"merge gate not met (checks {state}, head {info['headRefOid'][:8]})")
            if not self.bump("merge_gate"):   # was an unbounded ci -> review -> merge spin
                return self.blocker(f"merge gate not met after {LIMITS['merge_gate']} tries (checks {state}, PR head "
                                    f"`{info['headRefOid'][:8]}` vs driver head `{str(self.s.get('head'))[:8]}`, author {info['author']['login']}).")
            time.sleep(120); return self.save(stage="ci")
        if info["state"] != "MERGED":
            self.gh(*merge_args(self.full, pr, self.s["head"]), write=True)
        sha = self.gh("pr", "view", str(pr), "-R", self.full, "--json", "mergeCommit", "-q", ".mergeCommit.oid").stdout.strip()
        self.save(merge_sha=sha, stage="main")

    def st_main(self):
        sha, d_only = self.s["merge_sha"], docs_only(self.s["plan"]["files"])
        no_release = release_skipped(self.repo, self.merge_files(sha))
        time.sleep(30); runs = []
        for _ in range(20):   # wait for push runs of the merge commit to appear (none when paths-ignore skips them)
            r = self.gh("api", f"repos/{self.full}/actions/runs?head_sha={sha}&event=push&per_page=50", "--jq",
                        "[.workflow_runs[]|{id,name,conclusion}]", check=False)
            runs = json.loads(r.stdout or "[]")
            if runs: break
            time.sleep(30)
        for run in runs:
            self.gh("run", "watch", str(run["id"]), "-R", self.full, "--interval", "60", check=False, timeout=6 * 3600)
        r = self.gh("api", f"repos/{self.full}/actions/runs?head_sha={sha}&event=push&per_page=50", "--jq",
                    "[.workflow_runs[]|{name,conclusion}]", check=False)
        red = [x["name"] for x in json.loads(r.stdout or "[]") if x["conclusion"] not in ("success", "skipped", "neutral")]
        ev = "\n".join(f"- {t}: `{cmd}` passed — {last}" for t, cmd, last in self.s.get("evidence", []))
        col = "Done" if (d_only or no_release) and not red else "Merged"
        live = (f"This change touches only paths the system pipeline ignores (`factory/`, docs, pinned environment files) and "
                f"is live from main (merge `{sha[:8]}`); factory code runs from main on the factory box, and the system "
                "pipeline does not build a release for it, so no release is needed.\n\n") if no_release and col == "Done" else ""
        self.move(col)
        self.comment(f"Review → {col}\n\nReview: PASS. Squash-merged PR #{self.s['pr']} (head `{self.s['head'][:8]}`) as `{sha}`. "
                     f"Required checks green.\n\n{live}{ev}\n\n{self.usage(final=(col == 'Done'))}")
        key = f"{self.repo} main"
        if red:
            red_set(key, f"{', '.join(red)} red at `{sha[:8]}`")
            self.fix_forward_issue(key, f"{', '.join(red)} of `{sha[:8]}` on the default branch")
            return self.blocker(f"default-branch run(s) {', '.join(red)} of merge `{sha[:8]}` are red. Intake is stopped; a "
                                "fix-forward issue is filed.", who="the factory bot (fix forward)")
        if runs: red_clear(key)   # a green default-branch run of a newer commit: main is green again
        self.save(stage="done" if d_only or no_release or self.repo not in DEPLOYABLE else "deploy")

    def merge_files(self, sha):
        """Files the merge commit changed ([] when GitHub cannot say, so the item still waits for its deploy)."""
        r = self.gh("api", f"repos/{self.full}/commits/{sha}", "--jq", "[.files[].filename]", check=False)
        try: return json.loads(r.stdout or "[]")
        except Exception: return []

    def st_deploy(self, max_h=48):
        dep, sha, t_end = DEPLOYABLE[self.repo], self.s["merge_sha"], time.time() + max_h * 3600
        while time.time() < t_end:
            try:
                d = json.load(urllib.request.urlopen(DELIVERY, timeout=30))
                in_env, ver = {}, {}
                for e in d["environments"]:
                    x = next((x for x in e["deployables"] if x.get("name") == dep), None)
                    if not x: continue
                    st = json.loads(self.gh("api", f"repos/{self.full}/compare/{sha}...{x['commit']}", "--jq", "{status:.status}", check=False).stdout or "{}").get("status")
                    healthy = any(a.get("name") == dep and (a.get("last") or {}).get("result") == "healthy" for a in (e.get("health") or {}).get("containerApps", [])) or dep == "system"
                    rk = f"{dep} {e['name']}"
                    if env_red(e, dep) and st in ("ahead", "identical"):
                        if rk not in red_load():
                            red_set(rk, f"{dep} {x.get('version')} unhealthy in {e['name']}")
                            self.fix_forward_issue(rk, f"{dep} {x.get('version')} is not healthy in {e['name']} (delivery.json)", "cmdemo1-system")
                            self.comment(f"Status: {dep} {x.get('version')} (contains merge `{sha[:8]}`) is not healthy in {e['name']}. "
                                         "Intake is stopped and a fix-forward issue is filed; the driver keeps watching.")
                    elif healthy and rk in red_load(): red_clear(rk)
                    in_env[e["name"]] = st in ("ahead", "identical") and healthy; ver[e["name"]] = (x.get("version"), x["commit"])
                moves = deploy_moves(self.s.get("column", "Merged"), in_env)
                if moves:
                    env = {"TDD": "tdd", "UAT": "uat", "Done": "prod"}[moves[-1]]
                    self.move(moves[-1])
                    path = " → ".join([self._col_before(moves)] + moves)
                    v, c = ver[env]
                    self.comment(f"{path}\n\n{dep} {v} runs in {env} (`{c[:8]}` contains merge `{sha[:8]}`), healthy."
                                 + (f"\n\n{self.usage(final=True)}" if moves[-1] == "Done" else ""))
                    if moves[-1] == "Done": return self.save(stage="done")
            except Exception as e:
                self.log(f"deploy check error: {e}")
            self.heartbeat(); time.sleep(600)
        self.log("deploy follow-through window ended; the bot's Deployments sweep takes over")
        self.save(stage="done", deploy_handoff=True)

    def fix_forward_issue(self, key, what, repo=None):
        """One open `fix-forward` issue per red key, assigned to the factory bot so its issue-assigned wake works it
        first (intake is stopped for everything else until it is green again)."""
        full = f"{ORG}/{repo or self.repo}"; title = f"Fix forward: {key} is red"
        r = self.gh("api", f"repos/{full}/issues?state=open&labels=fix-forward&per_page=100", "--jq", "[.[].title]", check=False)
        try:
            if title in json.loads(r.stdout or "[]"): return
        except Exception: pass
        self.gh("label", "create", "fix-forward", "-R", full, "--color", "B60205", "--description", "Red main or environment; fix forward",
                write=True, check=False)
        body = os.path.join(self.run_dir, "logs", f"fix-forward-{int(time.time())}.md")
        open(body, "w").write(scrub(f"{what}.\n\nFound while following #{self.issue} (run `{self.s.get('run_id')}`). Fix forward with a "
                                    "normal PR (plan `fix_forward: true`); never re-run, re-pin or promote by hand, and never "
                                    "weaken a test or gate. Intake of other items stays stopped until this is green.\n"))
        self.gh("issue", "create", "-R", full, "--title", title, "--body-file", body, "--label", "fix-forward", "--assignee", BOT,
                write=True, check=False)

    def _col_before(self, moves):
        return BOARD_ORDER[BOARD_ORDER.index(moves[0]) - 1]

def watchdog_exit(drv):
    """Driver-exit hook: the shared watchdog checks (factory/pi/watchdog.py) run exactly once when a
    driver run ends (done, blocker or error). A check's failure (and a failed `import watchdog`) is logged;
    this function never raises and never changes the driver's exit status or replaces its exception."""
    try:
        import watchdog
        watchdog.run_checks(log=drv.log)
    except Exception as e:
        try:
            drv.log(f"watchdog exit hook failed: {scrub(str(e))}")
        except Exception:
            pass   # never let the hook (or its log) change the driver's exit

# ---------------------------------------------------------------- commands
def draft_plan_prompt(repo, issue, title, body, out):
    """The draft-plan prompt (out path, prompt text): Pi drafts the plan JSON for <repo>#<issue> into `out` and changes
    no repository files. Pure: it reads nothing and writes nothing, so the prompt can be tested without a driver."""
    return out, (
        f"Draft an implementation plan for GitHub issue {repo}#{issue}. Read the repository (AGENTS.md, CLAUDE.md, "
        f"the files involved) but change NO files. Write the first complete draft early (do not wait for the last minutes "
        "of the timeout), then refine it: as you learn, add, fix and remove entries until the draft is complete and valid.\n\n"
        f"Issue title: {title}\n\nIssue body:\n{body}\n\n"
        f"Write the plan as JSON to the file {out} with keys: repo ({repo!r}), issue ({issue}), branch "
        f"('{BOT}/{issue}-<short-slug>'), files (every file to change), constraints (each Notes/Constraints/Out-of-scope "
        "sentence quoted), criteria (one per acceptance criterion: text, how, evidence_cmd = a shell command that exits 0 "
        "only when the criterion holds, e.g. a filtered test run or an HTTP probe), tasks (small ordered Pi tasks: name, "
        "prompt; one test or one code change each; tests first), size ('large' for big or cross-cutting work, 'small' for a UI or "
        "test-only change), verify_cmd (the repo's real build+test command, "
        "narrowed to the touched projects), pr_title, pr_summary (one line). "
        "Write a first complete, valid plan.draft.json as soon as you know the files involved (after at most a few reads), "
        "then refine it in place; never leave the file unwritten.")

def cmd_draft_plan(a):
    d = Driver(a.repo, a.issue, top_session=a.top_session)
    iss = json.loads(d.gh("api", f"repos/{d.full}/issues/{a.issue}", "--jq", "{title,body}").stdout)
    d.plan_worktree()
    out, prompt = draft_plan_prompt(a.repo, a.issue, iss["title"], iss["body"], os.path.join(d.run_dir, PLAN_DRAFT_FILE))
    try: ok = d.pi("draft-plan", prompt, DRAFT_PLAN_TIMEOUT_S, gpu=G.LARGE_GPU)   # plan drafting runs before the gpu stage: no gpu recorded yet
    except PiNotStarted as e: print(json.dumps({"draft": out, "pi_pass": False, "errors": [str(e)]}, indent=1)); sys.exit(1)
    try:
        p = json.load(open(out)); errs = validate_plan(p)
    except Exception as e:
        p, errs = None, [f"no valid JSON plan: {e}"]
    print(json.dumps({"draft": out, "pi_pass": ok, "errors": errs}, indent=1))
    print("Review plan.draft.json; copy it to plan.json (edit as needed), then run `item-loop start`.")
    sys.exit(0 if not errs else 1)

def refuse_held(a):
    h = held(a.repo, a.issue)
    if h: print(f"{a.repo}#{a.issue} is held, not starting: {h[:300]}"); sys.exit(0)

def cmd_start(a):
    refuse_held(a)
    d = Driver(a.repo, a.issue, top_session=a.top_session)
    plan_p = os.path.join(d.run_dir, PLAN_FILE); p = json.load(open(plan_p))
    labels = d.gh("api", f"repos/{d.full}/issues/{a.issue}", "--jq", "[.labels[].name]", check=False).stdout
    try: labels = json.loads(labels or "[]")
    except Exception: labels = []
    if "enhancement" in labels and p.get("kind") != "enhancement": p["kind"] = "enhancement"
    if "fix-forward" in labels: p["fix_forward"] = True
    errs = validate_plan(p)
    if errs: print("plan.json invalid:\n- " + "\n- ".join(errs)); sys.exit(2)
    json.dump(p, open(plan_p, "w"), indent=1)
    red = red_load()
    if not intake_open(red, p):
        print("NOTE: intake is stopped while red (" + "; ".join(red) + "); the driver waits in Todo until it is green.")
    d.s.setdefault("top_sessions", [])
    if a.top_session and a.top_session not in d.s["top_sessions"]: d.s["top_sessions"].append(a.top_session)
    if d.s.get("status") in ("blocked", "error") and a.resume:
        d.s = apply_resume(d.s)   # Jeffrey answered the Blocker: the limits start again
    d.save()
    log = open(os.path.join(d.run_dir, "driver.out"), "a")
    cmd = [sys.executable, os.path.abspath(__file__), "run", "--repo", a.repo, "--issue", str(a.issue)] + (["--dry-run"] if a.dry_run else [])
    p = subprocess.Popen(["nohup", *cmd], stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
    print(f"driver started pid {p.pid}; state {d.state_p}. End your turn; GitHub events wake you.")

def cmd_run(a): refuse_held(a); Driver(a.repo, a.issue, dry_run=a.dry_run).run()

def cmd_status(a):
    d = Driver(a.repo, a.issue); s = d.s
    alive = False
    if s.get("pid"):
        try: os.kill(int(s["pid"]), 0); alive = True
        except Exception: pass
    print(json.dumps({k: s.get(k) for k in ("run_id", "stage", "status", "gpu", "size", "reviewer_gpu", "wait_why", "pr", "head",
                                             "merge_sha", "column", "counts", "blocker", "error", "wake_reason", "updated")}
                     | {"alive": alive, "red": sorted(red_load())}))

def cmd_note_wake(a):
    d = Driver(a.repo, a.issue); d.s.setdefault("top_sessions", [])
    if a.top_session not in d.s["top_sessions"]: d.s["top_sessions"].append(a.top_session)
    d.save(); meta_p = os.path.join(d.run_dir, "run.json")
    if os.path.exists(meta_p):
        m = json.load(open(meta_p)); m["top_sessions"] = d.s["top_sessions"]; json.dump(m, open(meta_p, "w"), indent=1)

def cmd_red(a):
    if a.action == "set": red_set(a.key, a.what or "red")
    elif a.action == "clear": red_clear(a.key)
    print(json.dumps(red_load(), indent=1))

def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="c", required=True)
    r = sp.add_parser("red"); r.add_argument("action", choices=("status", "set", "clear"))
    r.add_argument("--key"); r.add_argument("--what")
    for name in ("draft-plan", "start", "run", "status", "note-wake"):
        x = sp.add_parser(name); x.add_argument("--repo", required=True); x.add_argument("--issue", type=int, required=True)
        x.add_argument("--top-session", required=(name == "note-wake"))
        x.add_argument("--dry-run", action="store_true"); x.add_argument("--resume", action="store_true")
    a = ap.parse_args()
    if a.c == "red":
        if a.action != "status" and not a.key: ap.error("--key is required")
        return cmd_red(a)
    {"draft-plan": cmd_draft_plan, "start": cmd_start, "run": cmd_run, "status": cmd_status, "note-wake": cmd_note_wake}[a.c](a)

if __name__ == "__main__": main()
