-- keymap-widget.lua — live keymap widget on the portrait display's wallpaper.
-- Two hs.webview windows render keymap-explorer's index.html in widget mode
-- (hotdox on top, creator micro below) and a flagsChanged eventtap feeds them
-- held-modifier state. Spec: ~/roaming/projects/keymap-explorer/live-keymap-widget-prd.md
-- Loaded from init.lua via dofile; exposed as the global `keymapWidget` for hs -c.

local M = {}

-- ---- placement constants (edit + hs.reload to adjust) ----------------------
local HTML = os.getenv("HOME") .. "/roaming/projects/keymap-explorer/index.html"
local SCREEN_PATTERN = "S2725HS"          -- the portrait Dell, 1080x1920
-- rects are offsets into the portrait screen's frame
local RECTS = {
  hd = { x = 0,  y = 60,  w = 1080, h = 580 },   -- hotdox: 17u wide, shallow
  cm = { x = 40, y = 680, w = 1000, h = 1040 },  -- micro: near-square
}
local CM_DEFAULT_LAYER = 2   -- monitors — the layer that matters day-to-day

-- ---- webviews --------------------------------------------------------------
local views = {}      -- board id -> hs.webview
local visible = true  -- recreated visible by default on every reload
local lastModsJS = "window.__setMods({cmd:false,alt:false,shift:false,ctrl:false,fn:false})"

local function makeView(hash, initJS)
  local wv = hs.webview.new(hs.geometry.rect(0, 0, 100, 100))
  wv:windowStyle({ "borderless" })
  wv:level(hs.drawing.windowLevels.desktopIcon)
  wv:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
  wv:allowTextEntry(false)
  wv:shadow(false)
  wv:navigationCallback(function(action, webview)
    -- don't evaluateJavaScript before the page is ready (PRD edge case)
    if action == "didFinishNavigation" then
      webview:evaluateJavaScript(lastModsJS)
      if initJS then webview:evaluateJavaScript(initJS) end
    end
  end)
  wv:url("file://" .. HTML .. hash)
  return wv
end

views.hd = makeView("#hotdox&widget")
views.cm = makeView("#micro&widget",
  string.format("window.__setLayer(%d)", CM_DEFAULT_LAYER))
M.views = views   -- reachable from `hs -c` for debugging

-- position on the portrait display, or hide when it's absent / toggled off
local function place()
  local screen = hs.screen.find(SCREEN_PATTERN)
  if not screen or not visible then
    for _, wv in pairs(views) do wv:hide() end
    return
  end
  local f = screen:frame()
  for id, wv in pairs(views) do
    local r = RECTS[id]
    wv:frame(hs.geometry.rect(f.x + r.x, f.y + r.y, r.w, r.h))
    wv:show()
  end
end

function M.toggle()
  visible = not visible
  place()
end

-- ---- live modifiers: one eventtap fans out to both webviews ----------------
local function b(v) return v and "true" or "false" end

M.modTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
  local f = e:getFlags()
  lastModsJS = string.format(
    "window.__setMods({cmd:%s,alt:%s,shift:%s,ctrl:%s,fn:%s})",
    b(f.cmd), b(f.alt), b(f.shift), b(f.ctrl), b(f.fn))
  for _, wv in pairs(views) do wv:evaluateJavaScript(lastModsJS) end
  return false
end)
M.modTap:start()
if not M.modTap:isEnabled() then
  hs.printf("keymap-widget: eventtap disabled — grant Accessibility to Hammerspoon; widget will render statically")
end

-- ---- optional per-keypress flash (toggle with cmd+ctrl+shift+K) ------------
-- Its own eventtap so that "off" means the tap is stopped — zero overhead,
-- not just filtered. keyDown/keyUp only; page flips a class, no re-render.
local KEYTOK = {
  space = "space", ["return"] = "enter", padenter = "enter", delete = "bksp",
  forwarddelete = "del", escape = "esc", tab = "tab",
  left = "left", right = "right", up = "up", down = "down",
  home = "home", ["end"] = "end", pageup = "pgup", pagedown = "pgdn",
}

local ktypes = hs.eventtap.event.types
M.keyTap = hs.eventtap.new({ ktypes.keyDown, ktypes.keyUp }, function(e)
  if e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) ~= 0 then
    return false  -- held-key repeats would just re-set the same class
  end
  local name = hs.keycodes.map[e:getKeyCode()]
  if not name then return false end
  local tok = KEYTOK[name]
      or (#name == 1 and name:lower())
      or (name:match("^f%d+$") and name)
  if not tok then return false end
  local js = string.format("window.__flashKey(%q,%s)",
    tok, e:getType() == ktypes.keyDown and "true" or "false")
  for _, wv in pairs(views) do wv:evaluateJavaScript(js) end
  return false
end)

function M.toggleKeys()
  if M.keyTap:isEnabled() then
    M.keyTap:stop()
    -- clear any keycap left lit mid-hold
    for _, wv in pairs(views) do
      wv:evaluateJavaScript(
        "window.__pressed && window.__pressed.clear();" ..
        "document.querySelectorAll('.key.press').forEach(n=>n.classList.remove('press'))")
    end
    hs.printf("keymap-widget: key flash off")
  else
    M.keyTap:start()
    hs.printf("keymap-widget: key flash on")
  end
end

M.keyTap:start()   -- flash enabled by default; ⌘⌃⇧K or keymapWidget.toggleKeys() to flip

-- ---- phase B: live layer tracking from the firmware's raw HID broadcast ----
-- keymap-widget-hid.py blocking-reads the hotdox raw HID interface and prints
-- "L<n>" per layer change (firmware sends [0x4C, layer] on every change and
-- once at boot). Layer goes to the hotdox webview only. The task dies on
-- unplug/sleep; respawn with 2s→30s backoff, fall back to layer 0 while down.
local HID_PY = "/opt/homebrew/bin/python3"
local HID_SCRIPT = os.getenv("HOME") .. "/.dotfiles/macos/scripts/keymap-widget-hid.py"
local hidBackoff = 2

local function setHdLayer(n)
  views.hd:evaluateJavaScript(string.format("window.__setLayer(%d)", n))
end

local function spawnHid()
  local started = hs.timer.secondsSinceEpoch()
  M.hidTask = hs.task.new(HID_PY, function(_, _, stdErr)
    -- termination: board gone or listener died — fall back, retry with backoff
    setHdLayer(0)
    if stdErr and #stdErr > 0 then
      hs.printf("keymap-widget hid: %s", (stdErr:gsub("%s+$", "")))
    end
    if hs.timer.secondsSinceEpoch() - started > 10 then hidBackoff = 2 end
    M.hidTimer = hs.timer.doAfter(hidBackoff, spawnHid)
    hidBackoff = math.min(hidBackoff * 2, 30)
  end, function(_, stdOut)
    for n in stdOut:gmatch("L(%d+)") do setHdLayer(tonumber(n)) end
    return true
  end, { HID_SCRIPT })
  M.hidTask:start()
end

spawnHid()

-- ---- wiring ----------------------------------------------------------------
M.screenWatcher = hs.screen.watcher.new(place)
M.screenWatcher:start()

-- kill the listener on hs.reload so the respawned config doesn't race a zombie
hs.shutdownCallback = function()
  if M.hidTimer then M.hidTimer:stop() end
  if M.hidTask then M.hidTask:terminate() end
end

hs.hotkey.bind({ "cmd", "ctrl" }, "K", M.toggle)
hs.hotkey.bind({ "cmd", "ctrl", "shift" }, "K", M.toggleKeys)

place()

keymapWidget = M
return M
