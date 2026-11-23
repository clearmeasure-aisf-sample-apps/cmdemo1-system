"""Unit tests of the Pi item driver's decision rules (no network, no Pi). Run: python3 -m unittest factory/pi/test_item_loop.py"""
import fcntl, importlib.machinery, importlib.util, json, os, signal, subprocess, sys, tempfile, time, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_loop as L
import gpu as G

PLAN = {"repo": "cmdemo1-workorders", "issue": 1, "branch": "cm-ai-ops-bot/1-x", "files": ["src/A.cs"],
        "criteria": [{"text": "A works", "evidence_cmd": "dotnet test --filter A"}],
        "tasks": [{"name": "t1", "prompt": "Write test A"}], "verify_cmd": "dotnet build", "pr_title": "A"}

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

    def test_review_fail_blocker_does_not_resume_on_green_checks(self):
        self.assertFalse(L.hold_resumes("Review FAIL twice: A works (exit 1)"))
        self.assertFalse(L.hold_resumes("independent review FAIL twice: - finding"))
        self.assertTrue(L.hold_resumes("required checks still red after 3 Pi fix passes."))
        self.assertTrue(L.hold_resumes("Qodana did not finish within 60 minutes."))
        self.assertTrue(L.hold_resumes(None))
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 9, dry_run=True); d.dry = False
                d.s.update(pr=5, resume_stage="review", blocker="independent review FAIL twice: - x")
                d.pr_checks = lambda: self.fail("a Review FAIL blocker must not wait on checks")
                self.assertFalse(d.hold_blocked())
            finally: L.HOME = old

class ReviewInfraRetry(unittest.TestCase):   # t83u: no / empty findings or no verdict = retry the review, never a FAIL
    def test_review_verdict_classifies_infra_failures(self):
        self.assertIsNone(L.review_verdict("exit 1", None)[0])         # #1944: no findings file
        self.assertIsNone(L.review_verdict("FAIL", " \n\t")[0])       # whitespace only
        self.assertIsNone(L.review_verdict("timeout", "- partial")[0])  # #820: timed out, no verdict
        self.assertEqual(L.review_verdict("PASS", "- No findings."), (True, "- No findings."))
        self.assertEqual(L.review_verdict("FAIL", "- bug"), (False, "- bug"))
        self.assertFalse(L.hold_resumes("independent review infra failed 3 times (x)"))

    def driver(self, h, verdicts):
        d = L.Driver("cmdemo1-workorders", 31, dry_run=True)
        plan = dict(PLAN, criteria=[{"text": "A works", "evidence_cmd": "true"}])
        d.s.update(plan=plan, wt=tempfile.mkdtemp(dir=h), gpu="pro5000", pr=7, stage="review")
        d.independent_review = lambda: verdicts.pop(0)
        d.pi = lambda *a, **k: self.fail("review infra findings must never reach Pi")
        d.blocker = lambda what: d.save(stage="blocked", blocker=what)
        d.comment = d.move = lambda *a, **k: None
        return d

    def test_infra_failure_is_retried_then_passes(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = self.driver(h, [(None, "no findings file"), (None, "empty"), (True, "- No findings.")])
                d.st_review()
                self.assertEqual(d.s["stage"], "merge")
                self.assertEqual((d.s["counts"]["review_fail"], d.s["counts"]["review_infra"]), (0, 0))
            finally: L.HOME = old

    def test_infra_failure_blocks_after_two_retries_without_a_fail(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = self.driver(h, [(None, "no findings file")] * 3)
                d.st_review()
                self.assertEqual(d.s["stage"], "blocked")
                self.assertTrue(d.s["blocker"].startswith("independent review infra failed 3 times"))
                self.assertIn("not a code FAIL", d.s["blocker"])
                self.assertEqual(d.s["counts"]["review_fail"], 0)
            finally: L.HOME = old

    def test_review_runs_on_any_free_non_author_gpu_and_missing_file_is_infra(self):
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.research_ok, L.gpu_health); L.HOME = h
            try:
                L.research_ok = lambda *a: True; L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
                d = L.Driver("cmdemo1-workorders", 32, dry_run=True)
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
            finally: L.HOME, L.research_ok, L.gpu_health = old

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
            rc, _ = rt.run_pi(["bash", "-c", f"echo '{HDR}' > {f}; echo '{ASSISTANT}' >> {f}; sleep 60"], cwd=tmp, timeout=30,
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
        d = L.Driver("cmdemo1-workorders", 41, dry_run=True); d.s.update(gpu="ts3", size=size, wt=tempfile.mkdtemp(dir=h)); calls = []
        def sh(cmd, **k):
            calls.append(list(cmd)); res = results.pop(0)
            res, g = res if isinstance(res, tuple) else (res, cmd[cmd.index("--gpu") + 1].split(",")[0])
            return subprocess.CompletedProcess(cmd, 0 if res == "PASS" else 1,
                                               json.dumps({"task": cmd[cmd.index("--task") + 1], "gpu": g, "result": res}), "")
        d.sh = sh; return d, calls

    def test_handoff_relaunched_on_any_free_gpu_then_passes(self):
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.gpu_health); L.HOME = h; L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
            try:
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
            finally: L.HOME, L.gpu_health = old

    def test_large_item_relaunch_keeps_its_size_routing(self):   # review major 2, related minor
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "obs", "pro5000"]), ["pro5000"])
        self.assertEqual(L.relaunch_gpus(None, ["ts3", "obs", "pro5000"]), ["pro5000"])
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "obs"]), ["obs", "ts3"])   # pro5000 down: as pick_gpu
        self.assertEqual(L.relaunch_gpus("small", ["ts3", "pro5000"]), ["pro5000", "ts3"])
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "pro6000", "pro5000"]), ["pro5000", "pro6000"])   # either 262K GPU
        self.assertEqual(L.relaunch_gpus("large", ["ts3", "pro6000"]), ["pro6000"])
        self.assertEqual(L.relaunch_gpus("small", ["ts3", "obs", "pro6000", "pro5000"]), ["pro5000", "pro6000", "obs", "ts3"])
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.gpu_health); L.HOME = h; L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
            try:
                d, calls = self.driver(h, ["stalled", "PASS"], size="large")
                self.assertTrue(d.pi("t1", "do it"))
                self.assertEqual(calls[1][calls[1].index("--gpu") + 1], "pro5000,pro6000")   # a 262K GPU only
            finally: L.HOME, L.gpu_health = old

    def test_review_excludes_every_authoring_gpu_including_relaunch_gpus(self):   # review major 2
        self.assertEqual(G.reviewer_gpus(["ts3", "obs"], list(G.GPUS)), ["pro5000", "pro6000"])
        self.assertEqual(G.reviewer_gpus("ts3", list(G.GPUS)), ["pro5000", "pro6000", "obs"])
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.gpu_health, L.research_ok); L.HOME = h
            L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}; L.research_ok = lambda *a: True
            try:
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
            finally: L.HOME, L.gpu_health, L.research_ok = old

    def test_no_slot_record_is_not_an_author_gpu(self):
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.gpu_health); L.HOME = h; L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
            try:
                d, _ = self.driver(h, [("no-start", "pro5000,obs,ts3"), "PASS"])
                self.assertTrue(d.pi("t1", "do it")); self.assertEqual(d.s.get("author_gpus"), ["pro5000"])
            finally: L.HOME, L.gpu_health = old

    def test_read_only_calls_and_no_start_are_not_author_gpus(self):   # re-review major A / minor D
        self.assertFalse(L.writes_code("draft-plan")); self.assertFalse(L.writes_code("refactoring-research-1"))
        self.assertFalse(L.writes_code("independent-review-2")); self.assertTrue(L.writes_code("review-fix-1"))
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.gpu_health); L.HOME = h; L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
            try:
                d, _ = self.driver(h, [("PASS", "pro5000")])   # item on ts3; plan drafted on pro5000
                self.assertTrue(d.pi("draft-plan", "plan it", gpu="pro5000"))
                d2, _ = self.driver(h, [("PASS", "pro5000")]); d2.pi("refactoring-research-1", "research")
                self.assertNotIn("pro5000", d.author_gpus()); self.assertNotIn("pro5000", d2.author_gpus())
                self.assertIn("pro5000", G.reviewer_gpus(d.author_gpus(), list(G.GPUS)), "pro5000 stays a reviewer")
                d3, _ = self.driver(h, [("no-start", "obs"), ("PASS", "ts3")])   # got a slot on obs but never replied
                self.assertTrue(d3.pi("t1", "do it")); self.assertNotIn("obs", d3.author_gpus())
            finally: L.HOME, L.gpu_health = old

    def test_hold_mid_pass_stops_push_and_merge(self):   # re-review minor B
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 1946, dry_run=True)
                d.sh = lambda cmd, **k: self.fail("a held item must not run git or gh")
                d.gh = lambda *a, **k: self.fail("a held item must not call GitHub")
                self.hold(h, 1946)
                with self.assertRaises(L.PiHeld): d.commit_push("msg")
                with self.assertRaises(L.PiHeld): d.st_merge()
            finally: L.HOME = old

    def hold(self, h, issue, text="handed-off: FactoryBot1"):
        open(os.path.join(h, "factory-runs", f"cmdemo1-workorders-{issue}", "HOLD"), "w").write(text)

    def test_hold_stops_a_live_driver_at_the_next_stage_pass(self):   # review major 3
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.watchdog_exit); L.HOME = h; L.watchdog_exit = lambda drv: None
            try:
                d = L.Driver("cmdemo1-workorders", 1944, dry_run=True)
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
            finally: L.HOME, L.watchdog_exit = old

    def test_hold_stops_a_blocked_driver_inside_hold_blocked(self):   # review major 3
        class T:
            def __init__(self): self.t = 1e9
            def time(self): return self.t
            def sleep(self, s): self.t += s
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.time); L.HOME = h; L.time = T()
            try:
                d = L.Driver("cmdemo1-workorders", 1945, dry_run=True); d.dry = False
                d.s.update(pr=5, resume_stage="review", blocker="required checks still red after 3 Pi fix passes.")
                checks = []
                def pr_checks():   # red on the first re-check; the item is handed off before the next one turns green
                    checks.append(1); self.hold(h, 1945)
                    return "FAIL", [{"name": "build", "bucket": "fail"}]
                d.pr_checks = pr_checks; d.heartbeat = lambda *a: None
                d.comment = d.wake_bot = lambda *a, **k: self.fail("a held item is never touched")
                self.assertFalse(d.hold_blocked(), "a held driver never clears its Blocker or resumes")
                self.assertEqual(len(checks), 1); self.assertEqual(d.s["status"], "held"); self.assertIn("blocker", d.s)
            finally: L.HOME, L.time = old

    def test_handoff_blocks_after_two_relaunches_and_reviews_are_not_relaunched(self):
        with tempfile.TemporaryDirectory() as h:
            old = (L.HOME, L.gpu_health); L.HOME = h; L.gpu_health = lambda *a: {g: ("HEALTHY", "") for g in G.GPUS}
            try:
                d, calls = self.driver(h, ["no-start"] * 3)
                with self.assertRaises(L.PiNotStarted) as e: d.pi("t1", "do it")
                self.assertEqual(len(calls), 3); self.assertFalse(L.hold_resumes(str(e.exception)))
                d, calls = self.driver(h, ["no-start"])
                self.assertFalse(d.pi("independent-review-1", "review", gpu="obs")); self.assertEqual(len(calls), 1)
            finally: L.HOME, L.gpu_health = old

    def test_hold_file_stops_start_run_and_watchdog(self):
        import watchdog as W
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                os.makedirs(os.path.join(h, "factory-runs", "cmdemo1-workorders-1944"))
                self.assertFalse(W.excluded("cmdemo1-workorders", 1944))
                open(os.path.join(h, "factory-runs", "cmdemo1-workorders-1944", "HOLD"), "w").write("handed-off: FactoryBot1")
                self.assertTrue(W.excluded("cmdemo1-workorders", 1944))
                a = L.argparse.Namespace(repo="cmdemo1-workorders", issue=1944, top_session=None, dry_run=False, resume=True)
                for cmd in (L.cmd_start, L.cmd_run):
                    with self.assertRaises(SystemExit) as e: cmd(a)
                    self.assertEqual(e.exception.code, 0)
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
        self.assertEqual(G.env_names("pro6000"), ("LOCAL_LLM_PRO6000_URL", "LOCAL_LLM_PRO6000_TOKEN"))
        self.assertEqual(G.env_names("obs"), ("LOCAL_LLM_OBS_URL", "LOCAL_LLM_OBS_TOKEN"))
        self.assertEqual(G.env_names("ts3"), ("LOCAL_LLM_TS3_URL", "LOCAL_LLM_TS3_TOKEN"))
        self.assertEqual(list(G.GPUS), ["pro5000", "pro6000", "obs", "ts3"]); self.assertEqual(G.MODEL, "auto")
        self.assertEqual({g: G.GPUS[g]["ctx"] for g in G.GPUS}, {"pro5000": 262144, "pro6000": 262144, "obs": 65536, "ts3": 65536})

    def test_hard_caps_pro5000_2_pro6000_1_obs_1_ts3_1(self):   # Jeffrey, 21 + 22 Nov 2026
        self.assertEqual({g: G.GPUS[g]["slots"] for g in G.GPUS}, {"pro5000": 2, "pro6000": 1, "obs": 1, "ts3": 1})
        self.assertEqual([G.GPUS[g]["rank"] for g in G.GPUS], [0, 1, 2, 3])
        self.assertIn("LOCAL_LLM_X9_TOKEN", G.secret_env_names({"LOCAL_LLM_X9_TOKEN": "v"}))

    def test_size_classification(self):
        self.assertEqual(G.classify_size({"files": ["src/UI/Client/Pages/Board.razor", "src/UnitTests/BoardTests.cs"]}), "small")
        self.assertEqual(G.classify_size({"files": ["src/Database/scripts/Update/010.sql"]}), "large")
        self.assertEqual(G.classify_size({"files": [f"src/A{i}/x.cs" for i in range(6)]}), "large")
        self.assertEqual(G.classify_size({"files": ["src/Core/A.cs", "src/UI/B.razor", "src/DataAccess/C.cs"]}), "large")
        self.assertEqual(G.classify_size({"files": ["src/Database/x.sql"], "size": "small"}), "small")

    def test_pick_gpu_pro5000_then_pro6000_then_obs_then_ts3(self):
        up = ["pro5000", "pro6000", "obs", "ts3"]
        self.assertEqual(G.PRIORITY, ("pro5000", "pro6000", "obs", "ts3"))
        for size in ("small", "large"): self.assertEqual(G.pick_gpu(size, up, set()), "pro5000")
        for size in ("small", "large"): self.assertEqual(G.pick_gpu(size, up, {"pro5000"}), "pro6000")   # pro5000 full
        self.assertEqual(G.pick_gpu("small", up, {"pro5000", "pro6000"}), "obs")
        self.assertEqual(G.pick_gpu("small", up, {"pro5000", "pro6000", "obs"}), "ts3")
        self.assertIsNone(G.pick_gpu("large", up, {"pro5000", "pro6000"}))        # long context waits for a 262K GPU
        self.assertEqual(G.pick_gpu("large", ["pro6000", "obs"], set()), "pro6000")   # pro5000 down: pro6000 takes it
        self.assertIsNone(G.pick_gpu("large", ["pro6000", "obs"], {"pro6000"}))
        self.assertIsNone(G.pick_gpu("small", up, {"pro5000", "pro6000", "obs", "ts3"}))

    def test_pick_gpu_without_pro6000_keeps_the_old_order(self):   # pro6000 secrets missing or down
        up = ["pro5000", "obs", "ts3"]
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

    def test_reviewer_gpus_are_every_other_healthy_gpu(self):
        self.assertEqual(G.reviewer_gpus("pro5000", ["pro5000", "obs", "ts3"]), ["obs", "ts3"])
        self.assertEqual(G.reviewer_gpus("pro5000", ["pro5000", "pro6000", "obs", "ts3"]), ["pro6000", "obs", "ts3"])
        self.assertEqual(G.reviewer_gpus(["pro5000", "pro6000"], ["pro5000", "pro6000", "obs"]), ["obs"])
        self.assertEqual(G.reviewer_gpus("pro6000", ["pro5000", "pro6000"]), ["pro5000"])
        self.assertEqual(G.reviewer_gpus("obs", ["pro5000", "obs"]), ["pro5000"])

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
        self.assertEqual({g: st for g, (st, _) in h.items()}, {"pro5000": "HEALTHY", "pro6000": "MISSING_SECRETS", "obs": "UNREACHABLE", "ts3": "MISSING_SECRETS"})
        self.assertEqual(G.available(h), ["pro5000"]); self.assertEqual(G.health_exit(h), 0)
        self.assertEqual(seen, [("https://p.invalid/v1/models", "GET"), ("https://obs.invalid/v1/models", "GET")])  # models list only
        self.assertTrue(all("t1" not in d and "t2" not in d and "invalid" not in d for _, d in h.values()))
        self.assertEqual(G.health_exit(G.health(env={}, opener=opener)), 3)
        self.assertEqual(G.health_exit({"pro5000": ("UNREACHABLE", ""), "obs": ("MISSING_SECRETS", ""), "ts3": ("REFUSED", "")}), 4)

class GpuResume(unittest.TestCase):   # bug (a): a resumed item keeps the GPU recorded in state.json, never a silent pro5000 default
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
            L.HOME = h; L.time = Clock()
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
            L.HOME = h; L.time = Clock()
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
        self.assertEqual((L.wip_limit("cmdemo1-dashboard"), L.wip_limit("cmdemo1-workorders"), L.wip_limit("cmdemo1-system")), (8, 3, 3))

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

class ResearchBodyInnerH2(unittest.TestCase):   # the inner-H2 research lands in the PR body as ONE top-level section
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
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d = L.Driver("cmdemo1-workorders", 9, dry_run=True); d.s["plan"] = PLAN
                out, fu, prompt = d.research_prompt()
                self.assertIn(L.RESEARCH_HEAD, prompt)                                   # the heading the research starts with
                self.assertIn("###", prompt)                                             # ...and the subheadings it must use
                self.assertIn("never `## `", prompt)                                     # an H2 inside the research is forbidden
            finally: L.HOME = old

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
        d = L.Driver("cmdemo1-workorders", 9, dry_run=True); d.s["pr"] = pr; sent = []
        d.comment = lambda body, pr=False: sent.append((pr, body))
        return d, sent

    def test_fail_goes_to_issue_and_pr(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d, sent = self._driver(h, 77)
                d.review_fail_comment("Review → In Progress\n\nReview: FAIL.\n\n- x")
                self.assertEqual([p for p, _ in sent], [False, True])
                self.assertEqual(sent[0][1], sent[1][1])
            finally: L.HOME = old

    def test_no_pr_yet_only_the_issue(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME; L.HOME = h
            try:
                d, sent = self._driver(h, None)
                d.review_fail_comment("Review: FAIL")
                self.assertEqual([p for p, _ in sent], [False])
            finally: L.HOME = old

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
        d = L.Driver("cmdemo1-workorders", issue, dry_run=True)
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
        with tempfile.TemporaryDirectory() as h:
            old_home = L.HOME
            L.HOME = h
            try:
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
            finally:
                L.HOME = old_home

class RunTaskTimeout(unittest.TestCase):   # cmdemo1-system#817: --timeout must die with Pi's whole process group
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

    def _kill_pidfile(self, pidfile):
        try: pid = int(open(pidfile).read().strip())
        except (OSError, ValueError): return
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass

    def _pid_gone(self, pidfile, within=3.0):
        """True once the recorded pid is dead: no such process, gone from /proc, or a zombie (reaped by init)."""
        try: pid = int(open(pidfile).read().strip())
        except (OSError, ValueError): return False
        deadline = time.monotonic() + within
        while time.monotonic() < deadline:
            try: os.kill(pid, 0)
            except ProcessLookupError: return True
            try:
                with open(f"/proc/{pid}/status") as f:
                    state = next((l.split()[1] for l in f if l.startswith("State:")), "?")
            except OSError: return True
            if state == "Z": return True
            time.sleep(0.05)
        return False

    def test_run_pi_normal_exit_returns_rc_and_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, text = self.rt.run_pi(["bash", "-c", "echo hello; exit 3"], cwd=tmp, timeout=10)
            self.assertEqual(rc, 3)
            self.assertIn("hello", text)

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

class GpuGate(unittest.TestCase):   # cmdemo1-system#861: hard caps pro5000 2, obs 1, ts3 1 for every Pi launch
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
        for gpu, cap in (("pro5000", 2), ("obs", 1), ("ts3", 1)):
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
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME, L.gpu_health, L.time, L.gpu_for_item
            L.HOME = h; L.time = Clock()
            try:
                d = L.Driver("cmdemo1-workorders", 29)   # dry_run=False
                d.s["plan"] = dict(PLAN, size="large"); d.s["gpu"] = "obs"
                d.s["stage"] = "gpu"; d.s["status"] = "error"; d.s["error"] = "boom"; d.save()
                d.s = L.apply_resume(d.s); d.save()     # the resume rule: saved stage, error dropped, gpu cleared
                self.assertNotIn("gpu", d.s)
                rec = []
                real = L.gpu_for_item
                L.gpu_for_item = lambda *a: (rec.append(a), real(*a))[1]   # watch what st_gpu passes in
                L.gpu_health = lambda max_age=600: {"obs": ("UNREACHABLE", "down"), "pro5000": ("HEALTHY", ""), "ts3": ("HEALTHY", "")}
                d.comment = lambda *a, **k: None; d.wake_bot = lambda reason: None
                d.st_gpu()
                self.assertEqual(rec[0][0], None)        # st_gpu re-ran gpu_for_item with the cleared gpu
                self.assertEqual(d.s["gpu"], "pro5000")  # obs is down, so the free healthy pick is pro5000
                self.assertEqual(d.s["stage"], "pickup")
            finally:
                L.HOME, L.gpu_health, L.time, L.gpu_for_item = old

    def test_errone_gpu_item_waits_while_gpus_held_then_blocks(self):
        with tempfile.TemporaryDirectory() as h:
            old = L.HOME, L.gpu_health, L.time
            L.HOME = h; L.time = Clock()
            try:
                # Live items in another repo hold every available GPU: both pro5000 slots, obs and ts3.
                runs = os.path.join(h, "factory-runs")
                for i, (gpu, stage) in enumerate((("pro5000", "ci"), ("pro5000", "ci"), ("obs", "implement"), ("ts3", "review"))):
                    r = os.path.join(runs, f"cmdemo1-dashboard-{11 + i}"); os.makedirs(r)
                    json.dump({"repo": "cmdemo1-dashboard", "issue": 11 + i, "gpu": gpu, "stage": stage,
                              "status": "running", "pid": os.getpid()}, open(os.path.join(r, "state.json"), "w"))
                d = L.Driver("cmdemo1-workorders", 28)   # dry_run=False
                d.s["plan"] = dict(PLAN, size="large")
                d.s["stage"] = "gpu"; d.s["status"] = "error"; d.s["error"] = "boom"; d.save()   # the gpu is already cleared
                L.gpu_health = lambda max_age=600: {g: ("HEALTHY", "") for g in ("pro5000", "obs", "ts3")}
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
            finally:
                L.HOME, L.gpu_health, L.time = old

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
        with tempfile.TemporaryDirectory() as h:
            old_home, old_run = L.HOME, L.subprocess.run
            L.HOME = h
            seen, i = [], [0]
            def fake_run(*a, **k):
                seen.append((k.get("env") or {}).get("GH_TOKEN")); rc, out = replies[min(i[0], len(replies) - 1)]; i[0] += 1
                return L.subprocess.CompletedProcess(a, rc, out, "")
            L.subprocess.run = fake_run
            try:
                d = L.Driver("cmdemo1-workorders", 8); logs = []; d.log = logs.append
                res = d.gh("pr", "list", check=False)
            finally: L.subprocess.run, L.HOME = old_run, old_home
        return res, seen, logs

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
            with tempfile.TemporaryDirectory() as h:
                old_home, old_run = L.HOME, L.subprocess.run; L.HOME = h; seen = []
                L.subprocess.run = lambda *a, **k: (seen.append(k.get("env")), L.subprocess.CompletedProcess(a, 0, "", ""))[1]
                try: L.Driver("cmdemo1-workorders", 8).gh(*args)
                finally: L.subprocess.run, L.HOME = old_run, old_home
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


if __name__ == "__main__": unittest.main()
