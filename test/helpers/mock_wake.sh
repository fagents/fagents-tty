#!/bin/bash
# Mock wake.sh for tests -- logs invocation to a file instead of TIOCSTI'ing.
#
# Env knobs:
#   FAGENTS_TTY_MOCK_WAKE_LOG    -- log file path (default: /tmp/mock_wake.log)
#   FAGENTS_TTY_MOCK_WAKE_EXIT   -- exit code to return (default: 0)
#
# Log format: one line per invocation, tab-separated: target<TAB>envelope

set -uo pipefail

LOG_FILE="${FAGENTS_TTY_MOCK_WAKE_LOG:-/tmp/mock_wake.log}"
TARGET="${1:-}"
MESSAGE="${2:-}"

mkdir -p "$(dirname "$LOG_FILE")"
printf '%s\t%s\n' "$TARGET" "$MESSAGE" >> "$LOG_FILE"

exit "${FAGENTS_TTY_MOCK_WAKE_EXIT:-0}"
