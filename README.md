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

- `<your-project>/.fagents-tty/{bin,sessions,config,.gitignore}` (per-project),
- `~/.fagents-tty/registry/<project>/.path` (global; one line containing the project's absolute path, so the registry slot for that project name is claimed at install time and cannot be silently taken over by another project later -- see "Project-name conflicts" below).

Setup deliberately does NOT:

- modify `.claude/settings.json` or `.codex/hooks.json`,
- overwrite any top-level launcher script,
- install the agent skill globally to `~/.claude/skills/` or `~/.codex/skills/`.

The skill is opt-in (see below).

### Project-name conflicts

If `~/.fagents-tty/registry/<name>/.path` already exists and points to a different absolute project path, setup refuses with exit 1. Re-run with `--force` to take over (the previous registry directory is removed before the new `.path` is written). Pick a different `--project <name>` if you would rather keep both.

## Optional: install the skill

`skill/SKILL.md` teaches the agent how to register, send, and reply. fagents-tty does NOT auto-install it because that would leak into every Claude / Codex session on the host, including projects that have nothing to do with fagents-tty.

Pick the scope you want:

- **Per-project** (Claude Code reads `<project>/.claude/skills/`): from your project root, run `mkdir -p .claude/skills && ln -s /path/to/fagents-tty/skill .claude/skills/fagents-tty`. The skill is then loaded only in agents launched from this project.
- **Per-user** (every Claude session sees it): `ln -s /path/to/fagents-tty/skill ~/.claude/skills/fagents-tty`. Same for `~/.codex/skills/fagents-tty` if you use Codex.
- **None**: skip. The wake envelope already contains the verbatim reply command, so an agent without the skill can still respond correctly.

## Register (once per session)

```bash
bash .fagents-tty/bin/comms.sh register <agent-name>
```

Writes your TTY to a global registry at `~/.fagents-tty/registry/<project>/<agent>.tty`. After this, other projects can msg you as `<project>:<agent>`.

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
- No hook installation. No launcher overwrite. `setup.sh` writes only `<project>/.fagents-tty/` and the registry slot file `~/.fagents-tty/registry/<project>/.path` (see "Setup" above); it never touches tandem's `.tandem/` directory or its scripts.

If you want auto-registration on session start, copy `templates/launch-orchestrator` to your project and adapt it.

## Tests

```bash
bash test/test_comms.sh
```

44 test functions, 121 assertions. All TIOCSTI is mocked; the python encode path that real `wake.sh` uses is verified independently in test 41 (split UTF-8 from argv -> `os.fsencode` -> byte-by-byte ioctl payload, no `UnicodeEncodeError`). Real-TTY smoke test is manual:

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
- Not durable -- TIOCSTI fire-and-forget. If you need replay or queuing, an inbox.jsonl is the obvious v1.1 add.
