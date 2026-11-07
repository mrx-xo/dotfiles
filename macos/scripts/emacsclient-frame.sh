#!/bin/bash
# Wait for the daemon to be ready, then open a client frame

EMACSCLIENT="/opt/homebrew/opt/emacs-plus@31/bin/emacsclient"
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if $EMACSCLIENT -e '(+ 1 1)' &>/dev/null; then
        $EMACSCLIENT -c -n
        exit 0
    fi
    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
done

echo "Emacs daemon did not start in time"
exit 1
