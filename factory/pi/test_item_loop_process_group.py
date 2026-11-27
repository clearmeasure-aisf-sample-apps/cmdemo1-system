"""Process-group kill family (#817, #839) of the Pi item driver tests, moved out of test_item_loop.py
(#1021) so that file stops being 4,244 lines. The `PidfileKill` mixin and the classes that use it --
RunTaskTimeout (#817), RunCmdGroupKill, DriverShGroupKill, VerifyEvidenceRunCmd, SharedRunCmd (#839) --
plus the two in-block classes they share fixtures with, SharedTaskTimeout and GpuGate (#861).
Move-only: every test name and assertion is unchanged. No network, no real pi, nothing outside a
TemporaryDirectory; every pid a fake starts is killed in addCleanup.
Shared fakes (PLAN, fake_home, make_driver, ...) come from item_loop_test_fakes.py; test_item_loop.py
re-exports the TestCase classes here so the CI command that names it still runs them.
Run: python3 -m unittest factory/pi/test_item_loop_process_group.py"""
import argparse, fcntl, importlib.machinery, importlib.util, inspect, json, os, re, shutil, signal, subprocess, sys, tempfile, threading, time, unittest
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_loop as L
import item_loop_test_fakes as fakes
from item_loop_test_fakes import PLAN, fake_home, fake_modules, make_driver, scripted_sh, patch_run, HDR, ASSISTANT

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
            run = self.rt.run_pi(["bash", "-c", "echo hello; exit 3"], cwd=tmp, timeout=10)
            self.assertEqual(run.rc, 3)
            self.assertIn("hello", run.text)

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
            run = self.rt.run_pi([fake], cwd=tmp, timeout=2)
            elapsed = time.monotonic() - t0
            self.assertEqual(run.rc, 124, "a timed-out Pi run must report 124")
            self.assertIn("started", run.text)
            self.assertLess(elapsed, 12, f"--timeout 2 took {elapsed:.1f}s: it waited for the grandchildren to exit")
            self.assertTrue(self._pid_gone(pidfile), "the grandchild holding the stdout pipe must be killed too")

    def make_timed_out_run_dir(self, tmp, fake_pi):
        """Build the scenario for a run-task that will time out: a fake run dir with run.json, a prompt file,
        and a scrubbed env (no LOCAL_LLM_* secrets) with FACTORY_PI_GPU_BIN, FACTORY_PI_LOCK_DIR, TMPDIR,
        and FACTORY_MIN_CLIENT_TIMEOUT_S=1 (so --timeout 2 doesn't become 300 s). Returns (run, cwd, lockdir,
        prompt, env)."""
        run, cwd, lockdir = (os.path.join(tmp, x) for x in ("run", "work", "locks"))
        for d in (run, cwd, lockdir): os.makedirs(d)
        json.dump({"top_session": "t", "start": "2026-01-01T00:00:00+00:00", "pi_version": "0-test"},
                  open(os.path.join(run, "run.json"), "w"))   # so run-task never calls `pi --version`
        prompt = os.path.join(tmp, "prompt.md"); open(prompt, "w").write("do the task\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith("LOCAL_LLM_")}   # no secrets to the child
        env.update({"FACTORY_PI_GPU_BIN": fake_pi, "FACTORY_PI_LOCK_DIR": lockdir, "TMPDIR": tmp,
                    "FACTORY_MIN_CLIENT_TIMEOUT_S": "1"})
        return run, cwd, lockdir, prompt, env

    def test_run_task_timeout_releases_slot_and_leaves_no_grandchild(self):
        # Safety first: without the two overrides below, running run-task end to end would take the real
        # /tmp/factory-pi-<gpu>-slot-N.lock and exec the real pi-gpu. Fail here instead of doing either.
        src = open(self.RUN_TASK).read()
        missing = [v for v in ("FACTORY_PI_GPU_BIN", "FACTORY_PI_LOCK_DIR") if v not in src]
        self.assertFalse(missing, "run-task must honour " + ", ".join("$" + v for v in missing) +
                                  ": tests must never take the real /tmp slot locks or exec the real pi-gpu")
        with tempfile.TemporaryDirectory() as tmp:
            fake, pidfile = self._fake_pi(tmp)
            run, cwd, lockdir, prompt, env = self.make_timed_out_run_dir(tmp, fake)
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
                seen.append(a[2] if len(a) > 2 else kw.get("timeout"))
                return L.PiRun(result="PASS", gpu=None, rc=0)
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
        """GhChokepoint's #828 recorder, shared via item_loop_test_fakes (#1021): records every (cmd, kwargs) the
        runner is handed, answers rc 0."""
        return fakes.gh_recorder()

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
                r = d.gh("pr", "list", check=False)   # App attempt refused -> the same call on the user login
                d.sh(["git", "status"], check=False)  # never a gh command: never a token
        self.assertEqual([list(c) for c, _ in run.calls], [["gh", "pr", "list"], ["gh", "pr", "list"], ["git", "status"]],
                         "the refused attempt is re-run with the same argv")
        self.assertEqual([((k.get("env") or {}).get("GH_TOKEN")) for _, k in run.calls], [self.APP_TOKEN, None, None])
        self.assertEqual((r.returncode, r.stdout), (0, "[]"))
        self.assertTrue(any("user login" in m for m in logs))

    def test_bare_gh_list_gets_no_app_token_and_no_retry(self):
        """cmdemo1-system#947: a bare ["gh", ...] list passed to sh() is a non-gh command -- no App token, no
        rate-limit retry. Only gh() builds a Command with is_gh=True, and only that gets the App quota and the
        backoff. This test goes through the REAL Driver.sh via patch_run, so the real sh code path runs."""
        os.environ["GH_APP_TOKEN_CMD"] = f"printf {self.APP_TOKEN}"
        # a rate-limited reply: if sh() treated this as a gh command, it would retry
        rl = (1, "GraphQL: API rate limit exceeded for user ID 1.")
        run = self.run_recorder([rl])
        with fake_home():
            d = make_driver(repo="cmdemo1-system", issue=839, dry_run=False)
            waits = []; d.wait_alive = lambda s, why: waits.append((s, why))
            with patch_run(run):
                r = d.sh(["gh", "pr", "list"], check=False)   # bare list: not a Command, so non-gh
        # exactly one run: no retry (a gh command would have retried the rate-limited reply)
        self.assertEqual(len(run.calls), 1,
                         "a bare gh list must not be retried: sh() does not sniff argv for gh")
        # no App token: the env must not carry GH_TOKEN
        self.assertEqual([(k.get("env") or {}).get("GH_TOKEN") for _, k in run.calls], [None],
                         "a bare gh list must not get the App token: only gh() decides app_ok")
        # no wait_alive calls: the retry loop never ran
        self.assertEqual(waits, [])
        # the rate-limited reply is returned as-is (no retry)
        self.assertEqual((r.returncode, r.stdout), rl)

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
            with fake_modules({(L, "time"): self.StepTime(1e6, 1e6 + 1, 1e6 + 2)}):
                with patch_run(run):
                    rc, out = d.verify("x")
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

    # (5) cmdemo1-system#967: an opt-in per-plan verify_timeout -- the driver passes it to run_cmd, and a
    #     subprocess.TimeoutExpired becomes rc 124 with the collected output, not a raise.
    def test_verify_timeout_returns_rc_124_with_collected_output(self):
        """A plan with verify_timeout=300 hands timeout=300 to the runner; when the runner raises
        TimeoutExpired the driver returns (124, collected-output) -- it does not raise -- and the verify
        log carries the partial output plus the timeout line."""
        with fake_home() as h:
            d = self.driver(h)
            d.s["plan"]["verify_timeout"] = 300
            logs = []; d.log = logs.append
            captured = {}
            def fake_run(cmd, **k):
                captured["cmd"] = cmd
                captured.update(k)
                raise subprocess.TimeoutExpired(cmd, 300, output="partial")
            with fake_modules({(L, "run_cmd"): fake_run}):
                rc, out = d.verify("x")
            log_text = open(os.path.join(d.run_dir, "logs", "verify-x.log")).read()
            self.assertEqual(captured["timeout"], 300, "verify must hand the plan's verify_timeout to run_cmd")
            self.assertEqual(rc, 124, "a timed-out verify returns rc 124, not an exception")
            self.assertIn("partial", out, "the output collected before the kill must come back")
            self.assertIn("partial", log_text, "the verify log must carry the partial output")

    def test_local_green_routes_a_timed_out_verify_through_local_fix(self):
        """When verify times out every run, local_green must not raise -- it must return False and call Pi
        LIMITS['local_fix'] times with the fix names (x-fix-1, x-fix-2, ...) carrying the partial output in the
        prompt. This is the end-to-end proof the issue title asks for: a timed-out verify goes through the
        same local_fix Pi rounds as any other red verify."""
        with fake_home() as h:
            d = self.driver(h)
            d.s["plan"]["verify_timeout"] = 300
            d.log = lambda *a: None
            pi_calls = []
            def fake_pi(name, prompt, timeout=L.PI_TASK_TIMEOUT_S, gpu=None):
                pi_calls.append((name, prompt))
                return L.PiRun(result="FAIL", gpu=None, rc=1)
            d.pi = fake_pi
            d.verify = lambda name: (124, "partial")
            ok = d.local_green("x")
            self.assertFalse(ok, "a verify that times out every run is never green")
            self.assertEqual(len(pi_calls), L.LIMITS["local_fix"],
                             f"local_green must run LIMITS['local_fix']={L.LIMITS['local_fix']} Pi fix rounds, got {len(pi_calls)}")
            names = [c[0] for c in pi_calls]
            self.assertEqual(names, ["x-fix-1", "x-fix-2", "x-fix-3"],
                             "the fix rounds must be named x-fix-1, x-fix-2, x-fix-3")
            for name, prompt in pi_calls:
                self.assertIn("partial", prompt, f"the {name} prompt must carry the timed-out verify's output")

class GpuGate(unittest.TestCase):   # cmdemo1-system#861: hard caps pro5000 2, pro6000 1, obs 1, ts3 1 for every Pi launch
    """On Nov 21 a Pi session ran `rm -f /tmp/factory-pi-*-slot-*.lock`; new run-tasks then took "free" slots on new
    inodes while the old holders still ran (3 on pro5000, 2 on ts3 and obs). Only a private slot dir is used here."""
    HERE = os.path.dirname(os.path.abspath(__file__))
    GATE = os.path.join(HERE, "gpu_gate.py")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(); self.procs = []
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("LOCAL_LLM_", "FACTORY_GPU_"))}
        self.env["FACTORY_PI_LOCK_DIR"] = os.path.join(self.tmp, "slots")
        self.addCleanup(shutil.rmtree, self.tmp, True)   # #1021: the private slot dir is removed after the test (LIFO: after _reap)
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
        run = rt.run_pi([sys.executable, "-c", code], cwd=self.HERE, timeout=20, slot_fd=fd, env=env)
        os.close(fd)
        self.assertEqual((run.rc, run.text.strip()), (0, str(fd)), "pi-gpu must see the slot run-task passed down")

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
            run = rt.run_pi([fake], cwd=tmp, timeout=30, watch=rt.Watch.for_run(tmp, time.time(), 1.5, beat=beat, stall_s=1.5))
            elapsed = time.monotonic() - t0
        self.assertEqual(run.rc, rt.NO_START_RC, "a Pi that stops being active after its first model output is still rc 125")
        self.assertTrue(run.started, "model output arrived, so this is a stall and not a no-start")
        self.assertIn("started", run.text)
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
        run = rt.run_pi([sys.executable, "-c", code], cwd=self.HERE, timeout=20, slot_fd=fd, env=env)
        self.assertEqual(run.rc, 0, run.text[-500:])
        self.assertIn(f"ENVD=obs:{fd}", run.text, "the child still sees FACTORY_GPU_SLOT_FD: pi-gpu's gate reads the slot from it")
        self.assertIn(f"HELD={fd}", run.text, "and the fd itself is open in the child, so the slot is held as long as Pi lives")


# Asking unittest for one test as `<file> <Class>.<test>` (e.g. `python3 -m unittest factory/pi/test_item_loop_process_group.py
# RunTaskTimeout.test_run_pi_normal_exit_returns_rc_and_output`) does not work out of the box: unittest resolves every
# CLI name on its own, so it never reads <Class> off the file given before it -- it imports it as a module and the whole
# run dies as `ModuleNotFoundError: No module named 'RunTaskTimeout'` (FAILED (errors=1)) whatever the code does. Alias
# the TestCase classes defined here under their own names so that form resolves. It changes no assertion and no result.
for _cls in [_c for _c in list(globals().values())
             if isinstance(_c, type) and issubclass(_c, unittest.TestCase) and _c.__module__ == __name__]:
    sys.modules.setdefault(_cls.__name__, _cls)
