# PowerShell profile — managed in the dotfiles repo (symlinked here by bootstrap.ps1).
# Edit the copy in dotfiles/windows/powershell/ (or this file; it's the same inode).

# --- Starship prompt (gruvbox) -------------------------------------------------
$env:STARSHIP_CONFIG = Join-Path $HOME ".config\starship.toml"
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (&starship init powershell)
}

# --- PSReadLine: history autosuggest + nicer editing ---------------------------
if (Get-Module -ListAvailable PSReadLine) {
    Import-Module PSReadLine
    try {
        # PredictionSource needs PSReadLine >= 2.1; ignore on older builds.
        Set-PSReadLineOption -PredictionSource History -ErrorAction Stop
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction Stop
    } catch {}
    try { Set-PSReadLineOption -Colors @{ InlinePrediction = '#665c54' } } catch {}
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
}

# --- Quality-of-life aliases & functions ---------------------------------------
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
function ll { Get-ChildItem -Force @args }
function la { Get-ChildItem -Force -Hidden @args }
function g { git @args }
function which ($cmd) { (Get-Command $cmd -ErrorAction SilentlyContinue).Source }
function gs { git status @args }
function gl { git log --oneline --graph --decorate -20 @args }
function dotfiles { Set-Location "$HOME\dotfiles" }
function remacs { & "$HOME\dotfiles\windows\scripts\emacs-restart.ps1" }   # restart the Emacs daemon + fresh frame

# UTF-8 so the nerd-font glyphs render correctly.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
