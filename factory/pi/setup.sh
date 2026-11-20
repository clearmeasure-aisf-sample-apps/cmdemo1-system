#!/usr/bin/env bash
# Idempotent setup of Pi (pi-coding-agent) on the factory bot's Linux box, pointed at the factory's three local GPUs
# through the token-protected llm-proxy (named Cloudflare tunnels). Safe to run on every wake: it only installs or
# rewrites what is missing or different.
#
# Secrets of the Grok Bot account, as environment variables (values never go in a repository, comment, log or chat),
# two per GPU; a GPU whose two are missing is simply unavailable:
#   LOCAL_LLM_PRO5000_URL / LOCAL_LLM_PRO5000_TOKEN   RTX PRO 5000 (strongest, 262K context)
#   LOCAL_LLM_OBS_URL     / LOCAL_LLM_OBS_TOKEN       RTX 5070 Ti (64K context)
#   LOCAL_LLM_TS3_URL     / LOCAL_LLM_TS3_TOKEN       RTX 5060 Ti (64K context, slowest)
# Each URL is the proxy's OpenAI-compatible base URL ending in /v1; Pi always asks for model `auto`.
#
# Installs: Pi into ~/.local (npm prefix); links in ~/.local/bin to this clone: pi-gpu (Pi on one GPU), pi-pro5000
# (shim for `pi-gpu pro5000`), pi-gpu-health and pi-pro5000-health (both health.sh), factory-pi-run-task,
# factory-pi-usage-report, factory-pi-item-loop; the Pi agent dirs ~/.config/local-llm/pi-<gpu>. Ends with the health
# check of all three GPUs (a models list each).
#
# Exit codes: 0 ready (at least one GPU healthy), 3 every GPU lacks its secrets (ask Jeffrey), 4 no GPU answers (ask
# Jeffrey), 1 other.
set -euo pipefail

PI_PACKAGE="@earendil-works/pi-coding-agent"
PI_VERSION="1.5.2"
NODE_MAJOR_MIN=22
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
GPUS=(pro5000 obs ts3)

missing=(); configured=0
for g in "${GPUS[@]}"; do
  u="LOCAL_LLM_${g^^}_URL"; t="LOCAL_LLM_${g^^}_TOKEN"
  if [[ -n "${!u:-}" && -n "${!t:-}" ]]; then configured=$((configured + 1)); else missing+=("$u/$t"); fi
done
if (( configured == 0 )); then
  echo "MISSING_SECRETS: ${missing[*]}"
  echo "Ask Jeffrey to add them as secrets of this Grok Bot account (names exactly as above)."
  exit 3
fi
(( ${#missing[@]} )) && echo "Not configured (those GPUs stay unavailable): ${missing[*]}"

# Node.js (Pi needs a current Node). Install through nvm into $HOME when absent or too old; never with sudo.
node_ok() { command -v node >/dev/null && (( $(node -p 'process.versions.node.split(".")[0]') >= NODE_MAJOR_MIN )); }
if ! node_ok; then
  export NVM_DIR="$HOME/.nvm"
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash >/dev/null
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install 24 >/dev/null
  nvm alias default 24 >/dev/null
fi
node_ok || { echo "Node.js >= $NODE_MAJOR_MIN not available"; exit 1; }

mkdir -p "$BIN"
for g in "${GPUS[@]}"; do mkdir -p "$HOME/.config/local-llm/pi-$g/sessions"; done
case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH" ;; esac
grep -qs 'HOME/.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

# Pi, pinned to the version proven on the RTX Pro 5000.
have="$( (pi --version 2>/dev/null || true) | tail -1 )"
if [[ "$have" != "$PI_VERSION" ]]; then
  npm install -g --prefix "$HOME/.local" --no-fund --no-audit --loglevel=error "$PI_PACKAGE@$PI_VERSION" >/dev/null
fi
[[ "$(pi --version | tail -1)" == "$PI_VERSION" ]] || { echo "Pi $PI_VERSION did not install"; exit 1; }

# Agent dirs. models.json is written by pi-gpu on each run from the environment (so a new tunnel URL needs only the
# secret updated), so here only the files that hold no value.
for g in "${GPUS[@]}"; do
  d="$HOME/.config/local-llm/pi-$g"
  [[ -f "$d/auth.json" ]] || echo '{}' > "$d/auth.json"
  [[ -f "$d/models-store.json" ]] || echo '{}' > "$d/models-store.json"
  chmod 600 "$d/auth.json" "$d/models-store.json"
done

# The tools run from this clone (they read gpu.py next to them), so link rather than copy; gpu.py is also copied as a
# fallback for a copied tool.
chmod 755 "$HERE/pi-gpu" "$HERE/pi-pro5000" "$HERE/health.sh" "$HERE/run-task" "$HERE/usage-report" "$HERE/item-loop" "$HERE/gpu.py"
install -m 644 "$HERE/gpu.py" "$BIN/factory-pi-gpu.py"
ln -sfn "$HERE/pi-gpu" "$BIN/pi-gpu"
ln -sfn "$HERE/pi-pro5000" "$BIN/pi-pro5000"
ln -sfn "$HERE/health.sh" "$BIN/pi-gpu-health"
ln -sfn "$HERE/health.sh" "$BIN/pi-pro5000-health"
ln -sfn "$HERE/run-task" "$BIN/factory-pi-run-task"
ln -sfn "$HERE/usage-report" "$BIN/factory-pi-usage-report"
ln -sfn "$HERE/item-loop" "$BIN/factory-pi-item-loop"

echo "Pi $(pi --version | tail -1) installed; wrapper $BIN/pi-gpu <pro5000|obs|ts3>"
exec "$HERE/health.sh"
