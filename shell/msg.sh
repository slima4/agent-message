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
#   msg <n>            # the n latest, read or not; no watermark change (msg 2)
#   msg all            # every message to this repo, no watermark change
#   msg tail           # follow new arrivals across all agent logs
#
# Plumbing (scriptable, humans):
#   msg cat <id|prefix>        # pretty-print one record by id (min 4 chars)
#   msg log [alias]            # git-log style, messages involving me (or alias)
#   msg raw [all]              # JSONL dump for `jq` / scripts
#   msg compact                # dedup own log; ensures id populated
#
#   msg help
#
# Alias = `basename $PWD`, overridable via `.agent-message` (first valid line) at repo root.
# Message dir = $AGENT_MESSAGE_DIR or ${XDG_STATE_HOME:-$HOME/.local/state}/agent-message/. Each writer owns
# $DIR/log-<alias>.jsonl (single-writer, no interleave). Readers union across
# log-*.jsonl and dedup by (from, content-addressed id).

msg() {
  local dir="${AGENT_MESSAGE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-message}"
  local me="" line
  # Mirrors the wrapper's me(): scan lines, strip whitespace, first line passing
  # the §1 regex wins; anything else falls back to cwd basename.
  if [ -f .agent-message ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      case "$line" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) continue ;; esac
      [ ${#line} -le 64 ] || continue
      me="$line"; break
    done < .agent-message
  fi
  [ -z "$me" ] && me=${PWD##*/}
  # §1 alias regex enforcement (must match Python wrapper's _ok())
  case "$me" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) me="unknown" ;; esac
  [ ${#me} -gt 64 ] && me="unknown"
  mkdir -p "$dir" 2>/dev/null
  local cmd="${1:-new}"
  shift 2>/dev/null || true
  # Numeric subcommand = bounded re-read (git log -2): the n latest, read or not.
  local last=0
  case "$cmd" in
    ''|*[!0-9]*) ;;
    *) if [ "$cmd" -lt 1 ] 2>/dev/null; then echo "msg <n>: count must be >= 1" >&2; return 2; fi
       last="$cmd"; cmd=all ;;
  esac
  case "$cmd" in
    send)
      if [ $# -lt 2 ]; then echo "usage: msg send <to> <body...>" >&2; return 2; fi
      local to="$1"; shift
      case "$to" in ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) echo "msg send: recipient alias '$to' fails SAMP §1 alias regex" >&2; return 2 ;; esac
      if [ ${#to} -gt 64 ]; then echo "msg send: recipient alias '$to' fails SAMP §1 alias regex" >&2; return 2; fi
      MSG_ME="$me" MSG_TO="$to" MSG_BODY="$*" MSG_DIR="$dir" python3 - <<'PY'
import json, os, time, re, datetime, hashlib, unicodedata
from pathlib import Path
me=os.environ["MSG_ME"]; to=os.environ["MSG_TO"]
body=unicodedata.normalize("NFC", os.environ["MSG_BODY"]); d=Path(os.environ["MSG_DIR"])
m=re.match(r"\s*\[thread:([^\]]+)\]\s*", body)
thread=""
if m:
    # Control chars stripped; empty result falls through to auto-derive.
    # Must match bin/agent-message-cmd thread_of() exactly (id parity).
    thread=re.sub(r"[\x00-\x1f\x7f]", "", m.group(1)).strip(); body=body[m.end():]
if not thread:
    first=body.splitlines()[0] if body else ""
    slug=re.sub(r"[^a-z0-9]+", "-", first.lower()).strip("-")[:40] or "msg"
    thread=f"{datetime.datetime.now(datetime.timezone.utc).date().isoformat()}-{me}-{slug}"
ts=int(time.time())
core={"ts":ts,"from":me,"to":to,"thread":thread,"body":body}
mid=hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
rec={"id":mid, **core}
fd=os.open(d/f"log-{me}.jsonl", os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW, 0o644)
with os.fdopen(fd, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False)+"\n")
print(f"sent {me}→{to} thread={thread} id={mid}")
PY
      ;;
    reply)
      if [ $# -lt 1 ]; then echo "usage: msg reply <body...>" >&2; return 2; fi
      MSG_ME="$me" MSG_BODY="$*" MSG_DIR="$dir" python3 - <<'PY'
import json, os, re, sys, time, hashlib, unicodedata
from pathlib import Path
me=os.environ["MSG_ME"]; body=unicodedata.normalize("NFC", os.environ["MSG_BODY"]); d=Path(os.environ["MSG_DIR"])
A=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
S=lambda s: re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", s)
mine=[]
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    file_alias=lf.name[4:-6]
    if not A.match(file_alias): continue
    with open(lf, encoding="utf-8", errors="replace") as f:
        for line in f:
            line=line.strip()
            if not line: continue
            try: m=json.loads(line)
            except json.JSONDecodeError: continue
            if not (isinstance(m, dict) and isinstance(m.get("ts"),(int,float)) and all(isinstance(m.get(k),str) for k in ("from","to","thread","body"))): continue
            if m["from"]!=file_alias: continue
            if m["to"]==me: mine.append(m)
if not mine: sys.exit("no inbox messages")
newest_ts=max(m["ts"] for m in mine)
newest=[m for m in mine if m["ts"]==newest_ts]
# Only a cross-sender tie is unrecoverable (§5 single-writer log = arrival order).
targets={m["from"]:m for m in newest}
if len(targets)>1:
    lines=[f"reply: {len(targets)} senders tie at newest ts={newest_ts}; refusing ambiguous reply"]
    for frm,m in sorted(targets.items()):
        first=S(m["body"].splitlines()[0][:80]) if m["body"] else ""
        lines.append(f"  {frm}  [thread:{S(m['thread'])}]  {first}")
    lines.append('pick one: msg send <alias> "[thread:...] <body>" using a [thread:...] above')
    sys.exit("\n".join(lines))
last=newest[-1]
ts=int(time.time())
core={"ts":ts,"from":me,"to":last["from"],"thread":last["thread"],"body":body}
mid=hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
rec={"id":mid, **core}
fd=os.open(d/f"log-{me}.jsonl", os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW, 0o644)
with os.fdopen(fd, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False)+"\n")
print(f"reply {me}→{last['from']} thread={S(last['thread'])} id={mid}")
PY
      ;;
    new|inbox|all)
      local mode=new
      [ "$cmd" = all ] && mode=all
      MSG_ME="$me" MSG_DIR="$dir" MSG_MODE="$mode" MSG_LAST="$last" python3 - <<'PY'
import json, os, re, time, hashlib, unicodedata
from pathlib import Path
me=os.environ["MSG_ME"]; d=Path(os.environ["MSG_DIR"]); mode=os.environ["MSG_MODE"]
last=int(os.environ.get("MSG_LAST","0"))
A=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
S=lambda s: re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", s)
# Body chars printed per run — bounds a huge record from flooding the terminal.
# Every elision is announced; a silently truncated body reads as an empty one.
BUDGET=8000
log_paths=[p for p in sorted(d.glob("log-*.jsonl")) if not p.is_symlink()]
def aw(p, s):
    # with_name (not with_suffix): dotted aliases like "host.local" must not collapse
    # to ".seen-host.tmp". pid suffix: concurrent readers must not share a tmp.
    t=p.with_name(f"{p.name}.{os.getpid()}.tmp"); t.write_text(s, encoding="utf-8"); os.replace(str(t), str(p))
# mtime short-circuit — skip parse entirely if nothing observable changed.
# Size is the third signal: same-tick appends and sync deliveries preserving an
# older sender mtime are invisible to (mtime, count) alone.
mtime_file=d/f".mtime-{me}"
seen_file=d/f".seen-{me}"
stats=[p.stat() for p in log_paths]
cur_max=max((s.st_mtime for s in stats), default=0.0)
cur_count=len(stats)
cur_size=sum(s.st_size for s in stats)
now=int(time.time())
# Only short-circuit if seen_file also exists; otherwise user may have deleted it to force re-read.
if mode=="new" and mtime_file.exists() and seen_file.exists():
    try:
        c=json.loads(mtime_file.read_text(encoding="utf-8"))
        if c.get("max_mtime",0) >= cur_max and c.get("files",0) == cur_count and c.get("size",-1) == cur_size:
            print(f"no new messages (as {me})"); raise SystemExit
    except ValueError:
        pass
since=0; since_ids=set()
if mode=="new" and seen_file.exists():
    try:
        c=json.loads(seen_file.read_text(encoding="utf-8"))
        # Cap at local now: self-heals a watermark pushed into the future.
        since=min(c.get("ts",0), now); since_ids=set(c.get("ids",[]))
    except ValueError:
        pass
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
seen=set()
msgs=[]; allm=[]
for lf in log_paths:
    file_alias=lf.name[4:-6]
    if not A.match(file_alias): continue
    with open(lf, encoding="utf-8", errors="replace") as f:
        for line in f:
            line=line.strip()
            if not line: continue
            try: m=json.loads(line)
            except json.JSONDecodeError: continue
            # One malformed foreign record must not brick the reader: require §2 types.
            if not (isinstance(m, dict) and isinstance(m.get("ts"),(int,float)) and all(isinstance(m.get(k),str) for k in ("from","to","thread","body"))): continue
            if m["from"]!=file_alias: continue
            if m["to"]!=me: continue
            mid=m.get("id")
            if not (isinstance(mid,str) and mid): mid=cid(m)
            # Dedup scoped by sender: a forged id in another writer's log must not
            # suppress the genuine record.
            if (file_alias, mid) in seen: continue
            seen.add((file_alias, mid))
            t=m["ts"]; k=f"{m['from']}:{mid}"
            allm.append((k, t))
            # Watermark: strictly past, or already-shown id (ids cover every shown
            # record with ts >= the clock-capped watermark).
            if mode=="new" and (t<since or k in since_ids): continue
            m["_k"]=k; m["_id"]=mid
            msgs.append(m)
msgs.sort(key=lambda m: m["ts"])
total=len(msgs)
if last: msgs=msgs[-last:]
if not msgs:
    print(f"{'no new messages' if mode=='new' else 'no messages'} (as {me})")
    if mode=="new":
        aw(mtime_file, json.dumps({"max_mtime":cur_max,"files":cur_count,"size":cur_size}))
    raise SystemExit
# Bodies in both modes: `all` is the re-read mode, and re-reading is exactly when
# the body is wanted. The budget bounds the output, not the mode.
bodies=[S(m["body"]).strip("\n") for m in msgs]
full=set(); left=BUDGET
for x in range(len(msgs)-1, -1, -1):  # newest first — the budget should buy the newest
    if len(bodies[x])<=left: left-=len(bodies[x]); full.add(x)
for n, m in enumerate(msgs):
    ts=time.strftime("%m-%d %H:%M", time.localtime(m["ts"]))
    print(f"[{ts}] from={m['from']} id={m['_id'][:8]} thread={S(m['thread'])}:")
    body=bodies[n]
    shown=body if n in full else (body.splitlines()[0][:80].rstrip() if body else "")
    # Every body line indented: a body mimicking a header line can't impersonate one.
    for ln in (shown.splitlines() or ["(empty)"]): print("  "+ln if ln else "")
    if len(shown)<len(body): print(f"  … +{len(body)-len(shown)} chars elided — msg cat {m['_id'][:8]}")
senders=sorted({m["from"] for m in msgs})
# "new" only in default: all re-reads already-seen messages, none of them new.
# A bounded re-read says what it withheld, same rule as body elision.
lbl=f"{len(msgs)} of {total}" if last else f"{len(msgs)} {'new' if mode=='new' else 'total'}"
print(f"{lbl} from: {', '.join(senders)} (as {me})")
if mode=="new":
    # Watermark capped at local now so a fast-clock sender can't advance it past
    # honest senders; ids carry every shown record with ts >= the cap.
    shown={m["_k"] for m in msgs}
    new_since=min(now, max(m["ts"] for m in msgs))
    new_ids=sorted(k for k,t in allm if t>=new_since and (k in shown or k in since_ids))
    aw(seen_file, json.dumps({"ts":new_since,"ids":new_ids}))
    aw(mtime_file, json.dumps({"max_mtime":cur_max,"files":cur_count,"size":cur_size}))
PY
      ;;
    tail)
      local logs=() f alias0=""
      for f in "$dir"/log-*.jsonl; do
        [ -f "$f" ] && [ ! -L "$f" ] && logs+=("$f")
      done
      if [ ${#logs[@]} -eq 0 ]; then
        echo "no logs in $dir yet -- nothing to follow" >&2
        return 1
      fi
      # tail emits no "==> file <==" headers for a single file: seed the alias.
      if [ ${#logs[@]} -eq 1 ]; then
        alias0=${logs[0]##*/}; alias0=${alias0#log-}; alias0=${alias0%.jsonl}
      fi
      # python3 -c keeps stdin free for the pipe from tail (heredoc would shadow it).
      tail -n0 -F "${logs[@]}" 2>/dev/null | MSG_ME="$me" MSG_ALIAS0="$alias0" python3 -u -c '
import json, os, re, sys, time
me=os.environ["MSG_ME"]
A=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
S=lambda s: re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", s)
alias=os.environ.get("MSG_ALIAS0") or None
seen=set()
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    # tail -F emits "==> path <==" headers on file switch; use them to attribute
    # each record to its source log for the §5 from==file_alias check.
    if line.startswith("==>") and line.endswith("<=="):
        n=os.path.basename(line[3:-3].strip())
        alias=n[4:-6] if n.startswith("log-") and n.endswith(".jsonl") else None
        continue
    try: m=json.loads(line)
    except json.JSONDecodeError: continue
    if not (isinstance(m, dict) and isinstance(m.get("ts"),(int,float)) and all(isinstance(m.get(k),str) for k in ("from","to","thread","body"))): continue
    if alias is None or not A.match(alias): continue
    if m["from"]!=alias: continue
    if m["to"]!=me: continue
    mid=m.get("id")
    k=(m["from"], mid if isinstance(mid,str) else "")
    if k[1]:
        if k in seen: continue
        seen.add(k)
    ts=time.strftime("%m-%d %H:%M", time.localtime(m["ts"]))
    first=S(m["body"].splitlines()[0][:80]) if m["body"] else ""
    frm=m["from"]; th=S(m["thread"])
    print(f"[{ts}] from={frm} thread={th}: {first}", flush=True)
'
      ;;
    cat)
      if [ $# -lt 1 ]; then echo "usage: msg cat <id|prefix>" >&2; return 2; fi
      MSG_ID="$1" MSG_DIR="$dir" python3 - <<'PY'
import json, os, re, sys, hashlib, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"]); needle=os.environ["MSG_ID"]
A=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
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
    if not A.match(file_alias): continue
    with open(lf, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln=ln.strip()
            if not ln: continue
            try: m=json.loads(ln)
            except json.JSONDecodeError: continue
            if not (isinstance(m, dict) and isinstance(m.get("ts"),(int,float)) and all(isinstance(m.get(k),str) for k in ("from","to","thread","body"))): continue
            if m["from"]!=file_alias: continue
            i=m.get("id")
            if not (isinstance(i,str) and i): i=cid(m)
            if (file_alias, i) in seen: continue
            seen.add((file_alias, i))
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
import json, os, re, time, hashlib, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"]); who=os.environ["MSG_WHO"]
A=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
S=lambda s: re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", s)
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
seen=set(); msgs=[]
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    file_alias=lf.name[4:-6]
    if not A.match(file_alias): continue
    with open(lf, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln=ln.strip()
            if not ln: continue
            try: m=json.loads(ln)
            except json.JSONDecodeError: continue
            if not (isinstance(m, dict) and isinstance(m.get("ts"),(int,float)) and all(isinstance(m.get(k),str) for k in ("from","to","thread","body"))): continue
            if m["from"]!=file_alias: continue
            i=m.get("id")
            if not (isinstance(i,str) and i): i=cid(m)
            if (file_alias, i) in seen: continue
            seen.add((file_alias, i))
            if who and who not in (m["from"], m["to"]): continue
            m["_id"]=i; msgs.append(m)
msgs.sort(key=lambda m: m["ts"], reverse=True)
for m in msgs:
    ts=time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(m["ts"]))
    print(f"id     {m['_id']}")
    print(f"from   {m['from']} → {m['to']}")
    print(f"ts     {ts}")
    print(f"thread {S(m['thread'])}")
    print()
    for line in m["body"].splitlines() or [""]:
        print(f"    {S(line)}")
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
import json, os, re, hashlib, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"]); me=os.environ["MSG_ME"]; only_me=os.environ["MSG_ONLY_ME"]=="1"
A=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
seen=set()
for lf in sorted(d.glob("log-*.jsonl")):
    if lf.is_symlink(): continue
    file_alias=lf.name[4:-6]
    if not A.match(file_alias): continue
    with open(lf, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln=ln.strip()
            if not ln: continue
            try: m=json.loads(ln)
            except json.JSONDecodeError: continue
            if not (isinstance(m, dict) and isinstance(m.get("ts"),(int,float)) and all(isinstance(m.get(k),str) for k in ("from","to","thread","body"))): continue
            if m["from"]!=file_alias: continue
            i=m.get("id")
            if not (isinstance(i,str) and i): i=cid(m)
            if (file_alias, i) in seen: continue
            seen.add((file_alias, i))
            if only_me and m["to"]!=me: continue
            print(json.dumps(m, ensure_ascii=False))
PY
      ;;
    compact)
      MSG_ME="$me" MSG_DIR="$dir" python3 - <<'PY'
import json, os, hashlib, shutil, sys, tempfile, unicodedata
from pathlib import Path
d=Path(os.environ["MSG_DIR"]); me=os.environ["MSG_ME"]
def cid(m):
    c={k:m[k] for k in ("ts","from","to","thread","body") if k in m}
    if "body" in c: c["body"]=unicodedata.normalize("NFC", c["body"])
    return hashlib.sha256(json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
# §5 single-writer: only our own log is ours to rewrite. Other writers' logs
# may be mid-append (another session, a sync delivery) — never touch them.
lf=d/f"log-{me}.jsonl"
if lf.is_symlink(): sys.exit(f"refusing symlinked {lf.name}")
if not lf.exists():
    print(f"nothing to compact (no {lf.name})"); raise SystemExit
st=lf.stat()
with open(lf, encoding="utf-8", errors="replace") as f:
    orig=[ln.rstrip("\n") for ln in f if ln.strip()]
seen=set(); keep=[]; dropped=0; added_ids=0; bad=0
for ln in orig:
    try: m=json.loads(ln)
    except json.JSONDecodeError:
        # Unparseable bytes (e.g. crash-truncated line) are kept verbatim —
        # they may be hand-recoverable; compact must never destroy data.
        keep.append(ln); bad+=1; continue
    if not isinstance(m, dict):
        keep.append(ln); bad+=1; continue
    i=m.get("id")
    if not (isinstance(i,str) and i): i=cid(m)
    if i in seen: dropped+=1; continue
    seen.add(i)
    if "id" not in m:
        m={"id": i, **m}; added_ids+=1
        keep.append(json.dumps(m, ensure_ascii=False))
    else:
        keep.append(ln)
if dropped or added_ids:
    tmp=tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=str(d), delete=False)
    try:
        tmp.writelines(k+"\n" for k in keep)
        tmp.close()
        # Preserve the original log's permissions (NamedTemporaryFile defaults
        # to 0600, which would otherwise regress the 0644 that `send` writes).
        shutil.copymode(str(lf), tmp.name)
        cur=lf.stat()
        if (cur.st_mtime_ns, cur.st_size) != (st.st_mtime_ns, st.st_size):
            sys.exit(f"{lf.name} changed during compact; re-run")
        os.replace(tmp.name, str(lf))
    except BaseException:
        # Interrupt / error mid-write: clean up the temp so it doesn't linger.
        try: os.unlink(tmp.name)
        except OSError: pass
        raise
extra = f", filled id on {added_ids} legacy record(s)" if added_ids else ""
warn = f", kept {bad} unparseable line(s)" if bad else ""
print(f"compacted {lf.name}: {len(orig)} → {len(keep)} line(s), {dropped} duplicate(s) removed{extra}{warn}")
PY
      ;;
    --version|-V|version)
      echo "msg 1.2.0 (SAMP v1)"
      ;;
    help|-h|--help)
      cat <<EOF
msg — agent-message shell helper

Porcelain:
  msg                      show unseen (updates watermark)
  msg inbox                alias of default
  msg <n>                  the n latest, read or not (msg 2); no watermark change
  msg all                  every message to this repo
  msg send <to> <body>     append to your per-agent log
  msg reply <body>         reply to most recent inbox message
  msg tail                 follow new arrivals (existing logs at start time)

Plumbing:
  msg cat <id|prefix>      pretty-print one record (min 4-char prefix)
  msg log [alias]          git-log style; all messages involving me (or alias)
  msg raw [all]            JSONL dump for jq / scripts
  msg compact              dedup own log; ensures id populated

  msg help
  msg --version

dir:    \${AGENT_MESSAGE_DIR:-\${XDG_STATE_HOME:-\$HOME/.local/state}/agent-message}
files:  \$DIR/log-<alias>.jsonl  (single-writer, union on read)
alias:  \$(basename \$PWD), override via .agent-message file first valid line
EOF
      ;;
    *)
      echo "unknown subcommand: $cmd (try: msg help)" >&2
      return 1
      ;;
  esac
}
