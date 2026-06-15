#!/usr/bin/env bash
# Delegate a prompt to a local Ollama model (cost-asymmetry: cheap local models
# do the routine; the expensive path stays rare). Claude reviews the output
# before integrating — no silent merge (see tmp/tasks/README.md).
#
# Usage:
#   scripts/ollama_ask.sh MODEL [PROMPT_FILE]      # prompt from file or stdin
#   echo "draft X" | scripts/ollama_ask.sh qwen3-coder:30b
# Env: OLLAMA_BASE_URL (default http://localhost:11434), OLLAMA_TEMP (default 0.2).
set -euo pipefail

model="${1:?usage: ollama_ask.sh MODEL [PROMPT_FILE]}"
prompt_src="${2:-/dev/stdin}"
base="${OLLAMA_BASE_URL:-http://localhost:11434}"
temp="${OLLAMA_TEMP:-0.2}"

prompt="$(cat "$prompt_src")"

python3 - "$base" "$model" "$temp" "$prompt" <<'PY'
import json, sys, urllib.request

base, model, temp, prompt = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
payload = {
    "model": model,
    "prompt": prompt,
    "stream": False,
    "options": {"temperature": temp},
}
req = urllib.request.Request(
    base + "/api/generate",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=900) as resp:
    body = json.load(resp)
sys.stdout.write(body.get("response", ""))
PY
