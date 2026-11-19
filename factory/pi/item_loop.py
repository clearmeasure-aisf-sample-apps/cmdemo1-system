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
and `gh run watch` (no LLM call while waiting). Pi tasks go through run-task (at most 2 at once on the RTX Pro 5000).
Secrets never reach a log, comment or Pi prompt (scrubbed).
"""
import argparse, datetime as dt, fcntl, json, os, re, shlex, subprocess, sys, time, urllib.request, uuid

ORG = "clearmeasure-aisf-sample-apps"
BOT = "cm-ai-ops-bot"
BOT_GIT = ["-c", f"user.name={BOT}", "-c", "user.email=jeffrey+ai-ops@clear-measure.com"]
PROJECT = "PVT_kwDOD_ESUc4BliGL"
STATUS_FIELD = "PVTSSF_lADOD_ESUc4BliGLzhkOn7g"
STATUS = {"Todo": "f75ad846", "In Progress": "47fc9ee4", "Review": "e19122d0", "Merged": "8012c69b",
          "TDD": "eeb01ba5", "UAT": "ebff1a13", "Done": "98236657"}
REQUIRED = {"cmdemo1-workorders": ["Build result", "secret-scan"], "cmdemo1-system": ["env-checks"]}
DEPLOYABLE = {"cmdemo1-workorders": "ui", "cmdemo1-dashboard": "dashboard", "cmdemo1-system": "system"}
DELIVERY = f"https://raw.githubusercontent.com/{ORG}/cmdemo1-system/status/delivery.json"
NEVER_MERGE = {("cmdemo1-workorders", 1918)}
DRIVER_MARK = "<!-- factory-pi-driver -->"
# Existing limits (operating-instructions): 2 Review FAILs, 3 infrastructure reruns; then a Blocker.
LIMITS = {"local_fix": 3, "ci_fix": 3, "review_fail": 2, "infra_rerun": 3}
HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")

SECRET_RE = re.compile(r"(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|https?://[^\s'\"]*trycloudflare\.com[^\s'\"]*"
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
    for name in ("LOCAL_LLM_PRO5000_URL", "LOCAL_LLM_PRO5000_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "CM_AI_OPS_BOT_GH_TOKEN"):
        v = os.environ.get(name)
        if v and len(v) > 6: s = s.replace(v, "[redacted]")
    return s

# ---------------------------------------------------------------- pure helpers (unit-tested)
def classify_failure(log_text):
    """'infra' when the failure never reached the code (network, registry, runner), else 'code'."""
    if CODE_RE.search(log_text or ""): return "code"
    return "infra" if INFRA_RE.search(log_text or "") else "code"

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
    if not names: return "PENDING"
    rs = [st.get(n, "pending") for n in names]
    if any(b in ("fail", "cancel") for b in rs): return "RED"
    if all(b in ("pass", "skipping") for b in rs): return "GREEN"
    return "PENDING"

def validate_plan(p):
    errs = []
    for k in ("repo", "issue", "branch", "files", "criteria", "tasks", "verify_cmd", "pr_title"):
        if k not in p or p[k] in (None, "", []): errs.append(f"missing {k}")
    if not str(p.get("branch", "")).startswith(f"{BOT}/"): errs.append(f"branch must start with {BOT}/")
    for i, c in enumerate(p.get("criteria") or []):
        if not c.get("text") or not c.get("evidence_cmd"): errs.append(f"criteria[{i}] needs text and evidence_cmd")
    for i, t in enumerate(p.get("tasks") or []):
        if not t.get("name") or not t.get("prompt"): errs.append(f"tasks[{i}] needs name and prompt")
    if (p.get("repo"), p.get("issue")) in NEVER_MERGE: errs.append("this item's PR is never merged")
    blob = json.dumps(p)
    if scrub(blob) != blob: errs.append("plan contains a secret-looking value")
    if re.search(r"git\s+(push|commit)|gh\s+(pr|issue|api)", " ".join(t.get("prompt", "") for t in p.get("tasks") or [])):
        errs.append("Pi task prompts must not ask Pi to commit, push or call gh")
    return errs

def docs_only(files):
    return bool(files) and all(f.endswith(".md") or f.startswith("docs/") for f in files)

def deploy_moves(column, in_env):
    """column: current board column; in_env: {'tdd': bool, 'uat': bool, 'prod': bool}. Returns the moves to make."""
    order = ["Merged", "TDD", "UAT", "Done"]
    target = "Done" if in_env.get("prod") else "UAT" if in_env.get("uat") else "TDD" if in_env.get("tdd") else column
    if column not in order or order.index(target) <= order.index(column): return []
    return order[order.index(column) + 1: order.index(target) + 1]

def pickup_comment(p, run_id, run_dir):
    plan = "\n".join(f"  - [ ] {c['text']} — {c.get('how') or 'evidence: `' + c['evidence_cmd'] + '`'}" for c in p["criteria"])
    cons = "; ".join(f'"{c}"' for c in p.get("constraints") or []) or "none stated"
    return (f"Todo → In Progress\n\n{BOT} is taking this issue.\n\n"
            f"- `Files:` {', '.join('`' + f + '`' for f in p['files'])}. `Docs-only: {'yes' if docs_only(p['files']) else 'no'}`.\n"
            f"- Plan:\n{plan}\n- Constraints: {cons}\n"
            f"- `Pi driver:` run `{run_id}` (`{run_dir.replace(HOME, '~')}`); Pi tasks: {', '.join(t['name'] for t in p['tasks'])}.")

# ---------------------------------------------------------------- side-effect layer
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
        self.full = f"{ORG}/{repo}"

    # state / log
    def save(self, **kw):
        self.s.update(kw); self.s["updated"] = iso(); self.s["pid"] = os.getpid()
        tmp = self.state_p + ".tmp"; json.dump(self.s, open(tmp, "w"), indent=1); os.replace(tmp, self.state_p)
    def log(self, msg):
        line = f"{iso()} {scrub(msg)}"
        print(line, flush=True)
        open(os.path.join(self.run_dir, "driver.log"), "a").write(line + "\n")

    def sh(self, cmd, cwd=None, check=True, timeout=None, write=False):
        """write=True marks a GitHub- or remote-changing step: skipped (logged) in dry-run."""
        shown = cmd if isinstance(cmd, str) else " ".join(shlex.quote(c) for c in cmd)
        if write and self.dry:
            self.log(f"DRY-RUN skip: {shown[:300]}"); return subprocess.CompletedProcess(cmd, 0, "", "")
        r = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), text=True, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if check and r.returncode:
            raise RuntimeError(f"failed ({r.returncode}): {shown[:300]}\n{scrub(r.stdout)[-2000:]}")
        return r
    def gh(self, *a, write=False, check=True): return self.sh(["gh", *a], check=check, write=write)

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
        self.save(stage="blocked", status="blocked", blocker=what); self.wake_bot("blocked")

    def usage(self, final=False):
        a = [os.path.join(HERE, "usage-report"), "--run-dir", self.run_dir] + (["--final"] if final else [])
        return self.sh(a, check=False).stdout.strip()

    # Pi
    def pi(self, name, prompt, timeout=1800):
        pf = os.path.join(self.run_dir, "logs", f"{name}.prompt.md")
        suffix = ("\n\nRules: follow the repository's AGENTS.md and CLAUDE.md (read them if this task touches code, tests or "
                  "the build). Make only the change asked. Do not run git commit, git push or gh, and do not read or print "
                  "credentials. When done, run the narrowest relevant build/test, then end your reply with PASS or FAIL as "
                  "the last line.")
        open(pf, "w").write(scrub(prompt) + suffix)
        r = self.sh([os.path.join(HERE, "run-task"), "--run-dir", self.run_dir, "--cwd", self.s["wt"], "--task", name,
                     "--prompt-file", pf, "--timeout", str(timeout)], check=False)
        self.log(f"pi {name}: " + (r.stdout.splitlines() or ["?"])[0][:300])
        return r.returncode == 0

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
        wt = self.s["wt"]
        self.sh(["git", "add", "-A"], cwd=wt)
        if self.sh(["git", "diff", "--cached", "--quiet"], cwd=wt, check=False).returncode:
            self.sh(["git", *BOT_GIT, "commit", "-q", "-m", msg + f"\n\nCode by Pi (RTX Pro 5000); planned by the factory bot; "
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
            if cs and state != "PENDING": return state, cs
            if cs:
                self.sh(["gh", "pr", "checks", str(self.s["pr"]), "-R", self.full, "--watch", "--interval", "60"]
                        + (["--required"] if self.repo in REQUIRED else []), check=False, timeout=max_s)
            time.sleep(60)
        return "PENDING", []

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
            self.sh(["gh", "repo", "clone", self.full, clone, "--", "-q"])
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
            self.sh(["gh", "repo", "clone", self.full, clone, "--", "-q"])
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
        self.s.setdefault("start", iso()); self.s.setdefault("stage", "pickup")
        self.s["plan"] = json.load(open(os.path.join(self.run_dir, "plan.json")))
        self.save(status="running")
        meta_p = os.path.join(self.run_dir, "run.json")
        meta = json.load(open(meta_p)) if os.path.exists(meta_p) else {"start": self.s["start"]}
        meta.update(driver_run_id=self.s["run_id"], top_sessions=self.s.get("top_sessions") or [self.s.get("top_session", "unnamed")])
        meta.setdefault("top_session", self.s.get("top_session", "unnamed"))
        meta.setdefault("pi_version", self.sh(["pi", "--version"], check=False).stdout.strip().splitlines()[-1:] and
                        self.sh(["pi", "--version"], check=False).stdout.strip().splitlines()[-1])
        json.dump(meta, open(meta_p, "w"), indent=1)
        try:
            while self.s["stage"] not in ("done", "blocked", "dry-run-done"):
                stage = self.s["stage"]; self.log(f"stage {stage}")
                getattr(self, "st_" + stage.replace("-", "_"))()
        except Exception as e:  # unexpected: record, wake the bot once, never guess
            self.log(f"driver error: {e}")
            self.save(status="error", error=scrub(str(e))[-1500:]); self.wake_bot("driver error")
            raise
        self.save(status=self.s["stage"], end=iso())

    def st_pickup(self):
        p = self.s["plan"]; self.setup_worktree()
        if not self.s.get("pickup_posted"):
            self.move("In Progress"); self.comment(pickup_comment(p, self.s["run_id"], self.run_dir))
            self.save(pickup_posted=True)
        self.save(stage="implement")

    def st_implement(self):
        done = set(self.s.get("tasks_done", []))
        for t in self.s["plan"]["tasks"]:
            if t["name"] in done: continue
            self.pi(t["name"], t["prompt"], int(t.get("timeout", 1800)))
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

    def st_pr(self):
        p = self.s["plan"]; head = self.commit_push(p["pr_title"])
        if not self.s.get("pr"):
            r = self.gh("pr", "list", "-R", self.full, "--head", p["branch"], "--state", "open", "--json", "number", "-q", ".[0].number", check=False)
            if r.stdout.strip(): self.save(pr=int(r.stdout.strip()))
        if not self.s.get("pr"):
            body = os.path.join(self.run_dir, "logs", "pr-body.md")
            open(body, "w").write(scrub(f"Closes #{self.issue}\n\n{p.get('pr_summary', '')}\n\nCode by Pi on the RTX Pro 5000; "
                                        f"planned, verified and merged by the factory bot's Pi driver (run `{self.s['run_id']}`).\n\n{DRIVER_MARK}\n"))
            r = self.gh("pr", "create", "-R", self.full, "--head", p["branch"], "--base", self.s["default"],
                        "--title", p["pr_title"], "--body-file", body, write=True)
            self.save(pr=int(r.stdout.strip().rstrip("/").split("/")[-1]))
            self.move("Review")
            self.comment(f"In Progress → Review\n\nPR #{self.s['pr']} (head `{head[:8]}`). Required checks: running "
                         f"(local verification green, {self.s.get('verify_runs', 0)} runs). Change: {p.get('pr_summary', p['pr_title'])}\n\n{self.usage()}")
        self.save(stage="ci")

    def st_ci(self):
        state, cs = self.wait_ci()
        self.log(f"required checks {state}")
        if state == "GREEN": return self.save(stage="review")
        if state == "PENDING": return self.blocker("required checks did not finish within 4 hours.")
        runs, logs = self.failed_logs(cs)
        if classify_failure(logs) == "infra":
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
            self.comment("Review → In Progress\n\nReview: FAIL.\n\n" + "\n".join(f"- {c['text']}: evidence `{c['evidence_cmd']}` exit {rc}: {last}" for c, last, rc in failed)
                         + "\n\nSending the failed criteria to Pi.")
            self.pi(f"review-fix-{self.s['counts']['review_fail']}", "These acceptance criteria fail their evidence commands:\n" +
                    "\n".join(f"- {c['text']}: `{c['evidence_cmd']}` -> {last}" for c, last, _ in failed) + "\nFix the code so each passes.")
            if not self.local_green(f"review{self.s['counts']['review_fail']}"):
                return self.blocker("local verification red after a review fix.")
            self.commit_push("Fix review findings"); self.move("Review")
            return self.save(stage="ci")
        self.save(evidence=[[c["text"], c["evidence_cmd"], last] for c, last, _ in ev], stage="merge")

    def st_merge(self):
        pr = int(self.s["pr"]); state, _ = self.pr_checks()
        info = json.loads(self.gh("pr", "view", str(pr), "-R", self.full, "--json", "author,headRefOid,state").stdout)
        if (self.repo, pr) in NEVER_MERGE or info["author"]["login"] != BOT or state != "GREEN" or info["headRefOid"] != self.s["head"]:
            self.log(f"merge gate not met (checks {state}, head {info['headRefOid'][:8]})"); return self.save(stage="ci")
        if info["state"] != "MERGED":
            self.gh("pr", "merge", str(pr), "-R", self.full, "--squash", "--match-head-commit", self.s["head"], write=True)
        sha = self.gh("pr", "view", str(pr), "-R", self.full, "--json", "mergeCommit", "-q", ".mergeCommit.oid").stdout.strip()
        self.save(merge_sha=sha, stage="main")

    def st_main(self):
        sha, d_only = self.s["merge_sha"], docs_only(self.s["plan"]["files"])
        time.sleep(30); runs = []
        for _ in range(20):   # wait for push runs of the merge commit to appear (none when paths-ignore skips them)
            r = self.gh("api", f"repos/{self.full}/actions/runs?head_sha={sha}&event=push&per_page=50", "--jq",
                        "[.workflow_runs[]|{id,name,conclusion}]", check=False)
            runs = json.loads(r.stdout or "[]")
            if runs: break
            time.sleep(30)
        for run in runs:
            self.sh(["gh", "run", "watch", str(run["id"]), "-R", self.full, "--interval", "60"], check=False, timeout=6 * 3600)
        r = self.gh("api", f"repos/{self.full}/actions/runs?head_sha={sha}&event=push&per_page=50", "--jq",
                    "[.workflow_runs[]|{name,conclusion}]", check=False)
        red = [x["name"] for x in json.loads(r.stdout or "[]") if x["conclusion"] not in ("success", "skipped", "neutral")]
        ev = "\n".join(f"- {t}: `{cmd}` passed — {last}" for t, cmd, last in self.s.get("evidence", []))
        col = "Done" if d_only and not red else "Merged"
        self.move(col)
        self.comment(f"Review → {col}\n\nReview: PASS. Squash-merged PR #{self.s['pr']} (head `{self.s['head'][:8]}`) as `{sha}`. "
                     f"Required checks green.\n\n{ev}\n\n{self.usage(final=(col == 'Done'))}")
        if red: return self.blocker(f"default-branch run(s) {', '.join(red)} of merge `{sha[:8]}` are red.")
        self.save(stage="done" if d_only or self.repo not in DEPLOYABLE else "deploy")

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
            time.sleep(600)
        self.log("deploy follow-through window ended; the bot's Deployments sweep takes over")
        self.save(stage="done", deploy_handoff=True)

    def _col_before(self, moves):
        order = ["Merged", "TDD", "UAT", "Done"]
        return order[order.index(moves[0]) - 1]

# ---------------------------------------------------------------- commands
def cmd_draft_plan(a):
    d = Driver(a.repo, a.issue, top_session=a.top_session)
    iss = json.loads(d.gh("api", f"repos/{d.full}/issues/{a.issue}", "--jq", "{title,body}").stdout)
    d.plan_worktree()
    out = os.path.join(d.run_dir, "plan.draft.json")
    prompt = (f"Draft an implementation plan for GitHub issue {a.repo}#{a.issue}. Read the repository (AGENTS.md, CLAUDE.md, "
              f"the files involved) but change NO files.\n\nIssue title: {iss['title']}\n\nIssue body:\n{iss['body']}\n\n"
              f"Write the plan as JSON to the file {out} with keys: repo ({a.repo!r}), issue ({a.issue}), branch "
              f"('{BOT}/{a.issue}-<short-slug>'), files (every file to change), constraints (each Notes/Constraints/Out-of-scope "
              "sentence quoted), criteria (one per acceptance criterion: text, how, evidence_cmd = a shell command that exits 0 "
              "only when the criterion holds, e.g. a filtered test run or an HTTP probe), tasks (small ordered Pi tasks: name, "
              "prompt; one test or one code change each; tests first), verify_cmd (the repo's real build+test command, "
              "narrowed to the touched projects), pr_title, pr_summary (one line).")
    ok = d.pi("draft-plan", prompt, 1500)
    try:
        p = json.load(open(out)); errs = validate_plan(p)
    except Exception as e:
        p, errs = None, [f"no valid JSON plan: {e}"]
    print(json.dumps({"draft": out, "pi_pass": ok, "errors": errs}, indent=1))
    print("Review plan.draft.json; copy it to plan.json (edit as needed), then run `item-loop start`.")
    sys.exit(0 if not errs else 1)

def cmd_start(a):
    d = Driver(a.repo, a.issue, top_session=a.top_session)
    p = json.load(open(os.path.join(d.run_dir, "plan.json"))); errs = validate_plan(p)
    if errs: print("plan.json invalid:\n- " + "\n- ".join(errs)); sys.exit(2)
    d.s.setdefault("top_sessions", [])
    if a.top_session and a.top_session not in d.s["top_sessions"]: d.s["top_sessions"].append(a.top_session)
    if d.s.get("status") in ("blocked", "error") and a.resume:
        d.s["stage"] = d.s.get("resume_stage") or ("ci" if d.s.get("pr") else "implement"); d.s.pop("blocker", None)
        d.s["counts"] = {k: 0 for k in LIMITS}   # Jeffrey answered the Blocker: the limits start again
    d.save()
    log = open(os.path.join(d.run_dir, "driver.out"), "a")
    cmd = [sys.executable, os.path.abspath(__file__), "run", "--repo", a.repo, "--issue", str(a.issue)] + (["--dry-run"] if a.dry_run else [])
    p = subprocess.Popen(["nohup", *cmd], stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
    print(f"driver started pid {p.pid}; state {d.state_p}. End your turn; GitHub events wake you.")

def cmd_run(a): Driver(a.repo, a.issue, dry_run=a.dry_run).run()

def cmd_status(a):
    d = Driver(a.repo, a.issue); s = d.s
    alive = False
    if s.get("pid"):
        try: os.kill(int(s["pid"]), 0); alive = True
        except Exception: pass
    print(json.dumps({k: s.get(k) for k in ("run_id", "stage", "status", "pr", "head", "merge_sha", "column", "counts",
                                             "blocker", "error", "wake_reason", "updated")} | {"alive": alive}))

def cmd_note_wake(a):
    d = Driver(a.repo, a.issue); d.s.setdefault("top_sessions", [])
    if a.top_session not in d.s["top_sessions"]: d.s["top_sessions"].append(a.top_session)
    d.save(); meta_p = os.path.join(d.run_dir, "run.json")
    if os.path.exists(meta_p):
        m = json.load(open(meta_p)); m["top_sessions"] = d.s["top_sessions"]; json.dump(m, open(meta_p, "w"), indent=1)

def main():
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest="c", required=True)
    for name in ("draft-plan", "start", "run", "status", "note-wake"):
        x = sp.add_parser(name); x.add_argument("--repo", required=True); x.add_argument("--issue", type=int, required=True)
        x.add_argument("--top-session", required=(name == "note-wake"))
        x.add_argument("--dry-run", action="store_true"); x.add_argument("--resume", action="store_true")
    a = ap.parse_args()
    {"draft-plan": cmd_draft_plan, "start": cmd_start, "run": cmd_run, "status": cmd_status, "note-wake": cmd_note_wake}[a.c](a)

if __name__ == "__main__": main()
