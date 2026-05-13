# fagents-tty

Cross-project agent messaging via TIOCSTI. Installable plugin, alongside `fagents-tandem` (no shared deps).

Tandem makes two agents in the **same** project take turns. fagents-tty lets an agent in **one** project talk to an agent in **another** project.

## Setup

```bash
git clone https://github.com/fagents/fagents-tty.git
cd your-project
bash path/to/fagents-tty/setup.sh
```

Setup writes:

- `<your-project>/.fagents-tty/{bin,sessions,config,.gitignore}` -- the comms toolkit, project-local.
- `~/.fagents-tty/registry/<project>/.path` -- one line containing the project's absolute path. Claims the registry slot for that project name at install time so it cannot be silently taken over by another project later (see "Project-name conflicts" below).
- `<your-project>/launch-claude` and `<your-project>/launch-codex` -- launcher scripts that register your TTY in tandem and fagents-tty (if either is installed) before exec'ing the CLI. If a launcher with the same name already exists (e.g. from a previous tandem install), setup amends it in place by inserting one register line before `exec`. Override the agent list with `--agents <comma-list>`, opt out with `--no-launchers`.
- `<your-project>/.claude/skills/fagents-tty/SKILL.md` and `<your-project>/.codex/skills/fagents-tty/SKILL.md` -- project-local agent skills explaining the cross-project msging convention. Opt out with `--no-skill`.

Setup deliberately does NOT:

- modify `.claude/settings.json` or `.codex/hooks.json`,
- write to `~/.claude/skills/` or `~/.codex/skills/` (no global skill install),
- overwrite the `exec` line or arg-handling of an existing launcher.

### Project-name conflicts

If `~/.fagents-tty/registry/<name>/.path` already exists and points to a different absolute project path, setup refuses with exit 1. Re-run with `--force` to take over (the previous registry directory is removed before the new `.path` is written). Pick a different `--project <name>` if you would rather keep both.

### Flags

```
bash setup.sh                          # install in current dir; default agents = claude,codex
bash setup.sh --project <name>         # explicit project name (default: basename)
bash setup.sh --force                  # override registry slot conflict
bash setup.sh --update                 # refresh bin scripts, launchers, and skills (idempotent)
bash setup.sh --agents <comma-list>    # override default launcher list (rejects empty entries)
bash setup.sh --no-launchers           # skip launcher install
bash setup.sh --no-skill               # skip per-project skill install
```

## Launchers

Each `launch-<agent>` does four things:

1. Resolves `ROOT` to the launcher's own directory.
2. If `.tandem/bin/handoff.sh` is executable, calls `handoff.sh register <agent>`.
3. If `.fagents-tty/bin/comms.sh` is executable, calls `comms.sh register <agent>`.
4. `exec <agent> "$@"` so CLI args (e.g. `./launch-claude --resume`) pass through.

If an existing launcher has no `ROOT=` definition or no `exec` line, setup prints a warning with the exact line you need to add and continues without modifying the file. The warning is non-blocking (setup exits 0).

For non-CLI-named agents (e.g. `--agents orchestrator`), the launcher's `exec orchestrator "$@"` line will not work unless `orchestrator` is on `$PATH`. Edit the exec line to point at the actual binary you use (`exec claude "$@"`, `exec codex "$@"`, etc.).

## Register

Launchers register automatically. If you start your session via `./launch-claude` (or whatever launcher you adapted), your TTY is already in the registry. Confirm with:

```bash
bash .fagents-tty/bin/comms.sh status
```

If you bypassed the launcher, register manually:

```bash
bash .fagents-tty/bin/comms.sh register <agent-name>
```

## Send a message

```bash
bash .fagents-tty/bin/comms.sh msg <project>:<agent> "<body>"
```

The receiver gets an injected line:

```
[FAGENTS-TTY from <yourProject>:<yourAgent>]: <body>. Reply: bash .fagents-tty/bin/comms.sh msg <yourProject>:<yourAgent> "..."
```

The reply command is verbatim in every msg, so even agents without the skill loaded can reply correctly.

## Discover

```bash
bash .fagents-tty/bin/comms.sh ls               # all registered addresses
bash .fagents-tty/bin/comms.sh ls --project P   # one project
bash .fagents-tty/bin/comms.sh status           # your own registrations
```

## Address format

`<project>:<agent>` -- both segments match `^[A-Za-z0-9_][A-Za-z0-9_-]*$`.

## Body rules

- Control bytes (LF, CR, TAB, ESC, BEL, ...) are REPLACED with single spaces.
- Consecutive spaces are collapsed to one.
- Max 800 bytes after normalization. Longer bodies get `...[TRUNCATED]` and `msg` returns exit 4.
- Empty body after sanitization fails with exit 5.

## Exit codes for `msg`

| Code | Meaning |
|------|---------|
| 0 | delivered, body fit |
| 1 | usage / invalid args / invalid address |
| 2 | no such address |
| 3 | sudo/TIOCSTI failure |
| 4 | delivered, body was truncated |
| 5 | empty body after sanitization |
| 6 | sender not registered from this TTY |
| 7 | project config missing or invalid |
| 8 | (unregister) foreign-project refusal |

Precedence: pre-wake errors (1, 5, 6, 7) and target lookup (2) check first. Wake failure (1/2/3 from wake) overrides truncation. Exit 4 only fires on successful delivery of a truncated body.

## Wake

Uses TIOCSTI to inject keystrokes into the target TTY. Requires NOPASSWD sudo for the python3 ioctl call. Same requirement as `fagents-tandem`; if tandem already works, fagents-tty works.

`bin/wake.sh` exit codes match tandem's contract: `0` delivered, `1` usage, `2` no TTY registered, `3` sudo/TIOCSTI failure.

## Coexistence with tandem

- Different dirs: `.fagents-tty/` vs `.tandem/`. No shared files.
- Different registries: tandem uses per-project `.tandem/<agent>.tty`; fagents-tty uses global `~/.fagents-tty/registry/<project>/<agent>.tty`.
- Different prefixes: tandem injects `[claude]:` / `[codex]:`; fagents-tty injects `[FAGENTS-TTY from X:Y]:`.
- No hook installation, no global skill install. fagents-tty `setup.sh` writes only `<project>/.fagents-tty/`, the registry slot file `~/.fagents-tty/registry/<project>/.path`, project-local launchers (`./launch-<agent>`), and project-local skills (`<project>/.claude/skills/fagents-tty/`, `<project>/.codex/skills/fagents-tty/`).
- Existing tandem launchers (`./launch-claude` from `fagents-tandem` setup) are amended in place with a single register line; tandem's existing TTY-write logic and `exec ... "$@"` are preserved byte-for-byte.

## Tests

```bash
bash test/test_comms.sh
```

60 numbered tests plus `test_58b` (the permission-repair regression), 192 assertions. All TIOCSTI is mocked; the python encode path that real `wake.sh` uses is verified independently in test 41 (split UTF-8 from argv -> `os.fsencode` -> byte-by-byte ioctl payload, no `UnicodeEncodeError`). Real-TTY smoke test is manual:

```bash
# In project A (your TTY = /dev/ttysN):
bash .fagents-tty/bin/comms.sh register A
# In project B (different TTY):
bash .fagents-tty/bin/comms.sh register B
# From either side:
bash .fagents-tty/bin/comms.sh msg <other>:<other> "smoke test"
# The other side's prompt should see the injected envelope.
```

## What it's not

- Not a state machine or protocol (that's `fagents-tandem`).
- Not cross-host -- local TTYs only.
- Not authenticated -- same host, same UID assumed. Sender prefix is self-asserted.
- Not durable -- TIOCSTI fire-and-forget. If you need replay or queuing, an inbox.jsonl is a future v1.x add.
