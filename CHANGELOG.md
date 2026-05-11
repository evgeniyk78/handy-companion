# Changelog

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
