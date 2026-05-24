#!/usr/bin/env bash
# Switch Handy to its built-in post-processing pipeline pointed at Gemini's
# OpenAI-compatible endpoint. This is an ALTERNATIVE to the external_script
# path that ships by default with this repo — see README "External script
# vs Handy built-in" for the trade-offs.
#
# What this does:
#   1. Backs up your current Handy settings (handy-settings/backups/...)
#   2. Sets paste_method=ctrl_v (Handy's native clipboard paste — one atomic
#      Cmd+V, no per-character key synthesis). Do NOT use "direct" here: on
#      macOS it routes to enigo.text(), which injects Unicode characters one
#      keystroke at a time and reorders/drops them under load. The visible
#      symptom is mid-word characters getting relocated to the end of the
#      pasted text — worse on long, Cyrillic dictation.
#   3. Configures Handy's "Custom" post-process provider to point at
#      https://generativelanguage.googleapis.com/v1beta/openai/ with the
#      Gemini API key from your macOS Keychain
#   4. Inserts the cleanup prompt — picks prompts/medium.local.txt if you
#      have one, otherwise prompts/medium.txt
#   5. Restarts Handy
#
# Trade-off you accept by running this:
#   - No fallback chain (Gemini fails / quota → raw Whisper, no Ollama/Claude)
#   - No multi-key Keychain fallback (Handy only knows one key per provider)
#   - No custom logs/medium-*.log (Handy has its own internal log at
#     ~/Library/Logs/com.pais.handy/handy.log)
#
# To switch BACK to the external_script path, re-run `bash handy-settings/apply.sh`.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HANDY_SETTINGS="$HOME/Library/Application Support/com.pais.handy/settings_store.json"
BACKUP_DIR="$PROJECT_ROOT/handy-settings/backups"
PROMPT_DIR="$PROJECT_ROOT/prompts"

# Pick the most-personalized prompt available.
PROMPT_FILE="$PROMPT_DIR/medium.txt"
if [ -f "$PROMPT_DIR/medium.local.txt" ]; then
    PROMPT_FILE="$PROMPT_DIR/medium.local.txt"
fi

if [ ! -f "$HANDY_SETTINGS" ]; then
    echo "ERROR: Handy settings not found at $HANDY_SETTINGS" >&2
    echo "Make sure Handy is installed and ran at least once." >&2
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: prompt not found at $PROMPT_FILE" >&2
    exit 1
fi

# Match the same Keychain slot the rest of the repo uses.
GEMINI_KEYCHAIN_SERVICE="${GEMINI_KEYCHAIN_SERVICE:-handy-companion-gemini}"
GEMINI_KEYCHAIN_SERVICE_LEGACY="handy-claude-gemini"

API_KEY="$(security find-generic-password -a "$USER" -s "$GEMINI_KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
if [ -z "$API_KEY" ]; then
    API_KEY="$(security find-generic-password -a "$USER" -s "$GEMINI_KEYCHAIN_SERVICE_LEGACY" -w 2>/dev/null || true)"
fi
if [ -z "$API_KEY" ]; then
    echo "ERROR: no Gemini API key in Keychain (tried $GEMINI_KEYCHAIN_SERVICE and $GEMINI_KEYCHAIN_SERVICE_LEGACY)" >&2
    echo "Add one with: security add-generic-password -U -A -a \"\$USER\" -s $GEMINI_KEYCHAIN_SERVICE -w 'YOUR_KEY'" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
TS="$(date -u +%Y%m%d-%H%M%S)"
cp "$HANDY_SETTINGS" "$BACKUP_DIR/settings_store-$TS-pre-builtin-llm.json"
echo "Backup: $BACKUP_DIR/settings_store-$TS-pre-builtin-llm.json"

# Quit Handy so it doesn't overwrite our changes on next save.
osascript -e 'tell application "Handy" to quit' >/dev/null 2>&1 || true
sleep 1

PROMPT_BODY="$(cat "$PROMPT_FILE")"
# Handy interpolates ${output} with the raw Whisper transcript at request
# build time, so append it after our prompt's "Transcript:" line.
PROMPT_FULL="$PROMPT_BODY"$'\n${output}'

HANDY_SETTINGS="$HANDY_SETTINGS" API_KEY="$API_KEY" PROMPT_FULL="$PROMPT_FULL" \
python3 <<'PY'
import json, os, sys, tempfile

p = os.environ["HANDY_SETTINGS"]
key = os.environ["API_KEY"]
prompt = os.environ["PROMPT_FULL"]

with open(p, encoding="utf-8") as f:
    s = json.load(f)

S = s["settings"]

# Schema sanity: Handy's settings layout changes between versions. If the
# keys we need are missing, abort cleanly rather than write a half-broken
# config. The backup is already taken.
required = ["paste_method", "post_process_enabled", "post_process_provider_id",
            "post_process_api_keys", "post_process_models", "post_process_providers",
            "post_process_prompts", "post_process_selected_prompt_id"]
missing = [k for k in required if k not in S]
if missing:
    sys.exit(f"ERROR: Handy settings missing expected keys: {missing}. "
             f"Your Handy version may be incompatible with this script.")

S["paste_method"] = "ctrl_v"
S["post_process_enabled"] = True
S["post_process_provider_id"] = "custom"
S["post_process_api_keys"]["custom"] = key
S["post_process_models"]["custom"] = "gemini-2.5-flash-lite"

# Point the Custom provider at Gemini's OpenAI-compatible endpoint.
for prov in S["post_process_providers"]:
    if prov["id"] == "custom":
        prov["base_url"] = "https://generativelanguage.googleapis.com/v1beta/openai/"
        break
else:
    sys.exit("ERROR: 'custom' provider not found in post_process_providers.")

# Add or replace our cleanup prompt (idempotent — safe to re-run).
new_id = "handy_companion_slim_ru_en"
S["post_process_prompts"] = [p for p in S["post_process_prompts"] if p.get("id") != new_id]
S["post_process_prompts"].append({
    "id": new_id,
    "name": "handy-companion cleanup",
    "prompt": prompt,
})
S["post_process_selected_prompt_id"] = new_id

# Atomic write: tempfile in same dir, then rename. A crash mid-write leaves
# the original settings_store.json intact.
dst_dir = os.path.dirname(p)
fd, tmp = tempfile.mkstemp(dir=dst_dir, prefix=".settings_store.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False, indent=2)
    os.replace(tmp, p)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

print("Applied:")
print("  paste_method               =", S["paste_method"])
print("  post_process_enabled       =", S["post_process_enabled"])
print("  post_process_provider_id   =", S["post_process_provider_id"])
print("  custom model               =", S["post_process_models"]["custom"])
print("  custom base_url            =", next(p["base_url"] for p in S["post_process_providers"] if p["id"]=="custom"))
print("  selected_prompt_id         =", S["post_process_selected_prompt_id"])
print(f"  prompt source              = {len(prompt)} chars")
PY

open -a Handy
echo ""
echo "Handy restarted. Verify in Handy → Settings → Post-processing:"
echo "  Provider = Custom (Gemini OpenAI-compat)"
echo "  Model    = gemini-2.5-flash-lite"
echo "  Prompt   = handy-companion cleanup"
echo ""
echo "Test with ⌥Space on a short dictation including filler words and brand"
echo "names. If Gemini is unreachable (quota, network) Handy falls back to"
echo "raw Whisper output automatically — see ~/Library/Logs/com.pais.handy/handy.log"
