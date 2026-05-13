#!/bin/bash
# fagents-tty -- cross-project agent messaging via TIOCSTI.
#
# Subcommands: register | msg | ls | status | unregister
#
# Address format: <project>:<agent> where both segments match
#   ^[A-Za-z0-9_][A-Za-z0-9_-]*$
#
# Registry layout (global):
#   ~/.fagents-tty/registry/<project>/<agent>.tty   -- TTY device path
#   ~/.fagents-tty/registry/<project>/.path         -- project directory
#
# Sender identity (project-local):
#   <project>/.fagents-tty/sessions/<tty-basename>.agent
#
# Env overrides (mostly for tests):
#   FAGENTS_TTY_REGISTRY_DIR  -- registry root (default: $HOME/.fagents-tty/registry)
#   FAGENTS_TTY_WAKE_BIN      -- wake.sh path (default: alongside this script)
#   FAGENTS_TTY_FORCE_TTY     -- skip TTY detection, use this device path

set -euo pipefail

# Private-by-default for everything this script creates: 0700 dirs, 0600 files.
# fagents-tty assumes same-host/same-UID trust, but the registry and sessions
# files do not need to be world-readable, so deny group/other at create time
# rather than relying on whatever umask the caller's shell happens to have.
umask 077

# ── Paths ──

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FAGENTS_TTY_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_ROOT="$(cd "$FAGENTS_TTY_DIR/.." && pwd -P)"
CONFIG_FILE="$FAGENTS_TTY_DIR/config"
SESSIONS_DIR="$FAGENTS_TTY_DIR/sessions"

REGISTRY_ROOT="${FAGENTS_TTY_REGISTRY_DIR:-$HOME/.fagents-tty/registry}"
WAKE_BIN="${FAGENTS_TTY_WAKE_BIN:-$SCRIPT_DIR/wake.sh}"

# ── Helpers ──

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }

validate_name() {
    local name="$1"
    [ -z "$name" ] && return 1
    [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]
}

# Parse project_name= from config file. Data-only, never source/eval.
# Scans whole file; rejects unknown keys anywhere; first project_name= wins.
parse_project_name() {
    local cfg="$1" line value found=""
    [ -f "$cfg" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            project_name=*)
                if [ -z "$found" ]; then
                    value="${line#project_name=}"
                    value="${value#"${value%%[![:space:]]*}"}"
                    value="${value%"${value##*[![:space:]]}"}"
                    validate_name "$value" || return 1
                    found="$value"
                fi
                ;;
            *) return 1 ;;
        esac
    done < "$cfg"
    [ -z "$found" ] && return 1
    printf '%s' "$found"
    return 0
}

# Detect own TTY. Returns device path on stdout or returns 1.
# Honors FAGENTS_TTY_FORCE_TTY override.
detect_tty() {
    if [ -n "${FAGENTS_TTY_FORCE_TTY:-}" ]; then
        printf '%s' "$FAGENTS_TTY_FORCE_TTY"
        return 0
    fi
    local tty_dev=""
    tty_dev=$(tty 2>/dev/null) || true
    if [ -z "$tty_dev" ] || [ "$tty_dev" = "not a tty" ]; then
        tty_dev=""
        local pid=$$ ptty
        for _ in 1 2 3 4 5; do
            pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
            [ -z "$pid" ] && break
            ptty=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d '[:space:]')
            if [ -n "$ptty" ] && [ "$ptty" != "??" ]; then
                tty_dev="/dev/$ptty"
                break
            fi
        done
    fi
    [ -z "$tty_dev" ] && return 1
    printf '%s' "$tty_dev"
    return 0
}

tty_basename() {
    printf '%s' "${1##*/}"
}

# ── Commands ──

cmd_register() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: comms.sh register <agent-name>" 1
    validate_name "$name" || die "invalid-name '$name'" 1

    local project_name
    project_name=$(parse_project_name "$CONFIG_FILE") || die "no-project-config" 7

    local tty_dev
    tty_dev=$(detect_tty) || die "cannot-detect-tty (set FAGENTS_TTY_FORCE_TTY=/dev/... to override)" 1

    local registry_dir="$REGISTRY_ROOT/$project_name"
    local path_sidecar="$registry_dir/.path"

    if [ -f "$path_sidecar" ]; then
        local existing
        existing=$(cat "$path_sidecar")
        if [ "$existing" != "$PROJECT_ROOT" ]; then
            die "project-name-conflict: '$project_name' is registered to '$existing'. Re-run setup.sh with --force or pick a different --project name." 1
        fi
    fi

    mkdir -p "$registry_dir"
    [ -f "$path_sidecar" ] || printf '%s' "$PROJECT_ROOT" > "$path_sidecar"
    printf '%s' "$tty_dev" > "$registry_dir/$name.tty"

    mkdir -p "$SESSIONS_DIR"
    printf '%s' "$name" > "$SESSIONS_DIR/$(tty_basename "$tty_dev").agent"

    echo "Registered $project_name:$name -> $tty_dev"
}

cmd_msg() {
    local target="${1:-}"
    local body="${2:-}"
    [ -z "$target" ] && die "Usage: comms.sh msg <project>:<agent> <body>" 1
    # Body absent: usage error. Empty-string body falls through to sanitize -> exit 5.
    if [ "$#" -lt 2 ]; then
        die "Usage: comms.sh msg <project>:<agent> <body>" 1
    fi

    # 1. Validate address syntax
    case "$target" in
        *:*) ;;
        *) die "invalid-address '$target' (need <project>:<agent>)" 1 ;;
    esac
    local target_project="${target%%:*}"
    local target_agent="${target#*:}"
    case "$target_agent" in
        *:*) die "invalid-address '$target' (extra colon)" 1 ;;
    esac
    [ -z "$target_project" ] && die "invalid-address '$target' (empty project segment)" 1
    [ -z "$target_agent" ] && die "invalid-address '$target' (empty agent segment)" 1
    validate_name "$target_project" || die "invalid-address '$target' (project segment)" 1
    validate_name "$target_agent" || die "invalid-address '$target' (agent segment)" 1

    # 2. Sender sessions file (exit 6 if missing)
    local self_tty
    self_tty=$(detect_tty) || die "cannot-detect-tty" 1
    local sessions_file
    sessions_file="$SESSIONS_DIR/$(tty_basename "$self_tty").agent"
    [ -f "$sessions_file" ] || { echo "ERROR: not-registered-from-this-tty (run: bash $SCRIPT_DIR/comms.sh register <name>)" >&2; exit 6; }
    local sender_agent
    sender_agent=$(cat "$sessions_file")

    # 3. Project config (exit 7 if missing/invalid)
    local sender_project
    sender_project=$(parse_project_name "$CONFIG_FILE") || { echo "ERROR: no-project-config" >&2; exit 7; }

    # 4. Sanitize body (exit 5 if empty after normalization)
    # Replace control bytes with spaces, collapse runs, trim.
    local sanitized truncated=""
    sanitized=$(printf '%s' "$body" | LC_ALL=C tr '[:cntrl:]' ' ' | LC_ALL=C tr -s ' ' | sed 's/^ *//;s/ *$//')
    if [ -z "$sanitized" ]; then
        echo "ERROR: empty-body" >&2
        exit 5
    fi
    # Byte-length cap (not codepoint count -- plan and README promise bytes).
    # Use a tempfile instead of `printf | head -c` because under `set -o pipefail`
    # a very large body causes printf to be killed by SIGPIPE when head closes
    # its stdin early, making the assignment fail with exit 141.
    local tmpfile byte_len
    tmpfile=$(mktemp) || die "mktemp failed (cannot create tempfile for body sanitization)" 1
    printf '%s' "$sanitized" > "$tmpfile"
    byte_len=$(wc -c < "$tmpfile" | tr -d ' ')
    if [ "$byte_len" -gt 800 ]; then
        sanitized=$(head -c 800 "$tmpfile")
        sanitized="${sanitized}...[TRUNCATED]"
        truncated=1
    fi
    rm -f "$tmpfile"

    # 5. Target registry lookup (exit 2 if missing)
    local target_file="$REGISTRY_ROOT/$target_project/$target_agent.tty"
    [ -f "$target_file" ] || { echo "ERROR: no-such-address '$target'" >&2; exit 2; }

    # 6. Build envelope
    local envelope="[FAGENTS-TTY from $sender_project:$sender_agent]: $sanitized. Reply: bash .fagents-tty/bin/comms.sh msg $sender_project:$sender_agent \"...\""

    # 7. Invoke wake. Propagate wake's exit code on failure; else exit 4 if truncated, else 0.
    local wake_rc=0
    "$WAKE_BIN" "$target" "$envelope" || wake_rc=$?
    if [ "$wake_rc" -ne 0 ]; then
        exit "$wake_rc"
    fi
    if [ -n "$truncated" ]; then
        exit 4
    fi
    exit 0
}

cmd_ls() {
    local filter=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --project)
                filter="${2:-}"
                [ -z "$filter" ] && die "--project requires a value" 1
                shift 2
                ;;
            *) die "Unknown arg: $1" 1 ;;
        esac
    done
    if [ -n "$filter" ]; then
        validate_name "$filter" || die "invalid-name '$filter'" 1
    fi
    [ -d "$REGISTRY_ROOT" ] || return 0
    local project_dir project agent tty_file
    while IFS= read -r project_dir; do
        project=$(basename "$project_dir")
        [ -n "$filter" ] && [ "$project" != "$filter" ] && continue
        for tty_file in "$project_dir"/*.tty; do
            [ -f "$tty_file" ] || continue
            agent=$(basename "$tty_file" .tty)
            printf '%s:%s %s\n' "$project" "$agent" "$(cat "$tty_file")"
        done
    done < <(find "$REGISTRY_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
}

cmd_status() {
    local project_name
    project_name=$(parse_project_name "$CONFIG_FILE") || die "no-project-config" 7
    echo "project_name: $project_name"
    echo "project_root: $PROJECT_ROOT"
    echo "registry: $REGISTRY_ROOT/$project_name"
    echo "Registered from this project:"
    local agent_dir="$REGISTRY_ROOT/$project_name"
    if [ -d "$agent_dir" ]; then
        local tty_file agent
        for tty_file in "$agent_dir"/*.tty; do
            [ -f "$tty_file" ] || continue
            agent=$(basename "$tty_file" .tty)
            printf '  %s %s\n' "$agent" "$(cat "$tty_file")"
        done
    fi
}

cmd_unregister() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: comms.sh unregister <agent-name>" 1
    validate_name "$name" || die "invalid-name '$name'" 1

    local project_name
    project_name=$(parse_project_name "$CONFIG_FILE") || die "no-project-config" 7

    local registry_dir="$REGISTRY_ROOT/$project_name"
    local path_sidecar="$registry_dir/.path"
    if [ -f "$path_sidecar" ]; then
        local existing
        existing=$(cat "$path_sidecar")
        if [ "$existing" != "$PROJECT_ROOT" ]; then
            echo "ERROR: unregister-foreign-project: '$project_name' belongs to '$existing'" >&2
            exit 8
        fi
    fi

    local tty_file="$registry_dir/$name.tty"
    if [ -f "$tty_file" ]; then
        local tty_dev
        tty_dev=$(cat "$tty_file")
        rm -f "$tty_file"
        local sessions_file
        sessions_file="$SESSIONS_DIR/$(tty_basename "$tty_dev").agent"
        if [ -f "$sessions_file" ]; then
            local current
            current=$(cat "$sessions_file")
            if [ "$current" = "$name" ]; then
                rm -f "$sessions_file"
            fi
        fi
    fi
    echo "Unregistered $project_name:$name"
}

# ── Dispatch ──

CMD="${1:-status}"
shift || true

case "$CMD" in
    register)    cmd_register "$@" ;;
    msg)         cmd_msg "$@" ;;
    ls)          cmd_ls "$@" ;;
    status)      cmd_status "$@" ;;
    unregister)  cmd_unregister "$@" ;;
    --help|-h)
        echo "Usage: comms.sh <register|msg|ls|status|unregister> [args]"
        ;;
    *)           die "Unknown command: $CMD. Use: register|msg|ls|status|unregister" 1 ;;
esac
