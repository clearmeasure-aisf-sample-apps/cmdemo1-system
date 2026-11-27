"""Unit tests of the Pi GPU module's decision rules (no network, no Pi). Run: python3 -m unittest factory/pi/test_gpu.py"""
import json, os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu as G

class Gpus(unittest.TestCase):
    def test_secret_names_cover_four_gpus_and_keep_pro5000(self):
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

class GpuGateTasks(unittest.TestCase):
    """cmdemo1-system#865: an old-code run-task that keeps a legacy /tmp slot while its child pi holds the new slot
    is ONE task, not two. Unit test with a fake /proc (no real processes, no /tmp)."""

    def _fake_proc(self, root, procs):
        """procs: {pid: (ppid, [slot paths])} -> <root>/proc/<pid>/stat plus <pid>/fd/ symlinks onto the slot files."""
        proc = os.path.join(root, "proc")
        for pid, (ppid, slots) in procs.items():
            d = os.path.join(proc, str(pid)); fd = os.path.join(d, "fd"); os.makedirs(fd)
            with open(os.path.join(d, "stat"), "w") as f:
                f.write(f"{pid} (fake) S {ppid} 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 {pid}")
            for i, s in enumerate(slots): os.symlink(s, os.path.join(fd, str(i)))
        return proc

    def _slot_dirs(self, tmp):
        import gpu_gate as GG
        new, legacy = os.path.join(tmp, "new"), os.path.join(tmp, "legacy")
        for d in (new, legacy): os.makedirs(d)
        for g in ("pro5000",):
            for i in range(2):
                for d in (new, legacy): open(os.path.join(d, f"factory-pi-{g}-slot-{i}.lock"), "w").close()
        old = {k: os.environ.get(k) for k in ("FACTORY_PI_LOCK_DIR", "FACTORY_PI_LEGACY_LOCK_DIR")}
        os.environ.update({"FACTORY_PI_LOCK_DIR": new, "FACTORY_PI_LEGACY_LOCK_DIR": legacy})
        self.addCleanup(self._restore_env, old)
        return new, legacy, GG

    @staticmethod
    def _restore_env(old):
        for k, v in old.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v

    def test_parent_legacy_and_child_new_count_as_one_task(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            new, legacy, GG = self._slot_dirs(tmp)
            s0_leg = os.path.join(legacy, "factory-pi-pro5000-slot-0.lock")
            s0_new = os.path.join(new, "factory-pi-pro5000-slot-0.lock")
            s1_leg = os.path.join(legacy, "factory-pi-pro5000-slot-1.lock")
            # run-task (old code) keeps the legacy slot-0; its child pi holds the new slot-0; a third old run-task
            # waits on the legacy slot-1. The Nov 21 shape that showed pro5000 3/2 with one Pi running.
            proc = self._fake_proc(tmp, {100: (1, [s0_leg]), 200: (100, [s0_new]), 300: (1, [s1_leg])})
            h = GG.holders("pro5000", proc=proc)
            self.assertEqual(len(h), 3)                       # three distinct slot files really are open
            self.assertEqual(GG.tasks(h, proc=proc), 2)       # parent+child are one task; the waiter is the second

    def test_twin_slots_of_one_process_and_unrelated_holders_still_count(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            new, legacy, GG = self._slot_dirs(tmp)
            s0_leg = os.path.join(legacy, "factory-pi-pro5000-slot-0.lock")
            s0_new = os.path.join(new, "factory-pi-pro5000-slot-0.lock")
            s1_leg = os.path.join(legacy, "factory-pi-pro5000-slot-1.lock")
            # one process holding both the new slot and its legacy twin is one task (the old dedupe, kept)
            with tempfile.TemporaryDirectory() as tmp2:
                proc = self._fake_proc(tmp2, {100: (1, [s0_leg, s0_new])})
                self.assertEqual(GG.tasks(GG.holders("pro5000", proc=proc), proc=proc), 1)
            # two unrelated holders are still two tasks: ancestry only merges parent/child, not siblings
            with tempfile.TemporaryDirectory() as tmp2:
                proc = self._fake_proc(tmp2, {100: (1, [s0_leg]), 300: (1, [s1_leg])})
                self.assertEqual(GG.tasks(GG.holders("pro5000", proc=proc), proc=proc), 2)

    def test_mine_exclusion_still_hides_the_launchers_own_slots(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            new, legacy, GG = self._slot_dirs(tmp)
            s0_leg = os.path.join(legacy, "factory-pi-pro5000-slot-0.lock")
            s0_new = os.path.join(new, "factory-pi-pro5000-slot-0.lock")
            proc = self._fake_proc(tmp, {100: (1, [s0_leg]), 200: (100, [s0_new])})
            h = GG.holders("pro5000", proc=proc)
            # the child pi counting its own parent chain as `mine` sees no other task (the #861 own-parent rule)
            self.assertEqual(GG.tasks(h, mine=frozenset(GG.ancestors(200, proc=proc)), proc=proc), 0)


class GpuArg(unittest.TestCase):   # cmdemo1-system#907: one place renders run-task's --gpu argument
    def test_a_gpu_list_becomes_a_comma_list_in_the_order_given(self):
        self.assertEqual(G.gpu_arg(G.LARGE_GPUS), "pro5000,pro6000")
        self.assertEqual(G.gpu_arg(["obs", "ts3"]), "obs,ts3")
        self.assertEqual(G.gpu_arg(["pro5000", "pro6000", "obs", "ts3"]), "pro5000,pro6000,obs,ts3")

    def test_one_gpu_name_stays_one_name(self):
        for g in G.GPUS: self.assertEqual(G.gpu_arg(g), g)

    def test_every_name_it_renders_is_a_known_gpu(self):
        for arg in (G.gpu_arg(G.LARGE_GPUS), G.gpu_arg(G.PRIORITY), G.gpu_arg("ts3")):
            self.assertTrue(arg, "a --gpu argument is never empty")
            self.assertTrue(all(g in G.GPUS for g in arg.split(",")), arg)


class ExcludedGpus(unittest.TestCase):   # cmdemo1-system#926: reserved GPUs (gpu-exclude) are never picked
    def test_excluded_gpus_reads_temp_file(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "gpu-exclude")
            with open(p, "w") as f:
                f.write("# reserved for the box lane\npro6000, pro5000\nobs  # inline comment\nbogus\n# another\n")
            self.assertEqual(G.excluded_gpus(env={}, path=p), {"pro6000", "pro5000", "obs"})

    def test_env_var_overrides_file_and_empty_env_var_means_nothing_excluded(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "gpu-exclude")
            with open(p, "w") as f: f.write("pro6000\n")
            # env var set: wins over the file
            self.assertEqual(G.excluded_gpus(env={"FACTORY_GPU_EXCLUDE": "obs"}, path=p), {"obs"})
            # empty env var: wins over the file, means nothing excluded
            self.assertEqual(G.excluded_gpus(env={"FACTORY_GPU_EXCLUDE": ""}, path=p), set())

    def test_missing_file_gives_empty_set(self):
        self.assertEqual(G.excluded_gpus(env={}, path="/nonexistent/gpu-exclude"), set())

    def test_reviewer_gpus_drops_excluded(self):
        self.assertEqual(G.reviewer_gpus("pro5000", ["pro5000", "pro6000", "obs"], excluded={"pro6000"}), ["obs"])


if __name__ == "__main__": unittest.main()
