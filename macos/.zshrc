# TRAMP & other dumb terminals: bail to a plain prompt before any
# prompt/tool init runs, so remote Emacs can find the shell prompt.
# (Fancy PS1 escape codes + nvm noise otherwise hang TRAMP under PTY.)
if [[ $TERM == "dumb" ]]; then
  unsetopt zle 2>/dev/null
  PS1='$ '
  return
fi

autoload -U colors && colors
colors
# PATH=~/.console-ninja/.bin:$PATH

eval "$(/opt/homebrew/bin/brew shellenv)"
# Terminal Config

# node is managed by nvm

# nvm
export NVM_DIR="$HOME/.nvm"
source "$(brew --prefix nvm)/nvm.sh"
   # Place this after nvm initialization!
   autoload -U add-zsh-hook

# auto-check for nvm version
load-nvmrc() {
  local nvmrc_path="$(nvm_find_nvmrc)"
  [ -z "$nvmrc_path" ] && return

  local nvmrc_dir="$(dirname "$nvmrc_path")"

  # Skip if we're still in the same dir
  if [ "$nvmrc_dir" = "$NVM_PREVIOUS_DIR" ]; then
    return
  fi

  local node_version="$(nvm version)"
  local nvmrc_node_version="$(nvm version "$(cat "${nvmrc_path}")" 2>/dev/null)"

  if [ "$nvmrc_node_version" = "N/A" ]; then
    nvm install
  elif [ "$nvmrc_node_version" != "$node_version" ]; then
    nvm use
  fi

  export NVM_PREVIOUS_DIR="$nvmrc_dir"
}

add-zsh-hook chpwd load-nvmrc
load-nvmrc

# Set ls colors
export CLICOLOR=1
export LSCOLORS="gxfxcxdxbxegedabagacad"

# If you're using GNU ls (common on Linux), you can use this instead:
# eval "$(dircolors)"
alias ls='ls -G'


# Per-machine prompt name, derived from machine identity.
# MACHINE_ID is exported in ~/.zshenv (source of truth: ~/.config/machine-id).
# Run `whereami` for the full facts file. ~/.zshrc.local can still override.
case "${MACHINE_ID:-unknown}" in
  mrx)  PROMPT_NAME="${PROMPT_NAME:-MrX}" ;;
  mrx2) PROMPT_NAME="${PROMPT_NAME:-MrX2}" ;;
  *)    PROMPT_NAME="${PROMPT_NAME:-${MACHINE_ID:-?}}" ;;
esac
[ -f ~/.zshrc.local ] && source ~/.zshrc.local
PS1="%F{84}${PROMPT_NAME}%f %F{117}%1~%f %F{212}𐆖%f "

# Custom Jawns
alias mrxpath='printf "%s\n" $path'
# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/opt/homebrew/Caskroom/miniforge/base/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "/opt/homebrew/Caskroom/miniforge/base/etc/profile.d/conda.sh" ]; then
        . "/opt/homebrew/Caskroom/miniforge/base/etc/profile.d/conda.sh"
    else
        export PATH="/opt/homebrew/Caskroom/miniforge/base/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<

# Dracula Theme (for zsh-syntax-highlighting)
#
# https://github.com/zenorocha/dracula-theme
#
# Copyright 2021, All rights reserved
#
# Code licensed under the MIT license
# http://zenorocha.mit-license.org
#
# @author George Pickering <@bigpick>
# @author Zeno Rocha <hi@zenorocha.com>
# Paste this files contents inside your ~/.zshrc before you activate zsh-syntax-highlighting

# Enable colors
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main cursor)
typeset -gA ZSH_HIGHLIGHT_STYLES
# Default groupings per, https://spec.draculatheme.com, try to logically separate
# possible ZSH_HIGHLIGHT_STYLES settings accordingly...?
#
# Italics not yet supported by zsh; potentially soon:
#    https://github.com/zsh-users/zsh-syntax-highlighting/issues/432
#    https://www.zsh.org/mla/workers/2021/msg00678.html
# ... in hopes that they will, labelling accordingly with ,italic where appropriate
#
# Main highlighter styling: https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/docs/highlighters/main.md
#
## General
### Diffs
### Markup
## Classes
## Comments
ZSH_HIGHLIGHT_STYLES[comment]='fg=61'
## Constants
## Entitites
## Functions/methods
ZSH_HIGHLIGHT_STYLES[alias]='fg=84'
ZSH_HIGHLIGHT_STYLES[suffix-alias]='fg=84'
ZSH_HIGHLIGHT_STYLES[global-alias]='fg=84'
ZSH_HIGHLIGHT_STYLES[function]='fg=84'
ZSH_HIGHLIGHT_STYLES[command]='fg=84'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=84,italic'
ZSH_HIGHLIGHT_STYLES[autodirectory]='fg=215,italic'
ZSH_HIGHLIGHT_STYLES[single-hyphen-option]='fg=215'
ZSH_HIGHLIGHT_STYLES[double-hyphen-option]='fg=215'
ZSH_HIGHLIGHT_STYLES[back-quoted-argument]='fg=141'
## Keywords
## Built ins
ZSH_HIGHLIGHT_STYLES[builtin]='fg=117'
ZSH_HIGHLIGHT_STYLES[reserved-word]='fg=117'
ZSH_HIGHLIGHT_STYLES[hashed-command]='fg=117'
## Punctuation
ZSH_HIGHLIGHT_STYLES[commandseparator]='fg=212'
ZSH_HIGHLIGHT_STYLES[command-substitution-delimiter]='fg=255'
ZSH_HIGHLIGHT_STYLES[command-substitution-delimiter-unquoted]='fg=255'
ZSH_HIGHLIGHT_STYLES[process-substitution-delimiter]='fg=255'
ZSH_HIGHLIGHT_STYLES[back-quoted-argument-delimiter]='fg=212'
ZSH_HIGHLIGHT_STYLES[back-double-quoted-argument]='fg=212'
ZSH_HIGHLIGHT_STYLES[back-dollar-quoted-argument]='fg=212'
## Serializable / Configuration Languages
## Storage
## Strings
ZSH_HIGHLIGHT_STYLES[command-substitution-quoted]='fg=228'
ZSH_HIGHLIGHT_STYLES[command-substitution-delimiter-quoted]='fg=228'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument]='fg=228'
ZSH_HIGHLIGHT_STYLES[single-quoted-argument-unclosed]='fg=203'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument]='fg=228'
ZSH_HIGHLIGHT_STYLES[double-quoted-argument-unclosed]='fg=203'
ZSH_HIGHLIGHT_STYLES[rc-quote]='fg=228'
## Variables
ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument]='fg=255'
ZSH_HIGHLIGHT_STYLES[dollar-quoted-argument-unclosed]='fg=203'
ZSH_HIGHLIGHT_STYLES[dollar-double-quoted-argument]='fg=255'
ZSH_HIGHLIGHT_STYLES[assign]='fg=255'
ZSH_HIGHLIGHT_STYLES[named-fd]='fg=255'
ZSH_HIGHLIGHT_STYLES[numeric-fd]='fg=255'
## No category relevant in spec
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=203'
ZSH_HIGHLIGHT_STYLES[path]='fg=255'
ZSH_HIGHLIGHT_STYLES[path_pathseparator]='fg=212'
ZSH_HIGHLIGHT_STYLES[path_prefix]='fg=255'
ZSH_HIGHLIGHT_STYLES[path_prefix_pathseparator]='fg=212'
ZSH_HIGHLIGHT_STYLES[globbing]='fg=255'
ZSH_HIGHLIGHT_STYLES[history-expansion]='fg=141'
#ZSH_HIGHLIGHT_STYLES[command-substitution]='fg=?'
#ZSH_HIGHLIGHT_STYLES[command-substitution-unquoted]='fg=?'
#ZSH_HIGHLIGHT_STYLES[process-substitution]='fg=?'
#ZSH_HIGHLIGHT_STYLES[arithmetic-expansion]='fg=?'
ZSH_HIGHLIGHT_STYLES[back-quoted-argument-unclosed]='fg=203'
ZSH_HIGHLIGHT_STYLES[redirection]='fg=255'
ZSH_HIGHLIGHT_STYLES[arg0]='fg=255'
ZSH_HIGHLIGHT_STYLES[default]='fg=255'
ZSH_HIGHLIGHT_STYLES[cursor]='standout'

# Dracula theme main colors
# •	Green: #50FA7B (used for functions and methods)
# •	Blue: #8BE9FD (used for built-ins and reserved words)
# •	Purple: #BD93F9 (used for back-quoted arguments and history expansion)
# •	Pink: #FF79C6 (used for command separators and other punctuation)
# •	Yellow: #F1FA8C (used for strings and command substitution)
# •	White: #F8F8F2 (used for default text)

# Set up fzf key bindings and fuzzy completion
source <(fzf --zsh)
source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Git 

alias g="git"
alias gp="git push"
alias gpf="git push --force"
alias gpl="g pull"
alias gpls="g pull --recurse-submodules"
alias gst="git stash"
alias gstp="git stash pop"
alias gs="git status"
alias gw="git switch"
alias gb="git branch"
alias gsc="git switch -c"
alias gco="git checkout"
alias grb="git rebase"
alias gcan="git commit --amend --no-edit"
alias gprn="git fetch --prune && git branch -vv | grep ': gone]' | awk '{print \$1}' | xargs git branch -D"


alias pn="pnpm"



# Task Master aliases added on 7/4/2025
alias tm='task-master'
alias taskmaster='task-master'

# Emacs-plus@30 aliases
alias emacs="$(brew --prefix emacs-plus@30)/bin/emacs"
alias emacsclient="$(brew --prefix emacs-plus@30)/bin/emacsclient"

# Emacs daemon and client aliases
alias ec='emacsclient -n'           # Open in existing frame, no wait
alias ecn='emacsclient -nc'         # New frame, no wait
alias ecd='emacs --daemon'          # Start daemon
alias eck='emacsclient -e "(kill-emacs)"'  # Kill daemon
alias etest='emacs --batch -l ~/.emacs.d/init.el -l ~/.emacs.d/tests/config-tests.el -f ert-run-tests-batch-and-exit'
alias ports='lsof -iTCP -sTCP:LISTEN -P -n'
alias ipleak='~/.dotfiles/macos/scripts/ipleak-check.sh'
alias reload='source ~/.zshrc'
alias shl='ssh homelab'
alias shm2='ssh mrx2'
alias shv='ssh vengeance'


# Fix for Emacs native compilation with libgccjit
export LIBRARY_PATH="/opt/homebrew/opt/libgccjit/lib/gcc/current:/opt/homebrew/Cellar/gcc/15.1.0/lib/gcc/current/gcc/aarch64-apple-darwin24/15:$LIBRARY_PATH"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.bun/bin:$PATH"

# Yazi - cd to directory on quit
function y() {
  local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
  yazi "$@" --cwd-file="$tmp"
  if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
    builtin cd -- "$cwd"
  fi
  rm -f -- "$tmp"
}


# Claude Code deferred MCP loading (added by Taskmaster)
export ENABLE_EXPERIMENTAL_MCP_CLI='true'

# Home lab media upload aliases
alias upmovie="upload-media"
alias upshow="upload-media \$1 shows"

# Bind Ollama to the Tailscale interface only (tailnet-reachable, not exposed on LAN/public wifi)
# Reachable from other tailnet devices as http://mrx2:11434 or http://100.84.72.38:11434.
# Revert to 0.0.0.0 if you need it on the plain LAN or on localhost without tailscale.
export OLLAMA_HOST=100.84.72.38
