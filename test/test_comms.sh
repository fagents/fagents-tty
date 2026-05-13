#!/bin/bash
# test_comms.sh -- bash test suite for fagents-tty comms.sh
#
# Run: bash test/test_comms.sh
#
# Tests use temp dirs and FAGENTS_TTY_REGISTRY_DIR / FAGENTS_TTY_WAKE_BIN /
# FAGENTS_TTY_FORCE_TTY env overrides to avoid touching real registry or TTYs.
# All wake calls are mocked via test/helpers/mock_wake.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
COMMS_SRC="$REPO_ROOT/bin/comms.sh"
WAKE_SRC="$REPO_ROOT/bin/wake.sh"
MOCK_WAKE="$SCRIPT_DIR/helpers/mock_wake.sh"

PASS=0
FAIL=0
FAILED_DETAILS=()

# ── Assertion helpers ──

assert() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("$desc -- expected: '$expected', got: '$actual'")
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("$desc -- needle not found: '$needle' in '$haystack'")
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("$desc -- file does not exist: $path")
    fi
}

assert_file_missing() {
    local desc="$1" path="$2"
    if [ ! -e "$path" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("$desc -- file unexpectedly exists: $path")
    fi
}

assert_file_unchanged() {
    local desc="$1" path="$2" expected_sha="$3"
    local actual_sha
    actual_sha=$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')
    if [ "$actual_sha" = "$expected_sha" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("$desc -- file changed: $path (expected sha $expected_sha, got $actual_sha)")
    fi
}

# Portable file-mode helper: returns octal mode (e.g. "600", "700"). Both
# `stat -f '%Lp'` (macOS/BSD) and `stat -c '%a'` (GNU) already format the
# permission bits as an octal string, so we just pass them through.
file_mode() {
    local m
    if m=$(stat -f '%Lp' "$1" 2>/dev/null); then
        printf '%s' "$m"
    elif m=$(stat -c '%a' "$1" 2>/dev/null); then
        printf '%s' "$m"
    else
        return 1
    fi
}

# ── Env setup ──

setup_env() {
    local project_name="$1"
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    PROJECT_DIR="$TMPDIR/$project_name"
    # NB: do NOT pre-create .fagents-tty/sessions; let comms.sh register
    # create it under its own umask 077 so file-mode tests are meaningful.
    mkdir -p "$PROJECT_DIR/.fagents-tty/bin"
    cp "$COMMS_SRC" "$PROJECT_DIR/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$PROJECT_DIR/.fagents-tty/bin/wake.sh"
    chmod +x "$PROJECT_DIR/.fagents-tty/bin/comms.sh" "$PROJECT_DIR/.fagents-tty/bin/wake.sh"
    printf 'project_name=%s\n' "$project_name" > "$PROJECT_DIR/.fagents-tty/config"

    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
    export FAGENTS_TTY_WAKE_BIN="$MOCK_WAKE"
    export FAGENTS_TTY_MOCK_WAKE_LOG="$TMPDIR/wake.log"
    export FAGENTS_TTY_MOCK_WAKE_EXIT=0
    export FAGENTS_TTY_FORCE_TTY="/dev/ttys999"
}

setup_second_project() {
    local project_name="$1" force_tty="$2"
    SECOND_PROJECT_DIR="$TMPDIR/$project_name"
    mkdir -p "$SECOND_PROJECT_DIR/.fagents-tty/bin"
    cp "$COMMS_SRC" "$SECOND_PROJECT_DIR/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$SECOND_PROJECT_DIR/.fagents-tty/bin/wake.sh"
    chmod +x "$SECOND_PROJECT_DIR/.fagents-tty/bin/comms.sh" "$SECOND_PROJECT_DIR/.fagents-tty/bin/wake.sh"
    printf 'project_name=%s\n' "$project_name" > "$SECOND_PROJECT_DIR/.fagents-tty/config"
    FAGENTS_TTY_FORCE_TTY="$force_tty" \
        bash "$SECOND_PROJECT_DIR/.fagents-tty/bin/comms.sh" register "${3:-remote}" >/dev/null
}

teardown_env() {
    if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && [[ "$TMPDIR" == /var/* || "$TMPDIR" == /tmp/* || "$TMPDIR" == /private/var/* ]]; then
        rm -rf "$TMPDIR"
    fi
    unset FAGENTS_TTY_REGISTRY_DIR FAGENTS_TTY_WAKE_BIN FAGENTS_TTY_MOCK_WAKE_LOG FAGENTS_TTY_MOCK_WAKE_EXIT FAGENTS_TTY_FORCE_TTY
    unset TMPDIR PROJECT_DIR SECOND_PROJECT_DIR
}

# Run comms.sh from PROJECT_DIR. Captures merged stdout+stderr in COMMS_OUT, exit code in COMMS_RC.
run_comms() {
    COMMS_OUT=$(cd "$PROJECT_DIR" && bash .fagents-tty/bin/comms.sh "$@" 2>&1)
    COMMS_RC=$?
}

# Same but with an explicit FAGENTS_TTY_FORCE_TTY override (used for multi-TTY scenarios).
run_comms_with_tty() {
    local tty="$1"; shift
    COMMS_OUT=$(cd "$PROJECT_DIR" && FAGENTS_TTY_FORCE_TTY="$tty" bash .fagents-tty/bin/comms.sh "$@" 2>&1)
    COMMS_RC=$?
}

# ── Tests ──

test_1() {
    setup_env "projP"
    run_comms register foo
    assert "test 1: register exit 0" "$COMMS_RC" "0"
    assert_file_exists "test 1: registry/projP/foo.tty exists" "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty"
    local content
    content=$(cat "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty")
    assert "test 1: registry file holds TTY path" "$content" "/dev/ttys999"
    teardown_env
}

test_2() {
    setup_env "projP"
    run_comms register foo
    assert_file_exists "test 2: .path sidecar exists" "$FAGENTS_TTY_REGISTRY_DIR/projP/.path"
    local content
    content=$(cat "$FAGENTS_TTY_REGISTRY_DIR/projP/.path")
    assert "test 2: .path contains project dir" "$content" "$PROJECT_DIR"
    teardown_env
}

test_3() {
    setup_env "projP"
    run_comms register foo
    assert_file_exists "test 3: sessions/ttys999.agent exists" "$PROJECT_DIR/.fagents-tty/sessions/ttys999.agent"
    local content
    content=$(cat "$PROJECT_DIR/.fagents-tty/sessions/ttys999.agent")
    assert "test 3: sessions file names agent" "$content" "foo"
    teardown_env
}

test_4() {
    setup_env "projP"
    run_comms register foo
    local sha1
    sha1=$(shasum -a 256 "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty" | awk '{print $1}')
    run_comms register foo
    assert "test 4: idempotent re-register exits 0" "$COMMS_RC" "0"
    assert_file_unchanged "test 4: registry file unchanged" "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty" "$sha1"
    teardown_env
}

test_5() {
    setup_env "projP"
    run_comms register foo
    run_comms register bar
    assert_file_exists "test 5a: foo.tty still exists" "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty"
    assert_file_exists "test 5b: bar.tty exists" "$FAGENTS_TTY_REGISTRY_DIR/projP/bar.tty"
    local sessions_agent
    sessions_agent=$(cat "$PROJECT_DIR/.fagents-tty/sessions/ttys999.agent")
    assert "test 5c: sessions file is now 'bar'" "$sessions_agent" "bar"
    teardown_env
}

test_6() {
    setup_env "projP"
    local bad
    for bad in "foo:bar" "foo bar" "" "-foo" ".foo"; do
        run_comms register "$bad"
        if [ "$COMMS_RC" -eq 0 ]; then
            FAIL=$((FAIL + 1))
            FAILED_DETAILS+=("test 6: register accepted invalid name '$bad'")
        else
            PASS=$((PASS + 1))
        fi
    done
    teardown_env
}

test_7() {
    setup_env "projP"
    # First project registers
    run_comms register foo
    # Second project with same name from different dir
    local OTHER_PROJECT_DIR="$TMPDIR/other_projP"
    mkdir -p "$OTHER_PROJECT_DIR/.fagents-tty/bin" "$OTHER_PROJECT_DIR/.fagents-tty/sessions"
    cp "$COMMS_SRC" "$OTHER_PROJECT_DIR/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$OTHER_PROJECT_DIR/.fagents-tty/bin/wake.sh"
    chmod +x "$OTHER_PROJECT_DIR/.fagents-tty/bin/comms.sh"
    printf 'project_name=projP\n' > "$OTHER_PROJECT_DIR/.fagents-tty/config"
    local out rc
    out=$(cd "$OTHER_PROJECT_DIR" && bash .fagents-tty/bin/comms.sh register baz 2>&1)
    rc=$?
    assert "test 7: register from different dir fails" "$rc" "1"
    assert_contains "test 7: error mentions conflict" "$out" "project-name-conflict"
    teardown_env
}

test_8() {
    setup_env "projP"
    FAGENTS_TTY_FORCE_TTY="/dev/fake42" run_comms register foo
    local content
    content=$(cat "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty")
    assert "test 8: FORCE_TTY override is honored" "$content" "/dev/fake42"
    teardown_env
}

test_9() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    run_comms msg projB:foo "hi"
    assert "test 9: msg exit 0" "$COMMS_RC" "0"
    local log_content
    log_content=$(cat "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 9a: envelope has FAGENTS-TTY prefix" "$log_content" "[FAGENTS-TTY from projP:self]:"
    assert_contains "test 9b: envelope has body" "$log_content" ": hi."
    assert_contains "test 9c: envelope has reply command" "$log_content" "Reply: bash .fagents-tty/bin/comms.sh msg projP:self"
    local target_col
    target_col=$(awk -F'\t' 'NR==1{print $1}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert "test 9d: wake target is projB:foo" "$target_col" "projB:foo"
    teardown_env
}

test_10() {
    setup_env "projP"
    # Skip register so sessions file is absent
    setup_second_project "projB" "/dev/ttys888" "foo"
    run_comms msg projB:foo "hi"
    assert "test 10: missing sessions file exits 6" "$COMMS_RC" "6"
    assert_contains "test 10: error mentions not-registered" "$COMMS_OUT" "not-registered-from-this-tty"
    teardown_env
}

test_11() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    rm -f "$PROJECT_DIR/.fagents-tty/config"
    run_comms msg projB:foo "hi"
    assert "test 11: missing config exits 7" "$COMMS_RC" "7"
    assert_contains "test 11: error mentions no-project-config" "$COMMS_OUT" "no-project-config"
    teardown_env
}

test_12() {
    setup_env "projP"
    run_comms register self
    run_comms msg unknown:agent "hi"
    assert "test 12: unknown address exits 2" "$COMMS_RC" "2"
    teardown_env
}

test_13() {
    setup_env "projP"
    run_comms register self
    # Project exists, agent file doesn't
    mkdir -p "$FAGENTS_TTY_REGISTRY_DIR/projB"
    printf '%s' "$PROJECT_DIR" > "$FAGENTS_TTY_REGISTRY_DIR/projB/.path"
    run_comms msg projB:nonexistent "hi"
    assert "test 13: project exists but no agent file exits 2" "$COMMS_RC" "2"
    teardown_env
}

test_14() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/nonexistent_xyz" "foo"
    export FAGENTS_TTY_MOCK_WAKE_EXIT=3
    run_comms msg projB:foo "hi"
    unset FAGENTS_TTY_MOCK_WAKE_EXIT
    export FAGENTS_TTY_MOCK_WAKE_EXIT=0
    assert "test 14: wake failure propagates exit 3" "$COMMS_RC" "3"
    teardown_env
}

test_15() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    run_comms msg projB:foo $'line1\nline2'
    assert "test 15: LF body exits 0" "$COMMS_RC" "0"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 15: LF replaced with space" "$envelope" "line1 line2"
    teardown_env
}

test_16() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    run_comms msg projB:foo $'before\rafter'
    assert "test 16: CR body exits 0" "$COMMS_RC" "0"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 16: CR replaced with space" "$envelope" "before after"
    teardown_env
}

test_17() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    run_comms msg projB:foo $'\x1b[31mred\x1b[0m'
    assert "test 17: ESC body exits 0" "$COMMS_RC" "0"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    # Expect: leading ESC -> leading space -> trimmed; middle ESC -> space between "red" and "[0m"
    assert_contains "test 17: ESC replaced (red [0m)" "$envelope" "[31mred [0m"
    # Ensure no raw ESC byte survived
    if printf '%s' "$envelope" | LC_ALL=C grep -q $'\x1b'; then
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("test 17: raw ESC byte still present in envelope")
    else
        PASS=$((PASS + 1))
    fi
    teardown_env
}

test_18() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    run_comms msg projB:foo "a    b"
    assert "test 18: collapsed-spaces body exits 0" "$COMMS_RC" "0"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 18: spaces collapsed to one" "$envelope" ": a b."
    teardown_env
}

test_19() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    run_comms msg projB:foo ""
    assert "test 19: empty body exits 5" "$COMMS_RC" "5"
    teardown_env
}

test_20() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    # naive + combining acute (UTF-8: 0xCC 0x81)
    local utf8=$'naive\xCC\x81'
    run_comms msg projB:foo "$utf8"
    assert "test 20: UTF-8 body exits 0" "$COMMS_RC" "0"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    # The combining accent should still be there (bytes 0xCC 0x81 immediately after 'e')
    if printf '%s' "$envelope" | LC_ALL=C grep -q $'naive\xCC\x81'; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("test 20: UTF-8 bytes mangled by sanitizer")
    fi
    teardown_env
}

test_21() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    # All controls: tab, LF, CR, BEL
    run_comms msg projB:foo $'\t\n\r\x07'
    assert "test 21: all-controls body exits 5" "$COMMS_RC" "5"
    teardown_env
}

test_22() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    # Inject malicious config
    printf 'project_name=ok; touch %s/pwned\n' "$TMPDIR" > "$PROJECT_DIR/.fagents-tty/config"
    run_comms msg projB:foo "hi"
    assert "test 22: malicious config exits 7" "$COMMS_RC" "7"
    assert_file_missing "test 22: pwned file does not exist" "$TMPDIR/pwned"
    teardown_env
}

test_23() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    printf 'project_name=-leading-hyphen\n' > "$PROJECT_DIR/.fagents-tty/config"
    run_comms msg projB:foo "hi"
    assert "test 23: invalid configured name exits 7" "$COMMS_RC" "7"
    teardown_env
}

test_24() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    cat > "$PROJECT_DIR/.fagents-tty/config" <<EOF
# leading comment

# another comment

project_name=projP
EOF
    run_comms msg projB:foo "hi"
    assert "test 24: comments+blanks+valid name exits 0" "$COMMS_RC" "0"
    teardown_env
}

test_25() {
    # 25a: unknown key alone
    setup_env "projP"
    setup_second_project "projB" "/dev/ttys888" "foo"
    printf 'port=9000\n' > "$PROJECT_DIR/.fagents-tty/config"
    # No project_name= at all -> parse_project_name returns 1
    run_comms register self  # register also reads config
    assert "test 25a: unknown-key-only register exits 7" "$COMMS_RC" "7"
    teardown_env

    # 25b: unknown key after project_name=
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    cat > "$PROJECT_DIR/.fagents-tty/config" <<EOF
project_name=projP
port=9000
EOF
    run_comms msg projB:foo "hi"
    assert "test 25b: unknown-key-after-project_name exits 7" "$COMMS_RC" "7"
    teardown_env
}

test_26() {
    setup_env "projP"
    run_comms register self
    run_comms msg "foo:bar:baz" "hi"
    assert "test 26: extra colon exits 1" "$COMMS_RC" "1"
    teardown_env
}

test_27() {
    setup_env "projP"
    run_comms register self
    run_comms msg ":foo" "hi"
    assert "test 27a: empty project segment exits 1" "$COMMS_RC" "1"
    run_comms msg "foo:" "hi"
    assert "test 27b: empty agent segment exits 1" "$COMMS_RC" "1"
    run_comms ls --project "bad name"
    assert "test 27c: ls --project with bad name exits 1" "$COMMS_RC" "1"
    run_comms ls --project ".."
    assert "test 27d: ls --project with path-traversal exits 1" "$COMMS_RC" "1"
    teardown_env
}

test_28() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    # 900-byte body to trigger truncation
    local big
    big=$(printf 'a%.0s' $(seq 1 900))
    export FAGENTS_TTY_MOCK_WAKE_EXIT=0
    run_comms msg projB:foo "$big"
    assert "test 28: truncated + wake success exits 4" "$COMMS_RC" "4"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 28: envelope has TRUNCATED suffix" "$envelope" "...[TRUNCATED]"
    teardown_env
}

test_29() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    local big
    big=$(printf 'a%.0s' $(seq 1 900))
    export FAGENTS_TTY_MOCK_WAKE_EXIT=3
    run_comms msg projB:foo "$big"
    assert "test 29: truncated + wake failure exits 3 (NOT 4)" "$COMMS_RC" "3"
    # Mock still records the attempted envelope
    local log_lines
    log_lines=$(wc -l < "$FAGENTS_TTY_MOCK_WAKE_LOG" | tr -d ' ')
    assert "test 29: wake was invoked once" "$log_lines" "1"
    teardown_env
}

test_30() {
    setup_env "projP"
    run_comms register alice
    setup_second_project "projB" "/dev/ttys888" "bob"
    run_comms ls
    # Expect output sorted, one line per agent
    local line_count
    line_count=$(printf '%s\n' "$COMMS_OUT" | wc -l | tr -d ' ')
    assert "test 30: ls lists 2 entries" "$line_count" "2"
    assert_contains "test 30: ls includes projP:alice" "$COMMS_OUT" "projP:alice"
    assert_contains "test 30: ls includes projB:bob" "$COMMS_OUT" "projB:bob"
    teardown_env
}

test_31() {
    setup_env "projP"
    run_comms register alice
    setup_second_project "projB" "/dev/ttys888" "bob"
    run_comms ls --project projP
    local line_count
    line_count=$(printf '%s\n' "$COMMS_OUT" | wc -l | tr -d ' ')
    assert "test 31: ls --project filters to one" "$line_count" "1"
    assert_contains "test 31: ls --project includes projP:alice" "$COMMS_OUT" "projP:alice"
    teardown_env
}

test_32() {
    setup_env "projP"
    # No register, no projects
    run_comms ls
    assert "test 32: ls on empty registry exits 0" "$COMMS_RC" "0"
    assert "test 32: ls output is empty" "$COMMS_OUT" ""
    teardown_env
}

test_33() {
    setup_env "projP"
    run_comms register foo
    run_comms register bar
    run_comms unregister foo
    assert "test 33: unregister exits 0" "$COMMS_RC" "0"
    assert_file_missing "test 33: foo.tty removed" "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty"
    assert_file_exists "test 33: bar.tty preserved" "$FAGENTS_TTY_REGISTRY_DIR/projP/bar.tty"
    # sessions file was last "bar" so unregistering "foo" should NOT remove it
    assert_file_exists "test 33: sessions file preserved (was bar)" "$PROJECT_DIR/.fagents-tty/sessions/ttys999.agent"
    local sessions_agent
    sessions_agent=$(cat "$PROJECT_DIR/.fagents-tty/sessions/ttys999.agent")
    assert "test 33: sessions file still 'bar'" "$sessions_agent" "bar"
    teardown_env
}

test_34() {
    setup_env "projP"
    run_comms register foo
    # Tamper with .path to point at a different dir
    printf '/some/other/place' > "$FAGENTS_TTY_REGISTRY_DIR/projP/.path"
    run_comms unregister foo
    assert "test 34: foreign-project unregister exits 8" "$COMMS_RC" "8"
    teardown_env
}

test_35() {
    # Setup.sh test: invoke setup.sh in a fresh dir with preexisting .claude/.codex hook files.
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local PROJ="$TMPDIR/setup_test_proj"
    mkdir -p "$PROJ/.claude" "$PROJ/.codex"
    local CLAUDE_JSON='{"hooks":{"SessionStart":[{"hooks":[{"command":"echo tandem-owned"}]}]}}'
    local CODEX_JSON='{"hooks":{"SessionStart":[{"hooks":[{"command":"echo tandem-owned"}]}]}}'
    printf '%s' "$CLAUDE_JSON" > "$PROJ/.claude/settings.json"
    printf '%s' "$CODEX_JSON" > "$PROJ/.codex/hooks.json"
    local sha_claude
    sha_claude=$(shasum -a 256 "$PROJ/.claude/settings.json" | awk '{print $1}')
    local sha_codex
    sha_codex=$(shasum -a 256 "$PROJ/.codex/hooks.json" | awk '{print $1}')

    # Isolated fake HOME so the test proves setup.sh writes nothing global.
    local FAKE_HOME="$TMPDIR/fake_home"
    mkdir -p "$FAKE_HOME"

    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
    ( cd "$PROJ" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" --project setup_test_proj >/dev/null 2>&1 )
    local rc=$?
    assert "test 35: setup exits 0" "$rc" "0"
    assert_file_exists "test 35: .fagents-tty/bin/comms.sh" "$PROJ/.fagents-tty/bin/comms.sh"
    assert_file_exists "test 35: .fagents-tty/bin/wake.sh" "$PROJ/.fagents-tty/bin/wake.sh"
    assert_file_exists "test 35: .fagents-tty/config" "$PROJ/.fagents-tty/config"
    assert_file_exists "test 35: .fagents-tty/.gitignore" "$PROJ/.fagents-tty/.gitignore"
    if [ -d "$PROJ/.fagents-tty/sessions" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILED_DETAILS+=("test 35: sessions/ dir missing")
    fi
    assert_file_unchanged "test 35: .claude/settings.json unchanged" "$PROJ/.claude/settings.json" "$sha_claude"
    assert_file_unchanged "test 35: .codex/hooks.json unchanged" "$PROJ/.codex/hooks.json" "$sha_codex"
    # No global skill install: fake HOME must remain skill-free.
    assert_file_missing "test 35: no global Claude skill install" "$FAKE_HOME/.claude/skills/fagents-tty/SKILL.md"
    assert_file_missing "test 35: no global Codex skill install" "$FAKE_HOME/.codex/skills/fagents-tty/SKILL.md"

    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_REGISTRY_DIR TMPDIR
}

test_36() {
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local PROJ="$TMPDIR/upd_proj"
    mkdir -p "$PROJ"
    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
    ( cd "$PROJ" && bash "$REPO_ROOT/setup.sh" --project upd_proj >/dev/null 2>&1 )
    # Mark config so we can detect non-touch
    printf 'project_name=upd_proj\n# kept comment\n' > "$PROJ/.fagents-tty/config"
    local sha_cfg
    sha_cfg=$(shasum -a 256 "$PROJ/.fagents-tty/config" | awk '{print $1}')
    # Mutate bin scripts; --update should refresh them
    echo "stale" > "$PROJ/.fagents-tty/bin/comms.sh"
    ( cd "$PROJ" && bash "$REPO_ROOT/setup.sh" --update >/dev/null 2>&1 )
    local rc=$?
    assert "test 36: setup --update exits 0" "$rc" "0"
    local stale_check
    stale_check=$(cat "$PROJ/.fagents-tty/bin/comms.sh" | head -1)
    if [ "$stale_check" = "stale" ]; then
        FAIL=$((FAIL+1)); FAILED_DETAILS+=("test 36: --update did not refresh bin script")
    else
        PASS=$((PASS+1))
    fi
    assert_file_unchanged "test 36: config preserved by --update" "$PROJ/.fagents-tty/config" "$sha_cfg"
    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_REGISTRY_DIR TMPDIR
}

test_37() {
    # End-to-end: install two projects, register in each, bidirectional msg.
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local A="$TMPDIR/A" B="$TMPDIR/B"
    mkdir -p "$A/.fagents-tty/bin" "$A/.fagents-tty/sessions" "$B/.fagents-tty/bin" "$B/.fagents-tty/sessions"
    cp "$COMMS_SRC" "$A/.fagents-tty/bin/comms.sh"
    cp "$COMMS_SRC" "$B/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$A/.fagents-tty/bin/wake.sh"
    cp "$WAKE_SRC" "$B/.fagents-tty/bin/wake.sh"
    chmod +x "$A/.fagents-tty/bin/comms.sh" "$B/.fagents-tty/bin/comms.sh"
    printf 'project_name=A\n' > "$A/.fagents-tty/config"
    printf 'project_name=B\n' > "$B/.fagents-tty/config"

    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
    export FAGENTS_TTY_WAKE_BIN="$MOCK_WAKE"
    export FAGENTS_TTY_MOCK_WAKE_LOG="$TMPDIR/wake.log"
    export FAGENTS_TTY_MOCK_WAKE_EXIT=0

    ( cd "$A" && FAGENTS_TTY_FORCE_TTY=/dev/fakeA bash .fagents-tty/bin/comms.sh register alice ) >/dev/null
    ( cd "$B" && FAGENTS_TTY_FORCE_TTY=/dev/fakeB bash .fagents-tty/bin/comms.sh register bob ) >/dev/null

    # A -> B
    ( cd "$A" && FAGENTS_TTY_FORCE_TTY=/dev/fakeA bash .fagents-tty/bin/comms.sh msg B:bob "hello from A" ) >/dev/null
    local rc1=$?
    # B -> A (using the printed reply path)
    ( cd "$B" && FAGENTS_TTY_FORCE_TTY=/dev/fakeB bash .fagents-tty/bin/comms.sh msg A:alice "reply from B" ) >/dev/null
    local rc2=$?

    assert "test 37: A->B exits 0" "$rc1" "0"
    assert "test 37: B->A exits 0" "$rc2" "0"
    local log_lines
    log_lines=$(wc -l < "$FAGENTS_TTY_MOCK_WAKE_LOG" | tr -d ' ')
    assert "test 37: wake log has 2 entries" "$log_lines" "2"
    local first_target second_target
    first_target=$(awk -F'\t' 'NR==1{print $1}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    second_target=$(awk -F'\t' 'NR==2{print $1}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert "test 37: first wake targets B:bob" "$first_target" "B:bob"
    assert "test 37: second wake targets A:alice" "$second_target" "A:alice"
    local first_env second_env
    first_env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    second_env=$(awk -F'\t' 'NR==2{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 37: first envelope from A:alice" "$first_env" "[FAGENTS-TTY from A:alice]:"
    assert_contains "test 37: second envelope from B:bob" "$second_env" "[FAGENTS-TTY from B:bob]:"

    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_REGISTRY_DIR FAGENTS_TTY_WAKE_BIN FAGENTS_TTY_MOCK_WAKE_LOG FAGENTS_TTY_MOCK_WAKE_EXIT TMPDIR
}

# Byte-length truncation (regression for codex r4 P2 finding):
# UTF-8 char "é" is 2 bytes; 500 of them = 1000 bytes (>800) but only 500 chars.
# Naive `${#str}` measures chars and would let this through; byte cap catches it.
test_38() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    local utf8_body
    utf8_body=$(printf 'é%.0s' $(seq 1 500))
    run_comms msg projB:foo "$utf8_body"
    assert "test 38: 1000-byte 500-char UTF-8 body exits 4" "$COMMS_RC" "4"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 38: envelope has TRUNCATED suffix" "$envelope" "...[TRUNCATED]"
    teardown_env
}

# wake.sh direct-call address validation (regression for codex r4 P2 finding):
# wake.sh is a public command; untrusted callers must not be able to traverse
# outside the registry root via "../escape:agent".
test_39() {
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
    mkdir -p "$FAGENTS_TTY_REGISTRY_DIR"
    local rc out
    out=$(bash "$WAKE_SRC" "../escape:agent" "msg" 2>&1); rc=$?
    assert "test 39a: wake.sh rejects ../escape in project" "$rc" "1"
    assert_contains "test 39a: error names failed validation" "$out" "failed validation"
    out=$(bash "$WAKE_SRC" "valid:../escape" "msg" 2>&1); rc=$?
    assert "test 39b: wake.sh rejects ../escape in agent" "$rc" "1"
    out=$(bash "$WAKE_SRC" ":foo" "msg" 2>&1); rc=$?
    assert "test 39c: wake.sh rejects empty project" "$rc" "1"
    out=$(bash "$WAKE_SRC" "foo:" "msg" 2>&1); rc=$?
    assert "test 39d: wake.sh rejects empty agent" "$rc" "1"
    out=$(bash "$WAKE_SRC" "-leading:agent" "msg" 2>&1); rc=$?
    assert "test 39e: wake.sh rejects leading-hyphen project" "$rc" "1"
    out=$(bash "$WAKE_SRC" "valid:foo.dot" "msg" 2>&1); rc=$?
    assert "test 39f: wake.sh rejects invalid char (dot) in agent" "$rc" "1"
    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_REGISTRY_DIR TMPDIR
}

# setup.sh --force takeover claims the registry slot (regression for codex r4 P2):
# After forced takeover, .path must point at the new project so a third project
# cannot claim the same name with no --force in between.
test_40() {
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local PROJ_A="$TMPDIR/A_dir"
    local PROJ_B="$TMPDIR/B_dir"
    local PROJ_C="$TMPDIR/C_dir"
    mkdir -p "$PROJ_A" "$PROJ_B" "$PROJ_C"
    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
    local FAKE_HOME="$TMPDIR/fake_home"
    mkdir -p "$FAKE_HOME"

    ( cd "$PROJ_A" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" --project same >/dev/null 2>&1 )
    local path_a
    path_a=$(cat "$FAGENTS_TTY_REGISTRY_DIR/same/.path" 2>/dev/null)
    assert "test 40a: setup writes .path to project A immediately" "$path_a" "$PROJ_A"

    local rc
    ( cd "$PROJ_B" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" --project same --force >/dev/null 2>&1 )
    rc=$?
    assert "test 40b: setup --force exits 0" "$rc" "0"
    local path_b
    path_b=$(cat "$FAGENTS_TTY_REGISTRY_DIR/same/.path" 2>/dev/null)
    assert "test 40c: setup --force claims slot for B" "$path_b" "$PROJ_B"

    local out_c rc_c
    out_c=$(cd "$PROJ_C" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" --project same 2>&1)
    rc_c=$?
    assert "test 40d: third project without --force fails" "$rc_c" "1"
    assert_contains "test 40d: error mentions B's path" "$out_c" "$PROJ_B"

    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_REGISTRY_DIR TMPDIR
}

# Regression for codex r5 P2.2: wake.sh's python encode loop must accept split
# multibyte UTF-8 bytes from sys.argv without raising UnicodeEncodeError on
# surrogate-escaped code points. The fix uses os.fsencode(...) and bytes([b]).
# We replicate the encode path standalone (no TIOCSTI ioctl) and assert clean.
test_41() {
    local payload actual_bytes
    payload=$(printf '€%.0s' $(seq 1 266))    # 266 * 3 bytes = 798
    payload+=$'\xE2\x82'                      # +2 bytes of an incomplete €
    actual_bytes=$(printf '%s' "$payload" | wc -c | tr -d ' ')
    assert "test 41a: payload is 800 bytes" "$actual_bytes" "800"
    local out rc
    out=$(python3 -c '
import os, sys
raw = os.fsencode(sys.argv[1])
n = 0
for b in raw:
    chunk = bytes([b])
    n += len(chunk)
sys.stdout.write(str(n))
' "$payload" 2>&1)
    rc=$?
    assert "test 41b: python encode loop exits 0 on split UTF-8" "$rc" "0"
    assert "test 41c: encoded byte count matches input bytes" "$out" "800"
}

# Regression for codex r5 P2.1: `printf | head -c` under `set -o pipefail` could
# trigger SIGPIPE on very large bodies (exit 141). The fix writes to a tempfile
# instead of piping. Send a 200KB body and assert clean truncation.
test_42() {
    setup_env "projP"
    run_comms register self
    setup_second_project "projB" "/dev/ttys888" "foo"
    local huge
    huge=$(printf 'a%.0s' $(seq 1 200000))
    run_comms msg projB:foo "$huge"
    assert "test 42: 200KB body exits 4 (not 141 SIGPIPE)" "$COMMS_RC" "4"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "test 42: envelope has TRUNCATED suffix" "$envelope" "...[TRUNCATED]"
    teardown_env
}

# Regression for codex r7 P3: comms.sh and setup.sh must create registry +
# sessions files with private permissions (mode 0600 files, 0700 dirs) so
# SECURITY.md's defense-in-depth claim is real.
test_43() {
    setup_env "projP"
    run_comms register foo

    local tty_mode path_mode sessions_mode regdir_mode sessdir_mode
    tty_mode=$(file_mode "$FAGENTS_TTY_REGISTRY_DIR/projP/foo.tty")
    path_mode=$(file_mode "$FAGENTS_TTY_REGISTRY_DIR/projP/.path")
    sessions_mode=$(file_mode "$PROJECT_DIR/.fagents-tty/sessions/ttys999.agent")
    regdir_mode=$(file_mode "$FAGENTS_TTY_REGISTRY_DIR/projP")
    sessdir_mode=$(file_mode "$PROJECT_DIR/.fagents-tty/sessions")

    assert "test 43a: registry .tty file mode is 600" "$tty_mode" "600"
    assert "test 43b: registry .path file mode is 600" "$path_mode" "600"
    assert "test 43c: sessions agent file mode is 600" "$sessions_mode" "600"
    assert "test 43d: registry project dir mode is 700" "$regdir_mode" "700"
    assert "test 43e: sessions dir mode is 700" "$sessdir_mode" "700"
    teardown_env
}

# Same private-perm assertions for setup.sh's writes (registry .path + the
# files it materializes inside <project>/.fagents-tty/).
test_44() {
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local PROJ="$TMPDIR/perm_test_proj"
    mkdir -p "$PROJ"
    local FAKE_HOME="$TMPDIR/fake_home"
    mkdir -p "$FAKE_HOME"
    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
    ( cd "$PROJ" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" --project perm_test_proj >/dev/null 2>&1 )

    local config_mode gitignore_mode regpath_mode regdir_mode
    config_mode=$(file_mode "$PROJ/.fagents-tty/config")
    gitignore_mode=$(file_mode "$PROJ/.fagents-tty/.gitignore")
    regpath_mode=$(file_mode "$FAGENTS_TTY_REGISTRY_DIR/perm_test_proj/.path")
    regdir_mode=$(file_mode "$FAGENTS_TTY_REGISTRY_DIR/perm_test_proj")

    assert "test 44a: .fagents-tty/config mode is 600" "$config_mode" "600"
    assert "test 44b: .fagents-tty/.gitignore mode is 600" "$gitignore_mode" "600"
    assert "test 44c: registry .path mode is 600" "$regpath_mode" "600"
    assert "test 44d: registry project dir mode is 700" "$regdir_mode" "700"

    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_REGISTRY_DIR TMPDIR
}

# ── v1.1: launcher + project-local skill install ──

# Helper: bootstrap a clean install dir with fake HOME (used by v1.1 tests).
# Sets TMPDIR, PROJ, FAKE_HOME, FAGENTS_TTY_REGISTRY_DIR. Caller cleans up.
v11_bootstrap() {
    local proj_name="$1"
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    PROJ="$TMPDIR/$proj_name"
    mkdir -p "$PROJ"
    FAKE_HOME="$TMPDIR/fake_home"
    mkdir -p "$FAKE_HOME"
    export FAGENTS_TTY_REGISTRY_DIR="$TMPDIR/registry"
}

v11_teardown() {
    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_REGISTRY_DIR TMPDIR PROJ FAKE_HOME
}

# Run setup.sh from PROJ with isolated HOME. Captures stdout+stderr and rc.
v11_run_setup() {
    SETUP_OUT=$(cd "$PROJ" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" "$@" 2>&1)
    SETUP_RC=$?
}

# Launcher creation, fresh
test_45() {
    v11_bootstrap "launcher_default"
    v11_run_setup --project launcher_default
    assert "test 45a: setup exits 0" "$SETUP_RC" "0"
    assert_file_exists "test 45b: launch-claude created" "$PROJ/launch-claude"
    assert_file_exists "test 45c: launch-codex created" "$PROJ/launch-codex"
    local m_claude m_codex
    m_claude=$(file_mode "$PROJ/launch-claude")
    m_codex=$(file_mode "$PROJ/launch-codex")
    assert "test 45d: launch-claude mode 700" "$m_claude" "700"
    assert "test 45e: launch-codex mode 700" "$m_codex" "700"
    v11_teardown
}

test_46() {
    v11_bootstrap "launcher_agents"
    v11_run_setup --project launcher_agents --agents orchestrator,foo
    assert "test 46a: setup exits 0" "$SETUP_RC" "0"
    assert_file_exists "test 46b: launch-orchestrator created" "$PROJ/launch-orchestrator"
    assert_file_exists "test 46c: launch-foo created" "$PROJ/launch-foo"
    assert_file_missing "test 46d: launch-claude NOT created" "$PROJ/launch-claude"
    assert_file_missing "test 46e: launch-codex NOT created" "$PROJ/launch-codex"
    v11_teardown
}

test_47() {
    v11_bootstrap "launcher_skip"
    v11_run_setup --project launcher_skip --no-launchers
    assert "test 47a: setup exits 0" "$SETUP_RC" "0"
    assert_file_missing "test 47b: --no-launchers skips claude" "$PROJ/launch-claude"
    assert_file_missing "test 47c: --no-launchers skips codex" "$PROJ/launch-codex"
    v11_teardown
}

test_48() {
    v11_bootstrap "launcher_content"
    v11_run_setup --project launcher_content
    assert "test 48a: setup exits 0" "$SETUP_RC" "0"
    local content
    content=$(cat "$PROJ/launch-claude")
    # Literal $ROOT / $@ inside single quotes is intentional: we are asserting
    # the launcher CONTAINS the literal string `$ROOT/...` (not its expansion).
    # shellcheck disable=SC2016
    assert_contains "test 48b: launcher defines ROOT" "$content" 'ROOT="$(cd '
    # shellcheck disable=SC2016
    assert_contains "test 48c: launcher has tandem conditional" "$content" '[ -x "$ROOT/.tandem/bin/handoff.sh" ] && bash "$ROOT/.tandem/bin/handoff.sh" register claude'
    # shellcheck disable=SC2016
    assert_contains "test 48d: launcher has fagents-tty conditional" "$content" '[ -x "$ROOT/.fagents-tty/bin/comms.sh" ] && bash "$ROOT/.fagents-tty/bin/comms.sh" register claude'
    # shellcheck disable=SC2016
    assert_contains "test 48e: launcher exec preserves args" "$content" 'exec claude "$@"'
    v11_teardown
}

test_49() {
    v11_bootstrap "launcher_idem"
    v11_run_setup --project launcher_idem
    local sha1
    sha1=$(shasum -a 256 "$PROJ/launch-claude" | awk '{print $1}')
    v11_run_setup --update
    assert "test 49a: --update exits 0" "$SETUP_RC" "0"
    assert_file_unchanged "test 49b: launch-claude idempotent under --update" "$PROJ/launch-claude" "$sha1"
    v11_teardown
}

# Launcher amend via awk
test_50() {
    v11_bootstrap "amend_existing"
    # Real fagents-tandem launch-claude content
    cat > "$PROJ/launch-claude" <<'EOF'
#!/bin/bash
# Launch Claude Code with tandem TTY registration
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TTY_DEV=$(tty 2>/dev/null) || true
[[ "$TTY_DEV" == /dev/* ]] && echo "$TTY_DEV" > "$ROOT/.tandem/claude.tty"
exec claude "$@"
EOF
    chmod 0700 "$PROJ/launch-claude"
    v11_run_setup --project amend_existing
    assert "test 50a: setup exits 0" "$SETUP_RC" "0"
    local content
    content=$(cat "$PROJ/launch-claude")
    # Original lines preserved (intentional literal $ROOT / $TTY_DEV / $@)
    # shellcheck disable=SC2016
    assert_contains "test 50b: tandem TTY-write line preserved" "$content" '[[ "$TTY_DEV" == /dev/* ]] && echo "$TTY_DEV" > "$ROOT/.tandem/claude.tty"'
    # fagents-tty register line inserted
    # shellcheck disable=SC2016
    assert_contains "test 50c: fagents-tty register inserted" "$content" '[ -x "$ROOT/.fagents-tty/bin/comms.sh" ] && bash "$ROOT/.fagents-tty/bin/comms.sh" register claude'
    # Exec line still has "$@"
    # shellcheck disable=SC2016
    assert_contains "test 50d: exec preserved with args" "$content" 'exec claude "$@"'
    # The fagents-tty line must come BEFORE exec
    local fagents_line exec_line
    fagents_line=$(grep -n 'fagents-tty/bin/comms.sh' "$PROJ/launch-claude" | head -1 | cut -d: -f1)
    exec_line=$(grep -n '^exec ' "$PROJ/launch-claude" | head -1 | cut -d: -f1)
    if [ -n "$fagents_line" ] && [ -n "$exec_line" ] && [ "$fagents_line" -lt "$exec_line" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("test 50e: fagents-tty line not before exec (fagents=$fagents_line, exec=$exec_line)")
    fi
    v11_teardown
}

test_51() {
    v11_bootstrap "amend_idem"
    cat > "$PROJ/launch-claude" <<'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec claude "$@"
EOF
    chmod 0700 "$PROJ/launch-claude"
    v11_run_setup --project amend_idem
    local sha1
    sha1=$(shasum -a 256 "$PROJ/launch-claude" | awk '{print $1}')
    v11_run_setup --update
    assert "test 51a: --update exits 0" "$SETUP_RC" "0"
    assert_file_unchanged "test 51b: amended launcher idempotent" "$PROJ/launch-claude" "$sha1"
    v11_teardown
}

test_52() {
    v11_bootstrap "no_root"
    # Launcher lacks ROOT= definition
    cat > "$PROJ/launch-claude" <<'EOF'
#!/bin/bash
echo "hand-rolled"
exec claude "$@"
EOF
    chmod 0700 "$PROJ/launch-claude"
    local sha1
    sha1=$(shasum -a 256 "$PROJ/launch-claude" | awk '{print $1}')
    v11_run_setup --project no_root
    assert "test 52a: setup exits 0 (non-blocking warning)" "$SETUP_RC" "0"
    assert_contains "test 52b: setup printed manual instructions" "$SETUP_OUT" "does not define 'ROOT='"
    assert_file_unchanged "test 52c: launcher unchanged" "$PROJ/launch-claude" "$sha1"
    v11_teardown
}

test_53() {
    v11_bootstrap "no_exec"
    cat > "$PROJ/launch-claude" <<'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "no exec here"
EOF
    chmod 0700 "$PROJ/launch-claude"
    local sha1
    sha1=$(shasum -a 256 "$PROJ/launch-claude" | awk '{print $1}')
    v11_run_setup --project no_exec
    assert "test 53a: setup exits 0 (non-blocking warning)" "$SETUP_RC" "0"
    assert_contains "test 53b: setup printed manual instructions" "$SETUP_OUT" "no 'exec' line"
    assert_file_unchanged "test 53c: launcher unchanged" "$PROJ/launch-claude" "$sha1"
    v11_teardown
}

test_54() {
    v11_bootstrap "multi_exec"
    cat > "$PROJ/launch-claude" <<'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec claude "$@"
exec codex "$@"
EOF
    chmod 0700 "$PROJ/launch-claude"
    v11_run_setup --project multi_exec
    assert "test 54a: setup exits 0" "$SETUP_RC" "0"
    # Register line should appear ONCE, before the FIRST exec
    local register_count
    register_count=$(grep -c 'fagents-tty/bin/comms.sh.*register claude' "$PROJ/launch-claude")
    assert "test 54b: register line inserted once" "$register_count" "1"
    local fagents_line first_exec_line
    fagents_line=$(grep -n 'fagents-tty/bin/comms.sh' "$PROJ/launch-claude" | head -1 | cut -d: -f1)
    first_exec_line=$(grep -n '^exec ' "$PROJ/launch-claude" | head -1 | cut -d: -f1)
    if [ -n "$fagents_line" ] && [ "$fagents_line" -lt "$first_exec_line" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("test 54c: register not before first exec")
    fi
    v11_teardown
}

# --agents parsing
test_55() {
    v11_bootstrap "agents_invalid"
    local bad rc
    for bad in "" "," ",claude" "claude," "claude,,codex" "claude, ,codex" " claude"; do
        v11_run_setup --project agents_invalid --agents "$bad"
        rc=$SETUP_RC
        if [ "$rc" -eq 1 ]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            FAILED_DETAILS+=("test 55: --agents '$bad' should fail (got rc=$rc)")
        fi
    done
    v11_teardown
}

test_56() {
    v11_bootstrap "agents_valid"
    v11_run_setup --project agents_valid --agents "alpha,beta,gamma"
    assert "test 56a: 3 valid agents exits 0" "$SETUP_RC" "0"
    assert_file_exists "test 56b: launch-alpha" "$PROJ/launch-alpha"
    assert_file_exists "test 56c: launch-beta" "$PROJ/launch-beta"
    assert_file_exists "test 56d: launch-gamma" "$PROJ/launch-gamma"
    v11_teardown
}

# Project-local skill install
test_57() {
    v11_bootstrap "skill_install"
    v11_run_setup --project skill_install
    assert "test 57a: setup exits 0" "$SETUP_RC" "0"
    assert_file_exists "test 57b: claude SKILL.md" "$PROJ/.claude/skills/fagents-tty/SKILL.md"
    assert_file_exists "test 57c: codex SKILL.md" "$PROJ/.codex/skills/fagents-tty/SKILL.md"
    local m_claude_file m_codex_file m_claude_dir m_codex_dir
    m_claude_file=$(file_mode "$PROJ/.claude/skills/fagents-tty/SKILL.md")
    m_codex_file=$(file_mode "$PROJ/.codex/skills/fagents-tty/SKILL.md")
    m_claude_dir=$(file_mode "$PROJ/.claude/skills/fagents-tty")
    m_codex_dir=$(file_mode "$PROJ/.codex/skills/fagents-tty")
    assert "test 57d: claude SKILL.md mode 600" "$m_claude_file" "600"
    assert "test 57e: codex SKILL.md mode 600" "$m_codex_file" "600"
    assert "test 57f: claude skill dir mode 700" "$m_claude_dir" "700"
    assert "test 57g: codex skill dir mode 700" "$m_codex_dir" "700"
    v11_teardown
}

test_58() {
    v11_bootstrap "no_skill"
    v11_run_setup --project no_skill --no-skill
    assert "test 58a: --no-skill exits 0" "$SETUP_RC" "0"
    assert_file_missing "test 58b: claude skill dir absent" "$PROJ/.claude/skills/fagents-tty"
    assert_file_missing "test 58c: codex skill dir absent" "$PROJ/.codex/skills/fagents-tty"
    v11_teardown
}

# Permission repair: pre-existing permissive paths get tightened
test_58b() {
    v11_bootstrap "skill_repair"
    mkdir -p "$PROJ/.claude/skills/fagents-tty"
    chmod 0755 "$PROJ/.claude/skills/fagents-tty"
    echo "stale" > "$PROJ/.claude/skills/fagents-tty/SKILL.md"
    chmod 0644 "$PROJ/.claude/skills/fagents-tty/SKILL.md"
    v11_run_setup --project skill_repair
    assert "test 58b1: setup exits 0" "$SETUP_RC" "0"
    local m_dir m_file
    m_dir=$(file_mode "$PROJ/.claude/skills/fagents-tty")
    m_file=$(file_mode "$PROJ/.claude/skills/fagents-tty/SKILL.md")
    assert "test 58b2: pre-existing dir tightened to 700" "$m_dir" "700"
    assert "test 58b3: pre-existing file tightened to 600" "$m_file" "600"
    # Content overwritten to current SKILL.md
    if grep -q 'fagents-tty' "$PROJ/.claude/skills/fagents-tty/SKILL.md"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("test 58b4: pre-existing SKILL.md not overwritten with current content")
    fi
    v11_teardown
}

# No global pollution under fake HOME
test_59() {
    v11_bootstrap "no_global"
    v11_run_setup --project no_global
    assert "test 59a: setup exits 0" "$SETUP_RC" "0"
    assert_file_missing "test 59b: fake HOME claude skills absent" "$FAKE_HOME/.claude/skills/fagents-tty/SKILL.md"
    assert_file_missing "test 59c: fake HOME codex skills absent" "$FAKE_HOME/.codex/skills/fagents-tty/SKILL.md"
    # Check the would-be parent dirs also don't exist
    if [ ! -d "$FAKE_HOME/.claude/skills/fagents-tty" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("test 59d: $FAKE_HOME/.claude/skills/fagents-tty unexpectedly exists")
    fi
    if [ ! -d "$FAKE_HOME/.codex/skills/fagents-tty" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("test 59e: $FAKE_HOME/.codex/skills/fagents-tty unexpectedly exists")
    fi
    v11_teardown
}

# --update idempotency
test_60() {
    v11_bootstrap "update_idem"
    v11_run_setup --project update_idem
    local sha_claude sha_codex sha_skill_claude sha_skill_codex
    sha_claude=$(shasum -a 256 "$PROJ/launch-claude" | awk '{print $1}')
    sha_codex=$(shasum -a 256 "$PROJ/launch-codex" | awk '{print $1}')
    sha_skill_claude=$(shasum -a 256 "$PROJ/.claude/skills/fagents-tty/SKILL.md" | awk '{print $1}')
    sha_skill_codex=$(shasum -a 256 "$PROJ/.codex/skills/fagents-tty/SKILL.md" | awk '{print $1}')
    v11_run_setup --update
    assert "test 60a: --update exits 0" "$SETUP_RC" "0"
    assert_file_unchanged "test 60b: launch-claude unchanged" "$PROJ/launch-claude" "$sha_claude"
    assert_file_unchanged "test 60c: launch-codex unchanged" "$PROJ/launch-codex" "$sha_codex"
    assert_file_unchanged "test 60d: claude SKILL.md unchanged" "$PROJ/.claude/skills/fagents-tty/SKILL.md" "$sha_skill_claude"
    assert_file_unchanged "test 60e: codex SKILL.md unchanged" "$PROJ/.codex/skills/fagents-tty/SKILL.md" "$sha_skill_codex"
    v11_teardown
}

# ── Main ──

main() {
    local i
    for i in $(seq 1 60); do
        if declare -f "test_$i" >/dev/null; then
            "test_$i"
        fi
    done
    # test_58b is a named-suffix variant (permission repair) not covered by the seq loop.
    if declare -f test_58b >/dev/null; then test_58b; fi

    echo ""
    echo "==============================="
    echo "Total: $((PASS + FAIL))  Pass: $PASS  Fail: $FAIL"
    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo "Failures:"
        local d
        for d in "${FAILED_DETAILS[@]}"; do
            echo "  - $d"
        done
        exit 1
    fi
    echo "All assertions passed."
}

main "$@"
