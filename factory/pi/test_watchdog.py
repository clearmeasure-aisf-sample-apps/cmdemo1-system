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

def no_prs(args):   # gh stub for run_checks: no open PRs anywhere, so check 2 is a no-op
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
        self.assertEqual(r, [("gpu_health_check", "down: ts3"), ("fix_handoff_check", "ok")])   # the down GPU is in the result; the healthy ones carry on
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
        self.assertEqual(r, [("gpu_health_check", "ok"), ("fix_handoff_check", "ok")])

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
        self.assertEqual(r, [("gpu_health_check", "ok"), ("fix_handoff_check", "ok")])

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
        self.assertEqual(r, [("gpu_health_check", "no healthy GPU"), ("fix_handoff_check", "ok")])
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
        self.assertEqual([c.__name__ for c in W.CHECKS], ["gpu_health_check", "fix_handoff_check"])

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
