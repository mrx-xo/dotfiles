-- Only machines with explicit local configuration get Sidecar automation.
if sidecar then sidecar:stop(); sidecar = nil end
local configPath = os.getenv("HOME") .. "/.config/sidecar/config.json"
local config = hs.fs.attributes(configPath) and hs.json.read(configPath)
if config and type(config.device) == "string" and config.device ~= "" then
  config.binary = os.getenv("HOME") .. "/.local/share/sidecar/SidecarLauncher-cli"
  if type(config.wakeDevice) == "string" and config.wakeDevice ~= "" then
    config.wakeBinary = os.getenv("HOME") .. "/.local/bin/pymobiledevice3"
  end
  sidecar = dofile(os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/sidecar.lua").new(hs, config)
  sidecar.hotkey = hs.hotkey.bind({"ctrl", "alt", "cmd"}, "i", function() sidecar:connect() end)
  sidecar:start()
end
