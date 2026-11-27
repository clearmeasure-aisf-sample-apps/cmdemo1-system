"""Shared fakes for the item_loop test modules (test_item_loop.py and
test_item_loop_process_group.py, #1021). Pure fakes and fixtures -- no tests here,
so `unittest discover -p "test_*.py"` does not collect this file (its name does not
start with `test_`). Both test modules import the fakes they need from here; neither
imports the other, which keeps the re-export of the moved classes in test_item_loop.py
free of a circular import. Not a test module -- imported by the test_item_loop*.py files."""
import contextlib, os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import item_loop as L

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

HDR = '{"type": "session", "id": "s1"}'                                  # Pi session records (one JSON object per line)
USER = '{"type": "message", "message": {"role": "user", "content": "do it"}}'
ASSISTANT = '{"type": "message", "message": {"role": "assistant", "usage": {"input": 1, "output": 1}}}'

def scripted_sh(replies):
    """sh replacement for git/gh steps: a reply key is a command word or a run of consecutive words ('merge-base',
    'diff --cached', 'rev-parse', 'create') matched against the argv only, never against a commit message or a
    branch name. The first matching key answers; its value is the stdout, or a (returncode, stdout) pair when the
    command must fail. Every command is recorded in the callable's .calls list. A `Command` value object is
    unwrapped to its argv for matching and recording (cmdemo1-system#947)."""
    calls = []
    def sh(cmd, **k):
        argv = cmd.argv if isinstance(cmd, L.Command) else cmd
        calls.append(list(argv))
        words_argv = argv.split() if isinstance(argv, str) else [str(x) for x in argv]
        for key, reply in replies.items():
            words = key.split()
            if any(words_argv[i:i + len(words)] == words for i in range(len(words_argv) - len(words) + 1)):
                rc, stdout = reply if isinstance(reply, tuple) else (0, reply)
                return L.subprocess.CompletedProcess(argv, rc, stdout, "")
        return L.subprocess.CompletedProcess(argv, 0, "", "")
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

def gh_recorder():
    """GhChokepoint's #828 recorder, shared with the process-group tests (#1021): records every (cmd, kwargs) the
    runner is handed, answers rc 0. A `Command` value object is unwrapped to its argv for the CompletedProcess."""
    calls = []
    sh = lambda cmd, **k: (calls.append((cmd, k)), subprocess.CompletedProcess(getattr(cmd, "argv", cmd), 0, "", ""))[1]
    return sh, calls
