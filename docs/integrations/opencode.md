# opencode

[opencode](https://github.com/sst/opencode) is an open-source agentic CLI by SST. Spawns shell commands like Claude Code.

## Status

**Doc-only** — no `--integrate=opencode` yet. opencode is pre-1.0 and config schema is still moving. Track upstream: <https://github.com/sst/opencode>.

## Manual

Add to your opencode config (`~/.config/opencode/config.json` or per-repo `.opencode/config.json`):

```json
{
  "instructions": "When asked to send/check/reply messages between AI agents, use ~/.agent-message-cmd. Send: echo BODY | ~/.agent-message-cmd send TO. Inbox: ~/.agent-message-cmd inbox. Reply: echo BODY | ~/.agent-message-cmd reply. Alias = basename of pwd, or first line of .agent-message file."
}
```

Or invoke directly in chat with no setup:

> run `~/.agent-message-cmd inbox`

## Verify

In opencode session:

> check my inbox

Agent runs the wrapper, prints messages.

## Cross-agent test

Open two terminals — one with Claude Code in `~/dev/repo-a`, one with opencode in `~/dev/repo-b`. From Claude:

```
/message-send repo-b hello from claude
```

In opencode:

> check my inbox

Should see the message. Reply via opencode lands back in Claude's inbox. Same `$AGENT_MESSAGE_DIR`, no central registry, both agents speak SAMP.
