#!/usr/bin/env bash
#
# agent-message installer
#
# Installs three slash commands (/message-send, /message-inbox, /message-reply) for
# Claude Code, the `msg` shell helper (0-token human path), and creates the
# shared message dir. Idempotent: safe to re-run.
#
# Options:
#   --dir <path>        Override message dir (default: ${XDG_STATE_HOME:-$HOME/.local/state}/agent-message)
#   --commands <dir>    Override Claude commands dir (default: $HOME/.claude/commands)
#   --shell <path>      Override shell helper install path (default: $HOME/.agent-message.sh)
#   --bin <path>        Override wrapper install path (default: $HOME/.agent-message-cmd)
#   --no-shell          Skip shell helper install
#   --integrate=<list>  Wire up other agents. Comma-separated. Tools:
#                         cursor            global ~/.cursor/rules/agent-message.mdc
#                         copilot           per-repo .github/copilot-instructions.md
#                         copilot-cli       global ~/.copilot/copilot-instructions.md
#                         antigravity       global ~/.gemini/AGENTS.md
#                         antigravity-repo  per-repo ./AGENTS.md
#                         codex             global ~/.codex/AGENTS.md
#                         zed               per-repo ./.rules
#                         all               cursor + copilot + copilot-cli + antigravity + codex + zed
#                         auto              detect installed GLOBAL tools and integrate.
#                                           Per-repo writers (copilot, zed, antigravity-repo)
#                                           are NOT auto-included: run them explicitly from
#                                           inside the target repo.
#                         select            interactive menu: every tool with its detection
#                                           state, per-repo ones labelled with the cwd they
#                                           would write to. Needs a terminal; falls back to
#                                           auto when stdin/stderr is not a TTY. Works with
#                                           --uninstall too (wired tools are marked).
#                       With --uninstall, strips only listed tools. Without
#                       --uninstall, integrates them on top of main install.
#   --uninstall         Remove installed commands, wrapper, shell helper, message dir,
#                       and all known integrations (or only --integrate=<list> if set).
#   -h, --help          Show this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DIR_DEFAULT="${XDG_STATE_HOME:-$HOME/.local/state}/agent-message"
COMMANDS_DEFAULT="$HOME/.claude/commands"
SHELL_DEFAULT="$HOME/.agent-message.sh"
BIN_DEFAULT="$HOME/.agent-message-cmd"

MSG_DIR="$DIR_DEFAULT"
COMMANDS_DIR="$COMMANDS_DEFAULT"
SHELL_DST="$SHELL_DEFAULT"
BIN_DST="$BIN_DEFAULT"
INSTALL_SHELL=1
UNINSTALL=0
INTEGRATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) shift; MSG_DIR="${1:?}";;
    --dir=*) MSG_DIR="${1#*=}";;
    --commands) shift; COMMANDS_DIR="${1:?}";;
    --commands=*) COMMANDS_DIR="${1#*=}";;
    --shell) shift; SHELL_DST="${1:?}";;
    --shell=*) SHELL_DST="${1#*=}";;
    --bin) shift; BIN_DST="${1:?}";;
    --bin=*) BIN_DST="${1#*=}";;
    --no-shell) INSTALL_SHELL=0;;
    --integrate) shift; INTEGRATE="${1:?}";;
    --integrate=*) INTEGRATE="${1#*=}";;
    --uninstall) UNINSTALL=1;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
  shift
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required (macOS ships it; on Linux install python3)." >&2
  exit 1
fi

CMDS=(message-send.md message-inbox.md message-reply.md)
SHELL_SRC="$SCRIPT_DIR/shell/msg.sh"
BIN_SRC="$SCRIPT_DIR/bin/agent-message-cmd"

strip_rc_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  python3 - "$rc" <<'PY'
import errno, os, re, sys
p = sys.argv[1]
PAT = re.compile(
    rb"(?:^|\n)# >>> agent-message >>>\n.*?# <<< agent-message <<<\n?",
    re.DOTALL,
)

try:
    fd = os.open(p, os.O_RDWR | os.O_NOFOLLOW)
except FileNotFoundError:
    sys.exit(0)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.EMLINK):
        print(f"  refusing to follow symlink at {p}", file=sys.stderr)
        sys.exit(0)
    raise

with os.fdopen(fd, "r+b", closefd=True) as f:
    s = f.read()
    s2 = PAT.sub(b"", s)
    if s2 != s:
        f.seek(0)
        f.write(s2)
        f.truncate()
PY
}

inject_rc_block() {
  local rc="$1" dst="$2"
  [[ -f "$rc" ]] || return 0
  python3 - "$rc" "$dst" <<'PY'
import errno, os, re, sys
p, dst = sys.argv[1], sys.argv[2]
dst_b = os.fsencode(dst)
block = (
    b"\n# >>> agent-message >>>\n"
    + b'[ -f "' + dst_b + b'" ] && source "' + dst_b + b'"\n'
    + b"# <<< agent-message <<<\n"
)
PAT = re.compile(
    rb"(?:^|\n)# >>> agent-message >>>\n.*?# <<< agent-message <<<\n?",
    re.DOTALL,
)

try:
    fd = os.open(p, os.O_RDWR | os.O_NOFOLLOW)
except FileNotFoundError:
    sys.exit(0)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.EMLINK):
        print(f"  refusing to follow symlink at {p}", file=sys.stderr)
        sys.exit(0)
    raise

with os.fdopen(fd, "r+b", closefd=True) as f:
    s = f.read()
    matches = list(PAT.finditer(s))
    if len(matches) == 1 and matches[0].group() == block:
        sys.exit(0)
    if matches:
        first = matches[0]
        tail = PAT.sub(b"", s[first.end():])
        s2 = s[:first.start()] + block + tail
    else:
        s2 = s + block
    f.seek(0)
    f.write(s2)
    f.truncate()
PY
}

expand_integrations() {
  case "$1" in
    "") return 0;;
    all) echo "cursor copilot copilot-cli antigravity codex zed";;
    auto)
      # Global integrations only. Per-repo writers (copilot, zed, antigravity-repo)
      # are intentionally excluded: a global signal like ~/.config/zed/ or cwd
      # .git/ tells us the user has the tool, not that the current cwd is the
      # repo where rules should land. Running --integrate=auto from the
      # agent-message clone itself would otherwise drop .rules / .github/
      # files inside the clone. Users who want per-repo wiring run
      # --integrate=<tool> explicitly from inside the target repo.
      local out=""
      [[ -d "$HOME/.cursor" ]] && out="$out cursor"
      [[ -d "$HOME/.copilot" ]] && out="$out copilot-cli"
      [[ -d "$HOME/.gemini" ]] && out="$out antigravity"
      [[ -d "$HOME/.codex" ]] && out="$out codex"
      echo "$out";;
    *) echo "${1//,/ }";;
  esac
}

# Single source of truth for detection + status display: name|scope|target|signals.
# `signals` is a space-separated list of paths/globs; the tool counts as detected
# when any one exists. Signals for the per-repo writers are used ONLY by the
# select menu and the status line — never by `auto`, which stays global-only for
# the reason documented in expand_integrations.
integration_rows() {
  cat <<ROWS
cursor|global|$HOME/.cursor/rules/agent-message.mdc|$HOME/.cursor
copilot-cli|global|$HOME/.copilot/copilot-instructions.md|$HOME/.copilot
antigravity|global|$HOME/.gemini/AGENTS.md|$HOME/.gemini
codex|global|$HOME/.codex/AGENTS.md|$HOME/.codex
copilot|repo|.github/copilot-instructions.md|$HOME/.config/github-copilot $HOME/.vscode/extensions/github.copilot*
antigravity-repo|repo|AGENTS.md|$HOME/.gemini
zed|repo|.rules|$HOME/.config/zed $HOME/.zed
ROWS
}

# Unquoted expansion is deliberate: it splits the signal list AND globs each entry.
# shellcheck disable=SC2086
tool_detected() {
  local g
  for g in $1; do [[ -e "$g" ]] && return 0; done
  return 1
}

# Both writers (marker_block, cursor_block) embed this anchor, so one grep covers all.
tool_wired() {
  [[ -f "$1" ]] && grep -qF '>>> agent-message >>>' "$1" 2>/dev/null
}

# Printed after a plain install: names global tools that are present on the machine
# but not wired up, with the exact command. Silent only when nothing is detected at
# all — an all-wired machine still gets a one-line confirmation, otherwise a run
# that found and checked everything looks identical to one that checked nothing.
integration_hint() {
  local mode="$1" name scope target signals wired="" todo=""
  while IFS='|' read -r name scope target signals; do
    [[ "$scope" == global ]] || continue
    if tool_wired "$target"; then wired="$wired $name"; continue; fi
    tool_detected "$signals" && todo="$todo $name"
  done <<< "$(integration_rows)"
  # Wired tools ride in the aligned commands:/wrapper:/dir:/shell: block — a
  # free-floating line further down the banner is unfindable by eye. Unwired
  # ones get their own paragraph because they carry commands to copy.
  # Every branch below is an explicit `if`: a bare `[[ ]] && printf` evaluates to
  # 1 when the test fails, and under `set -e` that kills this whole function
  # (it runs inside $(...)), truncating the hint to nothing.
  if [[ "$mode" == row ]]; then
    [[ -n "$wired" ]] || return 0
    local list="${wired# }"
    printf '\n  agents:   %s' "${list// /, }"
    return 0
  fi
  [[ -n "$todo" ]] || return 0
  printf '\n\nNot wired yet (detected on this machine):\n'
  for name in $todo; do
    printf '  %-12s → %s/install.sh --integrate=%s\n' "$name" "$SCRIPT_DIR" "$name"
  done
  printf '\n  all at once: %s/install.sh --integrate=auto\n' "$SCRIPT_DIR"
  printf '  or pick from a menu: %s/install.sh --integrate=select' "$SCRIPT_DIR"
}

# Interactive picker. Menu goes to stderr so the chosen list can be captured on
# stdout by the caller. `a` means all detected GLOBAL tools — same set as `auto`.
# Per-repo writers must be picked by number: a blanket "all" run from the wrong
# folder is exactly the footgun `auto` exists to avoid.
select_integrations() {
  # stdin must be readable and stderr visible. Deliberately NOT -t 1: the caller
  # captures stdout via $(...), so fd 1 is a pipe on every real invocation.
  if [[ ! -t 0 || ! -t 2 ]]; then
    echo "  --integrate=select needs a terminal; falling back to auto" >&2
    expand_integrations auto
    return 0
  fi

  local rows=() row name scope target signals i=1 where status line out="" tok idx
  while IFS='|' read -r name scope target signals; do
    rows+=("$name|$scope|$target|$signals")
  done <<< "$(integration_rows)"

  printf '\nagent-message integrations   (cwd: %s)\n\n' "$PWD" >&2
  for row in "${rows[@]}"; do
    IFS='|' read -r name scope target signals <<< "$row"
    [[ "$scope" == repo ]] && where="./${PWD##*/}" || where="global"
    if tool_wired "$target"; then status="WIRED"
    elif tool_detected "$signals"; then status="detected"
    else status="not found"; fi
    printf '  [%d] %-17s %-12s %s\n' "$i" "$name" "$where" "$status" >&2
    i=$((i+1))
  done
  printf '\nNumbers to pick (space-separated), a=all detected global, Enter=none, q=quit\n> ' >&2

  read -r line || line=""
  case "$line" in
    q|Q) return 0;;
    a|A)
      for row in "${rows[@]}"; do
        IFS='|' read -r name scope target signals <<< "$row"
        [[ "$scope" == global ]] || continue
        tool_detected "$signals" && out="$out $name"
      done;;
    *)
      for tok in $line; do
        case "$tok" in ''|*[!0-9]*) echo "  ignoring: $tok" >&2; continue;; esac
        idx=$((tok - 1))
        if [[ $idx -lt 0 || $idx -ge ${#rows[@]} ]]; then
          echo "  out of range: $tok" >&2; continue
        fi
        IFS='|' read -r name scope target signals <<< "${rows[$idx]}"
        out="$out $name"
      done;;
  esac
  echo "$out"
}

cursor_block() {
  cat <<'CURSOR'
---
description: agent-message protocol — cross-agent messaging via local JSONL logs
alwaysApply: false
---

<!-- >>> agent-message >>> -->
When the user asks to send/check/reply to messages from other AI agents (Claude, opencode, Cursor, etc.), use the `~/.agent-message-cmd` wrapper:

- Send: `echo '<body>' | ~/.agent-message-cmd send <recipient-alias>`
- Check inbox: `~/.agent-message-cmd inbox`
- Reply to last: `echo '<body>' | ~/.agent-message-cmd reply`

Sender alias = `basename $(pwd)`, override via `.agent-message` file's first line.
Spec: SAMP v1 — https://github.com/slima4/agent-message/blob/main/SPEC.md
<!-- <<< agent-message <<< -->
CURSOR
}

# The original Cursor integration owned the entire file and had no markers.
# Migrate it only when it is byte-for-byte unchanged; a modified legacy file is
# user-owned and must not be overwritten or removed.
legacy_cursor_block() {
  cat <<'CURSOR'
---
description: agent-message protocol — cross-agent messaging via local JSONL logs
alwaysApply: false
---

When the user asks to send/check/reply to messages from other AI agents (Claude, opencode, Cursor, etc.), use the `~/.agent-message-cmd` wrapper:

- Send: `echo '<body>' | ~/.agent-message-cmd send <recipient-alias>`
- Check inbox: `~/.agent-message-cmd inbox`
- Reply to last: `echo '<body>' | ~/.agent-message-cmd reply`

Sender alias = `basename $(pwd)`, override via `.agent-message` file's first line.
Spec: SAMP v1 — https://github.com/slima4/agent-message/blob/main/SPEC.md
CURSOR
}

integrate_cursor() {
  local dst="$HOME/.cursor/rules/agent-message.mdc" parent expected legacy rc=0
  parent=$(dirname "$dst")
  if [[ -L "$parent" ]]; then
    echo "  cursor:   refusing — $parent is a symlink" >&2
    return 0
  fi
  mkdir -p "$parent"
  expected=$(cursor_block)
  legacy=$(legacy_cursor_block)
  python3 - "$dst" "$expected" "$legacy" <<'PY' || rc=$?
import errno, os, sys
p = sys.argv[1]
expected = os.fsencode(sys.argv[2]) + b"\n"
legacy = os.fsencode(sys.argv[3])

try:
    fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.EMLINK):
        print(f"  cursor:   refusing to follow symlink at {p}", file=sys.stderr)
        sys.exit(1)
    raise

with os.fdopen(fd, "r+b", closefd=True) as f:
    s = f.read()
    if expected[:-1] in s:
        sys.exit(2)
    if s and s not in (legacy, legacy + b"\n"):
        sys.exit(3)
    f.seek(0)
    f.write(expected)
    f.truncate()
PY
  case $rc in
    0) echo "  cursor:   $dst";;
    2) echo "  cursor:   $dst (already integrated)";;
    3) echo "  cursor:   $dst exists with non-agent-message content; skipping" >&2;;
  esac
}

uninstall_cursor() {
  local expected; expected=$(cursor_block)
  strip_marker_block "$HOME/.cursor/rules/agent-message.mdc" "$expected"
}

# Canonical marker block — single source of truth shared by all per-repo integrations.
# Updating wording here updates write + uninstall consistently.
marker_block() {
  cat <<'BLOCK'

<!-- >>> agent-message >>> -->
## Agent messaging (SAMP v1)

To send/check/reply to messages from other AI agents, use the `~/.agent-message-cmd` wrapper:

- Send: `echo '<body>' | ~/.agent-message-cmd send <recipient-alias>`
- Check inbox: `~/.agent-message-cmd inbox`
- Reply to last: `echo '<body>' | ~/.agent-message-cmd reply`

Sender alias = `basename $(pwd)`, override via `.agent-message` file's first line.
Spec: https://github.com/slima4/agent-message/blob/main/SPEC.md
<!-- <<< agent-message <<< -->
BLOCK
}

# Idempotent marker writer. Three cases:
#   exact match already present     → no-op (exit 2)
#   anchors present, content stale  → strip stale (anchor-based) + append current (exit 0)
#   anchors absent                  → append current (exit 0)
# Anchor-based replace during install is safe because the user invoked install
# on this file: replacing whatever was between our anchors with our current
# block is a net upgrade. Symlink-safe via O_NOFOLLOW on every open.
ensure_marker_block() {
  local dst="$1" block rc=0; block=$(marker_block)
  # `|| rc=$?` keeps `set -e` from aborting the script when python3 returns
  # the non-zero "already up-to-date" sentinel (exit 2) or a symlink error (1).
  python3 - "$dst" "$block" <<'PY' || rc=$?
import sys, os, re
p, expected = sys.argv[1], sys.argv[2]
PAT = re.compile(
    r"\n?<!-- >>> agent-message >>> -->.*?<!-- <<< agent-message <<< -->\n?",
    re.DOTALL,
)

try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r") as f: s = f.read()
except FileNotFoundError:
    s = ""
except OSError:
    print(f"  refusing to follow symlink at {p}", file=sys.stderr)
    sys.exit(1)

if expected in s:
    sys.exit(2)

m = PAT.search(s)
if m:
    s2 = (s[:m.start()] + s[m.end():]).rstrip("\n")
    try:
        fd = os.open(p, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
    except OSError:
        print(f"  refusing to follow symlink at {p}", file=sys.stderr)
        sys.exit(1)
    with os.fdopen(fd, "w") as f:
        if s2: f.write(s2 + "\n")

try:
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o644)
except OSError:
    print(f"  refusing to follow symlink at {p}", file=sys.stderr)
    sys.exit(1)
with os.fdopen(fd, "a") as f:
    f.write(expected + "\n")
PY
  return $rc
}

# Dispatch ensure_marker_block + echo status. Used by all integrate_* helpers.
# `|| rc=$?` again — needed because `set -e` would otherwise abort on the
# "already up-to-date" exit 2 from ensure_marker_block before we can dispatch.
emit_marker_status() {
  local label="$1" dst="$2" rc=0
  ensure_marker_block "$dst" || rc=$?
  case $rc in
    0) echo "  $label: $dst";;
    2) echo "  $label: $dst (already integrated)";;
    # Other non-zero (symlink refusal) — ensure_marker_block already logged
    # to stderr. Stay best-effort: continue the installer rather than abort.
  esac
}

# Strip the canonical marker block by EXACT-match substring removal.
# Defends against attacker-planted marker pairs wrapping legitimate user content:
# a regex predecessor would have stripped `<open>...arbitrary content...<close>`.
# This implementation only removes byte-for-byte what we wrote. If you edit
# marker_block contents, re-run install before uninstalling — ensure_marker_block
# replaces the stale block so exact-match strip then succeeds.
strip_marker_block() {
  local dst="$1"
  [[ -f "$dst" ]] || return 0
  local expected="${2-}"
  [[ -n "$expected" ]] || expected=$(marker_block)
  python3 - "$dst" "$expected" <<'PY'
import errno, os, stat, sys
p = sys.argv[1]
expected = os.fsencode(sys.argv[2])
# marker_block deliberately starts with a newline so install can append it to
# any existing file. Search for the semantic block itself, then remove at most
# the one separator newline on each side that belongs to the installed copy.
core = expected[1:] if expected.startswith(b"\n") else expected

try:
    fd = os.open(p, os.O_RDWR | os.O_NOFOLLOW)
except FileNotFoundError:
    sys.exit(0)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.EMLINK):
        print(f"  refusing to follow symlink at {p}", file=sys.stderr)
        sys.exit(0)
    raise

with os.fdopen(fd, "r+b", closefd=True) as f:
    before = os.fstat(f.fileno())
    s = f.read()
    ranges = []
    pos = 0
    while True:
        found = s.find(core, pos)
        if found < 0:
            break
        end = found + len(core)
        line_start = found == 0 or s[found - 1:found] == b"\n"
        line_end = end == len(s) or s[end:end + 1] == b"\n"
        if line_start and line_end:
            start = found - 1 if found > 0 else found
            end += 1 if end < len(s) else 0
            ranges.append((start, end))
        pos = found + len(core)

    # Adjacent manually duplicated blocks can share a separator newline.
    # Merge their removal spans before rebuilding the untouched user bytes.
    merged = []
    for start, end in ranges:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    s2 = s
    for start, end in reversed(merged):
        s2 = s2[:start] + s2[end:]
    if s2 == s:
        sys.exit(0)
    if s2:
        f.seek(0)
        f.write(s2)
        f.truncate()
        sys.exit(0)

    # Only unlink the pathname if it still names the inode opened with
    # O_NOFOLLOW. If it changed underneath us, leave the replacement alone.
    try:
        current = os.stat(p, follow_symlinks=False)
    except FileNotFoundError:
        sys.exit(0)
    if stat.S_ISREG(current.st_mode) and (current.st_dev, current.st_ino) == (before.st_dev, before.st_ino):
        os.unlink(p)
PY
}

# Real git repo only — refuse if cwd has no .git/, or .git is a symlink.
# Symlinked .git could be planted by a malicious checkout to satisfy the gate.
# Used only by copilot Chat (writes under .github/, presupposes git anyway).
in_real_git_repo() {
  [[ -d ".git" && ! -L ".git" ]]
}

# Light cwd sanity for per-repo integrations that don't require git (zed, AGENTS.md).
# Refuses obvious non-project paths: / and $HOME. Anything else is user discretion.
# Strips trailing slash from $HOME (env may set it as /Users/slim/) so the comparison holds.
cwd_is_project() {
  local home="${HOME%/}"
  [[ -n "$PWD" && "$PWD" != "/" && "$PWD" != "$home" ]]
}

integrate_copilot() {
  if ! in_real_git_repo; then
    echo "  copilot: cwd is not a git repo; skipping (run from inside the target repo)" >&2
    return 0
  fi
  if [[ -L ".github" ]]; then
    echo "  copilot: refusing to follow symlink at .github" >&2
    return 0
  fi
  mkdir -p ".github"
  emit_marker_status "copilot" ".github/copilot-instructions.md"
}

uninstall_copilot() {
  strip_marker_block ".github/copilot-instructions.md"
  rmdir ".github" 2>/dev/null || true
}

integrate_repo_root_md() {
  local label="$1" dst="$2"
  if ! cwd_is_project; then
    echo "  $label: cwd is $PWD (not a project folder); skipping" >&2
    return 0
  fi
  emit_marker_status "$label" "$dst"
}

uninstall_repo_root_md() {
  strip_marker_block "$1"
}

# Append marker to a per-user global path under $HOME (no repo gate, no cwd dependency).
# Defends against:
#   - symlinked parent dir (e.g. ~/.gemini → /attacker/dir): mkdir -p silently no-ops on
#     a symlink-to-dir, after which O_NOFOLLOW on the final component does NOT fire.
#     Refuse if dirname is a symlink before creating or writing.
#   - symlinked target file: O_NOFOLLOW in ensure_marker_block.
integrate_global_md() {
  local label="$1" dst="$2" parent
  parent=$(dirname "$dst")
  if [[ -L "$parent" ]]; then
    echo "  $label: refusing — $parent is a symlink" >&2
    return 0
  fi
  mkdir -p "$parent"
  if [[ -L "$parent" ]]; then
    # mkdir -p might race-create or follow a newly-planted symlink. Re-check.
    echo "  $label: refusing — $parent is a symlink (post-mkdir)" >&2
    return 0
  fi
  emit_marker_status "$label" "$dst"
}

uninstall_global_md() {
  strip_marker_block "$1"
}

# Antigravity: default to global (~/.gemini/AGENTS.md, also read by Gemini CLI).
# Per-repo opt-in via --integrate=antigravity-repo.
integrate_antigravity()      { integrate_global_md  "antigravity"      "$HOME/.gemini/AGENTS.md"; }
uninstall_antigravity()      { uninstall_global_md  "$HOME/.gemini/AGENTS.md"; }
integrate_antigravity_repo() { integrate_repo_root_md "antigravity-repo" "AGENTS.md"; }
uninstall_antigravity_repo() { uninstall_repo_root_md "AGENTS.md"; }

# Copilot CLI is distinct from Copilot Chat. CLI reads ~/.copilot/copilot-instructions.md
# globally; Chat reads .github/copilot-instructions.md per-repo.
integrate_copilot_cli()      { integrate_global_md  "copilot-cli"      "$HOME/.copilot/copilot-instructions.md"; }
uninstall_copilot_cli()      { uninstall_global_md  "$HOME/.copilot/copilot-instructions.md"; }

# OpenAI Codex CLI: reads ~/.codex/AGENTS.md globally.
#
# AGENTS.md alone is not enough. Under the default `workspace-write` sandbox Codex
# may only write inside cwd, so reading the inbox succeeds but saving the read
# marker in $MSG_DIR fails — messages re-show forever. `sandbox_workspace_write.
# writable_roots` is the persistent fix (the per-launch equivalent is `--add-dir`).
#
# TOML, not markdown, so this cannot reuse marker_block: `<!-- -->` is not a TOML
# comment. It also has a conflict case the markdown writers don't — appending a
# second [sandbox_workspace_write] table when the user already declared one is a
# TOML duplicate-table error that breaks Codex outright. Detect and refuse instead.
codex_sandbox_toml() {
  python3 - "$HOME/.codex/config.toml" "$MSG_DIR" <<'PY'
import errno, json, os, re, sys
p, msg_dir = sys.argv[1], sys.argv[2]
OPEN, CLOSE = "# >>> agent-message >>>", "# <<< agent-message <<<"
block = f'\n{OPEN}\n[sandbox_workspace_write]\nwritable_roots = [{json.dumps(msg_dir)}]\n{CLOSE}\n'
PAT = re.compile(rf"(?:^|\n){re.escape(OPEN)}\n.*?{re.escape(CLOSE)}\n?", re.DOTALL)

try:
    fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.EMLINK): sys.exit(1)
    raise

with os.fdopen(fd, "r+", encoding="utf-8", closefd=True) as f:
    s = f.read()
    rest = PAT.sub("", s)
    # A user-declared table outside our block: theirs wins, we stay out.
    if re.search(r"^[ \t]*\[sandbox_workspace_write\]", rest, re.MULTILINE): sys.exit(3)
    found = PAT.findall(s)
    if len(found) == 1 and found[0].strip("\n") == block.strip("\n"): sys.exit(2)
    s2 = rest.rstrip("\n") + "\n" + block if rest.strip() else block.lstrip("\n")
    f.seek(0); f.write(s2); f.truncate()
PY
}

integrate_codex() {
  integrate_global_md "codex" "$HOME/.codex/AGENTS.md"
  local rc=0
  codex_sandbox_toml || rc=$?
  case $rc in
    0) echo "  codex: ~/.codex/config.toml (sandbox writable_roots → $MSG_DIR)";;
    2) echo "  codex: ~/.codex/config.toml (already integrated)";;
    1) echo "  codex: refusing to follow symlink at ~/.codex/config.toml" >&2;;
    3) echo "  codex: ~/.codex/config.toml already sets [sandbox_workspace_write] — leaving it alone." >&2
       echo "         Add this to its writable_roots so read markers can be saved:" >&2
       echo "           \"$MSG_DIR\"" >&2;;
  esac
}

uninstall_codex() {
  uninstall_global_md "$HOME/.codex/AGENTS.md"
  [[ -f "$HOME/.codex/config.toml" ]] || return 0
  python3 - "$HOME/.codex/config.toml" <<'PY'
import errno, os, re, sys
p = sys.argv[1]
PAT = re.compile(r"(?:^|\n)# >>> agent-message >>>\n.*?# <<< agent-message <<<\n?", re.DOTALL)
try:
    fd = os.open(p, os.O_RDWR | os.O_NOFOLLOW)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.EMLINK): sys.exit(0)
    raise
with os.fdopen(fd, "r+", encoding="utf-8", closefd=True) as f:
    s = f.read(); s2 = PAT.sub("", s)
    if s2 != s: f.seek(0); f.write(s2); f.truncate()
PY
}

# Zed: per-repo only. Global rules live in an LMDB binary (Rules Library) — not safely scriptable.
integrate_zed()              { integrate_repo_root_md "zed" ".rules"; }
uninstall_zed()              { uninstall_repo_root_md ".rules"; }

run_integrate() {
  local tool
  for tool in $(expand_integrations "$INTEGRATE"); do
    case "$tool" in
      cursor) integrate_cursor;;
      copilot) integrate_copilot;;
      copilot-cli) integrate_copilot_cli;;
      antigravity) integrate_antigravity;;
      antigravity-repo) integrate_antigravity_repo;;
      codex) integrate_codex;;
      zed) integrate_zed;;
      *) echo "  unknown integrate target: $tool" >&2;;
    esac
  done
}

run_uninstall_integrate() {
  local tool
  for tool in $(expand_integrations "$INTEGRATE"); do
    case "$tool" in
      cursor) uninstall_cursor;;
      copilot) uninstall_copilot;;
      copilot-cli) uninstall_copilot_cli;;
      antigravity) uninstall_antigravity;;
      antigravity-repo) uninstall_antigravity_repo;;
      codex) uninstall_codex;;
      zed) uninstall_zed;;
      *) echo "  unknown integrate target: $tool" >&2;;
    esac
  done
}

# Copy through a same-directory temporary file, then atomically replace the
# final directory entry. os.replace() replaces destination symlinks themselves,
# including symlinks to directories; `mv` would follow a directory symlink.
install_file() {
  local src="$1" dst="$2" mode="$3" preserve_mode="${4:-0}" parent tmp
  parent=$(dirname "$dst")
  mkdir -p "$parent"
  if [[ -d "$dst" && ! -L "$dst" ]]; then
    echo "refusing to replace directory with file: $dst" >&2
    return 1
  fi
  if [[ "$preserve_mode" -eq 1 ]]; then
    mode=$(python3 - "$dst" "$mode" <<'PY'
import os, stat, sys
p, fallback = sys.argv[1], sys.argv[2]
try:
    current = os.stat(p, follow_symlinks=False)
except FileNotFoundError:
    print(fallback)
else:
    print(oct(stat.S_IMODE(current.st_mode))[2:] if stat.S_ISREG(current.st_mode) else fallback)
PY
)
  fi
  tmp=$(mktemp "$parent/.agent-message-install.XXXXXX")
  if ! cp "$src" "$tmp" || ! chmod "$mode" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! python3 -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])' "$tmp" "$dst"; then
    rm -f "$tmp"
    return 1
  fi
}

# Resolve the interactive picker before any install work: the user answers first,
# then the run proceeds non-interactively. Must sit after the function defs above.
# SELECT_MODE is remembered because an empty selection under --uninstall must NOT
# read as "no --integrate given" — that would escalate a cancelled menu into a
# full uninstall of commands, wrapper, shell helper and logs.
SELECT_MODE=0
if [[ "$INTEGRATE" == "select" ]]; then
  SELECT_MODE=1
  INTEGRATE=$(select_integrations)
  [[ -n "${INTEGRATE// /}" ]] || echo "  no integrations selected" >&2
fi

if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ -n "${INTEGRATE// /}" || "$SELECT_MODE" -eq 1 ]]; then
    # Partial: integrations only. Leave main install alone.
    echo "Removing integrations:"
    run_uninstall_integrate
    exit 0
  fi
  for f in "${CMDS[@]}"; do
    rm -f "$COMMANDS_DIR/$f"
  done
  # Remove per-agent logs and internal caches, but never the dir itself blindly.
  if [[ -d "$MSG_DIR" ]]; then
    find "$MSG_DIR" -maxdepth 1 -type f \( -name "log-*.jsonl" -o -name ".seen-*" -o -name ".mtime-*" \) -delete 2>/dev/null || true
    rmdir "$MSG_DIR" 2>/dev/null || true
  fi
  rm -f "$BIN_DST"
  rm -f "$SHELL_DST"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    strip_rc_block "$rc"
  done
  # Strip global integrations. Per-repo ones (copilot, antigravity-repo, zed)
  # require explicit `--uninstall --integrate=<tool>` from the target repo
  # to avoid mucking with foreign repos.
  uninstall_cursor
  uninstall_copilot_cli
  uninstall_antigravity
  uninstall_codex
  echo "agent-message uninstalled."
  echo "  removed: ${CMDS[*]/#/$COMMANDS_DIR/}"
  echo "  removed: $MSG_DIR/{log-*.jsonl,.seen-*,.mtime-*} (dir removed if empty)"
  echo "  removed: $BIN_DST"
  echo "  removed: $SHELL_DST (and rc source blocks)"
  echo "  removed: ~/.cursor/rules/agent-message.mdc marker block (file removed if empty)"
  echo "  removed: ~/.copilot/copilot-instructions.md marker block (if present)"
  echo "  removed: ~/.gemini/AGENTS.md marker block (if present)"
  echo "  removed: ~/.codex/AGENTS.md marker block (if present)"
  echo "  note:    per-repo integrations (copilot, antigravity-repo, zed) are NOT"
  echo "           auto-stripped; run \`./install.sh --uninstall --integrate=<tool>\`"
  echo "           from each repo to remove them."
  exit 0
fi

mkdir -p "$COMMANDS_DIR"
mkdir -p "$MSG_DIR"
# Existing private directories (for example mode 0700) are already usable and
# must stay private. Add only missing owner permissions instead of resetting
# group/other bits to 0755.
if [[ ! -r "$MSG_DIR" || ! -w "$MSG_DIR" || ! -x "$MSG_DIR" ]]; then
  chmod u+rwx "$MSG_DIR"
fi

for f in "${CMDS[@]}"; do
  src="$SCRIPT_DIR/commands/$f"
  if [[ ! -f "$src" ]]; then
    echo "missing source file: $src" >&2
    exit 1
  fi
  # `cp` historically preserved the mode of an existing regular command file.
  # Keep that contract while new files and symlink replacements default to 0644.
  install_file "$src" "$COMMANDS_DIR/$f" 0644 1
done

if [[ ! -f "$BIN_SRC" ]]; then
  echo "missing wrapper: $BIN_SRC" >&2
  exit 1
fi
install_file "$BIN_SRC" "$BIN_DST" 0755

SHELL_NOTE=""
if [[ "$INSTALL_SHELL" -eq 1 ]]; then
  if [[ ! -f "$SHELL_SRC" ]]; then
    echo "missing shell helper: $SHELL_SRC" >&2
    exit 1
  fi
  install_file "$SHELL_SRC" "$SHELL_DST" 0644
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    inject_rc_block "$rc" "$SHELL_DST"
  done
  SHELL_NOTE="
  shell:    $SHELL_DST  (sourced from ~/.zshrc and ~/.bashrc if present)
            → open a new terminal, then: msg help"
fi

INTEGRATE_NOTE=""
if [[ -n "${INTEGRATE// /}" ]]; then
  INTEGRATE_NOTE=$'\n\nIntegrations:\n'
  INTEGRATE_NOTE+="$(run_integrate)"
fi

# Computed after run_integrate so anything just wired counts as wired. Two pieces:
# the aligned `agents:` row belongs inside the commands:/wrapper:/dir: block, the
# actionable paragraph belongs below the per-run "Integrations:" output.
AGENTS_ROW="$(integration_hint row)"
HINT_NOTE="$(integration_hint todo)"

cat <<EOF
agent-message installed.

  commands: $COMMANDS_DIR/{message-send,message-inbox,message-reply}.md
  wrapper:  $BIN_DST
  dir:      $MSG_DIR  (per-agent logs: log-<alias>.jsonl)$SHELL_NOTE$AGENTS_ROW$INTEGRATE_NOTE$HINT_NOTE

Use from any Claude Code session (any repo, any path):

  /message-send <recipient-alias> <body…>
  /message-inbox
  /message-inbox 2            # the 2 latest, read or not
  /message-reply <body…>

From a terminal (0 Claude tokens):

  msg send <to> <body…>
  msg              # unseen
  msg 2            # the 2 latest, read or not
  msg reply <body> # reply to most recent
  msg tail         # follow live

Sender alias defaults to \$(basename "\$PWD"). Override per-repo by putting the
alias on the first line of a \`.agent-message\` file at the repo root.

Permission tip: to skip Claude Code's per-call approval prompt without granting
blanket python3 access, add to ~/.claude/settings.json:

  { "permissions": { "allow": ["Bash($BIN_DST:*)"] } }

This allows ONLY the wrapper, nothing else.

Uninstall: $SCRIPT_DIR/install.sh --uninstall
EOF
