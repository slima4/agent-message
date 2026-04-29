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
#   --integrate=<list>  Wire up other agents. Tools: cursor, copilot, all, auto.
#                       Comma-separated. With --uninstall, strips only listed tools.
#                       Without --uninstall, integrates them on top of main install.
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
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
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
MARKER_BEGIN="# >>> agent-message >>>"
MARKER_END="# <<< agent-message <<<"

strip_rc_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  python3 - "$rc" <<'PY'
import sys, re
p = sys.argv[1]
with open(p) as f: s = f.read()
# Replace the matched (including one leading \n) with a single \n to preserve surrounding
# content separation; then drop that leading \n iff the original file did not start with one.
s2 = re.sub(r"(?:^|\n)# >>> agent-message >>>.*?# <<< agent-message <<<\n?", "\n", s, flags=re.DOTALL)
if s2 != s:
    if not s.startswith("\n"):
        s2 = s2.lstrip("\n")
    with open(p, "w") as f: f.write(s2)
PY
}

inject_rc_block() {
  local rc="$1" dst="$2"
  [[ -f "$rc" ]] || return 0
  if grep -qF "$MARKER_BEGIN" "$rc"; then
    return 0
  fi
  {
    printf '\n%s\n' "$MARKER_BEGIN"
    printf '[ -f "%s" ] && source "%s"\n' "$dst" "$dst"
    printf '%s\n' "$MARKER_END"
  } >> "$rc"
}

expand_integrations() {
  case "$1" in
    "") return 0;;
    all) echo "cursor copilot";;
    auto)
      local out=""
      [[ -d "$HOME/.cursor" ]] && out="$out cursor"
      [[ -d ".git" ]] && out="$out copilot"
      echo "$out";;
    *) echo "${1//,/ }";;
  esac
}

integrate_cursor() {
  local dst="$HOME/.cursor/rules/agent-message.mdc"
  if [[ -L "$dst" ]]; then
    echo "  cursor:   refusing to follow symlink at $dst" >&2
    return 0
  fi
  if [[ -f "$dst" ]] && ! grep -qF "agent-message protocol — cross-agent messaging" "$dst"; then
    echo "  cursor:   $dst exists with non-agent-message content; skipping" >&2
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cat > "$dst" <<'CURSOR'
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
  echo "  cursor:   $dst"
}

uninstall_cursor() {
  rm -f "$HOME/.cursor/rules/agent-message.mdc"
}

integrate_copilot() {
  if [[ ! -d ".git" ]]; then
    echo "  copilot:  cwd is not a git repo; skipping (run from inside the target repo)" >&2
    return 0
  fi
  if [[ -L ".github" || -L ".github/copilot-instructions.md" ]]; then
    echo "  copilot:  refusing to follow symlink in .github/" >&2
    return 0
  fi
  local dst=".github/copilot-instructions.md"
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$dst" ]] && grep -qF "<!-- >>> agent-message >>> -->" "$dst"; then
    echo "  copilot:  $dst (already integrated)"
    return 0
  fi
  cat >> "$dst" <<'COPILOT'

<!-- >>> agent-message >>> -->
## Agent messaging (SAMP v1)

To send/check/reply to messages from other AI agents, use the `~/.agent-message-cmd` wrapper:

- Send: `echo '<body>' | ~/.agent-message-cmd send <recipient-alias>`
- Check inbox: `~/.agent-message-cmd inbox`
- Reply to last: `echo '<body>' | ~/.agent-message-cmd reply`

Sender alias = `basename $(pwd)`, override via `.agent-message` file's first line.
Spec: https://github.com/slima4/agent-message/blob/main/SPEC.md
<!-- <<< agent-message <<< -->
COPILOT
  echo "  copilot:  $dst"
}

uninstall_copilot() {
  local dst=".github/copilot-instructions.md"
  [[ -f "$dst" ]] || return 0
  python3 - "$dst" <<'PY'
import sys, re, os
p = sys.argv[1]
with open(p) as f: s = f.read()
s2 = re.sub(r"\n*<!-- >>> agent-message >>> -->.*?<!-- <<< agent-message <<< -->\n?", "\n", s, flags=re.DOTALL)
if s2 == s:
    sys.exit(0)
s2 = s2.strip()
if s2:
    with open(p, "w") as f: f.write(s2 + "\n")
else:
    os.unlink(p)
    parent = os.path.dirname(p)
    try: os.rmdir(parent)
    except OSError: pass
PY
}

run_integrate() {
  local tool
  for tool in $(expand_integrations "$INTEGRATE"); do
    case "$tool" in
      cursor) integrate_cursor;;
      copilot) integrate_copilot;;
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
      *) echo "  unknown integrate target: $tool" >&2;;
    esac
  done
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ -n "$INTEGRATE" ]]; then
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
  # Strip global integrations only. Per-repo integrations (copilot)
  # require explicit `--uninstall --integrate=copilot` from the target repo
  # to avoid mucking with foreign repos' .github/copilot-instructions.md.
  uninstall_cursor
  echo "agent-message uninstalled."
  echo "  removed: ${CMDS[*]/#/$COMMANDS_DIR/}"
  echo "  removed: $MSG_DIR/{log-*.jsonl,.seen-*,.mtime-*} (dir removed if empty)"
  echo "  removed: $BIN_DST"
  echo "  removed: $SHELL_DST (and rc source blocks)"
  echo "  removed: ~/.cursor/rules/agent-message.mdc (if present)"
  echo "  note:    per-repo copilot integrations are NOT auto-stripped;"
  echo "           run \`./install.sh --uninstall --integrate=copilot\` from each repo."
  exit 0
fi

mkdir -p "$COMMANDS_DIR"
mkdir -p "$MSG_DIR"
chmod 0755 "$MSG_DIR"

for f in "${CMDS[@]}"; do
  src="$SCRIPT_DIR/commands/$f"
  if [[ ! -f "$src" ]]; then
    echo "missing source file: $src" >&2
    exit 1
  fi
  cp "$src" "$COMMANDS_DIR/$f"
done

if [[ ! -f "$BIN_SRC" ]]; then
  echo "missing wrapper: $BIN_SRC" >&2
  exit 1
fi
mkdir -p "$(dirname "$BIN_DST")"
cp "$BIN_SRC" "$BIN_DST"
chmod 0755 "$BIN_DST"

SHELL_NOTE=""
if [[ "$INSTALL_SHELL" -eq 1 ]]; then
  if [[ ! -f "$SHELL_SRC" ]]; then
    echo "missing shell helper: $SHELL_SRC" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SHELL_DST")"
  cp "$SHELL_SRC" "$SHELL_DST"
  chmod 0644 "$SHELL_DST"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    inject_rc_block "$rc" "$SHELL_DST"
  done
  SHELL_NOTE="
  shell:    $SHELL_DST  (sourced from ~/.zshrc and ~/.bashrc if present)
            → open a new terminal, then: msg help"
fi

INTEGRATE_NOTE=""
if [[ -n "$INTEGRATE" ]]; then
  INTEGRATE_NOTE=$'\n\nIntegrations:\n'
  INTEGRATE_NOTE+="$(run_integrate)"
fi

cat <<EOF
agent-message installed.

  commands: $COMMANDS_DIR/{message-send,message-inbox,message-reply}.md
  wrapper:  $BIN_DST
  dir:      $MSG_DIR  (per-agent logs: log-<alias>.jsonl)$SHELL_NOTE$INTEGRATE_NOTE

Use from any Claude Code session (any repo, any path):

  /message-send <recipient-alias> <body…>
  /message-inbox
  /message-reply <body…>

From a terminal (0 Claude tokens):

  msg send <to> <body…>
  msg              # unseen
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
