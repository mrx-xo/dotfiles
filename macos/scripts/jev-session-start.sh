#!/usr/bin/env bash

set -euo pipefail

hook_path="${HOME}/src/jevwire/plugin/dist/hook.mjs"
node_bin="$(command -v node)"

unset TYPESAFE_API_KEY
typesafe_api_key=""
if secret_bin="$(command -v secret 2>/dev/null)" \
  && timeout_bin="$(command -v timeout 2>/dev/null)"; then
  typesafe_api_key="$("$timeout_bin" 3 "$secret_bin" typesafe-api-token 2>/dev/null || true)"
fi

if [[ -n "$typesafe_api_key" ]]; then
  export TYPESAFE_API_KEY="$typesafe_api_key"
fi

exec "$node_bin" "$hook_path" SessionStart
