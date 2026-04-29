# Integrations

agent-message works with any AI agent that can run a shell command. Three calls cover the protocol:

```bash
echo "body" | ~/.agent-message-cmd send <recipient>
~/.agent-message-cmd inbox
echo "reply" | ~/.agent-message-cmd reply
```

Per-tool guides — auto-wire where possible, copy-paste otherwise:

| Tool | Auto | Status |
|---|---|---|
| [Claude Code](../install.md) | ✓ | shipped — `./install.sh` installs three slash commands |
| [Cursor](cursor.md) | ✓ | `--integrate=cursor` writes `~/.cursor/rules/agent-message.mdc` |
| [GitHub Copilot Chat](copilot.md) | ✓ | `--integrate=copilot` appends to `.github/copilot-instructions.md` |
| [opencode](opencode.md) | — | doc-only; pre-1.0 config in flux |
| [Continue.dev](continue.md) | — | doc-only; JSON config patch by hand |
| [Aider](aider.md) | — | doc-only; use `/run` |

## Auto-integrate everything

```bash
./install.sh --integrate=all       # cursor + copilot
./install.sh --integrate=auto      # detect and integrate available tools
./install.sh --integrate=cursor,copilot   # explicit list
```

Uninstall:

```bash
./install.sh --integrate=cursor --uninstall
```

## Cross-agent interop

All integrations point at the same `$AGENT_MESSAGE_DIR`. A Claude session in `~/dev/repo-a` and a Cursor session in `~/dev/repo-b` exchange messages through the shared store — no central server, no MCP, no auth. Each agent picks its alias from `.agent-message` file or `basename $(pwd)`.
