' run-hidden.vbs -- launch a console app with no window at all.
' Windows has no native "start hidden" for console apps in the Startup
' folder (the .lnk WindowStyle=7 hint is ignored once Windows Terminal is
' the default console host, and GlazeWM then tiles the empty terminals).
' Startup shortcuts point here instead: wscript run-hidden.vbs <exe> [args...]
Set sh = CreateObject("WScript.Shell")
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If InStr(a, " ") > 0 Then a = """" & a & """"
    cmd = cmd & a & " "
Next
sh.Run Trim(cmd), 0, False
