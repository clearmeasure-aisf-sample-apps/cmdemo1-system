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

Check 3 (own_green_prs_check, run via run_checks(own_prs=True) / the `run-own-prs` CLI / the driver-exit hook's
full set): an own (cm-ai-ops-bot) PR that is green, mergeable and unmerged gets the independent Pi review on a
healthy GPU other than the author's, and is squash-merged with --match-head-commit (item_loop.merge_args: never
--delete-branch) only on PASS. A `Not merging until Jeffrey confirms` comment holds a PR unconditionally; an
unaddressed `Review: FAIL` or `Blocker:` (no commit and no Review: PASS after it) holds it too; an item with a
live driver is left to the driver.

Check 1: GPU health for pro5000, pro6000 (RTX PRO 6000), obs (RTX 5070 Ti) and ts3 (RTX 5060 Ti) via the gpu.py models list
(read-only: one GET /models per GPU; it never starts, stops or warms a model server). A down GPU is
reported in the log and in run_checks' result, and GPU selection routes to the healthy GPUs.

item_loop imports watchdog only lazily (inside watchdog_exit), so importing item_loop here cannot be circular.
"""
import argparse, datetime as dt, json, os, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gpu as G
import item_loop as L
from scrub import scrub   # the shared rule set directly (leaf import, #931): watchdog -> scrub, never through the driver module

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

def state_for(states, repo, issue):
    """The item's driver state ({} when the item has no recorded run): the one (repo, issue) scan every check
    uses for the driver-alive guard and the author-GPU rule."""
    return next((s for _, s in states or [] if s.get("repo") == repo and s.get("issue") == int(issue)), {})

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
    st = state_for(states, repo, issue)
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

def run_checks(repos=REPOS, gh=None, health=None, clock=None, log=None, own_prs=False):
    """Run every registered check exactly once. Each check gets (repos, gh, health, clock, log); a check's
    failure is caught, scrubbed and logged, and appears in the result list as 'error: <message>'.
    With own_prs=True, check 3 (own_green_prs_check) runs after the registered checks -- the full set the
    driver-exit hook and the 30-min watchdog routine use (the `run-own-prs` CLI entry). Returns [(check name,
    result), ...]; the caller's result is never changed."""
    log = log or print
    gh = gh or gh_subprocess
    health = health or L.gpu_health   # the driver's shared GpuHealthCache probe (cmdemo1-system#868), so an exit hook never fires three fresh GETs
    clock = clock or L.now
    results = []
    checks = list(CHECKS) + ([own_green_prs_check] if own_prs else [])
    for c in checks:
        try:
            results.append((c.__name__, c(repos=repos, gh=gh, health=health, clock=clock, log=log)))
        except Exception as e:
            msg = scrub(str(e))
            log("watchdog check %s failed: %s" % (c.__name__, msg))
            results.append((c.__name__, "error: " + msg))
    return results

@register
def gpu_health_check(repos=REPOS, gh=None, health=None, clock=None, log=None):
    """Check 1: GPU health for pro5000, pro6000 (RTX PRO 6000), obs (RTX 5070 Ti) and ts3 (RTX 5060 Ti) via the gpu.py models list
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

# ---------------------------------------------------------------- check 4: dead-driver idle items (pure rule)
IDLE_MIN = 90

def idle_decision(state, at, up, busy, alive=None, minutes=IDLE_MIN, size="small"):
    """Pure decision rule for check 4: a dead driver whose item has been idle for more than `minutes` minutes
    is restarted (resume on its recorded GPU), reassigned to a free healthy GPU, or waits. Never calls gh, the
    network or the filesystem. Returns (action, gpu):
    - ("leave", None)  — empty state, excluded item, status not running/error, live driver, or not yet idle
    - ("resume", gpu)  — dead driver, idle > minutes, recorded GPU is up and not busy
    - ("reassign", g)  — dead driver, idle > minutes, recorded GPU down or busy, another free healthy GPU found
    - ("wait", None)   — dead driver, idle > minutes, no free healthy GPU available
    `alive` defaults to L.pid_alive. A live driver is never restarted or reassigned, even if stalled."""
    alive = alive or L.pid_alive
    if not state:
        return ("leave", None)
    if excluded(state.get("repo"), state.get("issue")):
        return ("leave", None)
    if state.get("status") not in ("running", "error"):
        return ("leave", None)
    if alive(state.get("pid")):
        return ("leave", None)
    stamps = [state[k] for k in ("progress_at", "start", "last_comment_at") if state.get(k)]
    if not stamps:
        return ("leave", None)
    last = max(_ts(s) for s in stamps)
    if (at - last).total_seconds() <= minutes * 60:
        return ("leave", None)
    g = state.get("gpu")
    if g in up and g not in busy:
        return ("resume", g)
    g = G.pick_gpu(size, up, busy)
    return ("reassign", g) if g is not None else ("wait", None)

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

PR_LIST_FIELDS = "number,body,closingIssuesReferences,headRefOid"

def issue_comments(repo, n, gh):
    """One item's journal, newest included: the `gh api --paginate` issue/PR comment list as [{body, created_at}]"""
    r = gh(["api", "--paginate", f"repos/{L.ORG}/{repo}/issues/{n}/comments?per_page=100",
            "--jq", ".[] | {body, created_at}"])
    if r.returncode != 0: raise RuntimeError(r.stdout or "gh api comments failed")
    return _json_lines(r.stdout)

def head_commit_at(repo, pr, gh):
    """Committer time of the PR's head commit (one REST call, only for a PR that already has a stale FAIL)."""
    r = gh(["api", f"repos/{L.ORG}/{repo}/commits/{pr['headRefOid']}", "--jq", ".commit.committer.date"])
    if r.returncode != 0 or not (r.stdout or "").strip(): raise RuntimeError(r.stdout or "head commit lookup failed")
    return r.stdout.strip()

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
    comments = issue_comments(repo, issue, gh)
    if fix_handoff_stalled(comments, None, clock()) is None: return None   # cheap: no stale FAIL, no commit lookup
    fail_at = fix_handoff_stalled(comments, head_commit_at(repo, pr, gh), clock())
    return (issue, fail_at) if fail_at is not None else None

@register
def fix_handoff_check(repos=REPOS, gh=None, health=None, clock=None, log=None):
    """Check 2: a driver PR whose review FAILed but whose fix-up hand-off never ran (cmdemo1-dashboard#1311: the FAIL
    went to the issue, the Pi fix never started, the PR sat idle). For each open PR carrying item_loop's DRIVER_MARK,
    read its closing issue's journal; when fix_handoff_stalled() says the latest FAIL is FIX_HANDOFF_MIN+ min old with
    no fix commit, no activity and no live driver for the item, post one flagged comment on the issue and on the PR (post_comment's guards apply:
    excluded items and live, progressing drivers are left alone). Read-only otherwise: it never relaunches anything."""
    clock = clock or L.now; log = log or print; gh = gh or gh_subprocess
    states = L.all_states(); flagged = []; failed = []
    for repo in repos:
        try:
            r = gh(["pr", "list", "-R", f"{L.ORG}/{repo}", "--state", "open", "--limit", "100",
                    "--json", PR_LIST_FIELDS])   # no `commits`: GraphQL rejects 100 PRs x commits (500k-node limit)
            if r.returncode != 0: raise RuntimeError(r.stdout or "gh pr list failed")
            prs = json.loads(r.stdout or "[]")
        except Exception as e:
            log("watchdog fix-handoff: PR list for %s failed: %s" % (repo, scrub(str(e)))); failed.append(repo); continue
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
    out = "ok" if not flagged else "stalled: " + ", ".join(flagged)
    return out + ("; list failed: " + ", ".join(failed) if failed else "")

# ---------------------------------------------------------------- check 3: own green, mergeable, unmerged PRs
OWN_PR_LIST_FIELDS = "number,author,headRefOid,mergeable,closingIssuesReferences"
JEFFREY_HOLD = "Not merging until Jeffrey confirms"   # a human hold: the watchdog never posts, lifts or merges past one
HOLD_FAIL = "Review: FAIL"
HOLD_BLOCKER = "Blocker:"
PASS_MARK = "Review: PASS"
REVIEW_DIFF_LIMIT = 24000   # the diff copy in the review prompt (any GPU may take it: size for the smallest)

def green_pr_hold(comments, head_at):
    """Check 3's pure rule: the hold on a green, mergeable, unmerged bot PR. `comments` is the PR's journal
    (the PR's own comments plus the closing issue's, [{"body", "created_at"}], any order); `head_at` the newest
    commit time on the PR head (or None). Returns ("jeffrey" | "fail" | "blocker", comment) -- the comment that
    holds the merge -- or None when the PR may be reviewed and merged:
    - `Not merging until Jeffrey confirms` holds unconditionally (only Jeffrey lifts it, and no commit or PASS
      comment clears it);
    - a `Review: FAIL` or `Blocker:` holds while unaddressed: no commit has reached the PR head after it and no
      `Review: PASS` comment came after it."""
    cs = sorted(({"body": c.get("body") or "", "at": _ts(c["created_at"])} for c in comments or [] if c.get("created_at")),
                key=lambda c: c["at"])
    for c in cs:
        if JEFFREY_HOLD in c["body"]: return ("jeffrey", c)
    hold = None
    for c in cs:
        if HOLD_FAIL in c["body"] or HOLD_BLOCKER in c["body"]:
            if hold is None or c["at"] > hold["at"]: hold = c
    if hold is None: return None
    for c in cs:
        if c is not hold and c["at"] > hold["at"] and PASS_MARK in c["body"]: return None
    if head_at is not None and _ts(head_at) > hold["at"]: return None   # a commit after the hold: addressed
    return ("fail" if HOLD_FAIL in hold["body"] else "blocker", hold)

def author_gpus(states, repo, issue):
    """The GPUs a watchdog review must avoid for this item: the driver's recorded GPU plus every GPU that ran an
    authoring call (item_loop's author-gpus rule). [] when the item has no recorded state (author unknown: any
    healthy GPU is offered, and the pick is logged)."""
    st = state_for(states, repo, issue)
    gs = [st.get("gpu")] + list(st.get("author_gpus") or [])
    return [g for g in dict.fromkeys(gs) if g in G.GPUS]

def pi_review(repo, pr, issue, gpu, gh=None, runner=None):
    """Check 3's default review: one Pi task through run-task on `gpu` (the caller picked a non-author GPU). The
    prompt carries the issue, the PR body and the scrubbed diff; Pi changes no files, writes one bullet per
    problem to the findings file and ends its reply with PASS or FAIL. Returns the bare (result, findings) pair:
    the check feeds it through item_loop.review_verdict, so a result that is not PASS/FAIL (timeout, exit N) is
    an INFRA failure, never a code FAIL."""
    gh = gh or gh_subprocess
    runner = runner or (lambda cmd, **kw: subprocess.run(cmd, text=True, stdout=subprocess.PIPE,
                                                         stderr=subprocess.STDOUT, **kw))
    full = f"{L.ORG}/{repo}"
    pr_body = scrub((gh(["pr", "view", str(pr), "-R", full, "-q", ".body"]).stdout or "")[:8000])
    issue_body = scrub((gh(["issue", "view", str(issue), "-R", full, "-q", ".body"]).stdout or "")[:8000]) \
        if issue is not None else ""
    diff = scrub((gh(["pr", "diff", str(pr), "-R", full]).stdout or ""))[:REVIEW_DIFF_LIMIT]
    with tempfile.TemporaryDirectory(prefix="wd-review-") as d:
        out = os.path.join(d, "independent-review.md")
        prompt = (f"Independent code review of {full} PR #{pr} (watchdog check 3). You did not write this code. "
                  "Change NO files.\n\n"
                  + (f"The issue:\n{issue_body}\n\n" if issue_body else "")
                  + f"The PR body:\n{pr_body}\n\n"
                  + f"Diff against the default branch:\n```diff\n{diff}\n```\n\n"
                  "Check: every criterion is met by the code and its tests; tests are real (none skipped, deleted or "
                  "weakened); the repository's AGENTS.md / CLAUDE.md rules hold; the code is easy to read (names, small "
                  "methods, no duplication); no secret, credential or production-setup change. Write one bullet per "
                  f"problem to {out} (or `- No findings.`). End your reply with PASS when there is no blocking problem, "
                  "otherwise FAIL.")
        pf = os.path.join(d, "prompt.md")
        open(pf, "w").write(scrub(prompt))
        r = runner([os.path.join(L.HERE, "run-task"), "--run-dir", d, "--cwd", d,
                    "--task", f"watchdog-review-{repo}-{pr}", "--prompt-file", pf, "--gpu", gpu,
                    "--timeout", str(G.PI_TASK_TIMEOUT_S)], timeout=G.PI_TASK_TIMEOUT_S + 600)
        rec = {}
        for line in (r.stdout or "").splitlines():
            try: rec = json.loads(line)
            except ValueError: continue
        findings = scrub(open(out).read()) if os.path.exists(out) else None
        return rec.get("result"), findings   # the bare pair: the caller maps it through L.review_verdict

def _own_pr(repo, pr, states, gh, up, busy, review, clock, log):
    """Check 3 for one open PR. Returns 'merged', 'review-fail', 'wait' or None (not an own bot PR / not green /
    held / left to the driver): a comment lands only on 'merged' and 'review-fail', through post_comment's guards
    (excluded items and live, progressing drivers are never commented on)."""
    if (pr.get("author") or {}).get("login") != L.BOT: return None
    if pr.get("mergeable") != "MERGEABLE": return None
    issues = [i.get("number") for i in pr.get("closingIssuesReferences") or []
              if i.get("number") and (i.get("repository") or {}).get("name", repo) == repo]
    issue = issues[0] if issues else None
    if excluded(repo, pr["number"]) or (issue is not None and excluded(repo, issue)): return None
    if issue is not None and driver_alive(states, repo, issue): return None   # a live driver owns the PR (check 2's rule)
    r = gh(["pr", "checks", str(pr["number"]), "-R", f"{L.ORG}/{repo}", "--json", "name,bucket"])
    if r.returncode != 0: raise RuntimeError(r.stdout or "gh pr checks failed")
    try: cs = json.loads(r.stdout or "[]")
    except ValueError: raise RuntimeError("gh pr checks returned no json")
    if not L.MergeGate(cs, L.REQUIRED.get(repo)).green(): return None
    comments = issue_comments(repo, pr["number"], gh)
    if issue is not None: comments += issue_comments(repo, issue, gh)
    hold = green_pr_hold(comments, None)
    if hold is not None and hold[0] != "jeffrey":   # only FAIL / Blocker holds can be addressed by a commit
        hold = green_pr_hold(comments, head_commit_at(repo, pr, gh))
    if hold is not None:
        log("watchdog own-prs: %s PR #%s held (%s): %s" % (repo, pr["number"], hold[0], scrub(hold[1]["body"][:200])))
        return None
    authors = author_gpus(states, repo, issue) if issue is not None else []
    rv = [g for g in G.reviewer_gpus(authors, up) if g not in busy]
    if not rv:
        log("watchdog own-prs: %s PR #%s waits: no healthy non-author GPU free (authors %s)"
            % (repo, pr["number"], ", ".join(authors) or "unknown"))
        return "wait"
    v = review(repo, pr["number"], issue, rv[0])
    verdict = v if isinstance(v, L.ReviewVerdict) else L.review_verdict(*v)   # a bare (result, findings) pair takes the INFRA rule
    label = G.GPUS[rv[0]]["label"]
    if verdict.is_infra:
        log("watchdog own-prs: %s PR #%s review infra failure on %s: %s"
            % (repo, pr["number"], rv[0], scrub(verdict.findings)[:300]))
        return "wait"   # nothing about the code: no action, no comment, the next pass retries
    if verdict.is_fail:
        body = (f"Review \u2192 In Progress\n\nReview: FAIL (watchdog independent review on the {label}).\n\n"
                f"{scrub(verdict.findings)[:3000]}\n\nThe watchdog will not merge this PR until the findings are "
                "addressed with a new commit.")
        if post_comment(repo, issue if issue is not None else pr["number"], body, states, gh=gh, clock=clock, log=log):
            if issue is not None:   # the FAIL goes on the PR too, so the PR never looks clean (the driver's rule)
                post_comment(repo, pr["number"], body, states, gh=gh, clock=clock, log=log)
            log("watchdog own-prs: %s PR #%s review FAIL on %s" % (repo, pr["number"], rv[0]))
        return "review-fail"
    m = gh(L.merge_args(f"{L.ORG}/{repo}", pr["number"], pr["headRefOid"]))   # squash, --match-head-commit, never --delete-branch
    if m.returncode != 0:
        log("watchdog own-prs: merge of %s PR #%s failed: %s" % (repo, pr["number"], scrub(m.stdout or "")))
        return "wait"   # the next pass retries; a failed merge is not an action that gets a comment
    body = (f"Review \u2192 Merged\n\nReview: PASS (watchdog independent review on the {label}). Squash-merged PR "
            f"#{pr['number']} with --match-head-commit {str(pr['headRefOid'])[:8]} (the branch stays for the record).")
    if issue is not None:
        post_comment(repo, issue, body, states, gh=gh, clock=clock, log=log)
    post_comment(repo, pr["number"], body, states, gh=gh, clock=clock, log=log)
    log("watchdog own-prs: merged %s PR #%s after an independent review on %s" % (repo, pr["number"], rv[0]))
    return "merged"

def own_green_prs_check(repos=REPOS, gh=None, health=None, clock=None, log=None, review=None):
    """Check 3: an own (cm-ai-ops-bot) PR that is green, mergeable and unmerged gets the independent Pi review on
    a healthy GPU other than the author's, and is squash-merged with --match-head-commit (item_loop.merge_args:
    never --delete-branch) only on PASS. Every hard rule holds: excluded items (NEVER_MERGE -- workorders PR 1918 --
    and HANDS_OFF, plus #652 / #1672) are never merged or commented on; a `Not merging until Jeffrey confirms`
    comment, or an unaddressed `Review: FAIL` / `Blocker:` in the PR's journal, skips the PR; items with a live
    driver are left to the driver (check 2's rule: a running driver is never raced, however stale its progress); a
    comment lands only when the check acted. One bad PR never hides the others; the check never raises."""
    clock = clock or L.now; log = log or print; gh = gh or gh_subprocess
    review = review or pi_review
    up = G.available(health())
    states = L.all_states()
    busy = L.busy_gpus(states, alive=L.pid_alive)
    acted, waited, failed = [], [], []
    for repo in repos:
        try:
            r = gh(["pr", "list", "-R", f"{L.ORG}/{repo}", "--state", "open", "--limit", "100",
                    "--json", OWN_PR_LIST_FIELDS])
            if r.returncode != 0: raise RuntimeError(r.stdout or "gh pr list failed")
            prs = json.loads(r.stdout or "[]")
        except Exception as e:
            log("watchdog own-prs: PR list for %s failed: %s" % (repo, scrub(str(e)))); failed.append(repo); continue
        for pr in prs:
            try:
                a = _own_pr(repo, pr, states, gh, up, busy, review, clock, log)
            except Exception as e:
                log("watchdog own-prs: %s PR #%s skipped: %s" % (repo, pr.get("number"), scrub(str(e)))); continue
            if a in ("merged", "review-fail"): acted.append(f"{repo} PR #{pr['number']} ({a})")
            elif a == "wait": waited.append(f"{repo} PR #{pr['number']}")
    parts = (["acted: " + ", ".join(acted)] if acted else []) + (["waiting: " + ", ".join(waited)] if waited else [])
    out = "ok" if not parts else "; ".join(parts)
    return out + ("; list failed: " + ", ".join(failed) if failed else "")

# ---------------------------------------------------------------- CLI: run every check once (the same entry the driver-exit hook uses)
def main(argv=None):
    ap = argparse.ArgumentParser(prog="watchdog.py",
        description="Shared factory watchdog checks (scope: %s)." % ", ".join(REPOS))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="run every registered check once and print the result list as JSON")
    sub.add_parser("run-own-prs", help="run the registered checks plus check 3 (own green PRs) once, as the driver-exit hook does")
    a = ap.parse_args(argv)
    if a.cmd == "run":
        print(json.dumps(run_checks(), indent=1))
    if a.cmd == "run-own-prs":
        print(json.dumps(run_checks(own_prs=True), indent=1))
    return 0

if __name__ == "__main__":
    sys.exit(main())
