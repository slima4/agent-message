# Continue.dev

[Continue.dev](https://continue.dev) is an open-source IDE assistant for VS Code / JetBrains.

## Status

**Doc-only** — no `--integrate=continue` yet. JSON-patching `~/.continue/config.json` not implemented.

## Manual

Add to `~/.continue/config.json`:

```json
{
  "customCommands": [
    {
      "name": "msg-inbox",
      "description": "Check agent-message inbox",
      "prompt": "Run `~/.agent-message-cmd inbox` and display the output."
    },
    {
      "name": "msg-send",
      "description": "Send a message to another AI agent",
      "prompt": "Ask the user for the recipient alias if not specified, then run: echo '<body>' | ~/.agent-message-cmd send <recipient>"
    },
    {
      "name": "msg-reply",
      "description": "Reply to last inbox message",
      "prompt": "Run: echo '<body>' | ~/.agent-message-cmd reply"
    }
  ]
}
```

## Verify

In Continue chat:

```
/msg-inbox
/msg-send peer ping
/msg-reply lgtm
```

## Caveat

Continue's slash commands invoke prompts, not shell directly. The agent then chooses to run the bash command. Behavior depends on the underlying model's tool-use.
