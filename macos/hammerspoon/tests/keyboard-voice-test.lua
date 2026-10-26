-- OS boundaries are faked; no microphone, key injection or network activity.
local count = 0
local function fixture()
  local f = {bindings = {}, keys = {}, tasks = {}, alerts = {}, running = true}
  local api = {
    application = {get = function() return f.running and {} or nil end},
    alert = {show = function(message) table.insert(f.alerts, message) end},
    eventtap = {keyStroke = function(mods, key)
      table.insert(f.keys, {mods = mods, key = key})
    end},
    hotkey = {bind = function(mods, key, pressed, released, repeated)
      assert(#mods == 0)
      local binding = {pressed = pressed, released = released, repeated = repeated}
      function binding:delete() self.deleted = true end
      f.bindings[key] = binding
      return binding
    end},
    task = {new = function(path, callback, args)
      local task = {path = path, callback = callback, args = args}
      function task:start()
        self.started = true
        if f.startFails then return nil end
        return self
      end
      table.insert(f.tasks, task)
      return task
    end},
  }
  local env = setmetatable({hs = api}, {__index = _G})
  f.module = assert(loadfile(os.getenv("HOME") ..
    "/.dotfiles/macos/hammerspoon/keyboard-voice.lua", "t", env))()
  return f
end
local function test(name, fn) fn(); count = count + 1; print("PASS " .. name) end

test("keypad Enter triggers local dictation without binding ordinary Return", function()
  local f = fixture()
  assert(f.bindings.padenter and not f.bindings["return"])
  assert(not f.bindings.padenter.repeated, "holding Enter must not toggle repeatedly")
  f.bindings.padenter.pressed()
  assert(#f.keys == 1 and f.keys[1].key == "space" and f.keys[1].mods[1] == "alt")
  assert(#f.tasks == 0)
end)
test("local dictation reports a stopped app instead of typing a shortcut", function()
  local f = fixture(); f.running = false
  f.bindings.padenter.pressed()
  assert(#f.keys == 0 and #f.alerts == 1)
end)
test("keypad plus starts one bounded remote request and allows the next tap", function()
  local f = fixture()
  assert(not f.bindings["pad+"].repeated)
  f.bindings["pad+"].pressed(); f.bindings["pad+"].pressed()
  assert(#f.tasks == 1 and f.tasks[1].started, "concurrent toggle request escaped")
  assert(f.tasks[1].path:match("/macos/scripts/keyboard%-voice%-remote%.sh$"))
  assert(#f.tasks[1].args == 0 and #f.keys == 0)
  f.tasks[1].callback(0, "", "")
  f.bindings["pad+"].pressed()
  assert(#f.tasks == 2)
end)
test("remote failures are visible and do not block later attempts", function()
  local f = fixture()
  f.bindings["pad+"].pressed()
  f.tasks[1].callback(255, "", "offline")
  assert(#f.alerts == 1)
  f.bindings["pad+"].pressed()
  assert(#f.tasks == 2)
end)
test("task launch failure releases the busy flag", function()
  local f = fixture(); f.startFails = true
  f.bindings["pad+"].pressed(); f.bindings["pad+"].pressed()
  assert(#f.tasks == 2 and #f.alerts == 2)
end)
test("stop releases both keypad bindings", function()
  local f = fixture(); f.module.stop()
  assert(f.bindings.padenter.deleted and f.bindings["pad+"].deleted)
end)
print(count .. " keyboard voice checks passed")
