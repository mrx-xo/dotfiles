#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
; -----------------------------------------------------------------------------
; kanata escape hatch.
;
;   Win+Shift+K        toggle kanata off / on
;   tray icon menu     "kanata: toggle" (for when the keyboard is the problem)
;
; kanata runs as the elevated "kanata" scheduled task (scripts\kanata-ctl.ps1).
; This script stays unelevated and only drives that task, which needs no
; elevation because the task is ours. Turning kanata off also releases every
; modifier, so a stuck Super/Ctrl/Alt/Shift from whatever went wrong clears
; with the same chord.
;
; The hotkey takes the wildcard (*) on purpose: if a modifier IS stuck, the
; chord arrives with it attached and still has to match.
; -----------------------------------------------------------------------------

ctl := A_ScriptDir "\..\scripts\kanata-ctl.ps1"

A_IconTip := "kanata hatch (Win+Shift+K)"
A_TrayMenu.Insert("1&", "kanata: toggle", (*) => ToggleKanata())
A_TrayMenu.Insert("2&")

*#+k::ToggleKanata()

KanataRunning() {
    for name in ["kanata.exe", "kanata_windows_tty_winIOv2_x64.exe", "kanata_windows_gui_winIOv2_x64.exe"] {
        if ProcessExist(name)
            return true
    }
    return false
}

KanataCtl(cmd) {
    RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' ctl '" ' cmd, , "Hide")
}

ToggleKanata() {
    if KanataRunning() {
        KanataCtl("stop")
        ; Whatever kanata left half-pressed, let go of it.
        Send "{Blind}{LWin up}{RWin up}{LCtrl up}{RCtrl up}{LAlt up}{RAlt up}{LShift up}{RShift up}"
        msg := KanataRunning() ? "kanata: still running (stop failed)" : "kanata: OFF  (Win+Shift+K turns it back on)"
    } else {
        KanataCtl("start")
        msg := KanataRunning() ? "kanata: ON" : "kanata: failed to start (see kanata-ctl.ps1 status)"
    }
    TrayTip msg, "kanata hatch", "Mute"
    SetTimer () => TrayTip(), -3000
}
