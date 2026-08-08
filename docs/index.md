---
template: home.html
title: Cross-tool messaging between AI coding agents
description: >-
  agent-message lets AI coding agents in different tools — Claude Code, Codex CLI,
  Cursor, Copilot, Aider — send messages to each other through a shared directory of
  append-only JSONL files. No server, no MCP, no daemon, no token.
hide:
  - navigation
  - toc
---

**agent-message is a file-based message bus for AI coding agents.** Agents address each
other by directory name, write to their own append-only JSONL log, and read by unioning
the logs in one shared directory. Anything that can run a shell command can join — any
vendor, MCP or not, plus cron jobs, CI, and you in a terminal. It is the reference
implementation of [SAMP](spec.md) (Simple Agent Message Protocol), which is vendor-neutral
and separately specified.

## Install

```bash
git clone https://github.com/slima4/agent-message && cd agent-message
./install.sh && ./install.sh --integrate=auto
```

That installs three Claude Code slash commands, a `msg` shell function, and a wrapper
executable at `~/.agent-message-cmd` that any other agent can spawn. `--integrate=auto`
teaches the same three commands to every tool that configures globally — Cursor, Copilot
CLI, Antigravity, Codex. Per-repo tools (Copilot Chat, Zed) take `--integrate=<tool>` run
from inside the target repo. Re-running is safe. See [Install](install.md) for the flag
table and uninstall.

## First message

=== "Repo `api`"

    ```console
    $ msg send web "users.token can be null now"
    sent api→web thread=2026-08-08-api-users-token-can-be-null-now id=ff8ebf0654be0166
    ```

=== "Repo `web`"

    ```console
    $ msg
    [08-08 17:16] from=api id=ff8ebf06 thread=2026-08-08-api-users-token-can-be-null-now:
      users.token can be null now
    1 new from: api (as web)

    $ msg reply "guarded in auth.js:40, tests pass"
    reply web→api thread=2026-08-08-api-users-token-can-be-null-now id=346a220ebe4e7032
    ```

Nothing in that exchange depends on which tool sits behind either alias. An alias is a
directory name, so one side can be Claude Code and the other Codex CLI or Cursor —
neither knows or cares.

## Three paths, one protocol

| Path | Cost per operation | Use from |
|---|---|---|
| Slash commands — `/message-send`, `/message-inbox`, `/message-reply` | ~1 Bash tool call | a Claude Code session |
| Shell function — `msg send`, `msg`, `msg reply`, `msg tail` | **0 LLM tokens** | any terminal: humans, scripts, cron |
| Wrapper — `~/.agent-message-cmd` with `send`, `inbox`, `reply` | one shell call | any other agent CLI or framework |

All three read and write the same on-disk format, so they interoperate freely. The slash
commands are thin invocations of the wrapper; the shell function reimplements the same
protocol in bash and is covered by the same test suite.

## Design

Borrowed from git, which had the same problem: many writers, no server.

<div class="grid cards" markdown>

-   :material-file-tree-outline:{ .lg .middle } **One writer per file**

    ---

    Each alias appends only to `log-<alias>.jsonl`. No locking, no interleaved lines, and
    file-sync tools cannot produce a conflict because no file has two writers.

-   :material-fingerprint:{ .lg .middle } **Content-addressed ids**

    ---

    Every record carries `sha256` of its canonical form, truncated to 16 hex. Readers
    dedup on `(from, id)`, so a record that arrives twice through sync is shown once.

-   :material-clock-fast:{ .lg .middle } **`mtime` short-circuit**

    ---

    Readers compare `(max_mtime, file_count, total_size)` against a cached value and exit
    without parsing when nothing changed. 50k records: 100 ms → 20 ms.

-   :material-console-line:{ .lg .middle } **Plumbing and porcelain**

    ---

    `msg cat`, `msg log`, `msg raw`, `msg compact` for scripts; `msg`, `msg send`,
    `msg reply` for people. Same split, same reason as git.

-   :material-cloud-off-outline:{ .lg .middle } **No runtime beyond `python3`**

    ---

    No server, no port, no SQLite, no token, no `jq`. Works offline. The whole store is a
    directory you can `cat`, `grep`, and `tail -f` yourself.

-   :material-book-open-outline:{ .lg .middle } **Specified, not just shipped**

    ---

    [SAMP v1](spec.md) is normative and vendor-neutral, and `samp-validate` checks a store
    for conformance. Write your own implementation in any language.

</div>

[Read the design notes](design.md){ .md-button } [Read the spec](spec.md){ .md-button }

## Compared to the alternatives

| | agent-message | mcp_agent_mail | Agent Teams |
|---|---|---|---|
| Runtime | append-only files | HTTP server, SQLite | Claude Code built-in |
| **Which agents can join** | **anything that runs a shell command** | MCP clients only | Claude Code only |
| Setup | one script | installer, service, token, per-repo `.mcp.json` | env flag |
| Identity | repo basename | curated, registered | team lead / teammate |
| Tokens per send | ~1 shell call | MCP init + reads + call + ack | similar |
| From a script or cron | **0 tokens** | n/a | n/a |
| Cross-machine dedup | yes, content-addressed | n/a | n/a |

Pick agent-message when your agents run in *different tools*, volume is low, and you care
about tokens more than features. Pick [mcp_agent_mail](https://github.com/Dicklesworthstone/mcp_agent_mail)
when every agent is an MCP client and you want file leases, threaded search, and a web UI
enough to pay for them. Pick Agent Teams when you are entirely inside Claude Code.

## Questions

**Do I need MCP?** No. There is no server to run and no `.mcp.json` to add. Agents call
one shell command, so tools without MCP support work identically.

**How do I make Claude Code and Cursor or Codex talk?** Install once, then
`./install.sh --integrate=auto`. Identity is the repo directory name, so there is no
registration step and nothing to configure per pair.

**Does it work across machines?** Yes — sync the directory with Syncthing, Dropbox, or
iCloud. Per-writer logs cannot conflict and content-addressed ids dedup. Use a distinct
alias per host and exclude `.seen-*` / `.mtime-*` from sync.

**Can other people read my messages?** Anyone who can read the directory can. It is a
plaintext local log with no auth and no encryption — see [Limits](limits.md).

## Next

<div class="grid cards am-next" markdown>

-   [**Install**](install.md) — flags, integrations for nine tools, uninstall.
-   [**Use**](use.md) — all three paths, every subcommand, what a read prints.
-   [**SAMP spec**](spec.md) — the normative wire format, for implementers.
-   [**Limits**](limits.md) — no auth, no notifications, 64 KiB bodies, sync caveats.

</div>
