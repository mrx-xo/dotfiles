-- Run through hs -c 'dofile(os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/tests/keymap-widget-test.lua")'
-- Fake OS boundaries: no real windows, event taps, hotkeys or HID listeners.
local function fixture()
  local f = {screens = {}, selected = 3, alerts = {}, views = {}}
  for i = 1, 3 do
    local screen = {id = "screen-" .. i}
    function screen:getUUID() return self.id end
    function screen:frame() return {x = (i - 1) * 1400, y = -200, w = 1200, h = 900} end
    f.screens[i] = screen
  end
  local function resource()
    return {start = function(self) self.enabled = true; return self end,
      stop = function(self) self.enabled = false end,
      isEnabled = function(self) return self.enabled end}
  end
  local api = setmetatable({}, {__index = hs})
  api.screen = {find = function(id)
    if id == "S2725HS" then return f.screens[2] end
    for _, s in pairs(f.screens) do if s.id == id then return s end end
  end, mainScreen = function() return f.screens[1] end,
    watcher = {new = function(cb) f.screenChanged = cb; return resource() end}}
  api.execute = function(command)
    local index = tonumber(command:match("%-%-display (%d+)")) or f.selected
    local screen = f.screens[index]
    return screen and hs.json.encode({index = index, uuid = screen.id}) or "", screen ~= nil
  end
  api.alert = {show = function(s) table.insert(f.alerts, s) end}
  api.hotkey = {bind = function() return resource() end}
  api.eventtap = {event = hs.eventtap.event, new = function() return resource() end}
  api.task = {new = function() return resource() end}
  api.webview = {new = function()
    local view = {scripts = {}}
    for _, method in ipairs({"windowStyle", "level", "behaviorAsLabels", "allowTextEntry",
      "shadow", "transparent", "frame", "url"}) do
      view[method] = function(self, value)
        if value == nil then return self["_" .. method] end
        self["_" .. method] = value; return self
      end
    end
    function view:show() self.visible = true; return self end
    function view:hide() self.visible = false; return self end
    function view:evaluateJavaScript(js) table.insert(self.scripts, js); return self end
    function view:navigationCallback(cb) self.loaded = cb; return self end
    -- The Iris view is created first; later views (KOMAX) are kept by hash.
    table.insert(f.views, view)
    f.view = f.view or view
    return view
  end}
  local env = setmetatable({hs = api}, {__index = _G})
  f.widget = assert(loadfile(os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/keymap-widget.lua", "t", env))()
  return f
end

local count = 0
local function test(name, run) run(); count = count + 1; print("PASS " .. name) end

test("summon uses selected yabai display and restores wallpaper", function()
  local f = fixture()
  assert(type(f.widget.toggleOverlay) == "function", "overlay toggle is missing")
  local original = f.view:frame()
  f.widget.toggleOverlay()
  local frame = f.view:frame()
  assert(frame.x >= 2800 and frame.x + frame.w <= 4000, "overlay on wrong monitor")
  assert(f.view:level() > hs.drawing.windowLevels.normal, "overlay behind normal windows")
  assert(f.view:transparent() and f.view:allowTextEntry() == false)
  f.widget.toggleOverlay()
  assert(f.view.visible and f.view:level() == hs.drawing.windowLevels.desktopIcon)
  assert(f.view:frame().x == original.x and not f.view:transparent())
end)

test("dismiss restores hidden wallpaper", function()
  local f = fixture()
  f.widget.toggle()
  f.widget.toggleOverlay()
  assert(f.view.visible)
  f.widget.toggleOverlay()
  assert(not f.view.visible)
end)

test("move routes to overlay only while summoned", function()
  local f = fixture()
  assert(f.widget.moveToDisplay(1) == "inactive")
  f.widget.toggleOverlay()
  assert(f.widget.moveToDisplay(1) == "moved")
  local frame = f.view:frame()
  assert(frame.x >= 0 and frame.x + frame.w <= 1200)
  assert(f.widget.moveToDisplay(5) == "unavailable")
  assert(f.view:frame().x == frame.x, "missing monitor moved the overlay")
  assert(f.widget.moveToDisplay("1; bad") == "unavailable")
end)

test("screen disconnect relocates popup and preserves hidden wallpaper", function()
  local f = fixture()
  f.widget.toggle()
  f.widget.toggleOverlay()
  f.screens[3] = nil; f.selected = 1
  f.screenChanged()
  assert(f.view.visible and f.view:frame().x < 1200)
  f.widget.toggleOverlay()
  assert(not f.view.visible)
end)

test("page finishing navigation reapplies overlay styling", function()
  local f = fixture()
  f.widget.toggleOverlay()
  f.view.scripts = {}
  f.view.loaded("didFinishNavigation", f.view)
  assert(table.concat(f.view.scripts):find('"overlay",true', 1, true), "overlay style lost on load")
end)

local function komax(f)
  for _, v in ipairs(f.views) do
    if (v:url() or ""):match("#komax&widget$") then return v end
  end
end

test("KOMAX gets its own wallpaper view below the Iris", function()
  local f = fixture()
  local km = assert(komax(f), "no KOMAX webview")
  assert(km.visible, "KOMAX hidden on the wallpaper")
  local ir, k = f.view:frame(), km:frame()
  local portrait = f.screens[2]:frame()
  assert(k.y >= ir.y + ir.h, "KOMAX overlaps the Iris")
  assert(k.x >= portrait.x and k.x + k.w <= portrait.x + portrait.w, "KOMAX off the portrait display")
end)

test("summoned overlay stays Iris-only and KOMAX returns on dismiss", function()
  local f = fixture()
  local km = komax(f)
  local before = km:frame()
  f.widget.toggleOverlay()
  assert(f.view.visible and not km.visible, "KOMAX shown in the overlay")
  f.widget.toggleOverlay()
  assert(km.visible and km:frame().y == before.y)
end)

test("wallpaper toggle hides and restores KOMAX with the Iris", function()
  local f = fixture()
  local km = komax(f)
  f.widget.toggle()
  assert(not km.visible and not f.view.visible)
  f.widget.toggle()
  assert(km.visible and f.view.visible)
end)

print(string.format("%d keymap widget tests passed", count))
