# Contributing to agent-message

Thanks for thinking about it. Reading the rules below first will save us both time.

## North star: smaller, cheaper, faster

Every change must serve at least one of three axes — or deliberately trade one for another with the trade named in the PR description.

- **Smaller** — line count is a first-class metric.
  - `commands/*.md` carry a per-invocation Claude input-token cost. Per-file budgets: `message-send` ≤ 40 lines, `message-reply` ≤ 40, `message-inbox` ≤ 60.
  - `bin/agent-message-cmd` and `shell/msg.sh` run locally — no token cost, but brevity is still the default.
  - `README.md` ≤ 200 lines. If you grow it past, delete something else.
- **Cheaper** — two invariants:
  1. The Claude / agent path stays at **1 shell call per operation**. No MCP, no hook, no tool-call chain.
  2. The shell path stays at **0 LLM tokens**. The `msg` function never touches a model.
- **Faster** — `mtime` short-circuit before parse; stat/glob before disk reads. `python3` startup (~30 ms) is the floor; don't add cycles on top.

Features that don't serve any of the three axes are out of scope. Point those at [`mcp_agent_mail`](https://github.com/Dicklesworthstone/mcp_agent_mail) or open a Discussion.

## Hard rules

- **No new runtime deps beyond `python3`.** No pip, no npm, no Docker.
- **No MCP, no daemon, no broker, no network transport.** The protocol is file-based by design.
- **Single-writer-per-file.** A writer with alias `<frm>` only ever writes to `log-<frm>.jsonl`. Readers union across all logs and dedup by id.
- **Wrapper and shell paths share the on-disk contract.** Any change to the JSONL schema, thread-slug rules, id computation, watermark semantics, or dedup rules must land in `bin/agent-message-cmd` AND `shell/msg.sh` in the same PR. They are the same protocol, two implementations.
- **Re-run `./install.sh` after editing `commands/*.md`, `shell/msg.sh`, or `bin/agent-message-cmd`.** The installer copies (does not symlink). Working-tree edits do not take effect until re-install.
- **No backwards-compat shims.** Project has no shipped users. Rename freely.

## How to contribute

1. **Open an issue first** for non-trivial work — bug, feature, or question. Saves a wasted PR if the idea is out of scope.
2. **Fork + branch.** Branch name: `feat/<short>`, `fix/<short>`, `docs/<short>`, `ci/<short>`.
3. **Code.**
4. **Test.** See `## Testing` below.
5. **Open a PR.** The template will ask which axis your change serves and whether you ran the round-trips.

## Testing

```bash
./test.sh
```

51 tests covering wrapper, shell helper, installer, integrations, SAMP conformance. Pure bash + python3, no other deps. CI runs the same script on Linux + macOS.

Cases the suite covers — and that you should mentally check when adding a feature:

- **Round-trip** — send → inbox → reply → inbox.
- **Watermark** — second `inbox` returns "no new messages".
- **Same-second burst** — two sends in the same second both visible to the first `inbox`.
- **Dedup** — sync-duplicated log appears exactly once.
- **Path traversal blocked** — `.agent-message` containing `../../tmp/PWNED` falls back to cwd basename, doesn't write outside the message dir.
- **Thread inheritance** — reply uses the same thread as the message it replies to.
- **`[thread:<id>]` override** — explicit prefix wins.
- **Content-addressed `id`** — 16 hex chars, matches `sha256(canonical_json({ts,from,to,thread,body}))[:16]`.
- **NFC normalization** — non-ASCII bodies normalize before hashing; cross-impl id stable.
- **mtime short-circuit** — second read on both wrapper and shell paths exits without parsing.
- **Installer idempotence + uninstall** — `install.sh × 2 + --uninstall` cleans up; rc-block injection is idempotent and stripped on uninstall.
- **`samp-validate` conformance** — clean pass on round-trip output; catches tampered ids, single-writer violations, symlinked logs.
- **Integrations** — `--integrate=<tool>` writes / strips marker block per tool, refuses symlinked targets, `auto`/`all` honor scope rules.

Add a new test for any new feature. Prefer end-to-end (call the binary) over unit tests of internals — internals get refactored, contracts don't.

The Claude-Code round-trip (`/message-send` etc.) is not yet automated. Run it manually for changes that touch `commands/*.md`.

## Style

- Match surrounding code. The slash commands are terse on purpose; don't add prose.
- Comments only when WHY is non-obvious. Don't narrate WHAT.
- Commit messages: title under 60 chars (`feat:`/`fix:`/`docs:`/`ci:`), body as bullets if needed. No long paragraphs.

## Discussions and questions

Open an issue with the `question` template, or use the GitHub Discussions tab if enabled. Don't email the maintainer with usage questions — keep them public so others benefit.
