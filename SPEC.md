# SAMP — Simple Agent Message Protocol

**Version 1** · 2026-04-25 · MIT licence applies to this document and any reference code.

SAMP is a file-based protocol for asynchronous, durable, sync-safe message exchange between independent processes — typically AI agents (Claude Code, Cursor, Aider, custom CLIs) running locally on the same machine, or across machines that share a directory via Syncthing / Dropbox / iCloud / etc.

There is **no server**, **no daemon**, **no broker**, and **no network protocol**. Two parties agree on a shared directory; they exchange messages by appending JSON lines to per-writer files inside it.

This document defines the on-disk format, semantics, and conformance rules. Any implementation that follows them can interoperate with any other.

## 1. Storage layout

Implementations operate within a single **message directory** (`$DIR`):

```
$DIR/
├── log-<alias>.jsonl       — one append-only file per writer
├── .seen-<alias>            — reader watermark (one per reader; optional)
└── .mtime-<alias>           — reader mtime cache (optional, performance only)
```

- `<alias>` is the identifier used by a participant. It MUST match the regex `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. Implementations MUST reject or sanitise aliases that fail this check.
- The default location for `$DIR` is `$HOME/dev/.message`. Implementations SHOULD honour the environment variable **`AGENT_MESSAGE_DIR`** when set.
- Each `log-<alias>.jsonl` is owned by exactly one writer (the participant whose alias is in the filename). **No file has two writers.** This is the single hard invariant of the protocol; everything else follows from it.

## 2. Message schema

A message is a single JSON object on its own line in `$DIR/log-<from>.jsonl`. Required fields:

| field    | type        | description                                                                |
|----------|-------------|----------------------------------------------------------------------------|
| `id`     | string      | 16 lowercase hex chars; content-addressed (see §3)                         |
| `ts`     | integer     | Unix epoch seconds, UTC                                                    |
| `from`   | string      | sender alias (matches §1 alias regex)                                      |
| `to`     | string      | recipient alias                                                            |
| `thread` | string      | thread identifier (see §4)                                                 |
| `body`   | string      | message body — may contain newlines, Unicode, code fences, anything UTF-8  |

Implementations:

- MUST emit valid JSON (`json.dumps` / `JSON.stringify` with non-ASCII preserved or escaped).
- MUST write exactly one record per line (`\n` terminator).
- MUST NOT reorder fields on read — readers parse with a JSON library; field order is irrelevant.
- MAY add additional fields. Readers MUST ignore unknown fields (forward-compatible).

## 3. The `id` field

`id` is content-addressed:

```
canonical = json.dumps({ts, from, to, thread, body},
                       ensure_ascii=False, sort_keys=True)
id        = sha256(canonical.encode("utf-8")).hexdigest()[:16]
```

Reasoning:

- Identical message content → identical id, even across machines. Enables dedup after sync.
- Sorted keys + non-ASCII preserved → canonical bytes are deterministic across implementations.
- 16 hex chars (64 bits) → collision probability negligible at any plausible message volume.

Older records that pre-date `id` (legacy) MAY omit it; readers MUST compute the id on the fly using the same formula. New writes MUST include `id`.

## 4. The `thread` field

Threads group related messages. Two ways to derive `thread`:

**4.1 Explicit override.** If `body` begins with `[thread:<id>]` (optional surrounding whitespace), the writer:

- Strips the `[thread:<id>]` prefix from `body`.
- Sets `thread = <id>`.

**4.2 Auto-derived.** Otherwise, on the first message of a thread:

```
date  = strftime("%Y-%m-%d")  // local time
slug  = first line of body, lowercased,
        non-alphanumeric runs collapsed to "-",
        leading/trailing "-" stripped, truncated to 40 chars
        (empty → "msg")
thread = f"{date}-{from}-{slug}"
```

Including `<from>` in the slug prevents collisions when multiple writers send the same first-line content on the same day.

**Replies** inherit the thread of the message they reply to (§6).

## 5. Writing

A participant with alias `<frm>` sending to `<to>`:

1. Build the record — `ts` is current Unix time, `id` per §3, `thread` per §4.
2. Append exactly one line (`json.dumps(rec) + "\n"`) to `$DIR/log-<frm>.jsonl`.
3. The directory is created if missing.

Implementations:

- MUST NOT write to any log file other than their own (`log-<frm>.jsonl`).
- MUST use append mode (`O_APPEND` semantics). On POSIX, line-sized writes (≤ `PIPE_BUF`, 4 KiB on Linux/macOS) are atomic; longer messages are still safe given the single-writer invariant.
- SHOULD NOT lock — single-writer-per-file makes locking unnecessary.

## 6. Reading — inbox

To read messages addressed to alias `<me>` (porcelain, "inbox" view):

1. **mtime short-circuit (optional).** Stat all `$DIR/log-*.jsonl`. Compare `(max_mtime, file_count)` against `$DIR/.mtime-<me>` (if any). If unchanged, return "no new messages" without parsing.
2. **Watermark load (optional).** Read `$DIR/.seen-<me>` if present:
   ```json
   {"ts": <int>, "ids": [<hex>, ...]}
   ```
3. **Scan.** For each `$DIR/log-*.jsonl`, read line by line. For each parseable record where `to == me`:
   - Compute or read `id`.
   - Skip if seen this scan (dedup).
   - Skip if `ts < watermark.ts` OR (`ts == watermark.ts` AND `id ∈ watermark.ids`).
4. **Sort** survivors by `ts`.
5. **Output.**
6. **Update watermark.** Set:
   ```
   new_ts  = max ts in output
   new_ids = ids of records at ts == new_ts
            (∪ previous watermark.ids if new_ts == previous.ts)
   ```
   Write `{"ts": new_ts, "ids": new_ids}` atomically.
7. **Update mtime cache.** Write `{"max_mtime": cur_max, "files": cur_count}`.

The same-second-burst rule (`ts < since OR (ts == since AND id ∈ since_ids)`) handles 1-second clock resolution: two messages with the same epoch second remain distinct in the watermark.

Three modes are common (and present in the reference implementation):

- **default** — apply watermark, update on success
- **all** — show every record, no watermark update
- **raw** — emit JSONL verbatim, no formatting, no watermark update

Modes other than `default` are SHOULD-implement, not MUST.

## 7. Reading — reply

To reply to the most recent message addressed to `<me>`:

1. Scan as in §6 with watermark disabled, dedup by id.
2. Filter `to == me`. Sort by `ts`. Pick the last record `last`.
3. Build a new record with `from = me`, `to = last.from`, `thread = last.thread`, `body = <reply>`.
4. Append per §5.

## 8. Sync semantics

Because no file has two writers, syncing the directory between machines (Syncthing / Dropbox / iCloud) cannot create write conflicts. The same record may legitimately appear in two log files if the sync layer duplicates it, but readers dedup by `id` (§3) so each message is shown exactly once.

Implementations MUST NOT rely on filesystem locking, atomic rename across machines, or any property of the sync layer beyond eventual consistency.

## 9. Conformance

A SAMP-conformant implementation MUST:

- Use the schema in §2 with `id` computed per §3.
- Honour the alias regex in §1.
- Append-only, single-writer-per-log-file in §5.
- On read, dedup by `id` and filter by `to`.

A SAMP-conformant implementation SHOULD:

- Support the `[thread:<id>]` override in §4.1.
- Persist a watermark per §6 if it offers an "inbox" mode.
- Honour `AGENT_MESSAGE_DIR`.

A SAMP-conformant implementation MAY:

- Implement plumbing commands (`cat`, `log`, `raw`, `compact`) for human inspection.
- Cache the mtime short-circuit per §6.
- Add additional fields to records (forward-compatible).

## 10. Reference implementation

`agent-message` (this repository) is the reference implementation. It provides:

- A Python wrapper (`bin/agent-message-cmd`) — single executable, three subcommands (`send`, `inbox`, `reply`).
- A pure-bash shell helper (`shell/msg.sh`) — `msg` function with porcelain + plumbing subcommands.
- Three Claude Code slash-command prompts (`commands/message-{send,inbox,reply}.md`) — invoke the wrapper with one Bash tool call per operation.

Other agent CLIs / frameworks integrate by spawning the wrapper directly, or by reimplementing the protocol natively against the same `$DIR`.

## 11. Versioning

This document specifies SAMP **v1**. Future versions, if any, will be additive: new optional fields, new optional reader modes, no breaking changes to the schema or single-writer invariant.
