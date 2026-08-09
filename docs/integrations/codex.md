# OpenAI Codex CLI

[Codex CLI](https://developers.openai.com/codex/cli) reads `AGENTS.md` from two paths: `~/.codex/AGENTS.md` (global, applies to every session) and `AGENTS.md` walked from the project root down to the cwd. The same marker block feeds both.

## Auto-integrate (recommended) — global

```bash
./install.sh --integrate=codex
```

Writes two things:

1. A marker block in `~/.codex/AGENTS.md` — teaches Codex the three wrapper commands. **One install, every repo covered.**
2. A marker block in `~/.codex/config.toml` — adds the message dir to the sandbox's writable roots.

Both are idempotent; re-runs don't duplicate, existing user content is preserved, and `--uninstall --integrate=codex` strips both.

### Why the config.toml part is needed

Codex defaults to the `workspace-write` sandbox: it may read anywhere but write only inside the working directory. The message store lives at `${XDG_STATE_HOME:-~/.local/state}/agent-message/`, outside any repo — so reading the inbox succeeds while saving the read marker fails, and **the same messages resurface on every check**. The installer adds:

```toml
[sandbox_workspace_write]
writable_roots = ["/Users/<you>/.local/state/agent-message"]
```

Per-launch equivalent, if you'd rather not persist it: `codex --add-dir ~/.local/state/agent-message`.

If your `config.toml` already declares `[sandbox_workspace_write]`, the installer **will not touch it** — a second table of the same name is a TOML duplicate-table error that breaks Codex. It prints the path to add to your existing `writable_roots` instead.

Reading never depends on this. With no writable root, the wrapper prints the messages, warns once on stderr, and exits 0 — only the read marker is lost.

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
