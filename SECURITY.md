# Security

Project-specific security surface for fagents-tty.

## Stack

- Pure Bash 3.2+ (comms.sh, wake.sh, setup.sh, tests).
- Python 3 stdlib (only inside `wake.sh`, for the TIOCSTI ioctl call).
- Flat-file state on the local filesystem (`~/.fagents-tty/registry/`, `<project>/.fagents-tty/`).
- No databases, no network services, no daemons.

## Trust Boundaries

- **Same host, same UID assumed.** fagents-tty is a local-only transport. There is no cross-host protocol, no cross-user authentication, and no encryption. The threat model is "developer workstation where all agents and the operator share one UID".
- **Cross-UID confidentiality is NOT a guarantee, only defense-in-depth.** Both `comms.sh` and `setup.sh` set `umask 077` before any file or directory creation, so the registry under `~/.fagents-tty/registry/` and the per-project `.fagents-tty/` use mode `0700` for directories and `0600` for files. That blocks casual cross-UID reads, but anyone with traversal rights on a parent directory (an admin, a group-writable `$HOME` ancestor, an ACL'd path) can still bypass it. Treat the umask as best-effort hygiene, not a security perimeter. Same-UID processes can read and impersonate everything; that is the actual trust assumption.
- **`msg <body>` is untrusted input** even though it comes from a same-UID caller. The sender may have ingested it from external sources (logs, web responses, agent-generated text). Bodies are sanitized in `comms.sh` before envelope construction:
  - All bytes in `[\x00-\x1f\x7f]` (C0 control bytes including LF, CR, TAB, ESC, BEL) are replaced with single ASCII spaces. Prevents CR/LF injection that would submit extra prompts on the receiver's TTY, and neutralizes ANSI escape sequences.
  - Multiple whitespace bytes are collapsed; leading/trailing whitespace trimmed.
  - Capped at 800 bytes after sanitization (byte-length, not codepoint-length).
- **Sender identity is self-asserted.** The wake envelope prefix `[FAGENTS-TTY from X:Y]:` is built from the sender's local config plus a per-TTY sessions file. A malicious same-UID process can craft any sender prefix it wants; the receiver MUST treat all inbound msg bodies as untrusted text.
- **`<project>/.fagents-tty/config` is parsed as data, never `source`'d or `eval`'d.** Only `project_name=<value>` and `#`-comments are allowed. Unknown keys reject the file. The parsed value passes through `validate_name`. Test 22 confirms `project_name=ok; touch /tmp/pwned` does not execute the trailing command.
- **TIOCSTI requires NOPASSWD sudo.** Inherited from `fagents-tandem`'s sudoers grant on this host. fagents-tty does not add or require any new sudo entries beyond what tandem already needs. Without sudo, `wake.sh` exits 3.
- **Address parsing rejects path traversal.** Both `comms.sh msg <addr>` and direct `wake.sh <target>` invocations validate each segment against `^[A-Za-z0-9_][A-Za-z0-9_-]*$` BEFORE constructing the registry path. Test 39 covers `../escape:agent`, leading-hyphen, empty segments, and invalid characters.
- **`setup.sh` writes only inside `<project>/.fagents-tty/`, `~/.fagents-tty/registry/<project>/.path`, project-local launchers (`<project>/launch-<agent>`), and project-local skills (`<project>/.claude/skills/fagents-tty/`, `<project>/.codex/skills/fagents-tty/`).** It never modifies `.claude/settings.json` or `.codex/hooks.json`, never installs any skill globally under `~/.claude/skills/` or `~/.codex/skills/`, and never overwrites an existing launcher's `exec` line or arg handling (only inserts one register line before `exec` via portable awk). Test 35 hashes the JSON files before and after `setup.sh` to prove byte-for-byte preservation; tests 50, 52, 53 lock in the launcher-preservation contract; test 59 asserts the fake-`HOME` skill paths stay absent after setup.

## Checklist

Reviewers check these during REVIEW_CODE and QUALITY_REVIEW:

- [ ] Address segments validated against the name regex at every entry point (`register`, `msg`, `ls --project`, `unregister`, `setup.sh --project`, direct `wake.sh` call, config parser).
- [ ] No command injection (variables consistently double-quoted; no `eval`, no `source` on user-controlled files).
- [ ] Body sanitization runs on every `msg` invocation BEFORE envelope construction; control bytes never reach the wake call.
- [ ] `tmpfile` in `cmd_msg` is created via `mktemp`, written via redirection (not echoed through a shell), and removed after use; failure path is `die "mktemp failed"`.
- [ ] No globbing or path-traversal hole in the registry walk (`cmd_ls`).
- [ ] **No GLOBAL state written**: nothing under `~/.claude/skills/`, `~/.codex/skills/`, `.claude/settings.json`, or `.codex/hooks.json`. The only global write is `~/.fagents-tty/registry/<project>/.path` (registry slot claim, intentional). **Project-local writes ARE expected**: `<project>/.fagents-tty/`, `<project>/launch-<agent>` (or amends to existing), `<project>/.claude/skills/fagents-tty/`, `<project>/.codex/skills/fagents-tty/`.
- [ ] Wake envelope does not embed unsanitized input -- only the sanitized body and addresses that have already passed `validate_name`.
- [ ] Python encode path in `wake.sh` uses `os.fsencode(sys.argv[2])` so split multibyte UTF-8 bytes round-trip without `UnicodeEncodeError`.
- [ ] Test suite isolates `HOME`, `FAGENTS_TTY_REGISTRY_DIR`, and `FAGENTS_TTY_WAKE_BIN` so no test polluted real user state.
- [ ] Both `comms.sh` and `setup.sh` set `umask 077` before any file or directory creation. Registry files end up `0600`, registry/sessions dirs end up `0700`.
- [ ] `setup.sh` explicitly `chmod`s project-local skill paths (`0700` dir, `0600` file) after `mkdir -p` / `cp`. `umask` alone is not enough: it does not tighten an existing permissive directory and `cp` over an existing file preserves the destination mode. Test 58b proves repair-on-update behavior from pre-existing `0755`/`0644`.
- [ ] Launcher amend (`amend_existing_launcher`) does not modify any line other than inserting one register line before the first `^exec ` line. Existing `ROOT=` definitions, TTY-write logic, and `exec ... "$@"` arg-pass-through are byte-for-byte preserved. Test 50 asserts this on the real `fagents-tandem` launcher template.
