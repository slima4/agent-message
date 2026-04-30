# Zed

Per-repo. Zed's agent panel reads `.rules` at repo root (priority), with fallback to `.cursorrules`, `.windsurfrules`, `CLAUDE.md`, `AGENTS.md`.

## Auto-integrate (recommended)

From inside the target folder:

```bash
./install.sh --integrate=zed
```

Appends a marker block to `.rules` at the cwd. Idempotent: re-runs don't duplicate. Existing user content preserved. Works in any folder (refuses only `/` and `$HOME` to prevent accidents).

## Manual

Append to `.rules` at repo root (create if missing):

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

Open Zed's Agent Panel and ask:

> check my inbox

Agent should run `~/.agent-message-cmd inbox`.

## Uninstall

From inside the folder:

```bash
./install.sh --integrate=zed --uninstall
```

Strips the marker block. Other content in `.rules` preserved. Empty file deleted.

**Note:** the full `./install.sh --uninstall` does NOT auto-strip per-repo Zed integrations — that would require knowing every folder where you ran `--integrate=zed`. Run the partial uninstall from each one.

## Caveats

- **`.rules` is Zed's primary**, but Zed falls back to `.cursorrules`, `.windsurfrules`, `CLAUDE.md`, `AGENTS.md` if `.rules` is absent. If you'd rather feed Zed via the `AGENTS.md` cross-tool standard, use `--integrate=antigravity-repo` instead and skip `--integrate=zed`.
- Zed currently does not let you replace the system prompt — only append. The marker block is appended as user-rules context, which is enough for the agent to call `~/.agent-message-cmd` on request.
- **Per-repo only.** Zed's global Rules Library lives in an LMDB database (`~/.config/zed/prompts/prompts-library-db.0.mdb`) — a binary store edited via the Rules Library UI. Not safely scriptable. Either run `--integrate=zed` per-repo, or paste the marker block into a rule via the UI once and set it as default.
