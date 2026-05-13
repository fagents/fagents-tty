# fagents-tty

Cross-project agent messaging via TIOCSTI. Installable plugin, alongside `fagents-tandem` (no shared deps).

Tandem makes two agents in the **same** project take turns. fagents-tty lets an agent in **one** project talk to an agent in **another** project. **No global state**: everything lives inside `<project>/.fagents-tty/`. Discovery walks the parent directory.

## Setup

```bash
git clone https://github.com/fagents/fagents-tty.git
cd your-project
bash path/to/fagents-tty/setup.sh
```

Project name = directory basename. The basename must match `^[A-Za-z0-9_][A-Za-z0-9_-]*$`; setup refuses invalid dirnames.

Setup writes (all inside the project):

- `<your-project>/.fagents-tty/{bin,.gitignore}` -- the comms toolkit.
- `<your-project>/launch-claude` and `<your-project>/launch-codex` -- launchers that register your TTY in tandem and fagents-tty (if either is installed) before exec'ing the CLI. Existing launchers (e.g. from a prior tandem install) get amended in place by inserting one register line before `exec`. Override the agent list with `--agents <comma-list>`, opt out with `--no-launchers`.
- `<your-project>/.claude/skills/fagents-tty/SKILL.md` and `<your-project>/.codex/skills/fagents-tty/SKILL.md` -- per-project agent skills. Opt out with `--no-skill`.

Setup deliberately does NOT:

- modify `.claude/settings.json` or `.codex/hooks.json`,
- write to `~/.claude/skills/`, `~/.codex/skills/`, or `~/.fagents-tty/` (no global state),
- overwrite the `exec` line or arg-handling of an existing launcher.

If setup finds a stale v1.x `<project>/.fagents-tty/config` or `.fagents-tty/sessions/`, it removes them (v2 doesn't use them). If it finds an orphaned v1.x global `~/.fagents-tty/registry/`, it prints a non-blocking notice -- you can `rm -rf ~/.fagents-tty` once all your fagents-tty projects are migrated.

### Flags

```
bash setup.sh                          # install in current dir; default launchers = claude,codex
bash setup.sh --update                 # refresh bin scripts + launchers + skill (idempotent)
bash setup.sh --agents <comma-list>    # override default launcher list (rejects empty entries)
bash setup.sh --no-launchers           # skip launcher install
bash setup.sh --no-skill               # skip per-project skill install
```

## Discovery

`comms.sh ls` and `comms.sh msg` find target projects by walking the **parent directory** of the current project. Each sibling with `.fagents-tty/agents/` is reachable.

To search elsewhere, set `FAGENTS_TTY_SEARCH_PATH` to a colon-separated list of directories. The override REPLACES the default parent. Each listed dir is walked one level deep.

```bash
FAGENTS_TTY_SEARCH_PATH=~/Workspace:~/Side bash .fagents-tty/bin/comms.sh ls
```

Empty components in `FAGENTS_TTY_SEARCH_PATH` (`:/tmp`, `/tmp:`, `/tmp::/other`) are rejected with exit 1. This is deliberate: ambiguous search scope is a delivery-safety risk.

**Ambiguity is fail-closed at the project level.** If two `FAGENTS_TTY_SEARCH_PATH` roots both contain a project with the same basename, `comms.sh msg <project>:<agent>` exits 9 with `ambiguous-target` and lists all candidate paths on stderr. `comms.sh ls` shows all matches with their parent-dir paths so you can disambiguate visually.

## Launchers

Each `launch-<agent>` does four things:

1. Resolves `ROOT` to the launcher's own directory.
2. If `.tandem/bin/handoff.sh` is executable, calls `handoff.sh register <agent>`.
3. If `.fagents-tty/bin/comms.sh` is executable, calls `comms.sh register <agent>`.
4. `exec <agent> "$@"` so CLI args (e.g. `./launch-claude --resume`) pass through.

If an existing launcher has no `ROOT=` definition or no `exec` line, setup prints a warning with the exact line you need to add and continues without modifying the file. The warning is non-blocking (setup exits 0).

For non-CLI-named agents (e.g. `--agents orchestrator`), the launcher's `exec orchestrator "$@"` line will not work unless `orchestrator` is on `$PATH`. Edit the exec line to point at the actual binary.

## Register

Launchers register automatically. If you start your session via `./launch-claude`, your TTY is already in the project's `agents/` directory. Confirm with:

```bash
bash .fagents-tty/bin/comms.sh status
```

If you bypassed the launcher, register manually:

```bash
bash .fagents-tty/bin/comms.sh register <agent-name>
```

`register` is **self-cleaning**: if your TTY is already recorded under a different agent name in this project, that old entry is removed before the new one is written. End state: at most one `agents/<name>.tty` per TTY per project.

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
bash .fagents-tty/bin/comms.sh ls               # all registered addresses across the search roots
bash .fagents-tty/bin/comms.sh ls --project P   # one project basename
bash .fagents-tty/bin/comms.sh status           # your own registrations + current search roots
```

## Address format

`<project>:<agent>` -- both segments match `^[A-Za-z0-9_][A-Za-z0-9_-]*$`. The project segment is always a directory basename.

## Body rules

- Control bytes (LF, CR, TAB, ESC, BEL, ...) are REPLACED with single spaces.
- Consecutive spaces are collapsed to one.
- Max 800 bytes after normalization. Longer bodies get `...[TRUNCATED]` and `msg` returns exit 4.
- Empty body after sanitization fails with exit 5.

## Exit codes for `msg`

| Code | Meaning |
|------|---------|
| 0 | delivered, body fit |
| 1 | usage / invalid args / invalid address / empty `FAGENTS_TTY_SEARCH_PATH` component |
| 2 | no such project, or project found but agent not registered |
| 3 | wake failure (TTY device path rejected by regex, or sudo/TIOCSTI failed) |
| 4 | delivered, body was truncated |
| 5 | empty body after sanitization |
| 6 | sender not registered from this TTY |
| 7 | project directory name does not match the name regex |
| 9 | ambiguous target (more than one search root contains `<project>`) |

Precedence: pre-wake errors (1, 5, 6, 7) check first. Project lookup outcomes (2, 9) before wake. Wake failure (1/2/3 from wake) overrides truncation. Exit 4 only fires on successful delivery of a truncated body.

## Wake

Uses TIOCSTI to inject keystrokes into the target TTY. Requires NOPASSWD sudo for the python3 ioctl call. Same requirement as `fagents-tandem`.

`bin/wake.sh` validates the target TTY device path with an anchored regex `^/dev/(tty[A-Za-z0-9_-]*|pts/[0-9]+)$`. No path traversal (`/dev/pts/../../etc/passwd`) gets to the `sudo python3 os.open` call.

Exit codes: `0` delivered, `1` usage, `2` path failed regex validation, `3` sudo/TIOCSTI failure.

## Coexistence with tandem

- Different dirs: `.fagents-tty/` vs `.tandem/`. No shared files.
- Different registry models: tandem uses per-project `.tandem/<agent>.tty`; fagents-tty uses `<project>/.fagents-tty/agents/<agent>.tty`.
- Different prefixes: tandem injects `[claude]:` / `[codex]:`; fagents-tty injects `[FAGENTS-TTY from X:Y]:`.
- No hook installation, no global skill install, no global registry. fagents-tty `setup.sh` writes only inside `<project>/.fagents-tty/`, the launchers in `<project>/`, and per-project skills in `<project>/.claude/skills/fagents-tty/` and `<project>/.codex/skills/fagents-tty/`.
- Existing tandem launchers (`./launch-claude` from `fagents-tandem` setup) are amended in place with a single register line; tandem's existing TTY-write logic and `exec ... "$@"` are preserved byte-for-byte.

## Tests

```bash
bash test/test_comms.sh
```

54 test functions, 164 assertions. All TIOCSTI is mocked except test 32 (real `wake.sh` regex on six valid + six invalid TTY paths) and test 33 (python encode loop on split UTF-8). Real-TTY smoke test is manual:

```bash
# Two sibling projects in the same parent dir, each on its own TTY.
cd ~/Workspace/projA && bash .fagents-tty/bin/comms.sh register alice
cd ~/Workspace/projB && bash .fagents-tty/bin/comms.sh register bob
# From projA:
bash .fagents-tty/bin/comms.sh msg projB:bob "smoke test"
# projB's prompt should see the injected envelope.
```

## What it's not

- Not a state machine or protocol (that's `fagents-tandem`).
- Not cross-host -- local TTYs only.
- Not authenticated -- same host, same UID assumed. Sender prefix is self-asserted.
- Not durable -- TIOCSTI fire-and-forget. If you need replay or queuing, an inbox.jsonl is a future v2.x add.
