#!/bin/bash
# fagents-tty wake -- TIOCSTI delivery to a registered TTY.
#
# Exit codes:
#   0  message delivered (TIOCSTI succeeded)
#   1  usage error
#   2  no TTY registered for the target
#   3  sudo/TIOCSTI failure (target TTY exists but write failed)
#
# Usage: wake.sh <project>:<agent> <message>
#
# The registry path is ${FAGENTS_TTY_REGISTRY_DIR:-$HOME/.fagents-tty/registry}.
# Tests override this env var to avoid touching the real registry.

set -euo pipefail

TARGET="${1:-}"
MESSAGE="${2:-}"
[ -z "$TARGET" ] || [ -z "$MESSAGE" ] && { echo "Usage: wake.sh <project>:<agent> <message>" >&2; exit 1; }

case "$TARGET" in
    *:*) ;;
    *) echo "Invalid target '$TARGET' (need <project>:<agent>)" >&2; exit 1 ;;
esac
TARGET_PROJECT="${TARGET%%:*}"
TARGET_AGENT="${TARGET#*:}"
case "$TARGET_AGENT" in
    *:*) echo "Invalid target '$TARGET' (extra colon)" >&2; exit 1 ;;
esac

# Validate both segments BEFORE path construction. wake.sh is documented as a
# public command, so untrusted callers (e.g. `wake.sh ../escape:agent`) must
# not be able to read outside the registry root.
NAME_RE='^[A-Za-z0-9_][A-Za-z0-9_-]*$'
if ! [[ "$TARGET_PROJECT" =~ $NAME_RE ]]; then
    echo "Invalid target '$TARGET' (project segment failed validation)" >&2
    exit 1
fi
if ! [[ "$TARGET_AGENT" =~ $NAME_RE ]]; then
    echo "Invalid target '$TARGET' (agent segment failed validation)" >&2
    exit 1
fi

REGISTRY_ROOT="${FAGENTS_TTY_REGISTRY_DIR:-$HOME/.fagents-tty/registry}"
REGISTRY_FILE="$REGISTRY_ROOT/$TARGET_PROJECT/$TARGET_AGENT.tty"

TTY_DEV=$(tr -d '[:space:]' < "$REGISTRY_FILE" 2>/dev/null) || {
    echo "WARN: no TTY registered for $TARGET" >&2
    exit 2
}

sudo -n python3 -c "
import fcntl, termios, os, sys, time
# os.fsencode round-trips argv to its raw bytes, which lets us inject any byte
# sequence (including split multibyte UTF-8 from comms.sh truncation) without
# the default str-encode loop raising UnicodeEncodeError on surrogate escapes.
raw = os.fsencode(sys.argv[2])
fd = os.open(sys.argv[1], os.O_RDWR)
for b in raw:
    fcntl.ioctl(fd, termios.TIOCSTI, bytes([b]))
time.sleep(0.5)
fcntl.ioctl(fd, termios.TIOCSTI, b'\r')
os.close(fd)
" "$TTY_DEV" "$MESSAGE" 2>&1 || {
    echo "WARN: wake failed for $TARGET (sudo/TIOCSTI error)" >&2
    exit 3
}
