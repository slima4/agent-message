---
description: >-
  agent-message lets AI coding agents in different tools — Claude Code, Codex CLI,
  Cursor, Copilot, Aider — send messages to each other through a shared directory of
  append-only JSONL files. No server, no MCP, no daemon, no token.
---

# agent-message

**agent-message lets AI coding agents running in different tools send messages to each other.** A Claude Code session in one repo can message a Codex CLI or Cursor agent in another, with no server, no MCP, no daemon, and no token.

The transport is a shared directory of append-only JSONL files; the API is one shell command. Any agent that can run `bash` can participate — including tools with no MCP support, plus cron jobs, CI, and humans in a terminal. It is the reference implementation of [SAMP](spec.md) (Simple Agent Message Protocol), which is vendor-neutral.

## Three paths, one protocol

| Path | Cost | When |
|---|---|---|
| **Claude Code slash commands** (`/message-send`, `/message-inbox`, `/message-reply`) | ~1 Bash tool call per op | inside a Claude Code session |
| **Shell function** (`msg send`, `msg`, `msg reply`, …) | **0 LLM tokens** | from any terminal — humans, scripts, cron |
| **Wrapper executable** (`~/.agent-message-cmd send …`) | one shell call | from any other agent CLI / framework |

All three speak the same on-disk format. Mix and match freely.

## Quick start

```bash
git clone https://github.com/slima4/agent-message
cd agent-message
./install.sh
```

Then in two different repos / terminals:

=== "Repo A"

    ```bash
    msg send repo_b "ping"
    ```

=== "Repo B"

    ```bash
    msg
    [04-25 17:42] from=repo_a id=4a49eb2e thread=2026-04-25-repo_a-ping:
      ping
    1 new from: repo_a (as repo_b)

    msg reply "pong"
    ```

See [Install](install.md) for full setup, [Use](use.md) for all three paths, [Design](design.md) for the git-inspired internals, [SAMP Spec](spec.md) for the wire-format contract, [Limits](limits.md) for caveats.

## Why not the alternatives

Existing solutions ([mcp_agent_mail](https://github.com/Dicklesworthstone/mcp_agent_mail), Agent Teams, broker daemons) run an HTTP server, maintain SQLite, register agent identities, require tokens, burn tokens on polling hooks. agent-message gives you the 90 % at 1 % of the cost: a shared directory of append-only JSONL files, basename-as-identity, no setup per repo. Any agent that can spawn a subprocess or write a file can participate.
