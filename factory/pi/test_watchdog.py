"""Unit tests of the factory watchdog: the shared guards, the comment rules, check 1 (GPU health) and the
shared entry (no network, no Pi).

Run: python3 -m unittest factory/pi/test_watchdog.py
"""
import contextlib, datetime as dt, io, json, os, subprocess, sys, tempfile, unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu as G
import watchdog as W
import item_loop as L
from test_item_loop import fake_modules   # the shared save/swap/restore helper, kept with the sibling test file's helpers (#940)

T0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)

def clock_swaps(now, sleeps):
    """The (L.now, W.time.sleep) swaps for fake_modules in the comment-gap tests: the clock is frozen at now[0] and a
    sleep(secs) records secs in sleeps and moves now[0] on, so COMMENT_GAP_S is tested without waiting a minute."""
    return {(L, "now"): lambda: now[0],
            (W.time, "sleep"): lambda secs: (sleeps.append(secs), now.__setitem__(0, now[0] + dt.timedelta(seconds=secs)))[1]}

class Guards(unittest.TestCase):
    """The shared hard-rule guards every watchdog check must obey."""

    def test_excluded_reuses_item_loop_rules_plus_652_and_1672(self):
        self.assertEqual(W.EXCLUDED, L.NEVER_MERGE | L.HANDS_OFF | {("cmdemo1-system", 652), ("cmdemo1-workorders", 1672)})
        for repo, issue in W.EXCLUDED:
            self.assertTrue(W.excluded(repo, issue))
            self.assertTrue(W.excluded(repo, str(issue)))   # issue numbers may arrive as strings
        for repo, issue in (("cmdemo1-workorders", 1), ("cmdemo1-dashboard", 1), ("cmdemo1-system", 1)):
            self.assertFalse(W.excluded(repo, issue))

    def test_wip_cap_reuses_item_loop(self):
        self.assertEqual(W.wip_limit("cmdemo1-workorders"), L.wip_limit("cmdemo1-workorders"))
        self.assertEqual(W.wip_limit("cmdemo1-system"), 3)
        self.assertEqual(W.wip_limit("cmdemo1-dashboard"), 8)

    def test_scrub_reuses_item_loop(self):
        url = "https://fake-pro5000.trycloudflare.com/v1"
        out = W.scrub("the url is " + url)
        self.assertIn("[redacted]", out)
        self.assertNotIn("trycloudflare", out)

    def test_skips_alive_progressing_items(self):
        at = L.now()
        s = {"repo": "cmdemo1-workorders", "issue": 7, "stage": "implement", "pid": os.getpid(),
             "progress_at": (at - dt.timedelta(seconds=60)).isoformat()}
        # a live driver that is still progressing is skipped: its item is left to the driver
        self.assertTrue(W.alive_progressing(s, at))
        self.assertFalse(W.alive_progressing(dict(s, progress_at=(at - dt.timedelta(minutes=60)).isoformat()), at))
        self.assertFalse(W.alive_progressing(dict(s, pid=2 ** 22), at))   # a dead pid is not skipped
        # a live, progressing item holds its WIP slot: a check must not open new work there
        self.assertTrue(W.wip_full([(f"r{i}", dict(s)) for i in range(3)], "cmdemo1-workorders", alive=L.pid_alive))
        self.assertFalse(W.wip_full([(f"r{i}", dict(s)) for i in range(2)], "cmdemo1-workorders", alive=L.pid_alive))

class Comments(unittest.TestCase):
    def setUp(self):
        W._last_comment.clear()      # the watchdog's own comment tracking is per process: start each test clean

    def test_no_action_posts_no_comment(self):
        def gh(args): raise AssertionError("a no-op check must not call gh")
        self.assertIsNone(W.post_comment("cmdemo1-workorders", 7, "", states=[], gh=gh))
        self.assertIsNone(W.post_comment("cmdemo1-system", 652, "hi", states=[], gh=gh))   # excluded item: left alone
        self.assertIsNone(W.post_comment("cmdemo1-workorders", 1672, "hi", states=[], gh=gh))

    def test_alive_progressing_item_is_left_alone(self):
        def gh(args): raise AssertionError("must not call gh")
        at = L.now()
        s = {"repo": "cmdemo1-workorders", "issue": 7, "pid": os.getpid(),
             "progress_at": (at - dt.timedelta(seconds=10)).isoformat()}
        self.assertIsNone(W.post_comment("cmdemo1-workorders", 7, "acted", [("x", s)], gh=gh))

    def test_comment_body_is_scrubbed(self):
        url = "https://fake-pro5000.trycloudflare.com/v1"
        sent = []
        def gh(args):
            with open(args[args.index("--body-file") + 1]) as f: sent.append(f.read())
            return subprocess.CompletedProcess(args, 0, "", "")
        out = W.post_comment("cmdemo1-workorders", 7, "done with " + url, states=[], gh=gh)
        self.assertEqual(sent, [out])
        self.assertNotIn(url, out)
        self.assertNotIn("trycloudflare", out)
        self.assertIn("[redacted]", out)

    def test_actions_are_spaced_at_least_61_s(self):
        sleeps, calls = [], []
        now = [T0]
        def gh(args):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, "", "")
        with fake_modules(clock_swaps(now, sleeps)):
            W.post_comment("cmdemo1-workorders", 7, "action A", states=[], gh=gh)
            st = {"repo": "cmdemo1-workorders", "issue": 7, "last_comment_at": T0.isoformat()}   # action A commented at T0
            now[0] = T0 + dt.timedelta(seconds=10)                                           # the check acts again ten seconds later
            W.post_comment("cmdemo1-workorders", 7, "action B", [("x", st)], gh=gh)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps[-1], 51.0)                    # sleeps so action B lands 61 s after action A
        self.assertGreaterEqual((now[0] - T0).total_seconds(), W.COMMENT_GAP_S)

    def test_two_watchdog_actions_are_spaced_without_any_state(self):
        """The watchdog spaces its own comments: it remembers what it posted, so it never needs the item's state."""
        sleeps, calls = [], []
        now = [T0]
        def gh(args):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, "", "")
        with fake_modules(clock_swaps(now, sleeps)):
            self.assertIsNotNone(W.post_comment("cmdemo1-workorders", 7, "action A", states=[], gh=gh))
            self.assertIsNotNone(W.post_comment("cmdemo1-workorders", 7, "action B", states=[], gh=gh))
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [W.COMMENT_GAP_S])           # the second action waited the whole gap on its own
        self.assertGreaterEqual((now[0] - T0).total_seconds(), W.COMMENT_GAP_S)

    def test_failed_comment_is_logged_and_nothing_is_recorded(self):
        logs = []
        def gh(args): return subprocess.CompletedProcess(args, 1, "gh: no such issue", "")
        self.assertIsNone(W.post_comment("cmdemo1-workorders", 7, "acted", states=[], gh=gh, log=logs.append))
        self.assertEqual(W._last_comment, {})
        self.assertTrue(any("watchdog comment on cmdemo1-workorders#7 failed: gh: no such issue" in s for s in logs))

HEAD_SHA = "a" * 40

def no_prs(args):   # gh stub for run_checks: no open PRs anywhere (check 2 is a no-op) and no runs on main's head (check 4: unknown)
    if args[:1] == ["api"] and args[1].endswith("/commits/main"):
        return subprocess.CompletedProcess(args, 0, HEAD_SHA + "\n", "")
    return subprocess.CompletedProcess(args, 0, "[]", "")

class GpuHealthCheck(unittest.TestCase):
    """Check 1: a down GPU is reported in run_checks' result and log and pick_gpu / gpu_for_item never
    select it; all GPUs healthy is a no-op with no comment."""

    def _run(self, health, log):
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):   # no real drivers on disk: all_states() sees no live items
            return W.run_checks(health=health, log=log, gh=no_prs)

    def test_down_gpu_reported_and_selection_routes_to_the_others(self):
        h = {g: ("HEALTHY", "serves a loaded model (Pi asks for `auto`)") for g in G.GPUS}
        h["ts3"] = ("UNREACHABLE", "no answer (unknown host or timeout)")
        logs = []
        r = self._run(lambda: dict(h), logs.append)
        self.assertEqual(r, [("gpu_health_check", "down: ts3"), ("fix_handoff_check", "ok"), ("red_main_check", "ok")])   # the down GPU is in the result; the healthy ones carry on
        self.assertTrue(any("watchdog GPU ts3 (RTX 5060 Ti): UNREACHABLE - no answer (unknown host or timeout)" in s
                            for s in logs))
        up = G.available(h)
        busy = L.busy_gpus([], alive=L.pid_alive)
        for size in ("large", "small"):
            self.assertIn(G.pick_gpu(size, up, busy), ("pro5000", "obs", None))
        self.assertIsNone(L.gpu_for_item("ts3", "small", up, busy)[0])   # a recorded down GPU is waited on, never taken
        self.assertIn(L.gpu_for_item(None, "small", up, busy)[0], ("pro5000", "obs", None))

    def test_all_healthy_is_a_no_op_with_no_comment(self):
        def no_comment(*a, **kw):
            raise AssertionError("a no-op check must not comment")
        with fake_modules({(W, "post_comment"): no_comment}):
            r = self._run(lambda: {g: ("HEALTHY", "serves a loaded model (Pi asks for `auto`)") for g in G.GPUS},
                          lambda s: None)
        self.assertEqual(r, [("gpu_health_check", "ok"), ("fix_handoff_check", "ok"), ("red_main_check", "ok")])

    def test_check_failure_is_caught_logged_and_in_the_result(self):
        logs = []
        def boom(repos, gh, health, clock, log):
            raise RuntimeError("token ghp_" + "a" * 30 + " leaked")
        with fake_modules({(W, "CHECKS"): [boom]}):
            r = W.run_checks(log=logs.append)
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0][0], "boom")
        self.assertTrue(r[0][1].startswith("error: "))
        self.assertTrue(any("watchdog check boom failed" in s and "[redacted]" in s for s in logs))
        self.assertNotIn("ghp_", r[0][1])
        self.assertNotIn("ghp_", "".join(logs))

class GpuHealthDefault(unittest.TestCase):
    """Check 1's health injection (cmdemo1-system#868): run_checks with no health= uses the driver's shared
    GpuHealthCache, so a fresh cached probe means no network; an injected cache is used as given."""

    def test_run_checks_default_health_is_faked_with_a_fresh_shared_cache(self):
        fake = {g: ("HEALTHY", "serves a loaded model (Pi asks for `auto`)") for g in G.GPUS}
        def no_probe(**kw):
            raise AssertionError("no network: the shared cache is fresh, nothing may probe")
        old = (L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h)
        L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h = (lambda: 1e9, no_probe, 1e9, fake)
        try:
            with tempfile.TemporaryDirectory() as home:
                old_home = L.HOME; L.HOME = home
                try:
                    r = W.run_checks(gh=no_prs, log=lambda s: None)   # no health=: the default is the shared cache
                finally:
                    L.HOME = old_home
        finally:
            L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h = old
        self.assertEqual(r, [("gpu_health_check", "ok"), ("fix_handoff_check", "ok"), ("red_main_check", "ok")])

    def test_run_checks_uses_an_injected_health_cache(self):
        calls = []
        def health():
            calls.append(1)
            return {g: ("UNREACHABLE", "down") for g in G.GPUS}
        cache = L.GpuHealthCache(now=lambda: 1e9, health=health)
        with tempfile.TemporaryDirectory() as home:
            old_home = L.HOME; L.HOME = home
            try:
                r = W.run_checks(health=cache, gh=no_prs, log=lambda s: None)
            finally:
                L.HOME = old_home
        self.assertEqual(r, [("gpu_health_check", "no healthy GPU"), ("fix_handoff_check", "ok"), ("red_main_check", "ok")])
        self.assertEqual(calls, [1], "the injected cache probed exactly once")

FAIL = "Review → In Progress\n\nReview: FAIL (independent review on the RTX 5070 Ti).\n\n- a finding\n\nSending the findings to Pi."

def c(body, minutes_after_t0):
    return {"body": body, "created_at": (T0 + dt.timedelta(minutes=minutes_after_t0)).isoformat().replace("+00:00", "Z")}

class FixHandoffRule(unittest.TestCase):
    """Check 2's pure rule: a review FAIL whose fix-up hand-off produced no commit and no activity in 20+ min."""
    AT = T0 + dt.timedelta(minutes=30)

    def test_old_fail_with_no_commit_and_no_activity_is_stalled(self):
        self.assertEqual(W.fix_handoff_stalled([c("In Progress → Review", 0), c(FAIL, 5)], None, self.AT),
                         T0 + dt.timedelta(minutes=5))

    def test_heartbeats_are_not_activity(self):
        self.assertIsNotNone(W.fix_handoff_stalled([c(FAIL, 5), c("Status: no progress for 30+ min.", 25)], None, self.AT))

    def test_young_fail_is_not_stalled(self):
        self.assertIsNone(W.fix_handoff_stalled([c(FAIL, 15)], None, self.AT))   # 15 min < 20

    def test_fix_commit_after_the_fail_clears_it(self):
        head = (T0 + dt.timedelta(minutes=12)).isoformat()
        self.assertIsNone(W.fix_handoff_stalled([c(FAIL, 5)], head, self.AT))
        older = (T0 + dt.timedelta(minutes=1)).isoformat()
        self.assertIsNotNone(W.fix_handoff_stalled([c(FAIL, 5)], older, self.AT))   # only commits before the FAIL

    def test_activity_or_an_earlier_flag_clears_it(self):
        self.assertIsNone(W.fix_handoff_stalled([c(FAIL, 5), c("In Progress → Review", 9)], None, self.AT))
        self.assertIsNone(W.fix_handoff_stalled([c(FAIL, 5), c(W.STALL_MARK + "\nFix-up hand-off stalled", 26)], None, self.AT))

    def test_no_fail_or_a_new_fail_after_a_flag(self):
        self.assertIsNone(W.fix_handoff_stalled([c("In Progress → Review", 1)], None, self.AT))
        self.assertIsNone(W.fix_handoff_stalled([], None, self.AT))
        # flagged once, then a newer FAIL: the newer one is judged on its own
        cs = [c(FAIL, 0), c(W.STALL_MARK, 3), c(FAIL, 8)]
        self.assertEqual(W.fix_handoff_stalled(cs, None, self.AT), T0 + dt.timedelta(minutes=8))

class FixHandoffCheck(unittest.TestCase):
    """Check 2 end to end with a stub gh: one flagged comment on the issue and the PR, guards respected."""
    def setUp(self):
        W._last_comment.clear()

    def _gh(self, prs, comments, posted):
        def gh(args):
            if args[:2] == ["pr", "list"]:
                self.assertEqual(args[args.index("--json") + 1], "number,body,closingIssuesReferences,headRefOid")   # never `commits`
                return subprocess.CompletedProcess(args, 0, json.dumps(prs if "cmdemo1-dashboard" in args[3] else []), "")
            if args[0] == "api" and "/commits/" in args[1]:
                sha = args[1].rsplit("/", 1)[1]
                return subprocess.CompletedProcess(args, 0, self.HEADS.get(sha, (T0 - dt.timedelta(minutes=30)).isoformat()) + "\n", "")
            if args[0] == "api":
                return subprocess.CompletedProcess(args, 0, "\n".join(json.dumps(x) for x in comments), "")
            if args[:2] == ["issue", "comment"]:
                with open(args[args.index("--body-file") + 1]) as f: posted.append((args[2], f.read()))
                return subprocess.CompletedProcess(args, 0, "", "")
            raise AssertionError(args)
        return gh

    def _run(self, prs, comments):
        posted = []
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):   # no real drivers on disk
            r = W.fix_handoff_check(gh=self._gh(prs, comments, posted), clock=lambda: T0 + dt.timedelta(minutes=40),
                                    log=lambda s: None)
        return r, posted

    PR = {"number": 1311, "body": "Closes #1309\n\n" + L.DRIVER_MARK, "closingIssuesReferences": [{"number": 1309}],
          "headRefOid": "aaa"}
    HEADS = {}   # sha -> committer date; default 30 min before T0

    def test_stalled_fail_is_flagged_on_issue_and_pr(self):
        r, posted = self._run([self.PR], [c(FAIL, 5)])
        self.assertEqual(r, "stalled: cmdemo1-dashboard#1309")
        self.assertEqual([n for n, _ in posted], ["1309", "1311"])
        self.assertTrue(all(W.STALL_MARK in b and "PR #1311" in b for _, b in posted))

    def test_non_driver_pr_and_excluded_items_are_left_alone(self):
        r, posted = self._run([dict(self.PR, body="human PR")], [c(FAIL, 5)])
        self.assertEqual((r, posted), ("ok", []))
        with mock.patch.object(W, "EXCLUDED", W.EXCLUDED | {("cmdemo1-dashboard", 1309)}):   # an excluded issue
            self.assertEqual(self._run([self.PR], [c(FAIL, 5)]), ("ok", []))

    def test_live_driver_with_stale_progress_is_not_flagged(self):   # mid-fix / CI wait / review-GPU wait: still running
        posted = []
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):   # no real drivers on disk
            states = [("run", {"repo": "cmdemo1-dashboard", "issue": 1309, "pid": os.getpid(), "stage": "ci",
                               "progress_at": (T0 - dt.timedelta(minutes=60)).isoformat()})]
            with mock.patch.object(L, "all_states", lambda: states):
                r = W.fix_handoff_check(gh=self._gh([self.PR], [c(FAIL, 5)], posted),
                                        clock=lambda: T0 + dt.timedelta(minutes=40), log=lambda s: None)
        self.assertEqual((r, posted), ("ok", []))
        self.assertTrue(W.driver_alive(states, "cmdemo1-dashboard", 1309))
        self.assertFalse(W.driver_alive([("run", dict(states[0][1], pid=2 ** 22))], "cmdemo1-dashboard", 1309))

    def test_cross_repo_closing_issue_is_ignored(self):
        pr = dict(self.PR, closingIssuesReferences=[{"number": 1309, "repository": {"name": "cmdemo1-workorders"}}])
        self.assertEqual(self._run([pr], [c(FAIL, 5)]), ("ok", []))

    def test_one_bad_comment_response_does_not_hide_the_others(self):
        posted, logs = [], []
        good = self._gh([self.PR, dict(self.PR, number=1400, closingIssuesReferences=[{"number": 1398}])], [c(FAIL, 5)], posted)
        def gh(args):
            if args[0] == "api" and "/issues/1309/" in args[2]:
                return subprocess.CompletedProcess(args, 0, "gh: warning not json", "")
            return good(args)
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):
            r = W.fix_handoff_check(gh=gh, clock=lambda: T0 + dt.timedelta(minutes=40), log=logs.append)
        self.assertEqual(r, "stalled: cmdemo1-dashboard#1398")
        self.assertTrue(any("PR #1311 skipped" in l for l in logs))

    def test_fixed_pr_is_not_flagged(self):
        self.HEADS = {"bbb": (T0 + dt.timedelta(minutes=10)).isoformat().replace("+00:00", "Z")}
        pr = dict(self.PR, headRefOid="bbb")
        self.assertEqual(self._run([pr], [c(FAIL, 5)]), ("ok", []))

    def test_failed_pr_list_is_in_the_result(self):
        posted = []
        def gh(args):
            if args[:2] == ["pr", "list"]: return subprocess.CompletedProcess(args, 1, "GraphQL: too many nodes", "")
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):
            r = W.fix_handoff_check(repos=("cmdemo1-dashboard",), gh=gh, clock=lambda: T0, log=lambda s: None)
        self.assertEqual(r, "ok; list failed: cmdemo1-dashboard")

class SharedEntry(unittest.TestCase):
    def test_cli_run_entry_calls_run_checks_once_with_the_defaults(self):
        calls = []
        with fake_modules({(W, "run_checks"): lambda **kw: (calls.append(kw), [("gpu_health_check", "ok")])[1]}):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(W.main(["run"]), 0)
            self.assertEqual(calls, [{}])                   # 'run' calls run_checks once, with the defaults
            self.assertEqual(json.loads(out.getvalue()), [["gpu_health_check", "ok"]])

    def test_cli_help_works(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            with self.assertRaises(SystemExit) as e:
                W.main(["--help"])
        self.assertEqual(e.exception.code, 0)
        self.assertIn("usage:", out.getvalue())

    def test_registry_lists_checks_1_and_2(self):
        self.assertEqual([c.__name__ for c in W.CHECKS], ["gpu_health_check", "fix_handoff_check", "red_main_check"])

class ExitHook(unittest.TestCase):
    """The driver's exit hook (item_loop.watchdog_exit): run_checks runs exactly once when a driver run
    ends (done, blocked or error); a failing run_checks is logged in driver.log and never changes the
    driver's end status or swallows the driver's own exception."""

    PLAN = {"repo": "cmdemo1-workorders", "issue": 40, "branch": "cm-ai-ops-bot/40-x", "files": ["src/A.cs"],
            "criteria": [{"text": "A works", "evidence_cmd": "dotnet test --filter A"}],
            "tasks": [{"name": "t1", "prompt": "Write test A"}], "verify_cmd": "dotnet build", "pr_title": "A"}

    @contextlib.contextmanager
    def _env(self, h, issue, end, failing=False):
        """A dry-run driver under the temp home h, ending at `end` ("done", "blocked" or "raise"), with the watchdog's
        run_checks replaced by a stub that records its calls (and fails when `failing`); yields (driver, calls).
        fake_modules puts L.HOME and watchdog.run_checks back when the block ends, so no test leaves the watchdog
        patched for the next one and no test has to remember the restore order (#940)."""
        calls = []
        def rc(**kw):
            calls.append(kw)
            if failing: raise RuntimeError("checks down")
            return [("gpu_health_check", "ok")]
        with fake_modules({(L, "HOME"): h, (W, "run_checks"): rc}):
            d = L.Driver(self.PLAN["repo"], issue, dry_run=True)
            with open(os.path.join(d.run_dir, "plan.json"), "w") as f:
                json.dump(self.PLAN, f)
            d.sh = lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, "ok", "")
            if end == "raise":
                d.st_gpu = lambda: (_ for _ in ()).throw(RuntimeError("driver boom"))
            else:
                d.st_gpu = lambda: d.save(stage=end, **({"resume_stage": "ci"} if end == "blocked" else {}))
            yield d, calls

    def test_run_checks_once_when_done(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 40, "done") as (d, calls):
            d.run()
        self.assertEqual(d.s["status"], "done")
        self.assertEqual(len(calls), 1)                   # the exit hook ran run_checks exactly once
        self.assertIs(calls[0]["log"].__self__, d)        # called with the driver's own log

    def test_run_checks_once_when_blocked_and_hold_returns_false(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 41, "blocked") as (d, calls):
            d.run()
        self.assertEqual(d.s["status"], "blocked")
        self.assertFalse(d.hold_blocked())               # the blocker holds: no resume, the run ends blocked
        self.assertEqual(len(calls), 1)
        self.assertIs(calls[0]["log"].__self__, d)

    def test_run_checks_once_when_driver_raises(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 42, "raise") as (d, calls):
            with self.assertRaises(RuntimeError) as e:
                d.run()
            self.assertEqual(str(e.exception), "driver boom")   # the original driver exception is re-raised
        self.assertEqual((d.s["status"], d.s["error"]), ("error", "driver boom"))
        self.assertEqual(len(calls), 1)
        self.assertIs(calls[0]["log"].__self__, d)

    def test_failing_run_checks_is_logged_and_does_not_change_end_status(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 43, "done", failing=True) as (d, calls):
            d.run()                                   # the hook failure never escapes Driver.run
            with open(os.path.join(d.run_dir, "driver.log")) as f:
                log = f.read()
            self.assertIn("watchdog exit hook failed: checks down", log)
        self.assertEqual(d.s["status"], "done")          # the run still ends with the same status
        self.assertEqual(len(calls), 1)

    def test_import_failure_never_raises_out_of_the_done_path(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 45, "done") as (d, calls):
            with mock.patch.dict(sys.modules, {"watchdog": None}):    # `import watchdog` raises
                d.run()                                               # the hook swallows it; the run ends done
            with open(os.path.join(d.run_dir, "driver.log")) as f:
                log = f.read()
            self.assertIn("watchdog exit hook failed", log)
        self.assertEqual(d.s["status"], "done")
        self.assertEqual(calls, [])

    def test_import_failure_does_not_replace_the_driver_exception(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 46, "raise") as (d, calls):
            with mock.patch.dict(sys.modules, {"watchdog": None}):
                with self.assertRaises(RuntimeError) as e:
                    d.run()
            self.assertEqual(str(e.exception), "driver boom")   # still the original driver exception
        self.assertEqual(d.s["status"], "error")
        self.assertEqual(calls, [])

    def test_hook_never_raises_even_when_logging_fails(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 47, "done", failing=True) as (d, calls):
            real = d.log
            def log(line):
                if "watchdog exit hook" in line: raise IOError("driver.log is closed")
                real(line)
            d.log = log
            d.run()                                   # the failed log line never escapes Driver.run
        self.assertEqual(d.s["status"], "done")
        self.assertEqual(len(calls), 1)

    def test_failing_run_checks_never_swallows_the_driver_exception(self):
        with tempfile.TemporaryDirectory() as h, self._env(h, 44, "raise", failing=True) as (d, calls):
            with self.assertRaises(RuntimeError) as e:
                d.run()
            self.assertEqual(str(e.exception), "driver boom")   # still the original driver exception
            with open(os.path.join(d.run_dir, "driver.log")) as f:
                log = f.read()
            self.assertIn("driver error: driver boom", log)
            self.assertIn("watchdog exit hook failed: checks down", log)
        self.assertEqual(d.s["status"], "error")
        self.assertEqual(len(calls), 1)

class SharedScrubImport(unittest.TestCase):
    """#931: the watchdog reaches the shared scrub rule set directly (watchdog -> scrub): the module-level
    scrub is the leaf function itself, no delegating wrapper, and it redacts exactly as the driver's does."""

    def test_watchdog_binds_the_leaf_scrub_function(self):
        import importlib
        scrub = importlib.import_module("scrub")
        self.assertIs(W.scrub, scrub.scrub, "the watchdog must scrub through the shared rule set itself, not a wrapper")
        self.assertIs(W.scrub, L.scrub, "...and it is still the one rule set the driver re-exports")

    def test_watchdog_source_imports_the_leaf_and_keeps_no_wrapper(self):
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "watchdog.py")
        src = open(p).read()
        self.assertIn("from scrub import scrub", src)
        self.assertNotIn("def scrub(", src)   # the delegating wrapper is gone: the module name binds the leaf function

    def test_scrub_redacts_a_runtime_token_a_local_llm_token_and_a_tunnel_host(self):
        fake = lambda c: "fake" + c * 12   # built at run time so the secret scan sees no literal
        env = {"LOCAL_LLM_OBS_TOKEN": fake("o"), "LOCAL_LLM_TS3_TOKEN": fake("t")}
        old = {k: os.environ.get(k) for k in env}; os.environ.update(env)
        try:
            out = W.scrub(f"a {fake('o')} b {fake('t')} c https://pro5000.clearmeasure.ai/v1/models")
            for v in env.values(): self.assertNotIn(v, out)   # the LOCAL_LLM_*_TOKEN values are redacted
            self.assertNotIn("pro5000.clearmeasure.ai", out)  # and the tunnel hostname
            self.assertIn("[redacted]", out)
        finally:
            for k, v in old.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
        tok = "ghp_" + "k" * 30   # a runtime-built token value
        out = W.scrub(f"x {tok} y")
        self.assertNotIn(tok, out); self.assertIn("[redacted]", out)


# ---------------------------------------------------------------- check 3: own green, mergeable, unmerged PRs
GREEN_CHECKS = [{"name": "Build result", "bucket": "pass"}, {"name": "secret-scan", "bucket": "pass"}]
HEALTHY = {g: ("HEALTHY", "serves a loaded model (Pi asks for `auto`)") for g in G.GPUS}

class GreenPrHoldRule(unittest.TestCase):
    """Check 3's pure rule: a green, mergeable, unmerged bot PR merges only with no Jeffrey hold and no
    unaddressed Review: FAIL / Blocker: in its journal."""

    def test_clean_journal_is_mergeable(self):
        self.assertIsNone(W.green_pr_hold([c("In Progress → Review", 0), c("Status: no progress", 1)], None))
        self.assertIsNone(W.green_pr_hold([], None))

    def test_jeffrey_hold_is_unconditional(self):
        head = (T0 + dt.timedelta(minutes=50)).isoformat()   # even a commit after it, and a PASS, do not lift it
        h = W.green_pr_hold([c("Not merging until Jeffrey confirms", 5), c("Review: PASS", 10)], head)
        self.assertEqual(h[0], "jeffrey")

    def test_unaddressed_review_fail_holds(self):
        self.assertEqual(W.green_pr_hold([c(FAIL, 5)], (T0 + dt.timedelta(minutes=1)).isoformat())[0], "fail")   # commit predates the FAIL

    def test_unaddressed_blocker_holds(self):
        self.assertEqual(W.green_pr_hold([c("Blocker: needs Jeffrey. The Pi driver stopped.", 5)], None)[0], "blocker")

    def test_a_commit_after_the_hold_clears_it(self):
        self.assertIsNone(W.green_pr_hold([c(FAIL, 5)], (T0 + dt.timedelta(minutes=12)).isoformat()))
        self.assertIsNone(W.green_pr_hold([c("Blocker: needs Jeffrey.", 5)], (T0 + dt.timedelta(minutes=9)).isoformat()))

    def test_a_pass_comment_after_the_fail_clears_it(self):
        self.assertIsNone(W.green_pr_hold([c(FAIL, 5), c("Review: PASS", 9)], None))

    def test_the_latest_hold_is_the_one_judged(self):
        # an old addressed FAIL, then a fresh unaddressed Blocker: the Blocker holds
        self.assertEqual(W.green_pr_hold([c(FAIL, 0), c("Review: PASS", 2), c("Blocker: needs Jeffrey.", 8)], None)[0], "blocker")

class OwnGreenPrsCheck(unittest.TestCase):
    """Check 3 end to end with a stub gh, a fake health and a fake review: a green, mergeable, unmerged
    cm-ai-ops-bot PR is reviewed on a non-author GPU and squash-merged with --match-head-commit (never
    --delete-branch) only on PASS; the no-op cases act on nothing and post no comment."""

    PR = {"number": 100, "author": {"login": L.BOT}, "headRefOid": "abc123def456", "mergeable": "MERGEABLE",
          "closingIssuesReferences": [{"number": 99}]}

    def setUp(self):
        W._last_comment.clear()

    def _gh(self, prs, comments, checks, posted, merged):
        def gh(args):
            if args[:2] == ["pr", "list"]:
                return subprocess.CompletedProcess(args, 0, json.dumps(prs if "cmdemo1-workorders" in args[3] else []), "")
            if args[:2] == ["pr", "checks"]:
                return subprocess.CompletedProcess(args, 0, json.dumps(checks), "")
            if args[:2] == ["pr", "merge"]:
                merged.append(args)
                return subprocess.CompletedProcess(args, 0, "Merged", "")
            if args[:2] == ["issue", "comment"]:
                with open(args[args.index("--body-file") + 1]) as f: posted.append((args[2], f.read()))
                return subprocess.CompletedProcess(args, 0, "", "")
            if args[0] == "api" and "/commits/" in args[1]:
                return subprocess.CompletedProcess(args, 0, (T0 - dt.timedelta(hours=1)).isoformat() + "\n", "")
            if args[0] == "api":
                return subprocess.CompletedProcess(args, 0, "\n".join(json.dumps(x) for x in comments), "")
            raise AssertionError(args)
        return gh

    def _run(self, prs, comments, checks, review=None, states=None, health=None, logs=None):
        posted, merged, reviews = [], [], []
        def fake_review(repo, pr, issue, gpu):
            reviews.append((repo, pr, issue, gpu))
            return review(repo, pr, issue, gpu)
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):
            if states is not None:
                rd = os.path.join(home, "factory-runs", "run1"); os.makedirs(rd)
                with open(os.path.join(rd, "state.json"), "w") as f: json.dump(states, f)
            r = W.own_green_prs_check(repos=("cmdemo1-workorders",), gh=self._gh(prs, comments, checks, posted, merged),
                                      health=lambda: health or dict(HEALTHY), review=fake_review,
                                      clock=lambda: T0, log=logs.append if logs is not None else (lambda s: None))
        return r, posted, merged, reviews

    def test_green_mergeable_bot_pr_is_reviewed_off_author_gpu_and_merged(self):
        def review(repo, pr, issue, gpu):
            self.assertNotIn(gpu, ("pro5000",))   # never the author's GPU
            return L.ReviewVerdict(True, "- No findings.")
        r, posted, merged, reviews = self._run([self.PR], [], GREEN_CHECKS, review=review,
                                               states={"repo": "cmdemo1-workorders", "issue": 99, "gpu": "pro5000",
                                                       "author_gpus": ["pro5000"], "pid": 2 ** 22})
        self.assertEqual(reviews, [("cmdemo1-workorders", 100, 99, "pro6000")])   # the strongest non-author GPU
        self.assertEqual(merged, [L.merge_args("clearmeasure-aisf-sample-apps/cmdemo1-workorders", 100, "abc123def456")])
        self.assertIn("--squash", merged[0]); self.assertIn("--match-head-commit", merged[0])
        self.assertNotIn("--delete-branch", merged[0])
        self.assertIn("PR #100", r)
        self.assertEqual([n for n, _ in posted], ["99", "100"])   # the PASS comment lands on the issue and the PR
        self.assertTrue(all("Review: PASS" in b and "abc123de" in b for _, b in posted))

    def test_review_fail_comments_but_never_merges(self):
        def review(repo, pr, issue, gpu):
            return L.ReviewVerdict(False, "- a real finding")
        r, posted, merged, _ = self._run([self.PR], [], GREEN_CHECKS, review=review)
        self.assertEqual(merged, [])
        self.assertIn("review-fail", r)
        self.assertEqual([n for n, _ in posted], ["99", "100"])
        self.assertTrue(all("Review: FAIL" in b and "a real finding" in b for _, b in posted))

    def test_infra_review_is_a_wait_with_no_comment_and_no_merge(self):
        def review(repo, pr, issue, gpu):
            return L.ReviewVerdict(None, "the review ended with no PASS/FAIL verdict (run result: timeout)")
        r, posted, merged, _ = self._run([self.PR], [], GREEN_CHECKS, review=review)
        self.assertEqual((merged, posted), ([], []))
        self.assertIn("waiting: cmdemo1-workorders PR #100", r)

    def test_human_pr_conflicting_pr_and_red_checks_are_left_alone(self):
        for pr in (dict(self.PR, author={"login": "some-human"}),
                   dict(self.PR, mergeable="CONFLICTING")):
            r, posted, merged, reviews = self._run([pr], [], GREEN_CHECKS)
            self.assertEqual((r, posted, merged, reviews), ("ok", [], [], []))
        r, posted, merged, reviews = self._run([self.PR], [], [{"name": "Build result", "bucket": "fail"}])
        self.assertEqual((r, posted, merged, reviews), ("ok", [], [], []))

    def test_jeffrey_hold_and_unaddressed_fail_skip_the_review(self):
        for comments in ([c("Not merging until Jeffrey confirms", 5)], [c(FAIL, 5)]):   # the head commit is 1 h old
            r, posted, merged, reviews = self._run([self.PR], comments, GREEN_CHECKS)
            self.assertEqual((r, posted, merged, reviews), ("ok", [], [], []))

    def test_live_driver_is_left_alone_progressing_or_not(self):
        # a live driver owns the PR whether it is progressing or just waiting (a GPU / CI / review stall):
        # the watchdog never races it into a merge
        for progress_at in ((T0 - dt.timedelta(seconds=60)).isoformat(), (T0 - dt.timedelta(minutes=60)).isoformat()):
            states = {"repo": "cmdemo1-workorders", "issue": 99, "pid": os.getpid(), "progress_at": progress_at}
            r, posted, merged, reviews = self._run([self.PR], [], GREEN_CHECKS, states=states)
            self.assertEqual((r, posted, merged, reviews), ("ok", [], [], []))
        self.assertTrue(W.driver_alive([("run", {"repo": "cmdemo1-workorders", "issue": 99, "pid": os.getpid()})],
                                       "cmdemo1-workorders", 99))
        self.assertFalse(W.driver_alive([("run", {"repo": "cmdemo1-workorders", "issue": 99, "pid": 2 ** 22})],
                                        "cmdemo1-workorders", 99))

    def test_workorders_pr_1918_is_never_reviewed_or_merged(self):
        pr = dict(self.PR, number=1918, closingIssuesReferences=[{"number": 1917}])
        def review(repo, p, issue, gpu):
            raise AssertionError("PR 1918 must never be reviewed for a merge")
        r, posted, merged, reviews = self._run([pr], [], GREEN_CHECKS, review=review)
        self.assertEqual((r, posted, merged, reviews), ("ok", [], [], []))

    def test_no_non_author_gpu_free_is_a_wait_with_no_comment(self):
        def review(repo, pr, issue, gpu):
            raise AssertionError("no review expected: no non-author GPU is free")
        h = {g: ("HEALTHY" if g in ("pro5000", "pro6000") else "UNREACHABLE", "x") for g in G.GPUS}
        # the author owns pro5000 + pro6000 (the only healthy GPUs): every reviewer candidate is excluded
        r, posted, merged, reviews = self._run([self.PR], [], GREEN_CHECKS, review=review, health=h,
                                               states={"repo": "cmdemo1-workorders", "issue": 99, "gpu": "pro5000",
                                                       "author_gpus": ["pro6000"], "pid": 2 ** 22})
        self.assertIn("waiting: cmdemo1-workorders PR #100", r)
        self.assertEqual((posted, merged, reviews), ([], [], []))

    def test_one_bad_pr_does_not_hide_the_others(self):
        bad = dict(self.PR, number=200, closingIssuesReferences=[{"number": 199}])
        def review(repo, pr, issue, gpu):
            return L.ReviewVerdict(True, "- No findings.")
        posted, merged, logs = [], [], []
        def gh(args):
            if args[:2] == ["pr", "list"]:
                return subprocess.CompletedProcess(args, 0, json.dumps([bad, self.PR]), "")
            if args[:2] == ["pr", "checks"]:
                if args[2] == "200": return subprocess.CompletedProcess(args, 0, "not json", "")   # the bad PR
                return subprocess.CompletedProcess(args, 0, json.dumps(GREEN_CHECKS), "")
            if args[:2] == ["pr", "merge"]:
                merged.append(args)
                return subprocess.CompletedProcess(args, 0, "Merged", "")
            if args[:2] == ["issue", "comment"]:
                with open(args[args.index("--body-file") + 1]) as f: posted.append((args[2], f.read()))
                return subprocess.CompletedProcess(args, 0, "", "")
            if args[0] == "api":
                return subprocess.CompletedProcess(args, 0, "", "")
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):
            r = W.own_green_prs_check(repos=("cmdemo1-workorders",), gh=gh, health=lambda: dict(HEALTHY),
                                      review=review, clock=lambda: T0, log=logs.append)
        self.assertEqual(merged, [L.merge_args("clearmeasure-aisf-sample-apps/cmdemo1-workorders", 100, "abc123def456")])
        self.assertTrue(any("PR #200 skipped" in l for l in logs))
        self.assertIn("PR #100", r)

    def test_failed_pr_list_is_in_the_result(self):
        def gh(args):
            if args[:2] == ["pr", "list"]: return subprocess.CompletedProcess(args, 1, "gh: boom", "")
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home}):
            r = W.own_green_prs_check(repos=("cmdemo1-workorders",), gh=gh, health=lambda: dict(HEALTHY),
                                      review=lambda *a: None, clock=lambda: T0, log=lambda s: None)
        self.assertEqual(r, "ok; list failed: cmdemo1-workorders")

class OwnGreenPrsEntry(unittest.TestCase):
    """Check 3's wiring: run_checks(own_prs=True) and the `run-own-prs` CLI run the full set (the driver-exit
    hook's); the default run_checks() and `run` keep the registered checks only."""

    def test_run_checks_own_prs_runs_check_3_after_the_registered_checks(self):
        seen = []
        def fake(**kw): seen.append("own"); return "ok"
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home, (W, "own_green_prs_check"): fake}):
            r = W.run_checks(gh=no_prs, own_prs=True, log=lambda s: None)
        self.assertEqual([n for n, _ in r], ["gpu_health_check", "fix_handoff_check", "red_main_check", "fake"])
        self.assertEqual(seen, ["own"])
        self.assertEqual(r[2], ("red_main_check", "ok"))
        self.assertEqual(r[3], ("fake", "ok"))

    def test_default_run_checks_keeps_the_registered_checks_only(self):
        def no_check3(**kw): raise AssertionError("check 3 must not run without own_prs=True")
        with tempfile.TemporaryDirectory() as home, fake_modules({(L, "HOME"): home, (W, "own_green_prs_check"): no_check3}):
            r = W.run_checks(gh=no_prs, log=lambda s: None)
        self.assertEqual([n for n, _ in r], ["gpu_health_check", "fix_handoff_check", "red_main_check"])

    def test_cli_run_own_prs_passes_the_flag(self):
        calls = []
        with fake_modules({(W, "run_checks"): lambda **kw: (calls.append(kw), [["own_green_prs_check", "ok"]])[1]}):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(W.main(["run-own-prs"]), 0)
        self.assertEqual(calls, [{"own_prs": True}])

    def test_exit_hook_runs_the_full_set(self):
        """item_loop.watchdog_exit passes own_prs=True: the driver-exit hook gets check 3 with the rest."""
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "item_loop.py")).read()
        self.assertIn("watchdog.run_checks(log=drv.log, own_prs=True)", src)

class PiReviewDefault(unittest.TestCase):
    """Check 3's default review runner: one run-task on the given (non-author) GPU with the diff in the prompt;
    the record's result and the findings file become the ReviewVerdict pair."""

    def _gh(self, diff="diff --git a/a b/b"):
        def gh(args):
            if args[:2] == ["pr", "view"]: return subprocess.CompletedProcess(args, 0, "the PR body\n", "")
            if args[:2] == ["issue", "view"]: return subprocess.CompletedProcess(args, 0, "the issue body\n", "")
            if args[:2] == ["pr", "diff"]: return subprocess.CompletedProcess(args, 0, diff, "")
            raise AssertionError(args)
        return gh

    def test_fail_reads_the_findings_file_and_keeps_the_diff_in_the_prompt(self):
        def runner(cmd, **kw):
            self.assertEqual(cmd[0], os.path.join(L.HERE, "run-task"))
            self.assertEqual(cmd[cmd.index("--task") + 1], "watchdog-review-cmdemo1-workorders-100")
            self.assertEqual(cmd[cmd.index("--gpu") + 1], "ts3")
            d = cmd[cmd.index("--run-dir") + 1]
            self.assertEqual(cmd[cmd.index("--cwd") + 1], d)
            with open(cmd[cmd.index("--prompt-file") + 1]) as f: prompt = f.read()
            self.assertIn("diff --git a/a b/b", prompt)
            self.assertIn("End your reply with PASS", prompt)
            self.assertIn("the issue body", prompt)
            self.assertIn("the PR body", prompt)
            open(os.path.join(d, "independent-review.md"), "w").write("- a real finding\n")
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"result": "FAIL", "gpu": "ts3"}) + "\n", "")
        result, findings = W.pi_review("cmdemo1-workorders", 100, 99, "ts3", gh=self._gh(), runner=runner)
        v = L.review_verdict(result, findings)
        self.assertTrue(v.is_fail)
        self.assertIn("a real finding", findings)

    def test_pass_with_no_findings_file_is_infra_not_a_code_verdict(self):
        def runner(cmd, **kw):
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"result": "PASS", "gpu": "obs"}) + "\n", "")
        result, findings = W.pi_review("cmdemo1-workorders", 100, 99, "obs", gh=self._gh(), runner=runner)
        v = L.review_verdict(result, findings)
        self.assertTrue(v.is_infra)   # PASS with no findings file: the reviewer wrote nothing, not a code verdict
        self.assertFalse(v.is_fail)

    def test_timeout_with_no_issue_is_infra(self):
        def runner(cmd, **kw):
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"result": "timeout", "gpu": "obs"}) + "\n", "")
        result, findings = W.pi_review("cmdemo1-workorders", 100, None, "obs", gh=self._gh(diff=""), runner=runner)
        v = L.review_verdict(result, findings)
        self.assertTrue(v.is_infra)
        self.assertFalse(v.is_fail)


# ---------------------------------------------------------------- check 4: idle_decision pure rule
class IdleDecisionRule(unittest.TestCase):
    """Check 4's pure rule: a dead driver whose item has been idle > 90 min is restarted, reassigned or waits.
    Every test passes explicit state, at, up, busy and a fake alive lambda — no disk, no network."""

    T0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)

    def _state(self, **kw):
        base = {"repo": "cmdemo1-system", "issue": 999, "status": "running", "pid": 2**22,
                "progress_at": (self.T0 - dt.timedelta(minutes=91)).isoformat(), "gpu": "ts3"}
        base.update(kw)
        return base

    def test_dead_driver_idle_91min_recorded_gpu_up_and_free_returns_resume(self):
        at = self.T0
        st = self._state(progress_at=(at - dt.timedelta(minutes=91)).isoformat(), gpu="ts3")
        up = ["pro5000", "pro6000", "obs", "ts3"]
        busy = []
        alive = lambda pid: False
        self.assertEqual(W.idle_decision(st, at, up, busy, alive=alive), ("resume", "ts3"))

    def test_dead_driver_idle_89min_returns_leave(self):
        at = self.T0
        st = self._state(progress_at=(at - dt.timedelta(minutes=89)).isoformat())
        up = ["pro5000", "pro6000", "obs", "ts3"]
        busy = []
        alive = lambda pid: False
        self.assertEqual(W.idle_decision(st, at, up, busy, alive=alive), ("leave", None))

    def test_live_pid_idle_300min_recorded_gpu_down_returns_leave(self):
        at = self.T0
        st = self._state(progress_at=(at - dt.timedelta(minutes=300)).isoformat(), gpu="ts3")
        up = ["pro5000", "pro6000", "obs"]   # ts3 is down
        busy = []
        alive = lambda pid: True   # live driver: never restarted
        self.assertEqual(W.idle_decision(st, at, up, busy, alive=alive), ("leave", None))

    def test_dead_driver_idle_91min_recorded_gpu_down_other_gpu_free_returns_reassign(self):
        at = self.T0
        st = self._state(progress_at=(at - dt.timedelta(minutes=91)).isoformat(), gpu="ts3")
        up = ["pro5000", "pro6000", "obs"]   # ts3 down; pro5000 is up and free
        busy = []
        alive = lambda pid: False
        # G.pick_gpu("small", up, busy) → first free in PRIORITY order = "pro5000"
        self.assertEqual(W.idle_decision(st, at, up, busy, alive=alive), ("reassign", "pro5000"))

    def test_dead_driver_idle_91min_recorded_gpu_busy_no_other_free_returns_wait(self):
        at = self.T0
        st = self._state(progress_at=(at - dt.timedelta(minutes=91)).isoformat(), gpu="ts3")
        up = ["pro5000", "pro6000", "obs", "ts3"]   # ts3 up but busy
        busy = ["pro5000", "pro6000", "obs", "ts3"] # everything is busy
        alive = lambda pid: False
        # G.pick_gpu("small", up, busy) → no free GPU → None → wait
        self.assertEqual(W.idle_decision(st, at, up, busy, alive=alive), ("wait", None))

    def test_excluded_item_returns_leave(self):
        at = self.T0
        st = self._state(repo="cmdemo1-system", issue=652, progress_at=(at - dt.timedelta(minutes=91)).isoformat())
        up = ["pro5000", "pro6000", "obs", "ts3"]
        busy = []
        alive = lambda pid: False
        self.assertEqual(W.idle_decision(st, at, up, busy, alive=alive), ("leave", None))

    def test_z_suffix_mixed_with_offset_no_exception_newest_used(self):
        at = self.T0
        # last_comment_at is 10 min ago with Z suffix; progress_at is 200 min ago with +00:00
        st = self._state(
            progress_at=(at - dt.timedelta(minutes=200)).isoformat(),          # +00:00 offset
            last_comment_at=(at - dt.timedelta(minutes=10)).isoformat().replace("+00:00", "Z"),  # Z suffix
            gpu="ts3")
        up = ["pro5000", "pro6000", "obs", "ts3"]
        busy = []
        alive = lambda pid: False
        # newest is last_comment_at (10 min ago) < 90 min → leave
        self.assertEqual(W.idle_decision(st, at, up, busy, alive=alive), ("leave", None))

SYS = "cmdemo1-system"
SYS_KEY = "cmdemo1-system main"
SYS_TITLE = "Fix forward: cmdemo1-system main is red"
all_healthy = lambda: {g: ("HEALTHY", "serves a loaded model (Pi asks for `auto`)") for g in G.GPUS}

def run(rid, name, conclusion, status="completed"):
    return {"id": rid, "name": name, "status": status, "conclusion": conclusion}

class FakeGh:
    """gh stub for check 4: main's head sha, that sha's push runs, the open fix-forward titles (or a failed lookup),
    and a recorded `issue create` (whose body file is read before the check deletes it). No open PRs anywhere."""

    def __init__(self, runs, titles=(), titles_rc=0, create=None):
        self.runs, self.titles, self.titles_rc, self.create = runs, list(titles), titles_rc, create
        self.creates, self.bodies, self.calls = [], [], []

    def __call__(self, args):
        self.calls.append(args)
        ok = lambda out: subprocess.CompletedProcess(args, 0, out, "")
        if args[:1] == ["api"] and args[1].endswith("/commits/main"): return ok(HEAD_SHA + "\n")
        if args[:1] == ["api"] and "/actions/runs?" in args[1]:
            assert f"head_sha={HEAD_SHA}&event=push&per_page=50" in args[1], args[1]
            return ok(json.dumps(self.runs))
        if args[:1] == ["api"] and "/issues?state=open&labels=fix-forward" in args[1]:
            return subprocess.CompletedProcess(args, self.titles_rc, json.dumps(self.titles) if self.titles_rc == 0 else "HTTP 502", "")
        if args[:2] == ["issue", "create"]:
            if self.create: raise self.create
            with open(args[args.index("--body-file") + 1]) as f: self.bodies.append(f.read())
            self.creates.append(args); self.titles.append(args[args.index("--title") + 1])
            return ok(f"https://github.com/{L.ORG}/{SYS}/issues/9001\n")
        if args[:1] == ["issue"] and "comment" in args: raise AssertionError("check 4 posts no comments")
        return ok("[]")

class RedMainCheck(unittest.TestCase):
    """Check 4 (red_main_check): a red default-branch head (newest run per workflow on the head sha) sets
    `<repo> main` in red.json and files one fix-forward issue; a green head clears it; unknown changes nothing."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory(); self.addCleanup(self.home.cleanup)
        self.swap = fake_modules({(L, "HOME"): self.home.name}); self.swap.__enter__()
        self.addCleanup(self.swap.__exit__, None, None, None)
        self.logs = []

    def check(self, gh, repos=(SYS,)):
        return W.red_main_check(repos=repos, gh=gh, health=all_healthy, log=self.logs.append)

    def test_red_head_sets_the_flag_and_files_one_issue_once(self):
        gh = FakeGh([run(1, "Build", "success"), run(2, "Integration", "failure")])
        sets = []
        real_set = L.red_set
        with fake_modules({(L, "red_set"): lambda k, w: (sets.append(k), real_set(k, w))[1]}):
            self.assertEqual(self.check(gh), "acted: cmdemo1-system flagged, cmdemo1-system filed")
            self.assertEqual(self.check(gh), "ok")   # second run: the flag and the open issue already exist
        self.assertEqual(sets, [SYS_KEY])
        self.assertIn(SYS_KEY, L.red_load())
        self.assertEqual(len(gh.creates), 1)
        a = gh.creates[0]
        self.assertEqual(a[a.index("--title") + 1], SYS_TITLE)
        self.assertEqual(a[a.index("--label") + 1], "fix-forward")
        self.assertEqual(a[a.index("--assignee") + 1], L.BOT)
        self.assertIn("Integration red at `aaaaaaaa`", gh.bodies[0])

    def test_issue_already_open_sets_the_flag_without_a_create(self):
        gh = FakeGh([run(5, "Build", "failure")], titles=[SYS_TITLE.lower()])
        self.assertEqual(self.check(gh), "acted: cmdemo1-system flagged")
        self.assertEqual(gh.creates, [])
        self.assertIn(SYS_KEY, L.red_load())

    def test_failed_then_green_on_the_head_sha_is_green_and_clears_the_flag(self):
        L.red_set(SYS_KEY, "Build red at `bbbbbbbb`")
        gh = FakeGh([run(7, "Build", "failure"), run(9, "Build", "success"), run(8, "Lint", "skipped")])
        self.assertEqual(self.check(gh), "acted: cmdemo1-system cleared")
        self.assertNotIn(SYS_KEY, L.red_load())
        self.assertEqual(gh.creates, [])

    def test_no_runs_or_in_progress_or_cancelled_leaves_the_flag(self):
        L.red_set(SYS_KEY, "Build red at `bbbbbbbb`")
        for runs in ([], [run(3, "Build", None, status="in_progress")], [run(4, "Build", "cancelled")],
                     [run(4, "Build", "success"), run(6, "Deploy", "timed_out")], [run(2, "Build", "action_required")]):
            gh = FakeGh(runs)
            self.assertEqual(self.check(gh), "ok", runs)
            self.assertIn(SYS_KEY, L.red_load())
            self.assertEqual(gh.creates, [])

    def test_failed_issue_lookup_creates_nothing_but_sets_the_flag(self):
        gh = FakeGh([run(1, "Build", "failure")], titles_rc=1)
        self.assertEqual(self.check(gh), "acted: cmdemo1-system flagged")
        self.assertEqual(gh.creates, [])
        self.assertIn(SYS_KEY, L.red_load())
        self.assertTrue(any("open fix-forward lookup failed" in s for s in self.logs))

    def test_issue_create_or_red_set_raising_is_logged_scrubbed_and_never_raised(self):
        secret = "https://fake-pro5000.trycloudflare.com/v1"
        gh = FakeGh([run(1, "Build", "failure")], create=RuntimeError("create broke at " + secret))
        self.assertEqual(self.check(gh), "acted: cmdemo1-system flagged")
        def boom(k, w): raise OSError("disk full near " + secret)
        L.red_clear(SYS_KEY)
        with fake_modules({(L, "red_set"): boom}):
            self.assertEqual(self.check(FakeGh([run(1, "Build", "failure")])), "ok")
        self.assertTrue(any("create broke" in s for s in self.logs))
        self.assertTrue(any("disk full" in s for s in self.logs))
        self.assertNotIn("trycloudflare", "".join(self.logs))

    def test_deploy_flags_are_never_cleared(self):
        L.red_set("dashboard tdd", "dashboard 1.0 unhealthy in tdd")
        L.red_set(SYS_KEY, "Build red at `bbbbbbbb`")
        self.assertEqual(self.check(FakeGh([run(1, "Build", "success")])), "acted: cmdemo1-system cleared")
        self.assertEqual(list(L.red_load()), ["dashboard tdd"])

    def test_red_state_keeps_only_the_newest_run_per_workflow(self):
        self.assertEqual(W.main_state([run(9, "Build", "failure"), run(3, "Build", "success")]), ("red", ["Build"]))
        self.assertEqual(W.main_state([run(3, "Build", "failure"), run(9, "Build", "success")]), ("green", []))
        self.assertEqual(W.main_state([]), ("unknown", []))

    def test_run_checks_with_own_prs_runs_red_main_check(self):
        """Behavioural wiring: the driver-exit hook's call, run_checks(own_prs=True), runs check 4."""
        gh = FakeGh([run(1, "Build", "failure")])
        r = W.run_checks(repos=(SYS,), gh=gh, health=all_healthy, log=self.logs.append, own_prs=True)
        self.assertIn(("red_main_check", "acted: cmdemo1-system flagged, cmdemo1-system filed"), r)
        self.assertEqual([n for n, _ in r][-1], "own_green_prs_check")
        self.assertIn(SYS_KEY, L.red_load())
        self.assertEqual(len(gh.creates), 1)
