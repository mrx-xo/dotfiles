# Run the SYZYGY ERT suite headless on Windows, without agent-shell.
#   pwsh shared\emacs\tests\run-syzygy-tests.ps1
# Exits with ERT's status.
$ErrorActionPreference = 'Stop'

$emacs = (Get-Command emacs).Source
$root = Join-Path $env:USERPROFILE 'dotfiles'
$syzygy = Join-Path $root 'shared\emacs\lisp\syzygy'
$macLisp = Join-Path $root 'macos\emacs\.emacs.d\lisp'
$macTests = Join-Path $root 'macos\emacs\.emacs.d\tests'

# agent-recall comes from package.el on this box.
$elpa = '(setq package-user-dir (expand-file-name ".emacs.d/elpa" (getenv "APPDATA")))'

# The state directory is bound to a fresh temp dir before any test file loads,
# so a batch run can never touch the real ~/.acp-mobile sidecars.
$state = '(setq syzygy-state-directory (file-name-as-directory (make-temp-file "syzygy-tests-" t)))'

$emacsArgs = @('--batch', '-Q',
    '--eval', $elpa, '--eval', '(package-initialize)',
    '-L', $syzygy, '-L', $macLisp, '-L', $macTests,
    '--eval', '(require (quote syzygy-state))',
    '--eval', $state)
Get-ChildItem -Path $syzygy -Filter '*-test.el' | Sort-Object Name | ForEach-Object {
    $emacsArgs += @('-l', $_.FullName)
}
$emacsArgs += @('-l', (Join-Path $macTests 'syzygy-recall-tests.el'),
    '-f', 'ert-run-tests-batch-and-exit')

& $emacs @emacsArgs
exit $LASTEXITCODE
