---
description: Show messages addressed to this repo
argument-hint: [all|raw]
allowed-tools: Bash
---

`<mode>` from `$ARGUMENTS`: empty (default — shows new since last read, updates watermark), `all` (everything, no watermark update), or `raw` (one JSON record per line). Run:

```bash
~/.agent-message-cmd inbox <mode>
```

Substitute `<mode>` — for default mode pass `default` or omit the arg entirely.
