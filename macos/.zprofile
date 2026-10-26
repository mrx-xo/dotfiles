# /etc/zprofile runs path_helper after .zshenv and puts /usr/local/bin
# ahead of native Homebrew.  Restore the arm64 toolchain for every login
# shell, including noninteractive agents and TERM=dumb shells that return
# early from .zshrc.  HOMEBREW_PREFIX may already be set, so brew shellenv
# alone is not sufficient here.
typeset -U path
path=(/opt/homebrew/bin /opt/homebrew/sbin $path)
