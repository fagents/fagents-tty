# Security

Project-specific security surface for fagents-tty.

## Stack

- Pure Bash 3.2+ (comms.sh, wake.sh, setup.sh, tests).
- Python 3 stdlib (only inside `wake.sh`, for the TIOCSTI ioctl call).
- Flat-file state on the local filesystem (`<project>/.fagents-tty/`).
- No global registry, no databases, no network services, no daemons.

## Trust Boundaries

- **Same host, same UID assumed.** fagents-tty is a local-only transport. There is no cross-host protocol, no cross-user authentication, and no encryption. The threat model is "developer workstation where all agents and the operator share one UID".
- **Cross-UID confidentiality is NOT a guarantee, only defense-in-depth.** Both `comms.sh` and `setup.sh` set `umask 077` before any file or directory creation, so `<project>/.fagents-tty/agents/` uses mode `0700` for directories and `0600` for files. That blocks casual cross-UID reads, but anyone with traversal rights on a parent directory (an admin, a group-writable `$HOME` ancestor, an ACL'd path) can still bypass it. Same-UID processes can read and impersonate everything; that is the actual trust assumption.
- **`msg <body>` is untrusted input** even though it comes from a same-UID caller. The sender may have ingested it from external sources (logs, web responses, agent-generated text). Bodies are sanitized in `comms.sh` before envelope construction:
  - All bytes in `[\x00-\x1f\x7f]` (C0 control bytes including LF, CR, TAB, ESC, BEL) are replaced with single ASCII spaces. Prevents CR/LF injection that would submit extra prompts on the receiver's TTY, and neutralizes ANSI escape sequences.
  - Multiple whitespace bytes collapsed; leading/trailing trimmed.
  - Capped at 800 bytes after sanitization (byte-length, not codepoint-length).
- **Sender identity is self-asserted, derived from filesystem state.** Sender project name = `basename "$PROJECT_ROOT"` (validated against the name regex; exit 7 if invalid). Sender agent name = whichever `agents/*.tty` file in this project contains my detected TTY. A malicious same-UID process can craft any sender prefix it wants by writing arbitrary `agents/<name>.tty` files; the receiver MUST treat all inbound msg bodies as untrusted text.
- **Discovery scope is bounded by `FAGENTS_TTY_SEARCH_PATH` (or the default parent dir).** Empty components in the search path are rejected with exit 1 -- the boundary is a delivery-safety knob, not a place to silently widen scope.
- **Multi-search-path ambiguity fails closed.** When more than one search root contains a project with the target basename, `msg` exits 9 with `ambiguous-target` instead of silently picking the first match. The user must disambiguate (narrow the search path or rename a project). Tests 28-29 cover both "both have the agent" and "only one has the agent" sub-cases.
- **`wake.sh` runs under `sudo -n`** and opens the target path with `os.O_RDWR`. The argument is validated with an anchored regex `^/dev/(tty[A-Za-z0-9_-]*|pts/[0-9]+)$` BEFORE any open. The pattern has no `*`-glob prefix matching, so `/dev/pts/../../etc/passwd`, `/dev/tty/foo`, `/dev/null`, `/tmp/foo`, and similar traversal attempts are rejected with exit 2 -- they never reach the `sudo python3 os.open` call.
- **Address parsing rejects path traversal.** Both `comms.sh msg <addr>` and direct `wake.sh <tty-path>` invocations validate inputs against anchored regexes before any path construction.
- **`setup.sh` writes only inside `<project>/.fagents-tty/`, `<project>/launch-<agent>`, `<project>/.claude/skills/fagents-tty/`, and `<project>/.codex/skills/fagents-tty/`.** It never modifies `.claude/settings.json` or `.codex/hooks.json`, never installs any skill globally under `~/.claude/skills/` or `~/.codex/skills/`, never writes to `~/.fagents-tty/`, and never overwrites an existing launcher's `exec` line or arg handling. Test 38 asserts no global writes; tests 45-46 lock in the launcher-preservation contract; test 51 asserts the fake `HOME` skill paths stay absent.

## Checklist

Reviewers check these during REVIEW_CODE and QUALITY_REVIEW:

- [ ] Address segments validated against the name regex at every entry point (`register`, `msg`, `ls --project`, `unregister`, `setup.sh` basename, direct `wake.sh` call).
- [ ] No command injection (variables consistently double-quoted; no `eval`, no `source` on user-controlled files; no config file at all in v2).
- [ ] Body sanitization runs on every `msg` invocation BEFORE envelope construction; control bytes never reach the wake call.
- [ ] `tmpfile` in `cmd_msg` is created via `mktemp`, written via redirection (not echoed through a shell), and removed after use; failure path is `die "mktemp failed"`.
- [ ] No globbing or path-traversal hole in the per-project registry walk (`cmd_ls`).
- [ ] **No GLOBAL state written**: nothing under `~/.claude/skills/`, `~/.codex/skills/`, `~/.fagents-tty/`, `.claude/settings.json`, or `.codex/hooks.json`. **Project-local writes ARE expected**: `<project>/.fagents-tty/`, `<project>/launch-<agent>` (or amends to existing), `<project>/.claude/skills/fagents-tty/`, `<project>/.codex/skills/fagents-tty/`.
- [ ] Wake envelope does not embed unsanitized input -- only the sanitized body and addresses that have already passed `validate_name`.
- [ ] Python encode path in `wake.sh` uses `os.fsencode(sys.argv[2])` so split multibyte UTF-8 bytes round-trip without `UnicodeEncodeError`.
- [ ] **`wake.sh` validates the TTY argument with an anchored regex** `^/dev/(tty[A-Za-z0-9_-]*|pts/[0-9]+)$` BEFORE the `sudo python3 os.open` call. No glob `*`-prefix matching. Test 32 covers six rejection cases.
- [ ] **Multi-search-path discovery fails closed on ambiguity** (`msg` exits 9 with `ambiguous-target`). Tests 28-29 cover.
- [ ] **Empty `FAGENTS_TTY_SEARCH_PATH` components are rejected** with exit 1 (test 30).
- [ ] Test suite isolates `HOME` and uses per-test `TMPDIR`; no test polluted real user state.
- [ ] Both `comms.sh` and `setup.sh` set `umask 077` before any file or directory creation. `agents/` ends up `0700`, agent `.tty` files end up `0600`.
- [ ] `setup.sh` explicitly `chmod`s project-local skill paths (`0700` dir, `0600` file) after `mkdir -p` / `cp`. `umask` alone is not enough: it does not tighten an existing permissive directory and `cp` over an existing file preserves the destination mode. Test 50 proves repair-on-update behavior.
- [ ] Launcher amend (`amend_existing_launcher`) does not modify any line other than inserting one register line before the first `^exec ` line. Existing `ROOT=` definitions, TTY-write logic, and `exec ... "$@"` arg-pass-through are byte-for-byte preserved (test 45).
