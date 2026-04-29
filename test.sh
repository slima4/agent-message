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
