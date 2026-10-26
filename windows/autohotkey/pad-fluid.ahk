#Requires AutoHotkey v2.0
#SingleInstance Force
; Quick and dirty: K0 Max pad numpad * -> F20, which is FluidVoice's shortcut.
; Fluid on Windows only takes a lone key if it is a function key, and the
; stock pad sends none. Retire this once a pad key sends F20 from its own
; keymap (Keychron Launcher), then delete this file.
*NumpadMult::F20
