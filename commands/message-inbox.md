---
description: Show messages addressed to this repo from the shared JSONL mailbox
argument-hint: [all|raw]
allowed-tools: Bash
---

`<mode>` from `$ARGUMENTS`: `default` (empty), `all`, or `raw`. `<me>`: `.claude-message` line 1 or `basename $(pwd)`. `default` uses + updates watermark; `all`/`raw` don't.

One Bash call:

```bash
python3 - <<'PY'
import json, os, time
from pathlib import Path
ME, MODE = "<me>", "<mode>"
mb = Path(os.environ.get("CLAUDE_MESSAGE_PATH", str(Path.home()/"dev"/".message"/"messages.jsonl")))
seen = mb.parent / f".seen-{ME}"
since = int(seen.read_text().strip()) if MODE=="default" and seen.exists() else 0
msgs = [json.loads(l) for l in mb.read_text().splitlines() if l.strip()] if mb.exists() else []
mine = [m for m in msgs if m.get("to")==ME and (MODE!="default" or m.get("ts",0)>since)]
if not mine:
    print("no new messages" if MODE=="default" else "no messages"); raise SystemExit
if MODE=="raw":
    for m in mine: print(json.dumps(m, ensure_ascii=False))
    raise SystemExit
for m in mine:
    t = time.strftime("%m-%d %H:%M", time.localtime(m.get("ts",0)))
    first = (m.get("body") or "").splitlines()[0][:80] if m.get("body") else ""
    print(f"[{t}] from={m['from']} thread={m['thread']}: {first}")
if MODE=="default": seen.write_text(str(max(m["ts"] for m in mine)))
PY
```

Substitute `<me>/<mode>`. End with: `N new from: <from1>, …`. Suggest `/message-reply <body>`.
