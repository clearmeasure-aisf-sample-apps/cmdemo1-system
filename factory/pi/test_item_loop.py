"""Unit tests of the Pi item driver's decision rules (no network, no Pi). Run: python3 -m unittest factory/pi/test_item_loop.py"""
import argparse, fcntl, importlib.machinery, importlib.util, inspect, json, os, re, shutil, signal, subprocess, sys, tempfile, threading, time, unittest
import io   # added for io.StringIO in DraftPlanTests._run_with_plan (additive import for #895)
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_loop as L
import gpu as G
import contextlib
import item_loop_test_fakes as fakes   # #1021: shared fakes (PLAN, fake_home, ...) in item_loop_test_fakes.py
from item_loop_test_fakes import PLAN, fake_home, fake_modules, make_driver, scripted_sh, patch_run, HDR, USER, ASSISTANT
from test_item_loop_process_group import RunTaskTimeout, SharedTaskTimeout, RunCmdGroupKill, DriverShGroupKill, VerifyEvidenceRunCmd, GpuGate, SharedRunCmd   # #1021: the process-group kill family moved out; re-exported so the CI command that names this file still runs them
from test_scrub import ScrubEnvValues, Scrubbing, SharedScrubModule, ScrubRuleGaps   # #1022: the scrub rule tests moved out; re-exported the same way

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

class Clock:  # fake time module: one sleep() jumps past GPU_WAIT_H so st_gpu's wait loop exits after one iteration
    def __init__(self, t=1e9): self.t = float(t)
    def time(self): return self.t
    def sleep(self, s): self.t += L.GPU_WAIT_H * 3600 + 1

def pi_stub(result, calls=None):
    """Driver.pi replacement: returns a callable with the Driver.pi signature (name, prompt, timeout=L.PI_TASK_TIMEOUT_S, gpu=None)
    that appends each call's name to calls (when given) and returns a PiRun whose .ok is result: a bool, or a callable
    taking the calls list and returning a bool."""
    def pi(name, prompt, timeout=L.PI_TASK_TIMEOUT_S, gpu=None):
        if calls is not None: calls.append(name)
        ok = result(calls) if callable(result) else result
        return L.PiRun(result="PASS" if ok else "FAIL", gpu=None, rc=0 if ok else 1)
    return pi

class PiRunValue(unittest.TestCase):   # cmdemo1-system#894: PiRun distinguishes timeout from FAIL
    def test_timeout_is_distinguishable_from_fail(self):
        t = L.PiRun(result="timeout", gpu="pro5000", rc=124)
        f = L.PiRun(result="FAIL", gpu="pro5000", rc=1)
        self.assertFalse(t.ok); self.assertTrue(t.timed_out); self.assertFalse(t.not_started)
        self.assertFalse(f.ok); self.assertFalse(f.timed_out); self.assertFalse(f.not_started)
        self.assertNotEqual(t, f)

    def test_pass_is_ok_and_not_timed_out(self):
        p = L.PiRun(result="PASS", gpu="ts3", rc=0)
        self.assertTrue(p.ok); self.assertFalse(p.timed_out); self.assertFalse(p.not_started)

    def test_no_start_and_stalled_are_not_started(self):
        ns = L.PiRun(result="no-start", gpu="obs", rc=125)
        st = L.PiRun(result="stalled", gpu="obs", rc=125)
        self.assertTrue(ns.not_started); self.assertFalse(ns.ok)
        self.assertTrue(st.not_started); self.assertFalse(st.ok)

    def test_exit_n_is_not_ok_not_timed_out_not_not_started(self):
        e = L.PiRun(result="exit 3", gpu="obs", rc=3)
        self.assertFalse(e.ok); self.assertFalse(e.timed_out); self.assertFalse(e.not_started)

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

    def test_validate_plan_accepts_a_valid_verify_timeout_and_rejects_bad_ones(self):
        """cmdemo1-system#967: the plan's optional verify_timeout is validated as a positive int (not a bool)
        at or above MIN_CLIENT_TIMEOUT_S. Absent or a valid int passes silently; a bool, a non-int string, a
        zero, or a value below the floor all produce the fixed message."""
        # absent -> no verify_timeout message
        self.assertEqual(L.validate_plan(PLAN), [], "a plan without verify_timeout must not trip the check")
        # valid int at the floor -> no verify_timeout message
        self.assertEqual(L.validate_plan(dict(PLAN, verify_timeout=G.MIN_CLIENT_TIMEOUT_S)), [],
                         "a plan with verify_timeout == MIN_CLIENT_TIMEOUT_S must not trip the check")
        # a value well above the floor is also valid
        self.assertEqual(L.validate_plan(dict(PLAN, verify_timeout=7200)), [],
                         "a plan with verify_timeout well above the floor must not trip the check")
        msg = f"verify_timeout must be a positive int at or above {G.MIN_CLIENT_TIMEOUT_S}"
        for bad in (True, "600", 0, G.MIN_CLIENT_TIMEOUT_S - 1):
            errs = L.validate_plan(dict(PLAN, verify_timeout=bad))
            self.assertIn(msg, errs, f"verify_timeout={bad!r} must trip the check with: {msg}")

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

    def test_missing_keys_names_absent_and_empty_required_keys(self):
        self.assertEqual(L.missing_keys(PLAN), [])
        self.assertEqual(L.missing_keys({k: v for k, v in PLAN.items() if k not in ("criteria", "verify_cmd")}),
                         ["criteria", "verify_cmd"])
        self.assertEqual(L.missing_keys(dict(PLAN, files=[])), ["files"])
        self.assertEqual(L.missing_keys([]), [])

    def test_missing_keys_agrees_with_required_messages(self):
        for k in L.PLAN_REQUIRED_KEYS:
            p = {x: v for x, v in PLAN.items() if x != k}
            self.assertEqual(L.missing_keys(p), [k], k)
            self.assertIn(f"missing {k}", L.validate_plan(p), k)

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

    # ---- cmdemo1-system#887: the same three states, asked of a ReviewVerdict instead of unwrapped from a tuple. ----
    # The five assertions above stay exactly as they were; these re-run the same cases through the value object.
    def test_review_verdict_answers_the_three_states_it_always_carried(self):
        v = L.ReviewVerdict.of(L.review_verdict("exit 1", None))       # #1944: no findings file
        self.assertTrue(v.is_infra); self.assertFalse(v.is_pass); self.assertFalse(v.is_fail)
        v = L.ReviewVerdict.of(L.review_verdict("FAIL", " \n\t"))     # whitespace only
        self.assertTrue(v.is_infra); self.assertFalse(v.is_pass); self.assertFalse(v.is_fail)
        v = L.ReviewVerdict.of(L.review_verdict("timeout", "- partial"))   # #820: timed out, no verdict
        self.assertTrue(v.is_infra); self.assertFalse(v.is_pass); self.assertFalse(v.is_fail)
        v = L.ReviewVerdict.of(L.review_verdict("PASS", "- No findings."))
        self.assertTrue(v.is_pass); self.assertFalse(v.is_fail); self.assertFalse(v.is_infra)
        v = L.ReviewVerdict.of(L.review_verdict("FAIL", "- bug"))
        self.assertTrue(v.is_fail); self.assertFalse(v.is_pass); self.assertFalse(v.is_infra)
        self.assertFalse(L.hold_resumes("independent review infra failed 3 times (x)"))

    def test_verdict_labels_and_the_of_seam_read_the_three_states(self):
        self.assertEqual([v.label for v in (L.review_verdict("PASS", "- x"), L.review_verdict("FAIL", "- x"),
                                            L.review_verdict("exit 1", None))], ["PASS", "FAIL", "INFRA (retry)"])
        self.assertEqual(L.ReviewVerdict.of((False, "- bug")), L.ReviewVerdict(False, "- bug"))   # a bare pair still normalizes
        self.assertIsNone(L.ReviewVerdict.of(None))       # no review ran at all: independent_review blocked the item, the stage leaves
        self.assertIs(L.ReviewVerdict.of(L.ReviewVerdict(True, "- No findings.")).ok, True)

    def test_infra_value_objects_are_retried_then_pass(self):
        with fake_home() as h:
            d = self.driver(h, [L.ReviewVerdict(None, "no findings file"), L.ReviewVerdict(None, "empty"),
                                L.ReviewVerdict(True, "- No findings.")])
            d.st_review()
            self.assertEqual(d.s["stage"], "merge")
            self.assertEqual((d.s["counts"]["review_fail"], d.s["counts"]["review_infra"]), (0, 0))

    def test_infra_value_objects_block_after_two_retries_without_a_fail(self):
        with fake_home() as h:
            d = self.driver(h, [L.ReviewVerdict(None, "no findings file")] * 3)
            d.st_review()
            self.assertEqual(d.s["stage"], "blocked")
            self.assertTrue(d.s["blocker"].startswith("independent review infra failed 3 times"))
            self.assertIn("not a code FAIL", d.s["blocker"])
            self.assertEqual(d.s["counts"]["review_fail"], 0)

    def test_a_fail_verdict_is_a_code_fail_and_still_resets_the_infra_retries(self):
        with fake_home() as h:
            d = self.driver(h, [L.ReviewVerdict(None, "no findings file"), L.ReviewVerdict(False, "- a finding")])
            asked = []
            d.fix_pass = lambda key, *a, **k: (asked.append(key), None)[1]   # None: the stage leaves, as after a FAIL
            d.st_review()
            self.assertEqual(asked, ["review_fail"], "a FAIL verdict still goes to the review_fail fix pass")
            self.assertEqual((d.s["counts"]["review_fail"], d.s["counts"]["review_infra"]), (0, 0),
                             "a real verdict of either kind puts the infra retries back to zero")

    def test_independent_review_hands_back_a_review_verdict(self):   # the real review, not a double
        with patched_driver_env(research_ok=lambda *a: True, gpu_health=lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}) as h:
            d = make_driver(issue=887)
            d.s.update(plan=dict(PLAN), wt=tempfile.mkdtemp(dir=h), gpu="pro5000", pr=7, default="main")
            d.merge_base = lambda: "abc"
            rec = json.dumps({"task": "independent-review-1", "gpu": "ts3", "result": "exit 1"})
            def sh(cmd, **k):
                out = "body\n## Refactoring research\n- x" if "pr" in cmd else (rec + "\n--- pi tail ---" if "--gpu" in cmd else "")
                return subprocess.CompletedProcess(cmd, 1 if "--gpu" in cmd else 0, out, "")
            d.sh = sh
            v = d.independent_review()
            self.assertIsInstance(v, L.ReviewVerdict)
            self.assertTrue(v.is_infra); self.assertFalse(v.is_fail)
            self.assertIn("no findings file", v.findings); self.assertEqual(v.label, "INFRA (retry)")
            self.assertEqual(d.s["reviewer_gpu"], "ts3")

    def test_st_review_asks_the_verdict_a_question_instead_of_unwrapping_a_pair(self):   # the smell #887 names
        import inspect
        src = inspect.getsource(L.Driver.st_review)
        self.assertIn("self.review_until_verdict()", src, "the retry-an-INFRA-verdict policy has one home")
        self.assertIn("verdict.is_fail", src, "st_review branches on the value object")
        for unwrapped in ("verdict[0]", "verdict[1]", "ok, findings = verdict"):
            self.assertNotIn(unwrapped, src, f"st_review still unwraps the pair with `{unwrapped}`")

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

    def watch(self, rt, sdir, start_s, beat=None, stall_s=None):
        """Build a Watch for a test run (ObjectMother): the same builder production uses, with since=now."""
        return rt.Watch.for_run(sdir, time.time(), start_s, beat=beat, stall_s=stall_s)

    def test_run_pi_kills_a_pi_with_no_session_record(self):
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            beats = []; t0 = time.monotonic()
            run = rt.run_pi(["bash", "-c", "sleep 60"], cwd=tmp, timeout=30, watch=self.watch(rt, tmp, 1, beat=beats.append))
            self.assertEqual(run.rc, rt.NO_START_RC); self.assertFalse(run.started)
            self.assertLess(time.monotonic() - t0, 15); self.assertTrue(beats and "pi_pid" in beats[0])

    def test_run_pi_stalled_after_model_output_is_stalled_not_no_start(self):
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            # The run deadline is only a backstop for a starved watchdog thread (on a loaded host the stall kill can land
            # late, and a 30 s deadline then won first: rc 124 instead of 125). Same start_s / stall_s, same assertions.
            run = rt.run_pi(["bash", "-c", f"echo '{HDR}' > {f}; echo '{ASSISTANT}' >> {f}; sleep 600"], cwd=tmp, timeout=120,
                            watch=self.watch(rt, tmp, 1, stall_s=2))
            self.assertEqual(run.rc, rt.NO_START_RC); self.assertTrue(run.started)

    def test_user_prompt_record_alone_is_no_start(self):   # review minor 5: the prompt record is not model output
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            run = rt.run_pi(["bash", "-c", f"echo '{HDR}' > {f}; echo '{USER}' >> {f}; sleep 60"], cwd=tmp, timeout=30,
                            watch=self.watch(rt, tmp, 1))
            self.assertEqual(run.rc, rt.NO_START_RC); self.assertFalse(run.started)

    def test_reused_session_dir_with_older_larger_file_is_not_killed(self):   # review major 1
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            old = os.path.join(tmp, "old.jsonl"); open(old, "w").write((ASSISTANT + "\n") * 60)
            os.utime(old, (time.time() - 3600, time.time() - 3600))   # an earlier run under the same task name
            new = os.path.join(tmp, "new.jsonl")
            script = (f"echo '{HDR}' > {new}; echo '{ASSISTANT}' >> {new}; "
                      f"for i in 1 2 3 4 5 6 7 8; do sleep 0.5; echo '{ASSISTANT}' >> {new}; done; echo PASS")
            t0 = time.monotonic()
            run = rt.run_pi(["bash", "-c", script], cwd=tmp, timeout=30, watch=self.watch(rt, tmp, 1.5))
            self.assertEqual(run.rc, 0, "a healthy run must not be judged against an older session file"); self.assertIn("PASS", run.text)
            self.assertGreater(time.monotonic() - t0, 1.5)
            self.assertEqual(rt.session_files(tmp, time.time() - 60), [new])

    def test_run_that_keeps_writing_records_survives_past_start_s(self):   # review minor 10
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            script = f"echo '{HDR}' > {f}; for i in $(seq 12); do sleep 0.5; echo '{ASSISTANT}' >> {f}; done; echo PASS"
            t0 = time.monotonic()
            run = rt.run_pi(["bash", "-c", script], cwd=tmp, timeout=30, watch=self.watch(rt, tmp, 1.5, stall_s=1.5))
            self.assertEqual(run.rc, 0); self.assertIn("PASS", run.text)
            self.assertGreater(time.monotonic() - t0, 3 * 1.5, "the run outlived start_s several times over")

    def test_cpu_work_after_start_is_activity_not_a_stall(self):   # review minor 4: a long build writes no record
        rt = self.rt()
        with tempfile.TemporaryDirectory() as tmp:
            f = os.path.join(tmp, "s.jsonl")
            script = (f"echo '{HDR}' > {f}; echo '{ASSISTANT}' >> {f}; "
                      "end=$((SECONDS+5)); while [ $SECONDS -lt $end ]; do :; done; echo PASS")
            run = rt.run_pi(["bash", "-c", script], cwd=tmp, timeout=30, watch=self.watch(rt, tmp, 1.5, stall_s=1.5))
            self.assertEqual(run.rc, 0, "CPU work in Pi's group after model output keeps the run alive"); self.assertIn("PASS", run.text)

    def test_failing_heartbeat_never_turns_the_watch_off(self):   # review minor 7
        rt = self.rt()
        def beat(d): raise OSError("disk full")
        with tempfile.TemporaryDirectory() as tmp:
            t0 = time.monotonic()
            run = rt.run_pi(["bash", "-c", "sleep 60"], cwd=tmp, timeout=30, watch=self.watch(rt, tmp, 1, beat=beat))
            self.assertEqual(run.rc, rt.NO_START_RC); self.assertLess(time.monotonic() - t0, 15)

    def test_pi_exiting_on_its_own_at_the_kill_keeps_its_rc(self):   # review minor 11
        rt = self.rt(); ev = rt.WatchEvent()
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
            run = rt.run_pi(["bash", "-c", "echo done; exit 0"], cwd=tmp, timeout=10, watch=self.watch(rt, tmp, 5))
            self.assertEqual(run.rc, 0); self.assertIn("done", run.text)

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
        with fake_modules({(L, "gpu_health"): lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}}):
            with fake_home() as h:
                d, calls = self.driver(h, ["no-start", "stalled", "PASS"])
                self.assertTrue(d.pi("review-fix-2", "fix it").ok)
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

    def test_large_item_relaunch_keeps_its_size_routing(self):   # review major 2, related minor
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "obs", "pro5000"]), ["pro5000"])
        self.assertEqual(L.relaunch_gpus(None, ["ts3", "obs", "pro5000"]), ["pro5000"])
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "obs"]), ["obs", "ts3"])   # pro5000 down: as pick_gpu
        self.assertEqual(L.relaunch_gpus("small", ["ts3", "pro5000"]), ["pro5000", "ts3"])
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "pro6000", "pro5000"]), ["pro5000", "pro6000"])   # either 262K GPU
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "pro6000"]), ["pro6000"])
        self.assertEqual(L.relaunch_gpus("small", ["ts3", "obs", "pro6000", "pro5000"]), ["pro5000", "pro6000", "obs", "ts3"])
        with fake_modules({(L, "gpu_health"): lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}}):
            with fake_home() as h:
                d, calls = self.driver(h, ["stalled", "PASS"], size="large")
                self.assertTrue(d.pi("t1", "do it").ok)
                self.assertEqual(calls[1][calls[1].index("--gpu") + 1], "pro5000,pro6000")   # a 262K GPU only

    def test_review_excludes_every_authoring_gpu_including_relaunch_gpus(self):   # review major 2
        self.assertEqual(G.reviewer_gpus(["ts3", "obs"], list(G.GPUS)), ["pro5000", "pro6000"])
        self.assertEqual(G.reviewer_gpus("ts3", list(G.GPUS)), ["pro5000", "pro6000", "obs"])
        with patched_driver_env(gpu_health=lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}, research_ok=lambda *a: True) as h:
            d, calls = self.driver(h, ["stalled", ("PASS", "obs")])   # item on ts3; the relaunch wrote the code on obs
            self.assertTrue(d.pi("t1", "do it").ok)
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
        with fake_modules({(L, "gpu_health"): lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}}):
            with fake_home() as h:
                d, _ = self.driver(h, [("no-start", "pro5000,obs,ts3"), "PASS"])
                self.assertTrue(d.pi("t1", "do it").ok); self.assertEqual(d.s.get("author_gpus"), ["pro5000"])

    def test_read_only_calls_and_no_start_are_not_author_gpus(self):   # re-review major A / minor D
        self.assertFalse(L.writes_code("draft-plan")); self.assertFalse(L.writes_code("refactoring-research-1"))
        self.assertFalse(L.writes_code("independent-review-2")); self.assertTrue(L.writes_code("review-fix-1"))
        with fake_modules({(L, "gpu_health"): lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}}):
            with fake_home() as h:
                d, _ = self.driver(h, [("PASS", "pro5000")])   # item on ts3; plan drafted on pro5000
                self.assertTrue(d.pi("draft-plan", "plan it", gpu="pro5000").ok)
                d2, _ = self.driver(h, [("PASS", "pro5000")]); d2.pi("refactoring-research-1", "research")
                self.assertNotIn("pro5000", d.author_gpus()); self.assertNotIn("pro5000", d2.author_gpus())
                self.assertIn("pro5000", G.reviewer_gpus(d.author_gpus(), list(G.GPUS)), "pro5000 stays a reviewer")
                d3, _ = self.driver(h, [("no-start", "obs"), ("PASS", "ts3")])   # got a slot on obs but never replied
                self.assertTrue(d3.pi("t1", "do it").ok); self.assertNotIn("obs", d3.author_gpus())

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
        with fake_modules({(L, "time"): T()}):
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

    def test_handoff_blocks_after_two_relaunches_and_reviews_are_not_relaunched(self):
        with fake_modules({(L, "gpu_health"): lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}}):
            with fake_home() as h:
                d, calls = self.driver(h, ["no-start"] * 3)
                with self.assertRaises(L.PiNotStarted) as e: d.pi("t1", "do it")
                self.assertEqual(len(calls), 3); self.assertFalse(L.hold_resumes(str(e.exception)))
                d, calls = self.driver(h, ["no-start"])
                self.assertFalse(d.pi("independent-review-1", "review", gpu="obs").ok); self.assertEqual(len(calls), 1)

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
            self.assertTrue(d.pi(name, "do it").ok)   # used to raise FileNotFoundError (raw '/' in the prompt path)
            arg = lambda c, f: c[c.index(f) + 1]
            pf = arg(calls[0], "--prompt-file")
            self.assertEqual(pf, os.path.join(d.run_dir, "logs", "test--whole-factory-pi-suite-green-and-no-orphans-left.prompt.md"))
            self.assertTrue(os.path.exists(pf))
            self.assertIn("do it", open(pf).read())
            self.assertEqual(arg(calls[0], "--task"), "test--whole-factory-pi-suite-green-and-no-orphans-left")

    def test_pi_safe_name_keeps_its_existing_log_names(self):
        with fake_home() as h:
            d, calls = self.driver_with_scripted_run(h, 960, ["PASS"])
            self.assertTrue(d.pi("t1", "do it").ok)
            arg = lambda c, f: c[c.index(f) + 1]
            self.assertEqual(arg(calls[0], "--task"), "t1")
            self.assertEqual(arg(calls[0], "--prompt-file"), os.path.join(d.run_dir, "logs", "t1.prompt.md"))
            self.assertTrue(os.path.exists(os.path.join(d.run_dir, "logs", "t1.prompt.md")))

    def test_pi_relaunch_prompt_paths_are_slugged_too(self):
        with fake_modules({(L, "gpu_health"): lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}}):
            with fake_home() as h:
                d, calls = self.driver_with_scripted_run(h, 961, ["no-start", "PASS"])
                name = "test: whole factory/pi suite green"
                self.assertTrue(d.pi(name, "do it").ok)
                arg = lambda c, f: c[c.index(f) + 1]
                self.assertEqual([arg(c, "--task") for c in calls],
                                 ["test--whole-factory-pi-suite-green", "test--whole-factory-pi-suite-green-relaunch-1"])
                for c in calls:
                    pf = arg(c, "--prompt-file")
                    self.assertTrue(os.path.exists(pf), pf)
                self.assertIn("partial edits", open(arg(calls[1], "--prompt-file")).read())

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
        self.assertEqual(L.busy_gpus(st, None, alive), set())           # review (e) no longer holds its author GPU (cmdemo1-system#877)
        self.assertEqual(L.busy_gpus(st + [("f", {"gpu": "pro5000", "stage": "ci", "pid": 6})], None, alive), {"pro5000"})
        self.assertEqual(L.busy_gpus(st, "a", alive), set())
        self.assertEqual(L.repo_wip(st, "cmdemo1-workorders", None, alive), 2)   # a (ci) + d (blocked in review)
        self.assertEqual(L.repo_wip(st, "cmdemo1-dashboard", None, alive), 1)
        self.assertEqual(L.WIP_LIMIT, 3)
        self.assertEqual((L.wip_limit("cmdemo1-dashboard"), L.wip_limit("cmdemo1-workorders"), L.wip_limit("cmdemo1-system")), (8, 3, 3))

    def test_review_and_merge_items_do_not_hold_their_author_gpu(self):   # cmdemo1-system#877
        alive = lambda pid: True
        st = [("rev", {"gpu": "ts3", "stage": "review", "pid": 1}),
              ("mrg", {"gpu": "obs", "stage": "merge", "pid": 2}),
              ("imp", {"gpu": "pro5000", "stage": "implement", "pid": 3})]
        self.assertEqual(L.busy_gpus(st, None, alive), set(),
                         "review and merge items must not count toward their recorded (author) GPU")
        # a GPU-holding stage item still holds its GPU
        self.assertEqual(L.busy_gpus(st, None, alive), set(),
                         "pro5000 has 2 slots, only 1 held by implement")
        # fill pro5000's second slot: now busy
        st2 = st + [("imp2", {"gpu": "pro5000", "stage": "ci", "pid": 4})]
        self.assertEqual(L.busy_gpus(st2, None, alive), {"pro5000"},
                         "two GPU-holding items on pro5000 (2 slots) make it busy")
        # ts3 becomes busy only when a GPU-holding item is on it, not a review item
        st3 = st + [("imp3", {"gpu": "ts3", "stage": "pickup", "pid": 5})]
        self.assertEqual(L.busy_gpus(st3, None, alive), {"ts3"},
                         "a GPU-holding item on ts3 (1 slot) makes it busy even though a review item is also recorded there")

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

    def test_research_ok_accepts_stem_only(self):   # cmdemo1-system#913: stem on a word boundary passes
        # names only the stem `ChurchTimeZone`, never the file `ChurchTimeZone.cs`
        stem_only = ("## Refactoring research\n\n- `ChurchTimeZone` `CompletionWindow`: 80-line method with duplicated "
                     "validation; extract a specification object (in scope).\n- `ChurchTimeZone` `status` strings: "
                     "primitive obsession; a value object would make the rules explicit (follow-up: filed).\n- Tests "
                     "build data by hand; an ObjectMother would keep them short.\n\nIn scope: extract the "
                     "specification. Follow-up: status value object.")
        self.assertTrue(L.research_ok(stem_only, ["src/ChurchTimeZone.cs"]))

    def test_research_ok_still_fails_when_no_touched_file_named(self):   # cmdemo1-system#913: no touched file → still fails
        # names `OtherType` which is NOT the stem of `ChurchTimeZone.cs`
        no_match = ("## Refactoring research\n\n- `OtherType` `CompletionWindow`: 80-line method with duplicated "
                    "validation; extract a specification object (in scope).\n- `OtherType` `status` strings: "
                    "primitive obsession; a value object would make the rules explicit (follow-up: filed).\n- Tests "
                    "build data by hand; an ObjectMother would keep them short.\n\nIn scope: extract the "
                    "specification. Follow-up: status value object.")
        self.assertFalse(L.research_ok(no_match, ["src/ChurchTimeZone.cs"]))

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
        # The research-redo path lives in the verdict-FAIL helper (cmdemo1-system#918): sync_pr_research() and the
        # journal comment must stay adjacent, no commit on this path.
        src = inspect.getsource(L.Driver._st_review_verdict_fail)
        i = src.index("self.sync_pr_research()")
        self.assertIn('self.comment("Research re-done after the review FAIL', src[i:i + 300])

    def test_st_review_fail_comments_use_the_mirror(self):   # both FAIL branches go through review_fail_comment
        import inspect
        # The two review_fail_comment calls now live in the two FAIL-outcome helpers (cmdemo1-system#918): the
        # evidence-failed one and the verdict-fail one, one each.
        src = (inspect.getsource(L.Driver.st_review)
               + inspect.getsource(L.Driver._st_review_evidence_failed)
               + inspect.getsource(L.Driver._st_review_verdict_fail))
        self.assertEqual(src.count("self.review_fail_comment("), 2)
        self.assertNotIn('self.comment("Review → In Progress', src)
        self.assertNotIn('self.comment(f"Review → In Progress', src)

class StagedFilesGate(unittest.TestCase):
    """The protected-file gate: item_loop.staged_files(sh, wt, default) (the files staged in the worktree's index
    relative to the merge base of HEAD and origin/<default>, with protected_files() applied to the result) and the
    `st_pr` enhancement gate that reads it. The staged_files tests run on a real temporary git repo: a bare origin
    remote, a main branch, and a worktree branched from an older main commit after main has advanced with a commit
    touching environments/prod/versions.json."""

    def build_merge_base_repo(self, tmp):
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
            sh, wt = self.build_merge_base_repo(tmp)
            self.stage(wt, "factory/pi/sample.txt", "two\n")
            staged = L.staged_files(sh, wt, "main")
            self.assertEqual(sorted(staged), ["factory/pi/sample.txt"])   # only what the worktree staged; not main's prod bump
            self.assertEqual(L.protected_files(staged), [])

    def test_staged_files_merge_base_protected_nonempty_for_prod_versions(self):
        with tempfile.TemporaryDirectory() as tmp:
            sh, wt = self.build_merge_base_repo(tmp)
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

    def hold_all_gpus(self, h):
        """Create fake live items in another repo that hold every available GPU: both pro5000 slots, obs and ts3.
        Returns the runs directory path."""
        runs = os.path.join(h, "factory-runs")
        for i, (gpu, stage) in enumerate((("pro5000", "ci"), ("pro5000", "ci"), ("obs", "implement"), ("ts3", "review"))):
            r = os.path.join(runs, f"cmdemo1-dashboard-{11 + i}"); os.makedirs(r)
            json.dump({"repo": "cmdemo1-dashboard", "issue": 11 + i, "gpu": gpu, "stage": stage,
                      "status": "running", "pid": os.getpid()}, open(os.path.join(r, "state.json"), "w"))
        return runs

    def test_errone_gpu_item_waits_while_gpus_held_then_blocks(self):
        with patched_driver_env(time=Clock(),
                                gpu_health=lambda max_age=600: {g: ("HEALTHY", "") for g in ("pro5000", "obs", "ts3")}) as h:
            self.hold_all_gpus(h)
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
        with fake_modules({(L, "gpu_health"): fake}):
            with fake_home():
                self.assertIs(make_driver(issue=102).gpu_health, fake)   # a patch before construction is honored

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
                return L.PiRun(result="FAIL", gpu=None, rc=1)

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

    def _run_with_plan(self, plan):
        """Run cmd_draft_plan with the patched pi writing `plan` (a dict or None) to the quoted out path.
        Returns (calls, exit_code, stdout_json) -- stdout_json is the parsed JSON object printed by
        draft_result, the first JSON object at the start of the captured stdout."""
        calls = []
        out = io.StringIO()
        with fake_home():
            gh = mock.Mock(return_value=mock.Mock(stdout='{"title": "t", "body": "b"}'))
            plan, out_of = plan, self._out_of

            def pi(self, name, prompt, timeout, gpu=None):
                calls.append((name, prompt, timeout, gpu))
                if plan is not None: json.dump(plan, open(out_of(prompt), "w"))
                return L.PiRun(result="FAIL", gpu=None, rc=1)

            code = None
            with mock.patch.object(L.Driver, "gh", gh), mock.patch.object(L.Driver, "plan_worktree", mock.Mock()), \
                    mock.patch.object(L.Driver, "pi", pi), contextlib.redirect_stdout(out):
                try:
                    L.cmd_draft_plan(argparse.Namespace(repo="cmdemo1-system", issue=884, top_session=None))
                except SystemExit as e:
                    code = e.code
        text = out.getvalue()
        # the JSON object starts at the first '{' and ends before the trailing newline+review line
        start = text.index("{")
        # find the matching close brace by counting
        depth = 0
        for i in range(start, len(text)):
            if text[i] == "{": depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0: break
        obj = json.loads(text[start:i+1])
        return calls, code, obj

    def test_draft_plan_reports_missing_keys_for_partial_draft(self):
        """A partial draft (PLAN minus criteria and verify_cmd) prints missing == [criteria, verify_cmd],
        errors includes 'missing criteria', and the exit code is 1."""
        partial = {k: v for k, v in self.PLAN.items() if k not in ("criteria", "verify_cmd")}
        calls, code, obj = self._run_with_plan(partial)
        self.assertEqual(obj["missing"], ["criteria", "verify_cmd"])
        self.assertIn("missing criteria", obj["errors"])
        self.assertEqual(code, 1)

    def test_draft_plan_complete_draft_reports_empty_missing(self):
        """A complete (valid) draft prints 'missing': []."""
        calls, code, obj = self._run_with_plan(self.PLAN)
        self.assertEqual(obj["missing"], [])
        self.assertEqual(code, 0)

class GhChokepoint(unittest.TestCase):   # cmdemo1-system#828: every gh call is one sh chokepoint with explicit check, timeout and write
    def gh_recorder(self):
        """Delegates to the shared recorder in item_loop_test_fakes (#1021) -- the same one DriverShGroupKill uses."""
        return fakes.gh_recorder()

    def test_gh_passes_timeout_and_check_to_sh(self):
        with fake_home() as h:
            d = make_driver(repo="cmdemo1-system", issue=828)
            sh, calls = self.gh_recorder(); d.sh = sh
            d.gh("run", "watch", "1", check=False, timeout=21600)
            cmd, k = calls[0]
            self.assertIsInstance(cmd, L.Command)
            self.assertEqual(list(cmd.argv), ["gh", "run", "watch", "1"])
            self.assertEqual((k.get("check"), k.get("timeout")), (False, 21600))
            self.assertFalse(cmd.write)

    def test_gh_defaults_unchanged(self):
        with fake_home() as h:
            d = make_driver(repo="cmdemo1-system", issue=828)
            sh, calls = self.gh_recorder(); d.sh = sh
            d.gh("pr", "list")
            cmd, k = calls[0]
            self.assertIsInstance(cmd, L.Command)
            self.assertEqual(list(cmd.argv), ["gh", "pr", "list"])
            self.assertEqual((k.get("check"), k.get("timeout")), (True, None))
            self.assertFalse(cmd.write)

    def test_gh_decides_the_policy(self):
        """cmdemo1-system#947: gh() builds the Command and decides is_gh, app_ok and write -- sh() never sniffs."""
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=828)
            sh, calls = self.gh_recorder(); d.sh = sh
            # a plain gh read: is_gh=True, app_ok=True, write=False
            d.gh("pr", "list")
            cmd = calls[0][0]
            self.assertTrue(cmd.is_gh); self.assertTrue(cmd.app_ok); self.assertFalse(cmd.write)
            # pr create / issue create stay on the user login: app_ok=False
            d.gh("pr", "create", "--title", "t")
            cmd = calls[1][0]
            self.assertTrue(cmd.is_gh); self.assertFalse(cmd.app_ok); self.assertFalse(cmd.write)
            d.gh("issue", "create", "--title", "t")
            cmd = calls[2][0]
            self.assertTrue(cmd.is_gh); self.assertFalse(cmd.app_ok); self.assertFalse(cmd.write)
            # a write: write=True
            d.gh("pr", "comment", "1", "--body", "hi", write=True)
            cmd = calls[3][0]
            self.assertTrue(cmd.is_gh); self.assertTrue(cmd.app_ok); self.assertTrue(cmd.write)

    def test_sh_rejects_conflicting_write_kwarg_on_command(self):
        """A Command owns its write flag: a conflicting write= kwarg raises ValueError."""
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=828, dry_run=False)
            c = L.Command(["gh", "pr", "list"], is_gh=True, app_ok=True, write=False)
            with self.assertRaises(ValueError):
                d.sh(c, write=True)
            # matching kwarg is fine
            c2 = L.Command(["git", "status"], write=True)
            r = d.sh(c2, write=True, check=False)
            self.assertIsInstance(r, subprocess.CompletedProcess)

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


class EnsurePrTests(unittest.TestCase):   # cmdemo1-system#922: the shared ensure_pr helper - mocked self.gh, no network
    """ensure_pr is the PR-version of the find-existing-or-create pattern (the ensure_issue pattern, for a different
    object): saved PR first, then the open PR for this branch, then create. It consolidates PR-number parsing and
    creation in one place. Every test records each d.gh call and asserts the exact gh args. create_pr must RAISE when
    gh's output does not parse to a number - it must never save pr=None and let st_ci run `gh pr checks None`."""

    REPO = "cmdemo1-workorders"

    def driver_and_gh(self, list_stdout="", create_stdout="", create_rc=0, saved_pr=None, issue=922):
        """A dry-run driver with its plan/default/gpu/run_id set and self.gh mocked: `pr list` answers `list_stdout`,
        `pr create` answers (create_rc, create_stdout). Returns (driver, call recorder)."""
        d = make_driver(repo=self.REPO, issue=issue)
        d.s["plan"] = PLAN
        d.s["default"] = "main"
        d.s["gpu"] = "obs"
        d.s["run_id"] = "run922"
        if saved_pr is not None: d.s["pr"] = saved_pr
        d.usage = lambda final=False: "usage"
        calls = []
        def gh(*a, **k):
            calls.append((list(a), dict(k)))
            if a and a[0] == "pr" and len(a) > 1 and a[1] == "list":
                return subprocess.CompletedProcess(("gh",) + a, 0, list_stdout, "")
            if a and a[0] == "pr" and len(a) > 1 and a[1] == "create":
                return subprocess.CompletedProcess(("gh",) + a, create_rc, create_stdout, "")
            return subprocess.CompletedProcess(("gh",) + a, 0, "", "")
        d.gh = gh
        return d, calls

    def test_saved_pr_shortcut_returns_without_gh_call(self):
        with fake_home():
            d, calls = self.driver_and_gh(saved_pr=77)
            self.assertEqual(d.ensure_pr("abc123def"), 77)
            self.assertEqual(calls, [])   # no gh call at all when the PR is already saved

    def test_adopts_an_already_open_pr(self):
        with fake_home():
            d, calls = self.driver_and_gh(list_stdout="55\n")
            self.assertEqual(d.ensure_pr("abc123def"), 55)
            self.assertEqual(d.s["pr"], 55)
            # exactly one gh call: the pr list; no create
            self.assertEqual(len(calls), 1)
            args, kw = calls[0]
            self.assertEqual(args[0:2], ["pr", "list"])
            self.assertEqual(args[args.index("--head") + 1], PLAN["branch"])
            self.assertEqual(kw.get("check"), False)

    def test_creates_new_pr_when_none_open(self):
        with fake_home():
            url = f"https://github.com/{L.ORG}/{self.REPO}/pull/42"
            d, calls = self.driver_and_gh(list_stdout="", create_stdout=url + "\n")
            self.assertEqual(d.ensure_pr("abc123def"), 42)
            self.assertEqual(d.s["pr"], 42)
            verbs = [(a[0], a[1]) for a, _ in calls if a]
            # the first two gh calls are the find-then-create; move/comment add api/graphql + issue/comment after
            self.assertEqual(verbs[0], ("pr", "list")); self.assertEqual(verbs[1], ("pr", "create"))
            create_args = next(a for a, _ in calls if a and a[0:2] == ["pr", "create"])
            self.assertEqual(create_args, ["pr", "create", "-R", f"{L.ORG}/{self.REPO}",
                                           "--head", PLAN["branch"], "--base", "main", "--title", PLAN["pr_title"],
                                           "--body-file", create_args[create_args.index("--body-file") + 1]])
            self.assertEqual(next(k for a, k in calls if a and a[0:2] == ["pr", "create"]).get("write"), True)

    def test_create_pr_parses_number_from_url_with_trailing_slash(self):
        with fake_home():
            url = f"https://github.com/{L.ORG}/{self.REPO}/pull/88/"
            d, calls = self.driver_and_gh(create_stdout=url + "\n")
            self.assertEqual(d.create_pr("abc123def"), 88)
            self.assertEqual(d.s["pr"], 88)

    def test_create_pr_parses_number_from_plain_url(self):
        with fake_home():
            url = f"https://github.com/{L.ORG}/{self.REPO}/pull/88"
            d, calls = self.driver_and_gh(create_stdout=url + "\n")
            self.assertEqual(d.create_pr("abc123def"), 88)

    def test_create_pr_raises_on_unparseable_output(self):
        """The regression the prior attempt introduced: unparseable create output must raise, not save pr=None."""
        for bad in ("", "HTTP 422: Validation Failed", "not a number", "42abc"):
            with fake_home():
                d, calls = self.driver_and_gh(create_rc=0, create_stdout=bad + "\n")
                with self.assertRaises(RuntimeError):
                    d.create_pr("abc123def")
                self.assertNotIn("pr", d.s)   # never saved a pr (certainly not None)

    def test_create_pr_raises_on_http_error_output(self):
        with fake_home():
            d, calls = self.driver_and_gh(create_rc=1, create_stdout="HTTP 422: Validation Failed")
            with self.assertRaises(RuntimeError):
                d.create_pr("abc123def")
            self.assertNotIn("pr", d.s)

    def test_ensure_pr_propagates_unparseable_create(self):
        with fake_home():
            d, calls = self.driver_and_gh(list_stdout="", create_rc=0, create_stdout="garbage")
            with self.assertRaises(RuntimeError):
                d.ensure_pr("abc123def")
            self.assertNotIn("pr", d.s)


class EnsurePrNumberParse(unittest.TestCase):   # cmdemo1-system#922: pr_number now parses a PR URL as well as a plain number
    def test_plain_number_and_whitespace(self):
        self.assertEqual(L.pr_number("42"), 42)
        self.assertEqual(L.pr_number(" 42 "), 42)

    def test_url_without_trailing_slash(self):
        self.assertEqual(L.pr_number("https://github.com/x/y/pull/123"), 123)

    def test_url_with_trailing_slash(self):
        self.assertEqual(L.pr_number("https://github.com/x/y/pull/123/"), 123)

    def test_non_numeric_is_none(self):
        for bad in ("", "not a number", "HTTP 404: Not Found", "42abc", None, "no open PR for that head"):
            self.assertIsNone(L.pr_number(bad))


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
        d.pi = lambda name, prompt, timeout=L.PI_TASK_TIMEOUT_S, gpu=None: (ev.append(("pi", name, prompt)), L.PiRun(result="PASS", gpu=None, rc=0))[-1]
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
        # st_review's two FAIL-outcome helpers own the review fix_pass calls (cmdemo1-system#918), so for st_review the
        # guarded source is the dispatcher plus those two helpers; the other stages are their own method only.
        review_helpers = ("_st_review_evidence_failed", "_st_review_verdict_fail")
        for name, key in (("st_ci", "ci_fix"), ("fix_quality", "quality_fix"), ("st_review", "review_fail"), ("st_merge", "merge_gate")):
            with self.subTest(stage=name):
                src = inspect.getsource(getattr(L.Driver, name))
                if name == "st_review":
                    src += "".join(inspect.getsource(getattr(L.Driver, h)) for h in review_helpers)
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


class LatestAttemptMergeRule(unittest.TestCase):   # cmdemo1-system#886: ONE "latest attempt wins" rule + a MergeGate object
    """`gh pr checks --json name,bucket` lists one entry per attempt, so a rerun puts the same check name in the list
    twice. item_loop.latest_attempt() is now the only place that decides which entry counts, and MergeGate is its only
    reader: checks_state, quality_states, quality_failures, quality_pending and gate_state are thin wrappers over it,
    so the required checks and the Qodana / Refactoring-rationale hard gate can no longer disagree about the same
    list. Pinned here for BOTH kinds of check (the old tests pinned one half each: test_checks_state the sticky pass
    of a required check, NoIdleStall a quality fail-then-pass), plus the gate's red / pending / green answers, the
    hard gate end to end through st_ci, and the guard that no wrapper or stage re-derives it from raw buckets."""

    REQ = ["Build result", "secret-scan"]
    OK = [{"name": "Build result", "bucket": "pass"}, {"name": "secret-scan", "bucket": "pass"}]

    # ---- the shared rule itself
    def test_latest_attempt_is_the_one_rule_for_any_check_name(self):
        self.assertEqual(L.latest_attempt([{"name": "a", "bucket": "fail"}, {"name": "a", "bucket": "pass"}]), {"a": "pass"},
                         "a rerun's pass beats the earlier failure")
        self.assertEqual(L.latest_attempt([{"name": "a", "bucket": "pass"}, {"name": "a", "bucket": "fail"}]), {"a": "pass"},
                         "and it wins in either list order: a name that has passed stays passed")
        self.assertEqual(L.latest_attempt([{"name": "a", "bucket": "fail"}, {"name": "a", "bucket": "cancel"}]), {"a": "cancel"},
                         "a name that never passed: the last entry is its state")
        self.assertEqual(L.latest_attempt([{"name": "a", "bucket": "pass"}, {"name": "a", "bucket": "skipping"}]), {"a": "skipping"},
                         "green buckets replace each other (both mean finished and good)")
        self.assertEqual(L.latest_attempt([{"name": "a"}, {"name": "b", "bucket": "pass"}]), {"a": "pending", "b": "pass"},
                         "gh omits the bucket while a check is queued")
        self.assertEqual(L.latest_attempt([]), {}); self.assertEqual(L.latest_attempt(None), {})

    def test_the_bucket_predicates_say_finished_good_and_running_once(self):
        for b in ("pass", "skipping"):
            self.assertTrue(L.bucket_green(b), b); self.assertFalse(L.bucket_red(b), b); self.assertFalse(L.bucket_running(b), b)
        for b in ("fail", "cancel"):
            self.assertTrue(L.bucket_red(b), b); self.assertFalse(L.bucket_green(b), b); self.assertFalse(L.bucket_running(b), b)
        for b in ("pending", "queued"):
            self.assertTrue(L.bucket_running(b), b)
            self.assertFalse(L.bucket_green(b), b); self.assertFalse(L.bucket_red(b), b)
        self.assertEqual(L.bucket({"name": "a"}), "pending", "a missing bucket reads as pending, not as an empty string")
        self.assertEqual(L.bucket({"bucket": None}), "pending", "and so does an explicit null")
        self.assertTrue(L.bucket_running(L.bucket({"bucket": None})), "so a queued check holds the gate pending")

    def test_required_and_quality_names_cannot_disagree_about_the_same_list(self):
        cs = [{"name": "env-checks", "bucket": "fail"}, {"name": "env-checks", "bucket": "pass"},
              {"name": "Qodana", "bucket": "pass"}, {"name": "Qodana", "bucket": "fail"},
              {"name": "Refactoring rationale", "bucket": "fail"}, {"name": "Refactoring rationale", "bucket": "pass"}]
        self.assertEqual(L.checks_state(cs, ["env-checks"]), "GREEN", "the rerun's pass wins for a required check")
        self.assertEqual(L.quality_states(cs), {"Qodana": "pass", "Refactoring rationale": "pass"},
                         "and the same rule answers for the quality checks -- no second merge loop")
        self.assertEqual(L.quality_failures(cs), []); self.assertEqual(L.quality_pending(cs), [])
        self.assertEqual(L.gate_state(cs, ["env-checks"]), "GREEN")
        still_red = [{"name": "Qodana", "bucket": "pending"}, {"name": "Qodana", "bucket": "fail"}]
        self.assertEqual((L.quality_states(still_red), L.quality_failures(still_red)), ({"Qodana": "fail"}, ["Qodana"]),
                         "a name that never passed keeps its red")

    # ---- the gate as a value object, built on that rule
    def test_merge_gate_answers_red_pending_green_for_the_whole_gate(self):
        for cs, want in ((self.OK, "GREEN"),
                         (self.OK + [{"name": "Qodana", "bucket": "pass"}, {"name": "Refactoring rationale", "bucket": "pass"}], "GREEN"),
                         (self.OK + [{"name": "Qodana", "bucket": "fail"}], "RED"),
                         (self.OK + [{"name": "Refactoring rationale", "bucket": "pending"}], "PENDING"),
                         ([{"name": "Build result", "bucket": "fail"}, {"name": "secret-scan", "bucket": "pass"}], "RED")):
            g = L.MergeGate(cs, self.REQ)
            with self.subTest(checks=cs):
                self.assertEqual(g.state(), want)
                self.assertEqual(g.red(), want == "RED"); self.assertEqual(g.pending(), want == "PENDING")
                self.assertEqual(g.green(), want == "GREEN")
        g = L.MergeGate(self.OK + [{"name": "Qodana", "bucket": "fail"}], self.REQ)
        self.assertEqual(g.required_state(), "GREEN", "a quality red is the gate's, not the required checks' red")
        self.assertEqual(g.quality_red(), ["Qodana"]); self.assertEqual(g.quality_pending(), [])

    def test_merge_gate_is_built_on_latest_attempt_and_reads_the_list_once(self):
        cs = self.OK + [{"name": "Qodana", "bucket": "fail"}, {"name": "Qodana", "bucket": "pass"},
                        {"name": "Refactoring rationale", "bucket": "queued"}]
        g = L.MergeGate(cs, self.REQ)
        self.assertEqual(g.buckets, L.latest_attempt(cs), "the gate reads the list through the shared merge rule")
        self.assertEqual(g.quality_red(), [])
        self.assertEqual(g.quality_pending(), ["Refactoring rationale"])
        self.assertEqual((L.gate_state(cs, self.REQ), g.state()), (g.state(), g.state()))
        self.assertEqual((L.quality_failures(cs), g.quality_red()), (g.quality_red(), g.quality_red()))
        self.assertEqual((L.quality_pending(cs), g.quality_pending()), (g.quality_pending(), g.quality_pending()))

    def test_merge_gate_with_no_required_list_treats_every_check_as_required(self):
        self.assertEqual(L.MergeGate([{"name": "a", "bucket": "pass"}, {"name": "b", "bucket": "fail"}]).state(), "RED")
        self.assertEqual(L.MergeGate([]).state(), "PENDING", "no checks at all is never GREEN")
        self.assertEqual(L.MergeGate([], []).state(), "PENDING", "an empty required list means every check, as before")
        self.assertEqual(L.MergeGate([{"name": "a", "bucket": "pass"}], ["a", "b"]).state(), "PENDING",
                         "a required check missing from the list is still pending")

    def test_the_quality_hard_gate_answers_for_skipped_and_non_exact_names(self):
        self.assertEqual(L.quality_failures([{"name": "Qodana code quality", "bucket": "cancel"}]), ["Qodana code quality"],
                         "the quality match is the same substring test for red and for pending")
        self.assertEqual(L.quality_pending([{"name": "Refactoring Rationale for src/A.cs", "bucket": "queued"}]),
                         ["Refactoring Rationale for src/A.cs"])
        self.assertEqual((L.quality_failures([{"name": "Qodana", "bucket": "skipping"}]),
                          L.quality_pending([{"name": "Qodana", "bucket": "skipping"}])), ([], []),
                         "a skipped quality check is neither red nor still running (behaviour unchanged)")

    # ---- the gate end to end where the merge decision is made
    def ci_driver(self, cs):
        """A driver in the ci stage whose PR answers `cs` (required green), with nothing posted and nothing slept."""
        d = make_driver(repo="cmdemo1-system", issue=886, dry_run=False)
        d.events = []
        d.s.update(counts={k: 0 for k in L.LIMITS}, plan=dict(PLAN), wt="/tmp/wt", gpu="pro5000", pr=7,
                   head="h" * 40, stage="ci")
        cs_all = [{"name": "env-checks", "bucket": "pass"}] + cs
        d.wait_ci = lambda: (L.CheckState.GREEN, cs_all)
        d.pr_checks = lambda: (L.CheckState.GREEN, cs_all)   # the same PR answers when the merge stage re-reads it
        d.heartbeat = lambda *a, **k: None
        d.comment = lambda body, pr=False: d.events.append(("comment", body))
        d.blocker = lambda what, who="Jeffrey": (d.events.append(("blocker", what)), d.save(stage="blocked", blocker=what))[-1]
        return d

    def test_ci_waits_for_an_unfinished_quality_check_and_blocks_when_it_never_finishes(self):
        with patched_driver_env(sleep=lambda s: None), fake_home():
            d = self.ci_driver([{"name": "Qodana", "bucket": "pending"}])
            d.st_ci()
            self.assertIn("quality_wait_since", d.s, "required green + Qodana pending: the gate holds at ci")
            self.assertEqual(d.s["stage"], "ci"); self.assertEqual(d.events, [])
            d.s["quality_wait_since"] = (L.now() - L.dt.timedelta(minutes=L.QUALITY_WAIT_MIN + 1)).isoformat()
            d.st_ci()
            self.assertEqual(d.events, [("blocker", f"Qodana did not finish within {L.QUALITY_WAIT_MIN} minutes.")],
                             "the hard gate names the quality check that never finished")

    def test_ci_moves_to_review_once_required_and_quality_are_both_green(self):
        with patched_driver_env(sleep=lambda s: None), fake_home():
            d = self.ci_driver([{"name": "Qodana", "bucket": "fail"}, {"name": "Qodana", "bucket": "pass"},
                                {"name": "Refactoring rationale", "bucket": "pass"}])
            d.s["quality_wait_since"] = L.iso()
            d.st_ci()
            self.assertEqual(d.s["stage"], "review", "the rerun's pass beats the earlier Qodana failure")
            self.assertNotIn("quality_wait_since", d.s)
            self.assertEqual(d.events, [])

    def test_merge_stage_asks_the_gate_object_for_the_merge_decision(self):
        with patched_driver_env(sleep=lambda s: None), fake_home():
            d = self.ci_driver([{"name": "Qodana", "bucket": "pending"}])
            d.s.update(stage="merge", head="h" * 40)
            d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, json.dumps(
                {"author": {"login": L.BOT}, "headRefOid": "h" * 40, "state": "OPEN"}), "")
            d.st_merge()
            self.assertEqual(d.s["stage"], "ci", "a pending quality check keeps the gate from merging")

    # ---- the guard: one rule, and no re-derivation of it
    def test_the_wrappers_answer_through_the_gate_not_their_own_merge_loop(self):
        bucket_literal = re.compile(r'"(?:pass|skipping|fail|cancel)"')
        for name in ("checks_state", "quality_states", "quality_failures", "quality_pending", "gate_state"):
            src = inspect.getsource(getattr(L, name))
            with self.subTest(fn=name):
                self.assertIn("MergeGate", src, f"{name} must answer through MergeGate (or latest_attempt), not its own merge loop")
                self.assertIsNone(bucket_literal.search(src), f"{name} re-types a gh bucket literal instead of using the predicates")

    def test_the_stages_ask_this_repos_gate_instead_of_re_deriving_buckets(self):
        bucket_literal = re.compile(r'"(?:pass|skipping|fail|cancel)"')
        for name in ("merge_gate", "pr_checks", "st_ci", "st_merge", "hold_blocked"):
            src = inspect.getsource(getattr(L.Driver, name))
            with self.subTest(site=name):
                self.assertIn("merge_gate", src, f"Driver.{name} must ask the repo's gate object")
                self.assertIsNone(re.search(r"(?<![.\w])(?:gate_state|quality_failures|quality_pending)\(", src),
                                  f"Driver.{name} re-derives the gate from raw checks instead of asking MergeGate")
                self.assertIsNone(bucket_literal.search(src), f"Driver.{name} re-types a gh bucket literal")
        self.assertIn("latest_attempt", inspect.getsource(L.MergeGate.__init__),
                      "the gate is built on the one merge rule")


class SplitReviewAndDeploy(unittest.TestCase):   # cmdemo1-system#859: the extracted stage helpers are small and unit-testable
    """The three methods #859 pulls out of the long st_review / st_deploy bodies -- Driver.evidence_results,
    Driver.ensure_research_in_body and Driver.deploy_env_check -- each tested on its own: a small seam the stage
    orchestrators call, unit-testable without the whole stage. Behavior is unchanged (the stage methods keep their
    branching); these cases pin the extracted units' contracts so the split is provably only a split."""

    run_recorder = DriverShGroupKill.run_recorder

    def _driver(self, h, repo="cmdemo1-system", issue=859):
        d = make_driver(repo=repo, issue=issue, dry_run=False)
        wt = os.path.join(h, "wt"); os.makedirs(wt, exist_ok=True)
        d.s.update(plan=dict(PLAN, criteria=[dict(PLAN["criteria"][0])]), wt=wt, gpu="pro5000", pr=7, stage="review")
        return d

    # -- Driver.evidence_results: the per-criterion evidence pass, ev/failed and the log file
    def test_evidence_results_splits_passed_and_failed_and_writes_the_log(self):
        out = "line one\nPassed!  - failed: 0, passed: 3\n"
        with fake_home() as h:
            d = self._driver(h)
            run = self.run_recorder([(0, out)])
            with patch_run(run):
                ev, failed = d.evidence_results()
            self.assertEqual(len(run.calls), 1, "one criterion, one evidence run")
            self.assertEqual(len(ev), 1, "a passing criterion lands in ev")
            self.assertEqual(failed, [], "a passing criterion leaves failed empty")
            c, last, rc = ev[0]
            self.assertEqual(c["text"], PLAN["criteria"][0]["text"])
            self.assertEqual(rc, 0)
            self.assertEqual(last, "Passed!  - failed: 0, passed: 3")
            log_text = open(os.path.join(d.run_dir, "logs", "evidence-1.log")).read()
            self.assertEqual(log_text, out, "logs/evidence-<i>.log keeps the same (scrubbed) content")

    def test_evidence_results_a_failed_criterion_lands_in_failed_with_its_exit(self):
        with fake_home() as h:
            d = self._driver(h)
            run = self.run_recorder([(7, "boom\n")])
            with patch_run(run):
                ev, failed = d.evidence_results()
            self.assertEqual(ev, [], "a failing criterion does not land in ev")
            self.assertEqual(len(failed), 1, "a failing criterion lands in failed")
            c, last, rc = failed[0]
            self.assertEqual(rc, 7, "the returncode is carried for st_review's FAIL comment")
            self.assertEqual(last, "boom", "the last non-empty line is the one st_review shows")

    # -- Driver.ensure_research_in_body: the research-redo mechanics after an independent-review FAIL
    def test_ensure_research_in_body_runs_st_research_when_the_section_is_missing(self):
        with fake_modules({(L, "research_ok"): lambda *a: False}) :
            with fake_home() as h:
                d = self._driver(h)
                saw_stage = []
                d.st_research = lambda: saw_stage.append(d.s.get("stage")) or d.save(stage="review")
                self.assertTrue(d.ensure_research_in_body(d.s["plan"]), "a research redo that does not block returns True")
                self.assertIn("research", saw_stage, "st_research ran (the stage was set to research before the redo)")
                self.assertEqual(d.s.get("stage"), "review", "the stage is set back to review")
                self.assertEqual(d.s["counts"]["research"], 0, "the research count resets before the redo")

    def test_ensure_research_in_body_skips_the_redo_when_the_section_is_there(self):
        with fake_modules({(L, "research_ok"): lambda *a: True}):
            with fake_home() as h:
                d = self._driver(h)
                d.st_research = lambda: self.fail("a substantive section does not re-run st_research")
                self.assertTrue(d.ensure_research_in_body(d.s["plan"]), "a present section returns True without redoing")

    def test_ensure_research_in_body_returns_false_when_the_redo_blocks(self):
        with fake_modules({(L, "research_ok"): lambda *a: False}):
            with fake_home() as h:
                d = self._driver(h)
                d.st_research = lambda: d.save(stage="blocked")
                self.assertFalse(d.ensure_research_in_body(d.s["plan"]),
                                 "a research redo that blocks the item returns False so st_review leaves")

    # -- Driver.deploy_env_check: one environment's half of the st_deploy watch
    def test_deploy_env_check_none_when_the_env_has_no_entry_for_the_dep(self):
        with fake_home() as h:
            d = self._driver(h, repo="cmdemo1-system")
            env = {"name": "tdd", "deployables": []}
            self.assertIsNone(d.deploy_env_check(env, "system", "abc"),
                              "no entry for the deployable -> None so the watch skips the env")

    def test_deploy_env_check_healthy_identical_returns_in_env_and_version(self):
        with fake_home() as h:
            d = self._driver(h, repo="cmdemo1-system")
            d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, '{"status": "identical"}', "")
            env = {"name": "tdd", "deployables": [{"name": "system", "version": "v1", "commit": "c" * 8}]}
            in_env, (version, commit) = d.deploy_env_check(env, "system", "abc")
            self.assertTrue(in_env, "identical + healthy -> in_env True (system has no HTTP health, so it is never red)")
            self.assertEqual((version, commit), ("v1", "c" * 8))

    def test_deploy_env_check_behind_is_not_in_env(self):
        with fake_home() as h:
            d = self._driver(h, repo="cmdemo1-system")
            d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, '{"status": "behind"}', "")
            env = {"name": "tdd", "deployables": [{"name": "system", "version": "v1", "commit": "c" * 8}]}
            in_env, _ = d.deploy_env_check(env, "system", "abc")
            self.assertFalse(in_env, "a behind commit is not in_env even when healthy")

    def test_deploy_env_check_unhealthy_at_the_merge_sets_the_red_flag(self):
        with fake_home() as h:
            d = self._driver(h, repo="cmdemo1-workorders")
            d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, '{"status": "identical"}', "")
            d.fix_forward_issue = lambda *a, **k: None
            comments = []; d.comment = lambda body, **k: comments.append(body)
            env = {"name": "tdd", "deployables": [{"name": "ui", "version": "v9", "commit": "c" * 8}],
                   "health": {"containerApps": [{"name": "ui", "last": {"result": "unhealthy"}}]}}
            in_env, _ = d.deploy_env_check(env, "ui", "abc")
            self.assertFalse(in_env, "an unhealthy env at the merge commit is not in_env")
            self.assertIn("ui tdd", red_keys_of(h), "the red flag is set for the dep+env key")
            self.assertEqual(len(comments), 1, "one status comment when the flag is set")


def red_keys_of(h):
    """The keys currently in <h>/factory-runs/red.json ({} when the file is absent)."""
    try:
        return set(json.load(open(os.path.join(h, "factory-runs", "red.json"))))
    except (OSError, ValueError):
        return set()


class DeployNoHealthEntry(unittest.TestCase):
    """cmdemo1-system#847: a deployable that has NO containerApps health entry still advances the board once its
    deploy has passed (the auto-promote reason says 'deployment and health ok'), instead of sitting in the driver's
    deploy stage for its full 48-hour window. delivery.json for tdd/uat/prod lists only `ui` under containerApps, so
    for dep == 'dashboard' dep_health is None and env_red is False -- the board must move Merged -> TDD -> UAT -> Done.
    A deployable that HAS an entry reading unhealthy still does not advance."""

    def _driver(self, h, repo="cmdemo1-dashboard", issue=847):
        d = make_driver(repo=repo, issue=issue, dry_run=False)
        d.s.update(merge_sha="m" * 40, column="Merged")
        return d

    def _delivery(self, envs):
        return {"environments": envs}

    def test_deploy_env_check_no_health_entry_is_in_env_when_identical(self):
        with fake_home() as h:
            d = self._driver(h)
            d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, '{"status": "identical"}', "")
            # deployable present, but NO health key at all -> dep_health is None -> not red -> healthy
            env = {"name": "tdd", "deployables": [{"name": "dashboard", "version": "v533", "commit": "c" * 8}]}
            in_env, (version, commit) = d.deploy_env_check(env, "dashboard", "m" * 40)
            self.assertTrue(in_env, "no health entry + identical deploy -> in_env True (#847)")
            self.assertEqual((version, commit), ("v533", "c" * 8))

    def test_deploy_env_check_unhealthy_entry_still_not_in_env(self):
        with fake_home() as h:
            d = self._driver(h)
            d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, '{"status": "identical"}', "")
            d.fix_forward_issue = lambda *a, **k: None
            d.comment = lambda body, **k: None
            env = {"name": "tdd",
                   "deployables": [{"name": "dashboard", "version": "v533", "commit": "c" * 8}],
                   "health": {"containerApps": [{"name": "dashboard", "last": {"result": "unhealthy"}}]}}
            in_env, _ = d.deploy_env_check(env, "dashboard", "m" * 40)
            self.assertFalse(in_env, "a health entry reading unhealthy still does not advance")
            self.assertIn("dashboard tdd", red_keys_of(h), "the red flag is set for the unhealthy dep+env")

    def test_st_deploy_moves_dashboard_merged_through_tdd_uat_to_done_with_no_health_entry(self):
        """The acceptance fixture: delivery.json with dashboard deployables in tdd/uat/prod and no containerApps
        health entry for dashboard. The item moves Merged -> TDD -> UAT -> Done and the stage ends done."""
        with fake_home() as h:
            d = self._driver(h)
            d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, '{"status": "identical"}', "")
            envs = [{"name": n, "deployables": [{"name": "dashboard", "version": "v1.0.428",
                                                 "commit": "d" * 8}]}
                    for n in ("tdd", "uat", "prod")]
            delivery = self._delivery(envs)
            moves_seen = []
            comments = []
            saved = []
            d.move = lambda col: moves_seen.append(col) or d.s.update(column=col)
            d.comment = lambda body, **k: comments.append(body)
            d.heartbeat = lambda: None
            d.save = lambda **k: saved.append(k) or {"stage": k.get("stage")}
            class _Resp:
                def read(self): return json.dumps(delivery).encode()
            with fake_modules({(L.urllib.request, "urlopen"): lambda *a, **k: _Resp(),
                               (L.time, "sleep"): lambda s: None,
                               (L.time, "time"): lambda: 1e9}):   # fixed clock: the loop runs once, then Done
                d.st_deploy(max_h=48)
            self.assertEqual(moves_seen, ["Done"], "one move lands the item straight in Done")
            self.assertTrue(any("Merged → TDD → UAT → Done" in c for c in comments),
                            "the board path shows Merged -> TDD -> UAT -> Done")
            self.assertTrue(any(k.get("stage") == "done" for k in saved), "the stage ends done")


class TestHandoffBudgets(unittest.TestCase):
    """The HandoffBudgets value object (cmdemo1-system#954): the nine hand-off durations and the gh-retry knobs as
    one timedelta-based object whose invariants are asserted on construction, whose .describe() owns the no-start
    message and whose .slot_wait() owns the first-attempt-vs-relaunch rule. The shared module instance must match
    every existing named constant, so every value sent to run-task and every message string is unchanged."""

    def test_shared_instance_matches_every_named_constant(self):
        b = L.HANDOFF_BUDGETS
        self.assertEqual(b.start_s, L.HANDOFF_START_S)
        self.assertEqual(b.stall_s, L.HANDOFF_STALL_S)
        self.assertEqual(b.slot_wait_s, L.HANDOFF_SLOT_WAIT_S)
        self.assertEqual(b.any_slot_wait_s, L.ANY_SLOT_WAIT_S)
        self.assertEqual(b.draft_plan_s, L.DRAFT_PLAN_TIMEOUT_S)
        self.assertEqual(b.research_s, L.RESEARCH_TIMEOUT_S)
        self.assertEqual(b.task_timeout_s, L.PI_TASK_TIMEOUT_S)
        self.assertEqual(b.gpu_wait_s, L.GPU_WAIT_S)
        self.assertEqual(b.gpu_wait_h, L.GPU_WAIT_H)

    def test_slot_wait_rule(self):
        b = L.HANDOFF_BUDGETS
        self.assertEqual(b.slot_wait(False, 0), L.HANDOFF_SLOT_WAIT_S)   # first attempt: its own GPU slot
        self.assertEqual(b.slot_wait(False, 1), L.ANY_SLOT_WAIT_S)      # a relaunch: any free GPU
        self.assertEqual(b.slot_wait(True, 0), L.ANY_SLOT_WAIT_S)       # a review: any free GPU

    def test_describe_produces_the_pi_not_started_text(self):
        b = L.HANDOFF_BUDGETS
        text = b.describe("t1", "no-start")
        self.assertEqual(text,
                         f"Pi hand-off `t1` did not start or stalled (no-start: no GPU slot, no model "
                         f"output within {L.HANDOFF_START_S // 60} min of getting one, "
                         f"or no activity for {L.HANDOFF_STALL_S // 60} min) "
                         f"after {L.LIMITS['pi_relaunch']} relaunches on any free GPU.")

    def test_stall_must_exceed_start(self):
        with self.assertRaises(ValueError):
            L.HandoffBudgets(start=1800, stall=900)   # stall budget not greater than start budget

    def test_task_timeout_must_outlast_start(self):
        with self.assertRaises(ValueError):
            L.HandoffBudgets(start=1800, stall=3600, task_timeout=900)   # task timeout not greater than start

    def test_any_slot_wait_must_exceed_start(self):
        with self.assertRaises(ValueError):
            L.HandoffBudgets(start=900, stall=1800, any_slot_wait=600)   # any-slot wait not greater than start

    def test_negative_clock_rejected(self):
        for kw in ({"start": -1}, {"stall": 0}, {"gpu_wait": 0}, {"gpu_wait_h": 0}, {"draft_plan": -5}):
            with self.assertRaises(ValueError, msg=kw):
                L.HandoffBudgets(**kw)

    def test_default_construction_is_the_production_budget(self):
        b = L.HandoffBudgets()   # the defaults are the module constants
        self.assertEqual(b.start_s, L.HANDOFF_START_S)
        self.assertGreater(b.stall_s, b.start_s)
        self.assertGreater(b.task_timeout_s, b.start_s)
        self.assertGreater(b.any_slot_wait_s, b.start_s)


class TestTimeouts(unittest.TestCase):   # cmdemo1-system#966: the TIMEOUTS table names every command timeout in one place
    def test_table_values(self):
        self.assertEqual(L.TIMEOUTS["verify"], 3600)
        self.assertEqual(L.TIMEOUTS["evidence"], 3600)
        self.assertEqual(L.TIMEOUTS["git"], 600)
        self.assertEqual(L.TIMEOUTS["gh_watch"], 6 * 3600)
        self.assertEqual(L.TIMEOUTS["wait_ci"], 600)
        self.assertEqual(L.TIMEOUTS["api"], G.MIN_CLIENT_TIMEOUT_S)

    def test_keys_are_exactly_the_six_command_kinds(self):
        self.assertEqual(set(L.TIMEOUTS), {"verify", "evidence", "git", "gh_watch", "wait_ci", "api"})


class ItemTest(unittest.TestCase):   # cmdemo1-system#869: the Item NamedTuple value object
    def test_full_and_key(self):
        self.assertEqual(L.Item("r", 5).full, f"{L.ORG}/r")
        self.assertEqual(L.Item("r", 5).key, "r-5")

    def test_tuple_equality_both_orders(self):
        self.assertEqual(L.Item("r", 5), ("r", 5))
        self.assertEqual(("r", 5), L.Item("r", 5))

    def test_hash_equals_tuple_hash(self):
        self.assertEqual(hash(L.Item("r", 5)), hash(("r", 5)))

    def test_not_equal_to_3_tuple_or_string(self):
        self.assertNotEqual(L.Item("r", 5), ("r", 5, 0))
        self.assertNotEqual(L.Item("r", 5), "r-5")

    def test_immutability(self):
        it = L.Item("r", 5)
        with self.assertRaises(AttributeError):
            it.repo = "x"

    def test_never_merge_and_hands_off_members_are_items(self):
        for m in L.NEVER_MERGE:
            self.assertIsInstance(m, L.Item)
        for m in L.HANDS_OFF:
            self.assertIsInstance(m, L.Item)

    def test_unpacking(self):
        repo, issue = L.Item("r", 5)
        self.assertEqual(repo, "r")
        self.assertEqual(issue, 5)

    def test_malformed_plan_returns_list_not_raises(self):
        # "issue": "abc" — validate_plan must return a list (no exception)
        errs = L.validate_plan({"repo": "cmdemo1-system", "issue": "abc"})
        self.assertIsInstance(errs, list)
        # "issue": [1] and "issue": {} — the old code also raised TypeError (unhashable in set
        # membership), so the new code must raise the same exception type, not something else.
        for bad in ([1], {}):
            with self.assertRaises(TypeError):
                L.validate_plan({"repo": "cmdemo1-system", "issue": bad})


class ConflictingPrMerge(unittest.TestCase):   # cmdemo1-system#921: a CONFLICTING PR is unblocked by merging the default branch, not a 4 h wait
    def driver(self):
        d = make_driver(issue=921, repo="cmdemo1-system")
        d.s.update(plan=dict(PLAN, branch="cm-ai-ops-bot/921-x"), default="main", pr=920, wt=tempfile.mkdtemp(),
                   stage="ci", counts=L.fresh_counts())
        return d

    def test_pr_mergeable_reads_the_mergeable_field_not_mergeable_state(self):
        d = self.driver(); argv = []
        d.gh = lambda *a, **k: (argv.append(list(a)), L.subprocess.CompletedProcess(a, 0, "CONFLICTING\n", ""))[-1]
        self.assertEqual(d.pr_mergeable(), "CONFLICTING")
        for token in ("--json", "mergeable", "-q", ".mergeable"): self.assertIn(token, argv[0])
        self.assertNotIn("mergeableState", argv[0])
        d.gh = lambda *a, **k: L.subprocess.CompletedProcess(a, 0, "\n", "")
        self.assertEqual(d.pr_mergeable(), "UNKNOWN")

    def test_clean_merge_fetches_merges_and_pushes_in_order_as_bot(self):
        d = self.driver(); d.pr_mergeable = lambda: "CONFLICTING"
        d.sh = scripted_sh({"fetch": "", "merge --no-edit": "", "push": "", "rev-parse": "deadbeef"})
        self.assertEqual(d.merge_default_if_conflicting(), "pushed")
        calls = d.sh.calls
        i_fetch = next(i for i, c in enumerate(calls) if c[:2] == ["git", "fetch"])
        i_merge = next(i for i, c in enumerate(calls) if "merge" in c and "--no-edit" in c)
        i_push = next(i for i, c in enumerate(calls) if c[:2] == ["git", "push"])
        self.assertLess(i_fetch, i_merge); self.assertLess(i_merge, i_push)
        self.assertIn("origin/main", calls[i_merge])
        self.assertIn(L.BOT_GIT[1], calls[i_merge])   # -c user.name=cm-ai-ops-bot

    def test_failed_merge_is_aborted_not_pushed_and_blocks(self):
        d = self.driver(); d.pr_mergeable = lambda: "CONFLICTING"
        d.sh = scripted_sh({"fetch": "", "merge --no-edit": (1, "CONFLICT (content): Merge conflict in a.py")})
        d.comment = lambda *a, **k: None; d.wake_bot = lambda *a, **k: None
        self.assertEqual(d.merge_default_if_conflicting(), "blocked")
        self.assertTrue(any(c[:2] == ["git", "merge"] and "--abort" in c for c in d.sh.calls))
        self.assertFalse(any(c[:2] == ["git", "push"] for c in d.sh.calls))
        self.assertEqual(d.s["stage"], "blocked")
        self.assertIn("resolve", d.s["blocker"])

    def test_limit_exhausted_blocks_without_merging_or_pushing(self):
        d = self.driver(); d.pr_mergeable = lambda: "CONFLICTING"
        d.s["counts"]["conflict_merge"] = L.LIMITS["conflict_merge"]
        d.sh = scripted_sh({})
        d.comment = lambda *a, **k: None; d.wake_bot = lambda *a, **k: None
        self.assertEqual(d.merge_default_if_conflicting(), "blocked")
        self.assertFalse(any("merge" in c for c in d.sh.calls))
        self.assertFalse(any(c[:2] == ["git", "push"] for c in d.sh.calls))
        self.assertEqual(d.s["stage"], "blocked")

    def test_mergeable_and_unknown_make_no_git_calls(self):
        for m in ("MERGEABLE", "UNKNOWN"):
            d = self.driver(); d.pr_mergeable = lambda m=m: m
            d.sh = scripted_sh({})
            self.assertEqual(d.merge_default_if_conflicting(), "none")
            self.assertEqual(d.sh.calls, [])

    def test_wait_ci_stops_on_conflict_blocker_and_st_ci_posts_one_blocker(self):
        class T:
            t = 1e9
            def time(self): return self.t
            def sleep(self, s): self.t += s
        # wait_ci alone: budget spent, so the conflict detection blocks and the loop leaves after one iteration
        d = self.driver(); d.s["counts"]["conflict_merge"] = L.LIMITS["conflict_merge"]
        d.pr_mergeable = lambda: "CONFLICTING"; d.pr_checks = lambda: (L.CheckState.PENDING, [])
        d.comment = lambda *a, **k: None; d.wake_bot = lambda *a, **k: None
        with fake_modules({(L, "time"): T()}):
            self.assertEqual(d.wait_ci(), (L.CheckState.PENDING, []))
        # st_ci: its own wait_ci posts the conflict Blocker, then st_ci bails on the blocked stage -- one blocker, never the 4 h one
        d2 = self.driver(); d2.s["counts"]["conflict_merge"] = L.LIMITS["conflict_merge"]
        d2.pr_mergeable = lambda: "CONFLICTING"; d2.pr_checks = lambda: (L.CheckState.PENDING, [])
        posted = []; d2.comment = lambda body, **k: posted.append(body); d2.wake_bot = lambda *a, **k: None
        with fake_modules({(L, "time"): T()}):
            d2.st_ci()
        self.assertEqual(d2.s["stage"], "blocked")
        self.assertEqual(len([b for b in posted if b.startswith("Blocker:")]), 1, "exactly one Blocker, not the 4 h one on top")
        self.assertFalse(any("4 hours" in b for b in posted), "the 4 h Blocker must not post on top of the conflict one")


class CallSiteTimeouts(unittest.TestCase):   # cmdemo1-system#968: git, gh and pi --version get bounded budgets at the call sites
    """Driver.sh's contract is unchanged (None stays None, TimeoutExpired still raises); the budgets come from the
    callers: the Driver's GitRepo builders (TIMEOUTS["git"]), the gh call sites / gh() api policy (TIMEOUTS["api"]),
    and run()'s single pi --version probe (TIMEOUTS["api"], a timeout records pi_version "unknown")."""

    def test_pi_version_timeout_through_run_records_unknown_and_the_next_stage_runs(self):
        version_calls, ran = [], []
        with fake_modules({(L, "watchdog_exit"): lambda drv: None}):
            with fake_home():
                d = make_driver(repo="cmdemo1-system", issue=968)
                with open(os.path.join(d.run_dir, "plan.json"), "w") as f: json.dump(PLAN, f)
                def sh(cmd, **k):
                    if list(getattr(cmd, "argv", cmd)) == ["pi", "--version"]:
                        version_calls.append(k)
                        raise subprocess.TimeoutExpired(cmd, k.get("timeout"))
                    return subprocess.CompletedProcess(cmd, 0, "", "")
                d.sh = sh
                def st_research(): ran.append("research"); d.save(stage="done")
                d.st_research = st_research
                d.wake_bot = d.comment = lambda *a, **k: None
                d.s["stage"] = "research"
                d.run()
                with open(os.path.join(d.run_dir, "run.json")) as f: meta = json.load(f)
        self.assertEqual(ran, ["research"], "(a) the stage after the probe ran")
        self.assertEqual(meta["pi_version"], "unknown", "(b) the saved run metadata records pi_version unknown")
        self.assertEqual(len(version_calls), 1, "(c) pi --version is probed exactly once")
        self.assertEqual(version_calls[0].get("timeout"), L.TIMEOUTS["api"], "(c) with the api budget")
        self.assertIs(version_calls[0].get("check"), False, "(c) and check=False")

    def test_git_call_with_no_caller_timeout_reaches_the_runner_with_the_git_budget(self):
        with fake_home() as h:
            d = make_driver(repo="cmdemo1-system", issue=968, dry_run=False)
            run = fakes.gh_recorder()
            with patch_run(run[0]):
                d.git.fetch()                                   # the item work tree's GitRepo
                d.clone_git(os.path.join(h, "clone")).run("worktree", "prune")   # the shared clone's GitRepo
            calls = run[1]
        self.assertEqual([list(c) for c, _ in calls], [["git", "fetch", "-q", "origin"], ["git", "worktree", "prune"]])
        self.assertEqual([k.get("timeout") for _, k in calls], [L.TIMEOUTS["git"], L.TIMEOUTS["git"]])

    def test_git_call_keeps_an_explicit_caller_timeout(self):
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=968)
            sh, calls = fakes.gh_recorder(); d.sh = sh
            d.git.run("status", timeout=7)
        self.assertEqual(calls[0][1].get("timeout"), 7)

    def test_setup_worktree_git_calls_all_carry_the_git_budget(self):
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=968)
            d.s["plan"] = PLAN
            sh, calls = fakes.gh_recorder(); d.sh = sh
            d.setup_worktree()
        git = [k.get("timeout") for c, k in calls if list(getattr(c, "argv", c))[0] == "git"]
        gh = [(list(c.argv)[1:3], k.get("timeout")) for c, k in calls if isinstance(c, L.Command)]
        self.assertGreaterEqual(len(git), 4)
        self.assertEqual(set(git), {L.TIMEOUTS["git"]})
        self.assertEqual(gh, [(["repo", "clone"], L.TIMEOUTS["git"]), (["repo", "view"], L.TIMEOUTS["api"])])

    def test_gh_api_call_with_no_caller_timeout_reaches_the_runner_with_the_api_budget(self):
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=968, dry_run=False)
            run = fakes.gh_recorder()
            with fake_modules({(L, "app_token"): lambda *a, **k: None}):
                with patch_run(run[0]):
                    d.gh("api", "repos/o/r/issues/1", "--jq", ".title", check=False)
                    d.ensure_issue("t", "b", "enhancement")      # its list + create pass no timeout themselves
            calls = run[1]
        self.assertEqual([list(c)[1:3] for c, _ in calls], [["api", "repos/o/r/issues/1"], ["api", calls[1][0][2]],
                                                           ["issue", "create"]])
        self.assertEqual([k.get("timeout") for _, k in calls], [L.TIMEOUTS["api"]] * 3)

    def test_usage_report_gets_the_api_budget(self):
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=968)
            sh, calls = fakes.gh_recorder(); d.sh = sh
            d.usage()
        self.assertEqual(calls[0][1].get("timeout"), L.TIMEOUTS["api"])

    def test_pr_checks_watch_keeps_its_wait_ci_slice_and_its_timeout_is_still_caught(self):
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=968)
            d.s["pr"] = 7
            states = iter([(L.CheckState.PENDING, [{"name": "build"}]), (L.CheckState.GREEN, [{"name": "build"}])])
            d.pr_checks = lambda: next(states)
            d.heartbeat = lambda *a, **k: None
            seen = []
            def gh(*a, **k):
                seen.append((a, k)); raise subprocess.TimeoutExpired(["gh", *a], k.get("timeout"))
            d.gh = gh
            with mock.patch.object(L.time, "sleep", lambda s: None):
                state, _ = d.wait_ci()
        self.assertEqual(state, L.CheckState.GREEN, "the TimeoutExpired of a watch slice is caught and the loop goes on")
        self.assertEqual(len(seen), 1)
        self.assertIn("--watch", seen[0][0])
        self.assertEqual(seen[0][1].get("timeout"), L.TIMEOUTS["wait_ci"])

    def test_sh_and_gh_defaults_stay_none(self):
        """The contract the pinned DriverShGroupKill / GhChokepoint tests hold: neither sh nor a non-api gh call
        invents a timeout."""
        self.assertIsNone(inspect.signature(L.Driver.sh).parameters["timeout"].default)
        self.assertIsNone(inspect.signature(L.Driver.gh).parameters["timeout"].default)
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=968)
            sh, calls = fakes.gh_recorder(); d.sh = sh
            d.gh("pr", "list")
        self.assertIsNone(calls[0][1].get("timeout"))


if __name__ == "__main__": unittest.main()
