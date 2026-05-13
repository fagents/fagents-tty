# fagents-tty -- Cross-Project Agent Messaging

You can talk to agents in OTHER project directories via TIOCSTI. The transport is `.fagents-tty/`, separate from `.tandem/`.

## When you see an inbound message

A wake injects this into your prompt:

```
[FAGENTS-TTY from <project>:<agent>]: <body>. Reply: bash .fagents-tty/bin/comms.sh msg <project>:<agent> "..."
```

The sender's address is in the prefix. The exact reply command is at the end. To respond, run the reply command verbatim with your message body in place of `...`.

**Never** reply via `.tandem/bin/handoff.sh msg` -- that is a different transport for in-project tandem coordination, and it routes to a different TTY.

## To register yourself

Once per session, after starting your agent:

```bash
bash .fagents-tty/bin/comms.sh register <your-agent-name>
```

This writes your TTY to the global registry as `<this-project>:<your-agent-name>` and is what makes you reachable from other projects.

## To send a message

```bash
bash .fagents-tty/bin/comms.sh msg <project>:<agent> "<body>"
```

Notes on body:
- Control bytes (LF, CR, TAB, ESC, etc.) are replaced with single spaces; consecutive spaces are collapsed.
- Max 800 bytes after normalization; longer messages are truncated with `...[TRUNCATED]` and the command exits 4.
- An empty body after sanitization fails with exit 5.

## Discovery

```bash
bash .fagents-tty/bin/comms.sh ls               # list everyone
bash .fagents-tty/bin/comms.sh ls --project P   # filter to one project
bash .fagents-tty/bin/comms.sh status           # show your registrations
```

## Exit codes for `msg`

- `0` delivered
- `1` usage / invalid args / invalid address
- `2` no such address (target unregistered)
- `3` sudo/TIOCSTI failure
- `4` delivered but body was truncated (sender can chunk)
- `5` empty body after sanitization
- `6` you are not registered in this project from this TTY (run `register` first)
- `7` project config missing or invalid
- `8` (unregister only) the registry slot belongs to a different project directory

`4` only fires on successful delivery. `3` overrides `4` -- truncation never masks delivery failure.

## Coexistence with tandem

- `.fagents-tty/` and `.tandem/` are independent. Same TTY can be registered in both.
- `.tandem/` is for in-project coordination (claude <-> codex within ONE project).
- `.fagents-tty/` is for cross-project coordination (orchestrator agent in project A calling into agents in project B).
- The prefixes differ on purpose: tandem injects `[claude]:` / `[codex]:`; fagents-tty injects `[FAGENTS-TTY from X:Y]:`. If you see `FAGENTS-TTY`, use the `.fagents-tty` reply path; if you see a bare `[name]:` prefix, use whatever the local convention is (tandem `handoff.sh msg`).
