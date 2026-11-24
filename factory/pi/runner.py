#!/usr/bin/env python3
"""The factory's ONE command runner with a deadline (cmdemo1-system#839): every timed local command goes through it,
so #817's process-group rules are written once.

    from runner import run_cmd                      the driver (item_loop re-exports it) and run-task, both
    run_cmd(cmd, cwd=..., timeout=...) -> CompletedProcess | raises subprocess.TimeoutExpired

This file holds the mechanism only and never maps a timeout to a return code: run-task's rc 124, the driver's
RuntimeError and a caller's own retry stay with the caller. It is deliberately its own module, like scrub.py (#838):
run-task must be able to use it without importing the item driver.
"""
import os, signal, subprocess

# ---- The one place the factory runs a command with a deadline. Local commands move onto it from their own
#      subprocess.run / Popen pairs; it owns #817's process-group rules so every timeout is a real one.
def run_cmd(cmd, cwd=None, timeout=None, env=None, stdin=None, shell=None, stdout=subprocess.PIPE, stderr=None,
            text=True, pass_fds=(), on_spawn=None):
    """Run `cmd` (a str goes through the shell) in its OWN process group; return a CompletedProcess(cmd, rc, out, "").

    #839: subprocess.run(cmd, timeout=...) killed only the direct child, so the grandchildren of a long command (a
    `gh run watch` with timeout 6*3600, a verify command) survived the deadline and kept the inherited stdout pipe
    open -- the parent's read to EOF then outlasted the timeout, which is the same bug family as #817 (run-task's
    --timeout 1800 ran 4263 s and held the GPU slot lock the whole time). So: start_new_session=True makes the child a
    group leader, and on timeout SIGTERM then SIGKILL reach the child AND everything it started; the output collected
    before the kill comes back on the exception's output, because run-task re-reads it. The timeout is reported to the
    caller -- never swallowed here, and never converted into a return code (that mapping belongs to the caller).

    stderr=None means the child's stderr joins the single captured stream (subprocess.STDOUT, the way run-task reads
    Pi); pass subprocess.STDOUT/PIPE/DEVNULL explicitly to say otherwise. on_spawn(p) runs with the Popen before any
    waiting, so a watchdog (run-task's) can hold the handle while this function waits. shell=None means 'a str is a
    shell command', which is what the callers being replaced did."""
    p = subprocess.Popen(cmd, cwd=cwd, shell=isinstance(cmd, str) if shell is None else shell, text=text, env=env,
                         stdin=stdin, stdout=stdout, stderr=stderr if stderr is not None else subprocess.STDOUT,
                         pass_fds=pass_fds, start_new_session=True)
    if on_spawn is not None: on_spawn(p)
    try:
        out, _ = p.communicate(timeout=timeout)
        return subprocess.CompletedProcess(cmd, p.returncode, out, "")
    except subprocess.TimeoutExpired as e:
        collected = e.output if e.output is not None else ""   # bytes or str, whichever text= asked for
        def kill(sig):
            try: os.killpg(p.pid, sig)
            except ProcessLookupError: pass                    # already gone: nothing in the group left to signal
        for sig in (signal.SIGTERM, signal.SIGKILL):           # ask first, then end the whole group
            kill(sig)
            try:
                out, _ = p.communicate(timeout=5)
                collected = out or collected
                break
            except subprocess.TimeoutExpired as e2:            # something outside the group still holds the pipe
                collected = (e2.output if e2.output is not None else "") or collected
        try:
            if p.stdout is not None and not p.stdout.closed: p.stdout.close()   # stop waiting for EOF from a stranger
        except OSError: pass
        try: p.wait(timeout=5)                                 # always reap: the group is dead, so this returns at once
        except subprocess.TimeoutExpired: pass
        raise subprocess.TimeoutExpired(cmd, timeout, output=collected) from None
