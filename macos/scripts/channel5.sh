#!/bin/bash
# Launch the prepared Nabu briefing in Electron. Aliases: nabu-poc, nabu-dev.
# --inspector opens the console; --refresh prepares a new run first.
# Local configuration: ~/.config/channel5/launcher.env (shell assignments)
# CHANNEL5_APP_DIR, CHANNEL5_HA_URL, CHANNEL5_TOKEN_FILE, CHANNEL5_DATA_DIR.
# Machine/service addresses belong in that local file, not this public repo.
set -euo pipefail

refresh=false
inspector=false
for arg in "$@"; do
  case "$arg" in
    --refresh) refresh=true ;;
    --inspector) inspector=true ;;
    --help|-h)
      echo 'Usage: nabu-poc [--refresh] [--inspector]'
      echo '       nabu-dev [--refresh]'
      echo 'Reuses a valid saved briefing, otherwise prepares one. Playback starts on click.'
      exit 0 ;;
    *) echo "Unknown option: $arg (use --help)" >&2; exit 2 ;;
  esac
done

config="${CHANNEL5_CONFIG:-$HOME/.config/channel5/launcher.env}"
if [[ -f "$config" ]]; then source "$config"; fi
app_dir="${CHANNEL5_APP_DIR:-$HOME/home-lab-worktrees/main/services/briefing-show-electron}"
data_dir="${CHANNEL5_DATA_DIR:-$HOME/.local/share/channel5/briefings}"
token_file="${CHANNEL5_TOKEN_FILE:-$HOME/.config/gaia/ha-token.txt}"
[[ -f "$app_dir/prepare.mjs" ]] || { echo "Electron briefing not found: $app_dir" >&2; exit 1; }
command -v node >/dev/null || { echo 'Node.js 22 or newer is required.' >&2; exit 1; }
command -v npm >/dev/null || { echo 'npm is required.' >&2; exit 1; }
cd "$app_dir"
# Preparation can acquire runtime dependencies when the app checkout advances.
if ! npm ls --depth=0 --silent >/dev/null 2>&1; then npm ci; fi

briefing_run=''
if [[ "$refresh" == false ]]; then
  briefing_run=$(node - "$data_dir/sergio" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const {loadPrepared} = require('./bundle.cjs');
try {
  const root = fs.realpathSync(process.argv[2]);
  const pointer = JSON.parse(fs.readFileSync(path.join(root, 'latest.json'), 'utf8'));
  const file = fs.realpathSync(path.resolve(root, pointer.manifest));
  if (!file.startsWith(root + path.sep)) throw Error('Saved run escapes its directory');
  if (loadPrepared(file).person !== 'sergio') throw Error('Saved run belongs to another person');
  console.log(file);
} catch {
  // Missing, expired or invalid bundles must be prepared again before launch.
  process.exitCode = 1;
}
JS
  ) || briefing_run=''
fi

if [[ -z "$briefing_run" ]]; then
  [[ -n "${CHANNEL5_HA_URL:-}" ]] || { echo "Set CHANNEL5_HA_URL in $config before preparing a briefing." >&2; exit 1; }
  [[ -r "$token_file" ]] || { echo "HA token file is not readable: $token_file" >&2; exit 1; }
  echo 'Preparing a fresh Nabu briefing (about one minute)...'
  briefing_run=$(node prepare.mjs --ha-url "$CHANNEL5_HA_URL" \
    --person sergio --voice bm_daniel --output "$data_dir" < "$token_file")
else
  echo 'Using the saved Nabu briefing.'
fi

echo 'Opening on the agent desktop. Start briefing or Listen begins audio.'
if [[ "$inspector" == true ]]; then
  exec npm run preview -- --inspector --run "$briefing_run"
fi
exec npm run preview -- --run "$briefing_run"
