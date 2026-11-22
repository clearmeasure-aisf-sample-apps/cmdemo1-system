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

T0 = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)

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
        old_now, old_sleep = L.now, W.time.sleep
        L.now = lambda: now[0]
        W.time.sleep = lambda secs: (sleeps.append(secs), now.__setitem__(0, now[0] + dt.timedelta(seconds=secs)))[1]
        try:
            W.post_comment("cmdemo1-workorders", 7, "action A", states=[], gh=gh)
            st = {"repo": "cmdemo1-workorders", "issue": 7, "last_comment_at": T0.isoformat()}   # action A commented at T0
            now[0] = T0 + dt.timedelta(seconds=10)                                           # the check acts again ten seconds later
            W.post_comment("cmdemo1-workorders", 7, "action B", [("x", st)], gh=gh)
        finally:
            L.now, W.time.sleep = old_now, old_sleep
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
        old_now, old_sleep = L.now, W.time.sleep
        L.now = lambda: now[0]
        W.time.sleep = lambda secs: (sleeps.append(secs), now.__setitem__(0, now[0] + dt.timedelta(seconds=secs)))[1]
        try:
            self.assertIsNotNone(W.post_comment("cmdemo1-workorders", 7, "action A", states=[], gh=gh))
            self.assertIsNotNone(W.post_comment("cmdemo1-workorders", 7, "action B", states=[], gh=gh))
        finally:
            L.now, W.time.sleep = old_now, old_sleep
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [W.COMMENT_GAP_S])           # the second action waited the whole gap on its own
        self.assertGreaterEqual((now[0] - T0).total_seconds(), W.COMMENT_GAP_S)

    def test_failed_comment_is_logged_and_nothing_is_recorded(self):
        logs = []
        def gh(args): return subprocess.CompletedProcess(args, 1, "gh: no such issue", "")
        self.assertIsNone(W.post_comment("cmdemo1-workorders", 7, "acted", states=[], gh=gh, log=logs.append))
        self.assertEqual(W._last_comment, {})
        self.assertTrue(any("watchdog comment on cmdemo1-workorders#7 failed: gh: no such issue" in s for s in logs))

class GpuHealthCheck(unittest.TestCase):
    """Check 1: a down GPU is reported in run_checks' result and log and pick_gpu / gpu_for_item never
    select it; all GPUs healthy is a no-op with no comment."""

    def _run(self, health, log):
        with tempfile.TemporaryDirectory() as home:
            old_home = L.HOME
            L.HOME = home     # no real drivers on disk: all_states() sees no live items
            try:
                return W.run_checks(health=health, log=log)
            finally:
                L.HOME = old_home

    def test_down_gpu_reported_and_selection_routes_to_the_others(self):
        h = {g: ("HEALTHY", "serves a loaded model (Pi asks for `auto`)") for g in G.GPUS}
        h["ts3"] = ("UNREACHABLE", "no answer (unknown host or timeout)")
        logs = []
        r = self._run(lambda: dict(h), logs.append)
        self.assertEqual(r, [("gpu_health_check", "down: ts3")])   # the down GPU is in the result; the healthy ones carry on
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
        old = W.post_comment
        W.post_comment = no_comment
        try:
            r = self._run(lambda: {g: ("HEALTHY", "serves a loaded model (Pi asks for `auto`)") for g in G.GPUS},
                          lambda s: None)
        finally:
            W.post_comment = old
        self.assertEqual(r, [("gpu_health_check", "ok")])

    def test_check_failure_is_caught_logged_and_in_the_result(self):
        logs = []
        def boom(repos, gh, health, clock, log):
            raise RuntimeError("token ghp_" + "a" * 30 + " leaked")
        old = W.CHECKS
        W.CHECKS = [boom]
        try:
            r = W.run_checks(log=logs.append)
        finally:
            W.CHECKS = old
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0][0], "boom")
        self.assertTrue(r[0][1].startswith("error: "))
        self.assertTrue(any("watchdog check boom failed" in s and "[redacted]" in s for s in logs))
        self.assertNotIn("ghp_", r[0][1])
        self.assertNotIn("ghp_", "".join(logs))

class SharedEntry(unittest.TestCase):
    def test_cli_run_entry_calls_run_checks_once_with_the_defaults(self):
        calls = []
        old = W.run_checks
        W.run_checks = lambda **kw: (calls.append(kw), [("gpu_health_check", "ok")])[1]
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(W.main(["run"]), 0)
            self.assertEqual(calls, [{}])                   # 'run' calls run_checks once, with the defaults
            self.assertEqual(json.loads(out.getvalue()), [["gpu_health_check", "ok"]])
        finally:
            W.run_checks = old

    def test_cli_help_works(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            with self.assertRaises(SystemExit) as e:
                W.main(["--help"])
        self.assertEqual(e.exception.code, 0)
        self.assertIn("usage:", out.getvalue())

    def test_registry_lists_check_1(self):
        self.assertEqual([c.__name__ for c in W.CHECKS], ["gpu_health_check"])

class ExitHook(unittest.TestCase):
    """The driver's exit hook (item_loop.watchdog_exit): run_checks runs exactly once when a driver run
    ends (done, blocked or error); a failing run_checks is logged in driver.log and never changes the
    driver's end status or swallows the driver's own exception."""

    PLAN = {"repo": "cmdemo1-workorders", "issue": 40, "branch": "cm-ai-ops-bot/40-x", "files": ["src/A.cs"],
            "criteria": [{"text": "A works", "evidence_cmd": "dotnet test --filter A"}],
            "tasks": [{"name": "t1", "prompt": "Write test A"}], "verify_cmd": "dotnet build", "pr_title": "A"}

    def _setup(self, h, issue, end, failing=False):
        old_home, old_rc = L.HOME, W.run_checks
        L.HOME = h
        calls = []
        d = L.Driver(self.PLAN["repo"], issue, dry_run=True)
        with open(os.path.join(d.run_dir, "plan.json"), "w") as f:
            json.dump(self.PLAN, f)
        d.sh = lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, "ok", "")
        if end == "raise":
            d.st_gpu = lambda: (_ for _ in ()).throw(RuntimeError("driver boom"))
        else:
            d.st_gpu = lambda: d.save(stage=end, **({"resume_stage": "ci"} if end == "blocked" else {}))
        def rc(**kw):
            calls.append(kw)
            if failing: raise RuntimeError("checks down")
            return [("gpu_health_check", "ok")]
        W.run_checks = rc
        return d, calls, (old_home, old_rc)

    def test_run_checks_once_when_done(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 40, "done")
            try:
                d.run()
            finally:
                L.HOME, W.run_checks = old
        self.assertEqual(d.s["status"], "done")
        self.assertEqual(len(calls), 1)                   # the exit hook ran run_checks exactly once
        self.assertIs(calls[0]["log"].__self__, d)        # called with the driver's own log

    def test_run_checks_once_when_blocked_and_hold_returns_false(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 41, "blocked")
            try:
                d.run()
            finally:
                L.HOME, W.run_checks = old
        self.assertEqual(d.s["status"], "blocked")
        self.assertFalse(d.hold_blocked())               # the blocker holds: no resume, the run ends blocked
        self.assertEqual(len(calls), 1)
        self.assertIs(calls[0]["log"].__self__, d)

    def test_run_checks_once_when_driver_raises(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 42, "raise")
            try:
                with self.assertRaises(RuntimeError) as e:
                    d.run()
                self.assertEqual(str(e.exception), "driver boom")   # the original driver exception is re-raised
            finally:
                L.HOME, W.run_checks = old
        self.assertEqual((d.s["status"], d.s["error"]), ("error", "driver boom"))
        self.assertEqual(len(calls), 1)
        self.assertIs(calls[0]["log"].__self__, d)

    def test_failing_run_checks_is_logged_and_does_not_change_end_status(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 43, "done", failing=True)
            try:
                d.run()                                   # the hook failure never escapes Driver.run
            finally:
                L.HOME, W.run_checks = old
            with open(os.path.join(d.run_dir, "driver.log")) as f:
                log = f.read()
            self.assertIn("watchdog exit hook failed: checks down", log)
        self.assertEqual(d.s["status"], "done")          # the run still ends with the same status
        self.assertEqual(len(calls), 1)

    def test_import_failure_never_raises_out_of_the_done_path(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 45, "done")
            try:
                with mock.patch.dict(sys.modules, {"watchdog": None}):    # `import watchdog` raises
                    d.run()                                               # the hook swallows it; the run ends done
            finally:
                L.HOME, W.run_checks = old
            with open(os.path.join(d.run_dir, "driver.log")) as f:
                log = f.read()
            self.assertIn("watchdog exit hook failed", log)
        self.assertEqual(d.s["status"], "done")
        self.assertEqual(calls, [])

    def test_import_failure_does_not_replace_the_driver_exception(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 46, "raise")
            try:
                with mock.patch.dict(sys.modules, {"watchdog": None}):
                    with self.assertRaises(RuntimeError) as e:
                        d.run()
                self.assertEqual(str(e.exception), "driver boom")   # still the original driver exception
            finally:
                L.HOME, W.run_checks = old
        self.assertEqual(d.s["status"], "error")
        self.assertEqual(calls, [])

    def test_hook_never_raises_even_when_logging_fails(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 47, "done", failing=True)
            real = d.log
            def log(line):
                if "watchdog exit hook" in line: raise IOError("driver.log is closed")
                real(line)
            d.log = log
            try:
                d.run()                                   # the failed log line never escapes Driver.run
            finally:
                L.HOME, W.run_checks = old
        self.assertEqual(d.s["status"], "done")
        self.assertEqual(len(calls), 1)

    def test_failing_run_checks_never_swallows_the_driver_exception(self):
        with tempfile.TemporaryDirectory() as h:
            d, calls, old = self._setup(h, 44, "raise", failing=True)
            try:
                with self.assertRaises(RuntimeError) as e:
                    d.run()
                self.assertEqual(str(e.exception), "driver boom")   # still the original driver exception
            finally:
                L.HOME, W.run_checks = old
            with open(os.path.join(d.run_dir, "driver.log")) as f:
                log = f.read()
            self.assertIn("driver error: driver boom", log)
            self.assertIn("watchdog exit hook failed: checks down", log)
        self.assertEqual(d.s["status"], "error")
        self.assertEqual(len(calls), 1)
