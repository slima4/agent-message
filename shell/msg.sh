# claude-message shell helper — 0 Claude tokens, human-side only.
# Source from ~/.zshrc or ~/.bashrc:
#   [ -f "$HOME/.claude-message.sh" ] && source "$HOME/.claude-message.sh"
#
# Usage:
#   msg send <to> <body...>    # append one message
#   msg reply <body...>        # reply to most recent inbox message
#   msg                # unseen messages (default); updates watermark
#   msg inbox          # same as above
#   msg all            # every message to this repo, no watermark change
#   msg tail           # follow new arrivals in real time
#   msg help
#
# Alias = `basename $PWD`, overridable via `.claude-message` first line at repo root.
# Mailbox = $CLAUDE_MESSAGE_PATH or $HOME/dev/.message/messages.jsonl.

msg() {
  local mbox="${CLAUDE_MESSAGE_PATH:-$HOME/dev/.message/messages.jsonl}"
  local me=""
  if [ -s .claude-message ]; then
    IFS= read -r me < .claude-message || me=""
    me=${me%$'\r'}
  fi
  [ -z "$me" ] && me=${PWD##*/}
  local cmd="${1:-new}"
  shift 2>/dev/null || true
  case "$cmd" in
    send)
      if [ $# -lt 2 ]; then echo "usage: msg send <to> <body...>" >&2; return 2; fi
      local to="$1"; shift
      MSG_ME="$me" MSG_TO="$to" MSG_BODY="$*" MSG_BOX="$mbox" python3 - <<'PY'
import json, os, time, re, datetime
me=os.environ["MSG_ME"]; to=os.environ["MSG_TO"]
body=os.environ["MSG_BODY"]; mbox=os.environ["MSG_BOX"]
m=re.match(r"\[thread:([^\]]+)\]\s*", body)
if m:
    thread=m.group(1); body=body[m.end():]
else:
    first=body.splitlines()[0] if body else ""
    slug=re.sub(r"[^a-z0-9]+", "-", first.lower()).strip("-")[:40] or "msg"
    thread=f"{datetime.date.today().isoformat()}-{slug}"
line=json.dumps({"ts":int(time.time()),"from":me,"to":to,"thread":thread,"body":body}, ensure_ascii=False)
with open(mbox, "a") as f:
    f.write(line+"\n")
print(f"sent {me}→{to} thread={thread}")
PY
      ;;
    reply)
      if [ $# -lt 1 ]; then echo "usage: msg reply <body...>" >&2; return 2; fi
      MSG_ME="$me" MSG_BODY="$*" MSG_BOX="$mbox" python3 - <<'PY'
import json, os, sys, time
me=os.environ["MSG_ME"]; body=os.environ["MSG_BODY"]; mbox=os.environ["MSG_BOX"]
try:
    lines=[json.loads(l) for l in open(mbox) if l.strip()]
except FileNotFoundError:
    sys.exit("no mailbox")
mine=[m for m in lines if m.get("to")==me]
if not mine: sys.exit("no inbox messages")
last=mine[-1]
reply={"ts":int(time.time()),"from":me,"to":last["from"],"thread":last["thread"],"body":body}
with open(mbox, "a") as f:
    f.write(json.dumps(reply, ensure_ascii=False)+"\n")
print(f"reply {me}→{last['from']} thread={last['thread']}")
PY
      ;;
    new|inbox|all)
      local mode=new
      [ "$cmd" = all ] && mode=all
      MSG_ME="$me" MSG_BOX="$mbox" MSG_MODE="$mode" python3 - <<'PY'
import json, os, time
from pathlib import Path
me=os.environ["MSG_ME"]; mbox=Path(os.environ["MSG_BOX"]); mode=os.environ["MSG_MODE"]
seen=mbox.parent / f".seen-{me}"
since=0
if mode=="new" and seen.exists():
    try: since=int(seen.read_text().strip())
    except: pass
try:
    msgs=[json.loads(l) for l in open(mbox) if l.strip()]
except FileNotFoundError:
    msgs=[]
mine=[m for m in msgs if m.get("to")==me and (mode!="new" or m.get("ts",0)>since)]
if not mine:
    print("no new messages" if mode=="new" else "no messages"); raise SystemExit
latest=since
for m in mine:
    ts=time.strftime("%m-%d %H:%M", time.localtime(m.get("ts",0)))
    body=m.get("body") or ""
    first=body.splitlines()[0][:80] if body else ""
    print(f"[{ts}] from={m['from']} thread={m['thread']}: {first}")
    latest=max(latest, m.get("ts",0))
if mode=="new" and latest>since:
    seen.write_text(str(latest))
PY
      ;;
    tail)
      [ -f "$mbox" ] || { echo "no mailbox at $mbox" >&2; return 1; }
      tail -n0 -f "$mbox" | MSG_ME="$me" python3 -u - <<'PY'
import json, os, sys, time
me=os.environ["MSG_ME"]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: m=json.loads(line)
    except json.JSONDecodeError: continue
    if m.get("to")!=me: continue
    ts=time.strftime("%m-%d %H:%M", time.localtime(m.get("ts",0)))
    body=m.get("body") or ""
    first=body.splitlines()[0][:80] if body else ""
    print(f"[{ts}] from={m['from']} thread={m['thread']}: {first}", flush=True)
PY
      ;;
    help|-h|--help)
      cat <<EOF
msg — claude-message shell helper

  msg                      show unseen (updates watermark)
  msg inbox                alias of default
  msg all                  every message to this repo
  msg send <to> <body>     append message
  msg reply <body>         reply to most recent inbox message
  msg tail                 follow new arrivals
  msg help

mailbox: \${CLAUDE_MESSAGE_PATH:-\$HOME/dev/.message/messages.jsonl}
alias:   \$(basename \$PWD), override via .claude-message file first line
EOF
      ;;
    *)
      echo "unknown subcommand: $cmd (try: msg help)" >&2
      return 1
      ;;
  esac
}
