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
#                         auto              detect installed tools and integrate
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
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
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
    all) echo "cursor copilot copilot-cli antigravity codex zed";;
    auto)
      local out=""
      [[ -d "$HOME/.cursor" ]] && out="$out cursor"
      [[ -d ".git" ]] && out="$out copilot"
      [[ -d "$HOME/.copilot" ]] && out="$out copilot-cli"
      [[ -d "$HOME/.gemini" ]] && out="$out antigravity"
      [[ -d "$HOME/.codex" ]] && out="$out codex"
      if [[ -d "$HOME/.config/zed" || -d "$HOME/Library/Application Support/Zed" ]]; then
        out="$out zed"
      fi
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

# Append marker block via O_NOFOLLOW — refuses to follow symlinks (TOCTOU-safe).
append_marker_block() {
  local dst="$1" block; block=$(marker_block)
  python3 - "$dst" "$block" <<'PY'
import sys, os
p, data = sys.argv[1], sys.argv[2]
try:
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o644)
except OSError:
    print(f"  refusing to follow symlink at {p}", file=sys.stderr)
    sys.exit(1)
with os.fdopen(fd, "a") as f:
    f.write(data + "\n")
PY
}

# Strip the canonical marker block by EXACT-match substring removal.
# Defends against attacker-planted marker pairs wrapping legitimate user content:
# the regex-based predecessor would have stripped `<open>...arbitrary user content...<close>`.
# This implementation only removes byte-for-byte what we wrote.
strip_marker_block() {
  local dst="$1"
  [[ -f "$dst" ]] || return 0
  local expected; expected=$(marker_block)
  python3 - "$dst" "$expected" <<'PY'
import sys, os
p, expected = sys.argv[1], sys.argv[2]
with open(p) as f: s = f.read()
if expected not in s:
    sys.exit(0)
s2 = s.replace(expected, "", 1).strip()
if s2:
    with open(p, "w") as f: f.write(s2 + "\n")
else:
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
  local dst=".github/copilot-instructions.md"
  if [[ -f "$dst" ]] && grep -qF "<!-- >>> agent-message >>> -->" "$dst"; then
    echo "  copilot: $dst (already integrated)"
    return 0
  fi
  if append_marker_block "$dst"; then
    echo "  copilot: $dst"
  fi
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
  if [[ -f "$dst" ]] && grep -qF "<!-- >>> agent-message >>> -->" "$dst"; then
    echo "  $label: $dst (already integrated)"
    return 0
  fi
  if append_marker_block "$dst"; then
    echo "  $label: $dst"
  fi
}

uninstall_repo_root_md() {
  strip_marker_block "$1"
}

# Append marker to a per-user global path under $HOME (no repo gate, no cwd dependency).
# Defends against:
#   - symlinked parent dir (e.g. ~/.gemini → /attacker/dir): mkdir -p silently no-ops on
#     a symlink-to-dir, after which O_NOFOLLOW on the final component does NOT fire.
#     Refuse if dirname is a symlink before creating or writing.
#   - symlinked target file: O_NOFOLLOW in append_marker_block.
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
  if [[ -f "$dst" ]] && grep -qF "<!-- >>> agent-message >>> -->" "$dst"; then
    echo "  $label: $dst (already integrated)"
    return 0
  fi
  if append_marker_block "$dst"; then
    echo "  $label: $dst"
  fi
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
integrate_codex()            { integrate_global_md  "codex"            "$HOME/.codex/AGENTS.md"; }
uninstall_codex()            { uninstall_global_md  "$HOME/.codex/AGENTS.md"; }

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
  echo "  removed: ~/.cursor/rules/agent-message.mdc (if present)"
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
