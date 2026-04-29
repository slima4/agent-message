# shellcheck shell=bash
# agent-message shell helper -- 0 LLM tokens, human-side only.
# Source from ~/.zshrc or ~/.bashrc:
#   [ -f "$HOME/.agent-message.sh" ] && source "$HOME/.agent-message.sh"
#
# Usage:
#   msg send <to> <body...>    # append to your own per-agent log
#   msg reply <body...>        # reply to most recent inbox message
#   msg                # unseen messages (default); updates watermark
#   msg inbox          # same as above
#   msg all            # every message to this repo, no watermark change
#   msg tail           # follow new arrivals across all agent logs
#
# Plumbing (scriptable, humans):
#   msg cat <id|prefix>        # pretty-print one record by id (min 4 chars)
#   msg log [alias]            # git-log style, messages involving me (or alias)
#   msg raw [all]              # JSONL dump for `jq` / scripts
#   msg compact                # within-file dedup; ensures id populated
#
#   msg help
#
# Alias = `basename $PWD`, overridable via `.agent-message` first line at repo root.
# Message dir = $AGENT_MESSAGE_DIR or ${XDG_STATE_HOME:-$HOME/.local/state}/agent-message/. Each writer owns
# $DIR/log-<alias>.jsonl (single-writer, no interleave). Readers union across
# log-*.jsonl and dedup by content-addressed id.

msg() {
  local dir="${AGENT_MESSAGE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-message}"
  local me=""
  if [ -s .agent-message ]; then
    IFS= read -r me < .agent-message || me=""
    me=${me%$'\r'}
  fi
  [ -z "$me" ] && me=${PWD##*/}
  # §1 alias regex enforcement (must match Python wrapper's _ok())
  case "$me" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) me="unknown" ;; esac
  [ ${#me} -gt 64 ] && me="unknown"
  mkdir -p "$dir" 2>/dev/null
  local cmd="${1:-new}"
  shift 2>/dev/null || true
  case "$cmd" in
    send)
      if [ $# -lt 2 ]; then echo "usage: msg send <to> <body...>" >&2; return 2; fi
      local to="$1"; shift
      MSG_ME="$me" MSG_TO="$to" MSG_BODY="$*" MSG_DIR="$dir" python3 - <<'PY'
import json, os, time, re, datetime, hashlib, unicodedata
from pathlib import Path
me=os.environ["MSG_ME"]; to=os.environ["MSG_TO"]
body=unicodedata.normalize("NFC", os.environ["MSG_BODY"]); d=Path(os.environ["MSG_DIR"])
m=re.match(r"\s*\[thread:([^\]]+)\]\s*", body)
if m:
    thread=m.group(1).strip(); body=body[m.end():]
else:
    first=body.splitlines()[0] if body else ""
    slug=re.sub(r"[^a-z0-9]+", "-", first.lower()).strip("-")[:40] or "msg"
    thread=f"{datetime.datetime.now(datetime.timezone.utc).date().isoformat()}-{me}-{slug}"
ts=int(time.time())
core={"ts":ts,"from":me,"to":to,"thread":thread,"body":body}
mid=hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
rec={"id":mid, **core}
fd=os.open(d/f"log-{me}.jsonl", os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW, 0o644)
with os.fdopen(fd, "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False)+"\n")
print(f"sent {me}→{to} thread={thread} id={mid}")
PY
      ;;
    reply)
      if [ $# -lt 1 ]; then echo "usage: msg reply <body...>" >&2; return 2; fi
      MSG_ME="$me" MSG_BODY="$*" MSG_DIR="$dir" python3 - <<'PY'
import json, os, sys, time, hashlib, unicodedata
from pathlib import Path
me=os.environ["MSG_ME"]; body=unicodedata.normalize("NFC", os.environ["MSG_BODY"]); d=Path(os.environ["MSG_DIR"])
mine=[]
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    file_alias=lf.name[4:-6]
    with open(lf) as f:
        for line in f:
            line=line.strip()
            if not line: continue
            try: m=json.loads(line)
            except json.JSONDecodeError: continue
            if m.get("from")!=file_alias: continue
            if m.get("to")==me: mine.append(m)
if not mine: sys.exit("no inbox messages")
mine.sort(key=lambda m: m.get("ts",0))
last=mine[-1]
ts=int(time.time())
core={"ts":ts,"from":me,"to":last["from"],"thread":last["thread"],"body":body}
mid=hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
rec={"id":mid, **core}
fd=os.open(d/f"log-{me}.jsonl", os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW, 0o644)
with os.fdopen(fd, "a") as f:
    f.write(json.dumps(rec, ensure_ascii=False)+"\n")
print(f"reply {me}→{last['from']} thread={last['thread']} id={mid}")
PY
      ;;
    new|inbox|all)
      local mode=new
      [ "$cmd" = all ] && mode=all
      MSG_ME="$me" MSG_DIR="$dir" MSG_MODE="$mode" python3 - <<'PY'
import json, os, time, hashlib, unicodedata
from pathlib import Path
me=os.environ["MSG_ME"]; d=Path(os.environ["MSG_DIR"]); mode=os.environ["MSG_MODE"]
log_paths=[p for p in sorted(d.glob("log-*.jsonl")) if not p.is_symlink()]
def aw(p, s):
    t=p.with_suffix(".tmp"); t.write_text(s); os.replace(str(t), str(p))
# mtime short-circuit — skip parse entirely if nothing observable changed.
mtime_file=d/f".mtime-{me}"
seen_file=d/f".seen-{me}"
cur_max=max((p.stat().st_mtime for p in log_paths), default=0.0)
cur_count=len(log_paths)
# Only short-circuit if seen_file also exists; otherwise user may have deleted it to force re-read.
if mode=="new" and mtime_file.exists() and seen_file.exists():
    try:
        c=json.loads(mtime_file.read_text())
        if c.get("max_mtime",0) >= cur_max and c.get("files",0) == cur_count:
            print("no new messages"); raise SystemExit
    except json.JSONDecodeError:
        pass
since=0; since_ids=set()
if mode=="new" and seen_file.exists():
    try:
        c=json.loads(seen_file.read_text())
        since=c.get("ts",0); since_ids=set(c.get("ids",[]))
    except json.JSONDecodeError:
        pass
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
seen_ids=set()
msgs=[]
for lf in log_paths:
    file_alias=lf.name[4:-6]
    with open(lf) as f:
        for line in f:
            line=line.strip()
            if not line: continue
            try: m=json.loads(line)
            except json.JSONDecodeError: continue
            if m.get("from")!=file_alias: continue
            if m.get("to")!=me: continue
            mid=m.get("id") or cid(m)
            if mid in seen_ids: continue
            seen_ids.add(mid)
            t=m.get("ts",0)
            # Watermark: strictly past, or equal-ts but already in prior-run ids-at-max-ts.
            # Handles same-second messages (1s clock resolution) without re-showing.
            if mode=="new" and (t<since or (t==since and mid in since_ids)): continue
            m["_id"]=mid
            msgs.append(m)
msgs.sort(key=lambda m: m.get("ts",0))
if not msgs:
    print("no new messages" if mode=="new" else "no messages")
    if mode=="new":
        aw(mtime_file, json.dumps({"max_mtime":cur_max,"files":cur_count}))
    raise SystemExit
for m in msgs:
    ts=time.strftime("%m-%d %H:%M", time.localtime(m.get("ts",0)))
    body=m.get("body") or ""
    first=body.splitlines()[0][:80] if body else ""
    print(f"[{ts}] from={m['from']} thread={m['thread']}: {first}")
if mode=="new":
    new_max=max(m.get("ts",0) for m in msgs)
    # Accumulate ids at max-ts across old + new so we don't lose prior state
    # if nothing newer arrived between runs.
    new_ids=[m["_id"] for m in msgs if m.get("ts",0)==new_max]
    if new_max==since:
        new_ids=sorted(since_ids | set(new_ids))
    aw(seen_file, json.dumps({"ts":new_max,"ids":list(new_ids)}))
    aw(mtime_file, json.dumps({"max_mtime":cur_max,"files":cur_count}))
PY
      ;;
    tail)
      local logs=() f
      for f in "$dir"/log-*.jsonl; do
        [ -f "$f" ] && [ ! -L "$f" ] && logs+=("$f")
      done
      if [ ${#logs[@]} -eq 0 ]; then
        echo "no logs in $dir yet -- nothing to follow" >&2
        return 1
      fi
      # python3 -c keeps stdin free for the pipe from tail (heredoc would shadow it).
      tail -n0 -F "${logs[@]}" 2>/dev/null | MSG_ME="$me" python3 -u -c '
import json, os, sys, time
me=os.environ["MSG_ME"]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    # tail -F emits "==> file <==" headers on file switch; skip them.
    if line.startswith("==>") and line.endswith("<=="): continue
    try: m=json.loads(line)
    except json.JSONDecodeError: continue
    if m.get("to")!=me: continue
    ts=time.strftime("%m-%d %H:%M", time.localtime(m.get("ts",0)))
    body=m.get("body") or ""
    first=body.splitlines()[0][:80] if body else ""
    print(f"[{ts}] from={m[\"from\"]} thread={m[\"thread\"]}: {first}", flush=True)
'
      ;;
    cat)
      if [ $# -lt 1 ]; then echo "usage: msg cat <id|prefix>" >&2; return 2; fi
      MSG_ID="$1" MSG_DIR="$dir" python3 - <<'PY'
import json, os, sys, hashlib, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"]); needle=os.environ["MSG_ID"]
# 4-char min prevents trivial prefixes returning near-everything; full id is 16.
if len(needle) < 4:
    sys.exit("id prefix must be at least 4 chars")
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
hits=[]; seen=set()
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    file_alias=lf.name[4:-6]
    with open(lf) as f:
        for ln in f:
            ln=ln.strip()
            if not ln: continue
            try: m=json.loads(ln)
            except json.JSONDecodeError: continue
            if m.get("from")!=file_alias: continue
            i=m.get("id") or cid(m)
            if i in seen: continue
            seen.add(i)
            if i.startswith(needle): hits.append((i, m))
if not hits: sys.exit(f"no message with id starting with {needle!r}")
exact=[(i,m) for i,m in hits if i==needle]
if exact:
    print(json.dumps(exact[0][1], ensure_ascii=False, indent=2))
elif len(hits) > 1:
    print("multiple matches:", file=sys.stderr)
    for i,_ in hits[:10]:
        print(f"  {i}", file=sys.stderr)
    if len(hits) > 10:
        print(f"  … and {len(hits)-10} more", file=sys.stderr)
    sys.exit(1)
else:
    print(json.dumps(hits[0][1], ensure_ascii=False, indent=2))
PY
      ;;
    log)
      local who="${1:-$me}"
      MSG_WHO="$who" MSG_DIR="$dir" python3 - <<'PY'
import json, os, time, hashlib, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"]); who=os.environ["MSG_WHO"]
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
seen=set(); msgs=[]
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    file_alias=lf.name[4:-6]
    with open(lf) as f:
        for ln in f:
            ln=ln.strip()
            if not ln: continue
            try: m=json.loads(ln)
            except json.JSONDecodeError: continue
            if m.get("from")!=file_alias: continue
            i=m.get("id") or cid(m)
            if i in seen: continue
            seen.add(i)
            if who and who not in (m.get("from"), m.get("to")): continue
            m["_id"]=i; msgs.append(m)
msgs.sort(key=lambda m: m.get("ts",0), reverse=True)
for m in msgs:
    ts=time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(m.get("ts",0)))
    print(f"id     {m['_id']}")
    print(f"from   {m.get('from')} → {m.get('to')}")
    print(f"ts     {ts}")
    print(f"thread {m.get('thread')}")
    print()
    for line in (m.get("body") or "").splitlines() or [""]:
        print(f"    {line}")
    print()
PY
      ;;
    raw)
      local only_me=1
      if [ $# -gt 0 ]; then
        if [ "$1" = all ]; then only_me=0
        else echo "usage: msg raw [all]" >&2; return 2
        fi
      fi
      MSG_ME="$me" MSG_ONLY_ME="$only_me" MSG_DIR="$dir" python3 - <<'PY'
import json, os, hashlib, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"]); me=os.environ["MSG_ME"]; only_me=os.environ["MSG_ONLY_ME"]=="1"
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
seen=set()
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    file_alias=lf.name[4:-6]
    with open(lf) as f:
        for ln in f:
            ln=ln.strip()
            if not ln: continue
            try: m=json.loads(ln)
            except json.JSONDecodeError: continue
            if m.get("from")!=file_alias: continue
            i=m.get("id") or cid(m)
            if i in seen: continue
            seen.add(i)
            if only_me and m.get("to")!=me: continue
            print(json.dumps(m, ensure_ascii=False))
PY
      ;;
    compact)
      MSG_DIR="$dir" python3 - <<'PY'
import json, os, hashlib, shutil, tempfile, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"])
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
before=0; after=0; touched=0; added_ids=0
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    with open(lf) as f:
        orig=[ln.strip() for ln in f if ln.strip()]
    before += len(orig)
    seen_here=set(); keep=[]; mutated=False
    for ln in orig:
        try: m=json.loads(ln)
        except json.JSONDecodeError: continue
        i=m.get("id") or cid(m)
        if i in seen_here: continue
        seen_here.add(i)
        if "id" not in m:
            m={"id": i, **m}
            mutated=True; added_ids += 1
        keep.append(json.dumps(m, ensure_ascii=False))
    after += len(keep)
    if len(keep) != len(orig) or mutated:
        touched += 1
        tmp=tempfile.NamedTemporaryFile(mode="w", dir=str(d), delete=False)
        try:
            tmp.writelines(k+"\n" for k in keep)
            tmp.close()
            # Preserve the original log's permissions (NamedTemporaryFile defaults
            # to 0600, which would otherwise regress the 0644 that `send` writes).
            shutil.copymode(str(lf), tmp.name)
            os.replace(tmp.name, str(lf))
        except BaseException:
            # Interrupt / error mid-write: clean up the temp so it doesn't linger.
            try: os.unlink(tmp.name)
            except OSError: pass
            raise
extra = f", filled id on {added_ids} legacy record(s)" if added_ids else ""
print(f"compacted: {before} → {after} records ({touched} file(s) rewritten{extra})")
PY
      ;;
    --version|-V|version)
      echo "msg 1.0.0 (SAMP v1)"
      ;;
    help|-h|--help)
      cat <<EOF
msg — agent-message shell helper

Porcelain:
  msg                      show unseen (updates watermark)
  msg inbox                alias of default
  msg all                  every message to this repo
  msg send <to> <body>     append to your per-agent log
  msg reply <body>         reply to most recent inbox message
  msg tail                 follow new arrivals (existing logs at start time)

Plumbing:
  msg cat <id|prefix>      pretty-print one record (min 4-char prefix)
  msg log [alias]          git-log style; all messages involving me (or alias)
  msg raw [all]            JSONL dump for jq / scripts
  msg compact              within-file dedup; ensures id populated

  msg help
  msg --version

dir:    \${AGENT_MESSAGE_DIR:-\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-message}
files:  \$DIR/log-<alias>.jsonl  (single-writer, union on read)
alias:  \$(basename \$PWD), override via .agent-message file first line
EOF
      ;;
    *)
      echo "unknown subcommand: $cmd (try: msg help)" >&2
      return 1
      ;;
  esac
}
