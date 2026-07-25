require("hs.ipc")

-- Function to show a centered pill-style HUD with the layout name

-- HUD text + background objects
local layoutHUD = hs.drawing.text(hs.geometry.rect(0, 0, 400, 80), "")
layoutHUD:setTextSize(30)
layoutHUD:setTextColor({hex = "#FFFFFF"})
layoutHUD:setTextStyle({alignment = "center"})
layoutHUD:setLevel(hs.drawing.windowLevels.overlay)
layoutHUD:setBehavior(hs.drawing.windowBehaviors.canJoinAllSpaces)
layoutHUD:setAlpha(1.0)

local bgRect = hs.drawing.rectangle(hs.geometry.rect(0, 0, 400, 80))
bgRect:setRoundedRectRadii(12, 12)
bgRect:setFillColor({hex = "#1e1e2e", alpha = 0.8})
bgRect:setStroke(false)
bgRect:setLevel(hs.drawing.windowLevels.overlay)
bgRect:setBehavior(hs.drawing.windowBehaviors.canJoinAllSpaces)
bgRect:setAlpha(0.9)

-- HUD display logic
function showLayoutHUD(text)
  local frontWindow = hs.window.focusedWindow()
  local screenFrame = frontWindow and frontWindow:screen():frame() or hs.screen.mainScreen():frame()

  local hudWidth = 400
  local hudHeight = 80
  local hudX = (screenFrame.w - hudWidth) / 2
  local hudY = (screenFrame.h - hudHeight) / 2
  local hudRect = hs.geometry.rect(hudX, hudY, hudWidth, hudHeight)

  layoutHUD:setFrame(hudRect)
  bgRect:setFrame(hudRect)
  layoutHUD:setText(text)

  layoutHUD:show()
  bgRect:show()

  hs.timer.doAfter(1, function()
    layoutHUD:hide()
    bgRect:hide()
  end)
end

-- Visual bell icon overlay (called from Emacs)
local bellCanvas = nil
local bellTimer = nil

function showBellIcon()
  if bellTimer then bellTimer:stop() end
  if bellCanvas then bellCanvas:delete() end

  local imgPath = os.getenv("HOME") .. "/.emacs.d/var/other-eye-transparent.png"
  local img = hs.image.imageFromPath(imgPath)
  if not img then return end

  local screen = hs.screen.mainScreen()
  local focused = hs.window.focusedWindow()
  if focused then screen = focused:screen() end
  local sf = screen:frame()

  local size = 190
  local x = sf.x + (sf.w - size) / 2
  local y = sf.y + (sf.h - size) / 2

  bellCanvas = hs.canvas.new(hs.geometry.rect(x, y, size, size))
  bellCanvas:level(hs.canvas.windowLevels.overlay)
  bellCanvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  -- Tint the image to gruvbox dark (#282828)
  img:template(true)
  bellCanvas[1] = {
    type = "image",
    image = img,
    frame = { x = 0, y = 0, w = size, h = size },
    imageAlpha = 1.0,
    imageScaling = "scaleProportionally",
    compositeRule = "sourceOver",
  }
  bellCanvas[2] = {
    type = "rectangle",
    frame = { x = 0, y = 0, w = size, h = size },
    fillColor = { hex = "#ebdbb2", alpha = 1.0 },
    compositeRule = "sourceIn",
    action = "fill",
  }
  bellCanvas:show()

  bellTimer = hs.timer.doAfter(0.3, function()
    if bellCanvas then
      bellCanvas:delete()
      bellCanvas = nil
    end
  end)
end

-- Manual test hotkey (⌘ + Ctrl + L)
hs.hotkey.bind({ "cmd", "ctrl" }, "L", function()
  showLayoutHUD("bsp")
end)

-- File watcher to react to layout changes
local layoutFile = os.getenv("HOME") .. "/.config/yabai/current_layout"
layoutWatcher = hs.pathwatcher.new(layoutFile, function(files)
  for _, file in ipairs(files) do
    for line in io.lines(file) do
      local layout = line:match("^(%S+)")
      showLayoutHUD(layout)
    end
  end
end)
layoutWatcher:start()

-- Auto-heal monitor arrangement: macOS randomly forgets display positions
-- on reconnect/wake, so on any display change re-apply the saved
-- displayplacer profile for the current display set (no-op when in sync).
-- Debounce past monitor-mode's 4-10s re-enumeration churn.
local displayLayoutScript = os.getenv("HOME") .. "/.dotfiles/macos/scripts/display-layout.sh"
local displayLayoutTimer = nil
displayLayoutWatcher = hs.screen.watcher.new(function()
  if displayLayoutTimer then displayLayoutTimer:stop() end
  displayLayoutTimer = hs.timer.doAfter(4, function()
    hs.task.new(displayLayoutScript, nil, { "apply" }):start()
  end)
end)
displayLayoutWatcher:start()

-- Live keymap widget on the portrait display (keymap-explorer PRD)
dofile(os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/keymap-widget.lua")