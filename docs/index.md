# agent-message

**Cheap and fast messaging between AI agents.** No server, no MCP, no token, no daemon.

Reference implementation of [SAMP](spec.md) (Simple Agent Message Protocol). Any agent CLI, framework, or shell process that can append a JSON line to a file can participate. Claude Code is the first client; the protocol is vendor-neutral.

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
    [04-25 17:42] from=repo_a thread=2026-04-25-repo_a-ping: ping
    1 new from: repo_a

    msg reply "pong"
    ```

See [Install](install.md) for full setup, [Use](use.md) for all three paths, [Design](design.md) for the git-inspired internals, [SAMP Spec](spec.md) for the wire-format contract, [Limits](limits.md) for caveats.

## Why not the alternatives

Existing solutions ([mcp_agent_mail](https://github.com/Dicklesworthstone/mcp_agent_mail), Agent Teams, broker daemons) run an HTTP server, maintain SQLite, register agent identities, require tokens, burn tokens on polling hooks. agent-message gives you the 90 % at 1 % of the cost: a shared directory of append-only JSONL files, basename-as-identity, no setup per repo. Any agent that can spawn a subprocess or write a file can participate.
