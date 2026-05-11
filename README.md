# handy-companion

LLM post-processing layer for [Handy](https://github.com/cjpais/Handy), the
free, offline speech-to-text app for macOS.

Handy converts your voice into a raw transcript. **handy-companion** runs
that transcript through a fast LLM cleanup chain — fixing punctuation,
removing filler words ("um", "uh", "you know"), and restoring brand
names and technical terms that the speech-to-text engine garbled — and
pastes the polished version into the active app.

```
You speak  →  Handy (Whisper / Parakeet)  →  raw transcript
                                                   ↓
                                              handy-companion
                                                   ↓
                                          Gemini Flash (free, ~1-2s)
                                                   ↓
                                          ⌘V into your active app
```

Two modes triggered by separate hotkeys:

- **Medium** (⌥Space, configured in Handy itself) — quick cleanup of any
  dictation: punctuation, filler removal, term canonicalization.
- **Heavy** (double left-Ctrl, configured in Hammerspoon) — heavier
  rewrite for posts and emails: stitches fragmented thoughts, lifts
  register from speech to writing while keeping the speaker's voice.
- **Heavy Pro** (triple left-Ctrl) — same prompt as Heavy but routes
  to a stronger paid model for publication-grade copy.

## Why

Handy is great offline, but raw Whisper/Parakeet output still says
"versail" instead of "Vercel", "supa base" instead of "Supabase", and
keeps every "uh" and "you know". Sending it through a small fast LLM
fixes that in 1-2 seconds and makes voice input usable for actual writing.

Designed to **stay free for the common case**: Gemini 2.5 Flash on
Google's free tier handles 99% of the volume. Bring your own provider
(Ollama, Claude, OpenAI) if you need an offline or premium fallback.

## Requirements

- macOS (Apple Silicon recommended)
- [Handy](https://github.com/cjpais/Handy) v0.8+ — the speech-to-text app
- [Hammerspoon](https://www.hammerspoon.org/) — for the Heavy/Heavy-Pro
  Ctrl-tap trigger (only if you want Heavy mode)
- [Homebrew coreutils](https://formulae.brew.sh/formula/coreutils) for
  `gtimeout`: `brew install coreutils`
- `jq` (usually preinstalled on macOS via Xcode CLT, or
  `brew install jq`)
- A Gemini API key — free, [aistudio.google.com/apikey](https://aistudio.google.com/apikey)

## Setup

```bash
# 1. Clone
git clone https://github.com/evgeniyk78/handy-companion ~/handy-companion
cd ~/handy-companion

# 2. Run the interactive setup wizard. It will:
#    - prompt for your Gemini API key and store it in macOS Keychain
#    - apply the Handy settings patch (paste_method, hotkey, external_script_path)
#    - print the Hammerspoon snippet for you to add to ~/.hammerspoon/init.lua
bash bin/setup.sh
```

That's it for the free path. Press ⌥Space, dictate something, see clean
output paste into your active app.

For Heavy mode, follow the Hammerspoon snippet `setup.sh` printed.

### Optional: a second Gemini key for quota fallback

Free-tier Gemini quotas are tight (a few requests per minute on
`2.5-flash`). If you hit them often, add a key from a second Google
account in a separate Keychain slot:

```bash
security add-generic-password -A -a "$USER" -s handy-companion-gemini-2 -w 'YOUR_SECOND_KEY'
```

`_invoke_gemini_api` will automatically rotate to it on HTTP 429 from the
primary key. Any other error (network, bad key, 5xx, empty response)
still fails fast without burning the second key.

## Provider chain

handy-companion tries providers in order. The first one that returns a
non-empty response wins; the rest are skipped.

### Medium chain (⌥Space)

| Tier | Provider | Model | Latency | Cost | Required |
|------|----------|-------|---------|------|----------|
| 1 | Gemini API | gemini-2.5-flash-lite | ~0.8-1.5s | Free tier | API key |
| 2 | Gemini API | gemini-2.5-flash | ~1-2s | Free tier | API key |
| 3 | Ollama (opt-in) | your choice | ~1-3s | Free, offline | `HANDY_OLLAMA_HOST` set |
| 4 | Claude CLI | haiku → sonnet | ~3-7s | Claude Max sub or API key | `claude` in PATH |
| 5 | raw input | — | — | — | (always pastes original) |

### Heavy chain (×× Ctrl)

| Tier | Provider | Model | Latency |
|------|----------|-------|---------|
| 1 | Gemini API | gemini-2.5-flash | ~1-2s |
| 2 | Ollama (opt-in) | your choice | ~3-10s |
| 3 | Claude CLI | sonnet → haiku | ~15-25s |
| 4 | raw input | — | — |

> Gemini latency assumes the 2.5-family `thinkingBudget: 0` patch shipped
> with this release — without it, 2.5-flash spends 70-80% of wall time on
> hidden reasoning that doesn't help transcript cleanup, and on long
> inputs the result was getting truncated mid-sentence.

### Heavy Pro chain (××× Ctrl)

| Tier | Provider | Model |
|------|----------|-------|
| 1 | Claude CLI | sonnet |
| 2 | Claude CLI | haiku |
| 3 | raw input | — |

## Provider terms of service

Each provider has its own ToS. By using a provider through this tool you
agree to their terms.

- **Google Gemini API** — [Additional Terms of Service](https://ai.google.dev/gemini-api/terms).
  Free tier intended for "developers building with Google AI models for
  professional or business purposes". Each user provides their own API
  key from [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
  and is responsible for compliance.
- **Anthropic Claude** — [Usage Policies](https://www.anthropic.com/legal/usage-policy)
  via Claude Code CLI requires Claude Max subscription or API key.
- **Ollama** — runs locally. Models have their own licenses (Llama, Qwen,
  etc.) — check your model's terms.

## Customizing hotkeys

The three hotkeys live in two different places.

### Medium (default `option+space`)

Configured in **Handy**, not in this repo:

1. Open Handy → Settings → Bindings
2. Find "Transcribe with Post-Processing"
3. Click the existing binding and press the new combo
4. Restart Handy

Conflict-free combos on macOS (no clash with Spotlight or other
system shortcuts): `control+option+space`, `command+option+space`,
or any function key like `f5` / `f6`. The setting is persisted to
`~/Library/Application Support/com.pais.handy/settings_store.json`.

To bake your preferred binding into the setup wizard so a re-run of
`apply.sh` doesn't reset it, edit
`handy-settings/settings.patch.json` →
`bindings.transcribe_with_post_process.current_binding` before
running `bash handy-settings/apply.sh`.

### Heavy / Heavy Pro (default double / triple left-Ctrl)

Configured in `hammerspoon/handy-heavy.lua`. Two knobs at the top:

```lua
local TAP_INTERVAL = 0.25         -- seconds between taps to count as a sequence
local LEFT_CTRL_KEYCODE = 59      -- macOS keycode for left Control
```

Useful macOS modifier keycodes:

| Key | Code |
|-----|------|
| Left Control | 59 |
| Right Control | 62 |
| Left Option | 58 |
| Right Option | 61 |
| Left Shift | 56 |
| Right Shift | 60 |
| fn | 63 |

After editing, reload Hammerspoon: right-click the menubar icon →
**Reload Config**, or run `hs.reload()` in the Hammerspoon Console.

Prefer a regular hotkey over the double / triple tap chord? Keep
the `HEAVY_SCRIPT` definition at the top of `handy-heavy.lua` and
replace the `hs.eventtap.new(...)` block with two `hs.hotkey.bind`
calls — one for Heavy, one for Heavy Pro:

```lua
hs.hotkey.bind({"ctrl", "alt"}, "H", function()
    hs.task.new(HEAVY_SCRIPT, nil, {}):start()
end)
hs.hotkey.bind({"ctrl", "alt"}, "P", function()
    hs.task.new(HEAVY_SCRIPT, nil, {"--pro"}):start()
end)
```

## Customizing prompts (your stack, your style)

The default prompts in `prompts/medium.txt` and `prompts/heavy.txt` are
generic. They handle punctuation, filler removal, and basic phonetic
fixing for any language. They do NOT contain a list of specific
technical terms.

To add your own technical-term dictionary:

```bash
cp prompts/medium.txt prompts/medium.local.txt
# Edit medium.local.txt and add a section like:
#   Common mistranscriptions to fix:
#     "versail" → Vercel
#     "supa base" → Supabase
#     ...
```

`prompts/*.local.txt` is gitignored. The script automatically uses
`*.local.txt` if present, otherwise the default.

A worked example (web-dev stack with common mistranscriptions) lives in
[`examples/medium.with-stack.example.txt`](examples/medium.with-stack.example.txt).

## Configuration via env vars

All optional. Set in your shell profile or `~/.handy-companion/config.sh`
(which `bin/setup.sh` creates).

| Env var | Default | What it does |
|---------|---------|--------------|
| `HANDY_COMPANION_HEAVY` | `~/handy-companion/bin/handy-heavy` | Where Hammerspoon looks for the Heavy script |
| `HANDY_OLLAMA_HOST` | _empty_ | Set to e.g. `http://localhost:11434` to enable Ollama tier |
| `HANDY_OLLAMA_MODEL` | _empty_ | e.g. `qwen2.5:3b` |
| `OLLAMA_TIMEOUT_SEC` | `15` | Ollama call timeout |
| `GEMINI_TIMEOUT_SEC` | `15` | Gemini per-call timeout. A minimal prompt finishes in 1-2s; bigger personalized dictionaries (`prompts/*.local.txt` with dozens of terms) can take 8-12s on multilingual input, so 15s gives that headroom. |
| `CLAUDE_TIMEOUT_SEC` | `30` | Claude CLI call timeout (Heavy/Heavy-Pro) |
| `GEMINI_KEYCHAIN_SERVICE` | `handy-companion-gemini` | Keychain item name (primary key) |
| `GEMINI_KEYCHAIN_SERVICE_SECONDARY` | `<primary>-2` | Optional second-account key; auto-tried only on HTTP 429 from primary |

## Logs and debugging

- `logs/medium-*.log` and `logs/heavy-*.log` — JSON record per attempt
  (model, latency, attempt=primary/backup1/backup2, exit code, plus
  `input_excerpt` and `output_excerpt` — the first 1000 chars of the
  raw STT input and the cleaned output, useful for comparing what
  Whisper produced vs what Gemini changed). Last 50 kept.
- `logs/gemini-debug.log` — append-only diagnostic for every Gemini call:
  HTTP status, error.message, finishReason, body excerpt on failure.
- `logs/ollama-debug.log` — same for Ollama.

Quick check what just happened:

```bash
ls -t logs/*.log | head -3 | xargs -I{} jq '{model, attempt, latency_ms, exit_code}' {}
```

## Privacy

- Your dictation goes to whichever provider tier wins. With the default
  chain that means Google Gemini for most calls.
- If you want everything local, set `HANDY_OLLAMA_HOST` and unset your
  Gemini key — the chain skips directly to Ollama.
- API key is stored in **macOS Keychain**, not in any file or env var
  in this repo.
- No telemetry. No analytics. The repo doesn't phone home.

## Troubleshooting

**Medium hotkey does nothing.** Check Handy → Settings → Bindings:
"Transcribe with Post-Processing" should be `option+space` and
`paste_method` should be `external_script` (the setup wizard does
this). Also verify Handy has Accessibility permission (System Settings
→ Privacy & Security → Accessibility).

**Heavy double-Ctrl does nothing.** Check Hammerspoon has Accessibility
permission. Open Hammerspoon Console and run `hs.reload()`. You should
see the alert "Handy Heavy: double=Gemini, triple=Sonnet armed".

**Output is mojibake (non-ASCII letters appear as runs of `–` and box
characters).** Old install without the locale fix — Hammerspoon and
Handy launch the script without `LANG`, and `pbpaste`/`pbcopy` fall
back to a regional single-byte encoding. Pull latest; the script
forces `LANG=en_US.UTF-8`.

**Provider chain falls all the way through to raw.** Check
`logs/gemini-debug.log` — last entries show why each tier failed (quota,
bad key, schema mismatch).

**Cmd+V pastes my old clipboard, not the cleaned text.** Likely the
verify-pbcopy guard tripped. Check `logs/medium-*.log` for an entry
where the script exited 1.

## How it works (one-page architecture)

```
~/.hammerspoon/init.lua
  └── dofile handy-heavy.lua          ← left-Ctrl tap detector
        ├── ××   Ctrl  → bin/handy-heavy
        └── ×××  Ctrl  → bin/handy-heavy --pro

Handy (~/Library/Application Support/com.pais.handy/settings_store.json)
  └── paste_method = external_script
      external_script_path = bin/handy-clean
      bindings.transcribe_with_post_process = option+space
        ↓ (Handy passes raw transcript as argv[1])
      bin/handy-clean
        ├── reads prev clipboard (so we can restore it)
        ├── _common.sh::run_medium_cleanup_chain
        │     ├── _invoke_gemini_api gemini-2.5-flash-lite  (curl)
        │     ├── _invoke_gemini_api gemini-2.5-flash       (curl)
        │     ├── _invoke_ollama_api  $HANDY_OLLAMA_MODEL    (curl)
        │     └── run_claude_or_fallback sonnet/haiku       (claude CLI)
        ├── pbcopy cleaned text
        ├── verify pbcopy succeeded
        ├── osascript Cmd+V into active app
        └── restore prev clipboard
```

## Contributing

Issues and PRs welcome. The project is small and focused; non-trivial
features should be discussed in an issue first. Run `shellcheck bin/*`
before opening a PR.

## License

[MIT](LICENSE) — same as Handy itself.

## Maintainer

Built by [Yevhen Katkov](https://github.com/evgeniyk78), founder of
[aibot.pro](https://aibot.pro). Need this customized for your team or
language stack? Reach out.
