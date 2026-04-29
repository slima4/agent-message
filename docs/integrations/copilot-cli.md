# GitHub Copilot CLI

Distinct from [Copilot Chat in VS Code](copilot.md). The CLI is a standalone command-line agent (`copilot` binary) that reads instructions from a personal global path and from `AGENTS.md` files in cwd.

## Auto-integrate (recommended)

```bash
./install.sh --integrate=copilot-cli
```

Appends a marker block to `~/.copilot/copilot-instructions.md` (the personal/global path Copilot CLI reads regardless of cwd). **One install, every repo covered.** Idempotent: re-runs don't duplicate. Existing user content preserved.

## Manual

Append to `~/.copilot/copilot-instructions.md` (create if missing):

```markdown
<!-- >>> agent-message >>> -->
## Agent messaging (SAMP v1)

To send/check/reply to messages from other AI agents, use the `~/.agent-message-cmd` wrapper:

- Send: `echo '<body>' | ~/.agent-message-cmd send <recipient-alias>`
- Check inbox: `~/.agent-message-cmd inbox`
- Reply to last: `echo '<body>' | ~/.agent-message-cmd reply`

Sender alias = `basename $(pwd)`, override via `.agent-message` file's first line.
Spec: https://github.com/slima4/agent-message/blob/main/SPEC.md
<!-- <<< agent-message <<< -->
```

## Verify

In a Copilot CLI session:

> check my inbox

Agent should run `~/.agent-message-cmd inbox`.

## Uninstall

```bash
./install.sh --integrate=copilot-cli --uninstall
```

Strips the marker block. Other content preserved. Empty file deleted.

The full `./install.sh --uninstall` also strips this automatically (it's a global path).

## Caveats

- **Copilot CLI ≠ Copilot Chat.** The Chat extension in VS Code reads `.github/copilot-instructions.md` per-repo (see [`--integrate=copilot`](copilot.md)). The CLI reads `~/.copilot/copilot-instructions.md` globally and `AGENTS.md` from cwd. If you use both, install both flags — they don't overlap.
- **`AGENTS.md` is also read by Copilot CLI.** If you've already run `--integrate=antigravity`, Copilot CLI picks up the same instructions from `~/.gemini/AGENTS.md` *if* you set `COPILOT_CUSTOM_INSTRUCTIONS_DIRS=$HOME/.gemini`. Without that env var, the CLI only reads its own `~/.copilot/copilot-instructions.md` globally.
- **Personal instructions take precedence over repository instructions** in Copilot CLI's priority order, so the global path is the right home for cross-repo rules.

## References

- [Adding custom instructions for GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions) — file paths, priority, and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` semantics.
- [GitHub Copilot CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
