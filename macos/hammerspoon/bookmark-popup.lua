-- A global shortcut into the existing Emacs daemon; never starts/restarts it.
local M = {}

function M:launch()
  if self.task and self.task:isRunning() then return end

  local origin = hs.application.frontmostApplication()
  local window = hs.window.focusedWindow()
  local screen = window and window:screen() or hs.screen.mainScreen()
  local area = screen:frame()
  local expression = string.format(
    "(progn (require 'mr-x-bookmark-popup) (mr-x/bookmark-popup '(%d %d %d %d)))",
    math.floor(area.x), math.floor(area.y), math.floor(area.w), math.floor(area.h))

  self.task = hs.task.new(
    "/opt/homebrew/opt/emacs-plus@30/bin/emacsclient",
    function(code, stdout, stderr)
      self.task = nil
      if code ~= 0 then
        hs.alert.show("Bookmark picker unavailable; check Emacs")
        print("Bookmark picker: " .. stderr)
      end
      if code ~= 0 or stdout:match("^%s*cancelled%s*$") then
        if origin and origin:isRunning() then origin:activate() end
      end
    end,
    {"--socket-name=server", "--alternate-editor=false", "--eval", expression})

  if not self.task or not self.task:start() then
    self.task = nil
    hs.alert.show("Could not launch the Emacs bookmark picker")
  end
end

function M:start()
  if self.hotkey then self.hotkey:delete() end
  self.hotkey = hs.hotkey.bind(
    {"cmd", "ctrl"}, "B", "Emacs bookmarks", function() self:launch() end)
end

return M
