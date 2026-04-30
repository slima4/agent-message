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

test_wrapper_mtime_short_circuit() {
  ( cd "$TMP/foo" && echo "ping" | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/bar" && "$WRAPPER" inbox ) >/dev/null
  assert_file_exists "$AGENT_MESSAGE_DIR/.mtime-bar" || return 1
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "no new messages" "wrapper mtime short-circuit"
}

test_wrapper_seen_deletion_forces_reread() {
  ( cd "$TMP/foo" && echo "ping" | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/bar" && "$WRAPPER" inbox ) >/dev/null
  rm -f "$AGENT_MESSAGE_DIR/.seen-bar"
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "ping" "deleting .seen forces re-read despite mtime cache"
}

test_wrapper_mtime_sc_speedup_gate() {
  # Wallclock perf gate: SC hit must be ≥2x faster than cold parse on a 20k-record log.
  # Median both cold and warm to dampen CI runner jitter.
  python3 - "$AGENT_MESSAGE_DIR" "$WRAPPER" "$TMP/bar" <<'PY' || return 1
import hashlib, json, os, statistics, subprocess, sys, time
d, wrapper, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(d, exist_ok=True)
base = int(time.time()) - 200000
with open(f"{d}/log-alice.jsonl", "w") as f:
    for i in range(20000):
        core = {"ts": base + i, "from": "alice", "to": "bar",
                "thread": f"t-{i}", "body": f"msg {i} body padding"}
        mid = hashlib.sha256(json.dumps(core, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
        f.write(json.dumps({"id": mid, **core}) + "\n")
env = {**os.environ, "AGENT_MESSAGE_DIR": d}
def run_inbox():
    s = time.monotonic()
    subprocess.run([wrapper, "inbox"], cwd=cwd, env=env, check=True, capture_output=True)
    return (time.monotonic() - s) * 1000
def cold_run():
    for n in (".seen-bar", ".mtime-bar"):
        try: os.unlink(f"{d}/{n}")
        except FileNotFoundError: pass
    return run_inbox()
cold = statistics.median(cold_run() for _ in range(2))
warm = statistics.median(run_inbox() for _ in range(2))
ratio = cold / warm if warm > 0 else float("inf")
print(f"  cold={cold:.1f}ms warm={warm:.1f}ms ratio={ratio:.2f}x")
if ratio < 2.0:
    print(f"  FAIL: SC speedup {ratio:.2f}x below 2x threshold")
    sys.exit(1)
PY
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

test_install_integrate_antigravity_repo_preserves_user_content() {
  local fake_home="$TMP/antigrav-repo-home"
  local fake_repo="$TMP/antigrav-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf '# Project rules\nUse 2-space indent.\n' > "$fake_repo/AGENTS.md"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity-repo
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

test_install_integrate_antigravity_repo_empty_file_removed() {
  local fake_home="$TMP/antigrav-empty-home"
  local fake_repo="$TMP/antigrav-empty-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity-repo
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_exists "$fake_repo/AGENTS.md" || return 1
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_repo/AGENTS.md"
}

test_install_integrate_antigravity_repo_skipped_outside_git_repo() {
  local fake_home="$TMP/antigrav-non-git-home"
  local fake_dir="$TMP/antigrav-non-git-dir"
  mkdir -p "$fake_home" "$fake_dir"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity-repo
  )
  ( cd "$fake_dir" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  assert_file_missing "$fake_dir/AGENTS.md"
}

test_install_integrate_antigravity_global_writes_to_home_gemini() {
  local fake_home="$TMP/antigrav-global-home"
  mkdir -p "$fake_home"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local dst="$fake_home/.gemini/AGENTS.md"
  assert_file_exists "$dst" || return 1
  grep -qF "<!-- >>> agent-message >>> -->" "$dst" || { echo "  marker not in $dst"; return 1; }
  # Idempotent re-run
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local n; n=$(grep -c "^<!-- >>> agent-message >>> -->" "$dst" || true)
  assert_eq "1" "$n" "marker once after re-run" || return 1
  # Partial uninstall removes empty file
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  assert_file_missing "$dst"
}

test_install_integrate_antigravity_global_preserves_existing_gemini_md() {
  local fake_home="$TMP/antigrav-global-pre-home"
  mkdir -p "$fake_home/.gemini"
  printf '# Existing Gemini rules\nbe terse.\n' > "$fake_home/.gemini/AGENTS.md"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local dst="$fake_home/.gemini/AGENTS.md"
  local content; content=$(cat "$dst")
  assert_contains "$content" "Existing Gemini rules" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Partial uninstall preserves user content
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  content=$(cat "$dst")
  assert_contains "$content" "Existing Gemini rules" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
}

test_install_integrate_copilot_cli_writes_to_home_copilot() {
  local fake_home="$TMP/copilot-cli-home"
  mkdir -p "$fake_home"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=copilot-cli
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local dst="$fake_home/.copilot/copilot-instructions.md"
  assert_file_exists "$dst" || return 1
  grep -qF "<!-- >>> agent-message >>> -->" "$dst" || { echo "  marker not in $dst"; return 1; }
  # Idempotent
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local n; n=$(grep -c "^<!-- >>> agent-message >>> -->" "$dst" || true)
  assert_eq "1" "$n" "marker once after re-run" || return 1
  # Uninstall
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  assert_file_missing "$dst"
}

test_install_integrate_copilot_cli_preserves_existing_instructions() {
  local fake_home="$TMP/copilot-cli-pre-home"
  mkdir -p "$fake_home/.copilot"
  printf '# My personal Copilot rules\nUse pytest.\n' > "$fake_home/.copilot/copilot-instructions.md"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=copilot-cli
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local dst="$fake_home/.copilot/copilot-instructions.md"
  local content; content=$(cat "$dst")
  assert_contains "$content" "My personal Copilot rules" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  content=$(cat "$dst")
  assert_contains "$content" "My personal Copilot rules" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
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
    --integrate=antigravity-repo
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
    --integrate=antigravity-repo
  )
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 ) || return 1
  # Symlink target must NOT have been written through.
  local content; content=$(cat "$foreign_file")
  assert_eq "sensitive content" "$content" "symlink target unchanged"
}

test_install_integrate_global_refuses_symlinked_parent_dir() {
  # Symlinked parent dir (e.g. ~/.gemini → /attacker/dir) bypasses O_NOFOLLOW
  # because the FINAL component is not a symlink. Helper must refuse pre-write.
  local fake_home="$TMP/sym-parent-home"
  local attacker_dir="$TMP/attacker"
  mkdir -p "$fake_home" "$attacker_dir"
  ln -s "$attacker_dir" "$fake_home/.gemini"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  # No file written under the attacker dir.
  assert_file_missing "$attacker_dir/AGENTS.md" || return 1
  # And nothing written under the symlink path itself.
  if [[ -e "$fake_home/.gemini/AGENTS.md" && ! -L "$fake_home/.gemini/AGENTS.md" ]]; then
    # Only fails if the file was created via the symlink.
    if [[ -f "$attacker_dir/AGENTS.md" ]]; then
      echo "  symlinked parent was followed; attacker dir written"
      return 1
    fi
  fi
}

test_install_uninstall_global_preserves_attacker_planted_marker() {
  # Same defense as per-repo: exact-match strip must not delete attacker-planted
  # marker pairs around legitimate user content in the global global path.
  local fake_home="$TMP/atk-global-home"
  mkdir -p "$fake_home/.gemini"
  cat > "$fake_home/.gemini/AGENTS.md" <<'PLANTED'
# Existing rules

<!-- >>> agent-message >>> -->
arbitrary content the attacker wants to delete via uninstall
<!-- <<< agent-message <<< -->

More rules.
PLANTED
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 || return 1
  local content; content=$(cat "$fake_home/.gemini/AGENTS.md")
  assert_contains "$content" "arbitrary content the attacker wants to delete" \
    "non-canonical block survives uninstall" || return 1
  assert_contains "$content" "More rules" "trailing content survives"
}

test_install_integrate_global_refuses_symlinked_target() {
  # O_NOFOLLOW must also defend the global path (~/.gemini/AGENTS.md).
  local fake_home="$TMP/sym-global-home"
  local foreign_file="$TMP/sensitive-global"
  mkdir -p "$fake_home/.gemini"
  printf 'sensitive\n' > "$foreign_file"
  ln -s "$foreign_file" "$fake_home/.gemini/AGENTS.md"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
    --integrate=antigravity
  )
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null 2>&1 || return 1
  local content; content=$(cat "$foreign_file")
  assert_eq "sensitive" "$content" "global symlink target unchanged"
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
    --integrate=antigravity-repo
  )
  # User runs uninstall, expecting a no-op. Must NOT touch the file.
  ( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" --uninstall >/dev/null 2>&1 ) || return 1
  local content; content=$(cat "$fake_repo/AGENTS.md")
  assert_contains "$content" "arbitrary user content the attacker wants to delete" \
    "non-canonical block survives uninstall" || return 1
  assert_contains "$content" "More legitimate content" "trailing content survives"
}

test_install_integrate_all_includes_global_and_per_repo() {
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
  # Global integrations
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_home/.gemini/AGENTS.md" || return 1
  assert_file_exists "$fake_home/.copilot/copilot-instructions.md" || return 1
  # Per-repo (cwd) integrations — `all` does NOT include antigravity-repo
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  assert_file_exists "$fake_repo/.rules" || return 1
  # antigravity-repo is opt-in only; --integrate=all should NOT have written ./AGENTS.md
  assert_file_missing "$fake_repo/AGENTS.md"
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
  test_wrapper_mtime_short_circuit
  test_wrapper_seen_deletion_forces_reread
  test_wrapper_mtime_sc_speedup_gate
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
  test_install_integrate_antigravity_repo_preserves_user_content
  test_install_integrate_antigravity_repo_empty_file_removed
  test_install_integrate_antigravity_repo_skipped_outside_git_repo
  test_install_integrate_antigravity_global_writes_to_home_gemini
  test_install_integrate_antigravity_global_preserves_existing_gemini_md
  test_install_integrate_copilot_cli_writes_to_home_copilot
  test_install_integrate_copilot_cli_preserves_existing_instructions
  test_install_integrate_zed_preserves_user_content
  test_install_integrate_zed_empty_file_removed
  test_install_integrate_zed_skipped_outside_git_repo
  test_install_integrate_refuses_symlinked_dotgit
  test_install_integrate_refuses_symlinked_target
  test_install_integrate_global_refuses_symlinked_target
  test_install_integrate_global_refuses_symlinked_parent_dir
  test_install_uninstall_preserves_attacker_planted_marker_pair
  test_install_uninstall_global_preserves_attacker_planted_marker
  test_install_integrate_all_includes_global_and_per_repo
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
