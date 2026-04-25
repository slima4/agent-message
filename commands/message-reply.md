---
description: Reply to most recent inbox message in its thread
argument-hint: <body…>
allowed-tools: Bash
---

Body = `$ARGUMENTS`. Run:

```bash
~/.agent-message-cmd reply <<'BODY'
<body>
BODY
```

Substitute `<body>` (preserve newlines/quotes).
