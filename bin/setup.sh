#!/usr/bin/env bash
# Interactive setup wizard for handy-companion.
# - prompts for the Gemini API key and saves it to macOS Keychain
# - applies the Handy settings patch (paste_method, hotkey, external_script_path)
# - prints the Hammerspoon snippet for the user to add to ~/.hammerspoon/init.lua

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN_SERVICE="${GEMINI_KEYCHAIN_SERVICE:-handy-companion-gemini}"

echo "═══════════════════════════════════════════════════════════════════"
echo "  handy-companion setup"
echo "═══════════════════════════════════════════════════════════════════"
echo

# ─── Dependency check ──────────────────────────────────────────────────────
missing=()
for cmd in jq curl python3 osascript security; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1 || missing+=("gtimeout (brew install coreutils)")

if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: missing dependencies: ${missing[*]}" >&2
    echo "Install with: brew install jq coreutils" >&2
    exit 1
fi
echo "✓ Dependencies OK (jq, curl, python3, osascript, security, gtimeout)"
echo

# ─── Gemini API key ────────────────────────────────────────────────────────
existing_key="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
if [ -n "$existing_key" ]; then
    echo "✓ Gemini API key already in Keychain (service: $KEYCHAIN_SERVICE)"
    printf "  Replace it? [y/N]: "
    read -r ans
    if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
        echo "  Keeping existing key."
    else
        existing_key=""
    fi
fi

if [ -z "$existing_key" ]; then
    echo
    echo "  Get a free Gemini API key here: https://aistudio.google.com/apikey"
    printf "  Paste your Gemini API key (input hidden): "
    stty -echo
    read -r api_key
    stty echo
    echo
    if [ -z "$api_key" ]; then
        echo "ERROR: empty key, aborting." >&2
        exit 1
    fi
    # -A allows all applications to read; needed because Hammerspoon and Handy
    # children inherit a different "responsible app" than the terminal that
    # added the item.
    security add-generic-password -U -A -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$api_key"
    echo "✓ Stored in Keychain as service '$KEYCHAIN_SERVICE'"
fi
echo

# ─── Handy settings patch ──────────────────────────────────────────────────
HANDY_SETTINGS="$HOME/Library/Application Support/com.pais.handy/settings_store.json"
if [ ! -f "$HANDY_SETTINGS" ]; then
    echo "⚠  Handy settings file not found at:"
    echo "   $HANDY_SETTINGS"
    echo "   Install Handy from https://github.com/cjpais/Handy and run it once,"
    echo "   then re-run this setup."
    echo "   (Skipping Handy patch for now.)"
else
    echo "Apply Handy settings patch?"
    echo "  This will:"
    echo "    - back up settings_store.json"
    echo "    - set paste_method = external_script"
    echo "    - set external_script_path = $PROJECT_ROOT/bin/handy-clean"
    echo "    - set bindings.transcribe_with_post_process = option+space"
    echo "    - set bindings.transcribe = option+shift+space (raw, no LLM)"
    echo "    - restart Handy"
    printf "  Apply now? [Y/n]: "
    read -r ans
    if [ -z "$ans" ] || [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        bash "$PROJECT_ROOT/handy-settings/apply.sh"
    else
        echo "  Skipped. Run it manually later: bash handy-settings/apply.sh"
    fi
fi
echo

# ─── Hammerspoon snippet ───────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  Hammerspoon (optional, for Heavy / Heavy Pro modes)"
echo "═══════════════════════════════════════════════════════════════════"
echo
echo "Add this to ~/.hammerspoon/init.lua and reload Hammerspoon:"
echo
cat <<EOF
-- handy-companion: Heavy (×× Ctrl) and Heavy Pro (××× Ctrl)
require("hs.ipc")
hs.allowAppleScript(true)

-- Tell Hammerspoon where the Heavy script lives. Adjust to your install path.
os.setenv("HANDY_COMPANION_HEAVY", "$PROJECT_ROOT/bin/handy-heavy")

dofile("$PROJECT_ROOT/hammerspoon/handy-heavy.lua")
EOF
echo
echo "Then either restart Hammerspoon or run this once to reload it now:"
echo
echo "  osascript -e 'tell application \"Hammerspoon\" to execute lua code \"hs.reload()\"'"
echo
echo "═══════════════════════════════════════════════════════════════════"
echo "  Setup complete."
echo "═══════════════════════════════════════════════════════════════════"
echo "Test: press ⌥Space, dictate something, watch the cleaned text paste in."
echo
