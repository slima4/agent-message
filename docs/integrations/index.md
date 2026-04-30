# Integrations

agent-message works with any AI agent that can run a shell command. Three calls cover the protocol:

```bash
echo "body" | ~/.agent-message-cmd send <recipient>
~/.agent-message-cmd inbox
echo "reply" | ~/.agent-message-cmd reply
```

### Global integrations

One install covers every repo on the machine.

| Tool | Flag | Writes |
|---|---|---|
| [Claude Code](../install.md) | (default) | `~/.claude/commands/message-{send,inbox,reply}.md` |
| [Cursor](cursor.md) | `--integrate=cursor` | `~/.cursor/rules/agent-message.mdc` |
| [GitHub Copilot CLI](copilot-cli.md) | `--integrate=copilot-cli` | `~/.copilot/copilot-instructions.md` |
| [Google Antigravity](antigravity.md) | `--integrate=antigravity` | `~/.gemini/AGENTS.md` |
| [OpenAI Codex CLI](codex.md) | `--integrate=codex` | `~/.codex/AGENTS.md` |

### Per-repo integrations

Run from inside each repo where you want them.

| Tool | Flag | Writes |
|---|---|---|
| [GitHub Copilot Chat](copilot.md) | `--integrate=copilot` | `.github/copilot-instructions.md` |
| [Antigravity (per-repo)](antigravity.md) | `--integrate=antigravity-repo` | `./AGENTS.md` (cross-tool, opt-in) |
| [Zed](zed.md) | `--integrate=zed` | `./.rules` |

### Doc-only

Configure by hand — these tools have no marker-block target we'd own.

| Tool | Why |
|---|---|
| [opencode](opencode.md) | pre-1.0 config in flux |
| [Continue.dev](continue.md) | JSON config patch by hand |
| [Aider](aider.md) | use `/run` |

## Auto-integrate everything

```bash
./install.sh --integrate=all       # cursor + copilot + copilot-cli + antigravity + codex + zed
./install.sh --integrate=auto      # detect and integrate available tools
./install.sh --integrate=cursor,antigravity   # explicit list
```

`--integrate=all` does NOT include `antigravity-repo` (opt-in only — global covers it).

Uninstall:

```bash
./install.sh --integrate=cursor --uninstall            # global
./install.sh --integrate=antigravity --uninstall       # global
./install.sh --integrate=zed --uninstall               # per-repo (run from inside the repo)
```

## Cross-agent interop

All integrations point at the same `$AGENT_MESSAGE_DIR`. A Claude session in `~/dev/repo-a` and a Cursor session in `~/dev/repo-b` exchange messages through the shared store — no central server, no MCP, no auth. Each agent picks its alias from `.agent-message` file or `basename $(pwd)`.
