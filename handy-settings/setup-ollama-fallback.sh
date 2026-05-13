#!/usr/bin/env bash
# One-shot setup for the Ollama fallback tier: pulls a small multilingual
# model, bakes the cleanup prompt into a custom Modelfile, registers it
# under a stable name, and prints the env-var snippet for activating the
# Ollama tier in handy-companion's chain.
#
# Why baked prompt (Modelfile) rather than passing prompt per call?
# A multi-KB system prompt dominates prefill latency on small models —
# baking it removes that work from every call. Empirically: ~67% faster
# on short inputs, ~38% on medium, negligible on long. See the
# "Local-only with Ollama" section of the README for the full bench.
#
# Default model is gemma4:e2b (2.3B effective parameters, ~7.2 GB on
# disk, multilingual, native /api/chat doesn't engage thinking unless
# the prompt includes <|think|> — none of ours do, so it's off). On
# our bench this was the only sub-billion-effective-params model that
# actually followed multi-KB instructions rather than echoing input
# verbatim. Override with the OLLAMA_BASE_MODEL env var.

set -euo pipefail

OLLAMA_BASE_MODEL="${OLLAMA_BASE_MODEL:-gemma4:e2b}"
HANDY_MODEL_NAME="${HANDY_MODEL_NAME:-handy-medium}"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT_DIR="$PROJECT_ROOT/prompts"

# Prefer the user's local overlay (with their stack dictionary, etc.),
# fall back to the shipped default. Mirrors what bin/handy-clean and
# bin/handy-heavy do at runtime.
PROMPT_FILE="$PROMPT_DIR/medium.txt"
if [ -f "$PROMPT_DIR/medium.local.txt" ]; then
    PROMPT_FILE="$PROMPT_DIR/medium.local.txt"
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: prompt not found at $PROMPT_FILE" >&2
    exit 1
fi

if ! command -v ollama >/dev/null 2>&1; then
    echo "ERROR: ollama not on PATH." >&2
    echo "Install with: brew install ollama && brew services start ollama" >&2
    exit 1
fi

# Make sure the daemon is up before we hit the API.
if ! curl -sS --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "ERROR: Ollama daemon not responding on http://localhost:11434" >&2
    echo "Start it with: brew services start ollama  (or: ollama serve &)" >&2
    exit 1
fi

# Sanity-check: the prompt cannot contain triple-double-quotes, because
# Modelfile's SYSTEM """...""" syntax doesn't escape them. Bail cleanly.
if grep -q '"""' "$PROMPT_FILE"; then
    echo "ERROR: prompt contains triple-quote sequences which can't be" >&2
    echo "embedded in a Modelfile SYSTEM block. File: $PROMPT_FILE" >&2
    exit 1
fi

echo "1. Pulling base model: $OLLAMA_BASE_MODEL"
ollama pull "$OLLAMA_BASE_MODEL"

echo
echo "2. Building Modelfile from $PROMPT_FILE"
MODELFILE_TMP="$(mktemp -t handy-modelfile.XXXXXX)"
trap 'rm -f "$MODELFILE_TMP"' EXIT

# Heredoc would interpolate; use python for clean string handling.
PROMPT_PATH="$PROMPT_FILE" BASE_MODEL="$OLLAMA_BASE_MODEL" \
    OUT_PATH="$MODELFILE_TMP" python3 - <<'PY'
import os
prompt = open(os.environ["PROMPT_PATH"], encoding="utf-8").read()
modelfile = (
    f"FROM {os.environ['BASE_MODEL']}\n\n"
    f'SYSTEM """{prompt}"""\n\n'
    "PARAMETER temperature 0.2\n"
    "PARAMETER num_predict 2048\n"
)
open(os.environ["OUT_PATH"], "w", encoding="utf-8").write(modelfile)
print(f"   wrote {len(modelfile)} chars")
PY

echo
echo "3. Creating $HANDY_MODEL_NAME in Ollama"
ollama create "$HANDY_MODEL_NAME" -f "$MODELFILE_TMP"

echo
echo "4. Smoke test"
warmup_out="$(curl -sS --max-time 30 http://localhost:11434/api/chat \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg m "$HANDY_MODEL_NAME" '{
        model: $m,
        messages: [{role:"user", content:"Test message with um filler words."}],
        stream: false,
        think: false,
        options: {temperature: 0.2}
    }')" | jq -r '.message.content // empty')"
if [ -z "$warmup_out" ]; then
    echo "   WARN: smoke test returned empty response. Model might not be loaded yet." >&2
else
    echo "   OK: model responded ($(printf '%s' "$warmup_out" | wc -c | tr -d ' ') chars)"
fi

cat <<EOF

================================================================
Done. Model '$HANDY_MODEL_NAME' is registered in Ollama and ready.

To activate as a fallback tier in handy-companion's chain (after the
Gemini API tiers, before Claude CLI), add to your shell profile:

  export HANDY_OLLAMA_HOST=http://localhost:11434
  export HANDY_OLLAMA_MODEL=$HANDY_MODEL_NAME

Or, to use it from Handy's built-in post-processing directly (instead
of the external_script path), point Handy → Settings → Post-processing
at: Provider Custom, Base URL http://localhost:11434/v1, Model
$HANDY_MODEL_NAME, Prompt \${output}. (The system prompt is baked
into the model, so just \${output} is enough.)

To rebuild after editing prompts/medium.local.txt, re-run this script.
To remove: ollama rm $HANDY_MODEL_NAME
================================================================
EOF
