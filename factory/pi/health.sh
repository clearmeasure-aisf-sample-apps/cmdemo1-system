#!/usr/bin/env bash
# Health check of the RTX Pro 5000 proxy: one models list, nothing else. No warm-up, no completion request, never
# asks for a model. Prints the model the server has loaded (the only one Pi may use) and never prints the URL or token.
# Exit codes: 0 healthy, 3 a secret is missing, 4 unreachable / refused / no model loaded.
set -uo pipefail
[[ -n "${LOCAL_LLM_PRO5000_URL:-}" && -n "${LOCAL_LLM_PRO5000_TOKEN:-}" ]] || {
  echo "MISSING_SECRETS: LOCAL_LLM_PRO5000_URL and/or LOCAL_LLM_PRO5000_TOKEN"; exit 3; }
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
code="$(curl -sS -m 20 -o "$body" -w '%{http_code}' \
  -H "Authorization: Bearer $LOCAL_LLM_PRO5000_TOKEN" "${LOCAL_LLM_PRO5000_URL%/}/models" 2>/dev/null)" || code="000"
case "$code" in
  200) ;;
  000) echo "UNREACHABLE: no answer from the proxy (unknown host or timeout). The tunnel URL has probably changed; ask Jeffrey for the new LOCAL_LLM_PRO5000_URL. Do not guess a URL."; exit 4 ;;
  401|403) echo "REFUSED: HTTP $code from the proxy. LOCAL_LLM_PRO5000_TOKEN is wrong or rotated; ask Jeffrey."; exit 4 ;;
  502|503|504|530) echo "TUNNEL_DOWN: HTTP $code. The tunnel or the model server is down, or the tunnel URL changed; ask Jeffrey. Do not restart anything."; exit 4 ;;
  *) echo "UNHEALTHY: HTTP $code from the proxy; ask Jeffrey."; exit 4 ;;
esac
model="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("data") or [{}])[0].get("id",""))' "$body" 2>/dev/null)"
[[ -n "$model" ]] || { echo "UNHEALTHY: the proxy lists no loaded model; ask Jeffrey."; exit 4; }
echo "HEALTHY: RTX Pro 5000 proxy serves model $model"
