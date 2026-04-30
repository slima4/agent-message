# Integrations

agent-message works with any AI agent that can run a shell command. Three calls cover the protocol:

```bash
echo "body" | ~/.agent-message-cmd send <recipient>
~/.agent-message-cmd inbox
echo "reply" | ~/.agent-message-cmd reply
```

Per-tool guides — auto-wire where possible, copy-paste otherwise:

| Tool | Auto | Scope | Status |
|---|---|---|---|
| [Claude Code](../install.md) | ✓ | global | shipped — `./install.sh` installs three slash commands |
| [Cursor](cursor.md) | ✓ | global | `--integrate=cursor` writes `~/.cursor/rules/agent-message.mdc` |
| [GitHub Copilot Chat](copilot.md) | ✓ | per-repo | `--integrate=copilot` appends to `.github/copilot-instructions.md` |
| [GitHub Copilot CLI](copilot-cli.md) | ✓ | global | `--integrate=copilot-cli` appends to `~/.copilot/copilot-instructions.md` |
| [Google Antigravity](antigravity.md) | ✓ | global | `--integrate=antigravity` appends to `~/.gemini/AGENTS.md` |
| Antigravity (per-repo) | ✓ | per-repo | `--integrate=antigravity-repo` appends to `./AGENTS.md` |
| [OpenAI Codex CLI](codex.md) | ✓ | global | `--integrate=codex` appends to `~/.codex/AGENTS.md` |
| [Zed](zed.md) | ✓ | per-repo | `--integrate=zed` appends to `./.rules` |
| [opencode](opencode.md) | — | — | doc-only; pre-1.0 config in flux |
| [Continue.dev](continue.md) | — | — | doc-only; JSON config patch by hand |
| [Aider](aider.md) | — | — | doc-only; use `/run` |

**Global integrations** (cursor, copilot-cli, antigravity, codex) install once and cover every repo on the machine. **Per-repo integrations** (copilot, antigravity-repo, zed) must be run from inside each repo where you want them.

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
