#!/usr/bin/env bash
# agent-message test runner. Pure bash + python3, no other deps.
# Run: ./test.sh
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAPPER="$SCRIPT_DIR/bin/agent-message-cmd"
SHELL_HELPER="$SCRIPT_DIR/shell/msg.sh"
VALIDATOR="$SCRIPT_DIR/samp-validate"

PASS=0
FAIL=0
FAILED=()

setup() {
  TMP=$(mktemp -d)
  export AGENT_MESSAGE_DIR="$TMP/.message"
  mkdir -p "$TMP/foo" "$TMP/bar"
}

teardown() {
  [[ -n "${TMP:-}" ]] && rm -rf "$TMP"
  unset TMP
}

assert_eq() {
  [[ "$1" == "$2" ]] && return 0
  echo "  ASSERT_EQ failed ($3): expected=[$1] actual=[$2]"
  return 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] && return 0
  echo "  ASSERT_CONTAINS failed ($3): needle=[$2]"
  echo "  haystack:"; echo "$1" | sed 's/^/    /'
  return 1
}

assert_file_exists() {
  [[ -f "$1" ]] && return 0
  echo "  ASSERT_FILE_EXISTS failed: $1 missing"
  return 1
}

assert_file_missing() {
  [[ ! -e "$1" ]] && return 0
  echo "  ASSERT_FILE_MISSING failed: $1 exists"
  return 1
}

run_test() {
  setup
  if "$1"; then
    echo "PASS: $1"
    PASS=$((PASS+1))
  else
    echo "FAIL: $1"
    FAIL=$((FAIL+1))
    FAILED+=("$1")
  fi
  teardown
}

# ---- wrapper tests ----

test_wrapper_round_trip() {
  ( cd "$TMP/foo" && echo "hi from foo" | "$WRAPPER" send bar ) >/dev/null
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "from=foo" "inbox sees foo" || return 1
  assert_contains "$out" "hi from foo" "inbox shows body" || return 1
  ( cd "$TMP/bar" && echo "lgtm" | "$WRAPPER" reply ) >/dev/null
  out=$( cd "$TMP/foo" && "$WRAPPER" inbox )
  assert_contains "$out" "lgtm" "foo sees reply"
}

test_wrapper_watermark() {
  ( cd "$TMP/foo" && echo "msg1" | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/bar" && "$WRAPPER" inbox ) >/dev/null
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "no new messages" "watermark suppresses re-show"
}

test_wrapper_same_second_burst() {
  ( cd "$TMP/foo" && echo "first" | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/foo" && echo "second" | "$WRAPPER" send bar ) >/dev/null
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "first" "burst: first visible" || return 1
  assert_contains "$out" "second" "burst: second visible"
}

test_wrapper_dedup_synced_log() {
  ( cd "$TMP/foo" && echo "ping" | "$WRAPPER" send bar ) >/dev/null
  cp "$AGENT_MESSAGE_DIR/log-foo.jsonl" "$AGENT_MESSAGE_DIR/log-foo-replica.jsonl"
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  local n; n=$(echo "$out" | grep -c "from=foo" || true)
  assert_eq "1" "$n" "synced duplicate dedups to 1"
}

test_wrapper_alias_traversal_blocked() {
  ( cd "$TMP/foo" || exit 1
    echo "../../../tmp/PWNED-$$" > .agent-message
    echo "evil" | "$WRAPPER" send bar ) >/dev/null
  assert_file_exists "$AGENT_MESSAGE_DIR/log-foo.jsonl" || return 1
  assert_file_missing "/tmp/PWNED-$$" || return 1
  assert_file_missing "/tmp/PWNED-$$.jsonl"
}

test_wrapper_thread_inheritance() {
  ( cd "$TMP/foo" && echo "first" | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/bar" && echo "second" | "$WRAPPER" reply ) >/dev/null
  local sent_thread reply_thread
  sent_thread=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["thread"])' \
                "$AGENT_MESSAGE_DIR/log-foo.jsonl")
  reply_thread=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["thread"])' \
                 "$AGENT_MESSAGE_DIR/log-bar.jsonl")
  assert_eq "$sent_thread" "$reply_thread" "reply inherits thread"
}

test_wrapper_thread_override() {
  ( cd "$TMP/foo" && printf '[thread:custom-id]\nbody' | "$WRAPPER" send bar ) >/dev/null
  local thread
  thread=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["thread"])' \
           "$AGENT_MESSAGE_DIR/log-foo.jsonl")
  assert_eq "custom-id" "$thread" "[thread:id] prefix override"
}

test_wrapper_id_is_content_addressed() {
  ( cd "$TMP/foo" && echo "same body" | "$WRAPPER" send bar ) >/dev/null
  local id1; id1=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["id"])' \
                   "$AGENT_MESSAGE_DIR/log-foo.jsonl")
  # Reset and resend with identical content (and identical ts via mocked time? no — ts differs)
  # Instead, verify id is 16 hex chars and reproducible from canonical content.
  [[ "${#id1}" -eq 16 ]] || { echo "  id length wrong: $id1"; return 1; }
  python3 - "$AGENT_MESSAGE_DIR/log-foo.jsonl" <<'PY' || return 1
import hashlib, json, sys
rec = json.loads(open(sys.argv[1]).readline())
core = {k: rec[k] for k in ("ts","from","to","thread","body")}
expected = hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
assert rec["id"] == expected, f'id mismatch: {rec["id"]} vs {expected}'
PY
}

# ---- shell helper tests ----
# shellcheck source=shell/msg.sh
test_msg_round_trip() {
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "hi from msg" ) >/dev/null
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "hi from msg" "msg shows message"
}

test_msg_mtime_short_circuit() {
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "ping" ) >/dev/null
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/bar" && msg ) >/dev/null
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "no new messages" "mtime short-circuit"
}

# ---- version + validator tests ----

test_wrapper_version() {
  local out; out=$("$WRAPPER" --version)
  assert_contains "$out" "agent-message" "wrapper --version mentions name" || return 1
  assert_contains "$out" "SAMP v1" "wrapper --version mentions spec"
}

test_msg_version() {
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; msg --version )
  assert_contains "$out" "msg" "msg --version mentions name" || return 1
  assert_contains "$out" "SAMP v1" "msg --version mentions spec"
}

test_validator_clean() {
  ( cd "$TMP/foo" && echo "hi" | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/bar" && echo "yo" | "$WRAPPER" reply ) >/dev/null
  local out; out=$("$VALIDATOR" "$AGENT_MESSAGE_DIR" 2>&1)
  assert_contains "$out" "OK:" "validator passes on round-trip"
}

test_validator_catches_id_tamper() {
  ( cd "$TMP/foo" && echo "hi" | "$WRAPPER" send bar ) >/dev/null
  python3 - "$AGENT_MESSAGE_DIR/log-foo.jsonl" <<'PY'
import json, sys
p = sys.argv[1]
lines = open(p).readlines()
rec = json.loads(lines[0])
rec["id"] = "0000000000000000"
lines[0] = json.dumps(rec) + "\n"
open(p, "w").writelines(lines)
PY
  local rc; "$VALIDATOR" "$AGENT_MESSAGE_DIR" >/dev/null 2>&1; rc=$?
  assert_eq "1" "$rc" "validator exits 1 on tampered id"
}

test_validator_catches_single_writer_violation() {
  ( cd "$TMP/foo" && echo "hi" | "$WRAPPER" send bar ) >/dev/null
  python3 - "$AGENT_MESSAGE_DIR/log-foo.jsonl" <<'PY'
import json, sys
p = sys.argv[1]
lines = open(p).readlines()
rec = json.loads(lines[0])
rec["from"] = "evil"
# Reset id to match new content so we test single-writer, not id mismatch.
import hashlib
core = {k: rec[k] for k in ("ts","from","to","thread","body")}
rec["id"] = hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
lines[0] = json.dumps(rec) + "\n"
open(p, "w").writelines(lines)
PY
  local out; out=$("$VALIDATOR" "$AGENT_MESSAGE_DIR" 2>&1) || true
  assert_contains "$out" "single-writer" "validator catches single-writer violation"
}

# ---- security + correctness tests ----

test_msg_alias_traversal_blocked() {
  ( cd "$TMP/foo" || exit 1
    echo "../../../tmp/PWNED-msg-$$" > .agent-message
    # shellcheck source=shell/msg.sh
    source "$SHELL_HELPER"
    msg send bar "evil" ) >/dev/null 2>&1
  assert_file_missing "/tmp/PWNED-msg-$$" || return 1
  assert_file_missing "/tmp/PWNED-msg-$$.jsonl" || return 1
  assert_file_exists "$AGENT_MESSAGE_DIR/log-unknown.jsonl"
}

test_wrapper_single_writer_runtime_enforced() {
  ( cd "$TMP/foo" && echo "legit" | "$WRAPPER" send bar ) >/dev/null
  python3 - "$AGENT_MESSAGE_DIR" <<'PY'
import json, hashlib, time, sys, os
d = sys.argv[1]
ts = int(time.time())
core = {"ts":ts,"from":"foo","to":"bar","thread":"forged","body":"FORGED"}
i = hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
rec = {"id":i, **core}
with open(os.path.join(d, "log-mallory.jsonl"), "w") as f:
    f.write(json.dumps(rec, ensure_ascii=False)+"\n")
PY
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "legit" "legit message visible" || return 1
  if [[ "$out" == *"FORGED"* ]]; then
    echo "  reader showed forged record from log-mallory.jsonl"
    return 1
  fi
}

test_wrapper_nfc_body() {
  # NFD: 'cafe' + combining acute (\xcc\x81). Should normalize to NFC: 'café' (\xc3\xa9).
  ( cd "$TMP/foo" && printf 'cafe\xcc\x81' | "$WRAPPER" send bar ) >/dev/null
  python3 - "$AGENT_MESSAGE_DIR/log-foo.jsonl" <<'PY'
import json, sys, unicodedata
rec = json.loads(open(sys.argv[1]).readline())
b = rec["body"]
assert b == unicodedata.normalize("NFC", b), f"stored body not NFC: {b!r}"
assert "é" in b, f"body lacks NFC composed é: {b!r}"
PY
}

test_msg_thread_strip_whitespace() {
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER" && cd "$TMP/foo" && msg send bar "[thread:  spaced  ] body" ) >/dev/null
  local thread
  thread=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["thread"])' \
           "$AGENT_MESSAGE_DIR/log-foo.jsonl")
  assert_eq "spaced" "$thread" "shell strips whitespace around [thread:id]"
}

test_wrapper_symlink_log_blocks_write() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  local target="$TMP/symlink-target-$$"
  : > "$target"
  ln -s "$target" "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  ( cd "$TMP/foo" && echo "evil" | "$WRAPPER" send bar ) >/dev/null 2>&1
  local rc=$?
  [[ $rc -ne 0 ]] || { echo "  send to symlink should have failed"; return 1; }
  if [[ -s "$target" ]]; then
    echo "  symlink target was written through"
    return 1
  fi
}

test_msg_seen_deletion_forces_reread() {
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER" && cd "$TMP/foo" && msg send bar "ping" ) >/dev/null
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER" && cd "$TMP/bar" && msg ) >/dev/null
  rm -f "$AGENT_MESSAGE_DIR/.seen-bar"
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER" && cd "$TMP/bar" && msg )
  assert_contains "$out" "ping" "deleting .seen forces re-read despite mtime cache"
}

# ---- installer tests ----

test_install_integrate_cursor() {
  local fake_home="$TMP/cursor-home"
  mkdir -p "$fake_home"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=cursor
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  assert_file_missing "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  # partial uninstall: main install untouched
  assert_file_exists "$fake_home/.agent-message-cmd" || return 1
  assert_file_exists "$fake_home/.claude/commands/message-send.md"
}

test_install_integrate_copilot_preserves_user_content() {
  local fake_home="$TMP/copilot-home"
  local fake_repo="$TMP/copilot-repo"
  mkdir -p "$fake_home" "$fake_repo/.github" "$fake_repo/.git"
  printf '# Existing user content\nUse 4-space indent.\n' > "$fake_repo/.github/copilot-instructions.md"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=copilot
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  local content; content=$(cat "$fake_repo/.github/copilot-instructions.md")
  assert_contains "$content" "Existing user content" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Idempotent re-run
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  local n; n=$(grep -c "^<!-- >>> agent-message >>> -->" "$fake_repo/.github/copilot-instructions.md" || true)
  assert_eq "1" "$n" "marker block once after re-run" || return 1
  # Partial uninstall
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  content=$(cat "$fake_repo/.github/copilot-instructions.md")
  assert_contains "$content" "Existing user content" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
}

test_install_integrate_copilot_empty_file_removed() {
  local fake_home="$TMP/copilot-empty-home"
  local fake_repo="$TMP/copilot-empty-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=copilot
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_repo/.github/copilot-instructions.md"
}

test_install_integrate_all_and_full_uninstall() {
  local fake_home="$TMP/all-home"
  local fake_repo="$TMP/all-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=all
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  # Full uninstall strips main + cursor (global), but NOT copilot (per-repo, explicit only).
  local args_no_integ=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args_no_integ[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  assert_file_missing "$fake_home/.agent-message-cmd" || return 1
  # Explicit --uninstall --integrate=copilot from inside the repo strips it.
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" --integrate=copilot --uninstall >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_repo/.github/copilot-instructions.md"
}

test_install_integrate_copilot_skipped_outside_git_repo() {
  local fake_home="$TMP/non-git-home"
  local fake_dir="$TMP/non-git-dir"
  mkdir -p "$fake_home" "$fake_dir"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=copilot
  )
  ( cd "$fake_dir" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  # No .github/ created in non-git dir
  assert_file_missing "$fake_dir/.github/copilot-instructions.md"
}

test_install_integrate_antigravity_preserves_user_content() {
  local fake_home="$TMP/antigrav-home"
  local fake_repo="$TMP/antigrav-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf '# Project rules\nUse 2-space indent.\n' > "$fake_repo/AGENTS.md"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  local content; content=$(cat "$fake_repo/AGENTS.md")
  assert_contains "$content" "Project rules" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Idempotent re-run
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  local n; n=$(grep -c "^<!-- >>> agent-message >>> -->" "$fake_repo/AGENTS.md" || true)
  assert_eq "1" "$n" "marker block once after re-run" || return 1
  # Partial uninstall preserves user content
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  content=$(cat "$fake_repo/AGENTS.md")
  assert_contains "$content" "Project rules" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
}

test_install_integrate_antigravity_empty_file_removed() {
  local fake_home="$TMP/antigrav-empty-home"
  local fake_repo="$TMP/antigrav-empty-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_exists "$fake_repo/AGENTS.md" || return 1
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_repo/AGENTS.md"
}

test_install_integrate_antigravity_skipped_outside_git_repo() {
  local fake_home="$TMP/antigrav-non-git-home"
  local fake_dir="$TMP/antigrav-non-git-dir"
  mkdir -p "$fake_home" "$fake_dir"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  ( cd "$fake_dir" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_dir/AGENTS.md"
}

test_install_integrate_zed_preserves_user_content() {
  local fake_home="$TMP/zed-home"
  local fake_repo="$TMP/zed-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf 'Use TypeScript strict mode.\n' > "$fake_repo/.rules"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=zed
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  local content; content=$(cat "$fake_repo/.rules")
  assert_contains "$content" "TypeScript strict mode" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Idempotent
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  local n; n=$(grep -c "^<!-- >>> agent-message >>> -->" "$fake_repo/.rules" || true)
  assert_eq "1" "$n" "marker once after re-run" || return 1
  # Partial uninstall
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  content=$(cat "$fake_repo/.rules")
  assert_contains "$content" "TypeScript strict mode" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
}

test_install_integrate_zed_empty_file_removed() {
  local fake_home="$TMP/zed-empty-home"
  local fake_repo="$TMP/zed-empty-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=zed
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_exists "$fake_repo/.rules" || return 1
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_repo/.rules"
}

test_install_integrate_zed_skipped_outside_git_repo() {
  local fake_home="$TMP/zed-non-git-home"
  local fake_dir="$TMP/zed-non-git-dir"
  mkdir -p "$fake_home" "$fake_dir"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=zed
  )
  ( cd "$fake_dir" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_dir/.rules"
}

test_install_integrate_refuses_symlinked_dotgit() {
  local fake_home="$TMP/sym-dotgit-home"
  local fake_repo="$TMP/sym-dotgit-repo"
  local foreign_dir="$TMP/foreign"
  mkdir -p "$fake_home" "$fake_repo" "$foreign_dir"
  ln -s "$foreign_dir" "$fake_repo/.git"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  # Symlinked .git must NOT satisfy the gate — file should not be written.
  assert_file_missing "$fake_repo/AGENTS.md"
}

test_install_integrate_refuses_symlinked_target() {
  local fake_home="$TMP/sym-target-home"
  local fake_repo="$TMP/sym-target-repo"
  local foreign_file="$TMP/sensitive-file"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf 'sensitive content\n' > "$foreign_file"
  ln -s "$foreign_file" "$fake_repo/AGENTS.md"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  # Symlink target must NOT have been written through.
  local content; content=$(cat "$foreign_file")
  assert_eq "sensitive content" "$content" "symlink target unchanged"
}

test_install_uninstall_preserves_attacker_planted_marker_pair() {
  # Attacker ships AGENTS.md with the marker pair wrapping non-canonical content.
  # Exact-match strip must NOT delete it (regex predecessor would have).
  local fake_home="$TMP/atk-home"
  local fake_repo="$TMP/atk-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  cat > "$fake_repo/AGENTS.md" <<'PLANTED'
# Project rules

<!-- >>> agent-message >>> -->
arbitrary user content the attacker wants to delete
<!-- <<< agent-message <<< -->

More legitimate content here.
PLANTED
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  # User runs uninstall, expecting a no-op. Must NOT touch the file.
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  local content; content=$(cat "$fake_repo/AGENTS.md")
  assert_contains "$content" "arbitrary user content the attacker wants to delete" \
    "non-canonical block survives uninstall" || return 1
  assert_contains "$content" "More legitimate content" "trailing content survives"
}

test_install_integrate_all_includes_antigravity_and_zed() {
  local fake_home="$TMP/all-new-home"
  local fake_repo="$TMP/all-new-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=all
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  assert_file_exists "$fake_repo/AGENTS.md" || return 1
  assert_file_exists "$fake_repo/.rules"
}

test_installer_idempotent_and_uninstall() {
  local fake_home="$TMP/fake-home"
  mkdir -p "$fake_home"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  assert_file_exists "$fake_home/.agent-message-cmd" || return 1
  assert_file_exists "$fake_home/.claude/commands/message-send.md" || return 1
  # Re-run -- must not fail
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  assert_file_missing "$fake_home/.agent-message-cmd" || return 1
  assert_file_missing "$fake_home/.claude/commands/message-send.md"
}

test_installer_rc_block_idempotent_and_stripped() {
  local fake_home="$TMP/rc-home"
  mkdir -p "$fake_home"
  printf '# user content above\nexport FOO=bar\n' > "$fake_home/.zshrc"
  printf '# user content above\nexport FOO=bar\n' > "$fake_home/.bashrc"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local n
  n=$(grep -c "^# >>> agent-message >>>$" "$fake_home/.zshrc" || true)
  assert_eq "1" "$n" "rc-block injected once into .zshrc" || return 1
  n=$(grep -c "^# >>> agent-message >>>$" "$fake_home/.bashrc" || true)
  assert_eq "1" "$n" "rc-block injected once into .bashrc" || return 1
  # Re-run install -- must not duplicate
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  n=$(grep -c "^# >>> agent-message >>>$" "$fake_home/.zshrc" || true)
  assert_eq "1" "$n" "rc-block still once after re-install" || return 1
  # Uninstall -- rc-block must be stripped, user content preserved
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  n=$(grep -c "agent-message" "$fake_home/.zshrc" || true)
  assert_eq "0" "$n" "rc-block stripped from .zshrc" || return 1
  n=$(grep -c "agent-message" "$fake_home/.bashrc" || true)
  assert_eq "0" "$n" "rc-block stripped from .bashrc" || return 1
  local zshrc; zshrc=$(cat "$fake_home/.zshrc")
  assert_contains "$zshrc" "user content above" "user content preserved in .zshrc" || return 1
  assert_contains "$zshrc" "FOO=bar" "user export preserved in .zshrc"
}

# ---- run ----

TESTS=(
  test_wrapper_round_trip
  test_wrapper_watermark
  test_wrapper_same_second_burst
  test_wrapper_dedup_synced_log
  test_wrapper_alias_traversal_blocked
  test_wrapper_thread_inheritance
  test_wrapper_thread_override
  test_wrapper_id_is_content_addressed
  test_msg_round_trip
  test_msg_mtime_short_circuit
  test_wrapper_version
  test_msg_version
  test_validator_clean
  test_validator_catches_id_tamper
  test_validator_catches_single_writer_violation
  test_msg_alias_traversal_blocked
  test_wrapper_single_writer_runtime_enforced
  test_wrapper_nfc_body
  test_msg_thread_strip_whitespace
  test_wrapper_symlink_log_blocks_write
  test_msg_seen_deletion_forces_reread
  test_install_integrate_cursor
  test_install_integrate_copilot_preserves_user_content
  test_install_integrate_copilot_empty_file_removed
  test_install_integrate_all_and_full_uninstall
  test_install_integrate_copilot_skipped_outside_git_repo
  test_install_integrate_antigravity_preserves_user_content
  test_install_integrate_antigravity_empty_file_removed
  test_install_integrate_antigravity_skipped_outside_git_repo
  test_install_integrate_zed_preserves_user_content
  test_install_integrate_zed_empty_file_removed
  test_install_integrate_zed_skipped_outside_git_repo
  test_install_integrate_refuses_symlinked_dotgit
  test_install_integrate_refuses_symlinked_target
  test_install_uninstall_preserves_attacker_planted_marker_pair
  test_install_integrate_all_includes_antigravity_and_zed
  test_installer_idempotent_and_uninstall
  test_installer_rc_block_idempotent_and_stripped
)

echo "running ${#TESTS[@]} tests"
echo
for t in "${TESTS[@]}"; do
  run_test "$t"
done

echo
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "failed:"
  for n in "${FAILED[@]}"; do echo "  - $n"; done
  exit 1
fi
