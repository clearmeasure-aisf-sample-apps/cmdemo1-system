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


if __name__ == "__main__": unittest.main()
