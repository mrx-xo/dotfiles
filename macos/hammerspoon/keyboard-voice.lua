-- Keypad dictation: + on the remote desktop, Enter on this Mac.
-- These are host bindings; the compiled knob+Enter Fn combo still consumes
-- its chord before either key reaches macOS. Ordinary Return is untouched.
local M = {}
local pending
local bindings = {}
local remoteScript = os.getenv("HOME") .. "/.dotfiles/macos/scripts/keyboard-voice-remote.sh"

local function localVoice()
  if not hs.application.get("FluidVoice") then
    hs.alert.show("Open FluidVoice on this Mac first")
    return
  end
  -- Matches the configured PrimaryDictationShortcuts (Option+Space).
  hs.eventtap.keyStroke({"alt"}, "space", 0)
end

local function remoteVoice()
  if pending then return end
  local task = hs.task.new(remoteScript, function(code)
    pending = nil
    if code ~= 0 then
      hs.alert.show("Remote dictation request failed; check the Windows connection")
    end
  end, {})
  pending = task
  if not task or not task:start() then
    pending = nil
    hs.alert.show("Could not start the remote dictation request")
  end
end

function M.stop()
  for _, binding in pairs(bindings) do binding:delete() end
  bindings = {}
end

-- No repeat callback: holding either key must not repeatedly toggle the mic.
bindings.plus = hs.hotkey.bind({}, "pad+", remoteVoice)
bindings.enter = hs.hotkey.bind({}, "padenter", localVoice)
if not bindings.plus or not bindings.enter then
  M.stop()
  hs.alert.show("Keypad dictation bindings unavailable")
end
return M
