#!/bin/bash
# test_comms.sh -- bash test suite for fagents-tty v2.
#
# Run: bash test/test_comms.sh
#
# v2 model: project name = directory basename. No global registry, no config,
# no sessions/. Discovery via sibling-walk (or FAGENTS_TTY_SEARCH_PATH).
# All TIOCSTI is mocked via test/helpers/mock_wake.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
COMMS_SRC="$REPO_ROOT/bin/comms.sh"
WAKE_SRC="$REPO_ROOT/bin/wake.sh"
MOCK_WAKE="$SCRIPT_DIR/helpers/mock_wake.sh"

PASS=0
FAIL=0
FAILED_DETAILS=()

# -- Assertion helpers --

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

assert_dir_exists() {
    local desc="$1" path="$2"
    if [ -d "$path" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("$desc -- dir does not exist: $path")
    fi
}

assert_dir_missing() {
    local desc="$1" path="$2"
    if [ ! -d "$path" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("$desc -- dir unexpectedly exists: $path")
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
        FAILED_DETAILS+=("$desc -- file changed: $path (expected $expected_sha, got $actual_sha)")
    fi
}

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

# -- Env / project setup --

# Bootstrap a temp dir with PROJECT (a valid-name dir under it). Project gets
# .fagents-tty/bin/ with copies of comms.sh and wake.sh. Sets:
#   TMPDIR, PROJECT_DIR, FAKE_HOME, FAGENTS_TTY_WAKE_BIN,
#   FAGENTS_TTY_MOCK_WAKE_LOG, FAGENTS_TTY_MOCK_WAKE_EXIT, FAGENTS_TTY_FORCE_TTY
setup_env() {
    local proj_name="${1:-projP}"
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    PROJECT_DIR="$TMPDIR/$proj_name"
    mkdir -p "$PROJECT_DIR/.fagents-tty/bin"
    cp "$COMMS_SRC" "$PROJECT_DIR/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$PROJECT_DIR/.fagents-tty/bin/wake.sh"
    chmod +x "$PROJECT_DIR/.fagents-tty/bin/comms.sh" "$PROJECT_DIR/.fagents-tty/bin/wake.sh"

    FAKE_HOME="$TMPDIR/fake_home"
    mkdir -p "$FAKE_HOME"

    export FAGENTS_TTY_WAKE_BIN="$MOCK_WAKE"
    export FAGENTS_TTY_MOCK_WAKE_LOG="$TMPDIR/wake.log"
    export FAGENTS_TTY_MOCK_WAKE_EXIT=0
    export FAGENTS_TTY_FORCE_TTY="/dev/ttys999"
}

# Create a sibling project (in same TMPDIR/$parent) with .fagents-tty/bin
# and register one agent. Used to set up cross-project msg targets.
setup_sibling_project() {
    local proj_name="$1" force_tty="$2" agent_name="${3:-remote}"
    local sib_dir="$TMPDIR/$proj_name"
    mkdir -p "$sib_dir/.fagents-tty/bin"
    cp "$COMMS_SRC" "$sib_dir/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$sib_dir/.fagents-tty/bin/wake.sh"
    chmod +x "$sib_dir/.fagents-tty/bin/comms.sh" "$sib_dir/.fagents-tty/bin/wake.sh"
    FAGENTS_TTY_FORCE_TTY="$force_tty" \
        bash "$sib_dir/.fagents-tty/bin/comms.sh" register "$agent_name" >/dev/null
}

teardown_env() {
    if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] && \
       [[ "$TMPDIR" == /var/* || "$TMPDIR" == /tmp/* || "$TMPDIR" == /private/var/* ]]; then
        rm -rf "$TMPDIR"
    fi
    unset FAGENTS_TTY_WAKE_BIN FAGENTS_TTY_MOCK_WAKE_LOG FAGENTS_TTY_MOCK_WAKE_EXIT FAGENTS_TTY_FORCE_TTY FAGENTS_TTY_SEARCH_PATH
    unset TMPDIR PROJECT_DIR FAKE_HOME
}

# Run comms.sh from PROJECT_DIR. Captures merged stdout+stderr / exit code.
run_comms() {
    COMMS_OUT=$(cd "$PROJECT_DIR" && bash .fagents-tty/bin/comms.sh "$@" 2>&1)
    COMMS_RC=$?
}

# Run setup.sh in PROJECT_DIR under a fake HOME.
run_setup() {
    SETUP_OUT=$(cd "$PROJECT_DIR" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" "$@" 2>&1)
    SETUP_RC=$?
}

# Common msg-test fixture: sender project "projP" with agent "alice" registered,
# plus sibling project "projB" with agent "remote" registered on /dev/ttys888.
# Many tests need this exact pair; callers issue their own `run_comms msg ...`
# afterward. COMMS_OUT/COMMS_RC after this helper are from the alice register
# (uninteresting); tests should re-invoke run_comms with their actual command.
setup_with_sibling() {
    setup_env "projP"
    run_comms register alice
    setup_sibling_project "projB" "/dev/ttys888" "remote"
}

# -- Tests: registration --

test_01() {
    setup_env "projP"
    run_comms register foo
    assert "01a: register exit 0" "$COMMS_RC" "0"
    assert_file_exists "01b: agents/foo.tty exists" "$PROJECT_DIR/.fagents-tty/agents/foo.tty"
    local content
    content=$(cat "$PROJECT_DIR/.fagents-tty/agents/foo.tty")
    assert "01c: agents/foo.tty contains TTY path" "$content" "/dev/ttys999"
    teardown_env
}

test_02() {
    setup_env "projP"
    run_comms register foo
    local sha1
    sha1=$(shasum -a 256 "$PROJECT_DIR/.fagents-tty/agents/foo.tty" | awk '{print $1}')
    run_comms register foo
    assert "02a: re-register exits 0" "$COMMS_RC" "0"
    assert_file_unchanged "02b: agents/foo.tty unchanged" "$PROJECT_DIR/.fagents-tty/agents/foo.tty" "$sha1"
    teardown_env
}

test_03() {
    setup_env "projP"
    local bad
    for bad in "foo:bar" "foo bar" "" "-foo" ".foo"; do
        run_comms register "$bad"
        if [ "$COMMS_RC" -eq 0 ]; then
            FAIL=$((FAIL + 1))
            FAILED_DETAILS+=("03: register accepted invalid name '$bad'")
        else
            PASS=$((PASS + 1))
        fi
    done
    teardown_env
}

test_04() {
    setup_env "projP"
    FAGENTS_TTY_FORCE_TTY="/dev/ttys888" run_comms register custom
    local content
    content=$(cat "$PROJECT_DIR/.fagents-tty/agents/custom.tty")
    assert "04: FORCE_TTY override honored" "$content" "/dev/ttys888"
    teardown_env
}

# Self-cleaning register: register foo, then bar on same TTY -> foo.tty gone.
test_05() {
    setup_env "projP"
    run_comms register foo
    assert_file_exists "05a: foo.tty exists" "$PROJECT_DIR/.fagents-tty/agents/foo.tty"
    run_comms register bar
    assert_file_missing "05b: foo.tty REMOVED by self-clean" "$PROJECT_DIR/.fagents-tty/agents/foo.tty"
    assert_file_exists "05c: bar.tty exists" "$PROJECT_DIR/.fagents-tty/agents/bar.tty"
    local content
    content=$(cat "$PROJECT_DIR/.fagents-tty/agents/bar.tty")
    assert "05d: bar.tty contains TTY path" "$content" "/dev/ttys999"
    teardown_env
}

# -- Tests: sender identity --

# Invalid project dirname (contains spaces) -> exit 7
test_06() {
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local proj="$TMPDIR/bad name"
    mkdir -p "$proj/.fagents-tty/bin"
    cp "$COMMS_SRC" "$proj/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$proj/.fagents-tty/bin/wake.sh"
    chmod +x "$proj/.fagents-tty/bin/comms.sh"
    export FAGENTS_TTY_FORCE_TTY="/dev/ttys999"
    local out rc
    out=$(cd "$proj" && bash .fagents-tty/bin/comms.sh status 2>&1)
    rc=$?
    assert "06a: status exits 7 on invalid dirname" "$rc" "7"
    assert_contains "06b: error names the dirname" "$out" "invalid-project-dirname"
    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_FORCE_TTY TMPDIR
}

# Sender identity = the agent whose agents/<name>.tty contains my TTY.
test_07() {
    setup_with_sibling
    run_comms msg projB:remote "hi"
    assert "07a: msg exits 0" "$COMMS_RC" "0"
    local envelope
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "07b: sender prefix is projP:alice" "$envelope" "[FAGENTS-TTY from projP:alice]:"
    teardown_env
}

# No agents/ registered -> exit 6.
test_08() {
    setup_env "projP"
    setup_sibling_project "projB" "/dev/ttys888" "remote"
    run_comms msg projB:remote "hi"
    assert "08a: missing agents/ -> exit 6" "$COMMS_RC" "6"
    assert_contains "08b: not-registered-from-this-tty" "$COMMS_OUT" "not-registered-from-this-tty"
    teardown_env
}

# -- Tests: send happy path --

test_09() {
    setup_with_sibling
    run_comms msg projB:remote "ping"
    assert "09a: msg exits 0" "$COMMS_RC" "0"
    local envelope target
    envelope=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    target=$(awk -F'\t' 'NR==1{print $1}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert "09b: wake target is the TTY device path" "$target" "/dev/ttys888"
    assert_contains "09c: envelope has FAGENTS-TTY prefix" "$envelope" "[FAGENTS-TTY from projP:alice]:"
    assert_contains "09d: envelope has body" "$envelope" ": ping."
    assert_contains "09e: envelope has reply command" "$envelope" "Reply: bash .fagents-tty/bin/comms.sh msg projP:alice"
    teardown_env
}

test_10() {
    setup_env "projP"
    run_comms register alice
    run_comms msg unknownproject:agent "hi"
    assert "10a: msg unknown project -> exit 2" "$COMMS_RC" "2"
    assert_contains "10b: error mentions no-such-project" "$COMMS_OUT" "no-such-project"
    teardown_env
}

test_11() {
    setup_with_sibling
    run_comms msg projB:nonexistent "hi"
    assert "11a: known project, unknown agent -> exit 2" "$COMMS_RC" "2"
    assert_contains "11b: error mentions no-such-agent" "$COMMS_OUT" "no-such-agent"
    teardown_env
}

# Bogus target TTY device path -> wake mock returns 3.
test_12() {
    setup_with_sibling
    export FAGENTS_TTY_MOCK_WAKE_EXIT=3
    run_comms msg projB:remote "hi"
    assert "12: wake failure -> exit 3" "$COMMS_RC" "3"
    teardown_env
}

# -- Tests: body sanitization --

test_13() {
    setup_with_sibling
    run_comms msg projB:remote $'line1\nline2'
    assert "13a: LF body exits 0" "$COMMS_RC" "0"
    local env
    env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "13b: LF replaced with space" "$env" "line1 line2"
    teardown_env
}

test_14() {
    setup_with_sibling
    run_comms msg projB:remote $'before\rafter'
    assert "14a: CR body exits 0" "$COMMS_RC" "0"
    local env
    env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "14b: CR replaced with space" "$env" "before after"
    teardown_env
}

test_15() {
    setup_with_sibling
    run_comms msg projB:remote $'\x1b[31mred\x1b[0m'
    assert "15a: ESC body exits 0" "$COMMS_RC" "0"
    local env
    env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "15b: ESC replaced" "$env" "[31mred [0m"
    if printf '%s' "$env" | LC_ALL=C grep -q $'\x1b'; then
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("15c: raw ESC byte still present")
    else
        PASS=$((PASS + 1))
    fi
    teardown_env
}

test_16() {
    setup_with_sibling
    run_comms msg projB:remote "a    b"
    assert "16a: spaces collapse exits 0" "$COMMS_RC" "0"
    local env
    env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "16b: 'a b' (collapsed)" "$env" ": a b."
    teardown_env
}

test_17() {
    setup_with_sibling
    run_comms msg projB:remote ""
    assert "17: empty body -> exit 5" "$COMMS_RC" "5"
    teardown_env
}

test_18() {
    setup_with_sibling
    local utf8=$'naive\xCC\x81'
    run_comms msg projB:remote "$utf8"
    assert "18a: UTF-8 exits 0" "$COMMS_RC" "0"
    local env
    env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    if printf '%s' "$env" | LC_ALL=C grep -q $'naive\xCC\x81'; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("18b: UTF-8 bytes mangled")
    fi
    teardown_env
}

test_19() {
    setup_with_sibling
    run_comms msg projB:remote $'\t\n\r\x07'
    assert "19: all-controls -> exit 5" "$COMMS_RC" "5"
    teardown_env
}

# -- Tests: address grammar --

test_20() {
    setup_env "projP"
    run_comms register alice
    run_comms msg "foo:bar:baz" "hi"
    assert "20: extra colon -> exit 1" "$COMMS_RC" "1"
    teardown_env
}

test_21() {
    setup_env "projP"
    run_comms register alice
    run_comms msg ":foo" "hi"
    assert "21a: empty project -> exit 1" "$COMMS_RC" "1"
    run_comms msg "foo:" "hi"
    assert "21b: empty agent -> exit 1" "$COMMS_RC" "1"
    run_comms ls --project "bad name"
    assert "21c: ls --project bad-name -> exit 1" "$COMMS_RC" "1"
    teardown_env
}

# -- Tests: truncation vs wake --

test_22() {
    setup_with_sibling
    local big
    big=$(printf 'a%.0s' $(seq 1 900))
    export FAGENTS_TTY_MOCK_WAKE_EXIT=0
    run_comms msg projB:remote "$big"
    assert "22a: truncated + wake success -> exit 4" "$COMMS_RC" "4"
    local env
    env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "22b: TRUNCATED suffix" "$env" "...[TRUNCATED]"
    teardown_env
}

test_23() {
    setup_with_sibling
    local big
    big=$(printf 'a%.0s' $(seq 1 900))
    export FAGENTS_TTY_MOCK_WAKE_EXIT=3
    run_comms msg projB:remote "$big"
    assert "23: truncated + wake failure -> exit 3 (not 4)" "$COMMS_RC" "3"
    teardown_env
}

# -- Tests: discovery / ls --

test_24() {
    setup_env "projP"
    run_comms register alice
    setup_sibling_project "projB" "/dev/ttys888" "bob"
    run_comms ls
    assert "24a: ls exits 0" "$COMMS_RC" "0"
    assert_contains "24b: ls includes projB:bob" "$COMMS_OUT" "projB:bob"
    # Should NOT include current project's own registration
    if printf '%s' "$COMMS_OUT" | grep -q "projP:alice"; then
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("24c: ls leaked current project's registration")
    else
        PASS=$((PASS + 1))
    fi
    teardown_env
}

test_25() {
    setup_env "projP"
    run_comms register alice
    setup_sibling_project "projB" "/dev/ttys888" "bob"
    setup_sibling_project "projC" "/dev/ttys777" "carol"
    run_comms ls --project projB
    assert "25a: ls --project exits 0" "$COMMS_RC" "0"
    local line_count
    line_count=$(printf '%s' "$COMMS_OUT" | grep -c ":")
    assert "25b: ls --project filters to 1 line" "$line_count" "1"
    assert_contains "25c: ls --project shows projB:bob" "$COMMS_OUT" "projB:bob"
    teardown_env
}

test_26() {
    setup_env "projP"
    run_comms register alice
    run_comms ls
    assert "26a: ls with no siblings exits 0" "$COMMS_RC" "0"
    assert "26b: ls output empty" "$COMMS_OUT" ""
    teardown_env
}

# -- Tests: FAGENTS_TTY_SEARCH_PATH --

test_27() {
    setup_env "projP"
    run_comms register alice
    # Put target in a NON-default location
    local other_root="$TMPDIR/other_root"
    mkdir -p "$other_root/projZ/.fagents-tty/bin"
    cp "$COMMS_SRC" "$other_root/projZ/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$other_root/projZ/.fagents-tty/bin/wake.sh"
    chmod +x "$other_root/projZ/.fagents-tty/bin/comms.sh"
    FAGENTS_TTY_FORCE_TTY=/dev/ttys888 \
        bash "$other_root/projZ/.fagents-tty/bin/comms.sh" register zed >/dev/null

    # Default discovery: should NOT find projZ
    run_comms msg projZ:zed "hi"
    assert "27a: default discovery exit 2 for projZ" "$COMMS_RC" "2"

    # With override: should find it
    export FAGENTS_TTY_SEARCH_PATH="$other_root"
    run_comms msg projZ:zed "hi"
    assert "27b: SEARCH_PATH override exit 0" "$COMMS_RC" "0"
    teardown_env
}

# Multiple roots, both have project foo with agent file -> exit 9.
test_28() {
    setup_env "projP"
    run_comms register alice
    local rootA="$TMPDIR/rootA"
    local rootB="$TMPDIR/rootB"
    for r in "$rootA" "$rootB"; do
        mkdir -p "$r/foo/.fagents-tty/bin"
        cp "$COMMS_SRC" "$r/foo/.fagents-tty/bin/comms.sh"
        cp "$WAKE_SRC" "$r/foo/.fagents-tty/bin/wake.sh"
        chmod +x "$r/foo/.fagents-tty/bin/comms.sh"
        FAGENTS_TTY_FORCE_TTY=/dev/ttys888 \
            bash "$r/foo/.fagents-tty/bin/comms.sh" register agent >/dev/null
    done
    export FAGENTS_TTY_SEARCH_PATH="$rootA:$rootB"
    : > "$FAGENTS_TTY_MOCK_WAKE_LOG"
    run_comms msg foo:agent "hi"
    assert "28a: ambiguous (both have agent) -> exit 9" "$COMMS_RC" "9"
    assert_contains "28b: error names ambiguous-target" "$COMMS_OUT" "ambiguous-target"
    local log_lines
    log_lines=$(wc -l < "$FAGENTS_TTY_MOCK_WAKE_LOG" | tr -d ' ')
    assert "28c: NO wake fired" "$log_lines" "0"
    teardown_env
}

# Multiple roots, only ONE has the agent file -> still exit 9 (project-level).
test_29() {
    setup_env "projP"
    run_comms register alice
    local rootA="$TMPDIR/rootA"
    local rootB="$TMPDIR/rootB"
    # rootA/foo: project exists but no agent file
    mkdir -p "$rootA/foo/.fagents-tty/agents"
    # rootB/foo: project + agent
    mkdir -p "$rootB/foo/.fagents-tty/bin"
    cp "$COMMS_SRC" "$rootB/foo/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$rootB/foo/.fagents-tty/bin/wake.sh"
    chmod +x "$rootB/foo/.fagents-tty/bin/comms.sh"
    FAGENTS_TTY_FORCE_TTY=/dev/ttys888 \
        bash "$rootB/foo/.fagents-tty/bin/comms.sh" register agent >/dev/null
    export FAGENTS_TTY_SEARCH_PATH="$rootA:$rootB"
    : > "$FAGENTS_TTY_MOCK_WAKE_LOG"
    run_comms msg foo:agent "hi"
    assert "29a: ambiguous (project-level) -> exit 9 even though only one has agent" "$COMMS_RC" "9"
    local log_lines
    log_lines=$(wc -l < "$FAGENTS_TTY_MOCK_WAKE_LOG" | tr -d ' ')
    assert "29b: NO wake fired" "$log_lines" "0"
    teardown_env
}

# Empty FAGENTS_TTY_SEARCH_PATH components -> exit 1.
test_30() {
    setup_env "projP"
    run_comms register alice
    local bad
    for bad in ":" ":/tmp" "/tmp:" "/tmp::/other"; do
        FAGENTS_TTY_SEARCH_PATH="$bad" run_comms msg foo:agent "hi"
        if [ "$COMMS_RC" -eq 1 ]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            FAILED_DETAILS+=("30: SEARCH_PATH '$bad' should exit 1 (got $COMMS_RC)")
        fi
    done
    teardown_env
}

# Status prints search roots
test_31() {
    setup_env "projP"
    run_comms register alice
    run_comms status
    assert "31a: status exits 0" "$COMMS_RC" "0"
    assert_contains "31b: status shows project_name" "$COMMS_OUT" "project_name: projP"
    assert_contains "31c: status shows search roots header" "$COMMS_OUT" "Search roots"
    # Default search root = dirname of PROJECT_ROOT (which is TMPDIR)
    assert_contains "31d: default search root is TMPDIR" "$COMMS_OUT" "$TMPDIR"
    teardown_env
}

# -- Tests: wake.sh strict regex --

# Real wake.sh (not the mock): valid paths pass regex; invalid get rejected with exit 2.
test_32() {
    setup_env "projP"
    local rc out
    # Valid shapes (real wake.sh; will probably exit 3 because TTY doesn't exist, but NOT 2)
    for valid in "/dev/ttys999" "/dev/pts/0" "/dev/tty" "/dev/ttyACM0" "/dev/tty1"; do
        out=$(bash "$WAKE_SRC" "$valid" "test" 2>&1)
        rc=$?
        if [ "$rc" -eq 2 ]; then
            FAIL=$((FAIL + 1))
            FAILED_DETAILS+=("32: valid path '$valid' was rejected (rc=2)")
        else
            PASS=$((PASS + 1))
        fi
    done
    # Invalid shapes: must exit 2 from regex
    local bad
    for bad in "/dev/pts/../../etc/passwd" "/dev/tty/../../etc/passwd" "/dev/ttyACM0/foo" "/tmp/foo" "/dev/null" "/dev/pts/0/extra"; do
        out=$(bash "$WAKE_SRC" "$bad" "test" 2>&1)
        rc=$?
        if [ "$rc" -eq 2 ]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            FAILED_DETAILS+=("32: invalid path '$bad' was NOT rejected (rc=$rc)")
        fi
    done
    teardown_env
}

# Python encode loop handles split UTF-8 (carried over from v1.1 test 41)
test_33() {
    local payload
    payload=$(printf '€%.0s' $(seq 1 266))
    payload+=$'\xE2\x82'
    local actual_bytes
    actual_bytes=$(printf '%s' "$payload" | wc -c | tr -d ' ')
    assert "33a: payload is 800 bytes" "$actual_bytes" "800"
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
    assert "33b: python encode loop exits 0 on split UTF-8" "$rc" "0"
    assert "33c: encoded byte count == input" "$out" "800"
}

# Large body (200KB) -> exit 4, not 141 SIGPIPE
test_34() {
    setup_with_sibling
    local huge
    huge=$(printf 'a%.0s' $(seq 1 200000))
    run_comms msg projB:remote "$huge"
    assert "34a: 200KB body exit 4 (not 141 SIGPIPE)" "$COMMS_RC" "4"
    local env
    env=$(awk -F'\t' 'NR==1{print $2}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert_contains "34b: TRUNCATED suffix" "$env" "...[TRUNCATED]"
    teardown_env
}

# -- Tests: unregister --

test_35() {
    setup_env "projP"
    run_comms register foo
    run_comms register bar
    run_comms unregister foo
    assert "35a: unregister exits 0" "$COMMS_RC" "0"
    assert_file_missing "35b: foo.tty removed" "$PROJECT_DIR/.fagents-tty/agents/foo.tty"
    assert_file_exists "35c: bar.tty preserved" "$PROJECT_DIR/.fagents-tty/agents/bar.tty"
    teardown_env
}

test_36() {
    setup_env "projP"
    run_comms unregister nonexistent
    assert "36: unregister nonexistent exits 0 (idempotent)" "$COMMS_RC" "0"
    teardown_env
}

# -- Tests: file modes --

test_37() {
    setup_env "projP"
    run_comms register foo
    local m_file m_dir
    m_file=$(file_mode "$PROJECT_DIR/.fagents-tty/agents/foo.tty")
    m_dir=$(file_mode "$PROJECT_DIR/.fagents-tty/agents")
    assert "37a: agent .tty file mode 600" "$m_file" "600"
    assert "37b: agents/ dir mode 700" "$m_dir" "700"
    teardown_env
}

# -- Tests: setup.sh --

test_38() {
    setup_env "projP"
    run_setup
    assert "38a: setup exits 0" "$SETUP_RC" "0"
    assert_file_exists "38b: bin/comms.sh exists" "$PROJECT_DIR/.fagents-tty/bin/comms.sh"
    assert_file_exists "38c: bin/wake.sh exists" "$PROJECT_DIR/.fagents-tty/bin/wake.sh"
    assert_file_exists "38d: .gitignore exists" "$PROJECT_DIR/.fagents-tty/.gitignore"
    assert_dir_missing "38e: agents/ NOT pre-created" "$PROJECT_DIR/.fagents-tty/agents"
    assert_file_missing "38f: NO config file" "$PROJECT_DIR/.fagents-tty/config"
    assert_dir_missing "38g: NO sessions/ dir" "$PROJECT_DIR/.fagents-tty/sessions"
    teardown_env
}

# Invalid project dirname at setup time -> exit 1
test_39() {
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local bad_proj="$TMPDIR/bad name"
    mkdir -p "$bad_proj"
    FAKE_HOME="$TMPDIR/fake_home"
    mkdir -p "$FAKE_HOME"
    local out rc
    out=$(cd "$bad_proj" && HOME="$FAKE_HOME" bash "$REPO_ROOT/setup.sh" 2>&1)
    rc=$?
    assert "39a: setup exits 1 on invalid dirname" "$rc" "1"
    assert_contains "39b: error mentions invalid dirname" "$out" "invalid project dirname"
    rm -rf "$TMPDIR"
}

# Setup rejects v1.x flags
test_40() {
    setup_env "projP"
    run_setup --project custom
    assert "40a: --project rejected" "$SETUP_RC" "1"
    assert_contains "40b: --project Unknown arg" "$SETUP_OUT" "Unknown arg"
    run_setup --force
    assert "40c: --force rejected" "$SETUP_RC" "1"
    assert_contains "40d: --force Unknown arg" "$SETUP_OUT" "Unknown arg"
    teardown_env
}

# Setup actively removes stale v1.x config + sessions/
test_41() {
    setup_env "projP"
    # Plant v1.x layout
    printf 'project_name=oldname\n' > "$PROJECT_DIR/.fagents-tty/config"
    mkdir -p "$PROJECT_DIR/.fagents-tty/sessions"
    touch "$PROJECT_DIR/.fagents-tty/sessions/stale.agent"
    run_setup --update
    assert "41a: --update exits 0" "$SETUP_RC" "0"
    assert_file_missing "41b: stale config removed" "$PROJECT_DIR/.fagents-tty/config"
    assert_dir_missing "41c: stale sessions/ removed" "$PROJECT_DIR/.fagents-tty/sessions"
    assert_contains "41d: setup announced cleanup" "$SETUP_OUT" "Removed stale v1.x files"
    teardown_env
}

# Setup detects orphaned ~/.fagents-tty/registry/ in fake HOME
test_42() {
    setup_env "projP"
    mkdir -p "$FAKE_HOME/.fagents-tty/registry/orphaned-old-proj"
    run_setup
    assert "42a: setup exits 0 (non-blocking notice)" "$SETUP_RC" "0"
    assert_contains "42b: notice references v1.x registry path" "$SETUP_OUT" ".fagents-tty/registry"
    teardown_env
}

# --no-launchers / --no-skill
test_43() {
    setup_env "projP"
    run_setup --no-launchers --no-skill
    assert "43a: setup exits 0" "$SETUP_RC" "0"
    assert_file_missing "43b: no launch-claude" "$PROJECT_DIR/launch-claude"
    assert_file_missing "43c: no launch-codex" "$PROJECT_DIR/launch-codex"
    assert_dir_missing "43d: no claude skill dir" "$PROJECT_DIR/.claude/skills/fagents-tty"
    assert_dir_missing "43e: no codex skill dir" "$PROJECT_DIR/.codex/skills/fagents-tty"
    teardown_env
}

# -- Tests: launchers (carried over from v1.1) --

test_44() {
    setup_env "projP"
    run_setup
    assert_file_exists "44a: launch-claude" "$PROJECT_DIR/launch-claude"
    assert_file_exists "44b: launch-codex" "$PROJECT_DIR/launch-codex"
    local m_claude
    m_claude=$(file_mode "$PROJECT_DIR/launch-claude")
    assert "44c: launch-claude mode 700" "$m_claude" "700"
    local content
    content=$(cat "$PROJECT_DIR/launch-claude")
    # shellcheck disable=SC2016
    assert_contains "44d: defines ROOT" "$content" 'ROOT="$(cd '
    # shellcheck disable=SC2016
    assert_contains "44e: tandem conditional" "$content" '[ -x "$ROOT/.tandem/bin/handoff.sh" ] && bash "$ROOT/.tandem/bin/handoff.sh" register claude'
    # shellcheck disable=SC2016
    assert_contains "44f: fagents-tty conditional" "$content" '[ -x "$ROOT/.fagents-tty/bin/comms.sh" ] && bash "$ROOT/.fagents-tty/bin/comms.sh" register claude'
    # shellcheck disable=SC2016
    assert_contains "44g: exec with args" "$content" 'exec claude "$@"'
    teardown_env
}

test_45() {
    setup_env "projP"
    cat > "$PROJECT_DIR/launch-claude" <<'EOF'
#!/bin/bash
# Launch Claude Code with tandem TTY registration
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TTY_DEV=$(tty 2>/dev/null) || true
[[ "$TTY_DEV" == /dev/* ]] && echo "$TTY_DEV" > "$ROOT/.tandem/claude.tty"
exec claude "$@"
EOF
    chmod 0700 "$PROJECT_DIR/launch-claude"
    run_setup
    assert "45a: setup exits 0" "$SETUP_RC" "0"
    local content
    content=$(cat "$PROJECT_DIR/launch-claude")
    # shellcheck disable=SC2016
    assert_contains "45b: tandem line preserved" "$content" '[[ "$TTY_DEV" == /dev/* ]] && echo "$TTY_DEV" > "$ROOT/.tandem/claude.tty"'
    # shellcheck disable=SC2016
    assert_contains "45c: fagents-tty register line inserted" "$content" '[ -x "$ROOT/.fagents-tty/bin/comms.sh" ] && bash "$ROOT/.fagents-tty/bin/comms.sh" register claude'
    # shellcheck disable=SC2016
    assert_contains "45d: exec preserved" "$content" 'exec claude "$@"'
    # Insertion order: the fagents-tty register line must appear BEFORE the
    # first `exec` line, otherwise registration runs after the CLI has already
    # taken over the TTY.
    local fagents_line exec_line
    fagents_line=$(grep -n 'fagents-tty/bin/comms.sh' "$PROJECT_DIR/launch-claude" | head -1 | cut -d: -f1)
    exec_line=$(grep -n '^exec ' "$PROJECT_DIR/launch-claude" | head -1 | cut -d: -f1)
    if [ -n "$fagents_line" ] && [ -n "$exec_line" ] && [ "$fagents_line" -lt "$exec_line" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_DETAILS+=("45e: fagents-tty register line not before exec (fagents=$fagents_line, exec=$exec_line)")
    fi
    teardown_env
}

test_46() {
    setup_env "projP"
    cat > "$PROJECT_DIR/launch-claude" <<'EOF'
#!/bin/bash
echo "hand-rolled, no ROOT"
exec claude "$@"
EOF
    chmod 0700 "$PROJECT_DIR/launch-claude"
    local sha1
    sha1=$(shasum -a 256 "$PROJECT_DIR/launch-claude" | awk '{print $1}')
    run_setup
    assert "46a: setup exits 0 (warning, non-blocking)" "$SETUP_RC" "0"
    assert_contains "46b: warning mentions ROOT=" "$SETUP_OUT" "does not define 'ROOT='"
    assert_file_unchanged "46c: launcher unchanged" "$PROJECT_DIR/launch-claude" "$sha1"
    teardown_env
}

# --agents parsing
test_47() {
    setup_env "projP"
    local bad
    for bad in "" "," ",claude" "claude," "claude,,codex" "claude, ,codex" " claude"; do
        run_setup --agents "$bad"
        if [ "$SETUP_RC" -eq 1 ]; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            FAILED_DETAILS+=("47: --agents '$bad' should fail (got $SETUP_RC)")
        fi
    done
    teardown_env
}

test_48() {
    setup_env "projP"
    run_setup --agents "alpha,beta"
    assert "48a: setup exits 0" "$SETUP_RC" "0"
    assert_file_exists "48b: launch-alpha" "$PROJECT_DIR/launch-alpha"
    assert_file_exists "48c: launch-beta" "$PROJECT_DIR/launch-beta"
    assert_file_missing "48d: NO launch-claude (overridden)" "$PROJECT_DIR/launch-claude"
    teardown_env
}

# -- Tests: project-local skill install --

test_49() {
    setup_env "projP"
    run_setup
    assert_file_exists "49a: claude skill" "$PROJECT_DIR/.claude/skills/fagents-tty/SKILL.md"
    assert_file_exists "49b: codex skill" "$PROJECT_DIR/.codex/skills/fagents-tty/SKILL.md"
    local m_file m_dir
    m_file=$(file_mode "$PROJECT_DIR/.claude/skills/fagents-tty/SKILL.md")
    m_dir=$(file_mode "$PROJECT_DIR/.claude/skills/fagents-tty")
    assert "49c: SKILL.md mode 600" "$m_file" "600"
    assert "49d: skill dir mode 700" "$m_dir" "700"
    teardown_env
}

# Permission repair
test_50() {
    setup_env "projP"
    mkdir -p "$PROJECT_DIR/.claude/skills/fagents-tty"
    chmod 0755 "$PROJECT_DIR/.claude/skills/fagents-tty"
    echo stale > "$PROJECT_DIR/.claude/skills/fagents-tty/SKILL.md"
    chmod 0644 "$PROJECT_DIR/.claude/skills/fagents-tty/SKILL.md"
    run_setup
    local m_file m_dir
    m_file=$(file_mode "$PROJECT_DIR/.claude/skills/fagents-tty/SKILL.md")
    m_dir=$(file_mode "$PROJECT_DIR/.claude/skills/fagents-tty")
    assert "50a: dir tightened to 700" "$m_dir" "700"
    assert "50b: file tightened to 600" "$m_file" "600"
    teardown_env
}

# No global skill pollution
test_51() {
    setup_env "projP"
    run_setup
    assert_file_missing "51a: no global claude skill" "$FAKE_HOME/.claude/skills/fagents-tty/SKILL.md"
    assert_file_missing "51b: no global codex skill" "$FAKE_HOME/.codex/skills/fagents-tty/SKILL.md"
    teardown_env
}

# --update idempotency
test_52() {
    setup_env "projP"
    run_setup
    local sha_launcher sha_skill
    sha_launcher=$(shasum -a 256 "$PROJECT_DIR/launch-claude" | awk '{print $1}')
    sha_skill=$(shasum -a 256 "$PROJECT_DIR/.claude/skills/fagents-tty/SKILL.md" | awk '{print $1}')
    run_setup --update
    assert "52a: --update exits 0" "$SETUP_RC" "0"
    assert_file_unchanged "52b: launcher unchanged" "$PROJECT_DIR/launch-claude" "$sha_launcher"
    assert_file_unchanged "52c: skill unchanged" "$PROJECT_DIR/.claude/skills/fagents-tty/SKILL.md" "$sha_skill"
    teardown_env
}

# -- End-to-end --

test_53() {
    TMPDIR=$(cd "$(mktemp -d)" && pwd -P)
    local A="$TMPDIR/A" B="$TMPDIR/B"
    mkdir -p "$A/.fagents-tty/bin" "$B/.fagents-tty/bin"
    cp "$COMMS_SRC" "$A/.fagents-tty/bin/comms.sh"
    cp "$COMMS_SRC" "$B/.fagents-tty/bin/comms.sh"
    cp "$WAKE_SRC" "$A/.fagents-tty/bin/wake.sh"
    cp "$WAKE_SRC" "$B/.fagents-tty/bin/wake.sh"
    chmod +x "$A/.fagents-tty/bin/comms.sh" "$B/.fagents-tty/bin/comms.sh"

    export FAGENTS_TTY_WAKE_BIN="$MOCK_WAKE"
    export FAGENTS_TTY_MOCK_WAKE_LOG="$TMPDIR/wake.log"
    export FAGENTS_TTY_MOCK_WAKE_EXIT=0

    ( cd "$A" && FAGENTS_TTY_FORCE_TTY=/dev/ttys001 bash .fagents-tty/bin/comms.sh register alice ) >/dev/null
    ( cd "$B" && FAGENTS_TTY_FORCE_TTY=/dev/ttys002 bash .fagents-tty/bin/comms.sh register bob ) >/dev/null

    ( cd "$A" && FAGENTS_TTY_FORCE_TTY=/dev/ttys001 bash .fagents-tty/bin/comms.sh msg B:bob "from A" ) >/dev/null
    local rc1=$?
    ( cd "$B" && FAGENTS_TTY_FORCE_TTY=/dev/ttys002 bash .fagents-tty/bin/comms.sh msg A:alice "from B" ) >/dev/null
    local rc2=$?
    assert "53a: A->B exits 0" "$rc1" "0"
    assert "53b: B->A exits 0" "$rc2" "0"
    local log_lines first second
    log_lines=$(wc -l < "$FAGENTS_TTY_MOCK_WAKE_LOG" | tr -d ' ')
    assert "53c: wake log has 2 entries" "$log_lines" "2"
    first=$(awk -F'\t' 'NR==1{print $1}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    second=$(awk -F'\t' 'NR==2{print $1}' "$FAGENTS_TTY_MOCK_WAKE_LOG")
    assert "53d: first wake targets B's TTY (/dev/ttys002)" "$first" "/dev/ttys002"
    assert "53e: second wake targets A's TTY (/dev/ttys001)" "$second" "/dev/ttys001"

    rm -rf "$TMPDIR"
    unset FAGENTS_TTY_WAKE_BIN FAGENTS_TTY_MOCK_WAKE_LOG FAGENTS_TTY_MOCK_WAKE_EXIT TMPDIR
}

# -- Main --

# Regression for codex r3 P2: wake.sh exit-2 (regex reject of a malformed
# target TTY path stored in the target's agent file) must NOT leak through
# as msg exit-2. msg exit-2 is reserved for "no such project/agent" lookup
# misses; any wake failure maps to msg exit-3.
test_54() {
    setup_env "projP"
    run_comms register alice
    # Sibling project with an agents/.tty pointing at an invalid TTY path
    local sib="$TMPDIR/projB"
    mkdir -p "$sib/.fagents-tty/agents"
    chmod 0700 "$sib/.fagents-tty/agents"
    printf '/tmp/not-a-tty' > "$sib/.fagents-tty/agents/remote.tty"
    chmod 0600 "$sib/.fagents-tty/agents/remote.tty"
    # Use the REAL wake.sh (not the mock) so its regex actually fires
    export FAGENTS_TTY_WAKE_BIN="$WAKE_SRC"
    run_comms msg projB:remote "hi"
    assert "54a: invalid target TTY path -> msg exit 3, NOT 2" "$COMMS_RC" "3"
    assert_contains "54b: stderr names the invalid TTY path" "$COMMS_OUT" "/tmp/not-a-tty"
    teardown_env
}

main() {
    local i num
    for i in $(seq 1 54); do
        num=$(printf '%02d' "$i")
        if declare -f "test_$num" >/dev/null; then
            "test_$num"
        fi
    done

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
