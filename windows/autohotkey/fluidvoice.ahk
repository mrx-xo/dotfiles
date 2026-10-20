#Requires AutoHotkey v2.0
#SingleInstance Force
; -----------------------------------------------------------------------------
; FluidVoice glue — two workarounds for the Windows 0.0.10 build. No hotkeys.
; Delete the matching half once an upstream build fixes it.
;
; 1. Overlay on top (altic-dev/FluidVoice#996). The dictation pill is shown
;    "without activation" (right, it must not steal focus) but Fluid never
;    re-asserts topmost on each show, so on a multi-monitor desktop it lands
;    behind the foreground app. A WinEvent hook watches for the overlay (an
;    untitled "Tauri Window" owned by fluidvoice.exe; the main window carries
;    the "FluidVoice" title) and pushes it to the top of the topmost band with
;    SWP_NOACTIVATE every time it is shown.
;
; 2. Dictation into Emacs. Fluid inserts by writing the clipboard, sending an
;    injected Ctrl+V, then restoring the previous clipboard ~650ms later. Emacs
;    only reads the clipboard when it gets round to the keystroke, which while
;    agent-shell is rendering can be seconds later, so it pasted whatever Fluid
;    had restored (an older transcript). A low-level keyboard hook spots the
;    injected Ctrl+V (LLKHF_INJECTED; physical keys never carry it) while an
;    Emacs frame is foreground, swallows it, reads the clipboard right then and
;    hands the text to Emacs through emacsclient (`mr-x/fluid-insert-file' in
;    windows\emacs\.emacs.d\init.el). Other apps keep Fluid's own paste.
; -----------------------------------------------------------------------------

; ---- 1. overlay --------------------------------------------------------------
EVENT_OBJECT_SHOW := 0x8002
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

cbShown := CallbackCreate(OnOverlayShown, "F", 7)
hWinEvent := DllCall("SetWinEventHook", "uint", EVENT_OBJECT_SHOW, "uint", EVENT_OBJECT_SHOW,
    "ptr", 0, "ptr", cbShown, "uint", 0, "uint", 0, "uint", 0, "ptr")  ; WINEVENT_OUTOFCONTEXT, all processes
if !hWinEvent
    throw Error("SetWinEventHook failed")

; ---- 2. Emacs bridge ---------------------------------------------------------
WH_KEYBOARD_LL := 13
WM_KEYDOWN := 0x100
WM_SYSKEYDOWN := 0x104
LLKHF_INJECTED := 0x10
VK_V := 0x56
EmacsClient := EnvGet("USERPROFILE") "\scoop\shims\emacsclient.exe"
TranscriptFile := A_Temp "\fluidvoice-transcript.txt"
injectedCtrl := false  ; an injected Ctrl is currently held

EmacsActive() {
    try
        return WinGetClass("A") = "Emacs"
    catch
        return false
}

; KBDLLHOOKSTRUCT: vkCode @0, scanCode @4, flags @8, time @12, dwExtraInfo @16
LowLevelKey(nCode, wParam, lParam) {
    global injectedCtrl
    if (nCode >= 0) {
        vk := NumGet(lParam, 0, "uint")
        flags := NumGet(lParam, 8, "uint")
        if (flags & LLKHF_INJECTED) {
            down := (wParam = WM_KEYDOWN || wParam = WM_SYSKEYDOWN)
            if (vk = 0x11 || vk = 0xA2 || vk = 0xA3)       ; VK_CONTROL / L / R
                injectedCtrl := down
            else if (vk = VK_V && injectedCtrl && EmacsActive()) {
                if down
                    SetTimer(BridgeTranscript, -1)
                return 1  ; swallow the V down and up; Emacs never sees the paste
            }
        }
    }
    return DllCall("CallNextHookEx", "ptr", 0, "int", nCode, "ptr", wParam, "ptr", lParam, "ptr")
}

BridgeTranscript() {
    text := A_Clipboard  ; Fluid wrote it a few ms ago; still untouched
    if (text = "")
        return
    try FileDelete(TranscriptFile)
    FileAppend(text, TranscriptFile, "UTF-8-RAW")
    path := StrReplace(TranscriptFile, "\", "/")
    Run('"' EmacsClient '" --eval "(mr-x/fluid-insert-file \"' path '\")"', , "Hide")
}

cbKey := CallbackCreate(LowLevelKey, "F", 3)
hKeyHook := DllCall("SetWindowsHookEx", "int", WH_KEYBOARD_LL, "ptr", cbKey,
    "ptr", DllCall("GetModuleHandle", "ptr", 0, "ptr"), "uint", 0, "ptr")
if !hKeyHook
    throw Error("SetWindowsHookEx failed")

OnExit((*) => (DllCall("UnhookWinEvent", "ptr", hWinEvent), DllCall("UnhookWindowsHookEx", "ptr", hKeyHook)))
Persistent
