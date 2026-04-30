# OpenAI Codex CLI

[Codex CLI](https://developers.openai.com/codex/cli) reads `AGENTS.md` from two paths: `~/.codex/AGENTS.md` (global, applies to every session) and `AGENTS.md` walked from the project root down to the cwd. The same marker block feeds both.

## Auto-integrate (recommended) — global

```bash
./install.sh --integrate=codex
```

Appends a marker block to `~/.codex/AGENTS.md`. **One install, every repo covered.** Idempotent: re-runs don't duplicate. Existing user content preserved.

## Per-repo opt-in

Codex respects the cross-tool `AGENTS.md` standard, so the existing per-repo flag works:

```bash
./install.sh --integrate=antigravity-repo
```

Appends to `./AGENTS.md` at the cwd. Same marker pattern. Refuses only `/` and `$HOME`. (Flag is named after Antigravity for historical reasons; `AGENTS.md` is the shared standard — Codex, Antigravity, Cursor, and newer Claude Code all read it.)

## Manual

Append to `~/.codex/AGENTS.md` (create if missing):

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

In a Codex CLI session:

> check my inbox

Agent should run `~/.agent-message-cmd inbox`.

## Uninstall

```bash
./install.sh --integrate=codex --uninstall
```

Strips the marker block. Other content preserved. Empty file deleted.

The full `./install.sh --uninstall` strips `~/.codex/AGENTS.md` automatically (it's a global integration).

## Caveats

- **`AGENTS.override.md` wins** if you keep one in `~/.codex/`. Codex reads it instead of `AGENTS.md`. Either delete the override or paste the marker block into it.
- **`AGENTS.md` is cross-tool.** If you already ran `--integrate=antigravity-repo` in a repo, Codex picks up `./AGENTS.md` automatically — no extra flag.
- **Codex Cloud / ChatGPT desktop / Operator** are out of scope: cloud sandboxes have no access to your local message dir, and the desktop ChatGPT app can't spawn arbitrary shell commands.
