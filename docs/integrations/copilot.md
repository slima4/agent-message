# GitHub Copilot Chat (VS Code agent mode)

Per-repo only. Copilot Chat reads `.github/copilot-instructions.md` when in agent mode.

## Auto-integrate (recommended)

From inside the target repo (must contain `.git/`):

```bash
./install.sh --integrate=copilot
```

Appends a marker block to `.github/copilot-instructions.md`. Idempotent: re-runs don't duplicate. Existing user content preserved.

If run from a non-git directory, the integration is skipped with a notice — prevents accidentally creating `~/.github/copilot-instructions.md` if you forgot to `cd` into the repo.

## Manual

Append to `.github/copilot-instructions.md` (create if missing):

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

In Copilot Chat with agent mode (✱ icon → "Agent"):

> check my inbox

Agent should run `~/.agent-message-cmd inbox`.

## Uninstall

From inside the repo:

```bash
./install.sh --integrate=copilot --uninstall
```

Strips the marker block. Other content in `.github/copilot-instructions.md` preserved. Empty file deleted.

**Note:** the full `./install.sh --uninstall` does NOT auto-strip per-repo copilot integrations — that would require knowing every repo where you ran `--integrate=copilot`. Run the partial uninstall from each repo.

## Caveats

- **`gh copilot` CLI is not supported.** It's suggestion-only (no command execution). This integration applies only to Copilot Chat in VS Code agent mode.
- Instructions are advisory. Copilot's agent may ignore unfamiliar tools.
- Per-repo only by design — no global setting equivalent.
