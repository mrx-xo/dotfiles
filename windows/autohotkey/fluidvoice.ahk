#Requires AutoHotkey v2.0
#SingleInstance Force
; -----------------------------------------------------------------------------
; FluidVoice glue — workarounds for the Windows build (0.0.10 through 0.0.13).
; No hotkeys. Delete the matching part once an upstream build fixes it.
;
; 1. Overlay. A WinEvent hook watches for the dictation pill being shown (an
;    untitled "Tauri Window" owned by fluidvoice.exe; the main window carries
;    the "FluidVoice" title) and repairs two things each time:
;
;    a. On top (altic-dev/FluidVoice#996). The pill is shown "without
;       activation" (right, it must not steal focus) but Fluid never
;       re-asserts topmost on each show, so on a multi-monitor desktop it
;       lands behind the foreground app. Push it to the top of the topmost
;       band with SWP_NOACTIVATE.
;
;    b. At its real size (seen on 0.0.13, no upstream issue yet). Fluid sizes
;       the overlay once per process, on the first dictation after its daily
;       self-recycle, in the same call that moves it to the dictation target's
;       monitor. When that move crosses a DPI boundary (100% primary to a 200%
;       display) the size Fluid already scaled is scaled again by the DPI
;       change. The window comes out twice as big, and the pill, pinned to the
;       window's bottom edge, sits below the screen until the next recycle.
;       Fluid keeps positioning the window for the size it meant, so that size
;       can be read back from its own centring and restored.
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
SWP_FLAGS := 0x1 | 0x2 | 0x10   ; NOSIZE | NOMOVE | NOACTIVATE
SWP_RESIZE := 0x2 | 0x4 | 0x10  ; NOMOVE | NOZORDER | NOACTIVATE

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
    FixOverlaySize(hwnd)
    SetTimer(() => FixOverlaySize(hwnd), -150)  ; and once more after the show has settled
}

; Fluid centres the overlay in the work area of the monitor it targets, for the
; width it meant the window to have, so that width is
; 2 * (work-area centre - window left). When the real width is off by the scale
; ratio between two attached monitors, a DPI change resized the window on top
; of Fluid's own scaling: put the intended size back, keeping the top-left
; corner Fluid chose. Any other mismatch means Fluid placed the overlay some
; other way, and it is left alone.
FixOverlaySize(hwnd) {
    ; AutoHotkey is only system-DPI aware. Without this, rects on the other
    ; monitor come back virtualised and none of the arithmetic holds.
    prev := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")  ; PER_MONITOR_AWARE_V2
    try {
        rc := Buffer(16), corner := Buffer(16), mi := Buffer(40)
        NumPut("uint", 40, mi)  ; MONITORINFO.cbSize
        ; A resize that changes which monitor owns the window is itself
        ; rescaled, so look again after each one. The next one sticks.
        loop 3 {
            if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rc)
                return
            left := NumGet(rc, 0, "int"), top := NumGet(rc, 4, "int")
            w := NumGet(rc, 8, "int") - left, h := NumGet(rc, 12, "int") - top
            ; The targeted monitor is the one under the top-left corner, even
            ; when an oversized window lies mostly on another monitor.
            NumPut("int", left, "int", top, "int", left + 1, "int", top + 1, corner)
            hMon := DllCall("MonitorFromRect", "ptr", corner, "uint", 2, "ptr")  ; DEFAULTTONEAREST
            if !DllCall("GetMonitorInfo", "ptr", hMon, "ptr", mi)
                return
            want := NumGet(mi, 20, "int") + NumGet(mi, 28, "int") - 2 * left  ; rcWork.left + rcWork.right
            if (w <= 0 || want <= 0 || Abs(w - want) <= 2 || !IsDpiRescale(w / want))
                return
            DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0, "int", 0, "int", 0,
                "int", want, "int", Round(h * want / w), "uint", SWP_RESIZE)
        }
    } finally {
        DllCall("SetThreadDpiAwarenessContext", "ptr", prev, "ptr")
    }
}

; True when RATIO is what one or two DPI changes between the attached monitors
; do to a window: 2 or 0.5 for a 200% display beside a 100% one, 4 or 0.25 when
; the doubled window was then carried to the other monitor.
IsDpiRescale(ratio) {
    dpis := []
    Collect(hMon, hdc, rect, data) {
        if !DllCall("shcore\GetDpiForMonitor", "ptr", hMon, "int", 0, "uint*", &dpi := 0, "uint*", &dpiY := 0)
            dpis.Push(dpi)
        return 1
    }
    cb := CallbackCreate(Collect, "F", 4)
    DllCall("EnumDisplayMonitors", "ptr", 0, "ptr", 0, "ptr", cb, "ptr", 0)
    CallbackFree(cb)
    steps := []
    for a in dpis
        for b in dpis
            if (a != b)
                steps.Push(a / b)
    for s in steps {
        if (Abs(ratio / s - 1) < 0.02)
            return true
        for t in steps
            if (Abs(s * t - 1) > 0.05 && Abs(ratio / (s * t) - 1) < 0.02)
                return true
    }
    return false
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

; The trailing 0 matters. A non-zero return from an OnExit callback cancels the
; exit, and UnhookWindowsHookEx returns non-zero on success, so without it a
; reload stripped the old instance of its hooks and then left it running.
OnExit((*) => (DllCall("UnhookWinEvent", "ptr", hWinEvent), DllCall("UnhookWindowsHookEx", "ptr", hKeyHook), 0))
Persistent
