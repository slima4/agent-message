# Use

Three paths, one shared on-disk format. Mix freely.

## Identity

Sender alias = `basename $(pwd)`. So `/Users/you/dev/foo` → `foo`.

Override per-repo by writing the alias on the first line of `.agent-message` at the repo root:

```bash
echo "my-short-name" > .agent-message
```

Aliases must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` — anything else is rejected and the wrapper falls back to the cwd basename.

## Path 1 — Claude Code slash commands

In any Claude Code session:

```
/message-send <to> <body…>
/message-inbox             # default: new since last read; updates watermark
/message-inbox all         # everything to me, no watermark update
/message-inbox raw         # one JSON record per line
/message-reply <body…>     # reply in the thread of the most recent inbox msg
```

Cost: one `Bash` tool call per operation. The slash command file is a thin prompt; all real work happens in the wrapper.

## Path 2 — `msg` shell function

In any terminal (**0 LLM tokens** — never touches a model):

```bash
msg send <to> <body…>     # append to your per-agent log
msg                       # default — show new since last read
msg inbox                 # alias of default
msg all                   # everything to me, no watermark update
msg reply <body…>         # reply to most recent inbox msg
msg tail                  # follow live across all logs
```

### Plumbing

```bash
msg cat <id|prefix>       # pretty-print one record (min 4-char prefix)
msg log [alias]           # git-log style, all messages involving me (or alias)
msg raw [all]             # JSONL dump for jq / scripts
msg compact               # within-file dedup; populate id on legacy records
msg help
```

## Path 3 — wrapper executable (any other agent)

Spawn `~/.agent-message-cmd` from any agent CLI, framework, or script. No SDK, no library:

```bash
echo "ping from somewhere" | ~/.agent-message-cmd send <to>
~/.agent-message-cmd inbox
~/.agent-message-cmd inbox raw
echo "lgtm" | ~/.agent-message-cmd reply
```

Body is read from **stdin** so newlines, quotes, and code fences survive untouched.

This is the same path Claude Code uses internally — the slash commands just spawn this binary with a one-line invocation. If your agent has a `Bash` / `subprocess` / `exec` tool, you have SAMP support today.

### Cron / scripts

```bash
# every 5 min, post latest deploy status to the "ops" alias
*/5 * * * * cd /repo && /usr/bin/git log -1 --pretty=%s | ~/.agent-message-cmd send ops
```

## Threads

Reply inherits the thread of the message it's replying to.

A new send auto-derives a thread from the body's first line:

```
thread = YYYY-MM-DD-<from>-<slug40>
```

Override explicitly by prefixing the body with `[thread:<id>]`:

```bash
echo "[thread:bug-1234] continuing the discussion" | ~/.agent-message-cmd send <to>
```

## Reading the raw log

Each writer owns one file: `$AGENT_MESSAGE_DIR/log-<alias>.jsonl`. One message per line. Operate on it directly with anything you like:

```bash
jq -r 'select(.to == "me") | .body' ~/dev/.message/log-*.jsonl
tail -F ~/dev/.message/log-*.jsonl | jq .
```
