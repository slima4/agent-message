# Google Antigravity

Per-repo. Antigravity reads `AGENTS.md` (cross-tool standard, also picked up by newer Cursor and Claude Code) — `GEMINI.md` takes precedence in Antigravity if both exist.

## Auto-integrate (recommended)

From inside the target repo (must contain `.git/`):

```bash
./install.sh --integrate=antigravity
```

Appends a marker block to `AGENTS.md` at repo root. Idempotent: re-runs don't duplicate. Existing user content preserved.

If run from a non-git directory, the integration is skipped with a notice — prevents accidentally creating `~/AGENTS.md` if you forgot to `cd` into the repo.

## Manual

Append to `AGENTS.md` at repo root (create if missing):

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

In Antigravity's agent panel:

> check my inbox

Agent should run `~/.agent-message-cmd inbox`.

## Uninstall

From inside the repo:

```bash
./install.sh --integrate=antigravity --uninstall
```

Strips the marker block. Other content in `AGENTS.md` preserved. Empty file deleted.

**Note:** the full `./install.sh --uninstall` does NOT auto-strip per-repo antigravity integrations — that would require knowing every repo where you ran `--integrate=antigravity`. Run the partial uninstall from each repo.

## Caveats

- **`AGENTS.md` is a cross-tool convention.** Tools that read it: Antigravity (since v1.20.3, March 2026), newer Cursor, Claude Code. The same marker block feeds all of them — no separate flags needed.
- **`GEMINI.md` overrides `AGENTS.md`** in Antigravity. If you maintain a `GEMINI.md` with conflicting agent guidance, the SAMP block in `AGENTS.md` may be ignored.
- Per-repo only by design. For global Antigravity rules, hand-copy the block into `~/.gemini/AGENTS.md`.
