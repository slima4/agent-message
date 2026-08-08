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
- Readers union across all `log-*.jsonl` and dedup by `(sender, content-addressed id)` (next).

## Content-addressed IDs

```
canonical = json.dumps({ts, from, to, thread, body},
                       ensure_ascii=False, sort_keys=True)
id        = sha256(canonical.encode("utf-8")).hexdigest()[:16]
```

Identical content → identical id, no matter which machine produced the record. After a sync layer occasionally duplicates a file, readers see each unique message **exactly once**. The dedup key is `(from, id)` — scoping by sender means a malicious writer can't suppress someone else's message by pre-publishing its id in their own log.

## `mtime` short-circuit

Before parsing anything, the reader stats all `log-*.jsonl` and compares `(max_mtime, file_count, total_size)` against the per-reader `.mtime-<alias>` cache. If unchanged, it prints `no new messages` and exits — no JSON parse, no file read past the directory listing. Total size catches what mtime alone can't: appends within the same mtime tick (coarse filesystems) and sync deliveries that preserve an older sender-side mtime.

Both reader paths (shell and wrapper) use this. ~5x speedup on cache hit at scale (50k records: 100ms → 20ms). Skipped when `.seen-<alias>` is missing, so `rm .seen-<alias>` forces a re-read.

## Clock-capped watermark with shown ids

Standard "show me new messages since I last looked" needs a watermark. A naive `last_seen_ts` breaks twice: at 1-second clock resolution (two messages in the same epoch second become indistinguishable) and under sender clock skew (one fast-clock sender pushes the watermark into the future, permanently hiding later on-time messages from everyone else).

agent-message stores:

```json
{"ts": <min(now, max_shown_ts)>, "ids": ["<from>:<id>", ...]}
```

Filter:

```
skip if  ts < watermark.ts
skip if  from:id ∈ watermark.ids
```

`ts` is capped at the reader's own clock, so a sender ahead of it can't advance the watermark past honest senders — its already-shown messages ride in `ids` (every shown record with `ts >=` the cap) until the clock catches up. Same-second bursts work the same way: the new message's id isn't in the prior watermark, so it shows.

## Plumbing + porcelain split

Like git's `cat-file` / `ls-tree` / `mktree` (plumbing) vs `add` / `commit` / `log` (porcelain).

| Porcelain | Plumbing |
|---|---|
| `msg`, `msg send`, `msg reply`, `msg tail` | `msg cat`, `msg log`, `msg raw`, `msg compact` |

Porcelain is for humans; plumbing is for scripts and forensic spelunking. Slash commands (Claude Code) are porcelain only — keeping the per-invocation prompt small.

## `git gc`-style compact

`msg compact` compacts **your own** `log-<me>.jsonl` only — other logs have their own writer (§5) and may be mid-append; they are never touched. It dedups by id, fills in `id` on records that lack it (legacy), keeps unparseable lines verbatim (crash-truncated bytes may be hand-recoverable), and atomically rewrites via temp-file + `os.replace` while preserving permissions — aborting if the log changed underneath it.

Idempotent: re-running on a clean log rewrites nothing.

## What we did NOT borrow (yet)

Roadmap candidates and declined items — with axis tags — live in [ROADMAP.md](https://github.com/slima4/agent-message/blob/main/ROADMAP.md). Short version:

- **Pack files** — monthly log rotation (`log-foo-2026-04.jsonl.gz`). Candidate; only worth it once a single log slows the `mtime` short-circuit miss.
- **Refs** — id-addressed threads. Stronger than the slug + alias disambiguator. v2 thing if ever.
- **Reflog** — write-ahead recovery. Probably overkill at our durability tier.

If a feature has no `git` analogue and doesn't make agent-message **smaller, cheaper, or faster**, it's out of scope. Point feature requests at [`mcp_agent_mail`](https://github.com/Dicklesworthstone/mcp_agent_mail) — different tool for different needs.
