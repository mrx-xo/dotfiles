#!/bin/bash
# Build the reviewed upstream CLI. No connection or wake trigger is activated.
set -euo pipefail
revision=4b7a9df950a64239b2a073428f0390fc16934a9e
sidecar_dir="$HOME/.local/share/sidecar"
source_dir="$sidecar_dir/SidecarLauncher"
mkdir -p "$sidecar_dir" "$HOME/.local/bin"
if [[ ! -d "$source_dir" ]]; then
  git clone --no-checkout https://github.com/Ocasio-J/SidecarLauncher.git "$source_dir"
  git -C "$source_dir" checkout --detach "$revision"
fi
if [[ $(git -C "$source_dir" rev-parse HEAD) != "$revision" ]] ||
   [[ -n $(git -C "$source_dir" status --porcelain) ]]; then
  printf 'Expected clean SidecarLauncher source at %s; inspect %s before building.\n' "$revision" "$source_dir" >&2
  exit 1
fi
/usr/bin/xcrun swiftc -O "$source_dir/SidecarLauncher/main.swift" \
  -o "$sidecar_dir/SidecarLauncher-cli"
link="$HOME/.local/bin/sidecar"
target="$HOME/.dotfiles/macos/scripts/sidecar.sh"
if [[ -e "$link" || -L "$link" ]]; then
  [[ -L "$link" && $(readlink "$link") == "$target" ]] || {
    printf 'Existing path is not our sidecar link: %s\n' "$link" >&2; exit 1;
  }
else
  ln -s "$target" "$link"
fi
printf 'Installed SidecarLauncher (%s) and sidecar command.\n' "$revision"
