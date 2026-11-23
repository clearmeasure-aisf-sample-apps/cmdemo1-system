#!/usr/bin/env python3
"""Shared factory watchdog: a small registry of checks that run from the CLI
(`python3 factory/pi/watchdog.py run`) and that the Pi driver's exit hook (item_loop.watchdog_exit) runs
once when a driver run ends. No schedule: the repo's rules wake the bot on GitHub events only.

    python3 factory/pi/watchdog.py run

Scope: cmdemo1-workorders, cmdemo1-dashboard and cmdemo1-system.

Shared hard-rule guards used by every check: excluded items are left alone (item_loop's NEVER_MERGE and
HANDS_OFF, plus system #652 and workorders #1672); the WIP cap is item_loop's wip_limit; items whose driver
is alive and progressing are skipped; a check comments only when it took an action, and comments on one
item are at least COMMENT_GAP_S apart; every log line and comment is scrubbed of secrets and tunnel URLs.
A check's failure is caught and logged; it never changes the caller's result.

Check 2 (fix_handoff_check): a driver PR whose latest review FAIL is 20+ min old with no fix commit and no driver
activity gets one flagged comment on its issue and on the PR (read-only otherwise).

Check 1: GPU health for pro5000, obs (RTX 5070 Ti) and ts3 (RTX 5060 Ti) via the gpu.py models list
(read-only: one GET /models per GPU; it never starts, stops or warms a model server). A down GPU is
reported in the log and in run_checks' result, and GPU selection routes to the healthy GPUs.

item_loop imports watchdog only lazily (inside watchdog_exit), so importing item_loop here cannot be circular.
"""
import argparse, datetime as dt, json, os, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gpu as G
import item_loop as L

REPOS = ("cmdemo1-workorders", "cmdemo1-dashboard", "cmdemo1-system")

# ---------------------------------------------------------------- shared hard-rule guards (used by every check)
# item_loop's NEVER_MERGE and HANDS_OFF, plus the excluded issues Jeffrey named: system #652, workorders #1672.
EXCLUDED = L.NEVER_MERGE | L.HANDS_OFF | {("cmdemo1-system", 652), ("cmdemo1-workorders", 1672)}
COMMENT_GAP_S = 61.0   # never two comments on one item within a minute
_last_comment = {}     # watchdog-owned: (repo, issue) -> iso time of the watchdog's last comment (state.json is never written)

def excluded(repo, issue):
    """Hard rule: a check must never touch these items (no action, no comment)."""
    try:
        return (repo, int(issue)) in EXCLUDED or bool(L.held(repo, issue))   # + a run dir HOLD file (t85u)
    except (TypeError, ValueError):
        return False

def wip_limit(repo):
    """Hard rule: the per-repo WIP cap, reused from item_loop (3 per repo, dashboard 8)."""
    return L.wip_limit(repo)

def scrub(text):
    """Shared scrub: no secret or tunnel URL ever reaches a log line or a comment."""
    return L.scrub(text or "")

def alive_progressing(state, at=None):
    """Skip guard: True while the item's driver is alive and still progressing (a live pid with progress no
    older than item_loop's HEARTBEAT_MIN). A check leaves such items to their driver."""
    st = state or {}
    if not L.pid_alive(st.get("pid")):
        return False
    at = at or L.now()
    p = st.get("progress_at") or st.get("start")
    if not p:
        return True
    return (at - dt.datetime.fromisoformat(p)).total_seconds() < L.HEARTBEAT_MIN * 60

def wip_full(states, repo, me=None, alive=L.pid_alive):
    """True while the repo is at its WIP cap (item_loop's repo_wip): a check must not open new work there."""
    return L.repo_wip(states, repo, me, alive) >= wip_limit(repo)

def gh_subprocess(args):
    return subprocess.run(["gh", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def post_comment(repo, issue, body, states, gh=None, clock=None, log=None):
    """Comment only when a check took an action: the body must be non-empty, the item must not be excluded
    and its driver must not be alive and progressing; a comment lands at least COMMENT_GAP_S after the
    watchdog's own last comment on that item (its own tracking, kept in this module) and after the item's
    last driver comment (read from the caller's state, never written there); the posted body is scrubbed.
    Returns the posted body, or None when nothing was posted."""
    clock = clock or L.now
    log = log or print
    body = scrub(body)
    if not body or excluded(repo, issue):
        return None
    st = next((s for _, s in states or [] if s.get("repo") == repo and s.get("issue") == int(issue)), {})
    if alive_progressing(st, clock()):
        return None
    key = (repo, int(issue))
    stamps = [t for t in (_last_comment.get(key), st.get("last_comment_at")) if t]
    if stamps:
        last = max(dt.datetime.fromisoformat(t) for t in stamps)
        wait = COMMENT_GAP_S - (clock() - last).total_seconds()
        if wait > 0:
            time.sleep(wait)
    with tempfile.NamedTemporaryFile("w", prefix="wd-comment-", suffix=".md", delete=False) as f:
        f.write(body)
        p = f.name
    try:
        r = (gh or gh_subprocess)(["issue", "comment", str(issue), "-R", f"{L.ORG}/{repo}", "--body-file", p])
    finally:
        os.unlink(p)
    if r.returncode != 0:
        log("watchdog comment on %s#%s failed: %s" % (repo, issue, scrub(r.stdout or "")))
        return None
    _last_comment[key] = clock().isoformat()
    return body

# ---------------------------------------------------------------- check registry
CHECKS = []

def register(check):
    """Register one check: (repos, gh, health, clock, log) -> result."""
    CHECKS.append(check)
    return check

def run_checks(repos=REPOS, gh=None, health=None, clock=None, log=None):
    """Run every registered check exactly once. Each check gets (repos, gh, health, clock, log); a check's
    failure is caught, scrubbed and logged, and appears in the result list as 'error: <message>'.
    Returns [(check name, result), ...]; the caller's result is never changed."""
    log = log or print
    gh = gh or gh_subprocess
    health = health or L.gpu_health   # the driver's cached probe, so an exit hook never fires three fresh GETs
    clock = clock or L.now
    results = []
    for c in CHECKS:
        try:
            results.append((c.__name__, c(repos=repos, gh=gh, health=health, clock=clock, log=log)))
        except Exception as e:
            msg = scrub(str(e))
            log("watchdog check %s failed: %s" % (c.__name__, msg))
            results.append((c.__name__, "error: " + msg))
    return results

@register
def gpu_health_check(repos=REPOS, gh=None, health=None, clock=None, log=None):
    """Check 1: GPU health for pro5000, obs (RTX 5070 Ti) and ts3 (RTX 5060 Ti) via the gpu.py models list
    (read-only: one GET /models per GPU; it never starts, stops or warms a model server). A down GPU is
    reported in the log and in this check's result ("down: <gpu>"), and GPU selection routes to the healthy
    GPUs; selection never picks a down GPU. All GPUs healthy is a no-op ("ok", no comment)."""
    h = health()
    up = G.available(h)
    down = [g for g in G.GPUS if g not in up]
    for g in down:
        s, d = h[g]
        log("watchdog GPU %s (%s): %s - %s" % (g, G.GPUS[g]["label"], s, scrub(d)))
    if not up:
        log("watchdog: no GPU is healthy; ask Jeffrey (never restart or warm a server)")
        return "no healthy GPU"
    busy = L.busy_gpus(L.all_states(), alive=L.pid_alive)
    picks = {size: G.pick_gpu(size, up, busy) for size in ("large", "small")}
    for size, g in picks.items():
        if g is not None and g not in up:
            raise RuntimeError("GPU selection routed a %s item to the down GPU %s" % (size, g))
    log("watchdog GPU selection: " + ", ".join(
        "%s -> %s" % (size, picks[size] or "wait for a free healthy GPU") for size in ("large", "small")))
    return "ok" if not down else "down: " + ", ".join(down)

# ---------------------------------------------------------------- check 2: stalled fix-up hand-offs
FIX_HANDOFF_MIN = 20                                   # a review FAIL with no fix commit and no driver activity for this long
REVIEW_FAIL_HEAD = "Review → In Progress\n\nReview: FAIL"   # the driver's review-FAIL journal comment (st_review)
STALL_MARK = "<!-- watchdog-fix-handoff-stalled -->"   # one flag per FAIL: a later FAIL can be flagged again
QUIET_HEADS = ("Status: no progress",)                 # driver heartbeats are not activity

def _ts(s):
    return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00"))

def fix_handoff_stalled(comments, head_at, at, minutes=FIX_HANDOFF_MIN):
    """Pure rule for check 2. `comments` is the issue journal ([{"body", "created_at"}], any order), `head_at` the
    newest commit time on the PR (or None). Returns the time of the latest review FAIL when its fix-up hand-off has
    stalled: the FAIL is at least `minutes` old, no commit reached the PR after it, no comment after it other than
    driver heartbeats shows activity, and the watchdog has not flagged it yet. Otherwise None."""
    cs = sorted(({"body": c.get("body") or "", "at": _ts(c["created_at"])} for c in comments or [] if c.get("created_at")),
                key=lambda c: c["at"])
    fails = [c for c in cs if c["body"].startswith(REVIEW_FAIL_HEAD)]
    if not fails: return None
    fail_at = fails[-1]["at"]
    if (at - fail_at).total_seconds() < minutes * 60: return None
    if head_at is not None and _ts(head_at) > fail_at: return None
    for c in cs:
        if c["at"] <= fail_at: continue
        if STALL_MARK in c["body"]: return None           # already flagged
        if not c["body"].startswith(QUIET_HEADS): return None   # the driver (or someone) acted after the FAIL
    return fail_at

def _json_lines(text):
    out = []
    for line in (text or "").splitlines():
        line = line.strip()
        if line: out.append(json.loads(line))
    return out

def driver_alive(states, repo, issue, alive=None):
    """True when any driver run for (repo, issue) has a live pid: a running driver (mid-fix, waiting on CI or a review
    GPU) is never reported as a hand-off that did not run, however stale its progress stamp is."""
    alive = alive or L.pid_alive
    return any(s.get("repo") == repo and s.get("issue") == int(issue) and alive(s.get("pid")) for _, s in states or [])

def _stalled_pr(repo, pr, states, gh, clock):
    """(issue, fail_at) when this open PR is a driver PR whose fix-up hand-off stalled, else None."""
    if L.DRIVER_MARK not in (pr.get("body") or ""): return None
    issues = [i.get("number") for i in pr.get("closingIssuesReferences") or []
              if i.get("number") and (i.get("repository") or {}).get("name", repo) == repo]   # same-repo issues only
    if not issues or excluded(repo, issues[0]) or excluded(repo, pr["number"]): return None
    issue = issues[0]
    if driver_alive(states, repo, issue): return None
    dates = [c.get("committedDate") for c in pr.get("commits") or [] if c.get("committedDate")]
    head_at = max(dates, key=_ts) if dates else None
    c = gh(["api", "--paginate", f"repos/{L.ORG}/{repo}/issues/{issue}/comments?per_page=100",
            "--jq", ".[] | {body, created_at}"])
    if c.returncode != 0: raise RuntimeError(c.stdout or "gh api comments failed")
    fail_at = fix_handoff_stalled(_json_lines(c.stdout), head_at, clock())
    return (issue, fail_at) if fail_at is not None else None

@register
def fix_handoff_check(repos=REPOS, gh=None, health=None, clock=None, log=None):
    """Check 2: a driver PR whose review FAILed but whose fix-up hand-off never ran (cmdemo1-dashboard#1311: the FAIL
    went to the issue, the Pi fix never started, the PR sat idle). For each open PR carrying item_loop's DRIVER_MARK,
    read its closing issue's journal; when fix_handoff_stalled() says the latest FAIL is FIX_HANDOFF_MIN+ min old with
    no fix commit, no activity and no live driver for the item, post one flagged comment on the issue and on the PR (post_comment's guards apply:
    excluded items and live, progressing drivers are left alone). Read-only otherwise: it never relaunches anything."""
    clock = clock or L.now; log = log or print; gh = gh or gh_subprocess
    states = L.all_states(); flagged = []
    for repo in repos:
        try:
            r = gh(["pr", "list", "-R", f"{L.ORG}/{repo}", "--state", "open", "--limit", "100",
                    "--json", "number,body,closingIssuesReferences,commits"])
            if r.returncode != 0: raise RuntimeError(r.stdout or "gh pr list failed")
            prs = json.loads(r.stdout or "[]")
        except Exception as e:
            log("watchdog fix-handoff: PR list for %s failed: %s" % (repo, scrub(str(e)))); continue
        for pr in prs:
            try:
                hit = _stalled_pr(repo, pr, states, gh, clock)
            except Exception as e:   # one bad response never hides the other PRs
                log("watchdog fix-handoff: %s PR #%s skipped: %s" % (repo, pr.get("number"), scrub(str(e)))); continue
            if not hit: continue
            issue, fail_at = hit
            mins = int((clock() - fail_at).total_seconds() // 60)
            body = (f"{STALL_MARK}\nFix-up hand-off stalled: the review FAILed {mins} min ago "
                    f"({fail_at.strftime('%Y-%m-%d %H:%M UTC')}) and no fix commit reached PR #{pr['number']} since, with no "
                    "driver activity and no live driver. The factory bot should resume the driver or take the fix over; "
                    "nothing merges until a review passes.")
            if post_comment(repo, issue, body, states, gh=gh, clock=clock, log=log):
                # the PR post rides on the issue post's guards (the item's state is keyed by issue, not PR number)
                post_comment(repo, pr["number"], body, states, gh=gh, clock=clock, log=log)
                log("watchdog fix-handoff: flagged %s#%s (PR #%s)" % (repo, issue, pr["number"]))
                flagged.append(f"{repo}#{issue}")
    return "ok" if not flagged else "stalled: " + ", ".join(flagged)

# ---------------------------------------------------------------- CLI: run every check once (the same entry the driver-exit hook uses)
def main(argv=None):
    ap = argparse.ArgumentParser(prog="watchdog.py",
        description="Shared factory watchdog checks (scope: %s)." % ", ".join(REPOS))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="run every registered check once and print the result list as JSON")
    a = ap.parse_args(argv)
    if a.cmd == "run":
        print(json.dumps(run_checks(), indent=1))
    return 0

if __name__ == "__main__":
    sys.exit(main())
