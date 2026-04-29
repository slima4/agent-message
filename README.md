# agent-message

[![test](https://github.com/slima4/agent-message/actions/workflows/test.yml/badge.svg)](https://github.com/slima4/agent-message/actions/workflows/test.yml) [![docs](https://github.com/slima4/agent-message/actions/workflows/docs.yml/badge.svg)](https://github.com/slima4/agent-message/actions/workflows/docs.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![Docs site](https://img.shields.io/badge/docs-live-blue)](https://slima4.github.io/agent-message/)

**Cheap, fast messaging between AI agents.** File-based — no server, no MCP, no daemon. Reference impl of [SAMP](SPEC.md) ([implementations](IMPLEMENTATIONS.md)).

- **Why:** ~1 shell call per send (low Claude tokens). **0 LLM tokens** from terminal — `msg` never touches a model. Per-writer logs sync conflict-free across machines.
- **Install:** `git clone https://github.com/slima4/agent-message && cd agent-message && ./install.sh`
- **Demo:** sender runs `msg send bar "ping"`; recipient (in `bar/`) runs `msg`; message appears. Done.

Any agent CLI, framework, or shell process that can append a JSON line to a file can participate. Claude Code is the first client; the protocol is vendor-neutral.

## Goal

Make agent-to-agent communication as **cheap** and **fast** as possible:

- **Cheap for the agent**: ~1 shell call per send/receive. No MCP handshake, no polling hook, no ack roundtrip. Aggressively-shrunk slash-command prompts to minimize per-invocation input tokens.
- **Cheap for humans**: the `msg` shell function hits the logs directly. **0 LLM tokens**. The model is never in the loop.
- **Fast**: local file append + read. No network, no server to wake up. `mtime` short-circuit skips parsing entirely when nothing changed. Latency is dominated by `python3` startup (~30ms).

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

## Design — borrowed from git

> _"I'll do something that works for me, and I won't care about anybody else."_ — Linus. SAMP is on that path.

Linus built git to be fast and cheap. A few of his ideas apply here:

- **Per-agent append-only logs** (one file per writer: `log-<alias>.jsonl`). Single-writer per file → zero risk of interleaved lines, zero locking needed. Readers union across all `log-*.jsonl` files. This makes **distributed sync actually work** — Syncthing / Dropbox / iCloud can never produce conflicts because each writer owns its own file.
- **Content-addressed IDs**. Every message gets `id = sha256(ts|from|to|thread|body)[:16]`. Readers dedup by id — if the same record lands via sync in two different log files, you see it once.
- **`mtime` short-circuit** — before parsing anything, `msg` stats the log files and compares against a cached `(max_mtime, file_count)` per reader. If nothing observably changed, print "no new messages" and exit immediately.

Plumbing (scriptable): `msg cat <id|prefix>`, `msg log [alias]`, `msg raw [all]`, `msg compact`. Candidates and declined items in [ROADMAP.md](ROADMAP.md).

## Install

```bash
git clone https://github.com/slima4/agent-message && cd agent-message && ./install.sh
```

Installs:

- Three slash commands into `~/.claude/commands/` for Claude Code sessions.
- A `msg` shell function at `~/.agent-message.sh`, sourced from `~/.zshrc` / `~/.bashrc` so you can read/send from any terminal at **0 LLM tokens**.
- A Python wrapper at `~/.agent-message-cmd` that any agent (Claude Code, Cursor, Aider, scripts, cron) can spawn with one shell call.
- The shared message dir at `${XDG_STATE_HOME:-~/.local/state}/agent-message/`.

Idempotent — safe to re-run. Open a new terminal after first install so the shell function loads.

## Use

From any Claude Code session (any repo, any path):

```
# In repo "foo":
/message-send bar need your review on the schema change

# In repo "bar":
/message-inbox
  [04-24 17:42] from=foo thread=2026-04-24-foo-need-your-review: need your review on…

/message-reply lgtm, merge when ready
```

From any terminal (**0 LLM tokens** — doesn't hit any model at all):

```
# In repo "foo":
$ msg send bar "need your review on the schema change"
sent foo→bar thread=2026-04-24-foo-need-your-review id=ab12cd34ef56…

# In repo "bar":
$ msg
[04-24 17:42] from=foo thread=2026-04-24-foo-need-your-review: need your review on…

$ msg reply "lgtm, merge when ready"
$ msg tail        # follow live in a spare pane — free push notifications
```

The sender alias is the basename of `$(pwd)`. So `/Users/you/dev/foo` → `foo`. Override per-repo by dropping a one-line `.agent-message` file at the repo root:

```
$ echo "my-short-name" > .agent-message
```

From any other agent CLI / framework / script — spawn the wrapper directly. No SDK, no library:

```bash
# Send (body on stdin so newlines + quotes survive)
echo "ping from cron" | ~/.agent-message-cmd send bar

# Inbox / reply
~/.agent-message-cmd inbox
echo "pong" | ~/.agent-message-cmd reply
```

This is the same path Claude Code uses internally — the slash commands just spawn this binary. If your agent has a `Bash` / `subprocess` tool, you have SAMP support.

## How it works

Each writer owns one file: `$DIR/log-<alias>.jsonl`. One message per line:

```json
{"id": "ab12cd34ef56…", "ts": 1777040863, "from": "foo", "to": "bar", "thread": "2026-04-24-foo-need-your-review", "body": "…"}
```

- `/message-send <to> <body>` (or `msg send <to> <body>`) — appends one line to `log-<me>.jsonl`.
- `/message-inbox` (or `msg`) — unions `log-*.jsonl`, dedups by `id`, filters `to == me`, shows messages past the watermark (`ts` + ids-at-max-ts).
- `/message-reply <body>` (or `msg reply <body>`) — finds the most recent message addressed to me (across all logs), appends reply to `log-<me>.jsonl`.

No server. No network. No port. Works offline.

## Compared to the alternatives

| | agent-message | mcp_agent_mail | Agent Teams |
|---|---|---|---|
| runtime | append-only files | HTTP server, SQLite | Claude Code built-in |
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

Pick agent-message when: you run 2–10 agent sessions (Claude Code, Cursor, Aider, scripts, mixed), message volume is low, you care about tokens more than features, you want to `cat`/`grep`/`tail -f` the logs yourself.

Pick mcp_agent_mail when: you run many agents, want advisory file leases, threaded search, a web UI, and are OK with the token / setup cost.

## Browse and script

Plumbing for scripts and spelunking:

```bash
msg cat ab12cd34            # pretty-print one record by id (4+ char prefix)
msg log [alias]             # git-log style — messages involving me / alias
msg raw [all] | jq …        # JSONL dump for piping
msg compact                 # idempotent dedup + id backfill
```

## Uninstall

```bash
./install.sh --uninstall
```

Removes the three slash commands, the wrapper at `~/.agent-message-cmd`, the shell helper, the per-agent logs + caches in the message dir, and the `~/.zshrc` / `~/.bashrc` source block. Does not touch `.agent-message` files in your repos.

## Environment

- `AGENT_MESSAGE_DIR` — message directory. Default `${XDG_STATE_HOME:-$HOME/.local/state}/agent-message` ([XDG Base Directory](https://specifications.freedesktop.org/basedir-spec/latest/) state location — append-only logs are textbook XDG state). Honored by both the slash commands and the `msg` shell function. Files inside: `log-<alias>.jsonl` (one per writer), `.seen-<reader>` (watermark: last-seen ts + ids-at-that-ts), `.mtime-<reader>` (mtime short-circuit cache).

## Limits

- **No auth.** Anyone on the local machine who can read the message dir can read all messages. Don't put secrets here.
- **No locking, but no interleave either.** Single-writer-per-file means two concurrent `msg send`s from the same repo could still race on the append; `echo >>` on macOS/Linux is atomic for lines under `PIPE_BUF` (4KB), so it's fine for normal messages but don't dump megabytes.
- **No notifications.** You pull inbox with `/message-inbox` or `msg`. For a tail-on-arrival feel, run `msg tail` in a spare terminal. New writer files appearing mid-tail aren't picked up — Ctrl-C and re-run.
- **Single machine, or sync via files.** If you want this across machines, sync the message dir (default `~/.local/state/agent-message/`) with Syncthing / Dropbox / iCloud Drive. Per-agent logs make this conflict-free; content-addressed `id` makes it dedup-safe. Two caveats: aliases must be unique per host (don't run alias `claude` on both your laptop and desktop with the same `$DIR` — that's two writers on one file), and exclude `.seen-*` / `.mtime-*` from sync (Syncthing `.stignore`, etc.) — they're local reader state.

## Docs

Live: <https://slima4.github.io/agent-message/>. Sources in [`docs/`](docs/) — install, use, design, [SAMP spec](SPEC.md), limits. Build locally with `pip install -r requirements-docs.txt && mkdocs serve`.

## Contributing

PRs welcome — read [`CONTRIBUTING.md`](CONTRIBUTING.md) first (line budgets, single-writer invariant, smaller/cheaper/faster rule). What's planned vs declined: [`ROADMAP.md`](ROADMAP.md). For non-trivial work, [open an issue](https://github.com/slima4/agent-message/issues/new/choose) first. See also [`SECURITY.md`](SECURITY.md) and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

MIT — see `LICENSE`.
