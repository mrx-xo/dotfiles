-- Sidecar connection lifecycle. Device identity stays in per-machine config.
local M = {}

function M.new(api, config)
  local self = {config = config, generation = 0, attempts = 0, lastResult = "idle"}
  local log = api.logger.new("sidecar", "info")
  -- Automatic attempts per wake/unlock. Every failed attempt makes macOS
  -- show its own "Unable to connect" alert, so the default is one.
  local maxAttempts = tonumber(config.maxAttempts) or 1

  function self:connected()
    for _, screen in ipairs(api.screen.allScreens()) do
      if screen:name():find("Sidecar", 1, true) then return true end
    end
    return false
  end

  -- KOMAX grammar: while held, NYX is the AIDOS remote and no automatic
  -- connect may steal it back. The marker file survives reloads and logins.
  function self:held()
    if not config.holdPath then return false end
    local h = io.open(config.holdPath, "r")
    if not h then return false end
    h:close()
    return true
  end

  -- A connect made elsewhere (Control Center, the iPad) ends the AIDOS
  -- session; a stale hold would silently block every later auto-connect.
  -- Checked only when an automatic connect is about to be scheduled: right
  -- after our own disconnect the Sidecar screen can still be enumerated for
  -- a moment, so a check inside held() would drop a fresh hold.
  function self:holding()
    if not self:held() then return false end
    if self:connected() then self:release(); return false end
    return true
  end

  function self:hold()
    self:cancel()
    if config.holdPath then
      local h = io.open(config.holdPath, "w")
      if h then h:write("held\n"); h:close() end
    end
  end

  function self:release()
    if config.holdPath then os.remove(config.holdPath) end
  end

  -- Each phase owns its callback/deadline. A late callback must not finish
  -- or launch a second helper after timeout or cancellation.
  function self:run(generation, binary, args, timeout, callback)
    local done = false
    local function complete(code, output, err)
      if done or generation ~= self.generation then return end
      done = true
      if self.deadline then self.deadline:stop(); self.deadline = nil end
      self.task = nil
      callback(code, output, err)
    end
    local task = api.task.new(binary, complete, args)
    self.task = task
    if not task or not task:start() then
      complete(1, "Unable to start connection helper", "")
      return
    end
    self.deadline = api.timer.doAfter(timeout, function()
      complete(1, "Connection helper timed out", "")
      task:terminate()
    end)
  end

  function self:disconnect()
    if not self:connected() then self.lastResult = "not connected"; return self.lastResult end
    if self.task then return "Connection already in progress" end
    self:cancel()
    local generation = self.generation
    self.lastResult = "disconnecting"
    self:run(generation, config.binary, {"disconnect", config.device}, 25, function(code, output, err)
      if generation ~= self.generation then return end
      self.generation = self.generation + 1
      if code == 0 then
        self.lastResult = "disconnected"
        log.i("Disconnected configured iPad")
      else
        self.lastResult = (output or "") .. (err or "")
        log.w("Disconnect failed: " .. self.lastResult)
      end
    end)
    return self.lastResult
  end

  function self:cancel()
    self.generation = self.generation + 1
    if self.timer then self.timer:stop(); self.timer = nil end
    if self.deadline then self.deadline:stop(); self.deadline = nil end
    local task = self.task
    self.task = nil
    if task then task:terminate() end
  end

  function self:attempt(manual)
    if self:connected() then
      self.lastResult = "already connected"
      if manual then api.alert.show("iPad is already connected") end
      return
    end
    self.attempts = self.attempts + 1
    self.generation = self.generation + 1
    local generation = self.generation
    self.lastResult = "connecting"
    local function finish(code, output, err)
      if generation ~= self.generation then return end
      self.generation = self.generation + 1
      if self.deadline then self.deadline:stop(); self.deadline = nil end
      self.task = nil
      if code == 0 then
        self.lastResult = "connected"
        log.i("Connected to configured iPad")
        if manual then api.alert.show("iPad connected") end
      else
        self.lastResult = (output or "") .. (err or "")
        log.w("Connection failed: " .. self.lastResult)
        if manual then
          api.alert.show("Sidecar failed: wake and unlock your iPad, then retry")
        elseif self.attempts < maxAttempts then
          self.timer = api.timer.doAfter(15, function()
            self.timer = nil
            self:attempt(false)
          end)
        end
      end
    end
    local function run(binary, args, timeout, callback)
      self:run(generation, binary, args, timeout, callback)
    end
    local function connect()
      self.lastResult = "connecting"
      run(config.binary, {"connect", config.device}, 25, finish)
    end
    if config.wakeBinary and config.wakeDevice then
      self.lastResult = "waking iPad"
      run("/usr/bin/env", {"PYMOBILEDEVICE3_UDID=" .. config.wakeDevice,
        config.wakeBinary, "developer", "core-device", "hid", "button", "home", "--native"},
        15, function(code)
          if code ~= 0 then log.w("Wake helper failed; trying Sidecar directly") end
          connect()
        end)
    else
      connect()
    end
  end

  function self:connect()
    if self.task then return "Connection already in progress" end
    self:release()
    self:cancel()
    self.attempts = 0
    self:attempt(true)
    return self.lastResult
  end

  function self:schedule()
    if config.autoConnect == false or self.task or self:holding() then return end
    self:cancel()
    self.attempts = 0
    self.timer = api.timer.doAfter(5, function()
      self.timer = nil
      self:attempt(false)
    end)
  end

  function self:status()
    return string.format("%s; auto-connect %s; last result: %s; hold %s",
      self:connected() and "iPad connected" or "iPad not connected",
      config.autoConnect == false and "off" or "on", self.lastResult,
      self:held() and "on" or "off")
  end

  function self:start()
    local events = api.caffeinate.watcher
    self.watcher = events.new(function(event)
      if event == events.systemDidWake or event == events.screensDidWake
          or event == events.screensDidUnlock
          or event == events.sessionDidBecomeActive then
        self:schedule()
      elseif event == events.systemWillSleep or event == events.screensDidSleep
          or event == events.screensDidLock
          or event == events.sessionDidResignActive then
        self:cancel()
      end
    end)
    self.watcher:start()
    self:schedule()
    return self
  end

  function self:stop()
    self:cancel()
    if self.watcher then self.watcher:stop(); self.watcher = nil end
    if self.hotkey then self.hotkey:delete(); self.hotkey = nil end
  end

  return self
end

return M
