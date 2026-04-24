---
description: Reply in the thread of the most recent inbox message
argument-hint: <body…>
allowed-tools: Bash
---

Body = `$ARGUMENTS`. `<me>`: `.claude-message` line 1 or `basename $(pwd)`.

One Bash call:

```bash
python3 - <<'PY' >> "${CLAUDE_MESSAGE_PATH:-$HOME/dev/.message/messages.jsonl}"
import json, os, time
from pathlib import Path
ME = "<me>"; BODY = """<body>"""
mb = Path(os.environ.get("CLAUDE_MESSAGE_PATH", str(Path.home()/"dev"/".message"/"messages.jsonl")))
msgs = [json.loads(l) for l in mb.read_text().splitlines() if l.strip()]
mine = [m for m in msgs if m.get("to")==ME]
if not mine: raise SystemExit("no inbox messages to reply to")
last = mine[-1]
print(json.dumps({"ts":int(time.time()),"from":ME,"to":last["from"],"thread":last["thread"],"body":BODY}, ensure_ascii=False))
PY
```

Substitute `<me>/<body>`. Keep the triple-quotes.

Report: `reply <me>→<to> thread=<thread>`.
