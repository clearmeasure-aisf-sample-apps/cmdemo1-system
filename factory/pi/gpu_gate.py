#!/usr/bin/env python3
"""The one per-GPU concurrency gate every Pi launch goes through (cmdemo1-system#861). Hard caps: pro5000 2, pro6000 1, obs 1, ts3 1.

    gpu_gate.py hold GPU [--no-wait] -- CMD [ARGS...]   take a slot of GPU, then exec CMD holding it (pi-gpu runs Pi so)
    gpu_gate.py status [--json]                         live holders per GPU (pi-gpu-health / watchdog)

- A slot is an flock on <dir>/factory-pi-<gpu>-slot-<i>.lock (<dir>: $FACTORY_PI_LOCK_DIR, else ~/.config/factory/gpu-slots;
  never /tmp, where a blanket `rm` freed every slot on Nov 21). The OS drops an flock when the last process holding its
  file dies, so a crash or SIGKILL frees the slot; nothing to clean up, and slot files must never be deleted.
- The fd is inheritable: Pi (exec'd by pi-gpu) and every process Pi starts keep the slot until they all exit, so a killed
  run-task cannot free a slot while an orphan Pi still uses the GPU.
- Tamper-proof count: under a gate mutex, holders are counted from /proc/*/fd, as distinct open slot files of that GPU:
  deleted ones (`(deleted)`) and the legacy /tmp slot files of drivers still on old code included. A new slot is taken
  only while that count is under the cap, so deleting lock files can never let a fourth task start.
- Caps: gpu.GPUS[g]['slots']. $FACTORY_GPU_CAPS ("pro5000=2,pro6000=1,obs=1,ts3=1") may lower a cap, never raise it.
- Waiting: a launch that finds the GPU full waits (5 s polls) and prints a heartbeat line to stderr every 60 s; with
  --no-wait it exits 75 instead.
"""
import fcntl, json, os, re, sys, time
HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import gpu as G

BUSY_EXIT = 75
POLL_S, HEARTBEAT_S = 5, 60

def lock_dir():
    d = os.environ.get("FACTORY_PI_LOCK_DIR") or os.path.join(os.path.expanduser("~"), ".config", "factory", "gpu-slots")
    os.makedirs(d, exist_ok=True); return os.path.realpath(d)

def caps(env=None):
    env = os.environ if env is None else env
    c = {g: v["slots"] for g, v in G.GPUS.items()}
    for part in (env.get("FACTORY_GPU_CAPS") or "").split(","):
        g, _, n = part.strip().partition("=")
        if g in c and n.strip().isdigit(): c[g] = min(c[g], int(n))
    return c

def slot_path(g, i): return os.path.join(lock_dir(), f"factory-pi-{g}-slot-{i}.lock")

def slot_dirs():
    """Where slots live: the slot dir plus the legacy dir (/tmp: drivers still on old code; $FACTORY_PI_LEGACY_LOCK_DIR)."""
    legacy = os.environ.get("FACTORY_PI_LEGACY_LOCK_DIR", "" if os.environ.get("FACTORY_PI_LOCK_DIR") else "/tmp")
    return [lock_dir()] + ([os.path.realpath(legacy)] if legacy else [])

def ancestors(pid=None):
    """This process and its parents. A legacy run-task parent's /tmp slot is this launch's own slot, not another task's
    (else the new pi-gpu under an old run-task would wait on its own parent forever)."""
    out, pid = set(), pid or os.getpid()
    while pid > 1 and pid not in out:
        out.add(pid)
        try: pid = int(open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError): break
    return out

def holders(g, proc="/proc"):
    """Distinct slot files of GPU g open in any live process: (dev, inode) -> pids; deleted files included."""
    dirs = "|".join(re.escape(d.rstrip("/")) for d in slot_dirs())
    pat = re.compile(rf"^({dirs})/factory-pi-{re.escape(g)}-slot-\d+\.lock( \(deleted\))?$")
    found = {}
    for pid in (p for p in os.listdir(proc) if p.isdigit()):
        fd_dir = os.path.join(proc, pid, "fd")
        try: fds = os.listdir(fd_dir)
        except OSError: continue
        for fd in fds:
            try:
                if not pat.search(os.readlink(os.path.join(fd_dir, fd))): continue
                st = os.stat(os.path.join(fd_dir, fd))
            except OSError: continue
            found.setdefault((st.st_dev, st.st_ino), set()).add(int(pid))
    return found

def tasks(h, mine=frozenset()):
    """Live tasks among holders h: a slot and its legacy twin are held by the same processes, so they count once."""
    return len({frozenset(p) for p in h.values() if not p <= mine})

def try_acquire(g):
    """An inheritable fd holding one of g's slots, or None when g already has cap live holders."""
    if g not in G.GPUS: raise ValueError(f"unknown GPU {g}")
    cap = caps()[g]
    with open(os.path.join(lock_dir(), "gate.lock"), "a") as mutex:
        fcntl.flock(mutex, fcntl.LOCK_EX)
        mine, h = ancestors(), holders(g)
        if tasks(h, mine) >= cap: return None
        fd = next((x for x in (_lock(slot_path(g, i)) for i in range(cap)) if x is not None), None)
        legacy = slot_dirs()[1:]
        if fd is None or not legacy or any(pids <= mine for pids in h.values()): return fd
        # rollout: also hold a legacy slot, so a run-task still on old code (it only sees /tmp) cannot start beside us
        lfd = next((x for x in (_lock(os.path.join(legacy[0], f"factory-pi-{g}-slot-{i}.lock"))
                                for i in range(G.GPUS[g]["slots"])) if x is not None), None)
        if lfd is None: os.close(fd); return None
        COMPAT[fd] = lfd; return fd

COMPAT = {}   # slot fd -> the legacy /tmp slot fd held with it during the rollout

def _lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: os.close(fd); return None
    os.set_inheritable(fd, True); return fd

def slot_fds(fd): return (fd,) + ((COMPAT[fd],) if fd in COMPAT else ())

def release(fd):
    for x in slot_fds(fd): os.close(x)
    COMPAT.pop(fd, None)

def acquire(g, wait=True, log=sys.stderr):
    t0 = last = time.monotonic()
    while True:
        fd = try_acquire(g)
        if fd is not None or not wait: return fd
        if time.monotonic() - last >= HEARTBEAT_S:
            last = time.monotonic()
            print(f"gpu_gate: waiting for a {g} slot ({tasks(holders(g))}/{caps()[g]} held, {int(last - t0)} s)", file=log, flush=True)
        time.sleep(POLL_S)

def acquire_any(gs, wait=True, log=sys.stderr, max_wait=None):
    """(gpu, fd) for the first of gs with a free slot (in the given order), or (None, None) with wait=False. A review may
    run on any non-author GPU, so it never waits on one specific GPU while another is free (Jeffrey, t81u / t83u).
    max_wait (s): give up with (None, None) after that long (a hand-off that cannot start is relaunched, t85u)."""
    gs = [g for g in gs if g in G.GPUS]
    if not gs: raise ValueError("no known GPU to acquire")
    t0 = last = time.monotonic()
    while True:
        for g in gs:
            fd = try_acquire(g)
            if fd is not None: return g, fd
        if not wait or (max_wait is not None and time.monotonic() - t0 >= max_wait): return None, None
        if time.monotonic() - last >= HEARTBEAT_S:
            last = time.monotonic()
            print(f"gpu_gate: waiting for a slot on any of {','.join(gs)} ({int(last - t0)} s)", file=log, flush=True)
        time.sleep(POLL_S)

def held_fd(g, env=None):
    """The slot fd a parent (run-task) took for g and passed down as FACTORY_GPU_SLOT_FD=<gpu>:<fd>, or None."""
    env = os.environ if env is None else env
    gg, _, fd = (env.get("FACTORY_GPU_SLOT_FD") or "").partition(":")
    if gg != g or not fd.isdigit(): return None
    try:
        if os.readlink(f"/proc/self/fd/{fd}").startswith(os.path.join(lock_dir(), f"factory-pi-{g}-slot-")): return int(fd)
    except OSError: pass
    return None

def main(argv):
    if argv[:1] == ["status"]:
        st = {g: {"held": tasks(holders(g)), "cap": c} for g, c in caps().items()}
        print(json.dumps(st) if "--json" in argv else "\n".join(f"{g}: {v['held']}/{v['cap']}" for g, v in st.items()))
        return 0
    if len(argv) < 4 or argv[0] != "hold" or "--" not in argv:
        print(__doc__, file=sys.stderr); return 2
    g, opts, cmd = argv[1], argv[2:argv.index("--")], argv[argv.index("--") + 1:]
    if g not in G.GPUS or not cmd: print(__doc__, file=sys.stderr); return 2
    if held_fd(g) is None:
        fd = acquire(g, wait="--no-wait" not in opts)
        if fd is None: print(f"gpu_gate: {g} is at its cap of {caps()[g]}", file=sys.stderr); return BUSY_EXIT
        os.environ["FACTORY_GPU_SLOT_FD"] = f"{g}:{fd}"
    os.execvp(cmd[0], cmd)

if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
