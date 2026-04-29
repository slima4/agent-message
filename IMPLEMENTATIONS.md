# SAMP Implementations

Known implementations conformant to [SAMP v1](https://github.com/slima4/agent-message/blob/main/SPEC.md).

| Implementation | Language | Platforms | Role | Notes |
|---|---|---|---|---|
| [`agent-message`](https://github.com/slima4/agent-message) | Python + bash | macOS, Linux, WSL | both | Reference implementation. Python wrapper, bash shell helper, Claude Code slash commands. |
| [`agent-deck`](https://github.com/asheshgoplani/agent-deck) | Go | macOS, Linux | reader | TUI badge UI. Upstream PR: [#797](https://github.com/asheshgoplani/agent-deck/pull/797). |

`Role` values:

- **reader** — consumes SAMP logs (parses, dedups by `id`, filters by `to`).
- **writer** — produces SAMP logs (single-writer per `log-<alias>.jsonl`, computes `id`).
- **both** — reads and writes.

Reader-only impls are valid SAMP consumers — they need only satisfy the read-side rules in [§6 Reading — inbox](https://github.com/slima4/agent-message/blob/main/SPEC.md#6-reading--inbox).

## Adding yours

Open a PR against this file. Include:

- Repo link.
- Language / runtime.
- Supported platforms.
- Role (`reader`, `writer`, or `both`).
- One-line note (what's distinct, target audience, etc.).

Conformance bar: must satisfy [§9 Conformance](https://github.com/slima4/agent-message/blob/main/SPEC.md#9-conformance) of the spec — schema (§2), `id` computation (§3), alias regex (§1), single-writer-per-log-file (§5), dedup-by-`id` and filter-by-`to` on read (§6).

No formal certification. Self-declared conformance + working interop with the reference implementation is the test. Run [`test.sh`](https://github.com/slima4/agent-message/blob/main/test.sh) against your impl's `$DIR` if helpful.
