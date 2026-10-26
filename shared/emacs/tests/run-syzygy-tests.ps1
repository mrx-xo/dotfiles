# Run the SYZYGY ERT suite headless on Windows, without agent-shell.
#   pwsh shared\emacs\tests\run-syzygy-tests.ps1
# Repo root defaults to %USERPROFILE%\dotfiles; set $env:SYZYGY_DOTFILES_ROOT
# to run against another checkout.
# Exits with ERT's status.
$ErrorActionPreference = 'Stop'

$emacs = (Get-Command emacs).Source
$root = if ($env:SYZYGY_DOTFILES_ROOT) { $env:SYZYGY_DOTFILES_ROOT } else { Join-Path $env:USERPROFILE 'dotfiles' }
$syzygy = Join-Path $root 'shared\emacs\lisp\syzygy'
$macLisp = Join-Path $root 'macos\emacs\.emacs.d\lisp'
$macTests = Join-Path $root 'macos\emacs\.emacs.d\tests'

# Package setup and the temp state directory live in run-syzygy-tests.el, not
# in --eval forms: Windows PowerShell 5.1 strips double quotes from native args.
$bootstrap = Join-Path $root 'shared\emacs\tests\run-syzygy-tests.el'

$emacsArgs = @('--batch', '-Q',
    '-L', $syzygy, '-L', $macLisp, '-L', $macTests,
    '-l', $bootstrap)
Get-ChildItem -Path $syzygy -Filter '*-test.el' | Sort-Object Name | ForEach-Object {
    $emacsArgs += @('-l', $_.FullName)
}
$emacsArgs += @('-l', (Join-Path $macTests 'syzygy-recall-tests.el'),
    '-f', 'ert-run-tests-batch-and-exit')

& $emacs @emacsArgs
exit $LASTEXITCODE
