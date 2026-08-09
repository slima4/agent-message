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
| `${XDG_STATE_HOME:-~/.local/state}/agent-message/` | Default shared message directory (`AGENT_MESSAGE_DIR` overrides) |

## Flags

| Flag | Default | Effect |
|---|---|---|
| `--dir <path>` | `${XDG_STATE_HOME:-~/.local/state}/agent-message` | Override message dir |
| `--commands <path>` | `~/.claude/commands` | Override Claude commands dir |
| `--shell <path>` | `~/.agent-message.sh` | Override shell helper install path |
| `--bin <path>` | `~/.agent-message-cmd` | Override wrapper install path |
| `--no-shell` | install shell | Skip shell helper |
| `--uninstall` | install | Remove everything |

## Integrations

Wire up other agent tools with one flag. Global integrations install once and cover every repo; per-repo integrations target the current directory.

| Flag | Scope | Writes |
|---|---|---|
| `--integrate=cursor` | global | `~/.cursor/rules/agent-message.mdc` |
| `--integrate=copilot-cli` | global | `~/.copilot/copilot-instructions.md` |
| `--integrate=antigravity` | global | `~/.gemini/AGENTS.md` (Antigravity + Gemini CLI) |
| `--integrate=codex` | global | `~/.codex/AGENTS.md` + sandbox writable root in `~/.codex/config.toml` |
| `--integrate=copilot` | per-repo | `.github/copilot-instructions.md` (Copilot Chat) |
| `--integrate=antigravity-repo` | per-repo | `./AGENTS.md` (cross-tool, opt-in) |
| `--integrate=zed` | per-repo | `./.rules` |
| `--integrate=all` | mixed | every flag above except `antigravity-repo` |
| `--integrate=auto` | mixed | detect installed tools and integrate them |
| `--integrate=select` | mixed | interactive menu of every tool with its state |

`auto` only runs the global integrations — a global signal ("you have Zed installed") says nothing about whether the current directory is the repo where per-repo rules belong. Per-tool guides: [`integrations/`](integrations/index.md).

Every `./install.sh` reports integration state, so nothing installs silently half-connected. Wired tools appear as an `agents:` row inside the main block; anything detected but unwired gets its own paragraph with the command to run:

```
  commands: ~/.claude/commands/{message-send,message-inbox,message-reply}.md
  wrapper:  ~/.agent-message-cmd
  dir:      ~/.local/state/agent-message  (per-agent logs: log-<alias>.jsonl)
  agents:   antigravity, codex

Not wired yet (detected on this machine):
  cursor       → ./install.sh --integrate=cursor

  all at once: ./install.sh --integrate=auto
  or pick from a menu: ./install.sh --integrate=select
```

`--integrate=select` opens a menu instead. It is the only mode that offers the per-repo writers, because you can see which directory they would write to before confirming:

```
agent-message integrations   (cwd: /Users/you/dev/my-web)

  [1] cursor            global       detected
  [2] copilot-cli       global       not found
  [3] antigravity       global       WIRED
  [4] codex             global       detected
  [5] copilot           ./my-web     detected
  [6] antigravity-repo  ./my-web     detected
  [7] zed               ./my-web     not found

Numbers to pick (space-separated), a=all detected global, Enter=none, q=quit
> 4 5
```

`a` picks the detected global tools only — same set as `auto`. Per-repo writers need an explicit number. The menu needs a terminal; piped into `curl … | bash` it prints a notice and falls back to `auto`. It also works with `--uninstall`, where wired tools are marked `WIRED`.

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

## Verifying / contributing

If you cloned the repo to hack on it:

```bash
./test.sh        # 51 tests, pure bash + python3, no other deps
```

CI runs the same suite on Ubuntu and macOS plus `shellcheck` on every push and PR. See [CONTRIBUTING.md](https://github.com/slima4/agent-message/blob/main/CONTRIBUTING.md) for line budgets, the single-writer invariant, and the smaller/cheaper/faster rule.

## Uninstall

```bash
./install.sh --uninstall
```

Removes the slash commands, the wrapper, the shell helper, the per-agent logs + caches in the message dir, and the rc-block from `~/.zshrc` / `~/.bashrc`. Does not touch `.agent-message` files in your repos.
