#!/usr/bin/env bash
# Idempotent setup of Pi (pi-coding-agent) on the factory bot's Linux box, pointed at the RTX Pro 5000 through the
# proxy. Safe to run on every wake: it only installs or rewrites what is missing or different.
#
# Needs two secrets of the Grok Bot account, as environment variables (values never go in a repository, comment,
# log or chat):
#   LOCAL_LLM_PRO5000_URL    OpenAI-compatible base URL of the proxy, ending in /v1
#   LOCAL_LLM_PRO5000_TOKEN  bearer token of the proxy
#
# Installs: Pi into ~/.local (npm prefix), the wrapper ~/.local/bin/pi-pro5000, factory/pi/run-task and
# factory/pi/usage-report into ~/.local/bin, and the Pi agent dir ~/.config/local-llm/pi-pro5000. Ends with the
# health check (a models list only).
#
# Exit codes: 0 ready, 3 a secret is missing (ask Jeffrey), 4 proxy unreachable or refused (ask Jeffrey), 1 other.
set -euo pipefail

PI_PACKAGE="@earendil-works/pi-coding-agent"
PI_VERSION="1.5.2"
NODE_MAJOR_MIN=22
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
AGENT_DIR="$HOME/.config/local-llm/pi-pro5000"

missing=()
[[ -n "${LOCAL_LLM_PRO5000_URL:-}" ]] || missing+=(LOCAL_LLM_PRO5000_URL)
[[ -n "${LOCAL_LLM_PRO5000_TOKEN:-}" ]] || missing+=(LOCAL_LLM_PRO5000_TOKEN)
if (( ${#missing[@]} )); then
  echo "MISSING_SECRETS: ${missing[*]}"
  echo "Ask Jeffrey to add them as secrets of this Grok Bot account (names exactly as above)."
  exit 3
fi

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

mkdir -p "$BIN" "$AGENT_DIR/sessions"
case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH" ;; esac
grep -qs 'HOME/.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

# Pi, pinned to the version proven on the RTX Pro 5000.
have="$( (pi --version 2>/dev/null || true) | tail -1 )"
if [[ "$have" != "$PI_VERSION" ]]; then
  npm install -g --prefix "$HOME/.local" --no-fund --no-audit --loglevel=error "$PI_PACKAGE@$PI_VERSION" >/dev/null
fi
[[ "$(pi --version | tail -1)" == "$PI_VERSION" ]] || { echo "Pi $PI_VERSION did not install"; exit 1; }

# Agent dir. models.json is written by the wrapper on each run from the environment (so a new tunnel URL needs only
# the secret updated), so here only the files that hold no value.
[[ -f "$AGENT_DIR/auth.json" ]] || echo '{}' > "$AGENT_DIR/auth.json"
[[ -f "$AGENT_DIR/models-store.json" ]] || echo '{}' > "$AGENT_DIR/models-store.json"
chmod 600 "$AGENT_DIR/auth.json" "$AGENT_DIR/models-store.json"

install -m 755 "$HERE/pi-pro5000" "$BIN/pi-pro5000"
install -m 755 "$HERE/run-task" "$BIN/factory-pi-run-task"
install -m 755 "$HERE/usage-report" "$BIN/factory-pi-usage-report"
install -m 755 "$HERE/health.sh" "$BIN/pi-pro5000-health"

echo "Pi $(pi --version | tail -1) installed; wrapper $BIN/pi-pro5000"
exec "$HERE/health.sh"
