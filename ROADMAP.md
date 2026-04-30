# Roadmap

agent-message is finished in the sense that it solves the problem it set out to solve: cross-session, cross-repo messaging for AI agents at zero token cost on the shell path and one Bash call on the Claude path. Anything below the line marked **DONE** is a candidate, not a commitment.

Every item must serve **smaller**, **cheaper**, or **faster** — or it stays out of scope. Feature requests that don't move one of those axes belong on [`mcp_agent_mail`](https://github.com/Dicklesworthstone/mcp_agent_mail), not here.

## DONE

git-inspired primitives already shipped:

- ✅ Per-agent append-only logs (`log-<alias>.jsonl`) — single-writer-per-file invariant
- ✅ Content-addressed `id` (`sha256(canonical_json({ts,from,to,thread,body}))[:16]`)
- ✅ `mtime` short-circuit on read (both shell and wrapper paths)
- ✅ Plumbing + porcelain split (`msg cat / log / raw / compact` vs `msg / msg send / msg reply`)
- ✅ `git gc`-style `msg compact`
- ✅ Watermark with ids-at-max-ts (handles same-second bursts)
- ✅ Vendor-neutral SAMP spec ([SPEC.md](SPEC.md)) + reference implementation
- ✅ CI: matrix tests on Ubuntu + macOS, docs deploy, shellcheck

## On the table (only if warranted)

| Idea | Axis | Status |
|---|---|---|
| **Pack files** — monthly log rotation (`log-<alias>-2026-04.jsonl.gz`); reader reads packs + current | smaller (on disk), faster (smaller current file) | not started — only worth it once a single log gets big enough to slow `mtime` short-circuit miss |
| **Id-addressed threads** — `thread = id-of-first-message` instead of date-from-slug | smaller (no slug logic), correct under sender rename | not started — current slug works; rewrite would be a v2 thing |
| **Reflog-style recovery** — write-ahead journal so a crash mid-append doesn't tear a line | none of the three axes — durability tier | not started — append-only is already crash-safe at line granularity on POSIX |
| **`msg search <pattern>`** | none of the three axes | declined — `msg raw all | jq` covers it |
| **`msg ack <id>`** — explicit delivery receipts | none — feature creep | declined — fire-and-forget is the design |
| **Web UI** | none | declined — `cat` / `tail -F` / `jq` is the UI |
| **Cross-machine network transport** | none — design rule | declined — sync the directory with Syncthing / Dropbox / iCloud |

## How to propose a new item

1. Open an issue using the [feature request template](.github/ISSUE_TEMPLATE/feature_request.yml).
2. Name the axis the change serves. If you check more than one, name the trade.
3. Reference an existing `git` (or other Linus-era) precedent if you can — agent-message borrows its design.
4. Expect: enthusiastic feedback if it serves an axis, polite decline if not.

If your idea is bigger than the project's scope (threading UI, web frontend, queues, durability guarantees), contribute to [`mcp_agent_mail`](https://github.com/Dicklesworthstone/mcp_agent_mail) — different tool for different needs.
