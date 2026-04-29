# Google Antigravity

Antigravity reads `AGENTS.md` from two paths: `~/.gemini/AGENTS.md` (global, also read by Gemini CLI) and `./AGENTS.md` at the repo root (cross-tool — newer Cursor and Claude Code read it too). `GEMINI.md` takes precedence in Antigravity if both exist.

## Auto-integrate (recommended) — global

```bash
./install.sh --integrate=antigravity
```

Appends a marker block to `~/.gemini/AGENTS.md`. **One install, every repo covered.** Idempotent: re-runs don't duplicate. Existing user content preserved.

## Per-repo opt-in

If you'd rather scope the instructions to a single repo (e.g., for shared/team rules versioned with the project):

```bash
./install.sh --integrate=antigravity-repo
```

Appends to `./AGENTS.md` at the cwd repo root. Same marker pattern. Requires cwd to be a real git repo.

## Manual

Append to `~/.gemini/AGENTS.md` (global) or `./AGENTS.md` (per-repo) — create if missing:

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

```bash
./install.sh --integrate=antigravity --uninstall          # strips ~/.gemini/AGENTS.md
./install.sh --integrate=antigravity-repo --uninstall     # strips ./AGENTS.md (run from inside the repo)
```

Strips the marker block. Other content preserved. Empty file deleted.

**Note:** the full `./install.sh --uninstall` strips the global `~/.gemini/AGENTS.md` block automatically. Per-repo `antigravity-repo` integrations require running `--uninstall --integrate=antigravity-repo` from each repo.

## Caveats

- **`AGENTS.md` is a cross-tool convention.** Tools that read it: Antigravity (since v1.20.3, March 2026), newer Cursor, Claude Code. The same marker block feeds all of them — no separate flags needed.
- **`GEMINI.md` overrides `AGENTS.md`** in Antigravity. If you maintain a `GEMINI.md` with conflicting agent guidance, the SAMP block in `AGENTS.md` may be ignored.
- **Global vs per-repo precedence.** Antigravity reads both — global covers all repos by default, per-repo can override or extend. Pick one or run both.
