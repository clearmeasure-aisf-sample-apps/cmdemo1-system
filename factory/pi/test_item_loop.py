"""Unit tests of the Pi item driver's decision rules (no network, no Pi). Run: python3 -m unittest factory/pi/test_item_loop.py"""
import json, os, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_loop as L
import gpu as G

PLAN = {"repo": "cmdemo1-workorders", "issue": 1, "branch": "cm-ai-ops-bot/1-x", "files": ["src/A.cs"],
        "criteria": [{"text": "A works", "evidence_cmd": "dotnet test --filter A"}],
        "tasks": [{"name": "t1", "prompt": "Write test A"}], "verify_cmd": "dotnet build", "pr_title": "A"}

class Rules(unittest.TestCase):
    def test_infra_vs_code(self):
        self.assertEqual(L.classify_failure("curl: (6) Could not resolve host: api.nuget.org"), "infra")
        self.assertEqual(L.classify_failure("Error response from daemon: toomanyrequests"), "infra")
        self.assertEqual(L.classify_failure("src/A.cs(3,1): error CS1002: ; expected"), "code")
        self.assertEqual(L.classify_failure("Failed AcceptanceTests.Login test\nCould not resolve host"), "code")
        self.assertEqual(L.classify_failure("something odd"), "code")

    def test_trim_log_scrubs_and_keeps_errors(self):
        tok = "ghp_" + "a" * 30
        text = "\n".join(["noise"] * 500 + [f"token {tok}", "src/A.cs(1,1): error CS0103: x", "done"])
        out = L.trim_log(text)
        self.assertNotIn(tok, out); self.assertIn("error CS0103", out); self.assertLessEqual(len(out), 12000)

    def test_scrub_env_values(self):
        os.environ["LOCAL_LLM_PRO5000_URL"] = "https://example-tunnel.invalid/v1"
        try: self.assertNotIn("example-tunnel", L.scrub("base https://example-tunnel.invalid/v1/models"))
        finally: del os.environ["LOCAL_LLM_PRO5000_URL"]
        self.assertEqual(L.scrub("x https://a-b.trycloudflare.com/v1 y"), "x [redacted] y")

    def test_checks_state(self):
        req = ["Build result", "secret-scan"]
        self.assertEqual(L.checks_state([{"name": "Build result", "bucket": "pass"}, {"name": "secret-scan", "bucket": "pass"},
                                         {"name": "Qodana", "bucket": "fail"}], req), "GREEN")
        self.assertEqual(L.checks_state([{"name": "Build result", "bucket": "fail"}, {"name": "secret-scan", "bucket": "pass"}], req), "RED")
        self.assertEqual(L.checks_state([{"name": "Build result", "bucket": "pending"}, {"name": "secret-scan", "bucket": "pass"}], req), "PENDING")
        self.assertEqual(L.checks_state([{"name": "secret-scan", "bucket": "pass"}], req), "PENDING")
        self.assertEqual(L.checks_state([{"name": "a", "bucket": "pass"}, {"name": "b", "bucket": "fail"}], None), "RED")
        self.assertEqual(L.checks_state([], None), "PENDING")
        # a rerun that passed wins over the earlier failed attempt of the same check
        self.assertEqual(L.checks_state([{"name": "env-checks", "bucket": "pass"}, {"name": "env-checks", "bucket": "fail"}], ["env-checks"]), "GREEN")

    def test_validate_plan(self):
        self.assertEqual(L.validate_plan(PLAN), [])
        bad = dict(PLAN, branch="feature/x", tasks=[{"name": "t", "prompt": "then git push origin"}])
        errs = L.validate_plan(bad)
        self.assertTrue(any("branch" in e for e in errs)); self.assertTrue(any("commit, push" in e for e in errs))
        self.assertTrue(L.validate_plan(dict(PLAN, criteria=[{"text": "x"}])))
        self.assertTrue(L.validate_plan(dict(PLAN, issue=1918)))
        self.assertTrue(L.validate_plan(dict(PLAN, pr_title="token=abc123")))

    def test_docs_only(self):
        self.assertTrue(L.docs_only(["README.md", "docs/a.png"]))
        self.assertFalse(L.docs_only(["README.md", "src/A.cs"])); self.assertFalse(L.docs_only([]))

    def test_deploy_moves_never_skip_or_go_back(self):
        self.assertEqual(L.deploy_moves("Merged", {"tdd": True}), ["TDD"])
        self.assertEqual(L.deploy_moves("Merged", {"tdd": True, "uat": True, "prod": True}), ["TDD", "UAT", "Done"])
        self.assertEqual(L.deploy_moves("UAT", {"tdd": True, "uat": True}), [])
        self.assertEqual(L.deploy_moves("TDD", {"prod": True}), ["UAT", "Done"])
        self.assertEqual(L.deploy_moves("Merged", {}), [])

    def test_pickup_comment_shape(self):
        c = L.pickup_comment(PLAN, "run1", os.path.join(L.HOME, "factory-runs", "x"))
        self.assertTrue(c.startswith("Todo → In Progress\n\ncm-ai-ops-bot is taking this issue."))
        self.assertIn("`Docs-only: no`", c); self.assertIn("- [ ] A works", c); self.assertIn("~/factory-runs/x", c)

class NoIdleStall(unittest.TestCase):
    def test_quality_failures_route_qodana_and_refactoring_rationale(self):
        cs = [{"name": "Build result", "bucket": "pass"}, {"name": "Qodana", "bucket": "fail"},
              {"name": "Refactoring rationale", "bucket": "fail"}, {"name": "Qodana", "bucket": "pass"}]
        self.assertEqual(L.quality_failures(cs), ["Refactoring rationale"])   # the later Qodana pass wins
        self.assertEqual(L.quality_failures([{"name": "Build result", "bucket": "fail"}]), [])
        self.assertEqual(L.quality_failures([{"name": "Qodana code quality", "bucket": "cancel"}]), ["Qodana code quality"])

    def test_heartbeat_due_after_30_idle_minutes_once(self):
        t = L.now(); ago = lambda m: (t - L.dt.timedelta(minutes=m)).isoformat()
        self.assertFalse(L.heartbeat_due(ago(10), None, t))
        self.assertTrue(L.heartbeat_due(ago(31), None, t))
        self.assertFalse(L.heartbeat_due(ago(90), ago(5), t))      # one heartbeat per 30 min
        self.assertTrue(L.heartbeat_due(ago(90), ago(31), t))
        self.assertFalse(L.heartbeat_due(ago(90), None, t, minutes=120))
        self.assertFalse(L.heartbeat_due(None, None, t))

    def test_new_limits_are_bounded(self):
        self.assertEqual((L.LIMITS["quality_fix"], L.LIMITS["merge_gate"]), (3, 3))

    def test_blocker_records_resume_stage_and_dry_run_never_comments(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 8, dry_run=True); d.s.update(stage="ci", pr=5, start=L.iso())
                d.blocker("required checks still red."); self.assertEqual((d.s["resume_stage"], d.s["stage"]), ("ci", "blocked"))
                d.s["progress_at"] = (L.now() - L.dt.timedelta(minutes=45)).isoformat(); d.heartbeat()
                self.assertNotIn("heartbeat_at", d.s)   # dry-run posts nothing
                d.dry = False; d.sh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, "", ""); d.comment = lambda b, pr=False: setattr(d, "hb", b)
                d.heartbeat(); self.assertIn("no progress for 30+ min", d.hb); self.assertIn("required checks still red", d.hb)
            finally: L.HOME = old

class DryRunDriver(unittest.TestCase):
    def test_writes_are_skipped_in_dry_run(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 7, dry_run=True)
                r = d.sh(["false"], write=True)
                self.assertEqual(r.returncode, 0)
                self.assertIn("DRY-RUN skip", open(os.path.join(d.run_dir, "driver.log")).read())
                self.assertFalse(d.bump("review_fail") is False)   # 1 <= 2
                d.bump("review_fail"); self.assertFalse(d.bump("review_fail"))  # 3rd exceeds the limit of 2
            finally: L.HOME = old

class Gpus(unittest.TestCase):
    def test_secret_names_cover_three_gpus_and_keep_pro5000(self):
        self.assertEqual(G.env_names("pro5000"), ("LOCAL_LLM_PRO5000_URL", "LOCAL_LLM_PRO5000_TOKEN"))
        self.assertEqual(G.env_names("obs"), ("LOCAL_LLM_OBS_URL", "LOCAL_LLM_OBS_TOKEN"))
        self.assertEqual(G.env_names("ts3"), ("LOCAL_LLM_TS3_URL", "LOCAL_LLM_TS3_TOKEN"))
        self.assertEqual(list(G.GPUS), ["pro5000", "obs", "ts3"]); self.assertEqual(G.MODEL, "auto")
        self.assertEqual((G.GPUS["pro5000"]["ctx"], G.GPUS["obs"]["ctx"], G.GPUS["ts3"]["ctx"]), (262144, 65536, 65536))
        self.assertIn("LOCAL_LLM_X9_TOKEN", G.secret_env_names({"LOCAL_LLM_X9_TOKEN": "v"}))

    def test_size_classification(self):
        self.assertEqual(G.classify_size({"files": ["src/UI/Client/Pages/Board.razor", "src/UnitTests/BoardTests.cs"]}), "small")
        self.assertEqual(G.classify_size({"files": ["src/Database/scripts/Update/010.sql"]}), "large")
        self.assertEqual(G.classify_size({"files": [f"src/A{i}/x.cs" for i in range(6)]}), "large")
        self.assertEqual(G.classify_size({"files": ["src/Core/A.cs", "src/UI/B.razor", "src/DataAccess/C.cs"]}), "large")
        self.assertEqual(G.classify_size({"files": ["src/Database/x.sql"], "size": "small"}), "small")

    def test_pick_gpu_pro5000_first_then_obs_then_ts3(self):
        up = ["pro5000", "obs", "ts3"]
        self.assertEqual(G.PRIORITY, ("pro5000", "obs", "ts3"))
        for size in ("small", "large"): self.assertEqual(G.pick_gpu(size, up, set()), "pro5000")
        self.assertEqual(G.pick_gpu("small", up, {"pro5000"}), "obs")             # pro5000 slots full
        self.assertEqual(G.pick_gpu("small", up, {"pro5000", "obs"}), "ts3")      # ts3 only when both are busy
        self.assertIsNone(G.pick_gpu("small", up, {"pro5000", "obs", "ts3"}))
        self.assertIsNone(G.pick_gpu("large", up, {"pro5000"}))                   # long context waits for pro5000
        self.assertEqual(G.pick_gpu("large", ["obs", "ts3"], set()), "obs")       # pro5000 down: fall back
        self.assertEqual(G.pick_gpu("small", ["obs", "ts3"], {"obs"}), "ts3")
        self.assertIsNone(G.pick_gpu("small", [], set()))

    def test_client_timeout_floor_is_300s(self):
        self.assertGreaterEqual(G.MIN_CLIENT_TIMEOUT_S, 300)

    def test_reviewer_is_a_different_gpu(self):
        self.assertEqual(G.reviewer_gpu("obs", ["pro5000", "obs", "ts3"]), "pro5000")
        self.assertEqual(G.reviewer_gpu("pro5000", ["pro5000", "obs", "ts3"]), "obs")
        self.assertEqual(G.reviewer_gpu("pro5000", ["pro5000", "ts3"]), "ts3")
        self.assertIsNone(G.reviewer_gpu("obs", ["obs"]))

    def test_health_missing_or_down_is_unavailable_not_fatal(self):
        class R:
            def __init__(self, code, body): self.status, self._b = code, body
            def read(self): return self._b
            def __enter__(self): return self
            def __exit__(self, *a): return False
        seen = []
        def opener(req, timeout):
            seen.append((req.full_url, req.get_method()))
            if "obs" in req.full_url: raise OSError("no route")
            return R(200, json.dumps({"data": [{"id": "some-loaded-model"}]}).encode())
        env = {"LOCAL_LLM_PRO5000_URL": "https://p.invalid/v1", "LOCAL_LLM_PRO5000_TOKEN": "t1",
               "LOCAL_LLM_OBS_URL": "https://obs.invalid/v1/", "LOCAL_LLM_OBS_TOKEN": "t2"}
        h = G.health(env=env, opener=opener)
        self.assertEqual({g: st for g, (st, _) in h.items()}, {"pro5000": "HEALTHY", "obs": "UNREACHABLE", "ts3": "MISSING_SECRETS"})
        self.assertEqual(G.available(h), ["pro5000"]); self.assertEqual(G.health_exit(h), 0)
        self.assertEqual(seen, [("https://p.invalid/v1/models", "GET"), ("https://obs.invalid/v1/models", "GET")])  # models list only
        self.assertTrue(all("t1" not in d and "t2" not in d and "invalid" not in d for _, d in h.values()))
        self.assertEqual(G.health_exit(G.health(env={}, opener=opener)), 3)
        self.assertEqual(G.health_exit({"pro5000": ("UNREACHABLE", ""), "obs": ("MISSING_SECRETS", ""), "ts3": ("REFUSED", "")}), 4)

class GpuResume(unittest.TestCase):   # bug (a): a resumed item keeps the GPU recorded in state.json, never a silent pro5000 default
    class _Clock:  # fake time module: one sleep() jumps past GPU_WAIT_H so st_gpu's wait loop exits after one iteration
        def __init__(self, t=1e9): self.t = float(t)
        def time(self): return self.t
        def sleep(self, s): self.t += L.GPU_WAIT_H * 3600 + 1

    def test_gpu_raises_when_unrecorded(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 21, dry_run=True)
                self.assertNotIn("gpu", d.s)
                self.assertRaises(RuntimeError, d.gpu)   # no gpu in state: raise, never default to pro5000
                d.s["gpu"] = "obs"; d.save()
                self.assertEqual(d.gpu(), "obs")
            finally: L.HOME = old

    def test_resumed_item_keeps_its_gpu_and_waits(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME, L.gpu_health, L.time
            L.HOME = h; L.time = self._Clock()
            try:
                d = L.Driver("cmdemo1-workorders", 22)   # dry_run=False
                d.s["plan"] = dict(PLAN, size="large"); d.s["gpu"] = "obs"; d.s["stage"] = "gpu"; d.save()
                L.gpu_health = lambda max_age=600: {"obs": ("UNREACHABLE", "down"), "pro5000": ("HEALTHY", ""), "ts3": ("HEALTHY", "")}
                d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
                d.st_gpu()
                self.assertEqual(d.s["gpu"], "obs")      # not re-picked to pro5000 or anything else
                self.assertEqual(d.s["stage"], "blocked")
                self.assertIn("obs", d.s["blocker"])     # it waited for its own GPU, bounded by GPU_WAIT_H
            finally: L.HOME, L.gpu_health, L.time = old

    def test_new_item_picks_and_persists_its_gpu(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME, L.gpu_health, L.time
            L.HOME = h; L.time = self._Clock()
            try:
                d = L.Driver("cmdemo1-workorders", 23, dry_run=True)
                d.s["plan"] = PLAN; d.save()              # no 'gpu' in state yet
                L.gpu_health = lambda max_age=600: {g: ("HEALTHY", "") for g in ("pro5000", "obs", "ts3")}
                d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
                d.st_gpu()
                self.assertEqual(d.s["stage"], "pickup")
                self.assertEqual(d.s["gpu"], G.pick_gpu(G.classify_size(PLAN), ["pro5000", "obs", "ts3"], set()))
            finally: L.HOME, L.gpu_health, L.time = old

    def test_pi_targets_the_recorded_gpu(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 24, dry_run=True)
                d.s["gpu"] = "ts3"; d.s["wt"] = tempfile.mkdtemp(dir=h)
                capture = []
                d.sh = lambda cmd, **k: (capture.append(list(cmd)), subprocess.CompletedProcess(cmd, 0, "PASS", ""))[1]
                d.pi("t1", "do it")
                self.assertIn("--gpu", capture[0])
                self.assertEqual(capture[0][capture[0].index("--gpu") + 1], "ts3")
            finally: L.HOME = old

class TaskRetry(unittest.TestCase):   # bug (b): a failed Pi task must not be marked done: retry it under distinct names, then a Blocker
    def test_failed_pi_task_not_done_retried_then_blocked(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 25, dry_run=True)
                d.s["plan"] = dict(PLAN, tasks=[{"name": "t1", "prompt": "p"}])
                d.s["stage"] = "implement"
                d.s["wt"] = tempfile.mkdtemp(dir=h)
                calls = []
                d.pi = lambda name, prompt, timeout=1800, gpu=None: (calls.append(name), False)[1]
                d.st_implement()
                self.assertEqual(d.s.get("tasks_done", []), [])   # a failed task is never recorded done
                self.assertEqual(len(calls), L.LIMITS["local_fix"] + 1)   # retried up to the limit
                self.assertEqual(d.s["stage"], "blocked")
                self.assertNotEqual(d.s["stage"], "local-verify")
                self.assertIn("t1", d.s["blocker"])
                self.assertEqual(calls[0], "t1")
                self.assertTrue(all(n != "t1" for n in calls[1:]) and any("retry" in n.lower() for n in calls[1:]),
                                "retries run under distinct retry names")
            finally: L.HOME = old

    def test_passing_pi_task_done_and_advances(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 26, dry_run=True)
                d.s["plan"] = dict(PLAN, tasks=[{"name": "t1", "prompt": "p"}])
                d.s["stage"] = "implement"
                d.s["wt"] = tempfile.mkdtemp(dir=h)
                d.pi = lambda name, prompt, timeout=1800, gpu=None: True
                d.st_implement()
                self.assertEqual(d.s["tasks_done"], ["t1"])   # a passing task lands in tasks_done
                self.assertEqual(d.s["stage"], "local-verify")   # and the stage advances as before
            finally: L.HOME = old

    def test_pi_task_retried_until_pass(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 27, dry_run=True)
                d.s["plan"] = dict(PLAN, tasks=[{"name": "t1", "prompt": "p"}])
                d.s["stage"] = "implement"
                d.s["wt"] = tempfile.mkdtemp(dir=h)
                calls = []
                d.pi = lambda name, prompt, timeout=1800, gpu=None: (calls.append(name), len(calls) > 1)[1]   # fails exactly once
                d.st_implement()
                self.assertEqual(d.s["tasks_done"], ["t1"])
                self.assertEqual(d.s["stage"], "local-verify")
                self.assertEqual(len(calls), 2)
                self.assertNotEqual(calls[1], "t1")
                self.assertIn("retry", calls[1].lower())
            finally: L.HOME = old

class Concurrency(unittest.TestCase):
    def test_one_active_item_per_gpu_and_wip_three_per_repo(self):
        alive = lambda pid: pid != 9
        st = [("a", {"repo": "cmdemo1-workorders", "gpu": "pro5000", "stage": "ci", "pid": 1}),
              ("b", {"repo": "cmdemo1-workorders", "gpu": "obs", "stage": "deploy", "pid": 2}),        # past merge: frees GPU
              ("c", {"repo": "cmdemo1-workorders", "gpu": "ts3", "stage": "implement", "pid": 9}),     # dead driver
              ("d", {"repo": "cmdemo1-workorders", "gpu": "obs", "stage": "blocked", "resume_stage": "ci", "pid": 4}),
              ("e", {"repo": "cmdemo1-dashboard", "gpu": "ts3", "stage": "review", "pid": 5})]
        self.assertEqual(L.busy_gpus(st, None, alive), {"ts3"})        # pro5000 has 2 slots, only 1 held
        self.assertEqual(L.busy_gpus(st + [("f", {"gpu": "pro5000", "stage": "ci", "pid": 6})], None, alive), {"pro5000", "ts3"})
        self.assertEqual(L.busy_gpus(st, "a", alive), {"ts3"})
        self.assertEqual(L.repo_wip(st, "cmdemo1-workorders", None, alive), 2)   # a (ci) + d (blocked in review)
        self.assertEqual(L.repo_wip(st, "cmdemo1-dashboard", None, alive), 1)
        self.assertEqual(L.WIP_LIMIT, 3)
        self.assertEqual((L.wip_limit("cmdemo1-dashboard"), L.wip_limit("cmdemo1-workorders"), L.wip_limit("cmdemo1-system")), (5, 3, 3))

    def test_intake_stops_while_red_except_fix_forward(self):
        self.assertTrue(L.intake_open({}, PLAN))
        self.assertFalse(L.intake_open({"cmdemo1-workorders main": {"what": "Build red"}}, PLAN))
        self.assertTrue(L.intake_open({"ui prod": {"what": "x"}}, dict(PLAN, fix_forward=True)))

    def test_red_flags_round_trip(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                L.red_set("ui uat", "unhealthy"); L.red_set("ui uat", "again")
                self.assertEqual(L.red_load()["ui uat"]["what"], "unhealthy")   # first report kept
                L.red_clear("ui uat"); self.assertEqual(L.red_load(), {})
            finally: L.HOME = old

    def test_env_red(self):
        e = {"name": "uat", "health": {"containerApps": [{"name": "ui", "last": {"result": "unhealthy"}}]}}
        self.assertTrue(L.env_red(e, "ui")); self.assertFalse(L.env_red(e, "dashboard")); self.assertFalse(L.env_red(e, "system"))
        self.assertFalse(L.env_red({"health": {"containerApps": [{"name": "ui", "last": {"result": "healthy"}}]}}, "ui"))

class Gates(unittest.TestCase):
    def test_quality_checks_are_hard_merge_gates(self):
        req = ["Build result", "secret-scan"]; ok = [{"name": "Build result", "bucket": "pass"}, {"name": "secret-scan", "bucket": "pass"}]
        self.assertEqual(L.gate_state(ok, req), "GREEN")
        self.assertEqual(L.gate_state(ok + [{"name": "Qodana", "bucket": "pass"}, {"name": "Refactoring rationale", "bucket": "pass"}], req), "GREEN")
        self.assertEqual(L.gate_state(ok + [{"name": "Qodana", "bucket": "fail"}], req), "RED")
        self.assertEqual(L.gate_state(ok + [{"name": "Refactoring rationale", "bucket": "pending"}], req), "PENDING")
        self.assertEqual(L.gate_state([{"name": "Build result", "bucket": "fail"}, {"name": "secret-scan", "bucket": "pass"}], req), "RED")

    def test_merge_is_squash_pinned_and_never_deletes_the_branch(self):
        a = L.merge_args("o/r", 5, "abc")
        self.assertIn("--squash", a); self.assertEqual(a[a.index("--match-head-commit") + 1], "abc")
        self.assertNotIn("--delete-branch", a); self.assertNotIn("-d", a)

    def test_hands_off_and_protected_files(self):
        for repo, n in (("cmdemo1-system", 654), ("cmdemo1-workorders", 1875), ("cmdemo1-workorders", 1876)):
            self.assertTrue(any("hands-off" in e for e in L.validate_plan(dict(PLAN, repo=repo, issue=n))))
        enh = dict(PLAN, kind="enhancement", files=["src/A.cs", ".github/workflows/build.yml", "environments/prod/x.json"])
        self.assertTrue(any("production setup" in e for e in L.validate_plan(enh)))
        self.assertEqual(L.validate_plan(dict(PLAN, kind="enhancement")), [])
        self.assertEqual(L.protected_files(["src/UI/Board.razor", "infra/main.bicep", "src/appsettings.Production.json"]),
                         ["infra/main.bicep", "src/appsettings.Production.json"])

class GhRateLimit(unittest.TestCase):
    def setUp(self):   # whole waits per sleep() call unless a test sets the tick itself
        self.saved = (L.GH_RETRY_TICK_S, L.GH_RETRY_MAX_ATTEMPTS, L.GH_RETRY_MAX_WAIT_S)
        L.GH_RETRY_TICK_S = 10 ** 6
    def tearDown(self):
        L.GH_RETRY_TICK_S, L.GH_RETRY_MAX_ATTEMPTS, L.GH_RETRY_MAX_WAIT_S = self.saved

    def run_gh(self, replies, issue=8):
        """Call d.gh() with subprocess.run returning `replies` in order (last one repeats); returns (result|exc, calls, sleeps, driver)."""
        with tempfile.TemporaryDirectory() as h:
            old_home, old_run, old_sleep = L.HOME, L.subprocess.run, L.time.sleep
            L.HOME = h
            calls, sleeps = [0], []
            def fake_run(*a, **k):
                rc, out = replies[min(calls[0], len(replies) - 1)]; calls[0] += 1
                return L.subprocess.CompletedProcess(a, rc, out, "")
            L.subprocess.run, L.time.sleep = fake_run, sleeps.append
            try:
                d = L.Driver("cmdemo1-workorders", issue)
                try: res = d.gh("pr", "list")
                except RuntimeError as e: res = e
            finally:
                L.subprocess.run, L.time.sleep, L.HOME = old_run, old_sleep, old_home
        return res, calls[0], sleeps, d

    def test_is_rate_limit_matches_real_gh_errors_only(self):
        for real in ("GraphQL: API rate limit already exceeded for user ID 337178629.",
                     "GraphQL: API rate limit exceeded for user ID 1.",
                     "HTTP 403: API rate limit exceeded for user ID 1. (https://api.github.com/repos/x/y/pulls)",
                     "HTTP 403: You have exceeded a secondary rate limit and have been temporarily blocked.",
                     "HTTP 429: Secondary rate limit in effect. Please try again.",
                     "some progress\nGraphQL: API rate limit exceeded for user ID 1.\n"):
            self.assertTrue(L.is_rate_limit(real), real)
        dump = "\n".join(["build\t2026-11-21T19:00:00Z HTTP 403: API rate limit exceeded",
                            "step\tGraphQL: API rate limit exceeded"] + ["noise"] * 10 + ["HTTP 404: Not Found"])
        for fake in (dump, "Error response from daemon: toomanyrequests", "the api rate limit exceeded doc page",
                     "test asserts 'secondary rate limit' handling", "", None):
            self.assertFalse(L.is_rate_limit(fake), fake)

    def test_log_dump_mentioning_rate_limit_is_not_retried(self):
        dump = "\n".join(["job\tstep\tGraphQL: API rate limit exceeded for user ID 1."] + ["x"] * 20 + ["exit status 1"])
        res, calls, sleeps, _ = self.run_gh([(1, dump)])
        self.assertIsInstance(res, RuntimeError); self.assertEqual(calls, 1); self.assertEqual(sleeps, [])

    def test_gh_retry_capped_by_max_attempts(self):
        L.GH_RETRY_MAX_ATTEMPTS, L.GH_RETRY_MAX_WAIT_S = 4, 10 ** 6
        res, calls, sleeps, _ = self.run_gh([(1, "GraphQL: API rate limit exceeded for user ID 1.")])
        self.assertIsInstance(res, RuntimeError)   # gives up and fails like any other gh error
        self.assertEqual(calls, 5); self.assertEqual(sleeps, [60, 120, 240, 600])

    def test_gh_retry_capped_by_max_total_wait(self):
        L.GH_RETRY_MAX_ATTEMPTS, L.GH_RETRY_MAX_WAIT_S = 100, 1000
        res, calls, sleeps, _ = self.run_gh([(1, "HTTP 403: API rate limit exceeded for user ID 1.")])
        self.assertIsInstance(res, RuntimeError)
        self.assertEqual(sleeps, [60, 120, 240])   # a 4th wait (600) would pass 1000s in total
        self.assertEqual(calls, 4)

    def test_default_caps_bound_the_wait(self):
        waits, a, w = [], 0, 0
        while (x := L.gh_retry_wait(a, w)) is not None: waits.append(x); a += 1; w += x
        self.assertLessEqual(len(waits), L.GH_RETRY_MAX_ATTEMPTS); self.assertLessEqual(sum(waits), L.GH_RETRY_MAX_WAIT_S)
        self.assertGreater(len(waits), 0)

    def test_state_stays_alive_while_waiting(self):
        L.GH_RETRY_TICK_S = 50
        seen = []
        rl = (1, "GraphQL: API rate limit exceeded for user ID 1.")
        res, calls, sleeps, d = self.run_gh([rl, rl, (0, "42")])
        self.assertEqual(res.returncode, 0)
        self.assertEqual(sleeps, [50, 10, 50, 50, 20])   # 60s and 120s waits, re-saving state every 50s
        self.assertNotIn("gh_wait", d.s)                 # cleared once gh answered
        with tempfile.TemporaryDirectory() as h:
            old_home, old_sleep = L.HOME, L.time.sleep
            L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 9)
                L.time.sleep = lambda s: seen.append(json.load(open(d.state_p)))
                d.wait_alive(120, "gh rate limit, retry 1")
            finally: L.time.sleep, L.HOME = old_sleep, old_home
        self.assertEqual(len(seen), 3)
        self.assertTrue(all(x["gh_wait"]["why"] == "gh rate limit, retry 1" and x["pid"] == os.getpid() for x in seen))
        self.assertTrue(seen[0]["gh_wait"]["until"] >= seen[-1]["gh_wait"]["until"])

    def test_non_rate_limit_failure_still_raises(self):
        with tempfile.TemporaryDirectory() as h:
            old_home, old_run, old_sleep = L.HOME, L.subprocess.run, L.time.sleep
            L.HOME = h
            calls, sleeps = [0], []
            try:
                def fake_run(*a, **k):
                    calls[0] += 1
                    return L.subprocess.CompletedProcess(a, 1, "HTTP 404: Not Found", "")
                def fake_sleep(s): sleeps.append(s)
                L.subprocess.run = fake_run
                L.time.sleep = fake_sleep
                d = L.Driver("cmdemo1-workorders", 8)
                with self.assertRaises(RuntimeError):
                    d.gh("pr", "list")
            finally:
                L.subprocess.run, L.time.sleep, L.HOME = old_run, old_sleep, old_home
        self.assertEqual(calls[0], 1)   # non-rate-limit failures are never retried
        self.assertEqual(sleeps, [])

    def test_gh_retries_rate_limit_with_backoff_then_succeeds(self):
        with tempfile.TemporaryDirectory() as h:
            old_home, old_run, old_sleep = L.HOME, L.subprocess.run, L.time.sleep
            L.HOME = h
            calls, sleeps = [0], []
            try:
                def fake_run(*a, **k):
                    calls[0] += 1
                    if calls[0] <= 2:
                        return L.subprocess.CompletedProcess(a, 1, "HTTP 403: API rate limit exceeded", "")
                    return L.subprocess.CompletedProcess(a, 0, "42", "")
                def fake_sleep(s): sleeps.append(s)
                L.subprocess.run = fake_run
                L.time.sleep = fake_sleep
                d = L.Driver("cmdemo1-workorders", 8)
                self.assertEqual(d.gh("pr", "list").returncode, 0)   # a later try succeeds; no raise
            finally:
                L.subprocess.run, L.time.sleep, L.HOME = old_run, old_sleep, old_home
        self.assertEqual(calls[0], 3)             # two rate-limited tries, then the success
        self.assertEqual(sleeps, [60, 120])       # backoff before each retry

    def test_gh_waits_until_reset_after_backoff(self):
        with tempfile.TemporaryDirectory() as h:
            old_home, old_run, old_sleep = L.HOME, L.subprocess.run, L.time.sleep
            L.HOME = h
            calls, sleeps = [0], []
            try:
                def fake_run(*a, **k):
                    calls[0] += 1
                    if calls[0] <= 5:
                        return L.subprocess.CompletedProcess(a, 1, "HTTP 403: Secondary rate limit in effect. Please try again.", "")
                    return L.subprocess.CompletedProcess(a, 0, "42", "")
                def fake_sleep(s): sleeps.append(s)
                L.subprocess.run = fake_run
                L.time.sleep = fake_sleep
                d = L.Driver("cmdemo1-workorders", 8)
                self.assertEqual(d.gh("pr", "list").returncode, 0)
            finally:
                L.subprocess.run, L.time.sleep, L.HOME = old_run, old_sleep, old_home
        self.assertEqual(calls[0], 6)
        self.assertEqual(sleeps, [60, 120, 240, 600, 600])   # backoff first, then 600s waits until the limit resets

    def test_pr_number_ignores_non_numeric(self):
        for bad in ("", "not a number", "HTTP 404: Not Found", "42abc", None):
            self.assertIsNone(L.pr_number(bad))
        self.assertEqual(L.pr_number("42"), 42)
        self.assertEqual(L.pr_number(" 42 "), 42)

    def test_st_pr_survives_non_numeric_pr_list_and_creates(self):
        with tempfile.TemporaryDirectory() as h:
            old_home = L.HOME
            L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 30, dry_run=True)
                d.s["plan"] = PLAN
                d.s["wt"] = tempfile.mkdtemp(dir=h)
                d.s["default"] = "main"
                d.s["gpu"] = "obs"
                d.s["run_id"] = "run30"
                calls = []
                def fake_sh(cmd, **k):
                    calls.append(list(cmd))
                    if cmd[0] == "gh":
                        if "list" in cmd:   # gh pr list printed a non-numeric, non-rate-limit message
                            return L.subprocess.CompletedProcess(cmd, 0, "no open PR for that head", "")
                        if "create" in cmd:
                            return L.subprocess.CompletedProcess(cmd, 0, "https://github.com/x/cmdemo1-workorders/pull/42", "")
                        if "graphql" in cmd:
                            return L.subprocess.CompletedProcess(cmd, 0, "{\"data\": null}", "")
                    if cmd[0] == "git":
                        return L.subprocess.CompletedProcess(cmd, 0, "abc123def" if "rev-parse" in cmd else "", "")
                    return L.subprocess.CompletedProcess(cmd, 0, "", "")
                d.sh = fake_sh
                d.usage = lambda final=False: "usage"
                d.st_pr()                       # no ValueError from the non-numeric list output
                self.assertEqual(d.s["pr"], 42)  # it went on to creating the PR
                self.assertEqual(d.s["stage"], "ci")
            finally:
                L.HOME = old_home
        self.assertTrue(any("list" in c for c in calls))
        self.assertTrue(any("create" in c for c in calls))

class RefactoringResearch(unittest.TestCase):
    GOOD = ("## Refactoring research\n\n- `src/A.cs` `Save()`: 80-line method with duplicated validation; extract a "
            "specification object (in scope).\n- `src/A.cs` `status` strings: primitive obsession; a value object would "
            "make the rules explicit (follow-up: filed).\n- Tests build data by hand; an ObjectMother would keep them short.\n\n"
            "In scope: extract the specification. Follow-up: status value object.")

    def test_research_must_be_present_and_substantive(self):
        self.assertTrue(L.research_ok(self.GOOD, ["src/A.cs"]))
        self.assertFalse(L.research_ok("Closes #1", ["src/A.cs"]))
        self.assertFalse(L.research_ok("## Refactoring research\n\n- none", ["src/A.cs"]))
        self.assertFalse(L.research_ok(self.GOOD.replace("src/A.cs", "src/B.cs"), ["src/A.cs"]))   # names no touched file

    def test_pr_body_gets_exactly_one_section(self):
        b = L.with_research("Closes #1\n\n<!-- m -->\n", self.GOOD)
        self.assertEqual(b.count("## Refactoring research"), 1); self.assertTrue(b.startswith("Closes #1"))
        b2 = L.with_research(b + "\n## Refactoring plan\n\nshrink\n", self.GOOD + "\n- extra finding about src/A.cs")
        self.assertEqual(b2.count("## Refactoring research"), 1); self.assertIn("extra finding", b2); self.assertIn("## Refactoring plan", b2)
        self.assertTrue(L.research_ok(b2, ["src/A.cs"]))

    def test_followups_are_deduped_and_capped(self):
        items = [{"title": "Refactor: status value object", "body": "b"}, {"title": "Refactor: dup", "body": "b"},
                 {"title": "refactor: STATUS value object", "body": "b"}, {"title": "", "body": "b"}, {"title": "no body"}]
        self.assertEqual([x["title"] for x in L.new_followups(items, ["Refactor: dup"])], ["Refactor: status value object"])
        many = [{"title": f"Refactor {i}", "body": "b"} for i in range(9)]
        self.assertEqual(len(L.new_followups(many, [])), L.FOLLOWUP_MAX)

    def test_research_prompt_names_patterns_and_outputs(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 9, dry_run=True); d.s["plan"] = PLAN
                out, fu, prompt = d.research_prompt()
                for w in ("duplication", "long methods", "primitive obsession", "missing abstractions", "strategy", "specification",
                          "ObjectMother", "query / command", "## Refactoring research", "follow-up", out, fu, "src/A.cs"):
                    self.assertIn(w, prompt)
                self.assertTrue(out.startswith(d.run_dir) and fu.startswith(d.run_dir))   # outside the worktree
            finally: L.HOME = old

class Scrubbing(unittest.TestCase):
    def test_tunnel_hosts_and_every_gpu_secret_are_redacted(self):
        for host in ("pro5000", "5070ti", "5060ti"):
            out = L.scrub(f"GET https://{host}.clearmeasure.ai/v1/models -> 200; host {host}.clearmeasure.ai")
            self.assertNotIn(f"{host}.clearmeasure.ai", out); self.assertIn("[redacted]", out)
        fake = lambda c: "fake" + c * 12   # built at run time so the secret scan sees no literal
        env = {"LOCAL_LLM_OBS_TOKEN": fake("o"), "LOCAL_LLM_TS3_TOKEN": fake("t"), "LOCAL_LLM_TS3_URL": "https://other.example.invalid/v1"}
        old = {k: os.environ.get(k) for k in env}; os.environ.update(env)
        try:
            out = L.scrub(f"a {fake('o')} b {fake('t')} c https://other.example.invalid/v1/models")
            for v in env.values(): self.assertNotIn(v, out)
        finally:
            for k, v in old.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
        self.assertEqual(L.scrub("Authorization: Bearer abcdef123"), "Authorization: [redacted]")
        self.assertEqual(L.scrub("see https://github.com/x/y/pull/1"), "see https://github.com/x/y/pull/1")

    def test_run_task_uses_the_shared_scrub(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-task")).read()
        self.assertIn("from item_loop import scrub", src); self.assertIn('"--gpu"', src)

class UsageReport(unittest.TestCase):
    def test_report_lists_grok_sessions_driver_and_pi(self):
        with tempfile.TemporaryDirectory() as d:
            json.dump({"start": "2026-11-19T05:00:00+00:00", "top_sessions": ["grok-a", "grok-b"], "driver_run_id": "drv1",
                       "pi_version": "1.5.2"}, open(os.path.join(d, "run.json"), "w"))
            open(os.path.join(d, "tasks.jsonl"), "w").write(json.dumps({"task": "t1", "session_id": "pi-1", "result": "PASS", "turns": 3,
                "input": 1000, "cacheRead": 5000, "output": 200, "wall_s": 61}) + "\n")
            out = subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage-report"), "--run-dir", d, "--final"],
                                 capture_output=True, text=True, check=True).stdout
            for s in ("`grok-a`, `grok-b`", "`drv1`", "`pi-1`", "1,000 + 5,000", "1m01s", "Total (1 Pi session)"): self.assertIn(s, out)
            self.assertNotIn("(progress)", out)

if __name__ == "__main__": unittest.main()
