#Requires AutoHotkey v2.0
#SingleInstance Force
; -----------------------------------------------------------------------------
; Emacs global hotkeys — Windows port of the macOS skhd bindings.
; (cmd+shift on macOS  ->  Win+Shift here)
;
;   Win+Shift+E   Open an Emacs frame (auto-starts the daemon if needed)
;   Win+Shift+R   Restart the daemon, then open a fresh frame
; -----------------------------------------------------------------------------

; Win+Shift+E -> emacsclientw -c -a ""  (the empty -a "" starts a daemon if none)
#+e:: {
    ; Use the scoop shim — the apps\emacs\current\bin path drifts across updates.
    ecw := EnvGet("USERPROFILE") "\scoop\shims\emacsclientw.exe"
    Run('"' ecw '" -c -a ""')
}

; Win+Shift+R -> run the restart script (kill daemon, relaunch, open frame)
#+r:: {
    script := A_ScriptDir "\..\scripts\emacs-restart.ps1"
    Run('powershell -NoProfile -ExecutionPolicy Bypass -File "' script '"', , "Hide")
}
