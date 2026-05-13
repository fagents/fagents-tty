#!/bin/bash
# fagents-tty wake -- TIOCSTI delivery to a TTY device.
#
# Exit codes:
#   0  message delivered (TIOCSTI succeeded)
#   1  usage error
#   2  invalid TTY device path (failed regex validation)
#   3  sudo/TIOCSTI failure (path looks valid but write failed)
#
# Usage: wake.sh <tty-device-path> <message>
#
# v2 change: wake.sh no longer resolves <project>:<agent> -> registry path.
# comms.sh owns the search-path lookup; wake.sh is a pure mechanism that
# takes the TTY device path directly. The strict regex below closes the
# path-traversal vector that prefix-matching with `*` would have allowed.

set -euo pipefail

TTY_DEV="${1:-}"
MESSAGE="${2:-}"
[ -z "$TTY_DEV" ] || [ -z "$MESSAGE" ] && { echo "Usage: wake.sh <tty-device-path> <message>" >&2; exit 1; }

# Anchored regex: /dev/tty<alnum/dash/underscore>* OR /dev/pts/<digits>+. No
# slash, no dot, no `..` traversal possible. Pattern handles:
#   /dev/tty            (Linux controlling terminal)
#   /dev/tty0, /dev/tty1, ...
#   /dev/ttys001 (macOS pty), /dev/ttyUSB0, /dev/ttyACM0
#   /dev/pts/0, /dev/pts/123 (Linux ptys)
# Rejected examples in tests: /dev/pts/../../etc/passwd, /dev/tty/foo,
# /dev/null, /tmp/foo, /dev/ttyACM0/foo
TTY_RE='^/dev/(tty[A-Za-z0-9_-]*|pts/[0-9]+)$'
if ! [[ "$TTY_DEV" =~ $TTY_RE ]]; then
    echo "Invalid TTY device path '$TTY_DEV' (must match $TTY_RE)" >&2
    exit 2
fi

sudo -n python3 -c "
import fcntl, termios, os, sys, time
# os.fsencode round-trips argv to its raw bytes so split multibyte UTF-8 from
# comms.sh truncation does not raise UnicodeEncodeError on surrogate escapes.
raw = os.fsencode(sys.argv[2])
fd = os.open(sys.argv[1], os.O_RDWR)
for b in raw:
    fcntl.ioctl(fd, termios.TIOCSTI, bytes([b]))
time.sleep(0.5)
fcntl.ioctl(fd, termios.TIOCSTI, b'\r')
os.close(fd)
" "$TTY_DEV" "$MESSAGE" 2>&1 || {
    echo "WARN: wake failed for $TTY_DEV (sudo/TIOCSTI error)" >&2
    exit 3
}
