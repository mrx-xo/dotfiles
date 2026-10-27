# Run with: powershell -NoProfile -File windows/scripts/tests/ahk-toggle.test.ps1
# Covers the parsing half of ahk-toggle.ps1 (command lines and Startup shortcuts)
# without touching any real AutoHotkey process.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\ahk-toggle.ps1')

$failed = 0
function Check($name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Host "ok    $name" }
    else { Write-Host "FAIL  $name`n      expected: $expected`n      actual:   $actual"; $script:failed++ }
}

# --- Get-AhkScriptPath ----------------------------------------------------------
Check 'quoted exe + quoted script' `
    (Get-AhkScriptPath '"C:\u\scoop\apps\autohotkey\current\v2\AutoHotkey64.exe"  "C:\p\tools\game-key.ahk"') `
    'C:\p\tools\game-key.ahk'
Check 'unquoted script' `
    (Get-AhkScriptPath 'C:\u\scoop\shims\AutoHotkey.exe C:\d\emacs.ahk') `
    'C:\d\emacs.ahk'
Check 'launcher switches before the script' `
    (Get-AhkScriptPath '"AutoHotkey.exe" /restart "C:\d\with space\obs-skate.ahk"') `
    'C:\d\with space\obs-skate.ahk'
Check 'no script on the command line' (Get-AhkScriptPath '"AutoHotkey64.exe"') $null
Check 'empty command line' (Get-AhkScriptPath $null) $null

# --- Get-StartupAhkScripts ------------------------------------------------------
$tmp = Join-Path $env:TEMP ("ahk-toggle-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $ws = New-Object -ComObject WScript.Shell
    # WScript only writes *.lnk; a disabled twin is written as .lnk then renamed,
    # which is also how bootstrap's .lnk.disabled files come to exist.
    $mk = {
        param($name, $target, $arguments)
        $lnk = Join-Path $tmp ($name -replace '\.disabled$', '')
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = $target; $sc.Arguments = $arguments; $sc.Save()
        if ($name -ne (Split-Path $lnk -Leaf)) { Rename-Item $lnk $name }
    }
    & $mk 'Emacs Hotkeys.lnk' 'C:\u\scoop\shims\AutoHotkey.exe' '"C:\d\autohotkey\emacs.ahk"'
    & $mk 'Syncthing.lnk' 'C:\u\scoop\shims\syncthing.exe' '--no-browser'
    & $mk 'OBS Skate Hotkey.lnk.disabled' 'C:\u\scoop\shims\AutoHotkey.exe' '"C:\d\autohotkey\obs-skate.ahk"'

    $got = @(Get-StartupAhkScripts $tmp)
    Check 'only enabled AutoHotkey shortcuts' ($got -join ';') 'C:\d\autohotkey\emacs.ahk'
} finally {
    Remove-Item -Recurse -Force $tmp
}

if ($failed) { Write-Host "$failed failed"; exit 1 }
Write-Host 'all passed'
