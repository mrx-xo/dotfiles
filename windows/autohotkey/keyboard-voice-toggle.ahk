#Requires AutoHotkey v2.0
#SingleInstance Ignore
; One-shot action for the keyboard-voice-toggle interactive scheduled task.
; FluidVoice's configured dictation shortcut is F20. No focus or clipboard changes.
if !ProcessExist("fluidvoice.exe")
    ExitApp(2)
if A_Args.Length && A_Args[1] = "--check"
    ExitApp(0)
SendEvent("{F20}")
ExitApp(0)
