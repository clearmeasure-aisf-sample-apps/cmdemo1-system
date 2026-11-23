#!/usr/bin/env bash
# Health of the factory's four GPUs (pro5000, pro6000, obs, ts3): one models list each through the proxy, nothing else. No
# warm-up, no completion request, never asks for or loads a model. One line per GPU, then AVAILABLE: <list>. Never
# prints a URL or token. A GPU with missing secrets or no answer is unavailable, not fatal.
#   health.sh [--json] [pro5000|pro6000|obs|ts3 ...]
# Exit codes: 0 at least one GPU healthy, 3 every GPU lacks its secrets, 4 no GPU healthy.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GPU_PY="$HERE/gpu.py"; [[ -f "$GPU_PY" ]] || GPU_PY="$HOME/.local/bin/factory-pi-gpu.py"
exec python3 "$GPU_PY" health "$@"
