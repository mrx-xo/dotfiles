#!/bin/bash

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP_SCRIPT="$REPO_ROOT/macos/scripts/configure-rbw.sh"
if [ -n "${BREW_BIN:-}" ]; then
    :
elif [ -x /opt/homebrew/bin/brew ]; then
    BREW_BIN=/opt/homebrew/bin/brew
elif [ -x /usr/local/bin/brew ]; then
    BREW_BIN=/usr/local/bin/brew
else
    BREW_BIN="$(command -v brew || true)"
fi

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf 'PASS %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n' "$1"
}

if [ -n "$BREW_BIN" ] && HOMEBREW_NO_AUTO_UPDATE=1 "$BREW_BIN" bundle list \
    --file="$REPO_ROOT/macos/Brewfile" --formula \
    | /usr/bin/grep -Fxq rbw; then
    pass "Brewfile installs rbw"
else
    fail "Brewfile installs rbw"
fi

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/configure-rbw-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"

RBW_TEST_LOG="$TEST_TMP/rbw.log"
export RBW_TEST_LOG

printf '%s\n' \
    '#!/bin/bash' \
    'printf '\''%s\n'\'' "$*" >> "$RBW_TEST_LOG"' \
    > "$TEST_TMP/bin/rbw"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TEST_TMP/bin/pinentry-mac"
chmod +x "$TEST_TMP/bin/rbw" "$TEST_TMP/bin/pinentry-mac"

if [ -x "$SETUP_SCRIPT" ] && \
    PATH="$TEST_TMP/bin:/usr/bin:/bin" "$SETUP_SCRIPT" >/dev/null; then
    expected="$(printf '%s\n' \
        'config set email m00r0@proton.me' \
        'config set base_url https://home-lab.tail9179e0.ts.net:8443' \
        "config set pinentry $TEST_TMP/bin/pinentry-mac")"
    actual="$(cat "$RBW_TEST_LOG")"
    if [ "$actual" = "$expected" ]; then
        pass "setup configures the approved Vaultwarden account"
    else
        fail "setup configures the approved Vaultwarden account"
        printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual"
    fi
else
    fail "setup configures the approved Vaultwarden account"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
