-- Detect left-Ctrl chord and dispatch the right Heavy variant:
--   double tap → bin/handy-heavy           (Gemini flash-latest, ~5-7s)
--   triple tap → bin/handy-heavy --pro     (Claude Sonnet, ~16-25s)
--
-- A naive "fire on 2nd tap, fire on 3rd tap" would always fire Heavy first
-- and then Heavy Pro on a triple. To distinguish, the 2nd tap arms a delayed
-- timer (TAP_INTERVAL); a 3rd tap within that window cancels the timer and
-- fires Heavy Pro instead.

local M = {}

local TAP_INTERVAL = 0.25         -- seconds between taps to count as a sequence
local LEFT_CTRL_KEYCODE = 59      -- macOS keycode for left Control

-- HEAVY_SCRIPT: absolute path to bin/handy-heavy. Resolution order:
--   1. HANDY_COMPANION_HEAVY env var (explicit override). Note: env vars set
--      in ~/.zshrc / ~/.bash_profile are NOT visible to Hammerspoon — it's
--      launched by launchd, not from an interactive shell. Use `launchctl
--      setenv HANDY_COMPANION_HEAVY <path>` (re-run on each login) or a
--      LaunchAgent for that path to work.
--   2. ../bin/handy-heavy relative to THIS .lua file. This is the default
--      and works for any install location: the user's `dofile` in
--      ~/.hammerspoon/init.lua already had to point at our hammerspoon/
--      directory, so we know where bin/ sits relative to that.
--   3. ~/handy-companion/bin/handy-heavy as a last-resort fallback for
--      the canonical OSS-install path documented in the README.
local function script_dir()
    -- debug.getinfo(1, "S").source is "@/abs/path/to/handy-heavy.lua".
    -- Strip the leading "@" and the trailing filename to get the dir.
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("(.*/)") or "./"
end

local HEAVY_SCRIPT = os.getenv("HANDY_COMPANION_HEAVY")
    or (script_dir() .. "../bin/handy-heavy")
if not hs.fs.attributes(HEAVY_SCRIPT, "mode") then
    HEAVY_SCRIPT = os.getenv("HOME") .. "/handy-companion/bin/handy-heavy"
end

if not hs.fs.attributes(HEAVY_SCRIPT, "mode") then
    hs.alert.show(
        "handy-companion: script not found at\n" .. HEAVY_SCRIPT ..
        "\nSet HANDY_COMPANION_HEAVY env var to your install path.",
        5
    )
    return {}
end

local last_ctrl_time = nil
local had_other_key_between = false
local ctrl_was_down = false
local tap_count = 0
local pending_double_timer = nil

local function reset_state()
    last_ctrl_time = nil
    had_other_key_between = false
    tap_count = 0
    if pending_double_timer then
        pending_double_timer:stop()
        pending_double_timer = nil
    end
end

local function fire_heavy()
    pending_double_timer = nil
    hs.task.new(HEAVY_SCRIPT, nil, {}):start()
    reset_state()
end

local function fire_heavy_pro()
    if pending_double_timer then
        pending_double_timer:stop()
        pending_double_timer = nil
    end
    hs.task.new(HEAVY_SCRIPT, nil, {"--pro"}):start()
    reset_state()
end

local watcher = hs.eventtap.new(
    {hs.eventtap.event.types.flagsChanged, hs.eventtap.event.types.keyDown},
    function(event)
        local etype = event:getType()

        if etype == hs.eventtap.event.types.keyDown then
            had_other_key_between = true
            return false
        end

        if etype == hs.eventtap.event.types.flagsChanged then
            local keycode = event:getKeyCode()
            local flags = event:getFlags()

            if keycode ~= LEFT_CTRL_KEYCODE then
                return false
            end

            local ctrl_now = flags.ctrl == true
            local pure = (flags.cmd ~= true) and (flags.alt ~= true)
                and (flags.shift ~= true) and (flags.fn ~= true)

            if ctrl_now and not ctrl_was_down then
                ctrl_was_down = true
                if not pure then
                    -- Ctrl with another modifier: chord, not our trigger.
                    reset_state()
                    return false
                end

                local now = hs.timer.secondsSinceEpoch()
                local within_window = last_ctrl_time
                    and (now - last_ctrl_time) <= TAP_INTERVAL
                    and not had_other_key_between

                if within_window then
                    tap_count = tap_count + 1
                    last_ctrl_time = now
                    had_other_key_between = false

                    if tap_count == 2 then
                        -- Arm Heavy after the window; a 3rd tap cancels this.
                        if pending_double_timer then pending_double_timer:stop() end
                        pending_double_timer = hs.timer.doAfter(TAP_INTERVAL, fire_heavy)
                    elseif tap_count == 3 then
                        -- 3rd tap: Heavy Pro. Cancel pending double-Heavy.
                        fire_heavy_pro()
                    end
                    -- 4+ rapid taps within the same window: ignored. Heavy Pro
                    -- has already fired; reset_state() inside fire_heavy_pro
                    -- means tap_count is 0 again, so subsequent taps start a
                    -- fresh sequence.
                else
                    -- Start a fresh sequence. reset_state() clears
                    -- had_other_key_between so the *next* tap can match
                    -- within_window — without this clear, any keystroke
                    -- between sessions would permanently disable the chord.
                    reset_state()
                    last_ctrl_time = now
                    tap_count = 1
                end
            elseif not ctrl_now and ctrl_was_down then
                ctrl_was_down = false
            end

            return false
        end

        return false
    end
)

function M.start()
    watcher:start()
    hs.alert.show("Handy Heavy: double=Gemini, triple=Sonnet armed")
end

M.start()
return M
