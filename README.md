# claude-message

Dead-simple cross-session messaging for Claude Code. No server, no MCP, no token, no daemon.

One shared JSONL file on disk. Three slash commands for Claude + one shell function for humans. That's it.

## Why

Running multiple Claude Code sessions (one per repo) and want them to talk without manual copy-paste? Existing solutions ([mcp_agent_mail](https://github.com/Dicklesworthstone/mcp_agent_mail), Agent Teams, broker daemons) run a Python HTTP server, maintain SQLite, register agent identities, require tokens, burn tokens on polling hooks, and can reject your names for format reasons. Overkill if you just want a handful of messages a day between your own sessions.

This project gives you the 90% at 1% of the cost: a local append-only JSONL file, three slash commands, basename-as-identity, no setup per repo. And the terminal path (`msg`) costs **0 Claude tokens** — humans never touch the model.

## Install

```bash
git clone https://github.com/slima4/claude-message && cd claude-message && ./install.sh
```

Installs:

- Three slash commands into `~/.claude/commands/` for Claude Code sessions.
- A `msg` shell function at `~/.claude-message.sh`, sourced from `~/.zshrc` / `~/.bashrc` so you can read/send from any terminal at **0 Claude tokens**.
- The shared mailbox at `~/dev/.message/messages.jsonl`.

Idempotent — safe to re-run. Open a new terminal after first install so the shell function loads.

Custom paths:

```bash
./install.sh --mailbox ~/shared/messages.jsonl --commands ~/.claude/commands --shell ~/.my-msg.sh
./install.sh --no-shell    # slash commands only
```

## Use

From any Claude Code session, in any repo under `~/dev/`:

```
# In repo "foo":
/message-send bar need your review on the schema change

# In repo "bar":
/message-inbox
  [04-24 17:42] from=foo thread=2026-04-24-need-your-review: need your review on…

/message-reply lgtm, merge when ready
```

From any terminal (**0 Claude tokens** — doesn't hit the model at all):

```
# In repo "foo":
$ msg send bar "need your review on the schema change"
sent foo→bar thread=2026-04-24-need-your-review

# In repo "bar":
$ msg
[04-24 17:42] from=foo thread=2026-04-24-need-your-review: need your review on…

$ msg reply "lgtm, merge when ready"
$ msg tail        # follow live in a spare pane — free push notifications
```

The sender alias is the basename of `$(pwd)`. So `/Users/you/dev/foo` → `foo`. Override per-repo by dropping a one-line `.claude-message` file at the repo root:

```
$ echo "my-short-name" > .claude-message
```

## How it works

Messages are JSONL lines in one shared file:

```json
{"ts": 1777040863, "from": "foo", "to": "bar", "thread": "2026-04-24-need-your-review", "body": "…"}
```

- `/message-send <to> <body>` (or `msg send <to> <body>`) — one `python3` + shell append
- `/message-inbox` (or `msg`) — read file, filter `to == me`, show messages newer than `~/dev/.message/.seen-<me>` watermark
- `/message-reply <body>` (or `msg reply <body>`) — find last message addressed to me, append reply with same `thread` and reversed `from`/`to`

No server. No network. No port. Works offline.

## Compared to the alternatives

| | claude-message | mcp_agent_mail | Agent Teams |
|---|---|---|---|
| runtime | append-only file | HTTP server, SQLite | Claude Code built-in |
| setup | 1 script | installer + LaunchAgent + token rotation + per-repo `.mcp.json` | opt-in env flag |
| identity | repo basename | curated adjective+noun, strict rules | team lead/teammate |
| cross-session | yes | yes | team only |
| tokens per send (Claude) | ~1 Bash call | MCP init + resource reads + tool call + ack poll | similar |
| tokens per send (shell) | **0** | n/a | n/a |
| passive polling | none | optional hook | automatic |
| web UI | `cat ~/dev/.message/messages.jsonl` | yes (`:8765/mail`) | none |
| audit trail | the file itself | Git-backed markdown | per-session |
| cost | ~0 | high | medium |

Pick claude-message when: you run 2–10 Claude Code sessions, message volume is low, you care about tokens more than features, you want to cat/grep/`tail -f` the log yourself.

Pick mcp_agent_mail when: you run many agents, want advisory file leases, threaded search, a web UI, and are OK with the token / setup cost.

## Browse history

```bash
# All messages
cat ~/dev/.message/messages.jsonl | jq .

# Thread
jq 'select(.thread == "2026-04-24-need-your-review")' ~/dev/.message/messages.jsonl

# Follow new messages as they arrive
tail -f ~/dev/.message/messages.jsonl | jq .

# Reset a repo's "seen" watermark so /message-inbox shows everything again
rm ~/dev/.message/.seen-<alias>
```

## Uninstall

```bash
./install.sh --uninstall
```

Removes the three slash commands, the shell helper, the mailbox file, and the `~/.zshrc` / `~/.bashrc` source block. Does not touch `.claude-message` files in your repos.

## Environment

- `CLAUDE_MESSAGE_PATH` — mailbox path. Default `$HOME/dev/.message/messages.jsonl`. Honored by both the slash commands and the `msg` shell function.

## Limits

- **No auth.** Anyone on the local machine who can read the mailbox file can read all messages. Don't put secrets here.
- **No locking.** Concurrent writers could in theory interleave lines; `echo >>` on macOS/Linux is atomic for lines under `PIPE_BUF` (4KB), so it's fine for normal messages but don't dump megabytes.
- **No notifications.** You pull inbox with `/message-inbox` or `msg`. For a tail-on-arrival feel, run `msg tail` in a spare terminal.
- **Single machine.** If you want this across machines, sync `~/dev/.message/` with Syncthing / Dropbox / iCloud Drive.

## License

MIT — see `LICENSE`.
