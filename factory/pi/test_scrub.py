#!/usr/bin/env python3
"""Tests for the shared scrub rule set, factory/pi/scrub.py (#838), moved out of test_item_loop.py (#1022) so the
module has a test file of its own -- the same move #1021 made for the process-group kill tests.
Moved unchanged (every test name and assertion as it was): Rules.test_scrub_env_values (now ScrubEnvValues),
Scrubbing and SharedScrubModule. The two classes move whole, including the tests that check item_loop's re-export and
run-task's binding, so their bodies stay byte-identical; splitting them would change the classes, not just move them.
ScrubRuleGaps (#1022) covers the rules nothing tested before. Every token, host and password here is made up and
built at run time, so the secret scan sees no literal; each test restores scrub.SECRET_SOURCES and every env var it sets.
test_item_loop.py re-exports the TestCase classes here so the CI command that names it still runs them.
Run: python3 -m unittest factory/pi/test_scrub.py"""
import importlib.machinery, importlib.util, os, sys, unittest
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_loop as L
import scrub as S

class ScrubEnvValues(unittest.TestCase):   # moved from Rules (#1022): an env URL value and a temporary tunnel are redacted
    def test_scrub_env_values(self):
        os.environ["LOCAL_LLM_PRO5000_URL"] = "https://example-tunnel.invalid/v1"
        try: self.assertNotIn("example-tunnel", L.scrub("base https://example-tunnel.invalid/v1/models"))
        finally: del os.environ["LOCAL_LLM_PRO5000_URL"]
        self.assertEqual(L.scrub("x https://a-b.trycloudflare.com/v1 y"), "x [redacted] y")

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

class ScrubRuleGaps(unittest.TestCase):   # #1022: the scrub rules nothing covered before; made-up values only
    def setUp(self):
        saved = list(S.SECRET_SOURCES)                     # every registration below is undone after each test
        self.addCleanup(S.SECRET_SOURCES.__setitem__, slice(None), saved)

    def assertRedacted(self, line, value, expected):
        out = S.scrub(line)
        self.assertNotIn(value, out); self.assertEqual(out, expected)

    def test_a_fine_grained_github_pat_is_redacted(self):
        pat = "github_pat_" + "A1" * 11 + "_" + "b2" * 15
        self.assertRedacted(f"push with {pat} done", pat, "push with [redacted] done")

    def test_a_gpu_tunnel_host_is_redacted_with_and_without_a_scheme(self):
        for host in ("pro9999.clearmeasure.ai", "1234ti.clearmeasure.ai", "edge.pro4321.clearmeasure.ai"):
            with self.subTest(host=host):
                self.assertRedacted(f"GET https://{host}/v1/models -> 200", host, "GET [redacted] -> 200")
                self.assertRedacted(f"GET http://{host}:8080/v1 ok", host, "GET [redacted] ok")
                self.assertRedacted(f"host {host}:8080 up", host, "host [redacted] up")
        self.assertEqual(S.scrub("see https://www.clearmeasure.ai/about"), "see https://www.clearmeasure.ai/about",
                         "a clearmeasure.ai host that is not a GPU tunnel is left alone")

    def test_password_api_key_and_mixed_case_token_assignments_are_redacted(self):
        v = "made" + "Up" * 5
        for key in ("password=", "api_key: ", "Token = ", "TOKEN=", "ApiKey:", "Secret = "):
            with self.subTest(key=key):
                self.assertRedacted(f"login {key}{v} ok", v, "login [redacted] ok")

    def test_min_secret_len_is_the_boundary_for_a_registered_value(self):
        self.assertEqual(S.MIN_SECRET_LEN, 6)
        kept, cut = "kq" + "w" * (S.MIN_SECRET_LEN - 2), "kq" + "w" * (S.MIN_SECRET_LEN - 1)
        self.assertEqual((len(kept), len(cut)), (6, 7))
        S.add_secret_source(lambda: kept)
        self.assertEqual(S.scrub(f"a {kept} b"), f"a {kept} b", "a 6-character value is too short to be a secret")
        S.add_secret_source(lambda: cut)
        self.assertEqual(S.scrub(f"a {cut} b"), "a [redacted] b", "a 7-character value is redacted")

    def test_min_secret_len_is_the_same_boundary_for_an_env_value(self):
        kept, cut = "zx" + "v" * 4, "zx" + "v" * 5
        with mock.patch.dict(os.environ, {"GH_TOKEN": kept}):
            self.assertEqual(S.scrub(f"a {kept} b"), f"a {kept} b")
        with mock.patch.dict(os.environ, {"GH_TOKEN": cut}):
            self.assertEqual(S.scrub(f"a {cut} b"), "a [redacted] b")

    def test_add_secret_source_keeps_one_entry_per_callable_and_ignores_none(self):
        src = lambda: "r" + "j" * 20
        before = len(S.SECRET_SOURCES)
        self.assertIs(S.add_secret_source(src), src)
        self.assertIs(S.add_secret_source(src), src)
        self.assertEqual(len(S.SECRET_SOURCES), before + 1); self.assertEqual(S.SECRET_SOURCES.count(src), 1)
        self.assertIsNone(S.add_secret_source(None))
        self.assertEqual(len(S.SECRET_SOURCES), before + 1); self.assertNotIn(None, S.SECRET_SOURCES)

    def test_a_source_that_raises_is_skipped_and_the_rest_still_run(self):
        v = "after" + "K" * 12
        def broken(): raise RuntimeError("source unavailable")
        S.add_secret_source(broken); S.add_secret_source(lambda: v)
        self.assertEqual(S.scrub(f"x {v} y"), "x [redacted] y", "the source after the broken one still redacts")


# Asking unittest for one test as `<file> <Class>.<test>` (e.g. `python3 -m unittest factory/pi/test_scrub.py
# ScrubRuleGaps.test_a_fine_grained_github_pat_is_redacted`) does not work out of the box: unittest resolves every
# CLI name on its own and imports <Class> as a module. Alias the TestCase classes defined here under their own names so
# that form resolves (the same block as test_item_loop_process_group.py). It changes no assertion and no result.
# `del _cls` after the loop: left bound, the loader would collect the last class a second time under the name `_cls`.
for _cls in [_c for _c in list(globals().values())
             if isinstance(_c, type) and issubclass(_c, unittest.TestCase) and _c.__module__ == __name__]:
    sys.modules.setdefault(_cls.__name__, _cls)
del _cls
