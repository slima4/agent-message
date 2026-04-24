---
description: Append a message to the shared JSONL mailbox for another repo
argument-hint: <to> <body…>
allowed-tools: Bash
---

Args: `$ARGUMENTS`. First word = `<to>`, rest = `<body>`. `<from>`: `.claude-message` line 1 or `basename $(pwd)`. `<thread>`: `<id>` from leading `[thread:<id>]` (strip prefix from body), else `YYYY-MM-DD-<slug40>` from body's first line (lowercase, non-alphanumeric → `-`, trim 40).

One Bash call:

```bash
python3 - <<'PY' >> "${CLAUDE_MESSAGE_PATH:-$HOME/dev/.message/messages.jsonl}"
import json, time
print(json.dumps({"ts":int(time.time()),"from":"<from>","to":"<to>","thread":"<thread>","body":"""<body>"""}, ensure_ascii=False))
PY
```

Substitute `<from>/<to>/<thread>/<body>`. Keep the `"""…"""` so newlines/quotes survive.

Report: `sent <from>→<to> thread=<thread>`.
