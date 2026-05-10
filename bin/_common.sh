#!/usr/bin/env bash
# Shared helpers for handy-clean and handy-heavy. Sourced, not executed.

set -uo pipefail

# Augment PATH so common install locations of claude/curl/jq/timeout are
# reachable when launched from Hammerspoon or Handy (which inherit a minimal
# environment from launchd). We APPEND, not replace — users with bun/volta/
# mise/asdf/fnm/etc. keep their existing tooling.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/Library/pnpm:$HOME/.npm-global/bin"

# UTF-8 locale: Hammerspoon and Handy launch the script without LANG, so
# pbpaste/pbcopy fall back to the legacy single-byte encoding implied by
# __CF_USER_TEXT_ENCODING and corrupt every non-ASCII round-trip.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
PROMPTS_DIR="$PROJECT_ROOT/prompts"
# Per-user sandbox: $TMPDIR on macOS is per-user (/var/folders/...), so this
# can't be hijacked by another user creating /tmp/handy-companion-sandbox first.
SANDBOX_DIR="${TMPDIR:-/tmp}/handy-companion-sandbox-$(id -u)"
CLAUDE_TIMEOUT_SEC="30"
GEMINI_TIMEOUT_SEC="8"
# Default model when caller doesn't specify one. handy-clean and handy-heavy
# pass their own (haiku for Medium, sonnet for Heavy) plus a backup model.
CLAUDE_MODEL_DEFAULT="sonnet"
# Gemini API key lives in macOS Keychain under this service name.
# Stored once via: security add-generic-password -U -A -a "$USER" -s handy-companion-gemini -w '<KEY>'
# (Legacy service name "handy-claude-gemini" is also accepted as fallback.)
GEMINI_KEYCHAIN_SERVICE="${GEMINI_KEYCHAIN_SERVICE:-handy-companion-gemini}"
GEMINI_KEYCHAIN_SERVICE_LEGACY="handy-claude-gemini"

# Optional Ollama provider (purely opt-in: empty = tier silently skipped).
# Set in shell profile or ~/.handy-companion/config.sh before invoking the
# scripts. Example:
#   export HANDY_OLLAMA_HOST="http://localhost:11434"
#   export HANDY_OLLAMA_MODEL="qwen2.5:3b"
HANDY_OLLAMA_HOST="${HANDY_OLLAMA_HOST:-}"
HANDY_OLLAMA_MODEL="${HANDY_OLLAMA_MODEL:-}"
OLLAMA_TIMEOUT_SEC="${OLLAMA_TIMEOUT_SEC:-15}"

mkdir -p "$LOG_DIR" "$SANDBOX_DIR"
chmod 700 "$SANDBOX_DIR" 2>/dev/null || true

find_claude() {
    command -v claude || true
}

# macOS has no built-in `timeout`; coreutils provides `gtimeout`.
# Fall back to direct exec if neither is available (no time-out guard).
find_timeout() {
    command -v gtimeout || command -v timeout || true
}

notify() {
    # Escape backslashes and double-quotes so dynamic title/body cannot inject
    # AppleScript. All current callers pass literals, but escape defensively.
    local title="${1//\\/\\\\}"
    title="${title//\"/\\\"}"
    local body="${2//\\/\\\\}"
    body="${body//\"/\\\"}"
    osascript -e "display notification \"$body\" with title \"$title\"" >/dev/null 2>&1 || true
}

log_run() {
    local mode="$1"  # medium | heavy
    local input="$2"
    local output="$3"
    local exit_code="$4"
    local latency_ms="$5"
    local model="${6:-$CLAUDE_MODEL_DEFAULT}"
    local attempt="${7:-primary}"  # primary | backup
    local ts
    ts="$(date -u +%Y%m%d-%H%M%S-%N)"
    local log_file="$LOG_DIR/${mode}-${ts}.log"

    INPUT="$input" OUTPUT="$output" \
    TS="$ts" MODE="$mode" MODEL="$model" ATTEMPT="$attempt" \
    EXIT_CODE="$exit_code" LATENCY_MS="$latency_ms" \
    python3 -c '
import json, os
data = {
    "ts": os.environ["TS"],
    "mode": os.environ["MODE"],
    "model": os.environ["MODEL"],
    "attempt": os.environ["ATTEMPT"],
    "input_len": len(os.environ["INPUT"]),
    "output_len": len(os.environ["OUTPUT"]),
    "input_first_200": os.environ["INPUT"][:200],
    "output_first_200": os.environ["OUTPUT"][:200],
    "latency_ms": int(os.environ["LATENCY_MS"]),
    "exit_code": int(os.environ["EXIT_CODE"]),
}
print(json.dumps(data, ensure_ascii=False))
' > "$log_file"
    truncate_logs
}

# Keep last 50 per-call logs total (across all modes). The *-debug.log files
# (gemini-debug.log, ollama-debug.log) are append-only diagnostics and must
# NOT be trimmed by this rotation, so we only match the per-call pattern
# `<mode>-<timestamp>.log` here.
truncate_logs() {
    local count
    count=$(ls -1 "$LOG_DIR"/medium-*.log "$LOG_DIR"/heavy-*.log "$LOG_DIR"/heavy-pro-*.log 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 50 ]; then
        ls -1t "$LOG_DIR"/medium-*.log "$LOG_DIR"/heavy-*.log "$LOG_DIR"/heavy-pro-*.log 2>/dev/null \
            | tail -n +51 | xargs rm -f
    fi
}

# Internal: invoke Google Gemini API directly via curl. Echoes generated text
# on success (return 0); returns 1 on any failure. Failure reasons (HTTP
# status, error.message, finishReason, body excerpt) are appended to
# logs/gemini-debug.log so we can post-mortem.
_invoke_gemini_api() {
    local model="$1"
    local prompt_file="$2"
    local input="$3"
    local debug_log="$LOG_DIR/gemini-debug.log"
    local ts
    ts="$(date -u +%FT%TZ)"

    local api_key
    api_key="$(security find-generic-password -a "$USER" -s "$GEMINI_KEYCHAIN_SERVICE" -w 2>/dev/null || true)"
    if [ -z "$api_key" ]; then
        api_key="$(security find-generic-password -a "$USER" -s "$GEMINI_KEYCHAIN_SERVICE_LEGACY" -w 2>/dev/null || true)"
    fi
    if [ -z "$api_key" ]; then
        echo "$ts [FAIL] $model: no API key in Keychain ($GEMINI_KEYCHAIN_SERVICE or legacy $GEMINI_KEYCHAIN_SERVICE_LEGACY)" >> "$debug_log"
        return 1
    fi

    local sys_prompt
    sys_prompt="$(cat "$prompt_file" 2>/dev/null)" || {
        echo "$ts [FAIL] $model: cannot read prompt $prompt_file" >> "$debug_log"
        return 1
    }

    local body
    body="$(jq -n --arg sys "$sys_prompt" --arg user "$input" '{
        systemInstruction: {parts: [{text: $sys}]},
        contents: [{parts: [{text: $user}]}],
        generationConfig: {temperature: 0.2, maxOutputTokens: 2048}
    }')" || {
        echo "$ts [FAIL] $model: jq could not build request body" >> "$debug_log"
        return 1
    }

    local raw http_status response curl_exit=0
    raw="$(curl -sS --max-time "$GEMINI_TIMEOUT_SEC" \
        -w '\n__HTTP_STATUS__:%{http_code}' \
        "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
        -H 'Content-Type: application/json' \
        -H "X-goog-api-key: $api_key" \
        -X POST -d "$body" 2>>"$debug_log")" || curl_exit=$?

    if [ "$curl_exit" -ne 0 ]; then
        echo "$ts [FAIL] $model: curl exit $curl_exit (timeout/network/dns)" >> "$debug_log"
        return 1
    fi

    http_status="$(printf '%s' "$raw" | tail -n1 | sed 's/.*__HTTP_STATUS__://')"
    response="$(printf '%s' "$raw" | sed '$d')"

    if [ "$http_status" != "200" ]; then
        local err_msg
        err_msg="$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)"
        echo "$ts [FAIL] $model: HTTP $http_status: ${err_msg:-no-detail}" >> "$debug_log"
        echo "$ts [FAIL]   body_first_400: $(printf '%s' "$response" | python3 -c 'import sys; print(sys.stdin.read()[:400], end="")')" >> "$debug_log"
        return 1
    fi

    local text
    text="$(printf '%s' "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)"
    if [ -z "$text" ]; then
        local finish_reason
        finish_reason="$(printf '%s' "$response" | jq -r '.candidates[0].finishReason // empty' 2>/dev/null)"
        echo "$ts [FAIL] $model: empty text (finishReason=${finish_reason:-none})" >> "$debug_log"
        echo "$ts [FAIL]   body_first_400: $(printf '%s' "$response" | python3 -c 'import sys; print(sys.stdin.read()[:400], end="")')" >> "$debug_log"
        return 1
    fi

    echo "$ts [ OK ] $model: $(printf '%s' "$text" | wc -c | tr -d ' ') bytes" >> "$debug_log"
    printf '%s' "$text"
    return 0
}

# Internal: invoke an Ollama-compatible local server (default port 11434).
# Echoes generated text on success (return 0); returns 1 on any failure.
# Tier is opt-in: if HANDY_OLLAMA_HOST is empty, this returns 1 immediately
# without even trying — user explicitly enables Ollama by setting the env.
_invoke_ollama_api() {
    local model="$1"
    local prompt_file="$2"
    local input="$3"
    local debug_log="$LOG_DIR/ollama-debug.log"
    local ts
    ts="$(date -u +%FT%TZ)"

    if [ -z "$HANDY_OLLAMA_HOST" ] || [ -z "$model" ]; then
        return 1
    fi

    local sys_prompt
    sys_prompt="$(cat "$prompt_file" 2>/dev/null)" || {
        echo "$ts [FAIL] $model: cannot read prompt $prompt_file" >> "$debug_log"
        return 1
    }

    local body
    body="$(jq -n --arg sys "$sys_prompt" --arg user "$input" --arg model "$model" '{
        model: $model,
        system: $sys,
        prompt: $user,
        stream: false,
        options: {temperature: 0.2}
    }')" || {
        echo "$ts [FAIL] $model: jq could not build request body" >> "$debug_log"
        return 1
    }

    local raw http_status response curl_exit=0
    raw="$(curl -sS --max-time "$OLLAMA_TIMEOUT_SEC" \
        -w '\n__HTTP_STATUS__:%{http_code}' \
        "${HANDY_OLLAMA_HOST}/api/generate" \
        -H 'Content-Type: application/json' \
        -X POST -d "$body" 2>>"$debug_log")" || curl_exit=$?

    if [ "$curl_exit" -ne 0 ]; then
        echo "$ts [FAIL] $model: curl exit $curl_exit (server down or unreachable)" >> "$debug_log"
        return 1
    fi

    http_status="$(printf '%s' "$raw" | tail -n1 | sed 's/.*__HTTP_STATUS__://')"
    response="$(printf '%s' "$raw" | sed '$d')"

    if [ "$http_status" != "200" ]; then
        echo "$ts [FAIL] $model: HTTP $http_status: $(printf '%s' "$response" | head -c 200)" >> "$debug_log"
        return 1
    fi

    local text
    text="$(printf '%s' "$response" | jq -r '.response // empty' 2>/dev/null)"
    if [ -z "$text" ]; then
        echo "$ts [FAIL] $model: empty .response field" >> "$debug_log"
        return 1
    fi
    echo "$ts [ OK ] $model: $(printf '%s' "$text" | wc -c | tr -d ' ') bytes" >> "$debug_log"
    printf '%s' "$text"
    return 0
}

# Medium-mode cleanup chain (free-first):
#   gemini-2.5-flash-lite (free, ~1s)
#   → gemini-2.5-flash    (free, ~2s, more capable)
#   → Ollama              (local, free, only if HANDY_OLLAMA_HOST is set)
#   → claude CLI sonnet   (paid: needs Claude Max or API key, 8s timeout)
#   → raw input           (final fallback)
# Each attempt is timed and logged separately with model + attempt label.
run_medium_cleanup_chain() {
    local prompt_file="$1"
    local input="$2"
    local mode="$3"

    local out start_ms end_ms latency_ms

    _try_gemini() {
        local model="$1" attempt="$2"
        start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        if out="$(_invoke_gemini_api "$model" "$prompt_file" "$input")" && [ -n "$out" ]; then
            end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
            latency_ms=$(( end_ms - start_ms ))
            log_run "$mode" "$input" "$out" 0 "$latency_ms" "$model" "$attempt"
            printf '%s' "$out"
            return 0
        fi
        end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        latency_ms=$(( end_ms - start_ms ))
        log_run "$mode" "$input" "" 1 "$latency_ms" "$model" "$attempt"
        return 1
    }

    _try_ollama() {
        local model="$1" attempt="$2"
        [ -z "$HANDY_OLLAMA_HOST" ] && return 1
        start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        if out="$(_invoke_ollama_api "$model" "$prompt_file" "$input")" && [ -n "$out" ]; then
            end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
            latency_ms=$(( end_ms - start_ms ))
            log_run "$mode" "$input" "$out" 0 "$latency_ms" "ollama:$model" "$attempt"
            printf '%s' "$out"
            return 0
        fi
        end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        latency_ms=$(( end_ms - start_ms ))
        log_run "$mode" "$input" "" 1 "$latency_ms" "ollama:$model" "$attempt"
        return 1
    }

    if out="$(_try_gemini "gemini-2.5-flash-lite" "primary")"; then
        printf '%s' "$out"; return 0
    fi
    # Pinned to 2.5-flash (stable). gemini-flash-latest now resolves to
    # gemini-3-flash-preview which uses thinking mode + scarce free-tier quota
    # and was the cause of the 2026-05-10 mass-fallback incident.
    if out="$(_try_gemini "gemini-2.5-flash" "backup1")"; then
        printf '%s' "$out"; return 0
    fi

    if out="$(_try_ollama "$HANDY_OLLAMA_MODEL" "backup2")"; then
        printf '%s' "$out"; return 0
    fi

    # Final paid tier: Claude CLI. Haiku-first (faster ~3-5s) for Medium —
    # Sonnet's cold-start floor is 5-7s which often busts the 8s per-call
    # timeout we set here. 8s timeout keeps a transient outage from making
    # the user wait a full minute. If Claude CLI isn't installed, this
    # returns fast (find_claude → empty).
    if out="$(run_claude_or_fallback "$prompt_file" "$input" "$mode" "haiku" "sonnet" "8")"; then
        printf '%s' "$out"; return 0
    fi
    # Explicit raw fallback. (run_claude_or_fallback echoed $input on its
    # own failure, but make the chain's contract independent of that.)
    printf '%s' "$input"
    return 1
}

# Heavy-mode chain: Gemini flash-latest (fast, ~6s, comparable quality on
# 100-200-word posts) → Claude Sonnet → Haiku → raw input. Used by the
# default double-Ctrl Heavy hotkey. Heavy Pro (triple-Ctrl) bypasses this
# chain and goes straight to Claude Sonnet for stricter publication-grade
# editing on long posts.
run_heavy_chain() {
    local prompt_file="$1"
    local input="$2"
    local mode="$3"

    local out start_ms end_ms latency_ms

    _try_gemini_heavy() {
        local model="$1" attempt="$2"
        start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        if out="$(_invoke_gemini_api "$model" "$prompt_file" "$input")" && [ -n "$out" ]; then
            end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
            latency_ms=$(( end_ms - start_ms ))
            log_run "$mode" "$input" "$out" 0 "$latency_ms" "$model" "$attempt"
            printf '%s' "$out"
            return 0
        fi
        end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        latency_ms=$(( end_ms - start_ms ))
        log_run "$mode" "$input" "" 1 "$latency_ms" "$model" "$attempt"
        return 1
    }

    _try_ollama_heavy() {
        local model="$1" attempt="$2"
        [ -z "$HANDY_OLLAMA_HOST" ] && return 1
        start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        if out="$(_invoke_ollama_api "$model" "$prompt_file" "$input")" && [ -n "$out" ]; then
            end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
            latency_ms=$(( end_ms - start_ms ))
            log_run "$mode" "$input" "$out" 0 "$latency_ms" "ollama:$model" "$attempt"
            printf '%s' "$out"
            return 0
        fi
        end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        latency_ms=$(( end_ms - start_ms ))
        log_run "$mode" "$input" "" 1 "$latency_ms" "ollama:$model" "$attempt"
        return 1
    }

    # Pinned to gemini-2.5-flash (stable, predictable quota).
    if out="$(_try_gemini_heavy "gemini-2.5-flash" "primary")"; then
        printf '%s' "$out"; return 0
    fi

    if out="$(_try_ollama_heavy "$HANDY_OLLAMA_MODEL" "backup1")"; then
        printf '%s' "$out"; return 0
    fi

    if out="$(run_claude_or_fallback "$prompt_file" "$input" "$mode" "sonnet" "haiku")"; then
        printf '%s' "$out"; return 0
    fi
    # Explicit raw fallback. (run_claude_or_fallback echoed $input on its
    # own failure, but make the chain's contract independent of that.)
    printf '%s' "$input"
    return 1
}

# Run claude with primary model; on failure (exit ≠ 0, empty output, or
# timeout) automatically retry with backup_model. Echoes cleaned text on
# success (return 0); echoes original input on full failure (return 1).
#
# Args: prompt_file input mode primary_model [backup_model] [timeout_sec]
run_claude_or_fallback() {
    local prompt_file="$1"
    local input="$2"
    local mode="$3"
    local primary_model="${4:-$CLAUDE_MODEL_DEFAULT}"
    local backup_model="${5:-}"
    local call_timeout="${6:-$CLAUDE_TIMEOUT_SEC}"

    local claude_bin
    claude_bin="$(find_claude)"
    if [ -z "$claude_bin" ]; then
        log_run "$mode" "$input" "" 127 0 "none" "primary"
        printf '%s' "$input"
        return 1
    fi

    local prompt
    prompt="$(cat "$prompt_file")"
    local timeout_bin
    timeout_bin="$(find_timeout)"

    # Try a single model. Echoes cleaned text + returns 0 on success;
    # returns non-zero on failure (caller decides whether to retry).
    _run_one_model() {
        local model="$1"
        local attempt="$2"
        local out exit_code=0
        local start_ms end_ms latency_ms
        start_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        if [ -n "$timeout_bin" ]; then
            out="$(printf '%s' "$input" \
                | (cd "$SANDBOX_DIR" && "$timeout_bin" "$call_timeout" "$claude_bin" -p "$prompt" \
                    --output-format text --max-turns 1 --model "$model" 2>/dev/null))" \
                || exit_code=$?
        else
            out="$(printf '%s' "$input" \
                | (cd "$SANDBOX_DIR" && "$claude_bin" -p "$prompt" \
                    --output-format text --max-turns 1 --model "$model" 2>/dev/null))" \
                || exit_code=$?
        fi
        end_ms="$(python3 -c 'import time; print(int(time.time()*1000))')"
        latency_ms=$(( end_ms - start_ms ))

        if [ -z "$out" ] || [ "$exit_code" -ne 0 ]; then
            log_run "$mode" "$input" "" "$exit_code" "$latency_ms" "$model" "$attempt"
            return 1
        fi
        log_run "$mode" "$input" "$out" "$exit_code" "$latency_ms" "$model" "$attempt"
        printf '%s' "$out"
        return 0
    }

    local output
    if output="$(_run_one_model "$primary_model" primary)"; then
        printf '%s' "$output"
        return 0
    fi

    if [ -n "$backup_model" ]; then
        if output="$(_run_one_model "$backup_model" backup)"; then
            printf '%s' "$output"
            return 0
        fi
    fi

    printf '%s' "$input"
    return 1
}
