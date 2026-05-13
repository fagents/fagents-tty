#!/bin/bash
# fagents-tty setup -- per-project installer.
#
# Usage:
#   bash setup.sh                       # install in current dir, project_name = basename
#   bash setup.sh --project <name>      # explicit project name
#   bash setup.sh --force               # override registry slot conflict
#   bash setup.sh --update              # refresh bin scripts only
#
# Creates <project>/.fagents-tty/{bin,sessions,config,.gitignore}. Does NOT
# modify .claude/settings.json or .codex/hooks.json. Does NOT create or
# overwrite top-level launcher scripts.

set -euo pipefail

# Private-by-default for everything this script creates (registry dirs, .path,
# config, .gitignore). 0700 dirs, 0600 files. Matches comms.sh umask.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(pwd -P)"
FAGENTS_TTY_DIR="$PROJECT_DIR/.fagents-tty"
REGISTRY_ROOT="${FAGENTS_TTY_REGISTRY_DIR:-$HOME/.fagents-tty/registry}"

PROJECT_NAME=""
FORCE=""
UPDATE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --project)
            PROJECT_NAME="${2:-}"
            [ -z "$PROJECT_NAME" ] && { echo "--project requires a value" >&2; exit 1; }
            shift 2
            ;;
        --force) FORCE=1; shift ;;
        --update) UPDATE=1; shift ;;
        --help|-h)
            echo "Usage: bash setup.sh [--project <name>] [--force] [--update]"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -z "$PROJECT_NAME" ] && PROJECT_NAME=$(basename "$PROJECT_DIR")

if ! [[ "$PROJECT_NAME" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
    echo "ERROR: invalid project name '$PROJECT_NAME' (must match ^[A-Za-z0-9_][A-Za-z0-9_-]*\$)" >&2
    exit 1
fi

echo "=== fagents-tty setup ==="
echo "Project: $PROJECT_NAME"
echo "Directory: $PROJECT_DIR"
echo ""

# Update mode: refresh bin scripts only
if [ -n "$UPDATE" ]; then
    if [ ! -d "$FAGENTS_TTY_DIR/bin" ]; then
        echo "ERROR: $FAGENTS_TTY_DIR/bin not found; run setup.sh without --update first" >&2
        exit 1
    fi
    cp "$SCRIPT_DIR/bin/comms.sh" "$FAGENTS_TTY_DIR/bin/comms.sh"
    cp "$SCRIPT_DIR/bin/wake.sh" "$FAGENTS_TTY_DIR/bin/wake.sh"
    chmod +x "$FAGENTS_TTY_DIR/bin/comms.sh" "$FAGENTS_TTY_DIR/bin/wake.sh"
    echo "Refreshed .fagents-tty/bin/"
    exit 0
fi

# Path conflict check
REGISTRY_PROJECT_DIR="$REGISTRY_ROOT/$PROJECT_NAME"
PATH_SIDECAR="$REGISTRY_PROJECT_DIR/.path"
if [ -f "$PATH_SIDECAR" ]; then
    EXISTING=$(cat "$PATH_SIDECAR" 2>/dev/null || true)
    if [ "$EXISTING" != "$PROJECT_DIR" ]; then
        if [ -z "$FORCE" ]; then
            echo "ERROR: project name '$PROJECT_NAME' is registered to '$EXISTING'." >&2
            echo "  Re-run with --force to take over, or pick a different --project name." >&2
            exit 1
        fi
        # Force: nuke the old registry so this project can take over
        rm -rf "$REGISTRY_PROJECT_DIR"
        echo "Forced removal of previous registry: $EXISTING"
    fi
fi

# Claim the registry slot for this project NOW (writes .path), closing the
# gap between forced takeover (or fresh install) and first `register`. Without
# this, a third project could claim the same name with no --force in between.
mkdir -p "$REGISTRY_PROJECT_DIR"
printf '%s' "$PROJECT_DIR" > "$PATH_SIDECAR"

# Create directories
mkdir -p "$FAGENTS_TTY_DIR/bin" "$FAGENTS_TTY_DIR/sessions"
cp "$SCRIPT_DIR/bin/comms.sh" "$FAGENTS_TTY_DIR/bin/comms.sh"
cp "$SCRIPT_DIR/bin/wake.sh" "$FAGENTS_TTY_DIR/bin/wake.sh"
chmod +x "$FAGENTS_TTY_DIR/bin/comms.sh" "$FAGENTS_TTY_DIR/bin/wake.sh"

# Write config only if absent
if [ ! -f "$FAGENTS_TTY_DIR/config" ]; then
    printf 'project_name=%s\n' "$PROJECT_NAME" > "$FAGENTS_TTY_DIR/config"
fi

cat > "$FAGENTS_TTY_DIR/.gitignore" << 'EOF'
*
!.gitignore
!bin/
!bin/**
EOF

echo "Created $FAGENTS_TTY_DIR/"

# Setup does NOT install the agent skill globally. The skill file lives at
# <fagents-tty-repo>/skill/SKILL.md. If you want an agent CLI (Claude / Codex)
# to load it as a skill, symlink it yourself per-project or per-user. See
# README "Optional: install the skill" for examples.

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Start your agent (claude / codex / your CLI)."
echo "  2. From inside the agent's session, register:"
echo "       bash .fagents-tty/bin/comms.sh register <agent-name>"
echo "  3. List who else is reachable:"
echo "       bash .fagents-tty/bin/comms.sh ls"
echo "  4. Send a msg:"
echo "       bash .fagents-tty/bin/comms.sh msg <project>:<agent> \"your message\""
echo ""
echo "Optional: install the skill for your agent CLI. fagents-tty does NOT do"
echo "this for you to avoid polluting global skill dirs. See README for ways"
echo "to symlink skill/SKILL.md per-project or per-user."
echo ""
echo "Optional: auto-register on session start by adapting"
echo "templates/launch-orchestrator from the fagents-tty repo."
