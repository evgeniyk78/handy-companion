# Changelog

## v0.1.2 — 2026-05-11

### Reliability

- **handy-clean: re-activate target app before Cmd+V.** The LLM cleanup
  call takes 1-8s; during that window the system's frontmost window can
  change (notification toast, Slack auto-focusing a new message, Stage
  Manager rearranging things) and Cmd+V at the end lands in the wrong
  field. Fix: capture the frontmost app at script start, then activate
  it right before the keystroke. Handy itself is filtered out (edge case
  when Handy briefly grabs focus while spawning the script). Helps in
  most cases but not all — see the new alternative architecture below
  for users who want bulletproof paste.

### New: alternative architecture using Handy's built-in post-process

- **`handy-settings/use-builtin-llm.sh`** — one-shot script that switches
  Handy to its own OpenAI-compatible post-processing pipeline, pointed
  at Gemini's OpenAI-compat endpoint
  (`https://generativelanguage.googleapis.com/v1beta/openai/`). Bypasses
  `bin/handy-clean` entirely; Handy calls the API itself and pastes via
  its native mechanism — more reliable than osascript Cmd+V, and one
  fewer process in the chain.

  Trade-offs: no fallback to Ollama/Claude on Gemini failure (Handy
  drops to raw Whisper output instead), no multi-key Keychain rotation,
  the API key lives in Handy's settings JSON rather than Keychain. See
  README "Alternative architecture: Handy's built-in post-process" for
  the full comparison. Re-run `bash handy-settings/apply.sh` to switch
  back to the external_script path.

### Logs

- Bumped `logs/medium-*.log` / `logs/heavy-*.log` excerpt fields from
  200 → 1000 chars, renamed `input_first_200` / `output_first_200` to
  `input_excerpt` / `output_excerpt`. Side-by-side comparison of raw
  Whisper input vs cleaned output is one of the most useful debugging
  signals, and 200 chars regularly cut off mid-sentence on real
  dictations. Disk impact is negligible (still rotated to 50 files).

### Prompts and timeouts

- `prompts/medium.txt` and `prompts/heavy.txt` got a "Numbers and
  versions" section so spoken version numbers in any language render as
  digits (`"three point one"` / `"три точка один"` / `"три один"` →
  `3.1`). Guarded against converting generic counted nouns —
  `"three cats"` / `"пять минут"` stay as words. (Whisper Large v3 Turbo
  does this normalization natively too, so this is now a fallback for
  non-Turbo STT engines.)
- `GEMINI_TIMEOUT_SEC` default bumped from 8s to 15s. A minimal prompt
  finishes in 1-2s; a personalized `prompts/medium.local.txt` with a
  sizeable technical-term dictionary regularly pushes flash-lite to
  8-12s on multilingual input, and the previous 8s cap silently dropped
  legitimate slow-but-working calls into the next tier. Overridable via
  the same env var.

### Docs

- New README section "Customizing hotkeys" — covers Medium (Handy UI
  rebind) and Heavy / Heavy Pro (`hammerspoon/handy-heavy.lua` with the
  `TAP_INTERVAL` and `LEFT_CTRL_KEYCODE` knobs and an `hs.hotkey.bind`
  alternative for users who prefer a normal chord over double / triple
  tap). Two FAQs in the same week pointed to this being a missing
  reference.

## v0.1.1 — 2026-05-11

### Performance

- **Disabled Gemini "thinking" for the 2.5 family** (`thinkingBudget: 0`
  in `_invoke_gemini_api`). Heavy mode `gemini-2.5-flash` dropped from
  ~3-7s to ~1-2s per call (~4× speedup), and the truncation-mid-sentence
  bug on long inputs is gone — default thinking was eating most of the
  2048-token output budget on hidden reasoning. The flag is added only
  for `gemini-2.5-*` (3.x models reject `0`); 2.5-flash-lite already
  doesn't think, so the field is a harmless no-op there.

### Reliability

- **Multi-key fallback in `_invoke_gemini_api`.** Optional second
  Keychain slot `handy-companion-gemini-2` is auto-tried on HTTP 429
  from the primary key. Other failures (network, 4xx other than 429,
  5xx, empty text) still fail immediately without burning the second
  key. Single-key setups are unchanged. Override the slot name via
  `GEMINI_KEYCHAIN_SERVICE_SECONDARY`. Logs now tag attempts with the
  slot label (`[primary]`, `[secondary]`, `[legacy]`) and a `[QUOTA]`
  marker on rotation.

## v0.1.0 — 2026-05-10 (initial public release)

First public release. Pipeline:

- **Speech-to-text:** [Handy](https://github.com/cjpais/Handy) v0.8 (Whisper /
  Parakeet, fully offline).
- **Hotkeys:** Medium = ⌥Space (Handy native), Heavy = ×× left-Ctrl,
  Heavy Pro = ××× left-Ctrl (Hammerspoon).
- **Cleanup providers** (free-first chain, opt-in for paid tiers):
  Gemini API direct (gemini-2.5-flash-lite → 2.5-flash) → Ollama
  (opt-in) → Claude CLI → raw fallback.
- **Paste mechanism:** Handy `paste_method=external_script` for Medium;
  `pbcopy` + osascript Cmd+V + clipboard restore for Heavy/Heavy-Pro.

### Notable design choices

- **Gemini API direct via `curl`** instead of Gemini CLI: CLI startup
  overhead (~9s) dominates inference time; direct API gets us under 2s
  end-to-end.
- **Pinned `gemini-2.5-flash`** instead of `gemini-flash-latest`. Google
  resolves `*-latest` to `gemini-3-flash-preview`, which uses thinking
  mode and has a thin free-tier quota.
- **API key in macOS Keychain** with `-A` flag so Hammerspoon and Handy
  children can read it without an authorization prompt.
- **`LANG=en_US.UTF-8` forced in `_common.sh`**. macOS launchd doesn't
  set `LANG`, and without it `pbpaste`/`pbcopy` interpret bytes as
  a region-specific single-byte encoding and corrupt
  non-ASCII round-trips into double-encoded mojibake.
- **Triple-Ctrl detection with delayed dispatch.** Naive "fire on 2nd
  tap, fire on 3rd tap" would double-fire on a triple. The 2nd tap
  arms a 250ms timer; a 3rd tap cancels it and fires Heavy Pro instead.
- **Per-user `$TMPDIR` sandbox** (not `/tmp`) so the script can't be
  hijacked on a shared machine.
- **Verify-pbcopy guard.** If `pbcopy` silently fails (rare — pasteboard
  held by another process), we skip the Cmd+V to avoid pasting the user's
  prior clipboard into an unexpected app.

### Known limitations

- macOS only (Hammerspoon, `pbpaste`/`pbcopy`, Handy itself). Linux
  port would need different paste mechanisms.
- Default English prompts deliberately have no technical-stack
  dictionary. Users with a specific stack (Vercel, Supabase, etc.)
  should copy `prompts/medium.txt` to `prompts/medium.local.txt` and
  add their own term mappings — see README.
- `pbpaste` only returns plain text, so image/file/RTF clipboards lose
  their rich type after Heavy mode's clipboard restore.
