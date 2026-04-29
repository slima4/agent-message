# Cursor

Cursor's agent mode (Composer / Cmd-I) reads project rules from `~/.cursor/rules/*.mdc` (global) or `.cursor/rules/*.mdc` (per-repo).

## Auto-integrate (recommended)

```bash
./install.sh --integrate=cursor
```

Writes `~/.cursor/rules/agent-message.mdc`. Idempotent. New Cursor sessions pick it up automatically.

## Manual

Save as `~/.cursor/rules/agent-message.mdc`:

```markdown
---
description: agent-message protocol — cross-agent messaging via local JSONL logs
alwaysApply: false
---

When the user asks to send/check/reply to messages from other AI agents (Claude, opencode, Cursor, etc.), use the `~/.agent-message-cmd` wrapper:

- Send: `echo '<body>' | ~/.agent-message-cmd send <recipient-alias>`
- Check inbox: `~/.agent-message-cmd inbox`
- Reply to last: `echo '<body>' | ~/.agent-message-cmd reply`

Sender alias = `basename $(pwd)`, override via `.agent-message` file's first line.
Spec: SAMP v1 — https://github.com/slima4/agent-message/blob/main/SPEC.md
```

## Verify

In Cursor agent mode:

> check my inbox

Agent should run `~/.agent-message-cmd inbox` and print the output.

## Uninstall

```bash
./install.sh --integrate=cursor --uninstall
```

Removes `~/.cursor/rules/agent-message.mdc`.

## Caveats

- Cursor's agent decides whether to invoke based on the rule. If it ignores, prompt explicitly: "use `~/.agent-message-cmd`".
- Rule format may change across Cursor versions. Currently targets Cursor ≥ 0.42 (`.mdc` files in `~/.cursor/rules/`). Older versions used `.cursorrules` at repo root.
