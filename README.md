<div align="center">

# agent-message

**Cheap, fast messaging between AI agents — across different tools.**

Claude Code ↔ Codex ↔ Cursor ↔ Copilot ↔ Aider ↔ cron

No server · no MCP · no daemon · **0 LLM tokens** from your terminal

[![test](https://github.com/slima4/agent-message/actions/workflows/test.yml/badge.svg)](https://github.com/slima4/agent-message/actions/workflows/test.yml) [![docs](https://github.com/slima4/agent-message/actions/workflows/docs.yml/badge.svg)](https://github.com/slima4/agent-message/actions/workflows/docs.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Docs site](https://img.shields.io/badge/docs-live-blue)](https://slima4.github.io/agent-message/)

[**Docs**](https://slima4.github.io/agent-message/) · [**SAMP spec**](SPEC.md) · [**Implementations**](IMPLEMENTATIONS.md) · [**Roadmap**](ROADMAP.md) · [**Contributing**](CONTRIBUTING.md)

</div>

---

https://github.com/user-attachments/assets/40588c99-6f3f-403e-ba9a-5d0f9d688675

Two Claude Code sessions, two repos, no shared state. `my-server` sends its API spec with `/message-send my-web`; `my-web` runs `/message-inbox`, gets the endpoints, the models and a "no CORS configured" warning, and wires the frontend against it. One shell call each way. 3x speed.

```bash
git clone https://github.com/slima4/agent-message && cd agent-message
./install.sh --integrate=auto
```

Installs everything and wires each globally-configured agent tool found on this machine: a marker block in the tool's rules file, plus a sandbox writable-root in `~/.codex/config.toml` for Codex. All reversible with `./install.sh --uninstall`. Plain `./install.sh` skips the wiring and just names what it found.

- **Use case:** Claude Code in `api/`, Codex CLI in `web/`, Cursor in `mobile/` — three vendors, one task. Claude finishes the schema change and runs `msg send web "schema: token nullable"`. The Codex agent sees it on its next inbox check and adapts its code. No shared session, no shared vendor, no human relaying between windows.
- **Why it works everywhere:** the transport is a directory of JSONL files and the API is one shell command. No MCP server to register, no per-repo `.mcp.json`, no token. If an agent can run `bash`, it can join — including tools with no MCP support at all, plus cron jobs, CI, and you in a terminal.
- **Works with:** [Claude Code](docs/integrations/index.md), [Codex CLI](docs/integrations/codex.md), [Cursor](docs/integrations/cursor.md), [Copilot Chat + CLI](docs/integrations/copilot.md), [Antigravity](docs/integrations/antigravity.md), [Zed](docs/integrations/zed.md), [Aider](docs/integrations/aider.md), [Continue](docs/integrations/continue.md), [opencode](docs/integrations/opencode.md). `--integrate=auto` wires up every tool that configures globally in one shot; per-repo ones (Copilot Chat, Zed) take `--integrate=<tool>` from the target repo.
- **Why it's cheap:** ~1 shell call per send — no MCP handshake, no polling hook, no ack roundtrip. **0 LLM tokens** from a terminal, since `msg` never touches a model. Per-writer logs sync conflict-free across machines.

## Example dialog

Two agents (`my_app` ↔ `my_app_web`), one thread, 13 messages over ~10 minutes — a mock bug hunt:

```
my_app      → my_app_web   🪨 Welcome, traveler. Fire warm.
my_app_web  → my_app       🔥 Fire good. Sit. Share bytes.
my_app      → my_app_web   🪓 Bytes shared. Bug hunt now.
my_app_web  → my_app       🦣 Spear ready. Where bug hide?
my_app      → my_app_web   🕳️ TypeError: Cannot read 'token' of undefined
my_app_web  → my_app       🔦 Add nil check before deref.
my_app      → my_app_web   🪨 Guard clause added (auth.js:40 + JS snippet)
my_app_web  → my_app       🪵 Run test.
my_app      → my_app_web   🟢 Tests: 3 passed.
my_app_web  → my_app       🏆 Commit. Push. Sleep.
my_app      → my_app_web   🔥 git push log + commit hash
my_app_web  → my_app       🍖 Bring axe. Save fat piece.
my_app      → my_app_web   🪓 Tale of recursive stack overflow ate forest.
```

All 13 share the same thread (slug derived from the first body, replies inherit it). `log-my_app.jsonl` holds the 7 outbound from `my_app`; `log-my_app_web.jsonl` holds the 6 outbound from `my_app_web`. Bodies preserve newlines, code fences, and emojis verbatim. Content-addressed ids = no duplicates if logs sync to another machine.

Nothing in that exchange depends on which tool is behind either alias. An alias is a directory name, so one side can be Claude Code and the other Codex or Cursor — neither knows or cares.

## Design — borrowed from git

> _"I'll do something that works for me, and I won't care about anybody else."_ — Linus. SAMP is on that path.

Linus built git to be fast and cheap. A few of his ideas apply here:

- **Per-agent append-only logs** (one file per writer: `log-<alias>.jsonl`). Single-writer per file → zero risk of interleaved lines, zero locking needed. Readers union across all `log-*.jsonl` files. This makes **distributed sync actually work** — Syncthing / Dropbox / iCloud can never produce conflicts because each writer owns its own file.
- **Content-addressed IDs**. Every message gets `id = sha256(ts|from|to|thread|body)[:16]`. Readers dedup by (sender, id) — if the same record lands via sync in two different log files, you see it once.
- **`mtime` short-circuit** — both readers stat the log files and compare against a cached `(max_mtime, file_count, total_size)` per reader. If nothing observably changed, print "no new messages" and exit without parsing. ~5x speedup on cache hit at scale (50k records: 100ms → 20ms). Latency floors at `python3` startup (~30ms).
- **Plumbing + porcelain split** — `msg cat`, `msg log`, `msg raw`, `msg compact` for scripts; everything else for humans. See [Use](https://slima4.github.io/agent-message/use/).

## Install

```bash
git clone https://github.com/slima4/agent-message && cd agent-message && ./install.sh
```

Installs three slash commands into `~/.claude/commands/`, a `msg` shell function at `~/.agent-message.sh` (sourced from `~/.zshrc` / `~/.bashrc`), a Python wrapper at `~/.agent-message-cmd` that any agent can spawn, and the shared message dir at `${XDG_STATE_HOME:-~/.local/state}/agent-message/`.

Idempotent — safe to re-run. Open a new terminal after first install so the shell function loads. Install ends by naming any detected-but-unwired tool. Wire them with `--integrate=auto`, `--integrate=select` for a menu, or one at a time — see [Install](https://slima4.github.io/agent-message/install/#integrations) for the full flag table and [Uninstall](https://slima4.github.io/agent-message/install/#uninstall).

## Use

From any Claude Code session (any repo, any path):

```
# In repo "foo":
/message-send bar need your review on the schema change

# In repo "bar":
/message-inbox
[08-08 18:20] from=foo id=4a48f8ec thread=2026-08-08-foo-need-your-review-on-the-schema-change:
  need your review on the schema change
1 new from: foo (as bar)

/message-reply lgtm, merge when ready
/message-inbox 2      # re-read the 2 latest, read or not
```

From any terminal (**0 LLM tokens** — doesn't hit any model at all):

```console
$ msg send bar "need your review on the schema change"
sent foo→bar thread=2026-08-08-foo-need-your-review-on-the-schema-change id=4a48f8ec9c868a1c

$ msg
[08-08 18:20] from=foo id=4a48f8ec thread=2026-08-08-foo-need-your-review-on-the-schema-change:
  need your review on the schema change
1 new from: foo (as bar)

$ msg reply "lgtm, merge when ready"
$ msg 2           # re-read the 2 latest, read or not — watermark untouched
$ msg tail        # follow live in a spare pane — free push notifications
```

The sender alias is the basename of `$(pwd)`. So `/Users/you/dev/foo` → `foo`. Override per-repo by dropping a one-line `.agent-message` file at the repo root:

```bash
echo "my-short-name" > .agent-message
```

From Codex, Cursor, Aider, a framework, CI, or cron — spawn the wrapper directly. No SDK, no library, no MCP:

```bash
echo "ping from cron" | ~/.agent-message-cmd send bar     # body on stdin
~/.agent-message-cmd inbox
echo "pong" | ~/.agent-message-cmd reply
```

This is the same binary Claude Code uses — the slash commands are thin wrappers around it, and `--integrate=<tool>` just teaches another agent the same three lines. If your agent has a `Bash` / `subprocess` tool, it can talk to every other agent here.

## How it works

Each writer owns one file: `$DIR/log-<alias>.jsonl`. One message per line:

```json
{"id": "4a48f8ec9c868a1c", "ts": 1786202456, "from": "foo", "to": "bar", "thread": "2026-08-08-foo-need-your-review-on-the-schema-change", "body": "need your review on the schema change"}
```

- `/message-send <to> <body>` (or `msg send <to> <body>`) — appends one line to `log-<me>.jsonl`.
- `/message-inbox` (or `msg`) — unions `log-*.jsonl`, dedups by `(from, id)`, filters `to == me`, shows what's past the watermark. Full bodies, indented. Default is bounded by *unread* — every one, however many. `<n>` is bounded by *count* — the N latest, read or not, watermark untouched. `all` is unbounded. Output is capped per run, spent newest-first; an elision always states how much was cut.
- `/message-reply <body>` (or `msg reply <body>`) — replies to the most recent message addressed to me, inheriting its thread. If two *different* senders tie at the newest `ts`, arrival order is unrecoverable, so it lists the candidates and refuses rather than guess — pick with `send <from>` plus a `[thread:<thread>]` prefix.

No server. No network. No port. Works offline.

## Compared to the alternatives

<details>
<summary><b>agent-message vs mcp_agent_mail vs Agent Teams</b></summary>

<br>

| | agent-message | mcp_agent_mail | Agent Teams |
|---|---|---|---|
| runtime | append-only files | HTTP server, SQLite | Claude Code built-in |
| **which agents can join** | **anything that runs a shell command — any vendor, MCP or not, plus cron / CI / humans** | MCP clients only, `.mcp.json` per repo | Claude Code only |
| setup | 1 script | installer + LaunchAgent + token rotation + per-repo `.mcp.json` | opt-in env flag |
| identity | repo basename | curated adjective+noun, strict rules | team lead/teammate |
| cross-session | yes | yes | team only |
| tokens per send (agent) | ~1 shell call | MCP init + resource reads + tool call + ack poll | similar |
| tokens per send (shell / cron / script) | **0** | n/a | n/a |
| passive polling | none | optional hook | automatic |
| dedup on cross-machine sync | yes (content-addressed `id`) | n/a | n/a |
| concurrent writers | safe (single-writer per file) | locked via server | centrally coordinated |
| audit trail | the files themselves | Git-backed markdown | per-session |
| cost | ~0 | high | medium |

</details>

**Pick agent-message** when your agents run in *different tools*, message volume is low, you care about tokens more than features, and you want to `cat`/`grep`/`tail -f` the logs yourself. **Pick mcp_agent_mail** when every agent is an MCP client, you run many of them, and you want advisory file leases, threaded search, and a web UI enough to accept the token and setup cost. **Pick Agent Teams** when you're entirely inside Claude Code.

## Limits

- **No auth, no encryption.** Anyone who can read the message dir reads every message. Don't put secrets here.
- **Bodies cap at 64 KiB.** Messages carry references, not payloads: send `review /tmp/big.diff`, not the diff. Logs are append-only, so one huge record taxes every future read forever.
- **No notifications.** You pull with `/message-inbox` or `msg`. Run `msg tail` in a spare pane for a push feel.
- **Single machine, or sync via files.** Syncthing / Dropbox / iCloud work by construction — per-writer logs can't conflict, content-addressed ids dedup. Aliases must be unique per host; exclude `.seen-*` / `.mtime-*` from sync.

Full detail, plus the `AGENT_MESSAGE_DIR` environment contract: [Limits](https://slima4.github.io/agent-message/limits/).

## FAQ

**How do I make Claude Code and Cursor (or Codex) talk to each other?** Install once, then `./install.sh --integrate=auto`. Every agent gets the same three commands. Identity is the repo directory name, so there's no registration step and nothing to configure per pair.

**Do I need MCP?** No. There's no server to run and no `.mcp.json` to add. Agents call one shell command, so tools without MCP support work identically.

**What does it cost in tokens?** About one Bash tool call per operation for an agent. Zero for the `msg` shell function — it never contacts a model.

**Does it work across machines?** Yes. Sync the message directory with Syncthing, Dropbox, or iCloud. Per-writer logs can't conflict and content-addressed ids dedup, so the same message never appears twice. Use a distinct alias per host.

**Can other people read my messages?** Anyone who can read the directory can. It's a plaintext local log with no auth and no encryption — treat it like `~/.bash_history` and keep secrets out.

## Contributing

PRs welcome — read [`CONTRIBUTING.md`](CONTRIBUTING.md) first (line budgets, single-writer invariant, smaller/cheaper/faster rule). For non-trivial work, [open an issue](https://github.com/slima4/agent-message/issues/new/choose) first. See also [`SECURITY.md`](SECURITY.md) and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

Docs live at <https://slima4.github.io/agent-message/> — sources in [`docs/`](docs/), build with `pip install -r requirements-docs.txt && mkdocs serve`.

## License

MIT — see [`LICENSE`](LICENSE).
