-- Run in Hammerspoon: hs -c 'dofile(os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/tests/sidecar-test.lua")'
local path = os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/sidecar.lua"
local function fixture(connected, wake)
  local f = {timers = {}, tasks = {}, alerts = {}, connected = connected}
  local api = {
    screen = {allScreens = function()
      return f.connected and {{name = function() return "Sidecar Display (AirPlay)" end}} or {}
    end},
    alert = {show = function(message) table.insert(f.alerts, message) end},
    logger = {new = function() return {i = function() end, w = function() end} end},
    timer = {doAfter = function(delay, fn)
      local timer = {delay = delay, fn = fn, stopped = false}
      function timer:stop() self.stopped = true end
      table.insert(f.timers, timer)
      return timer
    end},
    task = {new = function(bin, callback, args)
      local task = {bin = bin, callback = callback, args = args}
      function task:start() table.insert(f.tasks, self); return self end
      function task:terminate() self.terminated = true end
      return task
    end},
    caffeinate = {watcher = {
      systemDidWake = 1, screensDidUnlock = 2, sessionDidBecomeActive = 3,
      systemWillSleep = 4, screensDidLock = 5, sessionDidResignActive = 6,
      screensDidWake = 7, screensDidSleep = 8,
      new = function(callback)
        f.event = callback
        return {start = function() end, stop = function() end}
      end,
    }},
  }
  function f:fire(delay)
    for _, timer in ipairs(self.timers) do
      if not timer.stopped and timer.delay == delay then
        timer.stopped = true; timer.fn(); return
      end
    end
    error("No pending timer for " .. delay)
  end
  local module = assert(loadfile(path))()
  f.controller = module.new(api, {device = "Test iPad", binary = "/test/SidecarLauncher",
    wakeBinary = wake and "/test/pymobiledevice3" or nil, wakeDevice = wake and "test-udid" or nil})
  return f
end

local count = 0
local function test(name, fn)
  fn(); count = count + 1; print("PASS " .. name)
end

test("connected iPad is left alone", function()
  local f = fixture(true)
  f.controller:connect()
  assert(#f.tasks == 0)
end)

test("manual request connects configured device and suppresses duplicate requests", function()
  local f = fixture(false)
  f.controller:connect(); f.controller:connect()
  assert(#f.tasks == 1)
  assert(f.tasks[1].bin == "/test/SidecarLauncher")
  assert(f.tasks[1].args[1] == "connect" and f.tasks[1].args[2] == "Test iPad")
  f.tasks[1].callback(0, "connected", "")
  assert(#f.alerts == 1)
end)

test("login and wake schedule one connection, with bounded retries", function()
  local f = fixture(false)
  f.controller:start()
  f.event(1); f.event(2)
  f:fire(5)
  for n = 1, 4 do
    assert(#f.tasks == n)
    f.tasks[n].callback(4, "device locked", "")
    if n < 4 then f:fire(15) end
  end
  for _, timer in ipairs(f.timers) do assert(timer.stopped) end
  assert(#f.alerts == 0, "automatic failures must be quiet")
end)

test("hung attempt times out and ignores its late success callback", function()
  local f = fixture(false)
  f.controller:connect()
  f:fire(25)
  assert(f.tasks[1].terminated)
  f.tasks[1].callback(0, "connected", "")
  assert(#f.alerts == 1 and not f.alerts[1]:find("connected"))
  f.controller:connect()
  assert(#f.tasks == 2)
end)

test("locking cancels running connection and queued retries", function()
  local f = fixture(false)
  f.controller:start(); f:fire(5)
  f.event(5)
  assert(f.tasks[1].terminated)
  f.tasks[1].callback(4, "cancelled", "")
  for _, timer in ipairs(f.timers) do assert(timer.stopped) end
end)

test("manual connection cancels pending automatic retry", function()
  local f = fixture(false)
  f.controller:start(); f:fire(5)
  f.tasks[1].callback(4, "not ready", "")
  f.controller:connect()
  assert(#f.tasks == 2)
  f.tasks[2].callback(0, "connected", "")
  for _, timer in ipairs(f.timers) do assert(timer.stopped) end
end)

test("automatic mode can be disabled while manual connection still works", function()
  local f = fixture(false)
  f.controller.config.autoConnect = false
  f.controller:start(); f.event(1)
  assert(#f.timers == 0)
  f.controller:connect()
  assert(#f.tasks == 1)
end)

test("wireless wake precedes Sidecar and targets only the configured iPad", function()
  local f = fixture(false, true)
  f.controller:connect(); f.controller:connect()
  assert(#f.tasks == 1 and f.tasks[1].bin == "/usr/bin/env", "wake must run first")
  assert(table.concat(f.tasks[1].args, " ") ==
    "PYMOBILEDEVICE3_UDID=test-udid /test/pymobiledevice3 developer core-device hid button home --native")
  f.tasks[1].callback(0, "", "")
  assert(#f.tasks == 2 and f.tasks[2].bin == "/test/SidecarLauncher")
  f.tasks[2].callback(0, "", "")
  assert(f.controller.lastResult == "connected")
end)

test("wake failure still permits a normal Sidecar connection", function()
  local f = fixture(false, true)
  f.controller:connect()
  f.tasks[1].callback(1, "", "unreachable")
  assert(#f.tasks == 2 and f.tasks[2].bin == "/test/SidecarLauncher")
end)

test("wake timeout terminates wake and ignores late callbacks", function()
  local f = fixture(false, true)
  f.controller:connect()
  f:fire(15)
  assert(f.tasks[1].terminated and #f.tasks == 2)
  f.tasks[1].callback(0, "", "")
  assert(#f.tasks == 2)
end)

test("locking during wake prevents the subsequent Sidecar connection", function()
  local f = fixture(false, true)
  f.controller:start(); f:fire(5)
  f.event(5)
  assert(f.tasks[1].terminated)
  f.tasks[1].callback(0, "", "")
  assert(#f.tasks == 1)
end)

test("active Sidecar is not disturbed by a wake event", function()
  local f = fixture(true, true)
  f.controller:start(); f:fire(5)
  assert(#f.tasks == 0)
end)

test("display-only wake schedules one wake-then-connect attempt", function()
  local f = fixture(true, true)
  f.controller:start(); f:fire(5)
  f.connected = false
  f.event(7); f.event(7)
  assert(#f.tasks == 0, "display wake must retain the startup delay")
  f:fire(5)
  assert(#f.tasks == 1 and f.tasks[1].bin == "/usr/bin/env")
  f.tasks[1].callback(0, "", "")
  assert(#f.tasks == 2 and f.tasks[2].bin == "/test/SidecarLauncher")
end)

test("display sleep cancels delayed connections and automatic retries", function()
  local f = fixture(false)
  f.controller:start(); f.event(8)
  assert(f.controller.timer == nil, "display sleep must cancel the initial delay")
  f.event(7); f:fire(5)
  f.tasks[1].callback(1, "unavailable", "")
  f.event(8)
  assert(f.controller.timer == nil, "display sleep must cancel retry")
  for _, timer in ipairs(f.timers) do assert(timer.stopped) end
end)

test("display sleep terminates wake and ignores its late callback", function()
  local f = fixture(false, true)
  f.controller:start(); f:fire(5)
  f.event(8)
  assert(f.tasks[1].terminated, "display sleep must terminate the wake helper")
  f.tasks[1].callback(0, "", "")
  assert(#f.tasks == 1 and f.controller.task == nil)
  for _, timer in ipairs(f.timers) do assert(timer.stopped) end
end)

test("display wake respects disabled automatic mode", function()
  local f = fixture(false, true)
  f.controller.config.autoConnect = false
  f.controller:start(); f.event(7)
  assert(#f.tasks == 0 and #f.timers == 0)
end)

print(string.format("%d Sidecar tests passed", count))
