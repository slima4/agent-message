# Limits

agent-message intentionally trades features for cost. Some honest caveats:

## No authentication

The message directory is a normal directory. Anyone on the local machine who can read it can read every message. Filesystem permissions are your only defence.

**Don't put secrets here.** Treat it as you would `~/.bash_history` or any other plaintext local log.

## No encryption

Same reasoning. If you need encryption, encrypt the body yourself before sending and decrypt after reading — the protocol is body-opaque.

## No locking, but no interleave either

Single-writer-per-file means two concurrent `msg send` calls from the same alias *could* race on the append. POSIX `O_APPEND` makes writes atomic up to `PIPE_BUF` (4 KiB on Linux/macOS), so normal-sized messages are fine. Don't dump megabytes.

## No delivery guarantees

Sender appends. Reader unions and filters. There is no ack, no retry, no delivery report. If the disk eats your file, the message is gone.

For most agent-to-agent coordination flows, this is fine — the next sync round picks up missed messages, or the sender resends.

## No notifications / push

You pull inbox with `/message-inbox`, `msg`, or `~/.agent-message-cmd inbox`. For a tail-on-arrival feel, run `msg tail` in a spare terminal. New writer files appearing mid-tail aren't picked up — Ctrl-C and re-run.

## Single machine, or sync via files

The protocol is file-based. There is no network transport. To run across machines, sync `~/dev/.message/` with Syncthing / Dropbox / iCloud Drive.

Per-agent logs make this conflict-free *by construction* (no file has two writers); content-addressed `id` makes it dedup-safe (the same record arriving via two paths is still one record to readers).

Consistency model: eventual. A message sent on one machine becomes visible on another whenever the sync layer catches up.

## No threading index

Threads are derived from the message header (`thread` field). There's no separate index. To find all messages in a thread:

```bash
~/.agent-message-cmd inbox raw | jq 'select(.thread == "2026-04-25-foo-…")'
# or:
msg raw all | jq 'select(.thread == "...")'
```

For high-volume threading workflows, this is the wrong tool — use `mcp_agent_mail`.

## No web UI

Cat / grep / `tail -F` / `jq` / `msg log` are the UI.

## Cross-platform

Tested on macOS and Linux. Windows is not supported (depends on POSIX `O_APPEND` semantics, `chmod`, and shell sourcing). WSL works.
