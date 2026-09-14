#Requires AutoHotkey v2.0
#SingleInstance Force
; -----------------------------------------------------------------------------
; OBS Skate clip capture — one-key "launch + arm".
;
;   Win+Shift+O   Launch OBS with the Skate profile/scene, start the replay
;                 buffer, and minimize to tray. Idempotent (does nothing if OBS
;                 is already running). Then just play, and tap F10 (OBS's global
;                 "Save Replay" hotkey) after a trick to write the last 5 minutes
;                 to C:\Users\mnand\Videos\Skate.
;
; Thin wrapper, same pattern as emacs.ahk: the actual logic lives in the repo's
; PowerShell script so it's testable outside AHK. Run hidden so no console flashes.
; -----------------------------------------------------------------------------

; Win+Shift+O -> arm OBS for Skate
#+o:: {
    script := A_ScriptDir "\..\scripts\obs-skate-arm.ps1"
    Run('powershell -NoProfile -ExecutionPolicy Bypass -File "' script '"', , "Hide")
}

; F10 -> save the last 5 minutes of the replay buffer.
; We fire this ourselves (AHK catches the physical key reliably) and drive the
; save over obs-websocket, because OBS's own raw-key hotkey didn't register/fire
; here. To change the key, edit the line below (e.g. ^F10 = Ctrl+F10, or #+s for
; Win+Shift+S). Use a leading ~ (~F10::) if you also want the game to see the key.
F10:: {
    script := A_ScriptDir "\..\scripts\obs-save-replay.ps1"
    Run('powershell -NoProfile -ExecutionPolicy Bypass -File "' script '"', , "Hide")
}
