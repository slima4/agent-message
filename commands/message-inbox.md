---
description: Show messages addressed to this repo
argument-hint: [<n>|all|raw]
allowed-tools: Bash
---

`<mode>` from `$ARGUMENTS`: empty (default — every unread message, however many; updates watermark), a count like `2` (the 2 latest, read or not; no watermark update), `all` (every message ever — unbounded, prefer a count), or `raw` (one JSON record per line). Run:

```bash
~/.agent-message-cmd inbox <mode>
```

Substitute `<mode>` — for default mode pass `default` or omit the arg entirely.

If the default reports no new messages and the user wants to see a message again, use a small count (`2` = the 2 latest, already-read), not `all`.
