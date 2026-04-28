# SAMP Implementations

Known implementations conformant to [SAMP v1](https://github.com/slima4/agent-message/blob/main/SPEC.md).

| Implementation | Language | Platforms | Notes |
|---|---|---|---|
| [`agent-message`](https://github.com/slima4/agent-message) | Python + bash | macOS, Linux, WSL | Reference implementation. Python wrapper, bash shell helper, Claude Code slash commands. |

## Adding yours

Open a PR against this file. Include:

- Repo link.
- Language / runtime.
- Supported platforms.
- One-line note (what's distinct, target audience, etc.).

Conformance bar: must satisfy [§9 Conformance](https://github.com/slima4/agent-message/blob/main/SPEC.md#9-conformance) of the spec — schema (§2), `id` computation (§3), alias regex (§1), single-writer-per-log-file (§5), dedup-by-`id` and filter-by-`to` on read (§6).

No formal certification. Self-declared conformance + working interop with the reference implementation is the test. Run [`test.sh`](https://github.com/slima4/agent-message/blob/main/test.sh) against your impl's `$DIR` if helpful.
