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
from typing import NamedTuple
import argparse, datetime as dt, fcntl, json, os, re, shlex, subprocess, sys, time, urllib.request, uuid


sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gpu as G
from scrub import SECRET_RE, scrub, add_secret_source   # the one scrub rule set lives in scrub.py (#838), re-exported here so watchdog, run-task and the tests keep importing it from item_loop
from runner import run_cmd   # the one runner with a deadline lives in runner.py (#839), re-exported here for the same reason: run-task uses it without importing this driver


class Command(NamedTuple):
    """A command the driver will run, with the policy that sh() used to sniff out of argv (cmdemo1-system#947):
    `argv` is the command (a list of words or a shell string), `is_gh` says it is a `gh` call (the App-token
    first-try and the rate-limit retry apply), `app_ok` says the App token may be used for it (False for
    `pr create` / `issue create`, which stay on the user login), and `write` marks a GitHub- or remote-changing
    step (skipped, logged, in dry-run). Built by `Driver.gh()`; a bare list or string passed to `Driver.sh()`
    is a non-gh command with no App token and no rate-limit retry, and its `write` flag comes from the `write=`
    keyword."""
    argv: object
    is_gh: bool = False
    app_ok: bool = False
    write: bool = False

# String enums for check states and failure types (values are string literals for JSON compatibility).
class CheckState(StrEnum):
    GREEN = "GREEN"
    RED = "RED"
    PENDING = "PENDING"

class FailureClass(StrEnum):
    INFRA = "infra"
    CODE = "code"

class CheckBucket(StrEnum):
    """The gh `pr checks --json name,bucket` buckets as a value object (cmdemo1-system#870): the one place that
    names gh's check-bucket vocabulary, so the green / red / running classification and the pending default are
    built from these members instead of re-typing the raw literals. Values are string literals for JSON
    compatibility (a StrEnum member == its string value). gh also emits buckets outside this set (e.g. `queued`),
    which stay open strings and read as running -- `bucket()` never coerces, it only defaults to PENDING."""
    PASS = "pass"
    FAIL = "fail"
    PENDING = "pending"
    CANCEL = "cancel"
    SKIPPING = "skipping"

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
# Stages in which an item is In Progress or Review (WIP counting). Waiting for a GPU, blocked, main, deploy and done do not.
ACTIVE_STAGES = ("pickup", "research", "implement", "local-verify", "pr", "ci", "review", "merge")
# Stages in which an item holds its recorded (author) GPU slot. Review and merge do not: the independent review runs
# on a different (non-author) GPU enforced by gpu_gate.py, and merge is gate-only (no Pi task on the author GPU).
GPU_HOLDING_STAGES = ("pickup", "research", "implement", "local-verify", "pr", "ci")
# Never changed by an enhancement PR: credentials, secrets and production setup.
PROTECTED_RE = re.compile(r"(?i)(^|/)(\.github/workflows|environments/prod|infra|octopus)/|(^|/)\.env(\.|$)|secret|"
                          r"credential|\.(pem|pfx|key)$|appsettings\.prod|keyvault|(^|/)nuget\.config$")
FOLLOWUP_MAX = 5          # follow-up refactoring issues one item may file
RESEARCH_MIN_CHARS = 300
DRIVER_MARK = "<!-- factory-pi-driver -->"
# Existing limits (operating-instructions): 2 Review FAILs, 3 infrastructure reruns; then a Blocker.
LIMITS = {"local_fix": 3, "ci_fix": 3, "review_fail": 2, "infra_rerun": 3, "quality_fix": 3, "merge_gate": 3, "research": 2, "review_infra": 2, "pi_relaunch": 2, "conflict_merge": 2}
def fresh_counts(): return {k: 0 for k in LIMITS}   # one place says what "every limit back to zero" is (a new item's, and a resume's)
HANDOFF_START_S = 900     # a Pi hand-off with no model output 15 min after it got its slot is killed and relaunched (t85u)
HANDOFF_STALL_S = 1800    # ... or, once started, no session record and no CPU work in its process group for 30 min
HANDOFF_SLOT_WAIT_S = 900 # the first attempt waits this long for its own GPU's slot, then relaunches on any free GPU
ANY_SLOT_WAIT_S = 2 * 3600  # a relaunch (any free GPU) or a review waits up to 2 h for a slot: a busy queue is no failure
DRAFT_PLAN_TIMEOUT_S = 2700  # the draft-plan Pi pass: cold prompt reads on pro5000 made every 1500 s draft-plan time out (cmdemo1-system#884)
RESEARCH_TIMEOUT_S = 1500    # the mandatory refactoring-research Pi pass
PI_TASK_TIMEOUT_S = G.PI_TASK_TIMEOUT_S   # the default timeout for one plan task run through task_passes
# The driver's command timeouts, named in one place (cmdemo1-system#966): seconds per command kind, so the inline
# literals (evidence, gh run watch, wait_ci) read from here instead of re-typing the number at each call site.
# `verify`, `git` and `api` name the intended budgets for command kinds that currently inherit run_cmd's deadline
# (no explicit timeout at the call site) -- naming them here is what a future behaviour change edits.
TIMEOUTS = {
    "verify": 3600,            # one verify_cmd pass (Driver.verify)
    "evidence": 3600,          # one evidence_cmd pass (Driver.evidence_results / st_review)
    "git": 600,                # one git operation (clone, fetch, push -- Driver.sh / Driver.git)
    "gh_watch": 6 * 3600,      # gh run watch of one default-branch push run (st_main)
    "wait_ci": 600,            # one gh pr checks --watch slice (Driver.wait_ci)
    "api": G.MIN_CLIENT_TIMEOUT_S,   # one gh api call (floor: live via FACTORY_MIN_CLIENT_TIMEOUT_S)
}
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

def write_text(path, text):
    """Write `text` to `path`, closing the handle (cmdemo1-system#898: every `open(p,'w').write(x)` in this module
    leaked a handle; this is the one writer for plain text files)."""
    with open(path, "w") as f: f.write(text)

def read_text(path):
    """Read all of `path` and close the handle (cmdemo1-system#898)."""
    with open(path) as f: return f.read()

def append_text(path, text):
    """Append `text` to `path`, closing the handle (cmdemo1-system#898; used by Driver.log)."""
    with open(path, "a") as f: f.write(text)


class HandoffBudgets:
    """The Pi hand-off budget as one value object (cmdemo1-system#954): the start / stall / slot clocks, the per-pass
    task timeouts (draft-plan, research, the shared default task timeout) and the GPU-wait pacing, held as
    `datetime.timedelta`s with the relationships that decide whether a driver kills its own healthy run asserted on
    construction -- every clock positive, `stall > start` (a run that has produced model output is given a longer
    no-activity clock than the no-start clock), `task_timeout > start` (the wall-clock budget outlasts the no-start
    clock, so a healthy run is never timed out before it has had its full no-start window) and `any_slot_wait > start`
    (a relaunch / review queued on a busy GPU is not killed before it has had its no-start window either). The gh
    rate-limit retry knobs (the `GH_RETRY_*` family) are the driver's own pacing and stay live-tunable: the object
    documents them as read live through (the driver retunes them by rebinding the module names) rather than frozen
    on the object.

    Built once (HANDOFF_BUDGETS) from the module constants and handed to `Driver.pi` and the run-task launch
    (`run_task_args`), so the numbers and the one message that names them live in exactly one place. `.describe()`
    owns the user-facing no-start text (the `// 60` conversions), `.slot_wait()` owns the first-attempt-vs-relaunch
    rule. The module ints (HANDOFF_START_S, ...) remain the single source of truth and the wire format: this object is
    built from them, never the reverse, so every value sent to run-task and every message string is unchanged.
    """

    def __init__(self, start=HANDOFF_START_S, stall=HANDOFF_STALL_S, first_slot_wait=HANDOFF_SLOT_WAIT_S,
                 any_slot_wait=ANY_SLOT_WAIT_S, draft_plan=DRAFT_PLAN_TIMEOUT_S, research=RESEARCH_TIMEOUT_S,
                 task_timeout=PI_TASK_TIMEOUT_S, gpu_wait=GPU_WAIT_S, gpu_wait_h=GPU_WAIT_H):
        self.start = dt.timedelta(seconds=start)
        self.stall = dt.timedelta(seconds=stall)
        self.first_slot_wait = dt.timedelta(seconds=first_slot_wait)   # the item's own GPU slot, first attempt
        self.any_slot_wait = dt.timedelta(seconds=any_slot_wait)       # any free GPU: a relaunch or a review
        self.draft_plan = dt.timedelta(seconds=draft_plan)
        self.research = dt.timedelta(seconds=research)
        self.task_timeout = dt.timedelta(seconds=task_timeout)
        self.gpu_wait = dt.timedelta(seconds=gpu_wait)
        self.gpu_wait_h = int(gpu_wait_h)
        for name, td in (("start", self.start), ("stall", self.stall), ("first_slot_wait", self.first_slot_wait),
                         ("any_slot_wait", self.any_slot_wait), ("draft_plan", self.draft_plan), ("research", self.research),
                         ("task_timeout", self.task_timeout), ("gpu_wait", self.gpu_wait)):
            if td <= dt.timedelta(0):
                raise ValueError(f"HandoffBudgets.{name} must be positive, got {td}")
        if self.gpu_wait_h <= 0:
            raise ValueError(f"HandoffBudgets.gpu_wait_h must be positive, got {self.gpu_wait_h}")
        if self.stall <= self.start:
            raise ValueError("the stall budget must exceed the start budget: a run that has produced model output is "
                             f"given a longer no-activity clock ({self.stall}) than the no-start clock ({self.start})")
        if self.task_timeout <= self.start:
            raise ValueError("the task timeout must outlast the start clock, or a healthy run is timed out before it has "
                             f"had its full no-start window (task {self.task_timeout} <= start {self.start})")
        if self.any_slot_wait <= self.start:
            raise ValueError("the any-slot wait (a relaunch / review on a busy queue) must exceed the start clock, so a "
                             f"queued hand-off is not killed before it has had its no-start window "
                             f"({self.any_slot_wait} <= {self.start})")

    # ---- the seconds the run-task launch is sent (int, the wire format)
    @property
    def start_s(self): return int(self.start.total_seconds())
    @property
    def stall_s(self): return int(self.stall.total_seconds())
    @property
    def slot_wait_s(self): return int(self.first_slot_wait.total_seconds())
    @property
    def any_slot_wait_s(self): return int(self.any_slot_wait.total_seconds())
    @property
    def draft_plan_s(self): return int(self.draft_plan.total_seconds())
    @property
    def research_s(self): return int(self.research.total_seconds())
    @property
    def task_timeout_s(self): return int(self.task_timeout.total_seconds())
    @property
    def gpu_wait_s(self): return int(self.gpu_wait.total_seconds())

    def slot_wait(self, review, attempt):
        """The slot wait of one attempt in seconds: the item's own GPU slot on the first attempt; any free slot (a
        busy queue is no failure) on a relaunch or a review."""
        return self.any_slot_wait_s if review or attempt else self.slot_wait_s

    def describe(self, name, result):
        """The PiNotStarted message after the last relaunch (the stage ends in a Blocker with this text): the one place
        that turns the start / stall clocks into the human `// 60` minutes the bot reads."""
        return (f"Pi hand-off `{name}` did not start or stalled ({result}: no GPU slot, no model "
                f"output within {int(self.start.total_seconds()) // 60} min of getting one, "
                f"or no activity for {int(self.stall.total_seconds()) // 60} min) "
                f"after {LIMITS['pi_relaunch']} relaunches on any free GPU.")

    def __repr__(self):
        return (f"HandoffBudgets(start={self.start_s}s, stall={self.stall_s}s, slot_wait={self.slot_wait_s}s, "
                f"any_slot_wait={self.any_slot_wait_s}s, draft_plan={self.draft_plan_s}s, research={self.research_s}s, "
                f"task_timeout={self.task_timeout_s}s, gpu_wait={self.gpu_wait_s}s, gpu_wait_h={self.gpu_wait_h})")


# The one hand-off budget, built from the module constants above (their single source of truth). Driver.pi and the
# run-task launch read the clocks and the no-start message from here; the gh rate-limit knobs stay live on the module.
HANDOFF_BUDGETS = HandoffBudgets()

INFRA_RE = re.compile(r"(?i)(could not resolve host|temporary failure in name resolution|tls handshake timeout|"
                      r"connection reset by peer|econnreset|etimedout|503 service unavailable|502 bad gateway|"
                      r"toomanyrequests|rate limit exceeded|no space left on device|runner .* lost communication|"
                      r"the runner has received a shutdown signal|unable to (access|connect)|failed to fetch|"
                      r"apt-get .* failed|error response from daemon|context deadline exceeded)")
CODE_RE = re.compile(r"(?i)(error CS\d+|error [A-Z]{2,}\d+|\bFailed\b.*\btest|\bFAIL\b|Assert|Exception:|"
                     r"warning CS\d+|expected .* but|npm ERR!|Traceback)")


def now(): return dt.datetime.now(dt.timezone.utc)
def iso(t=None): return (t or now()).isoformat(timespec="seconds")

# ---------------------------------------------------------------- pure helpers (unit-tested)

# ---- GitHub App token for gh (own API quota). Opt-in: set GH_APP_TOKEN_CMD to a command that prints an installation token.
GH_APP_TOKEN_TTL_S = 50 * 60   # installation tokens last 1h; refresh before that
_APP_DENIED_RE = re.compile(r"HTTP 40[13]\b|Resource not accessible|Forbidden|Bad credentials|API rate limit|Repository rule violations|not authorized to push|protected branch", re.I)   # clear authorization refusals only
GH_APP_MINT_RETRY_S = 5 * 60   # a failed mint is not retried on every gh call
_app_tok = {"v": None, "at": 0.0}
# The token itself stays here (scrub.py never imports item_loop, so there is no cycle): it registers as a caller-owned
# secret source, so scrub() asks this cache for its value before the environment pass.
add_secret_source(lambda: _app_tok["v"])

def app_denied(output):
    """True when gh's output says the App token was refused (401/403, missing permission, branch rule, App rate limit)."""
    return bool(_APP_DENIED_RE.search("\n".join((output or "").splitlines()[-8:])))

def app_token(env=None, clock=time.time, runner=run_cmd):
    """Cached App installation token from $GH_APP_TOKEN_CMD, or None when unset / the command fails (callers then use the user login).
    Never logged: scrub() redacts it (ghs_ pattern and its exact value) and it is only passed to gh through GH_TOKEN.
    The mint command runs through run_cmd (#839), so on its 60 s timeout everything it started is killed with it."""
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
    """The PR number from gh output: a plain number (gh pr list -q .[0].number) or a PR URL (gh pr create),
    with or without a trailing slash. None when neither (the 'no open PR' message or unexpected output)."""
    t = str(text or "").strip().rstrip("/")
    if t.isdigit(): return int(t)
    m = re.search(r"/pull/(\d+)", t)
    return int(m.group(1)) if m else None

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

def task_slug(name):
    """The file-safe form of a Pi task name: letters, digits, . _ - and '-', everything else one '-'. run-task keeps
    the same mapping (it slugs the --task name for pi-sessions/ and the per-task prompt.md / .out / .progress.json),
    so the driver's prompt path and run-task's session and progress paths always agree (cmdemo1-system#959: a plan
    task name with '/' crashed the raw-name prompt-file write). Idempotent: slugging an already-slugged name is a
    no-op, so run-task re-slugging the driver's --task value changes nothing."""
    return re.sub(r"[^A-Za-z0-9._-]", "-", str(name))

# ---- the one "latest attempt wins" rule for a `gh pr checks --json name,bucket` list (cmdemo1-system#886)
# gh lists one entry per attempt, so a rerun puts the same check name in the list twice. Which attempt counts is
# decided by latest_attempt() and nowhere else: a name that has passed stays green (the rerun's pass beats the
# earlier failure), and the last entry of a name that never passed is its current state. MergeGate is its only
# reader, so the required checks and the quality checks can no longer disagree about the same list.
GREEN_BUCKETS = (CheckBucket.PASS, CheckBucket.SKIPPING)   # gh's buckets that mean "finished and good" (skipping counts: not applicable)
RED_BUCKETS = (CheckBucket.FAIL, CheckBucket.CANCEL)       # ... "finished and bad"; every other bucket (pending, queued) is still running

def bucket(check):
    """One check entry's bucket; gh omits it while the check is still queued, which means pending."""
    return check.get("bucket") or CheckBucket.PENDING

def bucket_green(b): return b in GREEN_BUCKETS
def bucket_red(b): return b in RED_BUCKETS
def bucket_running(b): return not bucket_green(b) and not bucket_red(b)

def latest_attempt(checks):
    """name -> the bucket of the attempt that counts, for a `gh pr checks --json` list (the rule above)."""
    st = {}
    for c in checks or []:
        b = bucket(c)
        if bucket_green(st.get(c["name"])) and not bucket_green(b): continue   # a passed check stays passed
        st[c["name"]] = b
    return st

def is_quality_check(name):
    """True for the Qodana / Refactoring-rationale checks: not required to merge, but a red or unfinished one holds the PR."""
    return any(q in str(name).lower() for q in QUALITY_CHECKS)

class MergeGate:
    """The merge gate as a Specification-style value object (cmdemo1-system#886): the PR's `gh pr checks --json` list
    plus the names required to merge, answering the questions the gate asks so no caller re-derives them from raw
    buckets -- `red() / pending() / green()` for the gate as a whole (required checks AND the Qodana /
    Refactoring-rationale hard gate), `required_state()` for the required names alone, and `quality_red() /
    quality_pending()` for the quality checks. Pure: it reads the list once through latest_attempt() and nothing else
    decides which attempt of a check counts.

    `required=None` means every check in the list is required (what checks_state has always meant); a name required
    but missing from the list counts as pending, and an empty required-and-present list is PENDING, never GREEN.
    """

    def __init__(self, checks, required=None):
        self.buckets = latest_attempt(checks)
        self.required = list(required) if required else None

    def __repr__(self):
        return f"MergeGate(required={self.required!r}, buckets={self.buckets!r})"

    def _state(self, names):
        if not names: return CheckState.PENDING
        rs = [self.buckets.get(n, CheckBucket.PENDING) for n in names]
        if any(bucket_red(b) for b in rs): return CheckState.RED
        if all(bucket_green(b) for b in rs): return CheckState.GREEN
        return CheckState.PENDING

    def required_state(self):
        """GREEN / RED / PENDING for the required names only: what checks_state answers."""
        return self._state(self.required or list(self.buckets))

    def quality_names(self):
        return [n for n in self.buckets if is_quality_check(n)]

    def quality_red(self):
        """Names of the quality checks that failed: the hard gate that sends the findings to Pi."""
        return sorted(n for n in self.quality_names() if bucket_red(self.buckets[n]))

    def quality_pending(self):
        """Names of the quality checks still running: the gate waits for them, never merges past them."""
        return sorted(n for n in self.quality_names() if bucket_running(self.buckets[n]))

    def red(self): return self.required_state() == CheckState.RED or bool(self.quality_red())
    def pending(self): return self.required_state() == CheckState.PENDING or bool(self.quality_pending())
    def green(self): return not self.red() and not self.pending()

    def state(self):
        """The whole gate as the CheckState the stages log: what gate_state answers."""
        if self.red(): return CheckState.RED
        if self.pending(): return CheckState.PENDING
        return CheckState.GREEN

def checks_state(checks, required):
    """checks: [{name, bucket}] from `gh pr checks --json`. required: names, or None = every check.
    Thin wrapper over MergeGate.required_state (the latest-attempt rule lives in latest_attempt)."""
    return MergeGate(checks, required).required_state()

def quality_states(checks):
    """name -> bucket for the Qodana / Refactoring-rationale checks, on the same latest_attempt rule as the rest."""
    g = MergeGate(checks)
    return {n: g.buckets[n] for n in g.quality_names()}

def quality_failures(checks):
    """Names of failing Qodana / Refactoring-rationale checks (latest attempt of each name wins)."""
    return MergeGate(checks).quality_red()

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

def _task_timeouts():
    """Spec for a plan task's optional `timeout`: every task omits it or gives a positive int at or above
    MIN_CLIENT_TIMEOUT_S (the floor every Pi client timeout has). The message names the offending task index,
    like _entry_fields."""
    def bad(p):
        return [i for i, t in enumerate(p.get("tasks") or [])
                if "timeout" in t and not (isinstance(t["timeout"], int) and not isinstance(t["timeout"], bool)
                                           and t["timeout"] >= G.MIN_CLIENT_TIMEOUT_S)]
    return (lambda p: not bad(p)), lambda p: "; ".join(
        f"tasks[{i}] timeout must be a positive int at or above {G.MIN_CLIENT_TIMEOUT_S}" for i in bad(p))

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
    _task_timeouts(),
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

def origin_ref(ref):
    """The remote-tracking ref for a branch name (`origin/<ref>`): the one place that spelling is built
    (cmdemo1-system#871) -- no stage or helper may hand-build an `origin/...` string."""
    return f"origin/{ref}"

def remote_refspec(branch):
    """The fetch refspec that materializes `branch` as a remote-tracking ref: the one place the
    `refs/remotes/origin/...` spelling is built (cmdemo1-system#871)."""
    return f"{branch}:refs/remotes/origin/{branch}"

class GitRepo:
    """A git working tree as a value object (cmdemo1-system#871): one path plus the git calls the driver makes
    inside it. Every call goes through the injected `sh` (Driver.sh: the logging, the dry-run skip and the gh
    rate-limit backoff live there, never in a git argument list), always with `cwd` set to the bound path, so the
    work-tree path and the `origin/...` refs (origin_ref) cannot drift between the stages that used to spell
    `cwd=self.s["wt"]` and `f"origin/{...}"` on every call.

    Driver builds one for the item's work tree in __init__ (`self.git`, through the Driver._sh seam so a test's
    `d.sh = ...` replacement is honored at call time); the module-level merge_base / staged_files keep their
    (sh, wt, default) signatures by building a throwaway GitRepo. The merge-base rule (merge-base of HEAD and
    origin/<default>, falling back to origin/<default> when git cannot resolve it, so the protected-file gate is
    never made more permissive than it was) lives in merge_base(), and nowhere else."""

    def __init__(self, sh, path):
        self.sh = sh
        self.path = path

    def _git(self, *a, **k):
        k.setdefault("cwd", self.path)
        return self.sh(["git", *a], **k)

    def add_all(self):
        return self._git("add", "-A")

    def head(self):
        return self._git("rev-parse", "HEAD").stdout.strip()

    def merge_base(self, base):
        """merge-base(HEAD, origin/<base>), or origin/<base> when git cannot resolve it (a branch behind main may
        still show a false protected file, never a missed one: the gate never widens)."""
        r = self._git("merge-base", "HEAD", origin_ref(base), check=False)
        b = (r.stdout or "").strip()
        return origin_ref(base) if r.returncode or not b else b

    def changed_names(self, base):
        """Paths staged in the index relative to merge_base(base): the branch's own staged changes, never commits
        main made after the branch forked off."""
        return self._git("diff", "--cached", "--name-only", self.merge_base(base), check=False).stdout.split()

    def diff(self, base):
        """The branch's diff against merge_base(base) (`<merge-base>...HEAD`): what the independent review reads."""
        return self._git("diff", f"{self.merge_base(base)}...HEAD", check=False).stdout

    def staged_changes(self):
        """True when the index holds a change (git diff --cached --quiet exits non-zero)."""
        return bool(self._git("diff", "--cached", "--quiet", check=False).returncode)

    def staged_stat(self):
        return self._git("diff", "--cached", "--stat").stdout

    def commit(self, msg, author_args=BOT_GIT, allow_empty=False):
        """One quiet commit as the bot (the BOT_GIT author args by default); allow_empty for the CI re-run commit."""
        return self._git(*author_args, "commit", "-q", *(("--allow-empty",) if allow_empty else ()), "-m", msg)

    def push(self, branch):
        """Push HEAD to the branch on origin (a write: skipped in dry-run by sh)."""
        return self._git("push", "-q", "origin", f"HEAD:refs/heads/{branch}", write=True)

    def fetch(self):
        return self._git("fetch", "-q", "origin")

    def merge(self, ref):
        """Merge `ref` into HEAD as the bot (BOT_GIT identity). check=False: a conflict exits non-zero and the caller decides."""
        return self._git(*BOT_GIT, "merge", "--no-edit", ref, check=False)

    def merge_abort(self):
        return self._git("merge", "--abort", check=False)

    def reset_hard(self, check=True):
        return self._git("reset", "-q", "--hard", check=check)

    def clean(self, check=True):
        return self._git("clean", "-fdq", check=check)

    def checkout(self, pathspec, check=True):
        return self._git("checkout", "--", pathspec, check=check)

    def status_porcelain(self):
        return self._git("status", "--porcelain", check=False).stdout.strip()

def merge_base(sh, wt, default):
    """Merge base of HEAD and origin/<default>: the commit the branch forked from, which is what the PR diff shows.
    Thin wrapper over GitRepo.merge_base (the rule and the origin/<default> fallback live there)."""
    return GitRepo(sh, wt).merge_base(default)

def staged_files(sh, wt, default):
    """Paths staged in the worktree's index relative to merge_base(sh, wt, default): the branch's own staged
    changes, never commits main made after the branch forked off. Thin wrapper over GitRepo.changed_names."""
    return GitRepo(sh, wt).changed_names(default)

def gate_state(checks, required):
    """Merge gate: required checks GREEN and the quality checks (Qodana zero new problems, Refactoring rationale)
    passed. RED when either is red, PENDING while either is still running, else GREEN.
    Thin wrapper over MergeGate.state; the merge rule itself is latest_attempt."""
    return MergeGate(checks, required).state()

def quality_pending(checks):
    """Names of the Qodana / Refactoring-rationale checks still running (same rule as quality_failures)."""
    return MergeGate(checks).quality_pending()

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
    item touches (by file name, full path, or stem on a word boundary), and names what it found (or why there is
    nothing) in at least two bullet lines."""
    if not text or research_head(text) < 0: return False
    sec = research_section(text)
    bullets = [l for l in sec.splitlines() if l.strip().startswith(("-", "*", "|")) and len(l.strip()) > 10]
    names = {f.rsplit("/", 1)[-1] for f in files or []} | set(files or [])
    # cmdemo1-system#913: accept the stem (file name without extension) on a word boundary, so Pi can name the
    # type (`ChurchTimeZone`) instead of the file (`ChurchTimeZone.cs`); the file name and full path still match
    # as before (substring, which is what the existing tests pin).
    def _named(n):
        if n in sec: return True
        stem = n.rsplit(".", 1)[0] if "." in n else ""
        return bool(stem) and bool(re.search(r"\b" + re.escape(stem) + r"\b", sec))
    return len(sec.strip()) >= RESEARCH_MIN_CHARS and len(bullets) >= 2 and (not names or any(_named(n) for n in names))

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

# ---------------------------------------------------------------- the one resume rule (cmdemo1-system#855)
# A paused item -- a Blocker or an unexpected driver error -- resumes through resume_plan below and nowhere else:
# `item-loop start --resume` after Jeffrey answers the Blocker, hold_blocked's wake-up of a blocked driver whose PR
# turned clean on its own, and the error resume. The rule owns the three decisions every one of them needs: the stage
# to run next, which pause fields to clear (blocker / error, and the recorded gpu when it died at gpu / pickup) and
# which counters start again. blocker() writes the half the rule reads back with paused_resume_stage().
PAUSED_STATUSES = ("blocked", "error")        # the two statuses that pause an item until something resumes it
WAKE_RESUME_STAGES = ("ci", "review", "merge")   # a blocked driver wakes itself only inside the PR gate

class Resume:
    """One resume as a decision object (cmdemo1-system#855): the `stage` to run next, the state fields the pause leaves
    behind (`clears`), `clear_gpu` (a gpu/pickup error re-picks a GPU instead of keeping the record of the one it died
    on), `reset_counts` (the fix limits start again) and the `status` to save (None leaves the status alone: `start
    --resume` keeps `blocked` / `error` until the driver's own run() sets it running). Built only by resume_plan(), so
    the stage choice and the clearing live in exactly one place; apply() is pure."""

    def __init__(self, stage, clears=(), clear_gpu=False, reset_counts=True, status=None):
        self.stage, self.clears, self.clear_gpu = stage, tuple(clears), clear_gpu
        self.reset_counts, self.status = reset_counts, status

    def __eq__(self, other):
        return isinstance(other, Resume) and (self.stage, self.clears, self.clear_gpu, self.reset_counts,
                                             self.status) == (other.stage, other.clears, other.clear_gpu,
                                                              other.reset_counts, other.status)
    def __hash__(self): return hash((self.stage, self.clears, self.clear_gpu, self.reset_counts, self.status))
    def __repr__(self):
        return (f"Resume(stage={self.stage!r}, clears={self.clears!r}, clear_gpu={self.clear_gpu!r}, "
                f"reset_counts={self.reset_counts!r}, status={self.status!r})")

    def apply(self, state):
        """The paused `state` with this resume applied: a new dict, the caller's never touched."""
        st = dict(state or {})
        st["stage"] = self.stage
        for f in self.clears + (("gpu",) if self.clear_gpu else ()):
            st.pop(f, None)
        if self.reset_counts: st["counts"] = fresh_counts()
        if self.status: st["status"] = self.status
        return st

def resume_target(state):
    """(stage, clear_gpu): the stage half of the resume rule, from the state dict alone. Blocked: `resume_stage` when
    set, else `ci` when a PR exists, else `implement`; the GPU is never cleared. Error: the saved stage (falling back
    to implement when no stage is saved); a gpu/pickup error maps to the gpu stage with the recorded GPU cleared."""
    st = state or {}
    if st.get("status") == "error":
        stage = st.get("stage")
        if stage in ("gpu", "pickup"):
            return "gpu", True
        return stage or "implement", False
    return st.get("resume_stage") or ("ci" if st.get("pr") else "implement"), False

def resume_plan(state, wake=False):
    """THE resume rule (cmdemo1-system#855): the Resume for a paused item, or None when this pause does not resume.

    `start --resume` (wake=False): the stage from resume_target (the saved stage for an error, `resume_stage` / ci /
    implement for a blocked), the pause flag dropped (`blocker` when blocked, `error` when errored), the recorded GPU
    cleared only for a gpu/pickup error, the fix counters reset, and the status left as the pause wrote it.

    wake=True is the blocked driver's own wake-up (hold_blocked re-reads the PR while it holds, and the checks turned
    clean on their own): it resumes only a pause raised inside the PR gate (WAKE_RESUME_STAGES) on an item that has a
    PR, only when hold_resumes says that Blocker may clear itself (a Review FAIL never does), and resumes the Review
    gate -- the checks are green, so there is nothing to re-run before it -- with the status back to running. The item
    is paused by definition there (the driver only holds while its stage is blocked), so the wake half reads the
    fields the pause left (pr, resume_stage, blocker) rather than the status.
    """
    st = state or {}
    if wake:
        if not st.get("pr") or st.get("resume_stage") not in WAKE_RESUME_STAGES or not hold_resumes(st.get("blocker")):
            return None
        return Resume("review", clears=("blocker",), status="running")
    if st.get("status") not in PAUSED_STATUSES: return None
    stage, clear_gpu = resume_target(st)
    return Resume(stage, clears=("blocker",) if st.get("status") == "blocked" else ("error",), clear_gpu=clear_gpu)

def apply_resume(state, wake=False):
    """The paused state with the one resume rule applied, and a copy of it unchanged when the rule does not resume
    (nothing paused, or a wake that this Blocker may not self-clear). The functional entry point for
    `item-loop start --resume`; hold_blocked asks resume_plan directly because it decides before the wait and applies
    after the PR turns green."""
    plan = resume_plan(state, wake=wake)
    return plan.apply(state) if plan else dict(state or {})

def paused_resume_stage(state):
    """The `resume_stage` a Blocker records: the stage the item is in, or the one already recorded when the item was
    already blocked -- a second Blocker (the wake loop's own, an error after a Blocker) must not move the resume
    target the rule will read back. The writing half of the resume rule."""
    st = state or {}
    return st.get("resume_stage") if st.get("stage") == "blocked" else st.get("stage")

def busy_gpus(states, me=None, alive=lambda pid: False):
    """GPUs whose slots are all held by other live items in a GPU-holding stage (pro5000 has 2, pro6000, obs and ts3
    have 1). states: [(key, state dict)]. Review and merge items do not hold their recorded (author) GPU: the
    independent review runs on a different GPU (gpu_gate.py enforces the real slot), and merge is gate-only."""
    held = Counter(s.get("gpu") for k, s in states
                   if k != me and s.get("gpu") and s.get("stage") in GPU_HOLDING_STAGES and alive(s.get("pid")))
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

class ReviewVerdict(NamedTuple):
    """One independent-review run as a value object (cmdemo1-system#887): the `ok` of the review and its `findings`
    text, answering the question the stages actually ask -- `is_pass` / `is_fail` / `is_infra` -- instead of unwrapping
    a pair and reading `verdict[0] is None` as "the infrastructure failed".

    INFRA is the third state, the one `review_verdict` used to carry in its docstring alone (t83u, #1944 / #820): the
    reviewer ran on broken plumbing -- no findings file, an empty one, or a reply with no PASS / FAIL verdict. It is
    retried on any free GPU under LIMITS['review_infra'], never handed to Pi as findings and never counted as a code
    FAIL. `label` is how the driver logs the three states.

    The tuple shape stays on purpose (`ok, findings = v` still unpacks and a ReviewVerdict still equals the bare pair):
    that pair is what every log line, test double and older call site already speaks, and the shape is saved in nothing.
    `of()` is the single seam that turns a bare pair -- or None, meaning no review ran at all because the caller had
    already blocked the item -- into the value object."""

    ok: bool | None
    findings: str

    @property
    def is_pass(self): return self.ok is True

    @property
    def is_fail(self): return self.ok is False

    @property
    def is_infra(self): return self.ok is None      # the review could not run: retry it, this says nothing about the code

    @property
    def label(self): return "INFRA (retry)" if self.is_infra else "PASS" if self.is_pass else "FAIL"

    @classmethod
    def of(cls, v):
        """`v` as a ReviewVerdict: itself, a bare (ok, findings) pair, or None when no review ran (a Blocker is up)."""
        if v is None or isinstance(v, cls): return v
        return cls(*v)

def review_verdict(result, findings):
    """The ReviewVerdict for one independent-review run. INFRA (`is_infra`, never a code FAIL; t83u, #1944 / #820): no
    findings file (findings None), an empty / whitespace-only one, or a reply with no PASS / FAIL verdict (timeout,
    crash). Those are retried on any free GPU and never handed to Pi as findings."""
    if findings is None: return ReviewVerdict(None, f"the reviewer wrote no findings file (run result: {result})")
    if not findings.strip(): return ReviewVerdict(None, f"the reviewer's findings file is empty (run result: {result})")
    if result not in ("PASS", "FAIL"):
        return ReviewVerdict(None, f"the review ended with no PASS/FAIL verdict (run result: {result})")
    return ReviewVerdict(result == "PASS", findings)

class PiRun(NamedTuple):
    """One Pi run-task result as a value object (cmdemo1-system#894): the `result` string (PASS / FAIL / timeout /
    no-start / stalled / exit N), the `gpu` that ran it (None when run-task printed no JSON line) and the `rc`
    (run-task exit code: 0 PASS, 125 no-start / stalled, 124 timeout, 1 otherwise), answering the questions the
    callers actually ask -- `ok` / `timed_out` / `not_started` -- instead of flattening them into one bool
    (`r.returncode == 0`) and reading the side channel (`Driver.last_task`) out of order.

    `not_started` covers both `no-start` and `stalled`: the driver treats them the same for relaunch purposes
    (a hand-off that did not produce enough model output is relaunched on any free GPU). A `stalled` run *did*
    produce model output (and may have edited the worktree), so the author-GPU check excludes only `no-start`,
    not `stalled` -- callers that need that finer distinction read `result` directly."""

    result: str
    gpu: str | None
    rc: int

    @property
    def ok(self): return self.result == "PASS"

    @property
    def timed_out(self): return self.result == "timeout"

    @property
    def not_started(self): return self.result in ("no-start", "stalled")

def intake_open(red, plan):
    """While anything is red only fix-forward items start."""
    return not red or bool(plan.get("fix_forward"))

def dep_health(environment, dep):
    """The last health result for dep in this environment (None when no result is recorded)."""
    for a in ((environment.get("health") or {}).get("containerApps") or []):
        if a.get("name") == dep:
            return (a.get("last") or {}).get("result")
    return None

def env_red(environment, dep):
    """An environment is red for a deployable when its last health report is not healthy (system has no HTTP health)."""
    if dep == "system": return False
    return dep_health(environment, dep) not in (None, "healthy")

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
    try: return read_text(os.path.join(_runs_dir(), f"{repo}-{int(issue)}", "HOLD")).strip() or "held"
    except (OSError, TypeError, ValueError): return None

RELAUNCH_NOTE = ("\n\nNote: an earlier attempt at this task (`{name}`) was stopped because it never started or stalled. It "
                 "may have left partial edits in this working tree: check `git status` and `git diff` first, keep what is "
                 "correct and finish the task.")
# The rules every Pi task prompt ends with. Prompt text is data, owned by PiHandoff, which assembles each attempt's
# prompt file from the scrubbed task prompt, the RELAUNCH_NOTE of a relaunch and this suffix (cmdemo1-system#889).
PI_RULES = ("\n\nRules: follow the repository's AGENTS.md and CLAUDE.md (read them if this task touches code, tests or "
            "the build). Make only the change asked. Do not run git commit, git push or gh, and do not read or print "
            "credentials. When done, run the narrowest relevant build/test, then end your reply with PASS or FAIL as "
            "the last line.")

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
    try:
        with open(os.path.join(_runs_dir(), "red.json")) as f: return json.load(f)
    except Exception: return {}

def _red_write(fn):
    os.makedirs(_runs_dir(), exist_ok=True)
    with open(os.path.join(_runs_dir(), "red.lock"), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX); r = red_load(); fn(r)
        tmp = os.path.join(_runs_dir(), "red.json.tmp"); write_text(tmp, json.dumps(r, indent=1))
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
        try:
            with open(sp) as f: out.append((n, json.load(f)))
        except Exception: pass
    return out

class GpuHealthCache:
    """The gpu.py health probe behind an injectable cache (cmdemo1-system#868): `now` and `health` are injected
    (defaults `time.time` and `G.health`), the probe runs only when the cached result is older than the `max_age`
    requested at call time, and the cache state (at / h) lives on this object instead of a module-global dict, so a
    fake probe (no network) is a plain construction argument."""
    def __init__(self, now=time.time, health=G.health):
        self.now, self.health, self.at, self.h = now, health, 0, {}
    def __call__(self, max_age=600):
        if self.now() - self.at > max_age: self.at, self.h = self.now(), self.health()
        return self.h

# Shared default cache: Driver's st_gpu / pi relaunch / independent_review use it through Driver.gpu_health and
# watchdog.run_checks' default health, so a driver and its exit hook share one probe (never three fresh GETs).
_HEALTH = GpuHealthCache()
def gpu_health(max_age=600):
    return _HEALTH(max_age)

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

def fix_text(value):
    """A FixRound text (cmdemo1-system#858): a literal, or a function of the pass number n."""
    return value if callable(value) else lambda n: value

class FixRound:
    """What one Pi fix round does, as the ci / quality / review stages build it and Driver.fix_pass runs it
    (cmdemo1-system#858): the Pi task name prefix (`<pi>-<n>`), its prompt with the findings, the local
    verification label prefix (`<verify><n>`), the Blocker text when verification stays red and the commit
    message. The last two are functions of the pass number because only the driver knows n after bumping the
    counter; `before_commit` runs between the local verification and the push (fix_quality pastes the
    refactoring plan into the PR body there)."""

    def __init__(self, pi, prompt, verify, local_red, commit, before_commit=None):
        self.pi, self.prompt, self.verify = pi, prompt, verify
        self.local_red, self.commit = fix_text(local_red), fix_text(commit)
        self.before_commit = before_commit

class PiHandoff:
    """One Pi hand-off as the state Driver.pi's loop drives (t85u, cmdemo1-system#889): the task name (the slug, then
    `<slug>-relaunch-<k>`), the scrubbed prompt, the GPU list the current attempt goes out on (the item's GPU first,
    then any free GPU of the item's size), the attempt number and the slot wait of the current attempt. Each attempt's
    prompt file is written by the handoff, so the relaunch prompt suffix (the partial-edits note of an earlier attempt,
    plus the rules every prompt ends with) belongs here, not to the loop; the loop runs the attempt, reads run-task's
    record, notes the author GPUs, decides pass / fail / relaunch and raises PiNotStarted with not_started() when the
    budget runs out."""

    def __init__(self, d, name, prompt, timeout=PI_TASK_TIMEOUT_S, gpu=None):
        self.d, self.name = d, name
        self.slug = task_slug(name)   # every per-task log path uses run-task's slug (cmdemo1-system#959)
        self.prompt = scrub(prompt)
        self.review = name.startswith("independent-review")   # a review keeps its non-author GPUs; no-start = infra retry
        self.timeout = G.client_timeout(timeout)
        self.attempt, self.task, self.gpu = 0, self.slug, gpu or d.gpu()
        self._write_prompt()

    def slot_wait(self):
        """The current attempt's slot wait: the item's own GPU slot on the first attempt; any free slot (a busy queue
        is no failure) on a relaunch or a review. The rule lives on the HandoffBudgets (cmdemo1-system#954)."""
        return self.d.budgets.slot_wait(self.review, self.attempt)

    def prompt_text(self):
        """The current attempt's prompt file text: a relaunch adds the partial-edits note of the ORIGINAL task (an
        earlier relaunch is not the name to check for), and every attempt ends with the same rules."""
        note = RELAUNCH_NOTE.format(name=self.name) if self.attempt else ""
        return self.prompt + note + PI_RULES

    def _write_prompt(self):
        self.pf = os.path.join(self.d.run_dir, "logs", f"{self.task}.prompt.md")
        write_text(self.pf, self.prompt_text())

    def run_task_args(self):
        """The run-task command of the current attempt: the slot/timeout argument assembly the loop used to inline.
        The start / stall / slot clocks come from the HandoffBudgets (cmdemo1-system#954); the ints are the wire
        format and are unchanged."""
        b = self.d.budgets
        return [os.path.join(HERE, "run-task"), "--run-dir", self.d.run_dir, "--cwd", self.d.s["wt"], "--task", self.task,
                "--prompt-file", self.pf, "--timeout", str(self.timeout), "--gpu", self.gpu, "--start-timeout", str(b.start_s),
                "--stall-timeout", str(b.stall_s), "--slot-wait", str(self.slot_wait())]

    def advance(self, k, result):
        """Attempt k (1-based) after a failed one: a new task name, a free GPU of the item's size and its prompt
        file; returns the log line the loop prints (the slot wait of the attempt that just failed, the GPU list the
        new one goes out on)."""
        old_slot = self.slot_wait()
        self.attempt = k
        up = G.available(self.d.gpu_health()) or list(G.PRIORITY)
        self.task, self.gpu = f"{self.slug}-relaunch-{k}", G.gpu_arg(relaunch_gpus(self.d.s.get("size"), up))   # a free GPU of the item's size
        self._write_prompt()
        b = self.d.budgets
        return (f"Pi hand-off {self.name} {result} (start {b.start_s} s / stall {b.stall_s} s / "
                f"slot {old_slot} s); relaunch {k} of {LIMITS['pi_relaunch']} on any free GPU ({self.gpu})")

    def not_started(self, result):
        """The PiNotStarted message after the last relaunch: the stage ends in a Blocker with this text. The text is
        owned by the HandoffBudgets (cmdemo1-system#954), the one place that names the start / stall clocks."""
        return self.d.budgets.describe(self.name, result)

class Driver:
    def __init__(self, repo, issue, dry_run=False, top_session=None, health=None):
        self.repo, self.issue, self.dry = repo, int(issue), dry_run
        # The GPU health probe st_gpu / the pi relaunch / independent_review use (cmdemo1-system#868): injectable
        # (a GpuHealthCache or any callable returning a gpu.py health dict), defaulting to the shared module
        # gpu_health resolved at construction time, so a test that patches L.gpu_health before building the Driver is honored.
        self.gpu_health = health if health is not None else gpu_health
        # The hand-off budget (#954): the start / stall / slot clocks, the per-pass task timeouts and the GPU-wait
        # pacing, one value object whose invariants are asserted on construction and whose .describe() owns the
        # no-start message. PiHandoff reads the run-task clocks and the message from here.
        self.budgets = HANDOFF_BUDGETS
        self.run_dir = os.path.join(HOME, "factory-runs", f"{repo}-{issue}")
        os.makedirs(os.path.join(self.run_dir, "logs"), exist_ok=True)
        self.state_p = os.path.join(self.run_dir, "state.json")
        self.s = json.loads(read_text(self.state_p)) if os.path.exists(self.state_p) else {}
        self.s.setdefault("repo", repo); self.s.setdefault("issue", self.issue)
        self.s.setdefault("counts", fresh_counts())
        if top_session: self.s["top_session"] = top_session
        self.full = f"{ORG}/{repo}"; self.last_task = {}
        # The item's work tree as a GitRepo value object (cmdemo1-system#871): the work-tree path is deterministic
        # (worktree_path("wt"), exactly what setup_worktree records into self.s["wt"]), and the _sh seam resolves
        # self.sh at call time, so a test's `d.sh = ...` replacement is honored although this is built once here.
        self.git = GitRepo(self._sh, self.worktree_path("wt"))

    # state / log
    def save(self, **kw):
        self.s.update(kw); self.s["updated"] = iso(); self.s["pid"] = os.getpid()
        tmp = self.state_p + ".tmp"; write_text(tmp, json.dumps(self.s, indent=1)); os.replace(tmp, self.state_p)
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
        append_text(os.path.join(self.run_dir, "driver.log"), line + "\n")

    def log_file(self, name, text):
        """Write `text` (scrubbed) to `logs/<name>` under the run dir and return the path (cmdemo1-system#898):
        the one writer for every `gh --body-file` body, closing the handle."""
        p = os.path.join(self.run_dir, "logs", name)
        write_text(p, scrub(text))
        return p

    def _sh(self, cmd, **k):
        """The sh seam GitRepo calls through (cmdemo1-system#871): resolved through the instance at call time, so
        the GitRepo built once in __init__ still honors a test's `d.sh = ...` replacement."""
        return self.sh(cmd, **k)

    _WRITE_SENTINEL = object()   # distinguishes "write= not passed" from "write=False passed"

    def sh(self, cmd, cwd=None, check=True, timeout=None, write=_WRITE_SENTINEL):
        """Run `cmd` and return its CompletedProcess. `cmd` is a `Command` value object (built by `Driver.gh()`,
        which decides `is_gh`, `app_ok` and `write`), or a bare list / shell string (a non-gh command: no App
        token, no rate-limit retry; its `write` flag comes from the `write=` keyword, defaulting to False).
        A `Command` fully owns its `write` flag: passing a conflicting `write=` keyword raises ValueError.
        Between the dry-run skip and check, sh does exactly two things: one subprocess of the command
        (_run_logged, a gh call first on the App token) and the gh rate-limit backoff on a rate-limited reply
        (_retry_rate_limit)."""
        if isinstance(cmd, Command):
            argv, is_gh, use_app = cmd.argv, cmd.is_gh, cmd.app_ok
            if write is not self._WRITE_SENTINEL and write != cmd.write:
                raise ValueError(f"sh(): write={write!r} kwarg conflicts with Command.write={cmd.write!r}; "
                                 "a Command owns its write flag -- drop the kwarg or build the Command with the right value")
            write = cmd.write
        else:
            argv, is_gh, use_app = cmd, False, False
            if write is self._WRITE_SENTINEL: write = False
        if write and self.dry:
            self.log(f"DRY-RUN skip: {self._shown(argv)[:300]}"); return subprocess.CompletedProcess(argv, 0, "", "")
        shown = self._shown(argv)
        r = self._run_logged(argv, use_app=use_app, cwd=cwd, timeout=timeout)
        r = self._retry_rate_limit(r, argv, is_gh=is_gh, use_app=use_app, cwd=cwd, timeout=timeout)
        if is_gh and "gh_wait" in self.s: self.s.pop("gh_wait"); self.save()
        if check and r.returncode:
            raise RuntimeError(f"failed ({r.returncode}): {shown[:300]}\n{scrub(r.stdout)[-2000:]}")
        return r

    @staticmethod
    def _shown(argv):
        """The one-line display form of `argv` for logs and error text: a str stays a str, a list is shlex-quoted."""
        return argv if isinstance(argv, str) else " ".join(shlex.quote(c) for c in argv)
    def _run_logged(self, cmd, use_app=False, cwd=None, timeout=None):
        """One subprocess of cmd through the shared runner (run_cmd owns the deadline and the process-group kill).
        A gh call goes out first on the App installation token when `use_app` (its own API quota); any refusal
        (403 / permission / branch rule) re-runs the same call on the user login, and a 401 drops the cached token
        (at=0: no negative cache) so the next call re-mints it."""
        tok = app_token() if use_app else None
        if tok:
            r = run_cmd(cmd, cwd=cwd, shell=isinstance(cmd, str), text=True, timeout=timeout, env={**os.environ, "GH_TOKEN": tok},
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if not (r.returncode and app_denied(r.stdout)): return r
            if re.search(r"HTTP 401|Bad credentials", r.stdout): _app_tok.update(v=None, at=0.0)   # expired: re-mint next call
            self.log("gh: App token refused; retrying this call with the user login")
        return run_cmd(cmd, cwd=cwd, shell=isinstance(cmd, str), text=True, timeout=timeout,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    def _retry_rate_limit(self, r, cmd, is_gh=False, use_app=False, cwd=None, timeout=None):
        """The gh rate-limit backoff, the wait loop on its own: while the reply's closing line is a rate limit, wait
        (gh_retry_wait: backoff first, then a fixed wait until the limit resets; GH_RETRY_MAX_ATTEMPTS retries,
        GH_RETRY_MAX_WAIT_S of sleep in total) and re-run the call through _run_logged (App token first again).
        Returns the reply that counts: the first non-rate-limited one, or the last one when the budget runs out."""
        attempt = waited = 0
        while is_gh and r.returncode and is_rate_limit(r.stdout):
            wait = gh_retry_wait(attempt, waited)
            if wait is None:
                self.log(f"gh rate-limited (exit {r.returncode}); giving up after {attempt} retries / {waited}s")
                return r
            self.log(f"gh rate-limited (exit {r.returncode}); retry {attempt + 1} in {wait}s")
            self.wait_alive(wait, f"gh rate limit, retry {attempt + 1}")
            waited += wait; attempt += 1
            r = self._run_logged(cmd, use_app=use_app, cwd=cwd, timeout=timeout)
        return r
    # Authored objects stay the bot user's: the merge gate requires PR author == BOT (cmdemo1-system#947: the
    # exclusion lives here, next to gh(), not at module level -- gh() already knows what it is building).
    GH_APP_USER_ONLY = {("pr", "create"), ("issue", "create")}

    def gh(self, *a, write=False, check=True, timeout=None):
        """Build a `Command` for a `gh` call and run it through sh(). `app_ok` is False for the subcommands in
        GH_APP_USER_ONLY (pr create / issue create stay on the user login); every other gh call tries the App
        token first."""
        argv = ["gh", *a]
        app_ok = not (len(argv) >= 3 and tuple(argv[1:3]) in self.GH_APP_USER_ONLY)
        return self.sh(Command(argv, is_gh=True, app_ok=app_ok, write=write), check=check, timeout=timeout)
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
        p = self.log_file(f"comment-{int(time.time())}.md", body)
        target = str(self.s["pr"]) if pr else str(self.issue)
        self.gh("pr" if pr else "issue", "comment", target, "-R", self.full, "--body-file", p, write=True)
        self.save(last_comment_at=iso()); self.log(f"comment {'drafted (dry-run)' if self.dry else 'posted'}: {p}")

    def review_fail_comment(self, body):
        """A review FAIL goes in the issue journal AND on the PR, so the PR never looks clean while its review failed
        (cmdemo1-dashboard#1311: the FAIL was on the issue only and the PR sat green and idle for two hours)."""
        self.comment(body)
        if self.s.get("pr"): self.comment(body, pr=True)

    def pr_body(self, check=True):
        """The PR body as GitHub has it now. check=False answers '' when the read fails: the research mirror and
        the independent review treat a body they cannot read as an empty one."""
        return self.gh("pr", "view", str(self.s["pr"]), "-R", self.full, "--json", "body", "-q", ".body", check=check).stdout

    def edit_pr_body(self, body, name):
        """Replace the PR body with `body`, drafted (scrubbed) to logs/pr-body-<name>.md first."""
        p = self.log_file(f"pr-body-{name}.md", body)
        self.gh("pr", "edit", str(self.s["pr"]), "-R", self.full, "--body-file", p, write=True)

    def lookup_board_item(self):
        """Return the board item id, looking it up if necessary. Logs and returns None on failure."""
        if self.s.get("item_id"):
            return self.s["item_id"]
        q = ('query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){'
             'projectItems(first:10){nodes{id project{id}}}}}}')
        r = self.gh("api", "graphql", "-f", f"query={q}", "-f", f"o={ORG}", "-f", f"r={self.repo}", "-F", f"n={self.issue}", check=False)
        try:
            nodes = json.loads(r.stdout)["data"]["repository"]["issue"]["projectItems"]["nodes"]
            item_id = next(n["id"] for n in nodes if n["project"]["id"] == PROJECT)
            self.save(item_id=item_id)
            return item_id
        except (json.JSONDecodeError, KeyError, TypeError):
            self.log("board lookup failed; skipping move")
            return None
        except StopIteration:
            self.log("board item not found; skipping move")
            return None

    def move_board_item(self, item_id, col):
        """Move the board item to col. Raises on failure."""
        self.gh("project", "item-edit", "--id", item_id, "--project-id", PROJECT, "--field-id", STATUS_FIELD,
                "--single-select-option-id", STATUS[col], write=True)
        self.save(column=col); self.log(f"board -> {col}")

    def move(self, col):
        """Move the item to board column col. No-op (logs) if the board item is not found."""
        item_id = self.lookup_board_item()
        if not item_id:
            return
        self.move_board_item(item_id, col)

    def wake_bot(self, reason):
        """Fire the bot's issue-assigned listener once (unassign + assign) so he reads state.json."""
        self.save(wake_reason=reason)
        self.gh("api", "-X", "DELETE", f"repos/{self.full}/issues/{self.issue}/assignees", "-f", f"assignees[]={BOT}", write=True, check=False)
        self.gh("api", "-X", "POST", f"repos/{self.full}/issues/{self.issue}/assignees", "-f", f"assignees[]={BOT}", write=True, check=False)
        self.log(f"woke the bot: {reason}")

    def blocker(self, what, who="Jeffrey"):
        self.comment(f"Blocker: {what} Needed from {who}. The Pi driver stopped (run `{self.s.get('run_id')}`). "
                     f"Reply on this issue or in chat.\n\n{self.usage()}")
        self.save(resume_stage=paused_resume_stage(self.s), stage="blocked", status="blocked", blocker=what)
        self.wake_bot("blocked")

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

    def pi(self, name, prompt, timeout=PI_TASK_TIMEOUT_S, gpu=None):
        """Run one Pi task through run-task, driving a PiHandoff (the task name, prompt file, GPU list, attempt and
        slot wait of each try): a no-start / stalled hand-off is relaunched on any free GPU of the item's size, up to
        LIMITS['pi_relaunch'] times. A review is never relaunched (its no-start is an infrastructure retry, and
        PiRun.ok False says so). Returns the PiRun (result / gpu / rc) of the attempt that counts; PiNotStarted when
        a non-review hand-off still did not start after the last relaunch."""
        h = PiHandoff(self, name, prompt, timeout, gpu)
        run = None
        for k in range(LIMITS["pi_relaunch"] + 1):
            r = self.sh(h.run_task_args(), check=False)
            self.log(f"pi {h.task}: " + (r.stdout.splitlines() or ["?"])[0][:300]); self.progress()
            rec = self._last_task_record(r)
            self.last_task = rec   # kept for one release (cmdemo1-system#894); no caller reads it now
            run = PiRun(result=rec.get("result", ""), gpu=rec.get("gpu"), rc=r.returncode)
            if writes_code(h.name) and run.result != "no-start":   # no model output = no edits
                self.note_author_gpu(run.gpu)
            if h.review or not run.not_started: return run
            if k == LIMITS["pi_relaunch"]: break
            self.log(h.advance(k + 1, run.result))
        raise PiNotStarted(h.not_started(run.result))

    def _last_task_record(self, r):
        """The run-task record of one attempt: the last JSON object line of run-task's stdout (its result / gpu /
        exit fields), or a synthetic `exit <code>` record when no line parsed -- the record pi() and the independent
        review both branch on (cmdemo1-system#918: pulled out of pi()'s loop so the loop reads as one step)."""
        return next((rec for rec in map(_json_or_none, (r.stdout or "").splitlines()) if isinstance(rec, dict)),
                    {"result": f"exit {r.returncode}"})

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
            if self.pi(name, prompt, t.get("timeout", PI_TASK_TIMEOUT_S)).ok: return True
        self.blocker(f"Pi task `{t['name']}` still failed after {LIMITS['local_fix'] + 1} attempts (last attempt `{name}`).")
        return False

    def verify(self, name):
        log = os.path.join(self.run_dir, "logs", f"verify-{name}.log"); t0 = time.time()
        r = run_cmd(["bash", "-o", "pipefail", "-c", self.s["plan"]["verify_cmd"]], cwd=self.s["wt"], text=True,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        write_text(log, scrub(r.stdout))
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

    def pi_round(self, name, prompt, label, local_red, commit, before_commit=None):
        """The fix half of a pass: Pi gets the findings as task `name`, the item re-verifies locally under label
        `label`, and the fix is committed and pushed as `commit` (`before_commit` in between, for a stage's own
        GitHub bookkeeping). Verification still red: Blocker `local_red` and nothing is committed, False -- the
        caller leaves the stage."""
        self.pi(name, prompt)
        if not self.local_green(label): self.blocker(local_red); return False
        if before_commit: before_commit()
        self.commit_push(commit)
        return True

    def fix_pass(self, limit_key, blocked, *, progress=None, comment=None, fix=None):
        """One fix pass: the loop the ci / quality / review / merge stages share instead of each inlining it with
        its own failure text (cmdemo1-system#858). Bump LIMITS[limit_key]; exhausted, post `blocked` as the
        Blocker and return None, so the caller leaves the stage. Otherwise: move the board item to `progress`
        when given, post `comment(n)` (a callable, so a review FAIL keeps its PR mirror in its own stage), then
        run the `fix` FixRound (Pi task `<pi>-<n>`, local verification `<verify><n>`, Blocker and commit message
        of n) and return the pass number n. With no `fix` the pass is the bump alone -- all the merge gate is.
        Every Blocker text is the caller's: hold_resumes keys off "Review FAIL twice" / "independent review
        FAIL twice" / "independent review infra", so the helper never generates one."""
        if not self.bump(limit_key):
            self.blocker(blocked); return None
        n = self.s["counts"][limit_key]
        if progress: self.move(progress)
        if comment: comment(n)
        if fix and not self.pi_round(f"{fix.pi}-{n}", fix.prompt, f"{fix.verify}{n}", fix.local_red(n),
                                     fix.commit(n), fix.before_commit): return None
        return n

    def commit_push(self, msg):
        self.check_held()
        self.git.add_all()
        if self.git.staged_changes():
            self.git.commit(msg + f"\n\nCode by Pi ({self.gpu_label()}); planned by the factory bot; "
                         f"Pi driver run {self.s['run_id']}.")
        self.git.push(self.s["plan"]["branch"])
        head = self.git.head(); self.save(head=head)
        if not self.dry and self.s.get("pr"): time.sleep(90)   # let the PR's checks move to the new head before reading them
        return head

    def pr_checks(self):
        r = self.gh("pr", "checks", str(self.s["pr"]), "-R", self.full, "--json", "name,bucket,link", check=False)
        try: cs = json.loads(r.stdout or "[]")
        except Exception: cs = []
        return self.merge_gate(cs).required_state(), cs

    def merge_gate(self, cs):
        """This repo's MergeGate for a `gh pr checks --json` list: the one place the repo's required-check names are
        looked up, so every stage asks the gate object instead of re-deriving it from raw buckets (#886)."""
        return MergeGate(cs, REQUIRED.get(self.repo))

    def pr_mergeable(self):
        """The PR's mergeable state or "UNKNOWN" on empty output: gh's field is `mergeable`, not `mergeableState` (#921)."""
        r = self.gh("pr", "view", str(self.s["pr"]), "-R", self.full, "--json", "mergeable", "-q", ".mergeable", check=False)
        return (r.stdout or "").strip() or "UNKNOWN"

    def merge_default_if_conflicting(self):
        """A CONFLICTING PR starts no workflows, so wait_ci would idle 4h on an empty checks list (#921): fetch, merge
        origin/<default> as the bot and push, at most LIMITS['conflict_merge'] times, then Blocker. "none" (not
        conflicting -- UNKNOWN included: the next iteration polls again), "pushed" (CI checks the clean merge), "blocked"."""
        if self.pr_mergeable() != "CONFLICTING": return "none"
        if not self.bump("conflict_merge"):
            self.blocker(f"PR #{self.s['pr']} still conflicts with {self.s['default']} after "
                         f"{LIMITS['conflict_merge']} merge attempts.")
            return "blocked"
        self.git.fetch()
        r = self.git.merge(origin_ref(self.s["default"]))
        if r.returncode != 0:   # any non-zero exit (a conflict, a dirty tree, a missing ref) is a failure
            self.git.merge_abort()
            self.blocker(f"merging {self.s['default']} into the PR branch conflicts; a human must resolve it.")
            return "blocked"
        self.git.push(self.s["plan"]["branch"])
        self.save(head=self.git.head())
        return "pushed"

    def wait_ci(self, max_s=4 * 3600):
        """Zero-LLM wait: gh's own watch; falls back to a sleep loop until checks exist. An empty list means no
        workflows started -- for a CONFLICTING PR that is permanent, so merge the default branch instead of idling (#921)."""
        t_end = time.time() + max_s
        while time.time() < t_end:
            state, cs = self.pr_checks()
            if cs and state != CheckState.PENDING: return state, cs
            if not cs:
                if self.merge_default_if_conflicting() == "blocked": return CheckState.PENDING, []
            else:
                try:
                    self.gh("pr", "checks", str(self.s["pr"]), "-R", self.full, "--watch", "--interval", "60",
                            *(["--required"] if self.repo in REQUIRED else []), check=False, timeout=TIMEOUTS["wait_ci"])
                except subprocess.TimeoutExpired: pass   # short slices so the heartbeat below runs
            self.heartbeat(); time.sleep(60)
        return CheckState.PENDING, []

    def failed_logs(self, cs):
        out, runs = [], set()
        for c in cs:
            if bucket_red(bucket(c)):   # every attempt with a red bucket: the log is wanted even when a rerun passed
                m = re.search(r"/actions/runs/(\d+)", c.get("link") or "")
                if m: runs.add(m.group(1))
        for rid in sorted(runs):
            r = self.gh("run", "view", rid, "-R", self.full, "--log-failed", check=False)
            out.append(f"### run {rid}\n" + trim_log(r.stdout, 8000))
        return runs, "\n".join(out)[-16000:]

    # ---------------------------------------------------------------- stages
    def _clone_ready(self):
        """The clone (when missing) + fetch + default-branch lookup shared by setup_worktree and plan_worktree:
        returns (clone path, default branch name)."""
        clone = os.path.join(HOME, "factory-clones", self.repo)
        if not os.path.isdir(os.path.join(clone, ".git")):
            os.makedirs(os.path.dirname(clone), exist_ok=True)
            self.gh("repo", "clone", self.full, clone, "--", "-q")
        self.sh(["git", "fetch", "-q", "origin"], cwd=clone)
        default = self.gh("repo", "view", self.full, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name").stdout.strip()
        return clone, default

    def worktree_path(self, kind="wt"):
        """The work-tree path for this item under ~/factory-wt: <repo>-<issue> for kind `wt`, <repo>-<issue>-plan for `plan`."""
        suffix = {"wt": "", "plan": "-plan"}[kind]
        return os.path.join(HOME, "factory-wt", f"{self.repo}-{self.issue}{suffix}")

    def setup_worktree(self):
        p = self.s["plan"]; clone, default = self._clone_ready()
        wt = self.worktree_path("wt")
        if os.path.isdir(self.worktree_path("plan")): self.sh(["git", "worktree", "remove", "--force", self.worktree_path("plan")], cwd=clone, check=False)
        if not os.path.isdir(wt):
            remote = self.sh(["git", "ls-remote", "--heads", "origin", p["branch"]], cwd=clone).stdout.strip()
            base = origin_ref(p["branch"]) if remote else origin_ref(default)
            if remote: self.sh(["git", "fetch", "-q", "origin", remote_refspec(p["branch"])], cwd=clone)
            self.sh(["git", "worktree", "prune"], cwd=clone)
            self.sh(["git", "worktree", "add", "-q", "-B", p["branch"], wt, base], cwd=clone)
        self.save(wt=wt, default=default, clone=clone)

    def plan_worktree(self):
        """Detached worktree at the default branch for Pi to read while drafting the plan (no branch is created)."""
        clone, default = self._clone_ready()
        wt = self.worktree_path("plan")
        if os.path.isdir(wt): self.sh(["git", "worktree", "remove", "--force", wt], cwd=clone, check=False)
        self.sh(["git", "worktree", "add", "-q", "--detach", wt, origin_ref(default)], cwd=clone)
        self.save(wt=wt, default=default, clone=clone)

    def run(self):
        # The lock handle is intentionally not closed: it is held open for the lifetime of run() so the flock
        # stays in place (cmdemo1-system#898: the one exception to the closed-handle rule, like the Popen stdout).
        lock = open(os.path.join(self.run_dir, "driver.lock"), "w")
        try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: print("driver already running for this item"); sys.exit(0)
        self.s.setdefault("run_id", now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
        self.s.setdefault("start", iso()); self.s.setdefault("stage", "gpu")
        with open(os.path.join(self.run_dir, PLAN_FILE)) as f: self.s["plan"] = json.load(f)
        self.save(status="running")
        meta_p = os.path.join(self.run_dir, "run.json")
        meta = json.loads(read_text(meta_p)) if os.path.exists(meta_p) else {"start": self.s["start"]}
        meta.update(driver_run_id=self.s["run_id"], top_sessions=self.s.get("top_sessions") or [self.s.get("top_session", "unnamed")])
        meta.setdefault("top_session", self.s.get("top_session", "unnamed"))
        meta.setdefault("pi_version", self.sh(["pi", "--version"], check=False).stdout.strip().splitlines()[-1:] and
                        self.sh(["pi", "--version"], check=False).stdout.strip().splitlines()[-1])
        write_text(meta_p, json.dumps(meta, indent=1))
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
        Blocker and resumes; otherwise it posts a heartbeat. Returns True when it resumed. Where it resumes, what the
        pause leaves behind and which limits start again are the one resume rule's, not this stage's."""
        if self.dry: return False
        plan = resume_plan(self.s, wake=True)
        if plan is None: return False
        t_end = time.time() + BLOCKED_HOLD_H * 3600
        while time.time() < t_end:
            time.sleep(RECHECK_S)
            if self.stop_if_held(): return False   # handed off while blocked: never clear the Blocker or resume
            _, cs = self.pr_checks()
            if self.merge_gate(cs).green():
                self.log("blocked PR is clean now; resuming")
                self.comment("Status: checks are green now (including Qodana and Refactoring rationale); the driver cleared its "
                             "Blocker and is resuming the Review.")
                self.s = plan.apply(self.s); self.save(); self.progress(); return True
            self.heartbeat(BLOCKED_HEARTBEAT_MIN)
        return False

    def _gpu_intake_check(self, plan):
        """Intake-red check (Specification): None when intake is open, else the exact `why` string the wait loop logs."""
        red = red_load()
        if intake_open(red, plan): return None
        return "intake stopped while red: " + "; ".join(f"{k}: {v['what']}" for k, v in red.items())

    def _gpu_wip_check(self, states, me):
        """WIP-full check (Specification): None when the repo has WIP room, else the exact `why` string."""
        if repo_wip(states, self.repo, me, pid_alive) < wip_limit(self.repo): return None
        return f"WIP is full for {self.repo} ({wip_limit(self.repo)})"

    def _gpu_free_check(self, size, up, states, me):
        """No-free-GPU check (Specification): (gpu, None) when a GPU of the right size is free, else (None, why).
        `gpu_for_item` returns `(gpu, wait_why)`; we forward its `why` when it says wait."""
        g, why = gpu_for_item(self.s.get("gpu"), size, up, busy_gpus(states, me, pid_alive))
        return (g, None) if g else (None, why)

    def st_gpu(self):
        """Wait (no Grok turn, no comment; the item stays in Todo) until intake is open, the repo has WIP room on this
        box and a GPU of the right size is free; then take it. One active item per GPU slot (pro5000 has 2), so up to 5 items at once."""
        p = self.s["plan"]; size = G.classify_size(p); t_end = time.time() + self.budgets.gpu_wait_h * 3600; me = os.path.basename(self.run_dir)
        while time.time() < t_end:
            why = self._gpu_intake_check(p)
            if why is None:
                with open(os.path.join(_runs_dir(), "gpu.lock"), "w") as lk:
                    fcntl.flock(lk, fcntl.LOCK_EX); states = all_states()
                    up = G.available(self.gpu_health())
                    why = self._gpu_wip_check(states, me)
                    if why is None:
                        g, free_why = self._gpu_free_check(size, up, states, me)
                        if g:
                            self.save(gpu=g, size=size, stage="pickup"); self.log(f"GPU {g} ({self.gpu_label(g)}) for a {size} item")
                            return
                        why = free_why
            if self.dry:
                g = self.s.get("gpu") or G.LARGE_GPU
                self.log(f"DRY-RUN: {why}; taking {g}"); return self.save(gpu=g, size=size, stage="pickup")
            if self.s.get("wait_why") != why: self.save(wait_why=why); self.log(f"waiting: {why}")
            time.sleep(self.budgets.gpu_wait_s)
        self.blocker(f"waited {self.budgets.gpu_wait_h} hours to start ({self.s.get('wait_why')}).")

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
            "code clearer and easier to maintain. Give each bullet's file **path** in backticks (e.g. `src/A.cs`).\n\n"
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
            self.pi(f"refactoring-research-{self.s['counts']['research']}", prompt, self.budgets.research_s)
            self.git.checkout(".", check=False); self.git.clean(check=False)
            text = self.research_text()
        try:
            with open(fu) as f: extra = json.load(f)
        except Exception: extra = {}
        if not self.s.get("research_posted"):
            self.comment(f"Refactoring research (journal)\n\n{text.strip()}"); self.save(research_posted=True)
        if not self.s.get("followups_filed"):
            self.file_followups(extra.get("followups") or []); self.save(followups_filed=True)
        refs = [t for t in (extra.get("in_scope") or []) if t.get("name") and t.get("prompt")][:3]
        if refs and not self.s.get("refactors_done"):
            for t in refs:
                self.pi(task_slug(t["name"])[:60], t["prompt"] + "\n\nBehavior must not change. Keep every "
                        "test green; never skip, delete or weaken a test. If this refactoring turns out larger than a small, "
                        "safe change inside the item's files, change nothing and end with FAIL.")
            if not self.local_green("refactor"):
                self.git.reset_hard(); self.git.clean()
                append_text(out, "\n- In-scope refactors were reverted: verification stayed red after the fix passes; "
                                   "they are left to a follow-up.\n")
                self.log("in-scope refactors reverted (red)")
            self.save(refactors_done=True)
        self.save(stage="implement")

    def ensure_issue(self, title, body, label, repo=None, assignee=None, case_insensitive=True):
        """File a new open issue with `label` when no open issue already has that title, and return its
        number; None when the title is already open (case-insensitive by default) or the create failed."""
        full = f"{ORG}/{repo or self.repo}"
        r = self.gh("api", f"repos/{full}/issues?state=open&labels={label}&per_page=100", "--jq", "[.[].title]", check=False)
        try: titles = json.loads(r.stdout or "[]")
        except Exception: titles = []
        have = {t.lower() for t in titles} if case_insensitive else titles
        q = title.lower() if case_insensitive else title
        if q in have: return None
        body_f = self.log_file(f"ensure-issue-{int(time.time())}.md", body)
        x = self.gh("issue", "create", "-R", full, "--title", title, "--body-file", body_f, "--label", label,
                    *(("--assignee", assignee) if assignee is not None else ()), write=True, check=False)
        return x.stdout.strip().rsplit("/", 1)[-1] if x.returncode == 0 and x.stdout.strip() else None

    def file_followups(self, items):
        """File the research follow-ups: one ensure_issue per valid item (the helper dedupes against the open
        issues itself), at most FOLLOWUP_MAX filed."""
        made = []
        for it in items or []:
            t = str(it.get("title") or "").strip(); b = str(it.get("body") or "").strip()
            if not t or not b: continue
            n = self.ensure_issue(t[:120], f"{b}\n\nFound by the refactoring research of #{self.issue}. "
                                         "Behavior unchanged; tests green; no test weakened.\n",
                                label="enhancement", assignee=BOT)
            if n:
                made.append(n)
                if len(made) == FOLLOWUP_MAX: break
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
            self.git.add_all()
            self.log("DRY-RUN: local verification green; stopping before commit/push/PR.\n"
                     + self.git.staged_stat())
            return self.save(stage="dry-run-done")
        self.save(stage="pr")

    def research_text(self):
        f = os.path.join(self.run_dir, RESEARCH_FILE)
        return read_text(f) if os.path.exists(f) else ""

    def merge_base(self):
        """Merge base of HEAD and origin/<default>, or origin/<default> when git cannot resolve it."""
        return self.git.merge_base(self.s["default"])

    def enhancement_blocker(self):
        """Blocker text when the enhancement's own staged changes touch credentials, secrets or production setup, else
        None. The index is compared with merge_base(), so commits main made after the branch forked off never block."""
        self.git.add_all()
        bad = protected_files(self.git.changed_names(self.s["default"]))
        return (f"the change touches credentials, secrets or production setup ({', '.join(bad)}); "
                "an enhancement PR may not.") if bad else None

    def find_open_pr(self):
        """Number of the PR already open for this branch, or None (gh prints a plain message, not a number, when there
        is none)."""
        p = self.s["plan"]
        r = self.gh("pr", "list", "-R", self.full, "--head", p["branch"], "--state", "open", "--json", "number", "-q", ".[0].number", check=False)
        return pr_number(r.stdout)

    def create_pr(self, head):
        """Open the PR (research section in the body), move the board to Review and say so on the issue.
        Raises RuntimeError when gh's output does not parse to a PR number: the driver must never save pr=None
        and advance to st_ci (which would run `gh pr checks None`)."""
        p = self.s["plan"]
        body = self.log_file("pr-body.md", with_research(f"Closes #{self.issue}\n\n{p.get('pr_summary', '')}\n\nCode by Pi on the {self.gpu_label()}; "
                                     f"planned, verified and merged by the factory bot's Pi driver (run `{self.s['run_id']}`).\n\n{DRIVER_MARK}\n",
                                     self.research_text()))
        r = self.gh("pr", "create", "-R", self.full, "--head", p["branch"], "--base", self.s["default"],
                    "--title", p["pr_title"], "--body-file", body, write=True)
        n = pr_number(r.stdout)
        if n is None:
            raise RuntimeError(f"gh pr create output is not a PR number: {r.stdout!r}")
        self.save(pr=n)
        self.move("Review")
        self.comment(f"In Progress → Review\n\nPR #{n} (head `{head[:8]}`). Required checks: running "
                     f"(local verification green, {self.s.get('verify_runs', 0)} runs). Change: {p.get('pr_summary', p['pr_title'])}\n\n{self.usage()}")
        return n

    def ensure_pr(self, head):
        """The PR-version of find-existing-or-create (the issue's ensure_issue pattern, for a different object: a
        PR, not an issue -- different gh verb, PR-specific fields, no label, and the merge gate needs PR author ==
        bot). Saved PR first, then the open PR for this branch, then create. Returns the PR number.
        create_pr raises when its output does not parse, so this never returns None."""
        if self.s.get("pr"): return self.s["pr"]
        if (n := self.find_open_pr()) is not None:
            self.save(pr=n); return n
        return self.create_pr(head)

    def st_pr(self):
        p = self.s["plan"]
        if p.get("kind") == "enhancement":
            if (why := self.enhancement_blocker()): return self.blocker(why)
        head = self.commit_push(p["pr_title"])
        self.ensure_pr(head)
        self.save(stage="ci")

    def st_ci(self):
        state, cs = self.wait_ci()
        if self.s.get("stage") == "blocked": return   # wait_ci's conflict Blocker was posted; the 4h blocker would stack on it
        self.log(f"required checks {state}")
        gate = self.merge_gate(cs)
        if state == CheckState.GREEN and not gate.quality_red():
            if gate.quality_pending():   # hard gate: Qodana and Refactoring rationale must finish green, never skipped
                since = self.s.setdefault("quality_wait_since", iso()); self.save()
                if (now() - dt.datetime.fromisoformat(since)).total_seconds() > QUALITY_WAIT_MIN * 60:
                    return self.blocker(f"{', '.join(gate.quality_pending())} did not finish within {QUALITY_WAIT_MIN} minutes.")
                self.heartbeat(); time.sleep(120); return
            self.s.pop("quality_wait_since", None)
            return self.save(stage="review")
        if state == CheckState.GREEN: return self.fix_quality(gate.quality_red(), cs)
        if state == CheckState.PENDING: return self.blocker("required checks did not finish within 4 hours.")
        runs, logs = self.failed_logs(cs)
        if classify_failure(logs) == FailureClass.INFRA:
            if not self.bump("infra_rerun"):
                return self.blocker(f"the same infrastructure step failed {LIMITS['infra_rerun']} times (runs {', '.join(runs)}).")
            time.sleep(600)
            for rid in runs:
                r = self.gh("run", "rerun", rid, "-R", self.full, "--failed", write=True, check=False)
                if r.returncode:   # refused: one empty commit instead (operating-instructions)
                    self.git.commit("Re-run CI after an infrastructure failure", allow_empty=True)
                    self.commit_push("Re-run CI"); break
            return
        if self.fix_pass("ci_fix", f"required checks still red after {LIMITS['ci_fix']} Pi fix passes.",
                         fix=FixRound("ci-fix", "Required CI checks failed on this branch. Failing job output (trimmed):\n```\n" + logs +
                                      "\n```\nFirst write three lines: the root cause, the file, the fix. Then fix the root cause with the "
                                      "smallest change. Never skip, delete, weaken or retry-wrap a test or gate, and add no baseline entries.",
                                      "ci", local_red=lambda n: f"local verification red after CI fix pass {n}.",
                                      commit=lambda n: f"Fix CI ({n})")) is None: return

    def fix_quality(self, bad, cs):
        """Qodana / Refactoring-rationale red while required checks are green: hand the findings to Pi, never idle."""
        bad_list = ", ".join(bad)
        links = "\n".join(f"- {c['name']}: {c.get('link') or 'no link'}" for c in cs if c["name"] in bad)
        _, logs = self.failed_logs([c for c in cs if c["name"] in bad])
        if self.fix_pass("quality_fix", f"{bad_list} still red after {LIMITS['quality_fix']} Pi fix passes.",
                         comment=lambda n: self.comment(f"Status: {bad_list} failed on PR #{self.s['pr']}; sending the findings to Pi "
                                                        f"(fix pass {n} of {LIMITS['quality_fix']})."),
                         fix=FixRound("quality-fix", f"These non-required checks failed and block the PR: {bad_list}.\n{links}\n"
                                      f"Findings (trimmed):\n```\n{logs or '(open the check link; no Actions log)'}\n```\n"
                                      "Qodana: fix every new problem in the code, with no baseline entries. Refactoring rationale: the PR description "
                                      "needs a `## Refactoring plan` section when a size-baselined file changes; write it to refactoring-plan.md in the "
                                      "repo root of this tree (the driver pastes it into the PR body) and shrink the file when you can. Smallest change.",
                                      "quality", local_red=lambda n: f"local verification red after quality fix pass {n}.",
                                      commit=lambda n: f"Fix {bad_list} ({n})",
                                      before_commit=self.paste_refactoring_plan)) is None: return

    def paste_refactoring_plan(self):
        """Pi writes `refactoring-plan.md` in the tree when a size-baselined file changed; the driver pastes it into
        the PR body's `## Refactoring plan` section and removes it from the tree so the fix commit stays clean
        (fix_quality runs it between the local verification and the push)."""
        plan = os.path.join(self.s["wt"], "refactoring-plan.md")
        if not os.path.exists(plan): return
        cur = self.pr_body()
        if "## Refactoring plan" not in cur:
            self.edit_pr_body(cur.rstrip() + "\n\n" + read_text(plan).strip() + "\n", "plan")
        os.remove(plan)

    def st_review(self):
        """The review stage, one decision per branch (cmdemo1-system#918): the evidence pass first, then the
        independent-review verdict. Each FAIL outcome (evidence failed / independent review FAIL) hands off to its own
        private helper (_st_review_evidence_failed / _st_review_verdict_fail); the PASS outcome saves the stage as
        merge. review_until_verdict owns the retry-an-INFRA-verdict policy, so the stage asks the verdict one kind of
        question and branches on verdict.is_fail."""
        p = self.s["plan"]; ev, failed = self.evidence_results()
        if failed:
            self._st_review_evidence_failed(failed)
            return
        self.save(evidence=[[c["text"], c["evidence_cmd"], last] for c, last, _ in ev])
        verdict = self.review_until_verdict()
        if verdict is None: return   # no verdict at all: review_until_verdict / independent_review already blocked the item
        self.s["counts"]["review_infra"] = 0; self.save()   # any real verdict, PASS or FAIL: the infra retries start over
        if verdict.is_fail:
            self._st_review_verdict_fail(verdict)
            return
        self.save(stage="merge")

    def _st_review_evidence_failed(self, failed):
        """The evidence-failed outcome of the review stage (cmdemo1-system#918): the criteria whose evidence_cmd went
        red, sent to Pi as a `review-fix` fix pass, then the board moves back to Review and the stage re-enters ci.
        Leaves the stage (returns) when fix_pass exhausted its review_fail budget."""
        evidence = "\n".join(f"- {c['text']}: evidence `{c['evidence_cmd']}` exit {rc}: {last}" for c, last, rc in failed)
        criteria = "\n".join(f"- {c['text']}: `{c['evidence_cmd']}` -> {last}" for c, last, _ in failed)
        if self.fix_pass("review_fail", "Review FAIL twice: " + "; ".join(f"{c['text']} (exit {rc})" for c, _, rc in failed),
                         progress="In Progress",
                         comment=lambda n: self.review_fail_comment(f"Review → In Progress\n\nReview: FAIL.\n\n{evidence}"
                                                                    "\n\nSending the failed criteria to Pi."),
                         fix=FixRound("review-fix", "These acceptance criteria fail their evidence commands:\n" + criteria +
                                      "\nFix the code so each passes.", "review",
                                      local_red="local verification red after a review fix.",
                                      commit="Fix review findings")) is None: return
        self.move("Review")
        self.save(stage="ci")

    def _st_review_verdict_fail(self, verdict):
        """The independent-review-FAIL outcome of the review stage (cmdemo1-system#918): the findings sent to Pi, or --
        when the PR body has no substantive research section -- the research redone and the body synced (a journal
        comment, no commit); otherwise the code-fix pi_round on the pass fix_pass already counted. Then the board moves
        back to Review and the stage re-enters ci. Leaves the stage (returns) when fix_pass / ensure_research_in_body /
        pi_round leave it."""
        p = self.s["plan"]; findings = verdict.findings
        n = self.fix_pass("review_fail", "independent review FAIL twice: " + findings[:600], progress="In Progress",
                          comment=lambda n: self.review_fail_comment(f"Review → In Progress\n\nReview: FAIL (independent review on the {self.gpu_label(self.s.get('reviewer_gpu'))}).\n\n"
                                                                     f"{findings[:3000]}\n\nSending the findings to Pi."))
        if n is None: return
        if not self.s.get("research_in_body"):   # the section is the driver's to write: redo the research, fix the body
            if not self.ensure_research_in_body(p): return
            self.sync_pr_research()
            self.comment("Research re-done after the review FAIL; the PR body's `## Refactoring research` section is updated.")   # journal activity: no commit on this path
        else:   # Pi fixes the code: the same fix round, on the pass the bump above already counted
            if not self.pi_round(f"review-fix-{n}", "An independent review of this branch failed. Findings:\n" + findings[:6000] +
                                 "\nFix each finding with the smallest change. Never skip, delete or weaken a test or gate.",
                                 f"review{n}", "local verification red after an independent-review fix.",
                                 "Fix independent review findings"): return
        self.move("Review")
        self.save(stage="ci")

    def evidence_results(self):
        """The per-criterion evidence pass of the review stage (cmdemo1-system#859): run each criterion's evidence_cmd
        through the one runner, keep the scrubbed output in logs/evidence-<i>.log, and return (ev, failed) -- the criteria
        that passed and the ones that did not, each as (criterion, last non-empty line, returncode). st_review branches
        on failed and saves the evidence list from ev."""
        ev, failed = [], []
        for i, c in enumerate(self.s["plan"]["criteria"], 1):
            r = run_cmd(["bash", "-o", "pipefail", "-c", c["evidence_cmd"]], cwd=self.s["wt"], text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=TIMEOUTS["evidence"])
            out = scrub(r.stdout); write_text(os.path.join(self.run_dir, "logs", f"evidence-{i}.log"), out)
            last = ([l for l in out.splitlines() if l.strip()][-1:] or [""])[0][:200]
            (ev if r.returncode == 0 else failed).append((c, last, r.returncode))
        return ev, failed

    def ensure_research_in_body(self, p):
        """Re-establish the PR body's `## Refactoring research` section after an independent-review FAIL
        (cmdemo1-system#859): when the section is missing or not substantive, reset the research count, run the research
        stage and set the stage back to review. Returns False when the research redo blocked the item (st_review then
        leaves); True when the section is (re)written and st_review may continue (sync_pr_research and the journal
        comment stay with the caller, as the source guard test_research_only_fix_path_leaves_journal_activity requires)."""
        if not research_ok(self.research_text(), p["files"]):
            self.s["counts"]["research"] = 0; self.save(stage="research", refactors_done=True)
            self.st_research()
            if self.s.get("stage") == "blocked": return False
            self.save(stage="review")
        return True

    def review_until_verdict(self):
        """The independent review, retried on any free GPU while it ends in an infrastructure failure (t83u, #887): an
        INFRA verdict says nothing about the code, so it is never a code FAIL and its text never reaches Pi. Returns
        the ReviewVerdict st_review branches on, or None when this stage must leave: `independent_review` blocked the
        item because no second GPU came up, or the LIMITS['review_infra'] retries of an INFRA verdict raised this
        Blocker. Bare (ok, findings) pairs are taken through ReviewVerdict.of so the stage asks one kind of question."""
        while True:
            verdict = ReviewVerdict.of(self.independent_review())
            if verdict is None or not verdict.is_infra: return verdict
            if not self.bump("review_infra"):
                self.blocker(f"independent review infra failed {LIMITS['review_infra'] + 1} times ({verdict.findings}); "
                             "this is not a code FAIL and no findings were sent to Pi. Check the review GPUs, then resume.")
                return None
            self.log(f"independent review infra failure: {verdict.findings}; retry {self.s['counts']['review_infra']} of "
                     f"{LIMITS['review_infra']} on any free GPU")

    def sync_pr_research(self):
        cur = self.pr_body(check=False)
        new = with_research(cur, self.research_text())
        if new.strip() != (cur or "").strip(): self.edit_pr_body(new, "research")

    def independent_review(self):
        """Pi on a different GPU than the author reviews the diff, the issue's criteria and the `## Refactoring
        research` section of the PR body (missing or not substantive = FAIL). Returns the ReviewVerdict (PASS / FAIL /
        INFRA, see review_verdict: no / empty findings file or no verdict), or None after a Blocker when no second GPU
        came up -- no review ran, so the stage leaves. The review runs on whichever non-author GPU has a free slot
        first."""
        p = self.s["plan"]
        body = self.pr_body(check=False)
        if not research_ok(body, p["files"]):
            self.save(research_in_body=False)
            return ReviewVerdict(False, f"- The PR body has no substantive `{RESEARCH_HEAD}` section "
                                        "(findings per touched file, in-scope refactors done, follow-ups filed). "
                                        "Every item needs it.")
        self.save(research_in_body=True)
        t_end = time.time() + REVIEWER_WAIT_H * 3600
        while True:
            rv = G.reviewer_gpus(self.author_gpus(), G.available(self.gpu_health(0 if self.s.get("reviewer_waited") else 600)))
            if rv or self.dry or time.time() > t_end: break
            self.save(reviewer_waited=True); self.heartbeat(); time.sleep(RECHECK_S)
        if not rv and not self.dry:
            self.blocker(f"no second GPU is up for the independent review of code written on {', '.join(self.gpu_label(g) for g in self.author_gpus())}."); return None
        rv = rv or [self.gpu()]; self.save(reviewer_gpu=rv[0])
        diff = self.git.diff(self.s["default"])
        limit = 60000 if all(g in G.LARGE_GPUS for g in rv) else 24000   # any small GPU may take it: size the prompt for the smallest
        out = os.path.join(self.run_dir, "independent-review.md")
        if os.path.exists(out): os.remove(out)
        crit = "\n".join(f"- {c['text']}" for c in p["criteria"])
        sec = research_section(body)
        if len(sec) > 24000:   # the reviewer must read every verdict: whole section, or a line-boundary cut that says so
            sec = sec[:24000].rsplit("\n", 1)[0].rstrip() + "\n(the section is longer than this prompt copy; the full text is in the PR body)"
        k = self.s["counts"].get("review_infra", 0)
        run = self.pi(f"independent-review-{self.s['counts'].get('review_fail', 0) + 1}" + (f"-retry-{k}" if k else ""),
                     f"Independent code review of {self.repo}#{self.issue} ({p['pr_title']}). You did not write this code. Change NO "
                     "files.\n\nAcceptance criteria:\n" + crit + "\n\nThe PR's refactoring research:\n" + sec +
                     f"\n\nDiff against {self.s['default']} (read any file in this tree for context):\n```diff\n{scrub(diff)[:limit]}\n```\n\n"
                     "Check: every criterion is met by the code and its tests; tests are real (none skipped, deleted or weakened); "
                     "the repository's AGENTS.md / CLAUDE.md rules hold; the code is easy to read (names, small methods, no "
                     "duplication) and the refactoring research is substantive and its in-scope items are done; no secret, "
                     f"credential or production-setup change. Write one bullet per problem to {out} (or `- No findings.`). "
                     "End your reply with PASS when there is no blocking problem, otherwise FAIL.", PI_TASK_TIMEOUT_S, gpu=G.gpu_arg(rv))
        rv = run.gpu or rv[0]; self.save(reviewer_gpu=rv)
        if self.git.status_porcelain():
            self.log("reviewer changed files; discarding them"); self.git.reset_hard()
            self.git.clean()
        verdict = review_verdict(run.result, scrub(read_text(out)) if os.path.exists(out) else None)
        self.log(f"independent review on {rv}: {verdict.label}")
        return verdict

    def check_held(self):
        """Raise PiHeld when a HOLD file appeared during a long stage pass (CI wait, review wait, deploy watch)."""
        if held(self.repo, self.issue): raise PiHeld(f"{self.full}#{self.issue} is held")

    def st_merge(self):
        self.check_held()
        pr = int(self.s["pr"]); _, cs = self.pr_checks(); gate = self.merge_gate(cs); state = gate.state()
        info = json.loads(self.gh("pr", "view", str(pr), "-R", self.full, "--json", "author,headRefOid,state").stdout)
        if (self.repo, pr) in NEVER_MERGE or info["author"]["login"] != BOT or not gate.green() or info["headRefOid"] != self.s["head"]:
            self.log(f"merge gate not met (checks {state}, head {info['headRefOid'][:8]})")
            exhausted = (f"merge gate not met after {LIMITS['merge_gate']} tries (checks {state}, PR head "
                         f"`{info['headRefOid'][:8]}` vs driver head `{str(self.s.get('head'))[:8]}`, author {info['author']['login']}).")
            if self.fix_pass("merge_gate", exhausted) is None: return   # was an unbounded ci -> review -> merge spin
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
            self.gh("run", "watch", str(run["id"]), "-R", self.full, "--interval", "60", check=False, timeout=TIMEOUTS["gh_watch"])
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
                    r = self.deploy_env_check(e, dep, sha)
                    if r is None: continue
                    in_env[e["name"]], ver[e["name"]] = r
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

    def deploy_env_check(self, env, dep, sha):
        """One environment's half of the st_deploy watch (cmdemo1-system#859): the deployable's compare status, its
        health and the red-flag side effects for this environment (set the red flag + fix-forward issue + comment when it
        is red at the merge commit, clear it when it turns healthy), returning the (in_env, (version, commit)) pair the
        board moves are built from. None when this environment has no entry for the deployable (the watch skips it)."""
        x = next((x for x in env.get("deployables") or [] if x.get("name") == dep), None)
        if not x: return None
        st = json.loads(self.gh("api", f"repos/{self.full}/compare/{sha}...{x['commit']}", "--jq", "{status:.status}",
                                check=False).stdout or "{}").get("status")
        rk = f"{dep} {env['name']}"
        red = env_red(env, dep)
        # A deployable with no containerApps health entry is treated as healthy once its deploy has passed
        # (cmdemo1-system#847): env_red is already False when no entry is recorded (or dep is `system`), so the
        # board-advancing health gate is exactly the inverse of the red flag. A deployable that HAS an entry
        # reading unhealthy is red and still does not advance.
        healthy = not red
        if red and st in ("ahead", "identical"):
            if rk not in red_load():
                red_set(rk, f"{dep} {x.get('version')} unhealthy in {env['name']}")
                self.fix_forward_issue(rk, f"{dep} {x.get('version')} is not healthy in {env['name']} (delivery.json)", "cmdemo1-system")
                self.comment(f"Status: {dep} {x.get('version')} (contains merge `{sha[:8]}`) is not healthy in {env['name']}. "
                             "Intake is stopped and a fix-forward issue is filed; the driver keeps watching.")
        elif healthy and rk in red_load(): red_clear(rk)
        return st in ("ahead", "identical") and healthy, (x.get("version"), x["commit"])

    def fix_forward_issue(self, key, what, repo=None):
        """One open `fix-forward` issue per red key, assigned to the factory bot so its issue-assigned wake works it
        first (intake is stopped for everything else until it is green again)."""
        full = f"{ORG}/{repo or self.repo}"; title = f"Fix forward: {key} is red"
        self.gh("label", "create", "fix-forward", "-R", full, "--color", "B60205", "--description", "Red main or environment; fix forward",
                write=True, check=False)
        self.ensure_issue(title, f"{what}.\n\nFound while following #{self.issue} (run `{self.s.get('run_id')}`). Fix forward with a "
                                "normal PR (plan `fix_forward: true`); never re-run, re-pin or promote by hand, and never "
                                "weaken a test or gate. Intake of other items stays stopped until this is green.\n",
                        label="fix-forward", assignee=BOT, repo=repo)

    def _col_before(self, moves):
        return BOARD_ORDER[BOARD_ORDER.index(moves[0]) - 1]

def watchdog_exit(drv):
    """Driver-exit hook: the shared watchdog checks (factory/pi/watchdog.py) run exactly once when a
    driver run ends (done, blocker or error) -- the full set, check 3 (own green PRs) included (own_prs=True).
    A check's failure (and a failed `import watchdog`) is logged; this function never raises and never changes
    the driver's exit status or replaces its exception."""
    try:
        import watchdog
        watchdog.run_checks(log=drv.log, own_prs=True)
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

def draft_result(draft, pi_pass, errors):
    """What cmd_draft_plan reports on stdout (the draft path, whether the Pi pass ended PASS, and the plan-validation
    errors): a Pi that never started and a plan that did not validate report the same way."""
    print(json.dumps({"draft": draft, "pi_pass": pi_pass, "errors": errors}, indent=1))

def cmd_draft_plan(a):
    d = Driver(a.repo, a.issue, top_session=a.top_session)
    iss = json.loads(d.gh("api", f"repos/{d.full}/issues/{a.issue}", "--jq", "{title,body}").stdout)
    d.plan_worktree()
    out, prompt = draft_plan_prompt(a.repo, a.issue, iss["title"], iss["body"], os.path.join(d.run_dir, PLAN_DRAFT_FILE))
    # plan drafting runs before the gpu stage: no gpu recorded yet, so ask for any free 262K GPU (#907) rather than queueing on pro5000
    try: run = d.pi("draft-plan", prompt, d.budgets.draft_plan_s, gpu=G.gpu_arg(G.LARGE_GPUS))
    except PiNotStarted as e: draft_result(out, False, [str(e)]); sys.exit(1)
    try:
        with open(out) as f: p = json.load(f)
        errs = validate_plan(p)
    except Exception as e:
        p, errs = None, [f"no valid JSON plan: {e}"]
    draft_result(out, run.ok, errs)
    print("Review plan.draft.json; copy it to plan.json (edit as needed), then run `item-loop start`.")
    sys.exit(0 if not errs else 1)

def refuse_held(a):
    h = held(a.repo, a.issue)
    if h: print(f"{a.repo}#{a.issue} is held, not starting: {h[:300]}"); sys.exit(0)

def cmd_start(a):
    refuse_held(a)
    d = Driver(a.repo, a.issue, top_session=a.top_session)
    plan_p = os.path.join(d.run_dir, PLAN_FILE)
    with open(plan_p) as f: p = json.load(f)
    labels = d.gh("api", f"repos/{d.full}/issues/{a.issue}", "--jq", "[.labels[].name]", check=False).stdout
    try: labels = json.loads(labels or "[]")
    except Exception: labels = []
    if "enhancement" in labels and p.get("kind") != "enhancement": p["kind"] = "enhancement"
    if "fix-forward" in labels: p["fix_forward"] = True
    errs = validate_plan(p)
    if errs: print("plan.json invalid:\n- " + "\n- ".join(errs)); sys.exit(2)
    write_text(plan_p, json.dumps(p, indent=1))
    red = red_load()
    if not intake_open(red, p):
        print("NOTE: intake is stopped while red (" + "; ".join(red) + "); the driver waits in Todo until it is green.")
    d.s.setdefault("top_sessions", [])
    if a.top_session and a.top_session not in d.s["top_sessions"]: d.s["top_sessions"].append(a.top_session)
    if a.resume: d.s = apply_resume(d.s)   # Jeffrey answered the Blocker: the one resume rule picks the stage, clears the pause and zeroes the limits (no-op unless the item is paused)
    d.save()
    # The driver.out handle is passed as stdout to the nohup launch and must stay open for the child's
    # lifetime; the `with` block closes the parent's copy after the child has inherited it (cmdemo1-system#898).
    with open(os.path.join(d.run_dir, "driver.out"), "a") as log:
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
        with open(meta_p) as f: m = json.load(f)
        m["top_sessions"] = d.s["top_sessions"]; write_text(meta_p, json.dumps(m, indent=1))

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
