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
