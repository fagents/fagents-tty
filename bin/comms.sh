#!/bin/bash
# fagents-tty -- cross-project agent messaging via TIOCSTI.
#
# Subcommands: register | msg | ls | status | unregister
#
# Address format: <project>:<agent> where both segments match
#   ^[A-Za-z0-9_][A-Za-z0-9_-]*$
#
# v2 data model: per-project only. No global registry, no config file, no
# sessions/ dir. Layout:
#   <project>/.fagents-tty/agents/<agent>.tty   -- contents: TTY device path
# Project name == basename of project directory. Filesystem is truth.
#
# Discovery (used by `ls` and `msg`):
#   - Default: dirname "$PROJECT_ROOT"  (parent dir of this project)
#   - Override: FAGENTS_TTY_SEARCH_PATH (colon-separated, no empty components)
#
# Env overrides (mostly for tests):
#   FAGENTS_TTY_WAKE_BIN      -- wake.sh path (default: alongside this script)
#   FAGENTS_TTY_FORCE_TTY     -- skip TTY detection, use this device path
#   FAGENTS_TTY_SEARCH_PATH   -- override discovery scope

set -euo pipefail

umask 077

# -- Paths --

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FAGENTS_TTY_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_ROOT="$(cd "$FAGENTS_TTY_DIR/.." && pwd -P)"
AGENTS_DIR="$FAGENTS_TTY_DIR/agents"

WAKE_BIN="${FAGENTS_TTY_WAKE_BIN:-$SCRIPT_DIR/wake.sh}"

NAME_RE='^[A-Za-z0-9_][A-Za-z0-9_-]*$'

# -- Helpers --

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }

validate_name() {
    local name="$1"
    [ -z "$name" ] && return 1
    [[ "$name" =~ $NAME_RE ]]
}

# Derive sender project name from basename of PROJECT_ROOT.
# Exits 7 if the basename does not satisfy the name regex.
sender_project_name() {
    local name
    name=$(basename "$PROJECT_ROOT")
    validate_name "$name" || die "invalid-project-dirname '$name' (must match $NAME_RE)" 7
    printf '%s' "$name"
}

# Detect own TTY. Returns device path on stdout or returns 1.
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

# Compute the discovery search roots. Honors FAGENTS_TTY_SEARCH_PATH if set
# (rejects empty components pre-split, same pattern as v1.1 --agents parser).
# Sets the global SEARCH_ROOTS array.
populate_search_roots() {
    SEARCH_ROOTS=()
    if [ -n "${FAGENTS_TTY_SEARCH_PATH:-}" ]; then
        local raw="$FAGENTS_TTY_SEARCH_PATH"
        case "$raw" in
            :*|*:|*::*) die "invalid-search-path: empty component in FAGENTS_TTY_SEARCH_PATH '$raw'" 1 ;;
        esac
        local IFS=':'
        local -a tmp
        read -ra tmp <<< "$raw"
        local root
        for root in "${tmp[@]}"; do
            [ -z "$root" ] && die "invalid-search-path: empty component in FAGENTS_TTY_SEARCH_PATH '$raw'" 1
            SEARCH_ROOTS+=("$root")
        done
    else
        SEARCH_ROOTS=("$(dirname "$PROJECT_ROOT")")
    fi
}

# Walk own agents/*.tty, find the one whose contents match my detected TTY.
# Sets SENDER_AGENT. Exits 6 on zero or multiple matches.
resolve_sender_agent() {
    local self_tty match_count="" agent tty_file contents
    self_tty=$(detect_tty) || die "cannot-detect-tty" 1
    SENDER_AGENT=""
    match_count=0
    if [ -d "$AGENTS_DIR" ]; then
        for tty_file in "$AGENTS_DIR"/*.tty; do
            [ -f "$tty_file" ] || continue
            contents=$(cat "$tty_file" 2>/dev/null)
            if [ "$contents" = "$self_tty" ]; then
                agent=$(basename "$tty_file" .tty)
                SENDER_AGENT="$agent"
                match_count=$((match_count + 1))
            fi
        done
    fi
    if [ "$match_count" -eq 0 ]; then
        echo "ERROR: not-registered-from-this-tty (run: bash $SCRIPT_DIR/comms.sh register <name>)" >&2
        exit 6
    fi
    if [ "$match_count" -gt 1 ]; then
        echo "ERROR: ambiguous-sender-tty (multiple agents claim $self_tty in this project)" >&2
        exit 6
    fi
}

# -- Commands --

cmd_register() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: comms.sh register <agent-name>" 1
    validate_name "$name" || die "invalid-name '$name'" 1

    # Sanity: project dir name must be valid (defends against agents/ being
    # created inside a malformed project dir).
    sender_project_name >/dev/null

    local tty_dev
    tty_dev=$(detect_tty) || die "cannot-detect-tty (set FAGENTS_TTY_FORCE_TTY=/dev/... to override)" 1

    mkdir -p "$AGENTS_DIR"
    chmod 0700 "$AGENTS_DIR"

    # Self-cleaning: remove any existing entries that point at MY TTY. End
    # state: at most one agents/<name>.tty per TTY in this project.
    local tty_file contents
    if [ -d "$AGENTS_DIR" ]; then
        for tty_file in "$AGENTS_DIR"/*.tty; do
            [ -f "$tty_file" ] || continue
            contents=$(cat "$tty_file" 2>/dev/null)
            if [ "$contents" = "$tty_dev" ]; then
                rm -f "$tty_file"
            fi
        done
    fi

    printf '%s' "$tty_dev" > "$AGENTS_DIR/$name.tty"
    chmod 0600 "$AGENTS_DIR/$name.tty"

    local proj
    proj=$(sender_project_name)
    echo "Registered $proj:$name -> $tty_dev"
}

cmd_msg() {
    local target="${1:-}"
    [ -z "$target" ] && die "Usage: comms.sh msg <project>:<agent> <body>" 1
    if [ "$#" -lt 2 ]; then
        die "Usage: comms.sh msg <project>:<agent> <body>" 1
    fi
    local body="$2"

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

    # 2. Sender identity
    local sender_project
    sender_project=$(sender_project_name)
    resolve_sender_agent  # sets SENDER_AGENT, exits 6 on failure

    # 3. Sanitize body. Replace control bytes with spaces, collapse runs, trim.
    local sanitized truncated=""
    sanitized=$(printf '%s' "$body" | LC_ALL=C tr '[:cntrl:]' ' ' | LC_ALL=C tr -s ' ' | sed 's/^ *//;s/ *$//')
    if [ -z "$sanitized" ]; then
        echo "ERROR: empty-body" >&2
        exit 5
    fi
    # Byte-length cap via tempfile (avoids SIGPIPE under pipefail on large bodies).
    local tmpfile byte_len
    tmpfile=$(mktemp) || die "mktemp failed" 1
    printf '%s' "$sanitized" > "$tmpfile"
    byte_len=$(wc -c < "$tmpfile" | tr -d ' ')
    if [ "$byte_len" -gt 800 ]; then
        sanitized=$(head -c 800 "$tmpfile")
        sanitized="${sanitized}...[TRUNCATED]"
        truncated=1
    fi
    rm -f "$tmpfile"

    # 4. Build search roots
    populate_search_roots

    # 5. Collect PROJECT-LEVEL matches across search roots
    local -a project_matches=()
    local root candidate_dir
    for root in "${SEARCH_ROOTS[@]}"; do
        candidate_dir="$root/$target_project/.fagents-tty/agents"
        [ -d "$candidate_dir" ] && project_matches+=("$candidate_dir")
    done

    # 6. Ambiguity check (project-level, before agent file lookup)
    if [ "${#project_matches[@]}" -gt 1 ]; then
        echo "ERROR: ambiguous-target '$target' (matches multiple search roots):" >&2
        local m
        for m in "${project_matches[@]}"; do
            echo "  $m" >&2
        done
        exit 9
    fi

    # 7. No project match
    if [ "${#project_matches[@]}" -eq 0 ]; then
        echo "ERROR: no-such-project '$target_project' in any search root" >&2
        exit 2
    fi

    # 8. Single match -- check agent file
    local target_agents_dir="${project_matches[0]}"
    local target_file="$target_agents_dir/$target_agent.tty"
    if [ ! -f "$target_file" ]; then
        echo "ERROR: no-such-agent '$target' in $target_agents_dir" >&2
        exit 2
    fi
    local target_tty
    target_tty=$(cat "$target_file")

    # 9. Build envelope and invoke wake
    local envelope="[FAGENTS-TTY from $sender_project:$SENDER_AGENT]: $sanitized. Reply: bash .fagents-tty/bin/comms.sh msg $sender_project:$SENDER_AGENT \"...\""

    local wake_rc=0
    "$WAKE_BIN" "$target_tty" "$envelope" || wake_rc=$?
    if [ "$wake_rc" -ne 0 ]; then
        # Any wake failure (usage=1, regex-reject=2, TIOCSTI fail=3) maps to
        # msg's documented wake-failure code 3. Preserves the msg API contract
        # where exit 2 means "no such project/agent" (lookup-miss), not "the
        # target's registered TTY path was corrupt/invalid".
        exit 3
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

    populate_search_roots

    # Walk search roots, list <root>/*/.fagents-tty/agents/*.tty
    # Skip the current project's own agents dir. With multiple roots, append
    # @<root> to each line if more than one root is configured.
    local root project_dir project_name agents_dir tty_file agent
    local multi_root=""
    [ "${#SEARCH_ROOTS[@]}" -gt 1 ] && multi_root=1

    local lines=()
    for root in "${SEARCH_ROOTS[@]}"; do
        [ -d "$root" ] || continue
        for project_dir in "$root"/*/; do
            [ -d "$project_dir" ] || continue
            project_dir="${project_dir%/}"
            project_name=$(basename "$project_dir")
            # Skip the current project (we're listing "who else")
            [ "$project_dir" = "$PROJECT_ROOT" ] && continue
            # Skip names that fail validation (might be unrelated dirs in the root)
            validate_name "$project_name" || continue
            [ -n "$filter" ] && [ "$project_name" != "$filter" ] && continue
            agents_dir="$project_dir/.fagents-tty/agents"
            [ -d "$agents_dir" ] || continue
            for tty_file in "$agents_dir"/*.tty; do
                [ -f "$tty_file" ] || continue
                agent=$(basename "$tty_file" .tty)
                local line tty_path
                tty_path=$(cat "$tty_file")
                if [ -n "$multi_root" ]; then
                    line=$(printf '%s:%s %s @%s' "$project_name" "$agent" "$tty_path" "$root")
                else
                    line=$(printf '%s:%s %s' "$project_name" "$agent" "$tty_path")
                fi
                lines+=("$line")
            done
        done
    done
    [ "${#lines[@]}" -eq 0 ] && return 0
    printf '%s\n' "${lines[@]}" | LC_ALL=C sort
}

cmd_status() {
    local proj
    proj=$(sender_project_name)
    echo "project_name: $proj"
    echo "project_root: $PROJECT_ROOT"
    echo "Registered from this project:"
    if [ -d "$AGENTS_DIR" ]; then
        local tty_file agent
        for tty_file in "$AGENTS_DIR"/*.tty; do
            [ -f "$tty_file" ] || continue
            agent=$(basename "$tty_file" .tty)
            printf '  %s %s\n' "$agent" "$(cat "$tty_file")"
        done
    fi
    populate_search_roots
    echo "Search roots (for ls / msg discovery):"
    local root
    for root in "${SEARCH_ROOTS[@]}"; do
        echo "  $root"
    done
}

cmd_unregister() {
    local name="${1:-}"
    [ -z "$name" ] && die "Usage: comms.sh unregister <agent-name>" 1
    validate_name "$name" || die "invalid-name '$name'" 1
    local target="$AGENTS_DIR/$name.tty"
    if [ -f "$target" ]; then
        rm -f "$target"
    fi
    local proj
    proj=$(sender_project_name)
    echo "Unregistered $proj:$name"
}

# -- Dispatch --

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
