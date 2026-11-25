"""Unit tests of the Pi item driver's decision rules (no network, no Pi). Run: python3 -m unittest factory/pi/test_item_loop.py"""
import argparse, fcntl, importlib.machinery, importlib.util, inspect, json, os, re, shutil, signal, subprocess, sys, tempfile, threading, time, unittest
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_loop as L
import gpu as G
import contextlib

PLAN = {"repo": "cmdemo1-workorders", "issue": 1, "branch": "cm-ai-ops-bot/1-x", "files": ["src/A.cs"],
        "criteria": [{"text": "A works", "evidence_cmd": "dotnet test --filter A"}],
        "tasks": [{"name": "t1", "prompt": "Write test A"}], "verify_cmd": "dotnet build", "pr_title": "A"}

@contextlib.contextmanager
def fake_home():
    """Create a TemporaryDirectory, set L.HOME to it, yield the path, restore on exit."""
    old = L.HOME
    with tempfile.TemporaryDirectory() as td:
        L.HOME = td
        try:
            yield td
        finally:
            L.HOME = old

@contextlib.contextmanager
def patched_driver_env(run=None, sleep=None, gpu_health=None, time=None, gpu_for_item=None, research_ok=None):
    """fake_home() plus, when given, L.subprocess.run and L.run_cmd = run (Driver.sh calls the latter) and L.time.sleep = sleep, and the item_loop module
    attributes named gpu_health, time, gpu_for_item and research_ok set to the values passed (None leaves an
    attribute unchanged); yields fake_home's temp dir path and restores every patched attribute in a finally
    block (fake_home restores L.HOME)."""
    old_run, old_run_cmd, old_sleep = L.subprocess.run, L.run_cmd, L.time.sleep
    overrides = {"gpu_health": gpu_health, "time": time, "gpu_for_item": gpu_for_item, "research_ok": research_ok}
    old = {name: getattr(L, name) for name, v in overrides.items() if v is not None}
    with fake_home() as h:
        if run is not None: L.subprocess.run = L.run_cmd = run
        if sleep is not None: L.time.sleep = sleep
        for name, v in overrides.items():
            if v is not None: setattr(L, name, v)
        try:
            yield h
        finally:
            for name in reversed(old): setattr(L, name, old[name])
            L.subprocess.run, L.run_cmd = old_run, old_run_cmd
            L.time.sleep = old_sleep

@contextlib.contextmanager
def fake_modules(swaps):
    """Shared save/swap/restore: `swaps` maps (module, "attribute") to the value it holds for the block --
    fake_modules({(L, "HOME"): home, (W.time, "sleep"): lambda s: None}) -- and puts every original value back in a
    finally, in reverse order, whether the block raises or not. The one replacement for the
    `old = X.a; X.a = fake; try: ... finally: X.a = old` scaffolding (#940); it covers any attribute of any module,
    so a test can patch item_loop and watchdog in one line, which fake_home and patched_driver_env cannot.
    An attribute that does not already exist raises AttributeError instead of being created, so a typo fails loudly."""
    old = [(obj, name, getattr(obj, name)) for obj, name in swaps]
    try:
        for (obj, name), value in swaps.items():
            setattr(obj, name, value)
        yield
    finally:
        for obj, name, value in reversed(old):
            setattr(obj, name, value)

def make_driver(issue=1, repo="cmdemo1-workorders", dry_run=True, **kw):
    """Create a standard test Driver; dry_run is explicit so callers can opt out."""
    return L.Driver(repo, issue, dry_run=dry_run, **kw)

class FakeGhProcess:   # scripted subprocess for Driver.gh() (#936): one query/command object the gh test classes share
    def __init__(self, replies, capture=None):
        """Answers from `replies` -- an ordered list of (returncode, stdout) pairs, the last one repeating -- wrapped in
        L.subprocess.CompletedProcess exactly as the real runner's result is read. When `capture` is a list it receives
        the kwargs of every call; when callable it is called with them. .calls counts the calls made."""
        self.replies, self.capture, self.calls = list(replies), capture, 0
    def __call__(self, *a, **k):
        if self.capture is not None:
            if isinstance(self.capture, list): self.capture.append(k)
            else: self.capture(k)
        rc, out = self.replies[min(self.calls, len(self.replies) - 1)]
        self.calls += 1
        return L.subprocess.CompletedProcess(a, rc, out, "")

HDR = '{"type": "session", "id": "s1"}'                                  # Pi session records (one JSON object per line)
USER = '{"type": "message", "message": {"role": "user", "content": "do it"}}'
ASSISTANT = '{"type": "message", "message": {"role": "assistant", "usage": {"input": 1, "output": 1}}}'

class Clock:  # fake time module: one sleep() jumps past GPU_WAIT_H so st_gpu's wait loop exits after one iteration
    def __init__(self, t=1e9): self.t = float(t)
    def time(self): return self.t
    def sleep(self, s): self.t += L.GPU_WAIT_H * 3600 + 1

def scripted_sh(replies):
    """sh replacement for git/gh steps: a reply key is a command word or a run of consecutive words ('merge-base',
    'diff --cached', 'rev-parse', 'create') matched against the argv only, never against a commit message or a
    branch name. The first matching key answers; its value is the stdout, or a (returncode, stdout) pair when the
    command must fail. Every command is recorded in the callable's .calls list."""
    calls = []
    def sh(cmd, **k):
        calls.append(list(cmd))
        argv = cmd.split() if isinstance(cmd, str) else [str(x) for x in cmd]
        for key, reply in replies.items():
            words = key.split()
            if any(argv[i:i + len(words)] == words for i in range(len(argv) - len(words) + 1)):
                rc, stdout = reply if isinstance(reply, tuple) else (0, reply)
                return L.subprocess.CompletedProcess(cmd, rc, stdout, "")
        return L.subprocess.CompletedProcess(cmd, 0, "", "")
    sh.calls = calls
    return sh

@contextlib.contextmanager
def patch_run(fake):
    """Install `fake` as BOTH subprocess entry points item_loop could use -- L.subprocess.run and the shared
    item_loop.run_cmd (#839) -- for the block, restoring both in `finally`. A gh fake written against either one keeps
    working when Driver.sh moves to the other. `fake` is called the way both callers call it: the command positionally,
    plus whatever of cwd/timeout/env/stdout/stderr/text/shell the caller passes as keywords."""
    old_run, old_run_cmd = L.subprocess.run, L.run_cmd
    L.subprocess.run = L.run_cmd = fake
    try:
        yield fake
    finally:
        L.subprocess.run, L.run_cmd = old_run, old_run_cmd
def pi_stub(result, calls=None):
    """Driver.pi replacement: returns a callable with the Driver.pi signature (name, prompt, timeout=L.PI_TASK_TIMEOUT_S, gpu=None)
    that appends each call's name to calls (when given) and returns result: a bool, or a callable taking the
    calls list and returning a bool."""
    def pi(name, prompt, timeout=L.PI_TASK_TIMEOUT_S, gpu=None):
        if calls is not None: calls.append(name)
        return result(calls) if callable(result) else result
    return pi

class PromptMentions:   # mixin for prompt tests: every phrase the prompt must name, on one line, needle named on failure
    def assert_mentions(self, text, *needles):
        for n in needles: self.assertIn(n, text, n)

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

class PlanSpec(unittest.TestCase):   # validate_plan as a specification list: PLAN_CHECKS = [(predicate, message), ...]
    """The plan rules as data: L.PLAN_CHECKS is a list of (predicate, message) pairs and validate_plan(p) returns
    exactly the messages of the specs p fails, in list order. A message is a string or a callable taking the plan.
    Every message pinned below is today's, one per check."""
    KEYS = ("repo", "issue", "branch", "files", "criteria", "tasks", "verify_cmd", "pr_title")

    def spec_errors(self, p):
        """The messages of the specs PLAN_CHECKS rejects for p, in list order: a spec's predicate is true when the
        plan satisfies it, and its message is either a string or a callable taking the plan."""
        return [(m(p) if callable(m) else m) for ok, m in L.PLAN_CHECKS if not ok(p)]

    def assert_check(self, p, msg):
        """p trips exactly one spec, its message is msg, and validate_plan says the same in list order."""
        self.assertEqual(L.validate_plan(p), [msg], msg)
        self.assertEqual(self.spec_errors(p), [msg], msg)

    def test_plan_checks_is_a_specification_list(self):
        self.assertIsInstance(L.PLAN_CHECKS, list)
        self.assertGreaterEqual(len(L.PLAN_CHECKS), 8)
        for c in L.PLAN_CHECKS:
            self.assertIsInstance(c, tuple); self.assertEqual(len(c), 2, str(c))
            ok, msg = c
            self.assertTrue(callable(ok), str(c))
            self.assertTrue(isinstance(msg, str) or callable(msg), str(c))
        self.assertEqual(self.spec_errors(PLAN), [])   # a good plan satisfies every spec

    def test_validate_plan_returns_the_failing_specs_in_list_order(self):
        bad = dict(PLAN, branch="feature/x", size="medium", pr_title="token=abc123",
                   tasks=[{"name": "t1", "prompt": "then git push origin"}])
        self.assertEqual(L.validate_plan(bad),
                         ["branch must start with cm-ai-ops-bot/", "size must be large or small",
                          "plan contains a secret-looking value",
                          "Pi task prompts must not ask Pi to commit, push or call gh"])
        for p in (PLAN, bad, dict(PLAN, issue=1918), dict(PLAN, criteria=[{"text": "A works"}])):
            self.assertEqual(L.validate_plan(p), self.spec_errors(p), json.dumps(p, sort_keys=True))

    def test_missing_key(self):
        for k in self.KEYS:
            absent = {x: v for x, v in PLAN.items() if x != k}
            # a missing branch is missing and not-a-bot-branch: today's two messages, in list order
            errs = [f"missing {k}"] + (["branch must start with cm-ai-ops-bot/"] if k == "branch" else [])
            for p in (absent, dict(PLAN, **{k: None})):
                self.assertEqual(L.validate_plan(p), errs, k)
                self.assertEqual(self.spec_errors(p), errs, k)

    def test_task_timeout(self):
        """A plan task's optional timeout is validated where the other task fields are: every task omits it or
        gives a positive int at or above MIN_CLIENT_TIMEOUT_S; the message names the offending task index."""
        self.assertEqual(L.validate_plan(PLAN), [])   # no timeout at all
        self.assertEqual(L.validate_plan(dict(PLAN, tasks=[{"name": "t1", "prompt": "p", "timeout": 600}])), [])
        msg = f"timeout must be a positive int at or above {G.MIN_CLIENT_TIMEOUT_S}"
        self.assert_check(dict(PLAN, tasks=[{"name": "t1", "prompt": "p", "timeout": "90 seconds"}]), f"tasks[0] {msg}")
        self.assert_check(dict(PLAN, tasks=[{"name": "t1", "prompt": "p", "timeout": 5}]), f"tasks[0] {msg}")
        self.assert_check(dict(PLAN, tasks=[{"name": "t1", "prompt": "p"},
                                            {"name": "t2", "prompt": "p", "timeout": "90 seconds"}]),
                          f"tasks[1] {msg}")

    def test_branch_prefix(self):
        self.assert_check(dict(PLAN, branch="feature/x"), "branch must start with cm-ai-ops-bot/")

    def test_criteria_need_text_and_evidence(self):
        self.assert_check(dict(PLAN, criteria=[{"text": "A works", "evidence_cmd": "dotnet test --filter A"},
                                              {"text": "B works"}]), "criteria[1] needs text and evidence_cmd")

    def test_tasks_need_name_and_prompt(self):
        self.assert_check(dict(PLAN, tasks=[{"name": "t1", "prompt": "Write test A"}, {"prompt": "Write B"}]),
                          "tasks[1] needs name and prompt")

    def test_never_merge(self):
        self.assert_check(dict(PLAN, issue=1918), "this item's PR is never merged")

    def test_hands_off(self):
        self.assert_check(dict(PLAN, repo="cmdemo1-system", issue=654),
                          "this item is hands-off (Jeffrey); do not work it")

    def test_size(self):
        self.assert_check(dict(PLAN, size="medium"), "size must be large or small")

    def test_enhancement_protected_files(self):
        self.assert_check(dict(PLAN, kind="enhancement",
                               files=["src/A.cs", "infra/main.bicep", "src/appsettings.Production.json"]),
                          "an enhancement may not change credentials, secrets or production setup: "
                          "infra/main.bicep, src/appsettings.Production.json")

    def test_secret_looking_value(self):
        self.assert_check(dict(PLAN, pr_title="token=abc123"), "plan contains a secret-looking value")

    def test_task_prompts_may_not_commit_push_or_call_gh(self):
        self.assert_check(dict(PLAN, tasks=[{"name": "t1", "prompt": "then git push origin"}]),
                          "Pi task prompts must not ask Pi to commit, push or call gh")

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
        with fake_home() as h:
            d = make_driver(issue=8); d.s.update(stage="ci", pr=5, start=L.iso())
            d.blocker("required checks still red."); self.assertEqual((d.s["resume_stage"], d.s["stage"]), ("ci", "blocked"))
            d.s["progress_at"] = (L.now() - L.dt.timedelta(minutes=45)).isoformat(); d.heartbeat()
            self.assertNotIn("heartbeat_at", d.s)   # dry-run posts nothing
            d.dry = False; d.sh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, "", ""); d.comment = lambda b, pr=False: setattr(d, "hb", b)
            d.heartbeat(); self.assertIn("no progress for 30+ min", d.hb); self.assertIn("required checks still red", d.hb)

    def test_review_fail_blocker_does_not_resume_on_green_checks(self):
        self.assertFalse(L.hold_resumes("Review FAIL twice: A works (exit 1)"))
        self.assertFalse(L.hold_resumes("independent review FAIL twice: - finding"))
        self.assertTrue(L.hold_resumes("required checks still red after 3 Pi fix passes."))
        self.assertTrue(L.hold_resumes("Qodana did not finish within 60 minutes."))
        self.assertTrue(L.hold_resumes(None))
        with fake_home() as h:
            d = make_driver(issue=9); d.dry = False
            d.s.update(pr=5, resume_stage="review", blocker="independent review FAIL twice: - x")
            d.pr_checks = lambda: self.fail("a Review FAIL blocker must not wait on checks")
            self.assertFalse(d.hold_blocked())

class ReviewInfraRetry(unittest.TestCase):   # t83u: no / empty findings or no verdict = retry the review, never a FAIL
    def test_review_verdict_classifies_infra_failures(self):
        self.assertIsNone(L.review_verdict("exit 1", None)[0])         # #1944: no findings file
        self.assertIsNone(L.review_verdict("FAIL", " \n\t")[0])       # whitespace only
        self.assertIsNone(L.review_verdict("timeout", "- partial")[0])  # #820: timed out, no verdict
        self.assertEqual(L.review_verdict("PASS", "- No findings."), (True, "- No findings."))
        self.assertEqual(L.review_verdict("FAIL", "- bug"), (False, "- bug"))
        self.assertFalse(L.hold_resumes("independent review infra failed 3 times (x)"))

    def driver(self, h, verdicts):
        d = make_driver(issue=31)
        plan = dict(PLAN, criteria=[{"text": "A works", "evidence_cmd": "true"}])
        d.s.update(plan=plan, wt=tempfile.mkdtemp(dir=h), gpu="pro5000", pr=7, stage="review")
        d.independent_review = lambda: verdicts.pop(0)
        d.pi = lambda *a, **k: self.fail("review infra findings must never reach Pi")
        d.blocker = lambda what: d.save(stage="blocked", blocker=what)
        d.comment = d.move = lambda *a, **k: None
        return d

    def test_infra_failure_is_retried_then_passes(self):
        with fake_home() as h:
            d = self.driver(h, [(None, "no findings file"), (None, "empty"), (True, "- No findings.")])
            d.st_review()
            self.assertEqual(d.s["stage"], "merge")
            self.assertEqual((d.s["counts"]["review_fail"], d.s["counts"]["review_infra"]), (0, 0))

    def test_infra_failure_blocks_after_two_retries_without_a_fail(self):
        with fake_home() as h:
            d = self.driver(h, [(None, "no findings file")] * 3)
            d.st_review()
            self.assertEqual(d.s["stage"], "blocked")
            self.assertTrue(d.s["blocker"].startswith("independent review infra failed 3 times"))
            self.assertIn("not a code FAIL", d.s["blocker"])
            self.assertEqual(d.s["counts"]["review_fail"], 0)

    def test_review_runs_on_any_free_non_author_gpu_and_missing_file_is_infra(self):
        with patched_driver_env(research_ok=lambda *a: True, gpu_health=lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}) as h:
            d = make_driver(issue=32)
            d.s.update(plan=dict(PLAN), wt=tempfile.mkdtemp(dir=h), gpu="pro5000", pr=7, default="main")
            d.merge_base = lambda: "abc"; calls = []
            rec = json.dumps({"task": "independent-review-1", "gpu": "ts3", "result": "exit 1"})
            def sh(cmd, **k):
                calls.append(list(cmd))
                out = "body\n## Refactoring research\n- x" if "pr" in cmd else (rec + "\n--- pi tail ---" if "--gpu" in cmd else "")
                return subprocess.CompletedProcess(cmd, 1 if "--gpu" in cmd else 0, out, "")
            d.sh = sh
            ok, why = d.independent_review()
            run = next(c for c in calls if "--gpu" in c)
            self.assertEqual(run[run.index("--gpu") + 1], "pro6000,obs,ts3")   # never the author's pro5000
            self.assertIsNone(ok); self.assertIn("no findings file", why); self.assertEqual(d.s["reviewer_gpu"], "ts3")

    def test_gate_acquire_any_takes_the_first_free_gpu(self):
        import gpu_gate
        with tempfile.TemporaryDirectory() as h:
            env = {k: os.environ.get(k) for k in ("FACTORY_PI_LOCK_DIR", "FACTORY_PI_LEGACY_LOCK_DIR")}
            os.environ["FACTORY_PI_LOCK_DIR"] = h; os.environ.pop("FACTORY_PI_LEGACY_LOCK_DIR", None)
            try:
                p = subprocess.Popen([sys.executable, "-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); "
                                      "fcntl.flock(f, fcntl.LOCK_EX); print('held', flush=True); time.sleep(30)",
                                      os.path.join(h, "factory-pi-obs-slot-0.lock")], stdout=subprocess.PIPE, text=True)
                try:
                    p.stdout.readline()
                    g, fd = gpu_gate.acquire_any(["obs", "ts3"], wait=False)
                    self.assertEqual(g, "ts3"); gpu_gate.release(fd)
                    self.assertEqual(gpu_gate.acquire_any(["obs"], wait=False), (None, None))
                finally: p.kill(); p.wait()
            finally:
                for k, v in env.items():
                    if v is None: os.environ.pop(k, None)
                    else: os.environ[k] = v

class HandoffStartWatchdog(unittest.TestCase):   # t85u: a Pi hand-off that has not really started in 15 min is relaunched
    def rt(self):
        loader = importlib.machinery.SourceFileLoader("run_task_t85u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-task"))
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("run_task_t85u", loader)); loader.exec_module(m); return m

    def test_run_pi_kills_a_pi_with_no_session_record(self):
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            beats = []; t0 = time.monotonic()
            rc, _ = rt.run_pi(["bash", "-c", "sleep 60"], cwd=tmp, timeout=30, sdir=tmp, start_s=1, beat=beats.append)
            self.assertEqual(rc, rt.NO_START_RC); self.assertFalse(rt.run_pi.started)
            self.assertLess(time.monotonic() - t0, 15); self.assertTrue(beats and "pi_pid" in beats[0])

    def test_run_pi_stalled_after_model_output_is_stalled_not_no_start(self):
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            # The run deadline is only a backstop for a starved watchdog thread (on a loaded host the stall kill can land
            # late, and a 30 s deadline then won first: rc 124 instead of 125). Same start_s / stall_s, same assertions.
            rc, _ = rt.run_pi(["bash", "-c", f"echo '{HDR}' > {f}; echo '{ASSISTANT}' >> {f}; sleep 600"], cwd=tmp, timeout=120,
                              sdir=tmp, start_s=1, stall_s=2)
            self.assertEqual(rc, rt.NO_START_RC); self.assertTrue(rt.run_pi.started)

    def test_user_prompt_record_alone_is_no_start(self):   # review minor 5: the prompt record is not model output
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            rc, _ = rt.run_pi(["bash", "-c", f"echo '{HDR}' > {f}; echo '{USER}' >> {f}; sleep 60"], cwd=tmp, timeout=30,
                              sdir=tmp, start_s=1)
            self.assertEqual(rc, rt.NO_START_RC); self.assertFalse(rt.run_pi.started)

    def test_reused_session_dir_with_older_larger_file_is_not_killed(self):   # review major 1
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            old = os.path.join(tmp, "old.jsonl"); open(old, "w").write((ASSISTANT + "\n") * 60)
            os.utime(old, (time.time() - 3600, time.time() - 3600))   # an earlier run under the same task name
            new = os.path.join(tmp, "new.jsonl")
            script = (f"echo '{HDR}' > {new}; echo '{ASSISTANT}' >> {new}; "
                      f"for i in 1 2 3 4 5 6 7 8; do sleep 0.5; echo '{ASSISTANT}' >> {new}; done; echo PASS")
            t0 = time.monotonic()
            rc, text = rt.run_pi(["bash", "-c", script], cwd=tmp, timeout=30, sdir=tmp, start_s=1.5)
            self.assertEqual(rc, 0, "a healthy run must not be judged against an older session file"); self.assertIn("PASS", text)
            self.assertGreater(time.monotonic() - t0, 1.5)
            self.assertEqual(rt.session_files(tmp, time.time() - 60), [new])

    def test_run_that_keeps_writing_records_survives_past_start_s(self):   # review minor 10
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            script = f"echo '{HDR}' > {f}; for i in $(seq 12); do sleep 0.5; echo '{ASSISTANT}' >> {f}; done; echo PASS"
            t0 = time.monotonic()
            rc, text = rt.run_pi(["bash", "-c", script], cwd=tmp, timeout=30, sdir=tmp, start_s=1.5, stall_s=1.5)
            self.assertEqual(rc, 0); self.assertIn("PASS", text)
            self.assertGreater(time.monotonic() - t0, 3 * 1.5, "the run outlived start_s several times over")

    def test_cpu_work_after_start_is_activity_not_a_stall(self):   # review minor 4: a long build writes no record
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            script = (f"echo '{HDR}' > {f}; echo '{ASSISTANT}' >> {f}; "
                      "end=$((SECONDS+5)); while [ $SECONDS -lt $end ]; do :; done; echo PASS")
            rc, text = rt.run_pi(["bash", "-c", script], cwd=tmp, timeout=30, sdir=tmp, start_s=1.5, stall_s=1.5)
            self.assertEqual(rc, 0, "CPU work in Pi's group after model output keeps the run alive"); self.assertIn("PASS", text)

    def test_failing_heartbeat_never_turns_the_watch_off(self):   # review minor 7
        rt = self.rt()
        def beat(d): raise OSError("disk full")
        with tempfile.TemporaryDirectory() as tmp:
            t0 = time.monotonic()
            rc, _ = rt.run_pi(["bash", "-c", "sleep 60"], cwd=tmp, timeout=30, sdir=tmp, start_s=1, beat=beat)
            self.assertEqual(rc, rt.NO_START_RC); self.assertLess(time.monotonic() - t0, 15)

    def test_pi_exiting_on_its_own_at_the_kill_keeps_its_rc(self):   # review minor 11
        rt = self.rt(); ev = rt.threading.Event()
        self.assertFalse(rt.killed_by_watch(ev, -15))                 # no kill
        ev.set()
        self.assertTrue(rt.killed_by_watch(ev, -signal.SIGTERM)); self.assertTrue(rt.killed_by_watch(ev, 143))
        self.assertFalse(rt.killed_by_watch(ev, 0)); self.assertFalse(rt.killed_by_watch(ev, 1))

    def run_task_main(self, tmp, args, pi_script=None, env_extra=None):
        run, cwd, lockdir = (os.path.join(tmp, x) for x in ("run", "work", "locks"))
        for d in (run, cwd, lockdir): os.makedirs(d, exist_ok=True)
        json.dump({"top_session": "t", "start": "2026-01-01T00:00:00+00:00", "pi_version": "0-test"}, open(os.path.join(run, "run.json"), "w"))
        prompt = os.path.join(tmp, "prompt.md"); open(prompt, "w").write("do it\n")
        fake = os.path.join(tmp, "fake-pi"); open(fake, "w").write("#!/usr/bin/env bash\n" + (pi_script or "echo PASS\n")); os.chmod(fake, 0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith("LOCAL_LLM_")}
        env.update({"FACTORY_PI_GPU_BIN": fake, "FACTORY_PI_LOCK_DIR": lockdir, "TMPDIR": tmp, "FACTORY_MIN_CLIENT_TIMEOUT_S": "1"}, **(env_extra or {}))
        p = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-task"), "--run-dir", run,
                            "--cwd", cwd, "--prompt-file", prompt, *args], env=env, capture_output=True, text=True, timeout=30)
        return p, run, lockdir

    def test_run_task_no_slot_record_exit_and_progress(self):   # review minors 7 / 9 / 10: the no-slot path
        with tempfile.TemporaryDirectory() as tmp:
            lockdir = os.path.join(tmp, "locks"); os.makedirs(lockdir)
            holder = subprocess.Popen([sys.executable, "-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX); "
                                       "print('held', flush=True); time.sleep(30)", os.path.join(lockdir, "factory-pi-ts3-slot-0.lock")],
                                      stdout=subprocess.PIPE, text=True)
            try:
                holder.stdout.readline()
                p, run, _ = self.run_task_main(tmp, ["--task", "t1", "--gpu", "ts3", "--start-timeout", "900", "--slot-wait", "1"],
                                               pi_script="echo should-not-run; exit 7\n")
            finally: holder.kill(); holder.wait()
            self.assertEqual(p.returncode, 125, p.stderr[-500:])
            rec = [json.loads(l) for l in open(os.path.join(run, "tasks.jsonl"))][-1]
            self.assertEqual((rec["rc"], rec["result"], rec["gpu"]), (125, "no-start", "ts3")); self.assertIn("no free slot", rec["why"])
            prog = json.load(open(os.path.join(run, "logs", "t1.progress.json")))
            self.assertEqual((prog["state"], prog["result"]), ("no-slot", "no-start"))

    def test_run_task_ignores_an_old_session_and_marks_progress_finished(self):   # majors 1 / minor 7 end to end
        with tempfile.TemporaryDirectory() as tmp:
            sd = os.path.join(tmp, "run", "pi-sessions", "t1"); os.makedirs(sd)
            old = os.path.join(sd, "old.jsonl"); open(old, "w").write((ASSISTANT + "\n") * 60)
            os.utime(old, (time.time() - 3600, time.time() - 3600))
            p, run, _ = self.run_task_main(tmp, ["--task", "t1", "--gpu", "obs", "--start-timeout", "5", "--slot-wait", "5"])
            self.assertEqual(p.returncode, 0, p.stdout[-500:] + p.stderr[-500:])
            rec = [json.loads(l) for l in open(os.path.join(run, "tasks.jsonl"))][-1]
            self.assertEqual(rec["result"], "PASS"); self.assertIsNone(rec["session_file"], "the old run's session is not this run's")
            self.assertEqual(rec["turns"], 0)
            prog = json.load(open(os.path.join(run, "logs", "t1.progress.json")))
            self.assertEqual((prog["state"], prog["result"], prog["gpu"]), ("finished", "PASS", "obs"))

    def test_run_pi_with_progress_is_left_alone(self):
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            rc, text = rt.run_pi(["bash", "-c", "echo done; exit 0"], cwd=tmp, timeout=10, sdir=tmp, start_s=5)
            self.assertEqual(rc, 0); self.assertIn("done", text)

    def test_gate_gives_up_after_max_wait(self):
        import gpu_gate
        with tempfile.TemporaryDirectory() as h:
            old = os.environ.get("FACTORY_PI_LOCK_DIR"); os.environ["FACTORY_PI_LOCK_DIR"] = h
            p = subprocess.Popen([sys.executable, "-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX); "
                                  "print('held', flush=True); time.sleep(30)", os.path.join(h, "factory-pi-ts3-slot-0.lock")],
                                 stdout=subprocess.PIPE, text=True)
            try:
                p.stdout.readline(); self.assertEqual(gpu_gate.acquire_any(["ts3"], max_wait=0), (None, None))
            finally:
                p.kill(); p.wait()
                if old is None: os.environ.pop("FACTORY_PI_LOCK_DIR", None)
                else: os.environ["FACTORY_PI_LOCK_DIR"] = old

    def driver(self, h, results, size="small"):
        """results: a result string (ran on the first GPU of --gpu) or (result, gpu that ran)."""
        d = make_driver(issue=41); d.s.update(gpu="ts3", size=size, wt=tempfile.mkdtemp(dir=h)); calls = []
        def sh(cmd, **k):
            calls.append(list(cmd)); res = results.pop(0)
            res, g = res if isinstance(res, tuple) else (res, cmd[cmd.index("--gpu") + 1].split(",")[0])
            return subprocess.CompletedProcess(cmd, 0 if res == "PASS" else 1,
                                               json.dumps({"task": cmd[cmd.index("--task") + 1], "gpu": g, "result": res}), "")
        d.sh = sh; return d, calls

    def test_handoff_relaunched_on_any_free_gpu_then_passes(self):
        old_gpu_health = L.gpu_health
        L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
        try:
            with fake_home() as h:
                d, calls = self.driver(h, ["no-start", "stalled", "PASS"])
                self.assertTrue(d.pi("review-fix-2", "fix it"))
                arg = lambda c, f: c[c.index(f) + 1]
                self.assertEqual([arg(c, "--gpu") for c in calls], ["ts3", "pro5000,pro6000,obs,ts3", "pro5000,pro6000,obs,ts3"])
                self.assertEqual([arg(c, "--task") for c in calls], ["review-fix-2", "review-fix-2-relaunch-1", "review-fix-2-relaunch-2"])
                self.assertEqual(arg(calls[0], "--start-timeout"), str(L.HANDOFF_START_S))
                self.assertEqual(arg(calls[0], "--stall-timeout"), str(L.HANDOFF_STALL_S))
                # minor 6: the slot wait is separate and longer than the start clock for every relaunch
                self.assertEqual([int(arg(c, "--slot-wait")) for c in calls], [L.HANDOFF_SLOT_WAIT_S, L.ANY_SLOT_WAIT_S, L.ANY_SLOT_WAIT_S])
                self.assertGreater(L.ANY_SLOT_WAIT_S, L.HANDOFF_START_S)
                # minor 8: the relaunch prompt says an earlier attempt may have left partial edits; the first does not
                p0, p1 = (open(arg(c, "--prompt-file")).read() for c in calls[:2])
                self.assertNotIn("partial edits", p0); self.assertIn("partial edits", p1); self.assertIn("fix it", p1)
                self.assertTrue(p1.rstrip().endswith("the last line."))
        finally:
            L.gpu_health = old_gpu_health

    def test_large_item_relaunch_keeps_its_size_routing(self):   # review major 2, related minor
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "obs", "pro5000"]), ["pro5000"])
        self.assertEqual(L.relaunch_gpus(None, ["ts3", "obs", "pro5000"]), ["pro5000"])
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "obs"]), ["obs", "ts3"])   # pro5000 down: as pick_gpu
        self.assertEqual(L.relaunch_gpus("small", ["ts3", "pro5000"]), ["pro5000", "ts3"])
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "pro6000", "pro5000"]), ["pro5000", "pro6000"])   # either 262K GPU
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "pro6000"]), ["pro6000"])
        self.assertEqual(L.relaunch_gpus("small", ["ts3", "obs", "pro6000", "pro5000"]), ["pro5000", "pro6000", "obs", "ts3"])
        old_gpu_health = L.gpu_health
        L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
        try:
            with fake_home() as h:
                d, calls = self.driver(h, ["stalled", "PASS"], size="large")
                self.assertTrue(d.pi("t1", "do it"))
                self.assertEqual(calls[1][calls[1].index("--gpu") + 1], "pro5000,pro6000")   # a 262K GPU only
        finally:
            L.gpu_health = old_gpu_health

    def test_review_excludes_every_authoring_gpu_including_relaunch_gpus(self):   # review major 2
        self.assertEqual(G.reviewer_gpus(["ts3", "obs"], list(G.GPUS)), ["pro5000", "pro6000"])
        self.assertEqual(G.reviewer_gpus("ts3", list(G.GPUS)), ["pro5000", "pro6000", "obs"])
        with patched_driver_env(gpu_health=lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}, research_ok=lambda *a: True) as h:
            d, calls = self.driver(h, ["stalled", ("PASS", "obs")])   # item on ts3; the relaunch wrote the code on obs
            self.assertTrue(d.pi("t1", "do it"))
            self.assertEqual(d.author_gpus(), ["ts3", "obs"])
            d.s.update(plan=dict(PLAN), pr=7, default="main"); d.merge_base = lambda: "abc"; review = []
            rec = json.dumps({"task": "independent-review-1", "gpu": "pro5000", "result": "PASS"})
            def sh(cmd, **k):
                if "--gpu" in cmd: review.append(list(cmd)); return subprocess.CompletedProcess(cmd, 0, rec, "")
                return subprocess.CompletedProcess(cmd, 0, "body\n## Refactoring research\n- x" if "pr" in cmd else "", "")
            d.sh = sh; d.independent_review()
            self.assertEqual(review[0][review[0].index("--gpu") + 1], "pro5000,pro6000", "neither ts3 nor obs may review")
            self.assertEqual(int(review[0][review[0].index("--slot-wait") + 1]), L.ANY_SLOT_WAIT_S)   # 2 h, per the docs
            self.assertEqual(d.author_gpus(), ["ts3", "obs"], "a review never counts as authoring")

    def test_no_slot_record_is_not_an_author_gpu(self):
        old_gpu_health = L.gpu_health
        L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
        try:
            with fake_home() as h:
                d, _ = self.driver(h, [("no-start", "pro5000,obs,ts3"), "PASS"])
                self.assertTrue(d.pi("t1", "do it")); self.assertEqual(d.s.get("author_gpus"), ["pro5000"])
        finally:
            L.gpu_health = old_gpu_health

    def test_read_only_calls_and_no_start_are_not_author_gpus(self):   # re-review major A / minor D
        self.assertFalse(L.writes_code("draft-plan")); self.assertFalse(L.writes_code("refactoring-research-1"))
        self.assertFalse(L.writes_code("independent-review-2")); self.assertTrue(L.writes_code("review-fix-1"))
        old_gpu_health = L.gpu_health
        L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
        try:
            with fake_home() as h:
                d, _ = self.driver(h, [("PASS", "pro5000")])   # item on ts3; plan drafted on pro5000
                self.assertTrue(d.pi("draft-plan", "plan it", gpu="pro5000"))
                d2, _ = self.driver(h, [("PASS", "pro5000")]); d2.pi("refactoring-research-1", "research")
                self.assertNotIn("pro5000", d.author_gpus()); self.assertNotIn("pro5000", d2.author_gpus())
                self.assertIn("pro5000", G.reviewer_gpus(d.author_gpus(), list(G.GPUS)), "pro5000 stays a reviewer")
                d3, _ = self.driver(h, [("no-start", "obs"), ("PASS", "ts3")])   # got a slot on obs but never replied
                self.assertTrue(d3.pi("t1", "do it")); self.assertNotIn("obs", d3.author_gpus())
        finally:
            L.gpu_health = old_gpu_health

    def test_hold_mid_pass_stops_push_and_merge(self):   # re-review minor B
        with fake_home() as h:
            d = make_driver(issue=1946)
            d.sh = lambda cmd, **k: self.fail("a held item must not run git or gh")
            d.gh = lambda *a, **k: self.fail("a held item must not call GitHub")
            self.hold(h, 1946)
            with self.assertRaises(L.PiHeld): d.commit_push("msg")
            with self.assertRaises(L.PiHeld): d.st_merge()

    def hold(self, h, issue, text="handed-off: FactoryBot1"):
        open(os.path.join(h, "factory-runs", f"cmdemo1-workorders-{issue}", "HOLD"), "w").write(text)

    def test_hold_stops_a_live_driver_at_the_next_stage_pass(self):   # review major 3
        old_watchdog = L.watchdog_exit
        L.watchdog_exit = lambda drv: None
        try:
            with fake_home() as h:
                d = make_driver(issue=1944)
                json.dump(PLAN, open(os.path.join(d.run_dir, "plan.json"), "w"))
                d.sh = lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, "0.1", "")
                ran = []
                def st_research(): ran.append("research"); self.hold(h, 1944); d.save(stage="implement")
                d.st_research = st_research
                d.st_implement = lambda: self.fail("a held item must not run another stage")
                d.wake_bot = d.comment = lambda *a, **k: self.fail("a held item is never touched")
                d.s["stage"] = "research"; d.run()
                self.assertEqual(ran, ["research"])
                s = json.load(open(d.state_p)); self.assertEqual((s["status"], s["stage"]), ("held", "implement"))
                self.assertIn("FactoryBot1", s["held"])
        finally:
            L.watchdog_exit = old_watchdog

    def test_hold_stops_a_blocked_driver_inside_hold_blocked(self):   # review major 3
        class T:
            def __init__(self): self.t = 1e9
            def time(self): return self.t
            def sleep(self, s): self.t += s
        old_time = L.time
        L.time = T()
        try:
            with fake_home() as h:
                d = make_driver(issue=1945); d.dry = False
                d.s.update(pr=5, resume_stage="review", blocker="required checks still red after 3 Pi fix passes.")
                checks = []
                def pr_checks():   # red on the first re-check; the item is handed off before the next one turns green
                    checks.append(1); self.hold(h, 1945)
                    return "FAIL", [{"name": "build", "bucket": "fail"}]
                d.pr_checks = pr_checks; d.heartbeat = lambda *a: None
                d.comment = d.wake_bot = lambda *a, **k: self.fail("a held item is never touched")
                self.assertFalse(d.hold_blocked(), "a held driver never clears its Blocker or resumes")
                self.assertEqual(len(checks), 1); self.assertEqual(d.s["status"], "held"); self.assertIn("blocker", d.s)
        finally:
            L.time = old_time

    def test_handoff_blocks_after_two_relaunches_and_reviews_are_not_relaunched(self):
        old_gpu_health = L.gpu_health
        L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
        try:
            with fake_home() as h:
                d, calls = self.driver(h, ["no-start"] * 3)
                with self.assertRaises(L.PiNotStarted) as e: d.pi("t1", "do it")
                self.assertEqual(len(calls), 3); self.assertFalse(L.hold_resumes(str(e.exception)))
                d, calls = self.driver(h, ["no-start"])
                self.assertFalse(d.pi("independent-review-1", "review", gpu="obs")); self.assertEqual(len(calls), 1)
        finally:
            L.gpu_health = old_gpu_health

    def test_hold_file_stops_start_run_and_watchdog(self):
        import watchdog as W
        with fake_home() as h:
            os.makedirs(os.path.join(h, "factory-runs", "cmdemo1-workorders-1944"))
            self.assertFalse(W.excluded("cmdemo1-workorders", 1944))
            open(os.path.join(h, "factory-runs", "cmdemo1-workorders-1944", "HOLD"), "w").write("handed-off: FactoryBot1")
            self.assertTrue(W.excluded("cmdemo1-workorders", 1944))
            a = L.argparse.Namespace(repo="cmdemo1-workorders", issue=1944, top_session=None, dry_run=False, resume=True)
            for cmd in (L.cmd_start, L.cmd_run):
                with self.assertRaises(SystemExit) as e: cmd(a)
                self.assertEqual(e.exception.code, 0)

class TaskNameSlug(unittest.TestCase):   # cmdemo1-system#959: a plan task name with '/' or ':' must not crash the prompt-file write
    def driver_with_scripted_run(self, h, issue, results):
        """A driver whose sh is faked to replay `results` (PASS / no-start / stalled, in order) for every run-task call."""
        d = make_driver(issue=issue); d.s.update(gpu="ts3", size="small", wt=tempfile.mkdtemp(dir=h))
        calls, it = [], iter(results)
        def sh(cmd, **k):
            calls.append(list(cmd))
            res = next(it)
            return subprocess.CompletedProcess(cmd, 0 if res == "PASS" else 1,
                                               json.dumps({"task": cmd[cmd.index("--task") + 1], "gpu": "ts3", "result": res}), "")
        d.sh = sh
        return d, calls

    def test_task_slug_is_the_run_task_file_mapping(self):
        self.assertEqual(L.task_slug("test: whole factory/pi suite green and no orphans left"),
                         "test--whole-factory-pi-suite-green-and-no-orphans-left")
        self.assertEqual(L.task_slug("t1"), "t1")   # a safe name is unchanged
        self.assertEqual(L.task_slug("review-fix-2-relaunch-1"), "review-fix-2-relaunch-1")
        self.assertEqual(L.task_slug(L.task_slug("a/b c:d")), L.task_slug("a/b c:d"))   # idempotent

    def test_pi_slashes_and_colons_run_without_error_and_write_the_slug_path(self):
        with fake_home() as h:
            d, calls = self.driver_with_scripted_run(h, 959, ["PASS"])
            name = "test: whole factory/pi suite green and no orphans left"
            self.assertTrue(d.pi(name, "do it"))   # used to raise FileNotFoundError (raw '/' in the prompt path)
            arg = lambda c, f: c[c.index(f) + 1]
            pf = arg(calls[0], "--prompt-file")
            self.assertEqual(pf, os.path.join(d.run_dir, "logs", "test--whole-factory-pi-suite-green-and-no-orphans-left.prompt.md"))
            self.assertTrue(os.path.exists(pf))
            self.assertIn("do it", open(pf).read())
            self.assertEqual(arg(calls[0], "--task"), "test--whole-factory-pi-suite-green-and-no-orphans-left")

    def test_pi_safe_name_keeps_its_existing_log_names(self):
        with fake_home() as h:
            d, calls = self.driver_with_scripted_run(h, 960, ["PASS"])
            self.assertTrue(d.pi("t1", "do it"))
            arg = lambda c, f: c[c.index(f) + 1]
            self.assertEqual(arg(calls[0], "--task"), "t1")
            self.assertEqual(arg(calls[0], "--prompt-file"), os.path.join(d.run_dir, "logs", "t1.prompt.md"))
            self.assertTrue(os.path.exists(os.path.join(d.run_dir, "logs", "t1.prompt.md")))

    def test_pi_relaunch_prompt_paths_are_slugged_too(self):
        old_gpu_health = L.gpu_health
        L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
        try:
            with fake_home() as h:
                d, calls = self.driver_with_scripted_run(h, 961, ["no-start", "PASS"])
                name = "test: whole factory/pi suite green"
                self.assertTrue(d.pi(name, "do it"))
                arg = lambda c, f: c[c.index(f) + 1]
                self.assertEqual([arg(c, "--task") for c in calls],
                                 ["test--whole-factory-pi-suite-green", "test--whole-factory-pi-suite-green-relaunch-1"])
                for c in calls:
                    pf = arg(c, "--prompt-file")
                    self.assertTrue(os.path.exists(pf), pf)
                self.assertIn("partial edits", open(arg(calls[1], "--prompt-file")).read())
        finally:
            L.gpu_health = old_gpu_health

class DryRunDriver(unittest.TestCase):
    def test_writes_are_skipped_in_dry_run(self):
        with fake_home() as h:
            d = make_driver(issue=7)
            r = d.sh(["false"], write=True)
            self.assertEqual(r.returncode, 0)
            self.assertIn("DRY-RUN skip", open(os.path.join(d.run_dir, "driver.log")).read())
            self.assertFalse(d.bump("review_fail") is False)   # 1 <= 2
            d.bump("review_fail"); self.assertFalse(d.bump("review_fail"))  # 3rd exceeds the limit of 2

class GpuResume(unittest.TestCase):   # bug (a): a resumed item keeps the GPU recorded in state.json, never a silent pro5000 default
    def test_gpu_raises_when_unrecorded(self):
        with fake_home() as h:
            d = make_driver(issue=21)
            self.assertNotIn("gpu", d.s)
            self.assertRaises(RuntimeError, d.gpu)   # no gpu in state: raise, never default to pro5000
            d.s["gpu"] = "obs"; d.save()
            self.assertEqual(d.gpu(), "obs")

    def test_resumed_item_keeps_its_gpu_and_waits(self):
        with patched_driver_env(time=Clock(),
                                gpu_health=lambda max_age=600: {"obs": ("UNREACHABLE", "down"), "pro5000": ("HEALTHY", ""), "ts3": ("HEALTHY", "")}) as h:
            d = L.Driver("cmdemo1-workorders", 22)   # dry_run=False
            d.s["plan"] = dict(PLAN, size="large"); d.s["gpu"] = "obs"; d.s["stage"] = "gpu"; d.save()
            d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
            d.st_gpu()
            self.assertEqual(d.s["gpu"], "obs")      # not re-picked to pro5000 or anything else
            self.assertEqual(d.s["stage"], "blocked")
            self.assertIn("obs", d.s["blocker"])     # it waited for its own GPU, bounded by GPU_WAIT_H

    def test_new_item_picks_and_persists_its_gpu(self):
        with patched_driver_env(time=Clock(),
                                gpu_health=lambda max_age=600: {g: ("HEALTHY", "") for g in ("pro5000", "obs", "ts3")}) as h:
            d = make_driver(issue=23)
            d.s["plan"] = PLAN; d.save()              # no 'gpu' in state yet
            d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
            d.st_gpu()
            self.assertEqual(d.s["stage"], "pickup")
            self.assertEqual(d.s["gpu"], G.pick_gpu(G.classify_size(PLAN), ["pro5000", "obs", "ts3"], set()))

    def test_pi_targets_the_recorded_gpu(self):
        with fake_home() as h:
            d = make_driver(issue=24)
            d.s["gpu"] = "ts3"; d.s["wt"] = tempfile.mkdtemp(dir=h)
            capture = []
            d.sh = lambda cmd, **k: (capture.append(list(cmd)), subprocess.CompletedProcess(cmd, 0, "PASS", ""))[1]
            d.pi("t1", "do it")
            self.assertIn("--gpu", capture[0])
            self.assertEqual(capture[0][capture[0].index("--gpu") + 1], "ts3")

class TaskRetry(unittest.TestCase):   # bug (b): a failed Pi task must not be marked done: retry it under distinct names, then a Blocker
    def test_failed_pi_task_not_done_retried_then_blocked(self):
        with fake_home() as h:
            d = make_driver(issue=25)
            d.s["plan"] = dict(PLAN, tasks=[{"name": "t1", "prompt": "p"}])
            d.s["stage"] = "implement"
            d.s["wt"] = tempfile.mkdtemp(dir=h)
            calls = []
            d.pi = pi_stub(False, calls)
            d.st_implement()
            self.assertEqual(d.s.get("tasks_done", []), [])   # a failed task is never recorded done
            self.assertEqual(len(calls), L.LIMITS["local_fix"] + 1)   # retried up to the limit
            self.assertEqual(d.s["stage"], "blocked")
            self.assertNotEqual(d.s["stage"], "local-verify")
            self.assertIn("t1", d.s["blocker"])
            self.assertEqual(calls[0], "t1")
            self.assertTrue(all(n != "t1" for n in calls[1:]) and any("retry" in n.lower() for n in calls[1:]),
                            "retries run under distinct retry names")

    def test_passing_pi_task_done_and_advances(self):
        with fake_home() as h:
            d = make_driver(issue=26)
            d.s["plan"] = dict(PLAN, tasks=[{"name": "t1", "prompt": "p"}])
            d.s["stage"] = "implement"
            d.s["wt"] = tempfile.mkdtemp(dir=h)
            d.pi = pi_stub(True)
            d.st_implement()
            self.assertEqual(d.s["tasks_done"], ["t1"])   # a passing task lands in tasks_done
            self.assertEqual(d.s["stage"], "local-verify")   # and the stage advances as before

    def test_pi_task_retried_until_pass(self):
        with fake_home() as h:
            d = make_driver(issue=27)
            d.s["plan"] = dict(PLAN, tasks=[{"name": "t1", "prompt": "p"}])
            d.s["stage"] = "implement"
            d.s["wt"] = tempfile.mkdtemp(dir=h)
            calls = []
            d.pi = pi_stub(lambda cs: len(cs) > 1, calls)   # fails exactly once
            d.st_implement()
            self.assertEqual(d.s["tasks_done"], ["t1"])
            self.assertEqual(d.s["stage"], "local-verify")
            self.assertEqual(len(calls), 2)
            self.assertNotEqual(calls[1], "t1")
            self.assertIn("retry", calls[1].lower())

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
        self.assertEqual((L.wip_limit("cmdemo1-dashboard"), L.wip_limit("cmdemo1-workorders"), L.wip_limit("cmdemo1-system")), (8, 3, 3))

    def test_intake_stops_while_red_except_fix_forward(self):
        self.assertTrue(L.intake_open({}, PLAN))
        self.assertFalse(L.intake_open({"cmdemo1-workorders main": {"what": "Build red"}}, PLAN))
        self.assertTrue(L.intake_open({"ui prod": {"what": "x"}}, dict(PLAN, fix_forward=True)))

    def test_red_flags_round_trip(self):
        with fake_home() as h:
            L.red_set("ui uat", "unhealthy"); L.red_set("ui uat", "again")
            self.assertEqual(L.red_load()["ui uat"]["what"], "unhealthy")   # first report kept
            L.red_clear("ui uat"); self.assertEqual(L.red_load(), {})

    def test_env_red(self):
        e = {"name": "uat", "health": {"containerApps": [{"name": "ui", "last": {"result": "unhealthy"}}]}}
        self.assertTrue(L.env_red(e, "ui")); self.assertFalse(L.env_red(e, "dashboard")); self.assertFalse(L.env_red(e, "system"))
        self.assertFalse(L.env_red({"health": {"containerApps": [{"name": "ui", "last": {"result": "healthy"}}]}}, "ui"))

    def test_env_red_healthy_result_is_not_red(self):
        """Last result 'healthy' -> healthy (not red)."""
        e = {"health": {"containerApps": [{"name": "ui", "last": {"result": "healthy"}}]}}
        self.assertFalse(L.env_red(e, "ui"))

    def test_env_red_unhealthy_result_is_red(self):
        """Last result 'unhealthy' -> not healthy, red."""
        e = {"health": {"containerApps": [{"name": "ui", "last": {"result": "unhealthy"}}]}}
        self.assertTrue(L.env_red(e, "ui"))

    def test_env_red_entry_present_no_last_is_not_red(self):
        """containerApps entry present with no 'last' -> not healthy, not red."""
        e = {"health": {"containerApps": [{"name": "ui"}]}}
        self.assertFalse(L.env_red(e, "ui"))

    def test_env_red_entry_present_last_empty_is_not_red(self):
        """containerApps entry with empty 'last' dict -> not healthy, not red."""
        e = {"health": {"containerApps": [{"name": "ui", "last": {}}]}}
        self.assertFalse(L.env_red(e, "ui"))

    def test_env_red_no_entry_for_dep_is_not_red(self):
        """No entry for dep -> not healthy, not red."""
        e = {"health": {"containerApps": [{"name": "other", "last": {"result": "unhealthy"}}]}}
        self.assertFalse(L.env_red(e, "ui"))

    def test_env_red_system_dep_never_red(self):
        """dep == 'system' -> healthy and never red."""
        e = {"health": {"containerApps": [{"name": "system", "last": {"result": "unhealthy"}}]}}
        self.assertFalse(L.env_red(e, "system"))
        e2 = {"health": {"containerApps": []}}
        self.assertFalse(L.env_red(e2, "system"))

    def test_blocked_at_pickup_is_not_wip(self):
        self.assertEqual(L.repo_wip([("x", {"repo": "cmdemo1-system", "stage": "blocked", "resume_stage": "pickup", "pid": 1})], "cmdemo1-system"), 0)
        self.assertEqual(L.repo_wip([("y", {"repo": "cmdemo1-system", "stage": "blocked", "resume_stage": "review", "pid": 1})], "cmdemo1-system"), 1)

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
        run, sleeps = FakeGhProcess(replies), []
        with patched_driver_env(run=run, sleep=sleeps.append) as h:
            d = L.Driver("cmdemo1-workorders", issue)
            try: res = d.gh("pr", "list")
            except RuntimeError as e: res = e
        return res, run.calls, sleeps, d

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
        with patched_driver_env(sleep=lambda s: seen.append(json.load(open(d.state_p)))) as h:
            d = L.Driver("cmdemo1-workorders", 9)
            d.wait_alive(120, "gh rate limit, retry 1")
        self.assertEqual(len(seen), 3)
        self.assertTrue(all(x["gh_wait"]["why"] == "gh rate limit, retry 1" and x["pid"] == os.getpid() for x in seen))
        self.assertTrue(seen[0]["gh_wait"]["until"] >= seen[-1]["gh_wait"]["until"])

    def test_non_rate_limit_failure_still_raises(self):
        calls, sleeps = [0], []
        def fake_run(*a, **k):
            calls[0] += 1
            return L.subprocess.CompletedProcess(a, 1, "HTTP 404: Not Found", "")
        def fake_sleep(s): sleeps.append(s)
        with patched_driver_env(run=fake_run, sleep=fake_sleep) as h:
            d = L.Driver("cmdemo1-workorders", 8)
            with self.assertRaises(RuntimeError):
                d.gh("pr", "list")
        self.assertEqual(calls[0], 1)   # non-rate-limit failures are never retried
        self.assertEqual(sleeps, [])

    def test_gh_retries_rate_limit_with_backoff_then_succeeds(self):
        calls, sleeps = [0], []
        def fake_run(*a, **k):
            calls[0] += 1
            if calls[0] <= 2:
                return L.subprocess.CompletedProcess(a, 1, "HTTP 403: API rate limit exceeded", "")
            return L.subprocess.CompletedProcess(a, 0, "42", "")
        def fake_sleep(s): sleeps.append(s)
        with patched_driver_env(run=fake_run, sleep=fake_sleep) as h:
            d = L.Driver("cmdemo1-workorders", 8)
            self.assertEqual(d.gh("pr", "list").returncode, 0)   # a later try succeeds; no raise
        self.assertEqual(calls[0], 3)             # two rate-limited tries, then the success
        self.assertEqual(sleeps, [60, 120])       # backoff before each retry

    def test_gh_waits_until_reset_after_backoff(self):
        calls, sleeps = [0], []
        def fake_run(*a, **k):
            calls[0] += 1
            if calls[0] <= 5:
                return L.subprocess.CompletedProcess(a, 1, "HTTP 403: Secondary rate limit in effect. Please try again.", "")
            return L.subprocess.CompletedProcess(a, 0, "42", "")
        def fake_sleep(s): sleeps.append(s)
        with patched_driver_env(run=fake_run, sleep=fake_sleep) as h:
            d = L.Driver("cmdemo1-workorders", 8)
            self.assertEqual(d.gh("pr", "list").returncode, 0)
        self.assertEqual(calls[0], 6)
        self.assertEqual(sleeps, [60, 120, 240, 600, 600])   # backoff first, then 600s waits until the limit resets

    def test_pr_number_ignores_non_numeric(self):
        for bad in ("", "not a number", "HTTP 404: Not Found", "42abc", None):
            self.assertIsNone(L.pr_number(bad))
        self.assertEqual(L.pr_number("42"), 42)
        self.assertEqual(L.pr_number(" 42 "), 42)

    def test_st_pr_survives_non_numeric_pr_list_and_creates(self):
        with fake_home() as h:
            d = make_driver(issue=30)
            d.s["plan"] = PLAN
            d.s["wt"] = tempfile.mkdtemp(dir=h)
            d.s["default"] = "main"
            d.s["gpu"] = "obs"
            d.s["run_id"] = "run30"
            d.sh = scripted_sh({
                "list": "no open PR for that head",   # gh pr list printed a non-numeric, non-rate-limit message
                "create": "https://github.com/x/cmdemo1-workorders/pull/42",
                "graphql": "{\"data\": null}",
                "rev-parse": "abc123def",
            })
            calls = d.sh.calls
            d.usage = lambda final=False: "usage"
            d.st_pr()                       # no ValueError from the non-numeric list output
            self.assertEqual(d.s["pr"], 42)  # it went on to creating the PR
            self.assertEqual(d.s["stage"], "ci")
        self.assertTrue(any("list" in c for c in calls))
        self.assertTrue(any("create" in c for c in calls))

class RefactoringResearch(PromptMentions, unittest.TestCase):
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
        with fake_home() as h:
            d = make_driver(issue=9); d.s["plan"] = PLAN
            out, fu, prompt = d.research_prompt()
            self.assert_mentions(prompt, "duplication", "long methods", "primitive obsession", "missing abstractions",
                                  "strategy", "specification", "ObjectMother", "query / command", "## Refactoring research",
                                  "follow-up", out, fu, "src/A.cs")
            self.assertTrue(out.startswith(d.run_dir) and fu.startswith(d.run_dir))   # outside the worktree

class ResearchInnerH2(unittest.TestCase):   # the research section ends at the driver's next H2, never at an inner H2
    FINDINGS = ("- `src/A.cs` `Save()`: 80-line method with duplicated validation; extract a specification object "
                "(in scope).\n- `src/A.cs` `status` strings: primitive obsession; a value object would make the rules "
                "explicit (follow-up: filed).\n- `src/A.cs` `Total()`: long conditional chain; one strategy per pricing "
                "rule keeps it readable (in scope).")
    GOOD = ("## Refactoring research\n\nRead `src/A.cs` and its close collaborators before touching anything.\n\n"
            "## Findings\n\n" + FINDINGS + "\n\n"
            "In scope: extract the specification object. Follow-up: the status value object.")

    def test_inner_h2_heading_passes_research_ok(self):
        self.assertTrue(L.research_ok(self.GOOD, ["src/A.cs"]))

    def test_several_inner_h2_headings_pass_research_ok(self):
        text = ("## Refactoring research\n\nRead `src/A.cs` and its close collaborators before touching anything.\n\n"
                "## Findings\n\n- `src/A.cs` `Save()`: 80-line method with duplicated validation; extract a specification "
                "object (in scope).\n- `src/A.cs` `status` strings: primitive obsession; a value object would make the "
                "rules explicit (follow-up: filed).\n\n"
                "## Notes\n\n- `src/A.cs` `Total()`: long conditional chain; one strategy per pricing rule keeps it "
                "readable (in scope).\n\nIn scope: extract the specification object. Follow-up: the status value object.")
        self.assertTrue(L.research_ok(text, ["src/A.cs"]))

    def test_inner_h2_still_rejects_thin_research(self):
        self.assertFalse(L.research_ok("## Refactoring research\n\nintro about src/A.cs.\n\n## Findings\n\n- none\n", ["src/A.cs"]))

    def test_inner_h2_stops_at_the_next_driver_section(self):
        plan = ("- `src/A.cs` `Save()` becomes a thin coordinator over the specification object; every rule moves out of it.\n"
                "- `src/A.cs` status strings move to the value object, with the parsing helper deleted and its callers updated.")
        self.assertFalse(L.research_ok("## Refactoring research\n\nintro about src/A.cs.\n\n## Refactoring plan\n\n" + plan, ["src/A.cs"]))

class ResearchBodyInnerH2(PromptMentions, unittest.TestCase):   # the inner-H2 research lands in the PR body as ONE top-level section
    RESEARCH = ResearchInnerH2.GOOD                                  # research text that carries an inner `## Findings`
    BULLETS = [l for l in ResearchInnerH2.FINDINGS.splitlines() if l.strip()]
    PLAN = "\n## Refactoring plan\n\nshrink\n"                       # the driver's own section after the research

    @staticmethod
    def h2_lines(text):   # the body's top-level H2 lines; an H2 written inside the research must never become one
        return [l for l in text.splitlines() if l.startswith("## ")]

    def test_inner_h2_research_gives_one_pr_section(self):
        b = L.with_research("Closes #9\n\nsummary\n\n", self.RESEARCH)
        self.assertEqual(b.count("## Refactoring research"), 1)
        self.assertIn("### Findings", b)                             # the inner H2 is demoted under the research
        self.assertNotIn("## Findings", self.h2_lines(b))            # ...and is not re-emitted as a second top-level section
        self.assertTrue(b.startswith("Closes #9"))                   # the body's own head is kept
        for line in self.BULLETS:                                    # every finding still reaches the PR body
            self.assertIn(line, b)

    def test_inner_h2_findings_appear_once(self):
        b = L.with_research("Closes #9\n\nsummary\n\n", self.RESEARCH)
        self.assertEqual(self.h2_lines(b), ["## Refactoring research"])          # nothing duplicated as a top-level section
        self.assertEqual(b.count("primitive obsession"), 1)                      # no repeated heading or bullet text
        for line in self.BULLETS:
            self.assertEqual([l for l in b.splitlines() if l == line], [line])   # each finding bullet exactly once

    def test_inner_h2_body_keeps_the_following_plan_section(self):
        b2 = L.with_research("Closes #9\n\n" + self.RESEARCH + self.PLAN, self.RESEARCH)
        self.assertIn("## Refactoring plan", b2)
        self.assertGreater(b2.index("Refactoring plan"), b2.index("Refactoring research"))
        self.assertEqual(b2.count("## Refactoring research"), 1)
        self.assertIn("### Findings", b2)
        self.assertTrue(L.research_ok(b2, ["src/A.cs"]))

    def test_replacing_a_body_research_section_leaves_no_leftovers(self):
        b = L.with_research("Closes #9\n\n" + self.RESEARCH + self.PLAN, self.RESEARCH)   # legacy body with an inner H2
        self.assertEqual(b.count("## Refactoring research"), 1)
        self.assertEqual(b.count("## Refactoring plan"), 1)
        self.assertNotIn("## Findings", self.h2_lines(b))
        self.assertEqual(self.h2_lines(b), ["## Refactoring research", "## Refactoring plan"])
        for line in self.BULLETS:                                                        # no leftovers of the old section
            self.assertEqual([l for l in b.splitlines() if l == line], [line])

    def test_research_prompt_uses_only_h3_subheadings(self):   # cmdemo1-dashboard#651: tell Pi, not just the body writer
        with fake_home() as h:
            d = make_driver(issue=9); d.s["plan"] = PLAN
            out, fu, prompt = d.research_prompt()
            self.assert_mentions(prompt, L.RESEARCH_HEAD, "###", "never `## `")   # starts at the heading, uses H3 subheadings, never an H2 inside

class ResearchHeadingLine(unittest.TestCase):   # the section starts at the heading LINE, never at an inline mention
    RESEARCH = ResearchInnerH2.GOOD
    BODY = ("Closes #9\n\nThe driver now reads the `## Refactoring research` section to its own next H2.\n\n"
            "Code by Pi (run `r1`).\n\n<!-- factory-pi-driver -->\n")

    def test_inline_mention_is_not_the_heading(self):
        self.assertEqual(L.research_head("see the `## Refactoring research` section"), -1)
        self.assertEqual(L.research_section("see the `## Refactoring research` section"), "")
        self.assertFalse(L.research_ok("prose about `## Refactoring research` in src/A.cs\n- a bullet line here\n- another bullet line", ["src/A.cs"]))

    def test_heading_at_start_and_after_inline_mention(self):
        self.assertEqual(L.research_head(self.RESEARCH), 0)
        text = "Mentions `## Refactoring research` inline.\n\n" + self.RESEARCH
        self.assertEqual(L.research_head(text), text.index("\n## Refactoring research") + 1)
        self.assertTrue(L.research_ok(text, ["src/A.cs"]))

    def test_summary_mentioning_the_heading_is_kept_in_the_pr_body(self):   # cmdemo1-system#890's own body was cut here
        b = L.with_research(self.BODY, self.RESEARCH)
        self.assertIn("The driver now reads the `## Refactoring research` section to its own next H2.", b)
        self.assertIn("Code by Pi (run `r1`).", b)
        self.assertIn("<!-- factory-pi-driver -->", b)                       # factory-wake recognises driver PRs by it
        self.assertEqual([l for l in b.splitlines() if l.startswith("## ")], ["## Refactoring research"])
        self.assertEqual(L.with_research(b, self.RESEARCH), b)               # syncing again changes nothing

    def test_crlf_heading_line(self):
        text = self.RESEARCH.replace("\n", "\r\n")
        self.assertEqual(L.research_head(text), 0)
        self.assertTrue(L.research_ok(text, ["src/A.cs"]))

    def test_blank_line_kept_before_the_driver_plan_and_stable(self):
        b = L.with_research("Closes #9\n\n" + self.RESEARCH + "\n\n## Refactoring plan\n\nshrink\n", self.RESEARCH)
        self.assertIn("\n\n## Refactoring plan", b)
        self.assertEqual(L.with_research(b, self.RESEARCH), b)

    def test_normalize_research_idempotent_and_leaves_deeper_headings(self):
        t = self.RESEARCH + "\n\n#### Deep\n"
        n = L.normalize_research(t)
        self.assertIn("### Findings", n); self.assertIn("\n#### Deep", n)
        self.assertEqual(L.normalize_research(n), n)
        self.assertEqual(L.normalize_research("no heading\n## Other\n"), "no heading\n## Other\n")

    def test_suffixed_driver_plan_heading_ends_the_section_and_survives(self):
        b = L.with_research("Closes #1\n\n" + self.RESEARCH + "\n\n## Refactoring plan (size baseline)\n\nx\n", self.RESEARCH)
        self.assertIn("## Refactoring plan (size baseline)\n\nx", b)
        self.assertEqual(L.with_research(b, self.RESEARCH), b)

    def test_research_preamble_before_the_heading_is_dropped(self):
        b = L.with_research("Closes #1\n", "Note: see `## Refactoring research`.\n\n" + self.RESEARCH)
        self.assertEqual([l for l in b.splitlines() if l.startswith("## ")], ["## Refactoring research"])
        self.assertNotIn("Note: see", b)

    def test_col_before_uses_board_order(self):
        self.assertEqual(L.Driver._col_before(None, ["TDD", "UAT"]), "Merged")
        self.assertEqual(L.Driver._col_before(None, ["Done"]), "UAT")

class ReviewFailOnPr(unittest.TestCase):   # cmdemo1-dashboard#1311: a review FAIL must be visible on the PR too
    def _driver(self, h, pr):
        d = make_driver(issue=9); d.s["pr"] = pr; sent = []
        d.comment = lambda body, pr=False: sent.append((pr, body))
        return d, sent

    def test_fail_goes_to_issue_and_pr(self):
        with fake_home() as h:
            d, sent = self._driver(h, 77)
            d.review_fail_comment("Review → In Progress\n\nReview: FAIL.\n\n- x")
            self.assertEqual([p for p, _ in sent], [False, True])
            self.assertEqual(sent[0][1], sent[1][1])

    def test_no_pr_yet_only_the_issue(self):
        with fake_home() as h:
            d, sent = self._driver(h, None)
            d.review_fail_comment("Review: FAIL")
            self.assertEqual([p for p, _ in sent], [False])

    def test_research_only_fix_path_leaves_journal_activity(self):   # no commit on this path: check 2 must see activity
        import inspect
        src = inspect.getsource(L.Driver.st_review)
        i = src.index("self.sync_pr_research()")
        self.assertIn('self.comment("Research re-done after the review FAIL', src[i:i + 300])

    def test_st_review_fail_comments_use_the_mirror(self):   # both FAIL branches go through review_fail_comment
        import inspect
        src = inspect.getsource(L.Driver.st_review)
        self.assertEqual(src.count("self.review_fail_comment("), 2)
        self.assertNotIn('self.comment("Review → In Progress', src)
        self.assertNotIn('self.comment(f"Review → In Progress', src)

class StagedFilesGate(unittest.TestCase):
    """The protected-file gate: item_loop.staged_files(sh, wt, default) (the files staged in the worktree's index
    relative to the merge base of HEAD and origin/<default>, with protected_files() applied to the result) and the
    `st_pr` enhancement gate that reads it. The staged_files tests run on a real temporary git repo: a bare origin
    remote, a main branch, and a worktree branched from an older main commit after main has advanced with a commit
    touching environments/prod/versions.json."""

    def build_repo(self, tmp):
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
        def git(*a, cwd):
            r = subprocess.run(["git", *a], cwd=cwd, env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(r.returncode, 0, f"git {' '.join(a)} failed: {r.stdout.strip()}")
        origin, work, wt = os.path.join(tmp, "origin.git"), os.path.join(tmp, "work"), os.path.join(tmp, "wt")
        git("init", "--bare", origin, cwd=tmp)
        git("init", "-b", "main", work, cwd=tmp)
        git("remote", "add", "origin", origin, cwd=work)
        def write(rel, text):
            p = os.path.join(work, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(text)
        write("environments/prod/versions.json", '{"v": 1}\n')
        write("factory/pi/sample.txt", "one\n")
        git("add", "-A", cwd=work)
        git("commit", "-m", "main A", cwd=work)
        a = subprocess.run(["git", "rev-parse", "HEAD"], cwd=work, env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True).stdout.strip()
        git("push", "origin", "main", cwd=work)
        # main advances past the fork point with a commit touching the protected production file
        write("environments/prod/versions.json", '{"v": 2}\n')
        git("add", "environments/prod/versions.json", cwd=work)
        git("commit", "-m", "main B (prod bump)", cwd=work)
        git("push", "origin", "main", cwd=work)
        # the worktree branches from the older main commit A
        git("worktree", "add", wt, "-b", "branch", a, cwd=work)
        def sh(cmd, cwd=None, check=True):
            r = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if check and r.returncode:
                raise RuntimeError(f"failed ({r.returncode}): {cmd}\n{r.stdout}")
            return r
        return sh, wt

    def stage(self, wt, rel, text):
        open(os.path.join(wt, rel), "a").write(text)
        subprocess.run(["git", "add", rel], cwd=wt, check=True)

    def test_staged_files_merge_base_protected_empty_for_factory_pi_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            sh, wt = self.build_repo(tmp)
            self.stage(wt, "factory/pi/sample.txt", "two\n")
            staged = L.staged_files(sh, wt, "main")
            self.assertEqual(sorted(staged), ["factory/pi/sample.txt"])   # only what the worktree staged; not main's prod bump
            self.assertEqual(L.protected_files(staged), [])

    def test_staged_files_merge_base_protected_nonempty_for_prod_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            sh, wt = self.build_repo(tmp)
            self.stage(wt, "factory/pi/sample.txt", "two\n")
            self.stage(wt, "environments/prod/versions.json", '{"v": 3}\n')
            staged = L.staged_files(sh, wt, "main")
            self.assertIn("environments/prod/versions.json", staged)
            self.assertNotEqual(L.protected_files(staged), [])

    def st_pr_driver(self, h, issue, base_reply, staged="src/A.cs\n"):
        """Dry-run enhancement Driver whose sh is the shared scripted fixture: `base_reply` is git merge-base's
        (returncode, stdout), `staged` the paths its index holds relative to that base."""
        d = make_driver(issue=issue)
        d.s["plan"] = dict(PLAN, kind="enhancement")
        d.s["wt"] = tempfile.mkdtemp(dir=h)
        d.s["default"] = "main"; d.s["gpu"] = "obs"; d.s["run_id"] = f"run{issue}"
        d.sh = scripted_sh({"merge-base": base_reply, "--name-only": staged,
                            "create": "https://github.com/x/cmdemo1-workorders/pull/43"})
        d.usage = lambda final=False: "usage"
        return d

    def name_only_diffs(self, d):
        return [c for c in d.sh.calls if c[:3] == ["git", "diff", "--cached"] and "--name-only" in c]

    def test_st_pr_protected_file_gate_diffs_against_the_merge_base(self):
        """The enhancement gate compares the index with merge-base(HEAD, origin/<default>), not main's tip."""
        with fake_home() as h:
            d = self.st_pr_driver(h, 31, (0, "0f5e8d2c1a4b6973\n"))
            d.st_pr()
            diffs = self.name_only_diffs(d)
            self.assertEqual([c[-1] for c in diffs], ["0f5e8d2c1a4b6973"])   # the merge base, never origin/main
            self.assertNotIn("origin/main", diffs[0])
            self.assertLess(d.sh.calls.index(["git", "add", "-A"]), d.sh.calls.index(diffs[0]))   # the add still comes first
            self.assertEqual(d.s["stage"], "ci")                                # clean files: on to the PR

            d2 = self.st_pr_driver(h, 32, (0, "0f5e8d2c1a4b6973\n"), staged="infra/main.bicep\n")
            d2.st_pr()
            self.assertEqual(d2.s["stage"], "blocked")                           # the gate still bites
            self.assertIn("credentials, secrets or production setup", d2.s["blocker"])
            self.assertEqual([c[-1] for c in self.name_only_diffs(d2)], ["0f5e8d2c1a4b6973"])

            # an unresolvable merge base falls back to origin/<default>: the gate never widens
            self.assertEqual(self.st_pr_driver(h, 33, (128, "")).merge_base(), "origin/main")
            self.assertEqual(self.st_pr_driver(h, 34, (0, "   \n")).merge_base(), "origin/main")

class PidfileKill:   # mixin for the process-group tests (#817, #839): fake children, their pidfiles and the two pidfile rules
    """A test's stand-in child records the pid(s) it started in a pidfile: _kill_pidfile runs in addCleanup so a failing
    test leaves nothing running, and _pid_gone proves a kill really reached them all."""

    def _kill_pidfile(self, pidfile):
        for pid in self._pids(pidfile):
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass

    def _pid_gone(self, pidfile, within=3.0):
        """True once every pid recorded in the file is dead: no such process, gone from /proc, or a zombie (reaped by init)."""
        deadline = time.monotonic() + within
        while True:
            pids = self._pids(pidfile)
            if pids and all(self._dead(p) for p in pids): return True
            if time.monotonic() >= deadline: return False
            time.sleep(0.05)

    @staticmethod
    def _pids(pidfile):
        """The pids a fake child recorded, one per whitespace-separated field ('' or a missing file records none)."""
        try: text = open(pidfile).read()
        except OSError: return []
        return [int(x) for x in text.split() if x.isdigit()]

    @staticmethod
    def _dead(pid):
        try: os.kill(pid, 0)
        except ProcessLookupError: return True
        try:
            with open(f"/proc/{pid}/status") as f:
                state = next((l.split()[1] for l in f if l.startswith("State:")), "?")
        except OSError: return True
        return state == "Z"

class RunTaskTimeout(PidfileKill, unittest.TestCase):   # cmdemo1-system#817: --timeout must die with Pi's whole process group
    """run-task ran Pi with subprocess.run(stdout=PIPE, timeout=...) and killed only the direct child. Pi's own tool
    subprocesses (`bash -c ...`) inherit that stdout pipe, so communicate() blocked until they exited: --timeout 1800
    ran 4263 s, and the GPU slot lock was held the whole time. run_pi() must put Pi in its own process group and
    SIGKILL the group. No real pi, no real pi-gpu, no real /tmp slot lock, no network, no secrets."""

    HERE = os.path.dirname(os.path.abspath(__file__))
    RUN_TASK = os.path.join(HERE, "run-task")        # no .py suffix; its main() runs only under __main__

    @classmethod
    def setUpClass(cls):
        loader = importlib.machinery.SourceFileLoader("run_task", cls.RUN_TASK)
        spec = importlib.util.spec_from_loader("run_task", loader)
        cls.rt = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.rt)

    def _fake_pi(self, tmp):
        """Stand-in for pi-gpu (takes and ignores any args): backgrounds a grandchild, records its pid, prints
        'started', then hangs itself -- what a hung Pi tool call looks like from the driver's side."""
        pidfile = os.path.join(tmp, "grandchild.pid")
        script = os.path.join(tmp, "fake-pi")
        with open(script, "w") as f:
            f.write("#!/usr/bin/env bash\n"
                    "sleep 300 &\n"
                    f'echo $! > "{pidfile}"\n'
                    "echo started\n"
                    "sleep 300\n")
        os.chmod(script, 0o755)
        self.addCleanup(self._kill_pidfile, pidfile)   # never leave a sleep 300 behind, even when the test fails
        return script, pidfile

    def test_run_pi_normal_exit_returns_rc_and_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, text = self.rt.run_pi(["bash", "-c", "echo hello; exit 3"], cwd=tmp, timeout=10)
            self.assertEqual(rc, 3)
            self.assertIn("hello", text)

    def _pi_on_path(self, tmp, body):
        """A fake `pi` executable first on PATH for this test (restored on cleanup)."""
        script = os.path.join(tmp, "pi")
        with open(script, "w") as f: f.write("#!/usr/bin/env bash\n" + body)
        os.chmod(script, 0o755)
        old = os.environ["PATH"]
        os.environ["PATH"] = tmp + os.pathsep + old
        self.addCleanup(os.environ.__setitem__, "PATH", old)

    def test_pi_version_returns_the_probe_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._pi_on_path(tmp, "echo '1.2.3'; echo noise >&2\n")
            self.assertEqual(self.rt.pi_version(timeout=10), "1.2.3", "stdout only, stripped")

    def test_pi_version_has_a_timeout_and_kills_a_hung_probe_group(self):
        self.assertGreater(self.rt.PI_VERSION_TIMEOUT_S, 0)
        self.assertEqual(self.rt.pi_version.__defaults__, (self.rt.PI_VERSION_TIMEOUT_S,), "the probe must default to the bounded timeout")
        with tempfile.TemporaryDirectory() as tmp:
            pidfile = os.path.join(tmp, "grandchild.pid")
            self.addCleanup(self._kill_pidfile, pidfile)
            self._pi_on_path(tmp, f'sleep 300 &\necho $! > "{pidfile}"\nsleep 300\n')
            t0 = time.monotonic()
            self.assertEqual(self.rt.pi_version(timeout=2), "", "a hung probe leaves the record without a version")
            self.assertLess(time.monotonic() - t0, 12)
            self.assertTrue(self._pid_gone(pidfile), "the probe's children must die with it")

    def test_run_pi_kills_whole_process_group_on_timeout(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake, pidfile = self._fake_pi(tmp)
            t0 = time.monotonic()
            rc, text = self.rt.run_pi([fake], cwd=tmp, timeout=2)
            elapsed = time.monotonic() - t0
            self.assertEqual(rc, 124, "a timed-out Pi run must report 124")
            self.assertIn("started", text)
            self.assertLess(elapsed, 12, f"--timeout 2 took {elapsed:.1f}s: it waited for the grandchildren to exit")
            self.assertTrue(self._pid_gone(pidfile), "the grandchild holding the stdout pipe must be killed too")

    def test_run_task_timeout_releases_slot_and_leaves_no_grandchild(self):
        # Safety first: without the two overrides below, running run-task end to end would take the real
        # /tmp/factory-pi-<gpu>-slot-N.lock and exec the real pi-gpu. Fail here instead of doing either.
        src = open(self.RUN_TASK).read()
        missing = [v for v in ("FACTORY_PI_GPU_BIN", "FACTORY_PI_LOCK_DIR") if v not in src]
        self.assertFalse(missing, "run-task must honour " + ", ".join("$" + v for v in missing) +
                                  ": tests must never take the real /tmp slot locks or exec the real pi-gpu")
        with tempfile.TemporaryDirectory() as tmp:
            fake, pidfile = self._fake_pi(tmp)
            run, cwd, lockdir = (os.path.join(tmp, x) for x in ("run", "work", "locks"))
            for d in (run, cwd, lockdir): os.makedirs(d)
            json.dump({"top_session": "t", "start": "2026-01-01T00:00:00+00:00", "pi_version": "0-test"},
                      open(os.path.join(run, "run.json"), "w"))   # so run-task never calls `pi --version`
            prompt = os.path.join(tmp, "prompt.md"); open(prompt, "w").write("do the task\n")
            env = {k: v for k, v in os.environ.items() if not k.startswith("LOCAL_LLM_")}   # no secrets to the child
            # floor down MIN_CLIENT_TIMEOUT_S or `--timeout 2` would become 300 s and outlast this 15 s test
            env.update({"FACTORY_PI_GPU_BIN": fake, "FACTORY_PI_LOCK_DIR": lockdir, "TMPDIR": tmp,
                        "FACTORY_MIN_CLIENT_TIMEOUT_S": "1"})
            try:
                proc = subprocess.run([sys.executable, self.RUN_TASK, "--run-dir", run, "--cwd", cwd,
                                       "--task", "t817", "--prompt-file", prompt, "--gpu", "obs", "--timeout", "2"],
                                      env=env, capture_output=True, text=True, timeout=15)
            except subprocess.TimeoutExpired:
                self.fail("run-task did not exit within 15 s of a --timeout 2 run")
            self.assertEqual(proc.returncode, 1, f"timeout is not PASS; stderr={proc.stderr[-500:]}")
            rec = [json.loads(l) for l in open(os.path.join(run, "tasks.jsonl"))][-1]
            self.assertEqual(rec["rc"], 124); self.assertEqual(rec["result"], "timeout")
            self.assertTrue(self._pid_gone(pidfile), "the grandchild must be killed with the Pi process group")
            f = open(os.path.join(lockdir, "factory-pi-obs-slot-0.lock"), "a")   # the slot must be free again
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.fail("the GPU slot lock is still held after the timeout")
            finally:
                fcntl.flock(f, fcntl.LOCK_UN); f.close()

    def test_result_of_covers_each_outcome(self):   # the result vocabulary: no-start / stalled, timeout, PASS, FAIL, exit N
        rt = self.rt
        self.assertEqual(rt.result_of(rt.NO_START_RC, False, "PASS"), "no-start")
        self.assertEqual(rt.result_of(rt.NO_START_RC, True, "PASS"), "stalled")
        self.assertEqual(rt.result_of(rt.TIMEOUT_RC, True, "PASS"), "timeout")
        self.assertEqual(rt.result_of(0, True, "done, PASS"), "PASS")
        self.assertEqual(rt.result_of(1, True, "done, FAIL"), "FAIL")
        self.assertEqual(rt.result_of(3, True, "crashed"), "exit 3")

class SharedTaskTimeout(unittest.TestCase):   # one Pi task's wall-clock budget is one shared constant, not three literals
    """1800 used to be spelled out in three places: Driver.pi's own default, the review call, and run-task's
    --timeout default. It now lives once in factory/pi/gpu.py (G.PI_TASK_TIMEOUT_S), is re-exported by item_loop
    (L.PI_TASK_TIMEOUT_S) and read by run-task. A plan task's own "timeout" must still win over that default."""

    def rt(self):   # run-task has no .py suffix: load it the way HandoffStartWatchdog.rt() does
        loader = importlib.machinery.SourceFileLoader("run_task_shared_timeout", os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-task"))
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("run_task_shared_timeout", loader)); loader.exec_module(m); return m

    def test_driver_pi_default_is_the_shared_constant(self):
        self.assertEqual(inspect.signature(L.Driver.pi).parameters["timeout"].default, L.G.PI_TASK_TIMEOUT_S,
                         "Driver.pi must default to the shared constant instead of its own literal or None")
        self.assertEqual(L.G.PI_TASK_TIMEOUT_S, L.PI_TASK_TIMEOUT_S,
                         "item_loop must re-export gpu.py's constant, never keep a second copy")
        self.assertEqual(L.PI_TASK_TIMEOUT_S, 1800, "one Pi task's wall-clock budget is 30 minutes")

    def test_run_task_timeout_default_is_the_shared_constant(self):
        rt = self.rt()
        class Parsed(Exception): pass   # raised from inside parse_args so main() stops before launching any Pi
        real = argparse.ArgumentParser.parse_args
        def spy(parser, args=None, namespace=None):
            real(parser, args=args, namespace=namespace)   # parse the patched argv (no --timeout given),
            raise Parsed(next(x.default for x in parser._actions if "--timeout" in x.option_strings))   # then read --timeout's default
        argv = ["run-task", "--run-dir", "/tmp/shared-timeout-run", "--cwd", "/tmp", "--task", "t", "--prompt-file", "/dev/null"]
        with mock.patch.object(argparse.ArgumentParser, "parse_args", spy), mock.patch.object(sys, "argv", argv):
            with self.assertRaises(Parsed) as cm: rt.main()
        self.assertEqual(cm.exception.args[0], L.G.PI_TASK_TIMEOUT_S,
                         "run-task --timeout must default to the shared constant, not its own literal")

    def test_explicit_task_timeout_still_flows_through(self):
        with fake_home():
            d = make_driver(issue=1)
            seen = []
            def rec(*a, **kw):   # record whatever timeout pi was handed (positional or keyword), then pass the task
                seen.append(a[2] if len(a) > 2 else kw.get("timeout")); return True
            d.pi = rec
            self.assertTrue(d.task_passes({"name": "t1", "prompt": "p", "timeout": 1234}))
            self.assertEqual(seen, [1234], "a plan task's own timeout must reach Driver.pi untouched")

class RunCmdGroupKill(PidfileKill, unittest.TestCase):   # cmdemo1-system#839: run_cmd must die with the whole process group
    """The factory's local commands move from their own subprocess.run / Popen pairs to one shared runner,
    item_loop.run_cmd(cmd, cwd=None, timeout=None, ...) (#839), so the one place that owns a timeout owns #817's rules:
    the child leads its own process group, so a timeout ends the child AND everything it started (Pi's tool subprocesses
    inherit the stdout pipe, so waiting for that pipe's EOF is what ran 4263 s on --timeout 1800), the output collected
    before the kill comes back on the exception because run-task re-reads it, a str command goes through the shell, a
    cwd= is honoured, and the child's stderr (the pipe is opened stderr=subprocess.STDOUT) lands in the one captured
    stdout. No network, no real pi, nothing outside a TemporaryDirectory; every pid a fake starts is killed in addCleanup."""

    def _fake_child(self, tmp):
        """Stand-in for a command that hangs together with what it started: backgrounds a grandchild (which inherits the
        stdout pipe), records its own pid and the grandchild's, prints 'started', then hangs itself. Returns the
        `bash -c` script body and the pidfile path; the pids in that file are killed whatever this test does next."""
        pidfile = os.path.join(tmp, "grandchild.pid")
        body = ("sleep 300 &\n"
                f'printf "%s %s\\n" "$$" "$!" > "{pidfile}"\n'
                "echo started\n"
                "sleep 300\n")
        self.addCleanup(self._kill_pidfile, pidfile)   # never leave a sleep 300 behind, even when the test fails
        return body, pidfile

    def test_run_cmd_returns_returncode_and_stdout_on_the_normal_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = L.run_cmd(["bash", "-c", "echo hello; exit 3"], cwd=tmp, timeout=10)
            self.assertIsInstance(r, subprocess.CompletedProcess)
            self.assertEqual(r.returncode, 3, "the child's own exit code comes back")
            self.assertIn("hello", r.stdout)

    def test_timeout_kills_the_whole_group_and_keeps_the_output_collected(self):
        with tempfile.TemporaryDirectory() as tmp:
            body, pidfile = self._fake_child(tmp)
            t0 = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired) as cm:
                L.run_cmd(["bash", "-c", body], cwd=tmp, timeout=2)
            elapsed = time.monotonic() - t0
            out = cm.exception.stdout
            self.assertIsNotNone(out, "the raised exception carries the output collected before the kill")
            needle = b"started" if isinstance(out, (bytes, bytearray)) else "started"   # text= decides which form
            self.assertIn(needle, out, "run-task re-reads this output, so the kill must not throw it away")
            self.assertLess(elapsed, 12, f"timeout=2 took {elapsed:.1f}s: it waited for the grandchildren to exit")
            self.assertTrue(self._pid_gone(pidfile), "the grandchild holding the stdout pipe must be killed too")

    def test_str_command_goes_through_the_shell_and_cwd_is_honoured(self):
        with tempfile.TemporaryDirectory() as tmp:
            wt = os.path.join(tmp, "wt"); os.makedirs(wt)
            r = L.run_cmd("pwd > here.txt; cat here.txt", cwd=wt, timeout=10)   # a str, so the shell must run it
            self.assertEqual(r.returncode, 0)
            self.assertEqual(r.stdout.strip(), os.path.realpath(wt), "cwd= is honoured, and the redirect proves the shell")
            self.assertTrue(os.path.exists(os.path.join(wt, "here.txt")), "the shell ran IN cwd: the redirect landed there")

    def test_child_stderr_is_merged_into_the_captured_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = L.run_cmd(["bash", "-c", "echo to-stdout; echo to-stderr >&2"], cwd=tmp, timeout=10)
            self.assertEqual(r.returncode, 0)
            self.assertIn("to-stdout", r.stdout)
            self.assertIn("to-stderr", r.stdout, "stderr=subprocess.STDOUT: one stream, the way run-task reads Pi")

    def _wait_for_pids(self, pidfile, within=10.0):
        """Block until the fake child has recorded its pids (it is then running, with its grandchild); fail if it never does."""
        deadline = time.monotonic() + within
        while len(self._pids(pidfile)) < 2:
            self.assertLess(time.monotonic(), deadline, "the fake child never recorded its pids")
            time.sleep(0.02)

    def test_no_timed_command_bypasses_run_cmd_in_the_driver_or_run_task(self):   # app_token's subprocess.run(timeout=60) was one
        here = os.path.dirname(os.path.abspath(__file__))
        for name in ("item_loop.py", "run-task"):
            src = open(os.path.join(here, name)).read()
            self.assertNotIn("subprocess.run(", src, f"{name}: a timed command must go through run_cmd, which kills the whole group")
        self.assertEqual(open(os.path.join(here, "run-task")).read().count("Popen("), 0)
        self.assertEqual(open(os.path.join(here, "item_loop.py")).read().count("Popen("), 1,
                         "only the detached nohup launch of the driver itself may use Popen outside runner.py")

    def test_exception_while_waiting_kills_the_whole_group(self):   # review: subprocess.run killed its child on ANY exception
        with tempfile.TemporaryDirectory() as tmp:
            body, pidfile = self._fake_child(tmp)
            def on_spawn(p):   # runs with the live child, before run_cmd waits on it
                self._wait_for_pids(pidfile)
                raise RuntimeError("driver bug while the child runs")
            t0 = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "driver bug"):
                L.run_cmd(["bash", "-c", body], cwd=tmp, timeout=60, on_spawn=on_spawn)
            self.assertLess(time.monotonic() - t0, 12, "the interrupted run waited for its timeout instead of killing the group")
            self.assertTrue(self._pid_gone(pidfile), "the child and its grandchild must not outlive the exception")

    def test_keyboard_interrupt_while_waiting_kills_the_whole_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            body, pidfile = self._fake_child(tmp)
            old = signal.signal(signal.SIGINT, signal.default_int_handler)   # a test runner may have replaced it
            self.addCleanup(signal.signal, signal.SIGINT, old)
            def interrupt_when_running():
                self._wait_for_pids(pidfile)
                os.kill(os.getpid(), signal.SIGINT)   # a real Ctrl-C, delivered to the thread blocked in run_cmd
            t = threading.Thread(target=interrupt_when_running, daemon=True)
            t.start()
            t0 = time.monotonic()
            with self.assertRaises(KeyboardInterrupt):
                L.run_cmd(["bash", "-c", body], cwd=tmp, timeout=60)
            t.join(5)
            self.assertLess(time.monotonic() - t0, 12, "the interrupted run waited for its timeout instead of killing the group")
            self.assertTrue(self._pid_gone(pidfile), "the child leads its own session, so the driver must kill its group on Ctrl-C")

    def test_app_token_mint_runs_through_run_cmd_and_a_timeout_kills_its_children(self):
        self.assertIs(inspect.signature(L.app_token).parameters["runner"].default, L.run_cmd,
                      "app_token must default to the shared group-killing runner, not subprocess.run")
        with tempfile.TemporaryDirectory() as tmp:
            body, pidfile = self._fake_child(tmp)
            def short_deadline(cmd, **k): return L.run_cmd(cmd, **{**k, "timeout": 2})   # app_token's own call, 60 s -> 2 s
            t0 = time.monotonic()
            tok = L.app_token({"GH_APP_TOKEN_CMD": body}, clock=lambda: 9000.0, runner=short_deadline)
            self.assertIsNone(tok, "a timed-out mint means no token: callers use the user login")
            self.assertLess(time.monotonic() - t0, 12)
            self.assertTrue(self._pid_gone(pidfile), "what the mint command started must die with it")
            L._app_tok.update(v=None, at=0.0)

class DriverShGroupKill(PidfileKill, unittest.TestCase):   # cmdemo1-system#839: Driver.sh must die with the whole process group
    """Driver.sh runs every command the item takes -- a `gh run watch` with timeout 6*3600, a verify command, git, pi --
    with subprocess.run(cmd, timeout=timeout), which ends only the direct child: everything that command started survives
    the deadline, still holding the stdout pipe it inherited (the #817 bug family: run-task's --timeout 1800 ran 4263 s
    and held the GPU slot the whole time, because reading that pipe to EOF waits for the grandchildren). Driver.sh must
    hand its command to item_loop.run_cmd, the one runner that owns the group rules.
    Only the timeout's behaviour is allowed to change: the argv, cwd=, timeout=, the single captured text stream, the
    shell rule, the App-token env, check=True's RuntimeError text, the rate-limit retry loop and the dry-run skip must
    all pass through untouched -- the cases below pin those down so the move is provably only a move. No network, no
    real gh, nothing outside a TemporaryDirectory; every pid a fake starts is killed in addCleanup."""

    APP_TOKEN = "ghs_" + "A" * 36                       # the same shape GhAppToken mints with printf
    _fake_child = RunCmdGroupKill._fake_child           # the #839 fake: a hang whose grandchild inherits the stdout pipe

    def setUp(self):
        self._app_env = os.environ.get("GH_APP_TOKEN_CMD")
        os.environ.pop("GH_APP_TOKEN_CMD", None)        # an App token only where a test asks for one
        L._app_tok.update(v=None, at=0.0)
    def tearDown(self):
        L._app_tok.update(v=None, at=0.0)
        if self._app_env is None: os.environ.pop("GH_APP_TOKEN_CMD", None)
        else: os.environ["GH_APP_TOKEN_CMD"] = self._app_env

    def _pid_dir(self):
        """Where the pidfiles of this class's fake children go. Registered FIRST, so addCleanup's LIFO order leaves the
        pidfile on disk for _kill_pidfile and removes the directory only afterwards -- inside fake_home it would be gone
        before the cleanup ran, and an orphan would outlive the test."""
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        return d

    def gh_recorder(self):
        """GhChokepoint's #828 recorder, reused as-is: records every (cmd, kwargs) the runner is handed, answers rc 0."""
        return GhChokepoint.gh_recorder(self)

    def run_recorder(self, replies=()):
        """An L.run_cmd stand-in: records every (cmd, kwargs) attempt and answers with `replies` in order (the last one
        repeats), a reply being a (returncode, stdout) pair or a CompletedProcess handed back as-is so the caller's
        result can be identity-checked. Install it with patch_run, so it answers whichever entry point Driver.sh uses --
        subprocess.run today, item_loop.run_cmd after #839."""
        calls = []
        def run(cmd, **k):
            calls.append((cmd, k))
            if not replies: return subprocess.CompletedProcess(cmd, 0, "", "")
            reply = replies[min(len(calls) - 1, len(replies) - 1)]
            if isinstance(reply, subprocess.CompletedProcess): return reply
            return subprocess.CompletedProcess(cmd, reply[0], reply[1], "")
        run.calls = calls
        return run

    def _sh_bounded(self, d, cmd, timeout, pidfile, budget=12):
        """d.sh(cmd, check=False, timeout=timeout) in a daemon thread, waited for `budget` seconds, so the one thing
        this timeout test must prove -- that the call comes back -- is proven by a bound and not by patience: a Driver.sh
        that waits for the grandchildren's inherited stdout pipe (which is what a runner reading to EOF does) would
        otherwise hang the suite for the lifetime of the fake. Over budget the recorded pids are killed to free the
        blocked read and the attempt is failed on the spot. Returns (elapsed, result_or_exception)."""
        box = {}
        def go():
            t0 = time.monotonic()
            try: box["v"] = d.sh(cmd, check=False, timeout=timeout)
            except BaseException as e: box["v"] = e     # the TimeoutExpired the caller must still see, or a surface change
            box["t"] = time.monotonic() - t0
        th = threading.Thread(target=go, daemon=True); th.start()
        th.join(budget)
        if th.is_alive():
            still = [p for p in self._pids(pidfile) if not self._dead(p)]
            self._kill_pidfile(pidfile)                 # free the pipe so the blocked read, and the test, can end
            th.join(30)
            self.fail(f"Driver.sh(timeout={timeout}) had not returned after {budget}s: the grandchild(ren) it left "
                      f"behind ({still or 'see ' + pidfile}) are still running and still hold the stdout pipe")
        return box["t"], box["v"]

    # (1) the smell: a timed-out long command must die with everything it started
    def test_sh_timeout_kills_the_whole_group_not_just_the_direct_child(self):
        pid_dir = self._pid_dir()                     # the pidfile must outlive the fake HOME, so it is not under it
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=839, dry_run=False)
            body, pidfile = self._fake_child(pid_dir)
            elapsed, v = self._sh_bounded(d, ["bash", "-c", body], timeout=2, pidfile=pidfile)
        self.assertIsInstance(v, subprocess.TimeoutExpired, f"a timed-out command must still raise, got {v!r}")
        self.assertLess(elapsed, 12, f"timeout=2 took {elapsed:.1f}s: it waited for the grandchildren's stdout")
        self.assertTrue(self._pid_gone(pidfile), "the grandchild must be killed with the process group")

    # (2) the handoff: Driver.sh -> the runner, command and keywords unchanged (the move must be only a move)
    def test_sh_hands_the_runner_the_command_cwd_timeout_and_streams_unchanged(self):
        with fake_home() as h:
            d = make_driver(repo="cmdemo1-system", issue=839, dry_run=False)
            sh, calls = self.gh_recorder()
            wt = os.path.join(h, "wt"); os.makedirs(wt)
            with patch_run(sh):
                d.sh(["gh", "run", "watch", "1"], cwd=wt, timeout=6 * 3600, check=False)   # the long watch
                d.sh("sleep 1; echo verify", cwd=wt, timeout=42, check=False)              # a verify command, as a str
                d.sh(["git", "-C", wt, "status"], check=False)                             # neither cwd= nor timeout=
            self.assertEqual([c for c, _ in calls],
                             [["gh", "run", "watch", "1"], "sleep 1; echo verify", ["git", "-C", wt, "status"]],
                             "the argv is handed over unchanged: a list stays a list, a str stays a str")
            self.assertEqual([k.get("cwd") for _, k in calls], [wt, wt, None])
            self.assertEqual([k.get("timeout") for _, k in calls], [6 * 3600, 42, None])
            for cmd, k in calls:   # one captured stream, read as text; the shell only for a str command
                self.assertIs(k.get("text", True), True, str(cmd))
                self.assertIs(k.get("stdout", subprocess.PIPE), subprocess.PIPE, str(cmd))
                self.assertIs(k.get("stderr", subprocess.STDOUT), subprocess.STDOUT, str(cmd))
                self.assertIs(k.get("shell", isinstance(cmd, str)), isinstance(cmd, str), str(cmd))

    def test_env_carries_gh_token_only_on_the_app_attempt_of_a_gh_command(self):
        """What the App-token tests already expect of the driver, restated as a handoff to the runner: a gh call goes out
        once with GH_TOKEN=<App token>, its user-login fallback and every non-gh command go out without one."""
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.APP_TOKEN}"
        run = self.run_recorder([(1, "gh: Resource not accessible by integration (HTTP 403)"), (0, "[]")])
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=839, dry_run=False)
            logs = []; d.log = logs.append
            with patch_run(run):
                r = d.sh(["gh", "pr", "list"], check=False)   # App attempt refused -> the same call on the user login
                d.sh(["git", "status"], check=False)          # never a gh command: never a token
        self.assertEqual([list(c) for c, _ in run.calls], [["gh", "pr", "list"], ["gh", "pr", "list"], ["git", "status"]],
                         "the refused attempt is re-run with the same argv")
        self.assertEqual([((k.get("env") or {}).get("GH_TOKEN")) for _, k in run.calls], [self.APP_TOKEN, None, None])
        self.assertEqual((r.returncode, r.stdout), (0, "[]"))
        self.assertTrue(any("user login" in m for m in logs))

    # (3) the surface: whatever the runner answers is what the caller always got
    def test_the_runners_result_flows_straight_back_to_the_caller(self):
        made = subprocess.CompletedProcess(["dotnet", "build"], 7, "dotnet build: FAIL\nsrc/A.cs(1,1): error CS0103\n", "")
        run, sh = self.run_recorder([made]), scripted_sh({"build": (7, "dotnet build: FAIL\nsrc/A.cs(1,1): error CS0103\n")})
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=839, dry_run=False)
            with patch_run(run):
                r = d.sh(["dotnet", "build"], check=False)
            self.assertIs(r, made, "the runner's own CompletedProcess is what Driver.sh returns")
            with patch_run(sh):   # the same (returncode, stdout) pair, this time straight from scripted_sh
                with self.assertRaises(RuntimeError) as cm:
                    d.sh(["dotnet", "build"], check=True)
        msg = str(cm.exception)
        self.assertIn("failed (7):", msg, "the runner's returncode still drives check=True")
        self.assertIn("dotnet build", msg)
        self.assertIn("error CS0103", msg, "and its stdout is what the failure text quotes")

    def test_the_rate_limit_retry_loop_still_runs_on_the_runners_stdout(self):
        rl = (1, "GraphQL: API rate limit exceeded for user ID 1.")
        run = self.run_recorder([rl, (0, "[]")])
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=839, dry_run=False)
            waits = []; d.wait_alive = lambda s, why: waits.append((s, why))   # never really sleep here
            with patch_run(run):
                r = d.gh("pr", "list")
            self.assertEqual(len(run.calls), 2, "the rate-limited reply is retried, then the second answer wins")
            self.assertEqual(waits, [(60, "gh rate limit, retry 1")])
            self.assertEqual((r.returncode, r.stdout), (0, "[]"))

    def test_dry_run_write_still_short_circuits_before_the_runner(self):
        run = self.run_recorder(); logs = []
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=839)   # dry_run=True
            d.log = logs.append
            with patch_run(run):
                r = d.sh(["gh", "pr", "comment", "1", "--body", "hi"], write=True)
            self.assertIsInstance(r, subprocess.CompletedProcess)
            self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
            self.assertEqual(run.calls, [], "a dry-run write never reaches the runner")
            self.assertEqual(logs, ["DRY-RUN skip: gh pr comment 1 --body hi"], "the DRY-RUN skip line is unchanged")

class VerifyEvidenceRunCmd(PidfileKill, unittest.TestCase):   # cmdemo1-system#839: verify's and st_review's commands move to the one runner too
    """The two local commands #839 left on their own subprocess.run: Driver.verify's
    `bash -o pipefail -c <verify_cmd>` (no timeout at all today, so a hung build outlives every deadline the item has)
    and st_review's per-criterion `bash -o pipefail -c <evidence_cmd>` (timeout=3600, which kills only the direct
    child: its grandchildren keep the stdout pipe open, the #817 family). Both must hand their command to
    item_loop.run_cmd, the one runner that owns the process-group rules.
    Only the timeout's behaviour may change: the argv (the `bash -o pipefail` included -- the driver's red/green
    decision is the PIPELINE's exit code, not the last command's), the worktree cwd, the single captured text stream,
    the (rc, stdout) pair the caller gets, the log files and the state bookkeeping all pass through untouched -- the
    cases below pin those down so the move is provably only a move. No network, no real build, nothing outside a
    TemporaryDirectory; every pid a fake starts is killed in addCleanup."""

    _pid_dir = DriverShGroupKill._pid_dir            # pidfiles that outlive the TemporaryDirectory they were written from
    run_recorder = DriverShGroupKill.run_recorder    # records every (cmd, kwargs) attempt, answers with `replies`

    class StepTime:                                  # stand-in for L.time: exact elapsed arithmetic, no wall-clock noise
        """time() answers with the next value of `values` (the last one repeats), so verify's three reads -- t0, the
        verify_s add, the log line -- come out as fixed numbers a test can assert on."""
        def __init__(self, *values): self.values = list(values)
        def time(self): return self.values.pop(0) if len(self.values) > 1 else self.values[0]
        def sleep(self, s): pass

    def driver(self, h, criteria=None):
        """A driver with a plan and a worktree: verify_cmd and one evidence_cmd, both the plainest real commands."""
        d = make_driver(repo="cmdemo1-system", issue=839, dry_run=False)
        wt = os.path.join(h, "wt"); os.makedirs(wt, exist_ok=True)
        d.s.update(plan=dict(PLAN, criteria=criteria or [dict(PLAN["criteria"][0])]), wt=wt,
                   gpu="pro5000", pr=7, stage="review")
        return d

    def assert_handed_over(self, cmd, k, argv, cwd, timeout):
        """The handoff both sites must make: the argv unchanged, the item's worktree as cwd, one captured text stream
        (stderr merged into stdout), the shell only ever for a str command, and that site's own timeout -- None for
        verify, 3600 for an evidence run -- handed over as it is today, never quietly added or dropped."""
        self.assertEqual(list(cmd), argv, str(cmd))
        self.assertEqual(k.get("cwd"), cwd, str(cmd))
        self.assertIs(k.get("stdout", subprocess.PIPE), subprocess.PIPE, str(cmd))
        self.assertIs(k.get("stderr", subprocess.STDOUT), subprocess.STDOUT, str(cmd))
        self.assertIs(k.get("text", True), True, str(cmd))
        self.assertIs(k.get("shell", isinstance(cmd, str)), isinstance(cmd, str), str(cmd))
        self.assertEqual(k.get("timeout"), timeout, f"{cmd}: timeout= must be exactly {timeout!r}")

    # (1) Driver.verify -> the runner, with its bookkeeping untouched
    def test_verify_hands_the_runner_the_command_cwd_streams_and_no_timeout(self):
        stdout = "Build FAILED.\nsrc/A.cs(1,1): error CS0103: x\n"
        with fake_home() as h:
            d = self.driver(h)
            d.s.update(verify_runs=5, verify_s=12.5)            # the counters must keep counting from where they are
            logs = []; d.log = logs.append
            run = self.run_recorder([(7, stdout)])
            old_time, L.time = L.time, self.StepTime(1e6, 1e6 + 1, 1e6 + 2)
            try:
                with patch_run(run):
                    rc, out = d.verify("x")
            finally:
                L.time = old_time
            # read everything back while the fake HOME still exists: it is a TemporaryDirectory, it goes on exit
            log_text = open(os.path.join(d.run_dir, "logs", "verify-x.log")).read()
            saved = json.load(open(d.state_p))
            self.assertEqual(len(run.calls), 1, "one verify is one command run")
            self.assert_handed_over(*run.calls[0], argv=["bash", "-o", "pipefail", "-c", PLAN["verify_cmd"]],
                                    cwd=d.s["wt"], timeout=None)
            self.assertEqual((rc, out), (7, stdout), "the caller still gets the runner's (rc, stdout) pair")
            self.assertEqual(log_text, stdout, "logs/verify-<name>.log keeps the same (scrubbed) content under the same name")
            self.assertEqual((d.s["verify_runs"], d.s["verify_s"]), (6, 13.5), "one run counted, the elapsed seconds added")
            self.assertEqual((saved["verify_runs"], saved["verify_s"]), (6, 13.5), "and saved, as before")
            self.assertEqual(logs, ["verify x: exit 7 in 2s"], "the verify log line is unchanged")

    # (2) st_review's per-criterion evidence run -> the runner, with its hour and its evidence list untouched
    def test_st_review_hands_the_runner_the_evidence_command_cwd_and_its_hour_timeout(self):
        out = "Test run for A\nPassed!  - failed: 0, passed: 12\n"
        with fake_home() as h:
            d = self.driver(h)
            d.independent_review = lambda: None     # the evidence pass is all this case is about; the verdict is another
            d.pi = d.blocker = lambda *a, **k: self.fail("a passing criterion reaches neither Pi nor a Blocker")
            run = self.run_recorder([(0, out)])
            with patch_run(run):
                d.st_review()
            log_text = open(os.path.join(d.run_dir, "logs", "evidence-1.log")).read()   # read it back before HOME goes
            self.assertEqual(len(run.calls), 1, "one criterion, one evidence run")
            self.assert_handed_over(*run.calls[0], argv=["bash", "-o", "pipefail", "-c", "dotnet test --filter A"],
                                    cwd=d.s["wt"], timeout=3600)
            self.assertEqual(log_text, out, "logs/evidence-<i>.log keeps the same (scrubbed) content under the same name")
            self.assertEqual(d.s["evidence"], [["A works", "dotnet test --filter A", "Passed!  - failed: 0, passed: 12"]],
                             "the saved evidence list is unchanged: criterion, command, last non-empty line")
            self.assertEqual(d.s["counts"]["review_fail"], 0, "a passing criterion is still not a review FAIL")

    # (3) the contract the two commands rely on, held by the runner itself
    def test_pipefail_comes_back_as_the_pipelines_code_not_the_last_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(L.run_cmd(["bash", "-o", "pipefail", "-c", "false | true"], cwd=tmp, timeout=10).returncode, 1,
                             "a verify pipeline that fails at any stage is RED: local_green and the review verdict read this")
            self.assertEqual(L.run_cmd(["bash", "-c", "false | true"], cwd=tmp, timeout=10).returncode, 0,
                             "and it is the `-o pipefail` in the argv that decides it, so the helper must pass it through")

    def _fake_pipeline(self, pid_dir):
        """Stand-in for a verify/evidence command that hangs inside a pipeline: it records its own pid, backgrounds a
        `sleep 300` (inheriting the stdout pipe), prints 'started', then hangs in a pipeline whose own `sleep 300`
        records itself too -- every grandchild a hung verify leaves behind is in that pidfile, an ungrouped kill
        included. Returns the `bash -c` script body and the pidfile; those pids are killed whatever else happens."""
        pidfile = os.path.join(pid_dir, "pipeline.pid")
        body = ("sleep 300 &\n"
                f'printf "%s %s\\n" "$$" "$!" > "{pidfile}"\n'
                "echo started\n"
                f'( sleep 300 & printf " %s\\n" "$!" >> "{pidfile}"; wait ) | true\n')
        self.addCleanup(self._kill_pidfile, pidfile)     # never leave a sleep 300 behind, even when the test fails
        return body, pidfile

    def test_hanging_pipeline_times_out_with_the_whole_group_dead(self):
        pid_dir = self._pid_dir()                        # the pidfile must outlive the TemporaryDirectory the run is in
        body, pidfile = self._fake_pipeline(pid_dir)
        with tempfile.TemporaryDirectory() as tmp:
            t0 = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired) as cm:
                L.run_cmd(["bash", "-o", "pipefail", "-c", body], cwd=tmp, timeout=2)
            elapsed = time.monotonic() - t0
        self.assertLess(elapsed, 12, f"timeout=2 took {elapsed:.1f}s: it waited for the pipeline's grandchildren")
        out = cm.exception.output
        needle = b"started" if isinstance(out, (bytes, bytearray)) else "started"   # text= decides which form
        self.assertIn(needle, out or (b"" if isinstance(needle, bytes) else ""),
                      "the output collected before the kill comes back on the exception")
        self.assertTrue(self._pid_gone(pidfile), "the backgrounded sleep and the pipeline's sleep must die with the group")

    # (4) the guard: these two sites are on the one runner, not on their own subprocess.run
    def test_verify_and_st_review_do_not_call_subprocess_run_directly(self):
        import inspect
        for name in ("verify", "st_review"):
            with self.subTest(site=name):
                src = inspect.getsource(getattr(L.Driver, name))
                self.assertIsNone(re.search(r"\bsubprocess\.run\s*\(", src),
                                  f"Driver.{name} still runs its own subprocess.run: every deadline must go through run_cmd")

class GpuGate(unittest.TestCase):   # cmdemo1-system#861: hard caps pro5000 2, pro6000 1, obs 1, ts3 1 for every Pi launch
    """On Nov 21 a Pi session ran `rm -f /tmp/factory-pi-*-slot-*.lock`; new run-tasks then took "free" slots on new
    inodes while the old holders still ran (3 on pro5000, 2 on ts3 and obs). Only a private slot dir is used here."""
    HERE = os.path.dirname(os.path.abspath(__file__))
    GATE = os.path.join(HERE, "gpu_gate.py")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(); self.procs = []
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_LLM_", "FACTORY_GPU_"))}
        self.env["FACTORY_PI_LOCK_DIR"] = os.path.join(self.tmp, "slots")
        self.addCleanup(self._reap)

    def _reap(self):
        for p in self.procs:
            if p.poll() is None: p.kill()
            p.wait()

    def hold(self, gpu, *extra, secs=30):
        """Start `gpu_gate.py hold GPU [extra] -- sleep secs` in the background; returns the Popen."""
        p = subprocess.Popen([sys.executable, self.GATE, "hold", gpu, *extra, "--", "sleep", str(secs)], env=self.env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.procs.append(p); return p

    def held(self, gpu):
        out = subprocess.run([sys.executable, self.GATE, "status", "--json"], env=self.env, capture_output=True,
                             text=True, check=True).stdout
        return json.loads(out)[gpu]["held"]

    def wait_held(self, gpu, n, within=10.0):
        deadline = time.monotonic() + within
        while time.monotonic() < deadline:
            if self.held(gpu) == n: return True
            time.sleep(0.1)
        return False

    def test_default_caps_are_the_hard_caps_and_overrides_only_lower(self):
        sys.path.insert(0, self.HERE); import gpu_gate
        self.assertEqual(gpu_gate.caps({}), {"pro5000": 2, "pro6000": 1, "obs": 1, "ts3": 1})
        self.assertEqual(gpu_gate.caps({"FACTORY_GPU_CAPS": "pro5000=5,obs=0,ts3=x"}), {"pro5000": 2, "pro6000": 1, "obs": 0, "ts3": 1})
        self.assertEqual(gpu_gate.caps({"FACTORY_GPU_CAPS": "pro6000=3"})["pro6000"], 1)   # never raised past 1

    def test_caps_hold_under_concurrent_acquisition(self):
        for gpu, cap in (("pro5000", 2), ("pro6000", 1), ("obs", 1), ("ts3", 1)):
            ps = [self.hold(gpu, "--no-wait") for _ in range(5)]   # five launches race for the GPU at once
            time.sleep(2.0)
            running = [p for p in ps if p.poll() is None]
            self.assertEqual(len(running), cap, f"{gpu}: {len(running)} holders, cap {cap}")
            self.assertTrue(all(p.returncode == 75 for p in ps if p not in running), f"{gpu}: the rest must exit 75")
            self.assertEqual(self.held(gpu), cap)

    def test_waiters_start_only_as_slots_free(self):
        first = self.hold("obs", secs=2)
        self.assertTrue(self.wait_held("obs", 1))
        second = self.hold("obs", secs=30)                 # waits instead of starting
        time.sleep(1.0); self.assertEqual(self.held("obs"), 1)
        first.wait(timeout=10)
        self.assertTrue(self.wait_held("obs", 1, within=12)); self.assertIsNone(second.poll())

    def test_slot_is_released_when_the_holder_is_killed(self):
        p = self.hold("ts3"); self.assertTrue(self.wait_held("ts3", 1))
        p.send_signal(signal.SIGKILL); p.wait(timeout=5)
        q = self.hold("ts3", "--no-wait"); self.assertTrue(self.wait_held("ts3", 1))
        time.sleep(0.5); self.assertIsNone(q.poll(), "the slot of a SIGKILLed holder must be free again")

    def test_deleting_slot_files_does_not_free_a_slot(self):
        self.hold("pro5000"); self.hold("pro5000"); self.assertTrue(self.wait_held("pro5000", 2))
        d = self.env["FACTORY_PI_LOCK_DIR"]
        for f in os.listdir(d): os.remove(os.path.join(d, f))      # what the Nov 21 Pi session did in /tmp
        third = self.hold("pro5000", "--no-wait"); third.wait(timeout=10)
        self.assertEqual(third.returncode, 75, "a deleted slot file must still count as held")
        self.assertEqual(self.held("pro5000"), 2)

    def test_legacy_slots_count_but_not_the_launchers_own_parent(self):
        legacy = os.path.join(self.tmp, "legacy"); os.makedirs(legacy); self.env["FACTORY_PI_LEGACY_LOCK_DIR"] = legacy
        hold_legacy = ("import fcntl,os,subprocess,sys; f=open(os.path.join(sys.argv[1],'factory-pi-obs-slot-0.lock'),'w');"
                       "fcntl.flock(f,fcntl.LOCK_EX); sys.exit(subprocess.call(sys.argv[2:]))")
        other = subprocess.Popen([sys.executable, "-c", hold_legacy, legacy, "sleep", "30"], env=self.env)
        self.procs.append(other); self.assertTrue(self.wait_held("obs", 1))      # an old run-task elsewhere: counted
        blocked = self.hold("obs", "--no-wait"); blocked.wait(timeout=10); self.assertEqual(blocked.returncode, 75)
        other.kill(); other.wait(); self.assertTrue(self.wait_held("obs", 0))
        # an old run-task whose new pi-gpu launches Pi: its own legacy slot must not block it
        own = subprocess.run([sys.executable, "-c", hold_legacy, legacy, sys.executable, self.GATE, "hold", "obs",
                              "--no-wait", "--", "true"], env=self.env, timeout=20)
        self.assertEqual(own.returncode, 0, "the launcher's own parent slot must not count against it")
        self.hold("pro5000"); self.assertTrue(self.wait_held("pro5000", 1))   # new slot + legacy twin: one task
        self.hold("pro5000", "--no-wait"); self.assertTrue(self.wait_held("pro5000", 2))
        mine = self.hold("obs"); self.assertTrue(self.wait_held("obs", 1))        # new slot + its legacy twin
        f = open(os.path.join(legacy, "factory-pi-obs-slot-0.lock"), "w")         # what an old run-task tries
        with self.assertRaises(BlockingIOError, msg="old run-tasks must see the gate's slot as taken"):
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        f.close()

    def test_every_pi_launch_path_goes_through_the_gate(self):
        src = lambda n: open(os.path.join(self.HERE, n)).read()
        self.assertIn('gpu_gate.py" hold "$gpu" -- pi ', src("pi-gpu"))          # manual runs, the watchdog, run-task
        self.assertNotRegex(src("pi-gpu"), r"(?m)^exec pi ")
        self.assertIn('pi-gpu" pro5000', src("pi-pro5000"))                     # the shim goes through pi-gpu
        rt = src("run-task")
        self.assertIn("gpu_gate.acquire_any(", rt); self.assertIn("pass_fds", rt); self.assertNotIn("/tmp", rt)
        self.assertIn('"run-task"', src("item_loop.py"))                        # drivers launch Pi only via run-task
        for n in os.listdir(self.HERE):                                          # no other tool starts Pi itself
            path = os.path.join(self.HERE, n)
            if n in ("pi-gpu", "test_item_loop.py") or not os.path.isfile(path) or n.endswith(".pyc"): continue
            self.assertNotRegex(open(path, errors="replace").read(), r"(?m)(^|[;&|]\s*|exec\s+)pi\s+--provider",
                                f"{n} starts Pi without the gate")

    def test_run_task_hands_its_slot_to_pi_gpu(self):
        rt = importlib.util.module_from_spec(importlib.util.spec_from_loader(
            "run_task_861", importlib.machinery.SourceFileLoader("run_task_861", os.path.join(self.HERE, "run-task"))))
        rt.__spec__.loader.exec_module(rt)
        os.environ["FACTORY_PI_LOCK_DIR"] = self.env["FACTORY_PI_LOCK_DIR"]
        self.addCleanup(os.environ.pop, "FACTORY_PI_LOCK_DIR", None)
        import gpu_gate
        fd = gpu_gate.acquire("obs", wait=False); self.assertIsNotNone(fd)
        env = dict(self.env, FACTORY_GPU_SLOT_FD=f"obs:{fd}")
        code = "import gpu_gate,sys; print(gpu_gate.held_fd('obs'))"
        rc, out = rt.run_pi([sys.executable, "-c", code], cwd=self.HERE, timeout=20, slot_fd=fd, env=env)
        os.close(fd)
        self.assertEqual((rc, out.strip()), (0, str(fd)), "pi-gpu must see the slot run-task passed down")

class SharedRunCmd(PidfileKill, unittest.TestCase):   # cmdemo1-system#839: run-task's Pi launch moves onto run_cmd too
    """run_pi() is the last Pi launch in factory/pi that still owns its own subprocess.Popen, so #817's process-group
    rules are written twice: once in item_loop.run_cmd, once here (#839 asks for one chokepoint, and item_loop.run_cmd
    is it -- its on_spawn hands the child back before any waiting, which is exactly what run_pi's hand-off watchdog
    needs). Pin the one behaviour that move must not change: the watchdog still gets a live child and still calls the
    stall / no-start rc (HandoffStartWatchdog), a hung Pi's grandchild -- the one that inherits the stdout pipe --
    still dies with the group, the GPU slot fd and FACTORY_GPU_SLOT_FD still reach the child (#861), and Driver.sh is
    already on the runner. RunTaskTimeout above (#817) is left exactly as it is: rc 124, result "timeout", the slot
    lock reacquirable, no grandchild. No real pi, no real pi-gpu, no real /tmp slot lock, no network, no secrets."""

    HERE = os.path.dirname(os.path.abspath(__file__))
    RUN_TASK = os.path.join(HERE, "run-task")        # no .py suffix; its main() runs only under __main__

    setUp = GpuGate.setUp                  # the #861 slot-fd fixture: a private FACTORY_PI_LOCK_DIR, no LOCAL_LLM_* env
    _reap = GpuGate._reap                  # ... and the reap of every child that fixture lets a test start
    _pid_dir = DriverShGroupKill._pid_dir  # pidfiles that outlive the TemporaryDirectory the run is in

    def rt(self):
        loader = importlib.machinery.SourceFileLoader("run_task_839", self.RUN_TASK)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("run_task_839", loader)); loader.exec_module(m); return m

    def _fake_pi(self, tmp, pid_dir):
        """Stand-in for a Pi that really starts and then hangs: writes THIS launch's session file (a header plus one
        assistant record, so the hand-off is 'started' and the stall rule is the one that fires), backgrounds a
        grandchild that inherits the stdout pipe, records both pids, prints 'started', then hangs itself -- what a hung
        Pi tool call looks like from the driver's side. Returns the script path and the pidfile; those pids are killed
        whatever this test does next."""
        pidfile = os.path.join(pid_dir, "grandchild.pid")
        script = os.path.join(pid_dir, "fake-pi")
        sess = os.path.join(tmp, "s.jsonl")
        with open(script, "w") as f:
            f.write("#!/usr/bin/env bash\n"
                    f"echo '{HDR}' > {sess}\n"
                    f"echo '{ASSISTANT}' >> {sess}\n"
                    "sleep 300 &\n"
                    f'printf "%s %s\\n" "$$" "$!" > "{pidfile}"\n'
                    "echo started\n"
                    "sleep 300\n")
        os.chmod(script, 0o755)
        self.addCleanup(self._kill_pidfile, pidfile)   # never leave a sleep 300 behind, even when the test fails
        return script, pidfile

    # (1) the chokepoint: one runner for every deadline, no launcher writing its own subprocess call
    def test_run_pi_and_driver_sh_are_on_run_cmd_not_on_their_own_subprocess_calls(self):
        import inspect
        src = inspect.getsource(self.rt().run_pi)
        for call in ("Popen", "run"):
            with self.subTest(call=f"subprocess.{call}"):
                self.assertIsNone(re.search(rf"\bsubprocess\.{call}\s*\(", src),
                                  "run_pi still starts its own subprocess." + call +
                                  ": #839 wants one runner -- item_loop.run_cmd owns the process-group rules")
        self.assertRegex(src, r"\brun_cmd\s*\(", "run_pi must hand its launch to item_loop.run_cmd")
        self.assertIsNone(re.search(r"\bsubprocess\.run\s*\(", inspect.getsource(L.Driver.sh)),
                          "Driver.sh still runs its own subprocess.run: every deadline must go through run_cmd")

    # (2) the watchdog: the handle run_cmd gives back is a live child, and the stall rc is unchanged
    def test_the_watchdog_still_gets_a_live_child_and_the_stall_rc_stands(self):
        rt = self.rt()
        pid_dir = self._pid_dir()
        beats = []
        def beat(d):   # the beat proves the watchdog was handed a child that was ALIVE when it polled
            try: os.kill(d["pi_pid"], 0); alive = True
            except ProcessLookupError: alive = False
            beats.append(dict(d, alive=alive))
        with tempfile.TemporaryDirectory() as tmp:
            fake, pidfile = self._fake_pi(tmp, pid_dir)
            t0 = time.monotonic()
            rc, text = rt.run_pi([fake], cwd=tmp, timeout=30, sdir=tmp, start_s=1.5, stall_s=1.5, beat=beat)
            elapsed = time.monotonic() - t0
        self.assertEqual(rc, rt.NO_START_RC, "a Pi that stops being active after its first model output is still rc 125")
        self.assertTrue(rt.run_pi.started, "model output arrived, so this is a stall and not a no-start")
        self.assertIn("started", text)
        self.assertLess(elapsed, 12, f"stall_s=1.5 took {elapsed:.1f}s: the kill must not wait for the grandchildren")
        self.assertTrue(beats and all(b["alive"] for b in beats),
                        "the watchdog must be handed a live child: every beat's pi_pid is a running process")
        self.assertTrue(any(b["model_output"] for b in beats), "and it still sees this launch's session records")
        self.assertTrue(self._pid_gone(pidfile), "the grandchild holding the stdout pipe must be killed with the group")

    # (3) the slot: run-task's GPU slot fd and its env still reach Pi (the #861 gate stays shut)
    def test_the_slot_fd_and_the_gpu_env_still_reach_the_child(self):
        rt = self.rt()
        os.environ["FACTORY_PI_LOCK_DIR"] = self.env["FACTORY_PI_LOCK_DIR"]   # the fixture's private slot dir
        self.addCleanup(os.environ.pop, "FACTORY_PI_LOCK_DIR", None)
        import gpu_gate
        fd = gpu_gate.acquire("obs", wait=False)
        self.assertIsNotNone(fd, "the fixture must really take a slot in the private lock dir")
        self.addCleanup(gpu_gate.release, fd)
        env = dict(self.env, FACTORY_GPU_SLOT_FD=f"obs:{fd}")
        code = ("import gpu_gate, os; print('ENVD=' + (os.environ.get('FACTORY_GPU_SLOT_FD') or 'missing')); "
                "print('HELD=' + str(gpu_gate.held_fd('obs')))")
        rc, out = rt.run_pi([sys.executable, "-c", code], cwd=self.HERE, timeout=20, slot_fd=fd, env=env)
        self.assertEqual(rc, 0, out[-500:])
        self.assertIn(f"ENVD=obs:{fd}", out, "the child still sees FACTORY_GPU_SLOT_FD: pi-gpu's gate reads the slot from it")
        self.assertIn(f"HELD={fd}", out, "and the fd itself is open in the child, so the slot is held as long as Pi lives")

class Scrubbing(unittest.TestCase):
    def test_tunnel_hosts_and_every_gpu_secret_are_redacted(self):
        for host in ("pro5000", "pro6000", "5070ti", "5060ti"):
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

    def test_run_task_uses_the_shared_scrub(self):   # 838: run-task imports the shared module; item_loop only re-exports it
        p = os.path.dirname(os.path.abspath(__file__))
        rt = open(os.path.join(p, "run-task")).read()
        self.assertIn("from scrub import scrub", rt); self.assertNotIn("item_loop", rt); self.assertIn('"--gpu"', rt)
        il = open(os.path.join(p, "item_loop.py")).read()
        self.assertIn("from scrub import", il)                                # the compatibility re-export keeps every call site working
        self.assertNotIn("SECRET_RE = re.compile", il); self.assertNotIn("def scrub(", il)   # the rule set itself lives in scrub.py only

class SharedScrubModule(unittest.TestCase):   # 838: one scrub rule set in factory/pi/scrub.py; item_loop re-exports it, run-task imports it.
    # 'scrub' is imported INSIDE each test (never at the top) so the rest of the suite stays runnable while factory/pi/scrub.py is absent.
    def rt(self):
        loader = importlib.machinery.SourceFileLoader("run_task_838", os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-task"))
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("run_task_838", loader)); loader.exec_module(m); return m

    def test_item_loop_reexports_the_same_regex_and_function(self):
        scrub = importlib.import_module("scrub")
        self.assertIs(scrub.SECRET_RE, L.SECRET_RE, "item_loop must re-export the shared pattern, not a copy of it")
        self.assertIs(scrub.scrub, L.scrub, "item_loop must re-export the shared function itself, so every existing call site keeps working")

    def test_run_task_binds_that_same_scrub_function(self):
        scrub = importlib.import_module("scrub")
        self.assertIs(self.rt().scrub, scrub.scrub, "run-task must go through the shared scrub, not its own copy")

    def test_add_secret_source_redacts_a_caller_owned_value(self):
        scrub = importlib.import_module("scrub")
        long_v, short_v = "own" + "Z" * 30, "own" + "Y" * 3   # built at run time so the secret scan sees no literal
        sources = list(scrub.SECRET_SOURCES)                   # the module's source list: save it, restore it in the finally,
                                                               # so no other test sees this registration
        try:
            scrub.add_secret_source(lambda: long_v)
            out = scrub.scrub(f"a {long_v} b")
            self.assertNotIn(long_v, out); self.assertIn("[redacted]", out)
            scrub.add_secret_source(lambda: short_v)
            self.assertIn(short_v, scrub.scrub(f"a {short_v} b"), "a value of 6 characters or fewer is not a secret")
            scrub.add_secret_source(lambda: None)
            self.assertEqual(scrub.scrub("a plain line"), "a plain line", "a source with nothing to hide changes nothing")
        finally:
            scrub.SECRET_SOURCES[:] = sources

    def test_item_loop_registers_its_cached_app_token(self):
        scrub = importlib.import_module("scrub")               # item_loop's scrub IS scrub.scrub: the App token is registered there
        tok = "app" + "Q" * 30                                 # built at run time so the secret scan sees no literal
        try:
            L._app_tok.update(v=tok, at=1.0)
            self.assertNotIn(tok, L.scrub(f"x {tok} y"), "the cached App token value must disappear from scrubbed output")
            self.assertNotIn(tok, scrub.scrub(f"x {tok} y"), "and through the shared module's own entry point too")
        finally:
            L._app_tok.update(v=None, at=0.0)

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

class ResumeTarget(unittest.TestCase):   # the paused-item resume rule, pure: resume_target(state) -> (stage, clear_gpu)
    def test_blocked_with_resume_stage(self):
        s = {"status": "blocked", "stage": "review", "resume_stage": "review", "pr": 7, "blocker": "checks still red"}
        self.assertEqual(L.resume_target(s), ("review", False))
        self.assertEqual(L.resume_target({"status": "blocked", "resume_stage": "ci", "pr": 7}), ("ci", False))

    def test_blocked_without_resume_stage_with_pr(self):
        self.assertEqual(L.resume_target({"status": "blocked", "stage": "review", "pr": 7}), ("ci", False))

    def test_blocked_without_resume_stage_without_pr(self):
        self.assertEqual(L.resume_target({"status": "blocked", "stage": "implement"}), ("implement", False))

    def test_does_not_mutate_the_state(self):
        s = {"status": "blocked", "resume_stage": "ci", "pr": 7, "blocker": "x", "gpu": "obs", "counts": {"ci_fix": 2}}
        before = dict(s); L.resume_target(s); self.assertEqual(s, before)
        e = {"status": "error", "stage": "pickup", "gpu": "obs", "error": "boom"}
        before = dict(e); L.resume_target(e); self.assertEqual(e, before)

    def test_error_resumes_the_saved_stage(self):
        self.assertEqual(L.resume_target({"status": "error", "stage": "ci", "error": "boom"}), ("ci", False))
        self.assertEqual(L.resume_target({"status": "error", "stage": "implement", "pr": 7}), ("implement", False))
        self.assertEqual(L.resume_target({"status": "error", "stage": "merge"}), ("merge", False))

    def test_error_at_gpu_or_pickup_maps_to_gpu_and_clears_the_recorded_gpu(self):
        self.assertEqual(L.resume_target({"status": "error", "stage": "gpu", "gpu": "obs"}), ("gpu", True))
        self.assertEqual(L.resume_target({"status": "error", "stage": "pickup", "gpu": "ts3"}), ("gpu", True))

class ResumeAfterError(unittest.TestCase):   # resuming an error state: keeps the saved stage, never jumping to ci (PR exists) or implement
    def test_blocked_still_resumes_resume_stage(self):
        # a status: blocked state still resumes its saved resume_stage (never jumping to ci or implement),
        # drops the blocker field and resets the counts -- the existing blocked behavior stays intact
        for rs in ("review", "ci", "implement"):
            for pr in (None, 7):
                s = {"status": "blocked", "stage": "blocked", "resume_stage": rs, "blocker": "checks still red",
                     "counts": {k: 5 for k in L.LIMITS}}
                if pr is not None: s["pr"] = pr
                r = L.apply_resume(s)
                self.assertEqual(r["stage"], rs, f"a blocked item with resume_stage {rs} (pr={pr}) must resume there, not ci or implement")
                self.assertNotIn("blocker", r)
                self.assertEqual(r["counts"], {k: 0 for k in L.LIMITS})
        for s, want in (({"status": "blocked", "stage": "review", "pr": 7, "blocker": "x", "counts": {k: 5 for k in L.LIMITS}}, "ci"),
                        ({"status": "blocked", "stage": "implement", "blocker": "x", "counts": {k: 5 for k in L.LIMITS}}, "implement")):
            r = L.apply_resume(s)
            self.assertEqual(r["stage"], want, "without a saved resume_stage: ci when a PR exists, implement otherwise")
            self.assertNotIn("blocker", r)
            self.assertEqual(r["counts"], {k: 0 for k in L.LIMITS})

    def test_error_resumes_saved_stage_not_implement_or_ci(self):
        for stage in ("implement", "local-verify", "ci", "review", "merge", "research"):
            for pr in (None, 7):
                s = {"status": "error", "stage": stage, "error": "boom", "counts": {k: 5 for k in L.LIMITS}}
                if pr is not None: s["pr"] = pr
                r = L.apply_resume(s)
                self.assertEqual(r["stage"], stage, f"an error at {stage} (pr={pr}) must resume the saved stage, not ci or implement")
                self.assertNotIn("error", r)
                self.assertEqual(r["counts"], {k: 0 for k in L.LIMITS})

    def test_error_in_gpu_or_pickup_clears_recorded_gpu(self):
        for stage in ("gpu", "pickup"):
            s = {"status": "error", "stage": stage, "gpu": "obs", "error": "boom"}
            r = L.apply_resume(s)
            self.assertEqual(r["stage"], "gpu", f"an error at {stage} with a recorded gpu must resume the gpu stage")
            self.assertNotIn("gpu", r)   # the recorded gpu is cleared, so the gpu stage re-picks instead of keeping it

    def test_errone_gpu_item_repicks_and_waits(self):
        rec = []
        real = L.gpu_for_item
        with patched_driver_env(time=Clock(),
                                gpu_for_item=lambda *a: (rec.append(a), real(*a))[1],   # watch what st_gpu passes in
                                gpu_health=lambda max_age=600: {"obs": ("UNREACHABLE", "down"), "pro5000": ("HEALTHY", ""), "ts3": ("HEALTHY", "")}) as h:
            d = L.Driver("cmdemo1-workorders", 29)   # dry_run=False
            d.s["plan"] = dict(PLAN, size="large"); d.s["gpu"] = "obs"
            d.s["stage"] = "gpu"; d.s["status"] = "error"; d.s["error"] = "boom"; d.save()
            d.s = L.apply_resume(d.s); d.save()     # the resume rule: saved stage, error dropped, gpu cleared
            self.assertNotIn("gpu", d.s)
            d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
            d.st_gpu()
            self.assertEqual(rec[0][0], None)        # st_gpu re-ran gpu_for_item with the cleared gpu
            self.assertEqual(d.s["gpu"], "pro5000")  # obs is down, so the free healthy pick is pro5000
            self.assertEqual(d.s["stage"], "pickup")

    def test_errone_gpu_item_waits_while_gpus_held_then_blocks(self):
        with patched_driver_env(time=Clock(),
                                gpu_health=lambda max_age=600: {g: ("HEALTHY", "") for g in ("pro5000", "obs", "ts3")}) as h:
            # Live items in another repo hold every available GPU: both pro5000 slots, obs and ts3.
            runs = os.path.join(h, "factory-runs")
            for i, (gpu, stage) in enumerate((("pro5000", "ci"), ("pro5000", "ci"), ("obs", "implement"), ("ts3", "review"))):
                r = os.path.join(runs, f"cmdemo1-dashboard-{11 + i}"); os.makedirs(r)
                json.dump({"repo": "cmdemo1-dashboard", "issue": 11 + i, "gpu": gpu, "stage": stage,
                          "status": "running", "pid": os.getpid()}, open(os.path.join(r, "state.json"), "w"))
            d = L.Driver("cmdemo1-workorders", 28)   # dry_run=False
            d.s["plan"] = dict(PLAN, size="large")
            d.s["stage"] = "gpu"; d.s["status"] = "error"; d.s["error"] = "boom"; d.save()   # the gpu is already cleared
            d.comment = lambda *a, **k: None; d.usage = lambda final=False: ""; d.wake_bot = lambda reason: None
            d.st_gpu()
            self.assertNotIn("gpu", d.s)                        # never re-picked: it stays in the gpu stage
            self.assertEqual(d.s["stage"], "blocked")
            self.assertEqual(d.s["status"], "blocked")
            self.assertEqual(d.s["resume_stage"], "gpu")        # it resumes the gpu stage, never implement or ci
            self.assertNotIn(d.s["stage"], ("implement", "ci"))
            self.assertTrue(d.s["wait_why"].startswith("no free GPU"), d.s["wait_why"])
            self.assertTrue(d.s["blocker"].startswith(f"waited {L.GPU_WAIT_H} hours to start (no free GPU"),
                            d.s["blocker"])

class OneResumeRule(unittest.TestCase):   # cmdemo1-system#855: resume_plan(state) -> Resume is the ONE resume rule;
    # start --resume, hold_blocked's wake of a blocked item and an error resume all ask it and apply its answer.
    GREEN = [{"name": "Build result", "bucket": "pass"}, {"name": "secret-scan", "bucket": "pass"}]

    def paused(self, **kw):
        """A blocked item with the limits burnt out, as a Blocker leaves it; `kw` overrides any field."""
        s = {"status": "blocked", "stage": "blocked", "resume_stage": "ci", "pr": 5, "gpu": "obs",
             "blocker": "required checks still red after 3 Pi fix passes.", "counts": {k: 5 for k in L.LIMITS}}
        s.update(kw); return s

    def start(self, state, resume=True):
        """`item-loop start --resume` on a run dir whose state.json holds `state`, with gh and the detached launch
        faked out and `resume_plan` spied on. Returns (the state.json the command left, the rule calls it saw)."""
        seen, launched = [], []
        real = L.resume_plan
        def spy(st, wake=False):
            seen.append(bool(wake)); return real(st, wake=wake)
        class Proc: pid = 4242
        def fake_popen(*c, **k):
            launched.append(c); return Proc()
        a = argparse.Namespace(repo="cmdemo1-workorders", issue=31, top_session=None, dry_run=False, resume=resume)
        with fake_home():
            d = L.Driver("cmdemo1-workorders", 31, dry_run=False)
            json.dump(dict(PLAN, repo="cmdemo1-workorders", issue=31), open(os.path.join(d.run_dir, "plan.json"), "w"))
            d.s.update(state); d.save()
            with patch_run(FakeGhProcess([(0, "[]")])), fake_modules({(L, "resume_plan"): spy, (L.subprocess, "Popen"): fake_popen}):
                L.cmd_start(a)
            self.assertEqual(len(launched), 1, "start still launches the driver exactly once")
            return json.load(open(d.state_p)), seen

    def hold(self, **kw):
        """A blocked driver holding for its PR to turn clean (its own checks answer GREEN, nothing is posted)."""
        d = make_driver(issue=33, dry_run=False)
        d.s.update(self.paused(resume_stage="review"))
        d.s.update(kw)
        d.pr_checks = lambda: ("GREEN", self.GREEN)
        d.comment = lambda *a, **k: None
        return d

    # ---- the rule itself: one decision object, stage + fields cleared + counters
    def test_the_rule_answers_each_pause_shape_with_one_decision(self):
        self.assertEqual(L.resume_plan(self.paused()), L.Resume("ci", clears=("blocker",)))
        self.assertEqual(L.resume_plan(self.paused(resume_stage="merge")), L.Resume("merge", clears=("blocker",)))
        self.assertEqual(L.resume_plan(self.paused(resume_stage=None)), L.Resume("ci", clears=("blocker",)))
        self.assertEqual(L.resume_plan(self.paused(resume_stage=None, pr=None)), L.Resume("implement", clears=("blocker",)))
        self.assertEqual(L.resume_plan({"status": "error", "stage": "ci", "pr": 5, "error": "boom"}),
                         L.Resume("ci", clears=("error",)))
        self.assertEqual(L.resume_plan({"status": "error", "stage": "gpu", "gpu": "obs"}),
                         L.Resume("gpu", clears=("error",), clear_gpu=True))
        self.assertIsNone(L.resume_plan({"status": "running", "stage": "ci"}), "a live item is not resumable")
        self.assertIsNone(L.resume_plan(None), "no state at all is not resumable either")

    def test_the_wake_half_of_the_rule_is_the_rules_own(self):
        self.assertEqual(L.resume_plan(self.paused(resume_stage="merge"), wake=True),
                         L.Resume("review", clears=("blocker",), status="running"))
        self.assertIsNone(L.resume_plan(self.paused(resume_stage="implement"), wake=True),
                          "a pause raised before the PR gate does not wake itself")
        self.assertIsNone(L.resume_plan(self.paused(resume_stage=None), wake=True))
        self.assertIsNone(L.resume_plan(self.paused(pr=None), wake=True), "no PR: nothing turned green")
        self.assertIsNone(L.resume_plan(self.paused(blocker="independent review FAIL twice: - x"), wake=True),
                          "a Review FAIL Blocker never clears itself (hold_resumes)")

    def test_apply_is_pure_and_clears_only_what_the_rule_says(self):
        st = self.paused()
        out = L.resume_plan(st).apply(st)
        self.assertEqual(st["counts"], {k: 5 for k in L.LIMITS}, "apply never touches the caller's state dict")
        self.assertIn("blocker", st)
        self.assertEqual(out["stage"], "ci"); self.assertNotIn("blocker", out)
        self.assertEqual(out["counts"], L.fresh_counts())
        hurt = self.paused(error="driver boom")
        both = L.resume_plan(hurt).apply(hurt)
        self.assertNotIn("blocker", both); self.assertEqual(both["error"], "driver boom",
                                                            "a blocked item clears its Blocker, not an unrelated error field")
        self.assertEqual(out["gpu"], "obs", "a blocked item keeps its GPU: only a gpu/pickup error clears it")
        self.assertEqual(out["status"], "blocked", "the start resume leaves the status to the driver's own run()")
        err = {"status": "error", "stage": "pickup", "gpu": "obs", "error": "boom"}
        got = L.resume_plan(err).apply(err)
        self.assertEqual((got["stage"], "gpu" in got, "error" in got), ("gpu", False, False))
        self.assertEqual(L.Resume("ci", reset_counts=False).apply({"counts": {"ci_fix": 2}})["counts"], {"ci_fix": 2})

    # ---- path 1: item-loop start --resume (Jeffrey answered the Blocker)
    def test_start_resume_goes_through_the_rule(self):
        s, seen = self.start(self.paused(resume_stage="review"))
        self.assertEqual(seen, [False], "start --resume asks the one resume rule once, and nothing else decides")
        self.assertEqual(s["stage"], "review")
        self.assertNotIn("blocker", s)
        self.assertEqual(s["counts"], {k: 0 for k in L.LIMITS})

    def test_start_without_the_resume_flag_never_asks_the_rule(self):
        s, seen = self.start(self.paused(resume_stage="review"), resume=False)
        self.assertEqual(seen, [], "only --resume resumes; a plain start never touches a paused item")
        self.assertEqual(s["stage"], "blocked"); self.assertIn("blocker", s)
        self.assertEqual(s["counts"], {k: 5 for k in L.LIMITS})

    # ---- path 2: the wake-resume of a blocked item (its PR turned clean on its own)
    def test_wake_resume_goes_through_the_rule(self):
        seen = []
        real = L.resume_plan
        def spy(st, wake=False):
            seen.append(bool(wake)); return real(st, wake=wake)
        with patched_driver_env(sleep=lambda s: None):
            d = self.hold()
            with fake_modules({(L, "resume_plan"): spy}):
                self.assertTrue(d.hold_blocked())
            self.assertEqual(seen, [True], "the blocked driver's wake-up asks the one resume rule (wake=True)")
            s = json.load(open(d.state_p))
            self.assertEqual((s["stage"], s["status"]), ("review", "running"))
            self.assertNotIn("blocker", s)
            self.assertEqual(s["counts"], {k: 0 for k in L.LIMITS})

    def test_wake_resume_applies_the_rules_decision_and_no_knowledge_of_its_own(self):
        with patched_driver_env(sleep=lambda s: None):
            d = self.hold()
            with fake_modules({(L, "resume_plan"): lambda st, wake=False: L.Resume("merge", clears=("blocker", "error"),
                                                                               status="running")}):
                self.assertTrue(d.hold_blocked())
            self.assertEqual((d.s["stage"], d.s["status"]), ("merge", "running"),
                             "hold_blocked runs the stage the rule chose, never one of its own")
            self.assertNotIn("blocker", d.s); self.assertNotIn("error", d.s)
            self.assertEqual(d.s["counts"], L.fresh_counts(), "the counters reset because the rule said reset_counts")

    def test_hold_blocked_holds_no_resume_knowledge_of_its_own(self):
        src = inspect.getsource(L.Driver.hold_blocked)
        for frag in ('"ci", "review", "merge"', "resume_stage", "counts", "LIMITS", 'pop("blocker"', "status="):
            self.assertNotIn(frag, src, frag)
        self.assertIn("resume_plan", src, "hold_blocked asks the one resume rule")

    # ---- path 3: an error resume (start --resume of an item that died instead of blocking)
    def test_error_resume_goes_through_the_rule(self):
        s, seen = self.start({"status": "error", "stage": "pickup", "gpu": "obs", "error": "boom",
                             "counts": {k: 5 for k in L.LIMITS}})
        self.assertEqual(seen, [False], "the error resume asks the same rule as the Blocker resume")
        self.assertEqual(s["stage"], "gpu", "a gpu/pickup error re-enters the gpu stage")
        self.assertNotIn("error", s); self.assertNotIn("gpu", s, "and re-picks a GPU instead of keeping the old record")
        self.assertEqual(s["counts"], {k: 0 for k in L.LIMITS})

    def test_error_resume_keeps_a_later_stage_and_its_gpu(self):
        s, seen = self.start({"status": "error", "stage": "review", "gpu": "ts3", "pr": 5, "error": "boom",
                             "counts": {k: 5 for k in L.LIMITS}})
        self.assertEqual(seen, [False])
        self.assertEqual((s["stage"], s["gpu"]), ("review", "ts3"), "a mid-review error resumes the review, GPU kept")
        self.assertNotIn("error", s)

    # ---- the writing half: what blocker() records for the rule to read back
    def test_blocker_records_the_resume_target_through_the_rule(self):
        with fake_home():
            d = make_driver(issue=34)
            d.usage = lambda final=False: ""; d.comment = lambda body, pr=False: None
            d.s["stage"] = "review"; d.blocker("checks still red")
            self.assertEqual(d.s["resume_stage"], "review")
            d.blocker("still red after the wake-up")
            self.assertEqual(d.s["resume_stage"], "review", "a second Blocker never moves the recorded resume target")
            self.assertIn("paused_resume_stage", inspect.getsource(L.Driver.blocker))
            self.assertEqual((L.paused_resume_stage({"stage": "ci"}), L.paused_resume_stage({"stage": "blocked", "resume_stage": "merge"})),
                             ("ci", "merge"))
            self.assertEqual(L.resume_plan({"status": "blocked", "stage": "blocked", "resume_stage": "review", "blocker": "x"}),
                             L.Resume("review", clears=("blocker",)), "and the rule reads that target back")

    def test_cmd_start_routes_through_the_rule(self):
        src = inspect.getsource(L.cmd_start)
        self.assertIn("apply_resume", src, "start --resume goes through the rule's functional entry point")
        self.assertNotIn('"blocked", "error"', src, "cmd_start no longer lists the paused statuses itself")
        self.assertEqual(L.PAUSED_STATUSES, ("blocked", "error"))
        self.assertEqual(L.WAKE_RESUME_STAGES, ("ci", "review", "merge"))

class GpuHealthCacheDi(unittest.TestCase):   # cmdemo1-system#868: the GPU health cache is injectable; GPU health is fully faked with no network
    def test_cache_probes_once_within_max_age_and_again_after(self):
        probes = []
        def health():
            probes.append(1)
            return {g: ("HEALTHY", "") for g in G.GPUS}
        t = [1000.0]
        cache = L.GpuHealthCache(now=lambda: t[0], health=health)
        self.assertEqual(cache(600), {g: ("HEALTHY", "") for g in G.GPUS})
        t[0] += 300
        self.assertEqual(cache(600), {g: ("HEALTHY", "") for g in G.GPUS})
        self.assertEqual(probes, [1], "300 s old is inside max_age 600: no second probe")
        t[0] += 301
        cache(600)
        self.assertEqual(len(probes), 2, "601 s old: the injected health probes again")

    def test_zero_max_age_reprobes_on_the_next_tick(self):
        probes = []
        def health():
            probes.append(1)
            return {g: ("HEALTHY", "") for g in G.GPUS}
        t = [1000.0]
        cache = L.GpuHealthCache(now=lambda: t[0], health=health)
        cache(0); t[0] += 1; cache(0)
        self.assertEqual(len(probes), 2, "max_age 0: a probe on every tick (the reviewer_waited path re-checks each loop)")
        t[0] += 1; cache(600)
        self.assertEqual(len(probes), 2, "max_age 600: a 1 s tick is still fresh")

    def test_module_gpu_health_delegates_to_the_shared_instance(self):
        fake = {g: ("HEALTHY", "") for g in G.GPUS}
        def boom(**kw):
            raise AssertionError("no probe: the shared cache already holds the result")
        old = (L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h)
        L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h = (lambda: 1e9, boom, 1e9, fake)
        try:
            self.assertEqual(L.gpu_health(600), fake)
            self.assertIs(L.gpu_health(600), fake)   # the cached dict, not a copy
        finally:
            L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h = old

    def test_driver_default_health_is_the_module_gpu_health_resolved_at_construction(self):
        with fake_home():
            self.assertIs(make_driver(issue=101).gpu_health, L.gpu_health)   # default: the shared module probe
        fake = lambda max_age=600: {g: ("HEALTHY", "") for g in G.GPUS}
        old = L.gpu_health
        L.gpu_health = fake
        try:
            with fake_home():
                self.assertIs(make_driver(issue=102).gpu_health, fake)   # a patch before construction is honored
        finally:
            L.gpu_health = old

    def test_injected_cache_fakes_st_gpu_with_no_network(self):
        seen = []
        def health():
            seen.append(1)
            return {g: ("HEALTHY", "") for g in G.GPUS}
        cache = L.GpuHealthCache(now=lambda: 1e9, health=health)
        with patched_driver_env(time=Clock()) as h:
            d = make_driver(issue=104, health=cache)
            self.assertIs(d.gpu_health, cache)
            d.s["plan"] = dict(PLAN); d.save()
            d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
            d.st_gpu()
        self.assertEqual(d.s["stage"], "pickup")
        self.assertEqual(d.s["gpu"], G.pick_gpu(G.classify_size(PLAN), list(G.GPUS), set()))
        self.assertEqual(seen, [1], "probed exactly once, through the injected cache")

    def test_default_driver_uses_the_shared_cache_without_network(self):
        fake = {g: ("HEALTHY", "") for g in G.GPUS}
        def no_probe(**kw):
            raise AssertionError("no network: the shared cache is fresh, nothing may probe")
        old = (L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h)
        L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h = (lambda: 1e9, no_probe, 1e9, fake)
        try:
            with patched_driver_env(time=Clock()) as h:
                d = L.Driver("cmdemo1-workorders", 103)   # dry_run=False, default health = the shared module probe
                d.s["plan"] = dict(PLAN); d.s["stage"] = "gpu"; d.save()
                d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
                d.st_gpu()
        finally:
            L._HEALTH.now, L._HEALTH.health, L._HEALTH.at, L._HEALTH.h = old
        self.assertEqual(d.s["stage"], "pickup")
        self.assertEqual(d.s["gpu"], G.pick_gpu(G.classify_size(PLAN), list(G.GPUS), set()))

    def test_independent_review_uses_the_injected_cache(self):
        seen = []
        def health():
            seen.append(1)
            return {g: ("HEALTHY", "") for g in G.GPUS}
        cache = L.GpuHealthCache(now=lambda: 1e9, health=health)
        with patched_driver_env(research_ok=lambda *a: True) as h:
            d = make_driver(issue=105, health=cache)
            d.s.update(gpu="ts3", size="small", wt=tempfile.mkdtemp(dir=h), plan=dict(PLAN), pr=7, default="main")
            d.save()
            d.merge_base = lambda: "abc"
            review = []
            rec = json.dumps({"task": "independent-review-1", "gpu": "pro5000", "result": "PASS"})
            def sh(cmd, **k):
                if "--gpu" in cmd: review.append(list(cmd)); return subprocess.CompletedProcess(cmd, 0, rec, "")
                return subprocess.CompletedProcess(cmd, 0, "body\n## Refactoring research\n- x" if "pr" in cmd else "", "")
            d.sh = sh
            d.independent_review()
        self.assertEqual(review[0][review[0].index("--gpu") + 1], "pro5000,pro6000,obs")   # every healthy GPU but the author's ts3
        self.assertEqual(seen, [1], "the reviewer wait probed exactly once, through the injected cache")

# Asking unittest for one test as `<file> <Class>.<test>` (e.g. `python3 -m unittest factory/pi/test_item_loop.py
# RunTaskTimeout.test_run_pi_normal_exit_returns_rc_and_output`) does not work out of the box: unittest resolves every
# CLI name on its own, so it never reads <Class> off the file given before it -- it imports it as a module and the whole
# run dies as `ModuleNotFoundError: No module named 'RunTaskTimeout'` (FAILED (errors=1)) whatever the code does. Alias
# the TestCase classes defined here under their own names so that form resolves. It changes no assertion and no result:
# `python3 -m unittest factory/pi/test_item_loop.py` (what CI runs) and
# `factory.pi.test_item_loop.<Class>.<test>` load these same classes and run these same tests.
for _cls in [_c for _c in list(globals().values())
             if isinstance(_c, type) and issubclass(_c, unittest.TestCase) and _c.__module__ == __name__]:
    sys.modules.setdefault(_cls.__name__, _cls)

class GhAppToken(unittest.TestCase):   # gh reads/writes use the GitHub App token when GH_APP_TOKEN_CMD is set; any refusal falls back to the user login
    FAKE = "ghs_" + "A" * 36
    def setUp(self):
        L._app_tok.update(v=None, at=0.0)
        self.env = os.environ.get("GH_APP_TOKEN_CMD")
    def tearDown(self):
        L._app_tok.update(v=None, at=0.0)
        if self.env is None: os.environ.pop("GH_APP_TOKEN_CMD", None)
        else: os.environ["GH_APP_TOKEN_CMD"] = self.env

    def test_unset_means_no_token(self):
        self.assertIsNone(L.app_token({}))

    def test_token_cached_then_refreshed_before_expiry(self):
        calls, t = [], [1000.0]
        def runner(cmd, **k): calls.append(cmd); return L.subprocess.CompletedProcess(cmd, 0, f"tok{len(calls)}\n", "")
        env = {"GH_APP_TOKEN_CMD": "mint"}
        self.assertEqual(L.app_token(env, clock=lambda: t[0], runner=runner), "tok1")
        t[0] += L.GH_APP_TOKEN_TTL_S - 1
        self.assertEqual(L.app_token(env, clock=lambda: t[0], runner=runner), "tok1")
        t[0] += 2
        self.assertEqual(L.app_token(env, clock=lambda: t[0], runner=runner), "tok2")
        self.assertLess(L.GH_APP_TOKEN_TTL_S, 3600)

    def test_failing_mint_falls_back_to_none(self):
        self.assertIsNone(L.app_token({"GH_APP_TOKEN_CMD": "mint"}, runner=lambda c, **k: L.subprocess.CompletedProcess(c, 1, "", "")))
        def boom(c, **k): raise OSError("no such command")
        L._app_tok.update(v=None, at=0.0)
        self.assertIsNone(L.app_token({"GH_APP_TOKEN_CMD": "mint"}, runner=boom))

    def test_app_denied_matches_refusals_only(self):
        for out in ("gh: Resource not accessible by integration (HTTP 403)", "HTTP 401: Bad credentials",
                    "GraphQL: Resource not accessible by integration"):
            self.assertTrue(L.app_denied(out), out)
        for out in ("", "HTTP 404: Not Found", "no pull requests match", "Pull request is not mergeable: required status check"): self.assertFalse(L.app_denied(out), out)

    def run_gh(self, replies):
        """d.gh() with subprocess.run returning `replies` in order; returns (result, [GH_TOKEN seen per call], driver logs)."""
        captured = []
        with patched_driver_env(run=FakeGhProcess(replies, captured)) as h:
            d = make_driver(issue=8); logs = []; d.log = logs.append
            res = d.gh("pr", "list", check=False)
        return res, [(k.get("env") or {}).get("GH_TOKEN") for k in captured], logs

    def test_gh_uses_app_token_when_it_works(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.FAKE}"
        res, seen, _ = self.run_gh([(0, "[]")])
        self.assertEqual((res.returncode, seen), (0, [self.FAKE]))

    def test_gh_falls_back_to_user_login_on_403(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.FAKE}"
        res, seen, logs = self.run_gh([(1, "gh: Resource not accessible by integration (HTTP 403)"), (0, "[]")])
        self.assertEqual((res.returncode, seen), (0, [self.FAKE, None]))
        self.assertTrue(any("user login" in l for l in logs))
        self.assertFalse(any(self.FAKE in l for l in logs))

    def test_gh_without_app_cmd_never_sets_token(self):
        os.environ.pop("GH_APP_TOKEN_CMD", None)
        res, seen, _ = self.run_gh([(0, "[]")])
        self.assertEqual(seen, [None])

    def test_non_permission_failure_is_not_retried_on_user_login(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.FAKE}"
        res, seen, _ = self.run_gh([(1, "HTTP 404: Not Found")])
        self.assertEqual((res.returncode, len(seen)), (1, 1))

    def test_401_drops_cached_token(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.FAKE}"
        self.run_gh([(1, "HTTP 401: Bad credentials"), (0, "[]")])
        self.assertEqual(L._app_tok, {"v": None, "at": 0.0})

    def test_pr_and_issue_create_stay_on_user_login(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.FAKE}"
        for args in (("pr", "create", "--title", "t"), ("issue", "create", "--title", "t")):
            seen = []
            with patched_driver_env(run=lambda *a, **k: (seen.append(k.get("env")), L.subprocess.CompletedProcess(a, 0, "", ""))[1]) as h:
                make_driver(issue=8).gh(*args)
            self.assertEqual(seen, [None], args)

    def test_failed_mint_is_not_retried_every_call(self):
        calls, t = [], [5000.0]
        def runner(cmd, **k): calls.append(1); return L.subprocess.CompletedProcess(cmd, 1, "", "")
        env = {"GH_APP_TOKEN_CMD": "mint"}
        for _ in range(3): L.app_token(env, clock=lambda: t[0], runner=runner)
        self.assertEqual(len(calls), 1)
        t[0] += L.GH_APP_MINT_RETRY_S + 1
        L.app_token(env, clock=lambda: t[0], runner=runner)
        self.assertEqual(len(calls), 2)

    def test_scrub_redacts_cached_app_token_value(self):
        L._app_tok.update(v="opaque-token-value", at=1.0)
        self.assertNotIn("opaque-token-value", L.scrub("x opaque-token-value y"))

class DraftPlanPrompt(unittest.TestCase):   # the draft-plan prompt is pure: no driver, no network, no Pi
    def test_names_the_draft_output_path_and_every_plan_key(self):
        out, prompt = L.draft_plan_prompt("cmdemo1-workorders", 28, "A title", "Body text", "/runs/cmdemo1-workorders-28/plan.draft.json")
        self.assertEqual(out, "/runs/cmdemo1-workorders-28/plan.draft.json")
        self.assertIn("Write the plan as JSON to the file /runs/cmdemo1-workorders-28/plan.draft.json", prompt)
        keys = prompt.split("with keys:", 1)[1]        # so a key must be named in the plan-key list, not just anywhere
        for key in ("repo", "issue", "branch", "files", "constraints", "criteria", "evidence_cmd", "tasks",
                    "size", "verify_cmd", "pr_title", "pr_summary"):
            self.assertIn(key, keys, key)
        self.assertIn("cmdemo1-workorders#28", prompt); self.assertIn("A title", prompt); self.assertIn("Body text", prompt)
        self.assertIn("change NO files", prompt)

class DraftPlanTests(unittest.TestCase):   # cmd_draft_plan with gh/plan_worktree/pi patched: no network, no Pi
    PLAN = dict(PLAN, repo="cmdemo1-system", issue=884)   # the module's valid plan, retargeted at this item

    @staticmethod
    def _out_of(prompt):
        """The draft path quoted in the prompt (`Write the plan as JSON to the file {out} with keys`)."""
        i = prompt.index(" to the file ") + len(" to the file ")
        return prompt[i:].split(" with keys", 1)[0].strip()

    def _run(self, write_plan=False):
        """Run cmd_draft_plan for cmdemo1-system#884 with Driver.gh, Driver.plan_worktree and Driver.pi patched:
        gh returns the issue, plan_worktree does nothing, pi records (name, prompt, timeout, gpu) and, when
        write_plan, writes a valid plan to the path quoted in the prompt. Returns (calls, SystemExit code);
        L.HOME is a temp dir during the call and is restored after."""
        calls = []
        with fake_home():
            gh = mock.Mock(return_value=mock.Mock(stdout='{"title": "t", "body": "b"}'))
            plan, out_of = self.PLAN, self._out_of   # bound in the closure: the patched pi's `self` is the Driver

            def pi(self, name, prompt, timeout, gpu=None):
                calls.append((name, prompt, timeout, gpu))
                if write_plan: json.dump(plan, open(out_of(prompt), "w"))
                return False

            code = None
            with mock.patch.object(L.Driver, "gh", gh), mock.patch.object(L.Driver, "plan_worktree", mock.Mock()), \
                    mock.patch.object(L.Driver, "pi", pi):
                try:
                    L.cmd_draft_plan(argparse.Namespace(repo="cmdemo1-system", issue=884, top_session=None))
                except SystemExit as e:
                    code = e.code
        return calls, code

    def test_draft_plan_uses_named_timeout(self):
        calls, _ = self._run()
        self.assertEqual(calls[0][2], L.DRAFT_PLAN_TIMEOUT_S)
        self.assertGreaterEqual(L.DRAFT_PLAN_TIMEOUT_S, 2700)

    def test_draft_plan_takes_any_free_262k_gpu(self):   # cmdemo1-system#907: a draft must not queue on pro5000 alone
        calls, _ = self._run()
        self.assertIn("pro5000", calls[0][3].split(",")); self.assertIn("pro6000", calls[0][3].split(","))
        self.assertEqual(calls[0][3], ",".join(G.LARGE_GPUS), "draft-plan asks for the 262K pair, pro5000 first")
        self.assertEqual(calls[0][3], L.G.gpu_arg(G.LARGE_GPUS), "the run-task --gpu argument form (reviews use it too)")

    def test_draft_plan_gpu_list_is_what_run_task_parses(self):   # the comma list is run-task's --gpu contract, not a driver habit
        loader = importlib.machinery.SourceFileLoader("run_task_draft_gpu", os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-task"))
        rt = importlib.util.module_from_spec(importlib.util.spec_from_loader("run_task_draft_gpu", loader)); loader.exec_module(rt)
        gpu = self._run()[0][0][3]   # calls[0] is (name, prompt, timeout, gpu)
        self.assertEqual(rt.gpu_list(gpu), ["pro5000", "pro6000"])   # run-task takes the first of them with a free slot

    def test_draft_plan_prompt_asks_for_early_draft(self):
        calls, _ = self._run()
        prompt = calls[0][1]
        self.assertIn("plan.draft.json", prompt)
        self.assertIn("first complete draft", prompt)
        self.assertIn("refine", prompt)

    def test_draft_plan_accepts_draft_written_before_timeout(self):
        calls, code = self._run(write_plan=True)
        self.assertEqual(calls[0][0], "draft-plan")
        self.assertEqual(code, 0)   # a valid draft on disk exits 0 even though the pi pass returned False

class GhChokepoint(unittest.TestCase):   # cmdemo1-system#828: every gh call is one sh chokepoint with explicit check, timeout and write
    def gh_recorder(self):
        calls = []
        sh = lambda cmd, **k: (calls.append((cmd, k)), subprocess.CompletedProcess(cmd, 0, "", ""))[1]
        return sh, calls

    def test_gh_passes_timeout_and_check_to_sh(self):
        with fake_home() as h:
            d = make_driver(repo="cmdemo1-system", issue=828)
            sh, calls = self.gh_recorder(); d.sh = sh
            d.gh("run", "watch", "1", check=False, timeout=21600)
            cmd, k = calls[0]
            self.assertEqual(list(cmd), ["gh", "run", "watch", "1"])
            self.assertEqual((k.get("check"), k.get("timeout"), k.get("write")), (False, 21600, False))

    def test_gh_defaults_unchanged(self):
        with fake_home() as h:
            d = make_driver(repo="cmdemo1-system", issue=828)
            sh, calls = self.gh_recorder(); d.sh = sh
            d.gh("pr", "list")
            cmd, k = calls[0]
            self.assertEqual(list(cmd), ["gh", "pr", "list"])
            self.assertEqual((k.get("check"), k.get("timeout"), k.get("write")), (True, None, False))

    def test_no_direct_sh_gh_call_sites(self):
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "item_loop.py")).read()
        self.assertIsNone(re.search(r'sh\(\[\s*"gh"', src))


class StageRegistry(unittest.TestCase):   # cmdemo1-system#829: stage name -> handler is one registry, not a "st_" + name formula
    def test_stages_is_a_dict_of_the_known_stage_names(self):
        self.assertIsInstance(L.STAGES, dict)
        self.assertEqual(set(L.STAGES), {"gpu", "pickup", "research", "implement", "local-verify",
                                         "pr", "ci", "review", "merge", "main", "deploy"})

    def test_every_value_is_an_existing_driver_method_name(self):   # the st_* methods keep their names
        for stage, name in sorted(L.STAGES.items()):
            with self.subTest(stage=stage):
                self.assertIsInstance(name, str, stage)
                self.assertTrue(callable(getattr(L.Driver, name, None)), f"{stage} -> {name}")

    def test_terminal_stages(self):
        self.assertEqual(L.TERMINAL_STAGES, ("done", "blocked", "dry-run-done"))

    def test_stage_handler_returns_the_driver_method(self):
        d = L.Driver.__new__(L.Driver)
        h = L.stage_handler(d, "review")
        self.assertTrue(callable(h))
        self.assertEqual(h.__name__, "st_review")
        self.assertEqual(h, d.st_review)

    def test_stage_handler_follows_an_instance_override(self):   # existing tests patch driver methods on the instance
        d = L.Driver.__new__(L.Driver)
        d.st_review = lambda: "overridden"
        self.assertEqual(L.stage_handler(d, "review")(), "overridden")

    def test_unknown_stage_raises_naming_the_stage(self):
        d = L.Driver.__new__(L.Driver)
        with self.assertRaises(L.UnknownStage) as cm: L.stage_handler(d, "no-such-stage")
        self.assertIn("no-such-stage", str(cm.exception))

    def test_unknown_stage_lists_the_known_stages(self):
        d = L.Driver.__new__(L.Driver)
        with self.assertRaises(L.UnknownStage) as cm: L.stage_handler(d, "no-such-stage")
        msg = str(cm.exception)
        for stage in sorted(L.STAGES): self.assertIn(stage, msg, stage)

    def test_unknown_stage_ends_the_run_like_any_driver_error(self):   # only the exception's name and message are new; the driver-error path (log, state, wake, watchdog) is unchanged
        old_watchdog = L.watchdog_exit
        woke, exits = [], []
        L.watchdog_exit = lambda drv: exits.append(drv)
        try:
            with fake_home() as h:
                d = make_driver(issue=1948)
                json.dump(PLAN, open(os.path.join(d.run_dir, "plan.json"), "w"))
                d.sh = lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, "0.1", "")
                for name in sorted(set(L.STAGES.values()) | {a for a in dir(L.Driver) if a.startswith("st_")}):
                    setattr(d, name, lambda *a, **k: self.fail("an unknown stage must not run any stage handler"))
                d.comment = lambda *a, **k: self.fail("a driver error posts no comment")
                d.wake_bot = lambda reason, **k: woke.append(reason)
                d.s["stage"] = "no-such-stage"
                with self.assertRaises(L.UnknownStage) as cm: d.run()
                s = json.load(open(d.state_p))
                self.assertEqual(s["status"], "error")
                self.assertEqual(s["error"], str(cm.exception)[:1500], "state.json carries the same message the driver raised")
                self.assertIn("no-such-stage", s["error"])
                self.assertEqual(woke, ["driver error"], "the bot is woken once, for a driver error")
                self.assertEqual(len(exits), 1, "the watchdog exit hook ran once")
        finally:
            L.watchdog_exit = old_watchdog


class UsageReportTests(unittest.TestCase):
    def test_no_start_record_renders_zero_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "run.json"), "w") as f:
                json.dump({"start": "2026-11-23T12:00:00+00:00"}, f)
            with open(os.path.join(tmp, "tasks.jsonl"), "w") as f:
                f.write(json.dumps({"task": "t1", "gpu": "pro5000", "result": "PASS", "turns": 3, "session_id": "s1", "input": 1000, "cacheRead": 2000, "output": 300, "wall_s": 65}) + "\n")
                f.write(json.dumps({"task": "draft-plan", "gpu": "pro5000", "result": "no-start", "rc": 125, "why": "no free slot", "start": "2026-11-23T12:00:00+00:00", "end": "2026-11-23T12:15:00+00:00"}) + "\n")
            report = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage-report")
            p = subprocess.run([sys.executable, report, "--run-dir", tmp], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, f"stderr: {p.stderr[-1000:]}" if p.stderr else "")
            self.assertNotIn("Traceback", p.stderr)
            lines = p.stdout.split("\n")
            no_start_line = next((l for l in lines if "no-start" in l), None)
            self.assertIsNotNone(no_start_line, "no line for the no-start task")
            self.assertIn("0 + 0 | 0 | 0m00s", no_start_line)
            total_line = next((l for l in lines if "Total" in l), None)
            self.assertIsNotNone(total_line, "no totals line")
            self.assertIn("**1,000 + 2,000**", total_line)
            self.assertIn("**300**", total_line)


class ReleaseSkip(unittest.TestCase):   # #914: a system merge the system pipeline ignores goes straight to Done
    def test_factory_docs_and_pinned_env_files_are_release_skipped(self):
        self.assertTrue(L.release_skipped("cmdemo1-system", ["factory/pi/item_loop.py", "factory/pi/test_item_loop.py"]))
        self.assertTrue(L.release_skipped("cmdemo1-system", ["README.md", "docs/a.png", "src/x/NOTES.md",
                                                             "environments/prod/versions.json", "environments/tdd/nodes.json",
                                                             "environments/uat/database.json"]))

    def test_mixed_or_unknown_changes_still_deploy(self):
        self.assertFalse(L.release_skipped("cmdemo1-system", ["factory/pi/gpu.py", "src/System/Program.cs"]))
        self.assertFalse(L.release_skipped("cmdemo1-system", ["environments/prod/secrets.json"]))
        self.assertFalse(L.release_skipped("cmdemo1-system", ["environments/prod/x/versions.json"]))
        self.assertFalse(L.release_skipped("cmdemo1-system", ["factory.yml"]))
        self.assertFalse(L.release_skipped("cmdemo1-system", []))
        self.assertFalse(L.release_skipped("cmdemo1-workorders", ["factory/pi/gpu.py"]))

    def run_main(self, h, files):
        d = make_driver(repo="cmdemo1-system", issue=914)
        d.s.update(plan=dict(PLAN, repo="cmdemo1-system", issue=914, files=["factory/pi/item_loop.py"]), merge_sha="ab" * 20,
                   pr=9, head="cd" * 20)
        moves, comments = [], []
        d.gh = lambda *a, **k: subprocess.CompletedProcess(a, 0, json.dumps(files) if a[1].endswith("/commits/" + "ab" * 20) else "[]", "")
        d.move, d.comment, d.usage = moves.append, lambda body, **k: comments.append(body), lambda **k: ""
        with patched_driver_env(sleep=lambda s: None):
            d.st_main()
        return d, moves, comments

    def test_factory_only_merge_goes_to_done_without_deploy(self):
        with fake_home() as h:
            d, moves, comments = self.run_main(h, ["factory/pi/item_loop.py", "factory/README.md"])
            self.assertEqual((moves, d.s["stage"]), (["Done"], "done"))
            self.assertIn("live from main (merge `abababab`)", comments[0])
            self.assertIn("no release is needed", comments[0])

    def test_mixed_merge_waits_for_its_deploy(self):
        with fake_home() as h:
            d, moves, comments = self.run_main(h, ["factory/pi/item_loop.py", "src/System/Program.cs"])
            self.assertEqual((moves, d.s["stage"]), (["Merged"], "deploy"))
            self.assertNotIn("live from main", comments[0])


class EnsureIssueTests(unittest.TestCase):   # cmdemo1-system#831: the shared ensure_issue helper - mocked self.gh, no network
    """Every test records each d.gh call (positional args and kwargs) and asserts them exactly:
    the open-issues list, then the issue create with the correct title, label and --assignee (only when given).
    TDD: these are red until the helper lands in implement-ensure-issue-helper."""

    REPO = "cmdemo1-system"

    def driver_and_gh(self, titles, create_rc=0, create_stdout="123\n"):
        d = make_driver(repo=self.REPO, issue=831)
        calls = []
        def gh(*a, **k):   # the mocked self.gh: answers the api list with titles, the create with an issue number
            calls.append((list(a), dict(k)))
            if a and a[0] == "api":
                return subprocess.CompletedProcess(("gh",) + a, 0, json.dumps(titles), "")
            return subprocess.CompletedProcess(("gh",) + a, create_rc, create_stdout, "")
        d.gh = gh
        return d, calls

    def test_creates_when_title_absent_and_returns_issue_number(self):
        with fake_home() as h:
            d, calls = self.driver_and_gh(["Some other followup"])
            self.assertEqual(d.ensure_issue("New followup", "Body text", "enhancement", assignee=L.BOT), "123")
            full = f"{L.ORG}/{self.REPO}"   # the default repo is self.repo, as a full repo name
            list_args, list_kw = calls[0]
            self.assertEqual(list_args, ["api", f"repos/{full}/issues?state=open&labels=enhancement&per_page=100",
                                        "--jq", "[.[].title]"])
            self.assertEqual(list_kw, {"check": False})
            create_args, create_kw = calls[1]
            self.assertEqual(create_kw, {"write": True, "check": False})
            body_f = create_args[create_args.index("--body-file") + 1]
            self.assertTrue(body_f.startswith(d.run_dir + os.sep + "logs" + os.sep), body_f)
            self.assertIn(L.scrub("Body text"), open(body_f).read())
            self.assertEqual(create_args, ["issue", "create", "-R", full, "--title", "New followup",
                                           "--body-file", body_f, "--label", "enhancement", "--assignee", L.BOT])
            self.assertEqual(len(calls), 2)

    def test_no_assignee_flag_when_assignee_not_given(self):
        with fake_home() as h:
            d, calls = self.driver_and_gh(["Some other followup"])
            self.assertEqual(d.ensure_issue("New followup", "Body text", "enhancement"), "123")
            full = f"{L.ORG}/{self.REPO}"
            create_args, create_kw = calls[1]
            body_f = create_args[create_args.index("--body-file") + 1]
            self.assertEqual(create_args, ["issue", "create", "-R", full, "--title", "New followup",
                                           "--body-file", body_f, "--label", "enhancement"])
            self.assertEqual(create_kw, {"write": True, "check": False})
            self.assertNotIn("--assignee", create_args)

    def test_existing_title_is_not_created(self):
        with fake_home() as h:
            d, calls = self.driver_and_gh(["New followup"])
            self.assertIsNone(d.ensure_issue("New followup", "Body text", "enhancement"))
            self.assertEqual(len(calls), 1)   # the open-issues list only; no create call

    def test_dedup_is_case_insensitive(self):
        with fake_home() as h:
            d, calls = self.driver_and_gh(["Existing"])
            self.assertIsNone(d.ensure_issue("existing", "Body text", "enhancement", case_insensitive=True))
            self.assertEqual(len(calls), 1)   # 'existing' matches the open 'Existing'; no create call

    def test_exact_match_when_not_case_insensitive(self):   # fix_forward_issue keeps its exact-match dedup
        with fake_home() as h:
            d, calls = self.driver_and_gh(["fix: a"])
            full = f"{L.ORG}/{self.REPO}"
            self.assertEqual(d.ensure_issue("Fix: A", "Body text", "fix-forward", assignee=L.BOT, case_insensitive=False), "123")
            self.assertEqual(len(calls), 2)   # different case is not a duplicate: it is created
            create_args, create_kw = calls[1]
            body_f = create_args[create_args.index("--body-file") + 1]
            self.assertEqual(create_args, ["issue", "create", "-R", full, "--title", "Fix: A",
                                           "--body-file", body_f, "--label", "fix-forward", "--assignee", L.BOT])
            self.assertEqual(create_kw, {"write": True, "check": False})

    def test_explicit_repo_overrides_the_default(self):
        with fake_home() as h:
            d, calls = self.driver_and_gh([])
            self.assertEqual(d.ensure_issue("New followup", "Body text", "enhancement", repo="other"), "123")
            full = f"{L.ORG}/other"
            self.assertEqual(calls[0][0][1], f"repos/{full}/issues?state=open&labels=enhancement&per_page=100")
            create_args, _ = calls[1]
            self.assertEqual(create_args[create_args.index("-R") + 1], full)

    def test_create_failure_returns_none(self):
        with fake_home() as h:
            d, calls = self.driver_and_gh([], create_rc=1, create_stdout="HTTP 422: Validation Failed")
            self.assertIsNone(d.ensure_issue("New followup", "Body text", "enhancement"))
            self.assertEqual(len(calls), 2)   # the list ran, the create was attempted and failed


class MoveBoardItem(unittest.TestCase):
    """Driver.move: board item lookup failures log and no-op; a found item is moved via item-edit."""

    def make_driver_and_calls(self, issue=100, stdout=""):
        """A dry-run driver with its gh call captured; returns (driver, call recorder). Caller must wrap in fake_home."""
        d = make_driver(issue=issue)
        calls = []
        def fake_gh(*a, **k):
            calls.append((a, k))
            return L.subprocess.CompletedProcess(a, 0, stdout, "")
        d.gh = fake_gh
        return d, calls

    def test_move_non_json_gh_output_logs_and_skips(self):
        """Case (1): gh returns non-JSON; move logs 'board lookup failed; skipping move' and does not call item-edit."""
        with fake_home():
            d, calls = self.make_driver_and_calls(stdout="not-json")
            d.move("In Progress")
            log = open(os.path.join(d.run_dir, "driver.log")).read()
            self.assertIn("board lookup failed; skipping move", log)
            item_edits = [c for c in calls if "item-edit" in c[0]]
            self.assertEqual(len(item_edits), 0)
            self.assertNotIn("item_id", d.s)

    def test_move_json_no_matching_project_logs_and_skips(self):
        """Case (2): valid JSON with no node matching L.PROJECT; move logs and skips."""
        payload = json.dumps({"data": {"repository": {"issue": {"projectItems": {"nodes": [{"id": "other-id", "project": {"id": "different-project"}}]}}}}})
        with fake_home():
            d, calls = self.make_driver_and_calls()
            def fake_gh(*a, **k):
                calls.append((a, k))
                return L.subprocess.CompletedProcess(a, 0, payload, "")
            d.gh = fake_gh
            d.move("In Progress")
            log = open(os.path.join(d.run_dir, "driver.log")).read()
            self.assertIn("board item not found; skipping move", log)
            item_edits = [c for c in calls if "item-edit" in c[0]]
            self.assertEqual(len(item_edits), 0)

    def test_move_matching_project_id_calls_item_edit(self):
        """Case (3): matching node found; item_id is saved and item-edit is called with the correct option."""
        payload = json.dumps({"data": {"repository": {"issue": {"projectItems": {"nodes": [{"id": "other-id", "project": {"id": "different-project"}}, {"id": "correct-id", "project": {"id": L.PROJECT}}]}}}}})
        with fake_home():
            d, calls = self.make_driver_and_calls()
            def fake_gh(*a, **k):
                calls.append((a, k))
                return L.subprocess.CompletedProcess(a, 0, payload, "")
            d.gh = fake_gh
            d.move("In Progress")
            self.assertEqual(d.s["item_id"], "correct-id")
            item_edits = [c for c in calls if "item-edit" in c[0]]
            self.assertEqual(len(item_edits), 1)
            args, kw = item_edits[0]
            self.assertEqual(args[0], "project")
            self.assertEqual(args[1], "item-edit")
            self.assertIn("--id", args)
            self.assertEqual(args[args.index("--id") + 1], "correct-id")
            self.assertIn("--project-id", args)
            self.assertEqual(args[args.index("--project-id") + 1], L.PROJECT)
            self.assertIn("--field-id", args)
            self.assertEqual(args[args.index("--field-id") + 1], L.STATUS_FIELD)
            self.assertIn("--single-select-option-id", args)
            self.assertEqual(args[args.index("--single-select-option-id") + 1], L.STATUS["In Progress"])

class SharedFixPass(unittest.TestCase):   # cmdemo1-system#858: the bump-or-block + fix loop is one helper, four call sites
    """Driver.fix_pass / Driver.pi_round / FixRound. The ci, quality, review and merge passes used to each
    re-type the same sequence -- bump a LIMITS counter, Blocker when it is exhausted, move to In Progress,
    comment the failure, send the Pi fix task, re-verify locally, commit and push -- with their own failure text
    inlined in each copy. Pinned here: the order of one pass (board move, comment, Pi task `<pi>-<n>`, local
    verification `<verify><n>`, commit message), that the Blocker text stays the stage's own (hold_resumes keys
    off "Review FAIL twice"), that an exhausted counter runs nothing else, that a red local verification never
    commits, and that the plan paste still runs between the verification and the push."""

    def driver(self, **state):
        d = make_driver(repo="cmdemo1-system", issue=858, dry_run=False)
        d.events = []; ev = d.events
        d.s.update(counts={k: 0 for k in L.LIMITS}, plan=dict(PLAN), wt="/tmp/wt", gpu="pro5000", pr=7,
                   head="h" * 40, stage="ci"); d.s.update(state)
        d.move = lambda col: ev.append(("move", col))
        d.comment = lambda body, pr=False: ev.append(("comment", body, pr))
        d.blocker = lambda what, who="Jeffrey": (ev.append(("blocker", what)), d.save(stage="blocked", blocker=what))[-1]
        d.commit_push = lambda msg: ev.append(("commit", msg)) or "sha"
        d.local_green = lambda label: ev.append(("local_green", label)) or True
        d.pi = lambda name, prompt, timeout=L.PI_TASK_TIMEOUT_S, gpu=None: (ev.append(("pi", name, prompt)), True)[-1]
        return d

    def test_one_pass_moves_comments_fixes_verifies_and_pushes_in_that_order(self):
        with fake_home():
            d = self.driver()
            n = d.fix_pass("ci_fix", "required checks still red after 3 Pi fix passes.", progress="In Progress",
                           comment=lambda k: d.comment(f"fix pass {k} of {L.LIMITS['ci_fix']}"),
                           fix=L.FixRound("ci-fix", "the findings", "ci",
                                          local_red=lambda k: f"local verification red after CI fix pass {k}.",
                                          commit=lambda k: f"Fix CI ({k})"))
            self.assertEqual((n, d.s["counts"]["ci_fix"]), (1, 1), "the pass number is the counter after the bump")
            self.assertEqual(d.events, [("move", "In Progress"), ("comment", "fix pass 1 of 3", False),
                                        ("pi", "ci-fix-1", "the findings"), ("local_green", "ci1"),
                                        ("commit", "Fix CI (1)")])

    def test_the_pass_number_names_the_task_and_the_verification_on_every_pass(self):
        with fake_home():
            d = self.driver(); d.s["counts"]["quality_fix"] = 1
            self.assertEqual(d.fix_pass("quality_fix", "Qodana still red after 3 Pi fix passes.",
                                        fix=L.FixRound("quality-fix", "findings", "quality",
                                                       local_red="local verification red after quality fix pass.",
                                                       commit="Fix Qodana")), 2)
            self.assertEqual([(e[0], e[1] if len(e) > 1 else None) for e in d.events],
                             [("pi", "quality-fix-2"), ("local_green", "quality2"), ("commit", "Fix Qodana")])

    def test_an_exhausted_counter_blocks_with_the_stages_own_text_and_runs_nothing_else(self):
        with fake_home():
            d = self.driver(); d.s["counts"]["review_fail"] = L.LIMITS["review_fail"]
            self.assertIsNone(d.fix_pass("review_fail", "Review FAIL twice: A works (exit 1)", progress="In Progress",
                                         comment=lambda k: d.comment("never posted"),
                                         fix=L.FixRound("review-fix", "never sent", "review",
                                                        local_red="never", commit="never")))
            self.assertEqual(d.events, [("blocker", "Review FAIL twice: A works (exit 1)")],
                             "exhausted: no board move, no comment, no Pi task, no push")
            self.assertEqual(d.s["counts"]["review_fail"], L.LIMITS["review_fail"] + 1)
            self.assertEqual(d.s["stage"], "blocked")
            self.assertFalse(L.hold_resumes(d.s["blocker"]),
                             "the text is the stage's own so a Review FAIL blocker keeps its 'never resume on green checks' prefix")

    def test_a_pass_without_a_fix_round_is_the_bump_alone(self):   # the merge gate shape
        with fake_home():
            d = self.driver(stage="merge")
            self.assertEqual(d.fix_pass("merge_gate", "merge gate not met after 3 tries"), 1)
            self.assertEqual(d.events, [])
            d.s["counts"]["merge_gate"] = L.LIMITS["merge_gate"]
            self.assertIsNone(d.fix_pass("merge_gate", "merge gate not met after 3 tries (checks RED)"))
            self.assertEqual(d.events, [("blocker", "merge gate not met after 3 tries (checks RED)")])
            self.assertTrue(L.hold_resumes(d.s["blocker"]), "a merge-gate Blocker is a checks problem: it may resume on green")

    def test_red_local_verification_blocks_and_never_commits(self):
        with fake_home():
            d = self.driver(); d.local_green = lambda label: (d.events.append(("local_green", label)), False)[-1]
            self.assertFalse(d.pi_round("ci-fix-1", "findings", "ci1",
                                        "local verification red after CI fix pass 1.", "Fix CI (1)"))
            self.assertEqual([e[0] for e in d.events], ["pi", "local_green", "blocker"])
            self.assertEqual(d.events[-1][1], "local verification red after CI fix pass 1.")

    def test_the_before_commit_hook_runs_between_the_verification_and_the_push(self):
        with fake_home():   # where fix_quality pastes the PR's `## Refactoring plan`
            d = self.driver()
            d.fix_pass("quality_fix", "Qodana still red after 3 Pi fix passes.",
                       fix=L.FixRound("quality-fix", "findings", "quality", local_red="red",
                                      commit=lambda k: f"Fix Qodana ({k})",
                                      before_commit=lambda: d.events.append(("paste plan",))))
            self.assertEqual([e[0] for e in d.events], ["pi", "local_green", "paste plan", "commit"])
            d.local_green = lambda label: (d.events.append(("local_green", label)), False)[-1]
            d.events.clear()
            d.fix_pass("quality_fix", "Qodana still red after 3 Pi fix passes.",
                       fix=L.FixRound("quality-fix", "findings", "quality", local_red="red",
                                      commit=lambda k: f"Fix Qodana ({k})",
                                      before_commit=lambda: d.events.append(("paste plan",))))
            self.assertEqual([e[0] for e in d.events], ["pi", "local_green", "blocker"],
                             "a red verification skips the paste and the push, exactly as before #858")

    def test_a_fix_round_text_is_a_literal_or_a_function_of_the_pass_number(self):
        r = L.FixRound("review-fix", "p", "review", local_red="local verification red after a review fix.",
                       commit="Fix review findings")
        self.assertEqual((r.local_red(2), r.commit(2)), ("local verification red after a review fix.", "Fix review findings"))
        r = L.FixRound("ci-fix", "p", "ci", local_red=lambda k: f"pass {k}", commit=lambda k: f"Fix CI ({k})")
        self.assertEqual((r.local_red(3), r.commit(3)), ("pass 3", "Fix CI (3)"))

    def test_the_four_stages_use_the_helper_and_no_longer_bump_their_own_counter(self):
        import inspect
        for name, key in (("st_ci", "ci_fix"), ("fix_quality", "quality_fix"), ("st_review", "review_fail"), ("st_merge", "merge_gate")):
            with self.subTest(stage=name):
                src = inspect.getsource(getattr(L.Driver, name))
                self.assertIn("self.fix_pass(", src, f"Driver.{name} still writes the fix loop itself")
                self.assertNotIn(f'bump("{key}")', src, f"Driver.{name} still bumps {key} outside the helper")

    def test_ci_fix_passes_still_end_in_the_same_blocker(self):
        with fake_home():
            d = self.driver(stage="ci"); d.s["counts"]["ci_fix"] = L.LIMITS["ci_fix"]
            d.wait_ci = lambda: (L.CheckState.RED, [{"name": "Build result", "bucket": "fail", "link": "https://x/actions/runs/1"}])
            d.failed_logs = lambda cs: ({"1"}, "src/A.cs(1,1): error CS1002: ; expected")
            d.st_ci()
            self.assertEqual(d.s["blocker"], "required checks still red after 3 Pi fix passes.")
            self.assertTrue(L.hold_resumes(d.s["blocker"]))
            self.assertEqual([e[0] for e in d.events], ["blocker"])

    def test_the_merge_gate_still_blocks_after_its_limit_from_the_merge_stage(self):
        with fake_home():
            d = self.driver(stage="merge"); d.s["counts"]["merge_gate"] = L.LIMITS["merge_gate"]
            d.pr_checks = lambda: (L.CheckState.RED, [])
            d.gh = lambda *a, **k: subprocess.CompletedProcess(a, 0, json.dumps({"author": {"login": L.BOT},
                                                                                "headRefOid": "h" * 40, "state": "MERGED"}), "")
            d.st_merge()
            self.assertEqual(d.s["stage"], "blocked")
            self.assertIn("merge gate not met after 3 tries", d.s["blocker"])


class CommandShapeHelpers(unittest.TestCase):   # cmdemo1-system#889: "is this a gh call" / "may it use the App quota" are pure rules, not loop internals
    def test_gh_command_recognises_the_argv_and_the_shell_form(self):
        for cmd in (["gh", "pr", "list"], ["gh"], "gh pr list", "gh run watch 1 --verbose"):
            self.assertTrue(L.gh_command(cmd), cmd)
        for cmd in (["git", "status"], [], "", "ghpython script.py", ["bash", "-c", "gh pr list"], None, "echo gh"):
            self.assertFalse(L.gh_command(cmd), cmd)

    def test_app_quota_first_is_every_gh_call_but_the_two_the_bot_user_must_author(self):
        self.assertTrue(L.app_quota_first(["gh", "pr", "view", "1"]))
        self.assertTrue(L.app_quota_first("gh pr comment 1 --body hi"))
        for cmd in ((["gh", "pr", "create", "--title", "t"], ["gh", "issue", "create", "--title", "t"])):
            self.assertFalse(L.app_quota_first(cmd), cmd)     # GH_APP_USER_ONLY: the merge gate wants author == BOT
        for cmd in (["git", "push"], ["git", "commit", "-m", "gh"], [], None, "sleep 1"):
            self.assertFalse(L.app_quota_first(cmd), cmd)     # never a token for a command gh is not

    def test_shown_cmd_quotes_an_argv_and_leaves_a_shell_string_alone(self):
        self.assertEqual(L.shown_cmd(["gh", "pr", "comment", "1", "--body", "hi"]), "gh pr comment 1 --body hi")
        self.assertEqual(L.shown_cmd(["bash", "-c", "echo a b"]), "bash -c 'echo a b'")
        self.assertEqual(L.shown_cmd("sleep 1; echo verify"), "sleep 1; echo verify")


class RunLoggedSeam(unittest.TestCase):   # cmdemo1-system#889: _run_logged is one command out, once (App token, then the user login)
    APP_TOKEN = "ghs_" + "B" * 36

    def setUp(self):
        self._app_env = os.environ.get("GH_APP_TOKEN_CMD")
        L._app_tok.update(v=None, at=0.0)
    def tearDown(self):
        L._app_tok.update(v=None, at=0.0)
        if self._app_env is None: os.environ.pop("GH_APP_TOKEN_CMD", None)
        else: os.environ["GH_APP_TOKEN_CMD"] = self._app_env

    def test_a_gh_call_goes_out_once_on_the_app_token(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.APP_TOKEN}"
        captured = []
        with patched_driver_env(run=FakeGhProcess([(0, "[]")], captured)):
            d = make_driver(repo="cmdemo1-system", issue=889, dry_run=False)
            r = d._run_logged(["gh", "pr", "list"])
        self.assertEqual((r.returncode, r.stdout), (0, "[]"))
        self.assertEqual([((k.get("env") or {}).get("GH_TOKEN")) for k in captured], [self.APP_TOKEN],
                         "one attempt, on the App quota; no user-login round after an accepted call")

    def test_a_refused_app_token_re_sends_the_same_call_on_the_user_login(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.APP_TOKEN}"
        captured = []
        with patched_driver_env(run=FakeGhProcess([(1, "HTTP 401: Bad credentials"), (0, "[]")], captured)):
            d = make_driver(repo="cmdemo1-system", issue=889, dry_run=False); logs = []; d.log = logs.append
            r = d._run_logged(["gh", "pr", "list"])
        self.assertEqual((r.returncode, r.stdout), (0, "[]"))
        self.assertEqual([((k.get("env") or {}).get("GH_TOKEN")) for k in captured], [self.APP_TOKEN, None],
                         "the refused App attempt, then the same call on the bot user's login")
        self.assertEqual(L._app_tok, {"v": None, "at": 0.0}, "a 401 drops the cached token: the next call mints a fresh one")
        self.assertTrue(any("user login" in m for m in logs))

    def test_a_non_gh_command_never_sees_a_token_and_never_mints_one(self):
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.APP_TOKEN}"
        captured = []
        with patched_driver_env(run=FakeGhProcess([(0, "")], captured)):
            d = make_driver(repo="cmdemo1-system", issue=889, dry_run=False)
            d._run_logged(["git", "status"])
        self.assertEqual(len(captured), 1, "one attempt, no App round for a local command")
        self.assertIsNone((captured[0].get("env") or {}).get("GH_TOKEN"))
        self.assertEqual(L._app_tok, {"v": None, "at": 0.0}, "a git call never asks for a token, so it never mints one")


class RateLimitLoopSeam(unittest.TestCase):   # cmdemo1-system#889: _retry_rate_limit owns only the backoff / wait / re-send loop
    def rl(self, text="GraphQL: API rate limit exceeded for user ID 1."):
        return subprocess.CompletedProcess(["gh", "pr", "list"], 1, text, "")

    def test_waits_with_the_backoff_then_returns_the_answer_that_stands(self):
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=889, dry_run=False)
            slept = []; d.wait_alive = lambda s, why: slept.append((s, why))
            bad, ok = self.rl(), subprocess.CompletedProcess(["gh", "pr", "list"], 0, "[]", "")
            sends = []
            def run():
                sends.append(1)
                return ok if len(sends) >= 2 else bad
            r = d._retry_rate_limit(bad, run)
            self.assertIs(r, ok, "the reply that is not a rate limit is what the caller gets")
            self.assertEqual(slept, [(60, "gh rate limit, retry 1"), (120, "gh rate limit, retry 2")])
            self.assertEqual(len(sends), 2, "one re-send per wait: the rate limit is re-checked only on a fresh reply")

    def test_gives_up_with_the_last_rate_limit_once_the_caps_are_reached(self):
        saved = (L.GH_RETRY_MAX_ATTEMPTS, L.GH_RETRY_MAX_WAIT_S)
        L.GH_RETRY_MAX_ATTEMPTS, L.GH_RETRY_MAX_WAIT_S = 1, 10 ** 6
        try:
            with fake_home():
                d = make_driver(repo="cmdemo1-system", issue=889, dry_run=False)
                slept = []; d.wait_alive = lambda s, why: slept.append(s)
                bad = self.rl(); sends = []
                def run():
                    sends.append(1); return bad
                self.assertIs(d._retry_rate_limit(bad, run), bad, "giving up returns the last reply, which fails like any other gh error")
                self.assertEqual((slept, len(sends)), ([60], 1), "one retry under the cap, then the give-up")
        finally:
            L.GH_RETRY_MAX_ATTEMPTS, L.GH_RETRY_MAX_WAIT_S = saved

    def test_a_reply_that_is_not_a_rate_limit_never_re_sends(self):
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=889, dry_run=False)
            ok = subprocess.CompletedProcess(["gh", "pr", "list"], 0, "[]", "")
            self.assertIs(d._retry_rate_limit(ok, lambda: self.fail("a clean reply is never re-sent")), ok)
            failed = subprocess.CompletedProcess(["gh", "pr", "list"], 1, "HTTP 404: Not Found", "")
            self.assertIs(d._retry_rate_limit(failed, lambda: self.fail("a non-rate-limit failure is never retried")), failed)

    def test_sh_delegates_to_the_two_extracts_and_stays_the_stubbed_seam(self):
        src = inspect.getsource(L.Driver.sh)
        self.assertIn("self._run_logged(", src, "sh must send every command through the one App-token/user-login attempt")
        self.assertIn("self._retry_rate_limit(", src, "sh must hand a rate-limited gh reply to the backoff loop")
        self.assertNotIn("app_token(", src, "the App-token fallback lives in _run_logged, not in sh")
        self.assertNotIn("gh_retry_wait(", src, "the backoff arithmetic lives in _retry_rate_limit, not in sh")
        self.assertIn("self.wait_alive(", inspect.getsource(L.Driver._retry_rate_limit))


class PiHandoffObject(unittest.TestCase):   # cmdemo1-system#889: the hand-off owns task name, prompt, gpu list, attempt and slot wait
    def arg(self, cmd, flag): return cmd[cmd.index(flag) + 1]

    def handoff(self, h, name="review-fix-2", prompt="fix it", size="small", gpu=None, issue=889):
        d = make_driver(issue=issue); d.s.update(gpu="ts3", size=size, wt=os.path.join(h, "wt"))
        return L.PiHandoff(d, name, prompt, gpu=gpu), d

    def test_first_attempt_runs_the_slug_on_the_item_gpu_with_the_short_slot_wait(self):
        with fake_home() as h:
            ho, d = self.handoff(h)
            c = ho.cmd()
            self.assertEqual(c[0], os.path.join(L.HERE, "run-task"))
            self.assertEqual(self.arg(c, "--task"), "review-fix-2")
            self.assertEqual(self.arg(c, "--gpu"), "ts3")
            self.assertEqual(self.arg(c, "--run-dir"), d.run_dir)
            self.assertEqual(self.arg(c, "--cwd"), d.s["wt"])
            self.assertEqual(self.arg(c, "--start-timeout"), str(L.HANDOFF_START_S))
            self.assertEqual(self.arg(c, "--stall-timeout"), str(L.HANDOFF_STALL_S))
            self.assertEqual(int(self.arg(c, "--slot-wait")), L.HANDOFF_SLOT_WAIT_S)
            self.assertEqual(int(self.arg(c, "--timeout")), G.client_timeout(L.PI_TASK_TIMEOUT_S))

    def test_the_prompt_file_is_the_attempt_s_own_and_ends_with_the_rules(self):
        with fake_home() as h:
            ho, d = self.handoff(h, name="test: whole suite", prompt="fix it")
            first = self.arg(ho.cmd(), "--prompt-file")
            self.assertEqual(first, os.path.join(d.run_dir, "logs", "test--whole-suite.prompt.md"))
            self.assertTrue(os.path.exists(first))
            text = open(first).read()
            self.assertIn("fix it", text); self.assertTrue(text.endswith(L.PiHandoff.RULES))
            self.assertTrue(text.rstrip().endswith("the last line."))
            self.assertNotIn("partial edits", text, "only a relaunch says an earlier attempt was stopped")

    def test_relaunch_names_a_new_task_widens_the_gpu_list_and_says_so_in_the_prompt(self):
        with patched_driver_env(gpu_health=lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}):
            with fake_home() as h:
                ho, d = self.handoff(h)
                first = self.arg(ho.cmd(), "--prompt-file")
                ho.relaunch()
                c = ho.cmd()
                self.assertEqual(self.arg(c, "--task"), "review-fix-2-relaunch-1")
                self.assertEqual(self.arg(c, "--gpu"), "pro5000,pro6000,obs,ts3")
                self.assertEqual(int(self.arg(c, "--slot-wait")), L.ANY_SLOT_WAIT_S)
                p = self.arg(c, "--prompt-file")
                self.assertEqual(p, os.path.join(d.run_dir, "logs", "review-fix-2-relaunch-1.prompt.md"))
                self.assertNotEqual(p, first, "each attempt keeps its own prompt file")
                text = open(p).read()
                self.assertIn("fix it", text)
                self.assertIn("`review-fix-2`", text, "the note names the attempt that was stopped")
                self.assertIn("partial edits", text); self.assertTrue(text.rstrip().endswith("the last line."))
                ho.relaunch()
                self.assertEqual(self.arg(ho.cmd(), "--task"), "review-fix-2-relaunch-2")
                self.assertEqual(ho.attempt, 2)
                self.assertEqual(int(self.arg(ho.cmd(), "--slot-wait")), L.ANY_SLOT_WAIT_S)

    def test_a_large_item_relaunch_asks_only_for_the_262k_gpus(self):
        with patched_driver_env(gpu_health=lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}):
            with fake_home() as h:
                ho, _ = self.handoff(h, size="large")
                ho.relaunch()
                self.assertEqual(self.arg(ho.cmd(), "--gpu"), "pro5000,pro6000")

    def test_an_answerless_health_probe_still_names_every_gpu_in_priority_order(self):
        with patched_driver_env(gpu_health=lambda *a: {}):
            with fake_home() as h:
                ho, d = self.handoff(h)
                self.assertEqual(d.gpus_to_try(), list(G.PRIORITY), "a stalled hand-off is retried somewhere, not failed on a GET")
                ho.relaunch()
                self.assertEqual(self.arg(ho.cmd(), "--gpu"), G.gpu_arg(list(G.PRIORITY)))

    def test_a_review_always_waits_the_long_slot_and_is_never_relaunched_here(self):
        with fake_home() as h:
            ho, _ = self.handoff(h, name="independent-review-1")
            self.assertEqual(int(self.arg(ho.cmd(), "--slot-wait")), L.ANY_SLOT_WAIT_S)
            for result in ("no-start", "stalled", "PASS", None):
                self.assertFalse(ho.relaunches(result), result)

    def test_relaunches_is_only_the_two_results_that_never_ran(self):
        with fake_home() as h:
            ho, _ = self.handoff(h)
            for result in ("no-start", "stalled"):
                self.assertTrue(ho.relaunches(result), result)
            for result in ("PASS", "FAIL", "exit 7", None):
                self.assertFalse(ho.relaunches(result), result)

    def test_leaves_edits_is_an_authoring_task_that_actually_replied(self):
        with fake_home() as h:
            for name, expect in (("t1", True), ("review-fix-1", True), ("draft-plan", False),
                                 ("refactoring-research-1", False), ("independent-review-2", False)):
                ho, _ = self.handoff(h, name=name)
                self.assertEqual(ho.leaves_edits("PASS"), expect, name)
                self.assertFalse(ho.leaves_edits("no-start"), f"{name}: no model output, so no edits")

    def test_not_started_is_the_blocker_text_hold_resumes_refuses(self):
        with fake_home() as h:
            ho, _ = self.handoff(h)
            exc = ho.not_started("no-start")
            self.assertIsInstance(exc, L.PiNotStarted)
            text = str(exc)
            self.assertIn("Pi hand-off `review-fix-2` did not start or stalled (no-start:", text)
            self.assertIn(f"{L.HANDOFF_START_S // 60} min", text); self.assertIn(f"{L.HANDOFF_STALL_S // 60} min", text)
            self.assertIn(f"{L.LIMITS['pi_relaunch']} relaunches on any free GPU.", text)
            self.assertFalse(L.hold_resumes(text), "a Pi hand-off Blocker never clears itself on a green PR")


if __name__ == "__main__": unittest.main()
