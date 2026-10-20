#Requires AutoHotkey v2.0
#SingleInstance Force
; -----------------------------------------------------------------------------
; FluidVoice recording overlay — keep it on top.
;
; Workaround for altic-dev/FluidVoice#996 (Windows 0.0.10): the dictation pill
; is shown "without activation" (right, it must not steal focus) but Fluid never
; re-asserts topmost on each show, so on a multi-monitor desktop it lands behind
; the foreground app and you cannot tell whether it is recording.
;
; No hotkeys. A WinEvent hook watches for the overlay (an untitled "Tauri
; Window" owned by fluidvoice.exe; the main window carries the "FluidVoice"
; title) and, every time it is shown, pushes it to the top of the topmost band
; with SWP_NOACTIVATE so focus stays where you are dictating.
; Delete this file once an upstream build fixes #996.
; -----------------------------------------------------------------------------

EVENT_OBJECT_SHOW := 0x8002
OBJID_WINDOW := 0
HWND_TOPMOST := -1
SWP_FLAGS := 0x1 | 0x2 | 0x10  ; NOSIZE | NOMOVE | NOACTIVATE

OnOverlayShown(hHook, event, hwnd, idObject, idChild, thread, time) {
    if (idObject != 0)
        return
    try {
        if (WinGetProcessName("ahk_id " hwnd) != "fluidvoice.exe")
            return
        if (WinGetClass("ahk_id " hwnd) != "Tauri Window" || WinGetTitle("ahk_id " hwnd) != "")
            return
    } catch {
        return  ; window went away between the event and our lookups
    }
    DllCall("SetWindowPos", "ptr", hwnd, "ptr", HWND_TOPMOST, "int", 0, "int", 0, "int", 0, "int", 0, "uint", SWP_FLAGS)
}

cb := CallbackCreate(OnOverlayShown, "F", 7)
hook := DllCall("SetWinEventHook", "uint", EVENT_OBJECT_SHOW, "uint", EVENT_OBJECT_SHOW,
    "ptr", 0, "ptr", cb, "uint", 0, "uint", 0, "uint", 0, "ptr")  ; WINEVENT_OUTOFCONTEXT, all processes
if !hook
    throw Error("SetWinEventHook failed")
OnExit((*) => DllCall("UnhookWinEvent", "ptr", hook))
Persistent
