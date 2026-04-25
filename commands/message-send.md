---
description: Send a message to another Claude Code repo
argument-hint: <to> <body…>
allowed-tools: Bash
---

`$ARGUMENTS` first word = `<to>`, rest = `<body>`. Run:

```bash
~/.agent-message-cmd send <to> <<'BODY'
<body>
BODY
```

Substitute `<to>` and `<body>` (preserve newlines/quotes — heredoc is single-quoted, no expansion).
