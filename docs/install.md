# Install

```bash
git clone https://github.com/slima4/agent-message
cd agent-message
./install.sh
```

Idempotent — safe to re-run. Open a new terminal after first install so the shell function loads.

## What gets installed

| Path | Purpose |
|---|---|
| `~/.claude/commands/message-{send,inbox,reply}.md` | Claude Code slash-command prompts |
| `~/.agent-message-cmd` | Python wrapper — single entry point used by the slash commands and any other agent |
| `~/.agent-message.sh` | `msg` shell function, sourced from `~/.zshrc` and `~/.bashrc` via an idempotent `# >>> agent-message >>>` block |
| `~/dev/.message/` | Default shared message directory (`AGENT_MESSAGE_DIR` overrides) |

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--dir <path>` | `~/dev/.message` | Override message dir |
| `--commands <path>` | `~/.claude/commands` | Override Claude commands dir |
| `--shell <path>` | `~/.agent-message.sh` | Override shell helper install path |
| `--bin <path>` | `~/.agent-message-cmd` | Override wrapper install path |
| `--no-shell` | install shell | Skip shell helper |
| `--uninstall` | install | Remove everything |

## Requirements

- `python3` — preinstalled on macOS, every Linux distro. The installer pre-flights and refuses if missing.
- A POSIX shell (`bash` or `zsh`).
- That's it. No pip, no npm, no Docker.

## Permission tip (Claude Code)

Claude Code's safety detector flags Python f-strings inside heredocs as "expansion obfuscation" and prompts for approval on every send. To skip the prompt without granting blanket `python3` access, allowlist only the wrapper:

```json
{ "permissions": { "allow": ["Bash(/Users/<you>/.agent-message-cmd:*)"] } }
```

Add it to `~/.claude/settings.json`. The rule allows ONLY the wrapper, nothing else.

## Uninstall

```bash
./install.sh --uninstall
```

Removes the slash commands, the wrapper, the shell helper, the per-agent logs + caches in the message dir, and the rc-block from `~/.zshrc` / `~/.bashrc`. Does not touch `.agent-message` files in your repos.
