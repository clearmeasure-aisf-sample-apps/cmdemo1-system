#!/usr/bin/env python3
"""The factory's four local GPUs behind the token-protected llm-proxy (named Cloudflare tunnels), and the rules
that choose one. Imported by item_loop.py and run-task; run by health.sh and pi-gpu.

    gpu.py health [--json] [GPU ...]   one models list per GPU (never a completion, never a model load); per-GPU lines
    gpu.py env GPU                     shell-safe NAME=VALUE lines pi-gpu needs (url, model, context); never the token

Secrets (values only in the account's secrets, never in a repository, log or comment), per GPU:
    LOCAL_LLM_<GPU>_URL     OpenAI-compatible base URL ending in /v1
    LOCAL_LLM_<GPU>_TOKEN   bearer token of the proxy
for GPU in PRO5000, PRO6000, OBS, TS3. The model is always `auto`: the proxy refuses any other name and is never asked to load
or warm a model. A GPU whose secrets are missing or that does not answer is unavailable, not fatal.
"""
import json, os, re, sys, urllib.error, urllib.request

# Ordered strongest first. ctx = context window Pi is told; slots = Pi tasks at once from this box.
GPUS = {
    "pro5000": {"label": "RTX PRO 5000", "ctx": 262144, "slots": 2, "rank": 0, "note": "Qwen3.8 27B Q6, strongest"},
    "pro6000": {"label": "RTX PRO 6000", "ctx": 262144, "slots": 1, "rank": 1, "note": "Qwen3.8 27B Q8, 96 GB; 1 slot (Jeffrey, 22 Nov 2026)"},
    "obs":     {"label": "RTX 5070 Ti",  "ctx": 65536,  "slots": 1, "rank": 2, "note": "64K context"},
    "ts3":     {"label": "RTX 5060 Ti",  "ctx": 65536,  "slots": 1, "rank": 3, "note": "64K context, slowest"},
}
MODEL = "auto"
LARGE_GPU = "pro5000"                  # default GPU (run-task, plan drafting)
LARGE_GPUS = ("pro5000", "pro6000")    # 262K context: the only GPUs a large item waits for while one is up
SMALL_GPUS = ("obs", "ts3")
PRIORITY = ("pro5000", "pro6000", "obs", "ts3")   # new work goes to the first GPU with a free slot; ts3 (slowest) only when the rest are full
# shortest client timeout for a Pi / model call (a long call hung up at less is a 499). Tests may lower the floor
# with FACTORY_MIN_CLIENT_TIMEOUT_S; production leaves it unset, so the floor stays 300.
MIN_CLIENT_TIMEOUT_S = int(os.environ.get("FACTORY_MIN_CLIENT_TIMEOUT_S", "300"))
# Pi's HTTP idle timeout (httpIdleTimeoutMs) per GPU: 499 client disconnects rose to ~9% (Jeffrey, t89u). pro5000 needs 600 s
# (slow cold prompt reads), every other GPU at least 300 s. Tests lower both floors with FACTORY_MIN_CLIENT_TIMEOUT_S.
PRO5000_MIN_CLIENT_TIMEOUT_S = int(os.environ.get("FACTORY_MIN_CLIENT_TIMEOUT_S", "600"))

def min_client_timeout(g):
    """Shortest client (idle / call) timeout in seconds for GPU g: 600 on pro5000, 300 elsewhere."""
    return PRO5000_MIN_CLIENT_TIMEOUT_S if g == "pro5000" else MIN_CLIENT_TIMEOUT_S

def is_excluded(g, env=None):
    """True when GPU g is reserved away from the factory (FACTORY_GPU_EXCLUDE, set from ~/.config/factory/gpu-exclude)."""
    env = os.environ if env is None else env
    return g in {x.strip().lower() for x in (env.get("FACTORY_GPU_EXCLUDE") or "").split(",") if x.strip()}

def env_names(g):
    u = g.upper(); return f"LOCAL_LLM_{u}_URL", f"LOCAL_LLM_{u}_TOKEN"

def secret_env_names(env=None):
    """Every LOCAL_LLM_*_URL / *_TOKEN name (the factory GPUs and any other in the environment): scrubbed everywhere."""
    env = os.environ if env is None else env
    names = {n for g in GPUS for n in env_names(g)}
    names |= {k for k in env if re.fullmatch(r"LOCAL_LLM_[A-Z0-9]+_(URL|TOKEN)", k)}
    return sorted(names)

def configured(g, env=None):
    env = os.environ if env is None else env
    return all(env.get(n) for n in env_names(g))

def probe(g, env=None, timeout=20, opener=urllib.request.urlopen):
    """(status, detail). status: HEALTHY | MISSING_SECRETS | UNREACHABLE | REFUSED | TUNNEL_DOWN | UNHEALTHY.
    One GET <url>/models; detail never contains the URL or token."""
    env = os.environ if env is None else env
    un, tn = env_names(g)
    if not configured(g, env): return "MISSING_SECRETS", f"{un} and/or {tn} not set"
    req = urllib.request.Request(env[un].rstrip("/") + "/models", headers={"Authorization": f"Bearer {env[tn]}", "User-Agent": "factory-pi-health/1"})   # an explicit UA: the tunnel edge refuses urllib's default
    try:
        with opener(req, timeout=timeout) as r: code, body = r.status, r.read()
    except urllib.error.HTTPError as e: code, body = e.code, b""
    except Exception: return "UNREACHABLE", "no answer (unknown host or timeout)"
    if code in (401, 403): return "REFUSED", f"HTTP {code}: {tn} wrong or rotated"
    if code in (502, 503, 504, 530): return "TUNNEL_DOWN", f"HTTP {code}: tunnel or model server down"
    if code != 200: return "UNHEALTHY", f"HTTP {code}"
    try: models = [m.get("id") for m in json.loads(body).get("data") or [] if m.get("id")]
    except Exception: models = []
    if not models: return "UNHEALTHY", "the proxy lists no loaded model"
    return "HEALTHY", f"serves a loaded model (Pi asks for `{MODEL}`)"

def health(gpus=None, env=None, **kw):
    return {g: probe(g, env, **kw) for g in (gpus or GPUS)}

def available(h):
    return [g for g in GPUS if h.get(g, ("",))[0] == "HEALTHY"]

def health_exit(h):
    """0 when at least one GPU is healthy; 3 when every GPU lacks its secrets; 4 otherwise."""
    if available(h): return 0
    return 3 if all(s == "MISSING_SECRETS" for s, _ in h.values()) else 4

# ---------------------------------------------------------------- choosing a GPU (pure, unit-tested)
LARGE_PATH_RE = re.compile(r"(?i)(^|/)(database|migrations?|infra|octopus|environments)/|\.(csproj|sln|props|targets|sql|bicep)$|"
                           r"(^|/)(Directory\.Build\.|global\.json|nuget\.config|Dockerfile)")
SMALL_PATH_RE = re.compile(r"(?i)(test|spec)s?[/._]|\.(razor|cshtml|css|scss|html|js|ts|tsx|md)$|(^|/)(ui|wwwroot|docs)/")

def classify_size(plan):
    """'large' (big, long-context or cross-cutting: pro5000 / pro6000 only) or 'small' (UI or test items: pro5000, pro6000,
    obs, then ts3). plan['size'] wins."""
    if plan.get("size") in ("large", "small"): return plan["size"]
    files = plan.get("files") or []
    areas = {"/".join(f.split("/")[:2]) for f in files}
    if len(files) > 5 or len(areas) > 2 or len(plan.get("tasks") or []) > 5: return "large"
    if any(LARGE_PATH_RE.search(f) for f in files): return "large"
    if files and all(SMALL_PATH_RE.search(f) for f in files): return "small"
    return "large" if len(files) > 3 else "small"

def pick_gpu(size, up, busy):
    """GPU for a new item, or None to wait. up: healthy GPUs; busy: GPUs with every slot taken (busy_gpus).
    pro5000 first (2 slots, 262K context), then pro6000 (1 slot, 262K), then obs, then ts3 only when the rest are full.
    Large (long-context) items wait for pro5000 / pro6000 while either is up and fall back to obs / ts3 only when both
    are down."""
    free = [g for g in PRIORITY if g in up and g not in busy and not is_excluded(g)]
    if size == "large" and any(g in up and not is_excluded(g) for g in LARGE_GPUS):
        return next((g for g in free if g in LARGE_GPUS), None)
    return free[0] if free else None

def reviewer_gpu(author, up):
    """A different healthy GPU for the independent diff review (strongest first), or None."""
    return next((g for g in GPUS if g in up and g != author), None)

def reviewer_gpus(author, up):
    """Every healthy GPU but the author's, strongest first: the review takes whichever has a free slot first. author is
    one GPU or a list (every GPU that wrote code for the item, relaunches included): none of them may review."""
    authors = {author} if isinstance(author, str) else set(author or ())
    return [g for g in GPUS if g in up and g not in authors]

def main():
    a = sys.argv[1:]
    if not a: print(__doc__); sys.exit(2)
    if a[0] == "health":
        js = "--json" in a; gs = [x for x in a[1:] if x != "--json"]
        bad = [g for g in gs if g not in GPUS]
        if bad: print(f"unknown GPU {bad}; use one of {list(GPUS)}"); sys.exit(2)
        h = health(gs or None)
        if js: print(json.dumps({g: {"status": s, "detail": d} for g, (s, d) in h.items()}))
        else:
            for g, (s, d) in h.items(): print(f"{g} ({GPUS[g]['label']}): {s}: {d}")
            up = available(h)
            print(f"AVAILABLE: {', '.join(up) or 'none'}" + ("" if up else " (ask Jeffrey; never restart or warm a server)"))
        sys.exit(health_exit(h))
    if a[0] == "env" and len(a) == 2 and a[1] in GPUS:
        g = a[1]; un, _ = env_names(g)
        if not configured(g): print(f"MISSING_SECRETS: {' and/or '.join(env_names(g))}", file=sys.stderr); sys.exit(3)
        print(f"GPU_MODEL={MODEL}\nGPU_CTX={GPUS[g]['ctx']}\nGPU_LABEL='{GPUS[g]['label']}'"); sys.exit(0)
    print(__doc__); sys.exit(2)

if __name__ == "__main__": main()
