#!/usr/bin/env bash
#
# claude-message installer
#
# Installs three slash commands (/message-send, /message-inbox, /message-reply) for
# Claude Code, the `msg` shell helper (0-token human path), and creates the
# shared JSONL mailbox. Idempotent: safe to re-run.
#
# Options:
#   --mailbox <path>    Override mailbox path (default: $HOME/dev/.message/messages.jsonl)
#   --commands <dir>    Override Claude commands dir (default: $HOME/.claude/commands)
#   --shell <path>      Override shell helper install path (default: $HOME/.claude-message.sh)
#   --no-shell          Skip shell helper install
#   --uninstall         Remove installed commands, shell helper, and mailbox
#   -h, --help          Show this help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

MAILBOX_DEFAULT="$HOME/dev/.message/messages.jsonl"
COMMANDS_DEFAULT="$HOME/.claude/commands"
SHELL_DEFAULT="$HOME/.claude-message.sh"

MAILBOX_PATH="$MAILBOX_DEFAULT"
COMMANDS_DIR="$COMMANDS_DEFAULT"
SHELL_DST="$SHELL_DEFAULT"
INSTALL_SHELL=1
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mailbox) shift; MAILBOX_PATH="${1:?}";;
    --mailbox=*) MAILBOX_PATH="${1#*=}";;
    --commands) shift; COMMANDS_DIR="${1:?}";;
    --commands=*) COMMANDS_DIR="${1#*=}";;
    --shell) shift; SHELL_DST="${1:?}";;
    --shell=*) SHELL_DST="${1#*=}";;
    --no-shell) INSTALL_SHELL=0;;
    --uninstall) UNINSTALL=1;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
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
MARKER_BEGIN="# >>> claude-message >>>"
MARKER_END="# <<< claude-message <<<"

strip_rc_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  python3 - "$rc" <<'PY'
import sys, re
p = sys.argv[1]
with open(p) as f: s = f.read()
# Replace the matched (including one leading \n) with a single \n to preserve surrounding
# content separation; then drop that leading \n iff the original file did not start with one.
s2 = re.sub(r"(?:^|\n)# >>> claude-message >>>.*?# <<< claude-message <<<\n?", "\n", s, flags=re.DOTALL)
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

if [[ "$UNINSTALL" -eq 1 ]]; then
  for f in "${CMDS[@]}"; do
    rm -f "$COMMANDS_DIR/$f"
  done
  rm -f "$MAILBOX_PATH"
  rm -f "$SHELL_DST"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    strip_rc_block "$rc"
  done
  mailbox_dir=$(dirname "$MAILBOX_PATH")
  [[ -d "$mailbox_dir" ]] && find "$mailbox_dir" -maxdepth 1 -name ".seen-*" -delete 2>/dev/null || true
  echo "claude-message uninstalled."
  echo "  removed: ${CMDS[*]/#/$COMMANDS_DIR/}"
  echo "  removed: $MAILBOX_PATH"
  echo "  removed: $SHELL_DST (and rc source blocks)"
  exit 0
fi

mkdir -p "$COMMANDS_DIR"
mkdir -p "$(dirname "$MAILBOX_PATH")"
touch "$MAILBOX_PATH"
chmod 0644 "$MAILBOX_PATH"

for f in "${CMDS[@]}"; do
  src="$SCRIPT_DIR/commands/$f"
  if [[ ! -f "$src" ]]; then
    echo "missing source file: $src" >&2
    exit 1
  fi
  cp "$src" "$COMMANDS_DIR/$f"
done

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

cat <<EOF
claude-message installed.

  commands: $COMMANDS_DIR/{message-send,message-inbox,message-reply}.md
  mailbox:  $MAILBOX_PATH$SHELL_NOTE

Use from any Claude Code session in a repo under ~/dev/:

  /message-send <recipient-alias> <body…>
  /message-inbox
  /message-reply <body…>

From a terminal (0 Claude tokens):

  msg send <to> <body…>
  msg              # unseen
  msg reply <body> # reply to most recent
  msg tail         # follow live

Sender alias defaults to \$(basename "\$PWD"). Override per-repo by putting the
alias on the first line of a \`.claude-message\` file at the repo root.

Uninstall: $SCRIPT_DIR/install.sh --uninstall
EOF
