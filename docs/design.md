# Design

Linus built `git` to be **fast** and **cheap**. agent-message borrows the same patterns:

## Per-agent append-only logs

```
$AGENT_MESSAGE_DIR/
├── log-foo.jsonl           — only foo writes here
├── log-bar.jsonl           — only bar writes here
├── .seen-foo                — foo's reader watermark
└── .mtime-foo               — foo's reader mtime cache
```

**Single-writer-per-file** is the one hard invariant. Everything else flows from it:

- No locking needed. Two processes never write the same file.
- No interleave. With one writer per file, two appends never race — regardless of message size.
- **Sync layers can't conflict.** Syncthing / Dropbox / iCloud each see one writer per file. No merge conflicts. No "both copies kept" duplicates that need manual resolution.
- Readers union across all `log-*.jsonl` and dedup by content-addressed id (next).

## Content-addressed IDs

```
canonical = json.dumps({ts, from, to, thread, body},
                       ensure_ascii=False, sort_keys=True)
id        = sha256(canonical.encode("utf-8")).hexdigest()[:16]
```

Identical content → identical id, no matter which machine produced the record. After a sync layer occasionally duplicates a file, readers see each unique message **exactly once**.

## `mtime` short-circuit

Before parsing anything, the reader stats all `log-*.jsonl` and compares `(max_mtime, file_count)` against the per-reader `.mtime-<alias>` cache. If unchanged, it prints `no new messages` and exits — no JSON parse, no file read past the directory listing.

Both reader paths (shell and wrapper) use this. ~5x speedup on cache hit at scale (50k records: 100ms → 20ms). Skipped when `.seen-<alias>` is missing, so `rm .seen-<alias>` forces a re-read.

## Watermark with ids-at-max-ts

Standard "show me new messages since I last looked" needs a watermark. A naive `last_seen_ts` breaks at 1-second clock resolution: two messages with the same epoch second become indistinguishable, and the second one is hidden by the next read.

agent-message stores:

```json
{"ts": <max_ts>, "ids": [<id1>, <id2>, ...]}
```

Filter:

```
skip if  ts <  watermark.ts
skip if  ts == watermark.ts AND id ∈ watermark.ids
```

If a new message arrives with the same `ts` as the previous max, its `id` is not in the prior watermark, so it shows. After the read, the watermark accumulates ids at the new max.

## Plumbing + porcelain split

Like git's `cat-file` / `ls-tree` / `mktree` (plumbing) vs `add` / `commit` / `log` (porcelain).

| Porcelain | Plumbing |
|---|---|
| `msg`, `msg send`, `msg reply`, `msg tail` | `msg cat`, `msg log`, `msg raw`, `msg compact` |

Porcelain is for humans; plumbing is for scripts and forensic spelunking. Slash commands (Claude Code) are porcelain only — keeping the per-invocation prompt small.

## `git gc`-style compact

`msg compact` walks every `log-*.jsonl`, dedups within each file by id, fills in `id` on records that lack it (legacy), and atomically rewrites via temp-file + `os.replace` while preserving permissions.

Idempotent: re-running on a clean store reports 0 rewrites.

## What we did NOT borrow (yet)

Roadmap candidates and declined items — with axis tags — live in [ROADMAP.md](https://github.com/slima4/agent-message/blob/main/ROADMAP.md). Short version:

- **Pack files** — monthly log rotation (`log-foo-2026-04.jsonl.gz`). Candidate; only worth it once a single log slows the `mtime` short-circuit miss.
- **Refs** — id-addressed threads. Stronger than the slug + alias disambiguator. v2 thing if ever.
- **Reflog** — write-ahead recovery. Probably overkill at our durability tier.

If a feature has no `git` analogue and doesn't make agent-message **smaller, cheaper, or faster**, it's out of scope. Point feature requests at [`mcp_agent_mail`](https://github.com/Dicklesworthstone/mcp_agent_mail) — different tool for different needs.
