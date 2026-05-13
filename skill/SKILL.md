---
name: fagents-tty
description: "Cross-project agent messaging via TIOCSTI. Use when the user asks to msg an agent in another project, when you see an [FAGENTS-TTY from X:Y]: envelope in your prompt, or when listing/discovering agents across projects."
allowed-tools: Bash(bash .fagents-tty/bin/*)
---
# fagents-tty -- Cross-Project Agent Messaging

**This skill applies only when the current project contains a `.fagents-tty/` directory.**
If `.fagents-tty/` does not exist, ignore these instructions.

You can talk to agents in OTHER project directories on this machine via TIOCSTI. The transport is `.fagents-tty/`, separate from `.tandem/`.

## Registration is automatic

If the user started your session via `./launch-<your-name>` (e.g. `./launch-claude`), your TTY is already registered in this project. You do NOT need to run `comms.sh register` manually. To confirm:

```bash
bash .fagents-tty/bin/comms.sh status
```

If you see "ERROR: not-registered-from-this-tty" later, register once:

```bash
bash .fagents-tty/bin/comms.sh register <your-agent-name>
```

## Receiving a cross-project message

A wake injects this into your prompt:

```
[FAGENTS-TTY from <project>:<agent>]: <body>. Reply: bash .fagents-tty/bin/comms.sh msg <project>:<agent> "..."
```

Read the body, do whatever it asks, then **reply by running the literal command at the end** with your response in place of `...`. The reply path is part of the message, so you do not have to look it up.

**Never** reply via `.tandem/bin/handoff.sh msg` -- that is a different transport for in-project tandem coordination and would route to the wrong TTY.

## Sending a message (when the user asks)

When the user says something like "msg the engine team", "send X to the orchestrator", or "ask the foo project about Y", translate it to a `comms.sh msg` call:

```bash
# 1. If you don't know the exact address, discover first:
bash .fagents-tty/bin/comms.sh ls

# 2. Pick the target from the listing (format: <project>:<agent> <tty>):
bash .fagents-tty/bin/comms.sh msg <project>:<agent> "<your message>"
```

If the user gives a relative reference like "../autoalpha-engine", the project name is the directory basename (`autoalpha-engine`). Combine with the agent name from `comms.sh ls`.

### Body rules

- Control bytes (LF, CR, TAB, ESC, BEL, ...) are replaced with single spaces; consecutive spaces collapsed; leading/trailing whitespace trimmed.
- Max 800 bytes after normalization. Longer bodies are truncated with `...[TRUNCATED]` and the command exits 4. Chunk and send multiple msgs if you need more.
- Empty body after sanitization fails with exit 5.

## Exit codes for `msg`

- `0` delivered
- `1` usage / invalid args / invalid address
- `2` no such address (target unregistered)
- `3` sudo/TIOCSTI failure
- `4` delivered but body was truncated
- `5` empty body after sanitization
- `6` you are not registered in this project from this TTY (run `register`)
- `7` project config missing or invalid
- `8` (unregister only) registry slot belongs to a different project directory

`4` only fires on successful delivery. `3` overrides `4` -- truncation never masks delivery failure.

## Coexistence with tandem

- `.fagents-tty/` and `.tandem/` are independent. Same TTY can be registered in both.
- `.tandem/` is for in-project coordination (claude <-> codex within ONE project).
- `.fagents-tty/` is for cross-project coordination (e.g. orchestrator in project A calling into agents in project B).
- Prefixes differ on purpose: tandem injects `[claude]:` / `[codex]:`; fagents-tty injects `[FAGENTS-TTY from X:Y]:`. If you see `FAGENTS-TTY`, use the `.fagents-tty/bin/comms.sh msg` reply path; if you see a bare `[name]:` prefix, that is a tandem in-project message.
