#!/usr/bin/env bash
# Apply Handy post-process settings: backup current, merge patch, restart Handy.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HANDY_SETTINGS="$HOME/Library/Application Support/com.pais.handy/settings_store.json"
PATCH_FILE="$PROJECT_ROOT/handy-settings/settings.patch.json"
BACKUP_DIR="$PROJECT_ROOT/handy-settings/backups"
HANDY_CLEAN_PATH="$PROJECT_ROOT/bin/handy-clean"

if [ ! -f "$HANDY_SETTINGS" ]; then
    echo "ERROR: Handy settings not found at $HANDY_SETTINGS" >&2
    echo "Make sure Handy is installed and ran at least once." >&2
    exit 1
fi

if [ ! -x "$HANDY_CLEAN_PATH" ]; then
    echo "ERROR: $HANDY_CLEAN_PATH is not executable" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
TS="$(date -u +%Y%m%d-%H%M%S)"
cp "$HANDY_SETTINGS" "$BACKUP_DIR/settings_store-$TS.json"
echo "Backup: $BACKUP_DIR/settings_store-$TS.json"

# Quit Handy if running.
osascript -e 'tell application "Handy" to quit' 2>/dev/null || true
sleep 1

HANDY_SETTINGS_PATH="$HANDY_SETTINGS" \
PATCH_PATH="$PATCH_FILE" \
CLEAN_PATH="$HANDY_CLEAN_PATH" \
python3 <<'PY'
import json, os, sys, tempfile

settings_path = os.environ["HANDY_SETTINGS_PATH"]
patch_path = os.environ["PATCH_PATH"]
clean_path = os.environ["CLEAN_PATH"]

with open(settings_path, encoding="utf-8") as f:
    settings = json.load(f)
with open(patch_path, encoding="utf-8") as f:
    patch = json.load(f)

def deep_merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            deep_merge(dst[k], v)
        else:
            dst[k] = v

def substitute(obj):
    if isinstance(obj, dict):
        return {k: substitute(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [substitute(x) for x in obj]
    if isinstance(obj, str):
        return obj.replace("__HANDY_CLEAN_PATH__", clean_path)
    return obj

patch = substitute(patch)

# Validate that the schema we expect is present BEFORE writing. Handy's
# settings_store.json structure changes between versions; if the keys we
# need are missing, abort cleanly so the user gets a real error instead
# of a half-merged file.
required_paths = [
    ("settings", "bindings", "transcribe", "current_binding"),
    ("settings", "bindings", "transcribe_with_post_process", "current_binding"),
    ("settings", "post_process_enabled"),
]
for path in required_paths:
    cur = settings
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            sys.exit(
                f"ERROR: required key {'.'.join(path)} missing from settings_store.json. "
                f"Your Handy version may be incompatible with this patch. "
                f"Backup is preserved; settings file unchanged."
            )
        cur = cur[k]

deep_merge(settings, patch)

# Atomic write: tempfile in same dir, then rename. A crash mid-write
# leaves the original settings_store.json intact (otherwise the truncated
# `open(..., 'w')` at the start of dump would corrupt Handy's config).
dst_dir = os.path.dirname(settings_path)
fd, tmp = tempfile.mkstemp(dir=dst_dir, prefix=".settings_store.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
    os.replace(tmp, settings_path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise

print("Applied patch:")
print("  external_script_path =", clean_path)
print("  transcribe           =", settings["settings"]["bindings"]["transcribe"]["current_binding"])
print("  transcribe+post-proc =", settings["settings"]["bindings"]["transcribe_with_post_process"]["current_binding"])
print("  post_process_enabled =", settings["settings"]["post_process_enabled"])
PY

open -a Handy
echo ""
echo "Handy restarted. Verify in Handy → Settings → Bindings:"
echo "  Transcribe                          = option+shift+space"
echo "  Transcribe with Post-Processing     = option+space"
