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
  unset TMP _IARGS
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

assert_not_contains() {
  [[ "$1" != *"$2"* ]] && return 0
  echo "  ASSERT_NOT_CONTAINS failed ($3): forbidden=[$2]"
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

# Create $1 (fake $HOME) and set global _IARGS to the standard installer arg block.
# Includes --no-shell (dominant case across integration tests). One test that needs
# the shell installed (test_installer_rc_block_idempotent_and_stripped) writes args directly.
_iargs() {
  mkdir -p "$1"
  _IARGS=(
    --dir "$1/.local/state/agent-message"
    --commands "$1/.claude/commands"
    --shell "$1/.agent-message.sh"
    --bin "$1/.agent-message-cmd"
    --no-shell
  )
}

# Run install.sh under fake $HOME with output suppressed. Returns installer exit code.
_install() { local home="$1"; shift; HOME="$home" "$SCRIPT_DIR/install.sh" "$@" >/dev/null 2>&1; }

# Assert the canonical marker block appears exactly once in $1.
assert_marker_once() {
  local n; n=$(grep -c "^<!-- >>> agent-message >>> -->" "$1" 2>/dev/null || true)
  assert_eq "1" "$n" "marker block once in $1"
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

# A sandboxed agent (Codex workspace-write) or a read-only sync mount can read the
# logs but not write the watermark. Reading must still work: show the messages,
# warn once, exit 0. Crashing after printing loses the messages the caller came for.
test_wrapper_readonly_dir_still_reads() {
  ( cd "$TMP/foo" && echo "sandboxed hello" | "$WRAPPER" send bar ) >/dev/null
  chmod a-w "$AGENT_MESSAGE_DIR"
  local out rc=0
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox 2>&1 ) || rc=$?
  chmod u+w "$AGENT_MESSAGE_DIR"
  assert_eq "0" "$rc" "read-only dir exits 0" || return 1
  assert_contains "$out" "sandboxed hello" "message still shown" || return 1
  assert_contains "$out" "read marker not saved" "warns once" || return 1
  assert_not_contains "$out" "Traceback" "no traceback" || return 1
  assert_file_missing "$AGENT_MESSAGE_DIR/.seen-bar"
}

test_shell_readonly_dir_still_reads() {
  ( cd "$TMP/foo" && echo "shell sandboxed" | "$WRAPPER" send bar ) >/dev/null
  chmod a-w "$AGENT_MESSAGE_DIR"
  local out rc=0
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg 2>&1 ) || rc=$?
  chmod u+w "$AGENT_MESSAGE_DIR"
  assert_eq "0" "$rc" "read-only dir exits 0" || return 1
  assert_contains "$out" "shell sandboxed" "message still shown" || return 1
  assert_contains "$out" "read marker not saved" "warns once" || return 1
  assert_not_contains "$out" "Traceback" "no traceback"
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

test_reply_rejects_two_sender_same_second_tie() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  printf '%s\n' '{"ts":1700000000,"from":"aaa","to":"bar","thread":"thread-a","body":"from aaa"}' \
    > "$AGENT_MESSAGE_DIR/log-aaa.jsonl"
  printf '%s\n' '{"ts":1700000000,"from":"zzz","to":"bar","thread":"thread-z","body":"from zzz"}' \
    > "$AGENT_MESSAGE_DIR/log-zzz.jsonl"

  local out rc
  out=$( cd "$TMP/bar" && printf 'ack' | "$WRAPPER" reply 2>&1 ); rc=$?
  assert_eq "1" "$rc" "wrapper rejects ambiguous reply" || return 1
  assert_contains "$out" "2 senders tie at newest ts=1700000000" "wrapper explains tie" || return 1
  assert_contains "$out" "aaa  [thread:thread-a]  from aaa" "wrapper lists aaa candidate" || return 1
  assert_contains "$out" "zzz  [thread:thread-z]  from zzz" "wrapper lists zzz candidate" || return 1
  assert_file_missing "$AGENT_MESSAGE_DIR/log-bar.jsonl" || return 1

  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg reply "ack" 2>&1 ); rc=$?
  assert_eq "1" "$rc" "shell rejects ambiguous reply" || return 1
  assert_contains "$out" "2 senders tie at newest ts=1700000000" "shell explains tie" || return 1
  assert_contains "$out" "aaa  [thread:thread-a]  from aaa" "shell lists aaa candidate" || return 1
  assert_contains "$out" "zzz  [thread:thread-z]  from zzz" "shell lists zzz candidate" || return 1
  assert_file_missing "$AGENT_MESSAGE_DIR/log-bar.jsonl"
}

# One sender, two threads, same ts: NOT ambiguous — §5 makes the log single-writer
# append-only, so the last line is the last arrival. Must reply, not refuse.
test_reply_same_sender_same_second_uses_log_order() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  printf '%s\n%s\n' \
    '{"ts":1700000000,"from":"aaa","to":"bar","thread":"thread-1","body":"first"}' \
    '{"ts":1700000000,"from":"aaa","to":"bar","thread":"thread-2","body":"second"}' \
    > "$AGENT_MESSAGE_DIR/log-aaa.jsonl"

  local out rc
  out=$( cd "$TMP/bar" && printf 'ack' | "$WRAPPER" reply 2>&1 ); rc=$?
  assert_eq "0" "$rc" "wrapper replies on same-sender tie" || return 1
  assert_contains "$out" "bar→aaa thread=thread-2" "wrapper picks last line" || return 1

  rm -f "$AGENT_MESSAGE_DIR/log-bar.jsonl"
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg reply "ack" 2>&1 ); rc=$?
  assert_eq "0" "$rc" "shell replies on same-sender tie" || return 1
  assert_contains "$out" "bar→aaa thread=thread-2" "shell picks last line"
}

# Newest ts wins over log filename order: aaa sorts first but is also newer.
test_reply_picks_newest_ts_not_log_order() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  printf '%s\n' '{"ts":1700000005,"from":"aaa","to":"bar","thread":"thread-a","body":"newer"}' \
    > "$AGENT_MESSAGE_DIR/log-aaa.jsonl"
  printf '%s\n' '{"ts":1700000000,"from":"zzz","to":"bar","thread":"thread-z","body":"older"}' \
    > "$AGENT_MESSAGE_DIR/log-zzz.jsonl"

  local out rc
  out=$( cd "$TMP/bar" && printf 'ack' | "$WRAPPER" reply 2>&1 ); rc=$?
  assert_eq "0" "$rc" "wrapper replies across logs" || return 1
  assert_contains "$out" "bar→aaa thread=thread-a" "wrapper replies to newest sender" || return 1

  rm -f "$AGENT_MESSAGE_DIR/log-bar.jsonl"
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg reply "ack" 2>&1 ); rc=$?
  assert_eq "0" "$rc" "shell replies across logs" || return 1
  assert_contains "$out" "bar→aaa thread=thread-a" "shell replies to newest sender"
}

# Body rendering. Until 1.2.0 every reader printed body.splitlines()[0][:80], so a
# multi-line message reached the reader as its first line with no hint of the rest.
# Every body in this suite was single-line, which is why it survived three releases.
test_inbox_full_body_parity_wrapper_and_shell() {
  ( cd "$TMP/foo" && printf 'Funny story:\n\nline two\n\n-- foo' | "$WRAPPER" send bar ) >/dev/null
  local w s
  w=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$w" "line two" "wrapper shows body past line 1" || return 1
  assert_contains "$w" "-- foo" "wrapper shows last line" || return 1
  assert_not_contains "$w" "elided" "full body needs no elision note" || return 1
  rm -f "$AGENT_MESSAGE_DIR/.seen-bar" "$AGENT_MESSAGE_DIR/.mtime-bar"
  # shellcheck source=shell/msg.sh
  s=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_eq "$w" "$s" "wrapper and shell render identically"
}

# Full bodies print untrusted text, so a body line must not be able to pose as a
# record header. Every body line is indented; headers are not.
test_inbox_body_cannot_spoof_header() {
  ( cd "$TMP/foo" && printf 'legit\n[01-01 00:00] from=admin id=deadbeef thread=spoof:' | "$WRAPPER" send bar ) >/dev/null
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "  [01-01 00:00] from=admin" "spoof line is indented" || return 1
  local n; n=$(printf '%s\n' "$out" | grep -c '^\[01-01' || true)
  assert_eq "0" "$n" "no body line sits at header column"
}

test_inbox_oversized_body_elided_not_silent() {
  local big; big=$(python3 -c "print('y'*9000)")
  ( cd "$TMP/foo" && printf 'headline\n%s' "$big" | "$WRAPPER" send bar ) >/dev/null
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "headline" "first line still shown" || return 1
  assert_contains "$out" "chars elided" "elision announced, never silent" || return 1
  assert_contains "$out" "inbox raw" "elision names the recovery path" || return 1
  [[ ${#out} -lt 2000 ]] || { echo "  oversized body not bounded: ${#out} chars"; return 1; }

  rm -f "$AGENT_MESSAGE_DIR/.seen-bar" "$AGENT_MESSAGE_DIR/.mtime-bar"
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "chars elided" "shell announces elision" || return 1
  assert_contains "$out" "msg cat " "shell elision names msg cat"
}

# One huge record must not exhaust a reading agent's context, and neither must
# many medium ones — the budget is per run, not per message.
test_inbox_budget_bounds_total_output() {
  local big n; big=$(python3 -c "print('x'*3000)")
  for n in 1 2 3 4 5; do
    ( cd "$TMP/foo" && printf 'msg%s\n%s' "$n" "$big" | "$WRAPPER" send bar ) >/dev/null
  done
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "chars elided" "budget exhaustion announced" || return 1
  assert_contains "$out" "5 new from: foo" "all 5 still listed" || return 1
  [[ ${#out} -lt 12000 ]] || { echo "  output $((${#out})) chars exceeds budget bound"; return 1; }
}

# `all` is the re-read mode (watermark ignored), so it must show bodies. When it
# didn't, a re-reading agent escalated inbox -> all -> raw: three calls for one op.
test_inbox_all_mode_shows_full_body() {
  ( cd "$TMP/foo" && printf 'first line\nsecond line' | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/bar" && "$WRAPPER" inbox ) >/dev/null   # consume the watermark
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "no new messages" "default is empty after watermark" || return 1
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox all )
  assert_contains "$out" "second line" "all shows body past line 1" || return 1
  assert_not_contains "$out" "elided" "re-read needs no raw fallback" || return 1
  assert_contains "$out" "1 total from: foo" "all counts totals, not new" || return 1
  assert_not_contains "$out" "new from" "re-read must not call old messages new"
}

# Budget is spent newest-first: on a long archive the recent messages are the ones
# worth the tokens, even though output stays in ts order.
test_inbox_budget_favours_newest() {
  # No sleep: one sender, one log, appended in order, and the ts sort is stable —
  # so send order is display order even when all three land in the same second.
  local big n; big=$(python3 -c "print('x'*5000)")
  for n in 1 2 3; do
    ( cd "$TMP/foo" && printf 'marker%s\n%s' "$n" "$big" | "$WRAPPER" send bar ) >/dev/null
  done
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  # 3 x 5000 over an 8000 budget: newest is funded, oldest elided.
  local newest_full oldest_full
  newest_full=$(printf '%s\n' "$out" | grep -c "^  marker3$" || true)
  oldest_full=$(printf '%s\n' "$out" | grep -c "^  marker1$" || true)
  assert_eq "1" "$newest_full" "newest message listed" || return 1
  assert_eq "1" "$oldest_full" "oldest message still listed" || return 1
  # The elision must land on the oldest, not the newest.
  printf '%s\n' "$out" | grep -A1 "^  marker1$" | grep -q "elided" \
    || { echo "  oldest message was not the one elided"; return 1; }
  printf '%s\n' "$out" | grep -A1 "^  marker3$" | grep -q "elided" \
    && { echo "  newest message was elided while budget went to older ones"; return 1; }
  return 0
}

# `all` is unbounded in message count — the body budget caps bytes, not records —
# so a context-limited reader needs a bounded re-read. git log -2, essentially.
test_inbox_count_bounded_reread() {
  local i
  for i in 1 2 3 4; do
    ( cd "$TMP/foo" && printf 'msg%s\nbody %s' "$i" "$i" | "$WRAPPER" send bar ) >/dev/null
  done
  # Default is bounded by unread, not by count: 4 unread means all 4, not the last n.
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "4 new from: foo" "default shows every unread message" || return 1
  assert_contains "$out" "msg1" "default withholds nothing unread" || return 1

  out=$( cd "$TMP/bar" && "$WRAPPER" inbox 2 )
  # Already read above, so these come back only because count ignores read state.
  assert_contains "$out" "msg3" "count shows 2nd-latest" || return 1
  assert_contains "$out" "msg4" "count shows latest" || return 1
  assert_not_contains "$out" "msg1" "count excludes older" || return 1
  assert_not_contains "$out" "msg2" "count excludes older" || return 1
  assert_contains "$out" "body 4" "count shows full bodies" || return 1
  assert_contains "$out" "2 of 4 from: foo" "count reports what it withheld" || return 1

  # Bounded re-read must not touch the watermark.
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "no new messages" "count left the watermark alone" || return 1

  # A count larger than the store is not an error.
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox 99 )
  assert_contains "$out" "4 of 4 from: foo" "oversized count clamps to what exists" || return 1

  local s
  # shellcheck source=shell/msg.sh
  s=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg 2 )
  assert_eq "$( cd "$TMP/bar" && "$WRAPPER" inbox 2 )" "$s" "wrapper and shell agree on count mode"
}

test_inbox_count_rejects_zero() {
  ( cd "$TMP/foo" && echo hi | "$WRAPPER" send bar ) >/dev/null
  local out rc
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox 0 2>&1 ); rc=$?
  assert_eq "1" "$rc" "wrapper rejects count 0" || return 1
  assert_contains "$out" "count must be >= 1" "wrapper explains" || return 1
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg 0 2>&1 ); rc=$?
  assert_eq "2" "$rc" "shell rejects count 0" || return 1
  assert_contains "$out" "count must be >= 1" "shell explains" || return 1
  # A non-numeric mode still reports unknown, not a count.
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox bogus 2>&1 ); rc=$?
  assert_eq "1" "$rc" "unknown mode still rejected" || return 1
  assert_contains "$out" "unknown mode: bogus" "unknown mode message intact"
}

# str.isdigit() accepts digit-like characters int() then rejects ('²' -> ValueError,
# an uncaught traceback) and ones the shell's [!0-9] test would not ('٢'). Count
# parsing is ASCII-only in both impls so neither crashes nor diverges.
test_inbox_count_rejects_non_ascii_digits() {
  ( cd "$TMP/foo" && echo hi | "$WRAPPER" send bar ) >/dev/null
  local out rc ch
  for ch in '²' '٢'; do
    out=$( cd "$TMP/bar" && "$WRAPPER" inbox "$ch" 2>&1 ); rc=$?
    assert_eq "1" "$rc" "wrapper rejects '$ch'" || return 1
    assert_contains "$out" "unknown mode" "wrapper reports unknown mode for '$ch'" || return 1
    assert_not_contains "$out" "Traceback" "wrapper must not crash on '$ch'" || return 1
    # shellcheck source=shell/msg.sh
    out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg "$ch" 2>&1 ); rc=$?
    assert_eq "1" "$rc" "shell rejects '$ch'" || return 1
    assert_contains "$out" "unknown subcommand" "shell reports unknown for '$ch'" || return 1
  done
}

test_inbox_empty_body_marked() {
  ( cd "$TMP/foo" && printf '' | "$WRAPPER" send bar ) >/dev/null
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "(empty)" "empty body distinguishable from a truncated one" || return 1
  assert_not_contains "$out" "elided" "empty body is not an elision"
}

# Writers cap the body; readers never do. Before the cap, the shell path died at
# ARG_MAX with a raw "Argument list too long" from the python3 spawn while the
# wrapper happily wrote multi-MB records nobody could read. (#9)
test_send_refuses_oversized_body() {
  local big; big=$(python3 -c "print('x'*(2*1024*1024), end='')")
  local out rc
  out=$( cd "$TMP/foo" && printf '%s' "$big" | "$WRAPPER" send bar 2>&1 ); rc=$?
  assert_eq "1" "$rc" "wrapper send refuses oversized body" || return 1
  assert_contains "$out" "limit 65536" "wrapper names the limit" || return 1
  assert_contains "$out" "send a path or link instead" "wrapper names the alternative" || return 1
  assert_file_missing "$AGENT_MESSAGE_DIR/log-foo.jsonl" || return 1

  # The shell must trip its own check before the exec, not surface E2BIG.
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "$big" 2>&1 ); rc=$?
  assert_eq "2" "$rc" "shell send refuses oversized body" || return 1
  assert_contains "$out" "limit 65536" "shell names the limit" || return 1
  assert_not_contains "$out" "Argument list too long" "shell check precedes the exec" || return 1
  assert_file_missing "$AGENT_MESSAGE_DIR/log-foo.jsonl"
}

test_reply_refuses_oversized_body() {
  ( cd "$TMP/foo" && echo "ping" | "$WRAPPER" send bar ) >/dev/null
  local big; big=$(python3 -c "print('x'*(2*1024*1024), end='')")
  local out rc
  out=$( cd "$TMP/bar" && printf '%s' "$big" | "$WRAPPER" reply 2>&1 ); rc=$?
  assert_eq "1" "$rc" "wrapper reply refuses oversized body" || return 1
  assert_contains "$out" "limit 65536" "wrapper reply names the limit" || return 1
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg reply "$big" 2>&1 ); rc=$?
  assert_eq "2" "$rc" "shell reply refuses oversized body" || return 1
  assert_not_contains "$out" "Argument list too long" "shell reply check precedes the exec" || return 1
  assert_file_missing "$AGENT_MESSAGE_DIR/log-bar.jsonl"
}

test_body_limit_boundary_is_exact() {
  local at over
  at=$(python3 -c "print('a'*65536, end='')")
  over=$(python3 -c "print('a'*65537, end='')")
  local out rc
  out=$( cd "$TMP/foo" && printf '%s' "$at" | "$WRAPPER" send bar 2>&1 ); rc=$?
  assert_eq "0" "$rc" "exactly at the limit is accepted" || return 1
  assert_contains "$out" "sent foo" "at-limit send succeeds" || return 1
  out=$( cd "$TMP/foo" && printf '%s' "$over" | "$WRAPPER" send bar 2>&1 ); rc=$?
  assert_eq "1" "$rc" "one char over is refused" || return 1
  assert_contains "$out" "body is 65537 chars" "error reports the actual size"
}

# Readers apply no cap: a record written by another impl, or by hand, is read
# whatever its size — only the display budget bounds what is printed.
test_reader_accepts_oversized_record() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  python3 - "$AGENT_MESSAGE_DIR" <<'PY'
import json, os, sys, time
d = sys.argv[1]
rec = {"ts": int(time.time()), "from": "foo", "to": "bar",
       "thread": "huge", "body": "H" + "x" * (200 * 1024)}
with open(os.path.join(d, "log-foo.jsonl"), "w", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "1 new from: foo" "reader shows the oversized record" || return 1
  assert_contains "$out" "chars elided" "reader elides rather than refusing" || return 1
  assert_not_contains "$out" "limit 65536" "reader does not apply the writer cap"
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

test_wrapper_inbox_shows_active_alias() {
  # cwd-derived alias is a footgun: cd into a subdir and your inbox silently
  # shifts identity. inbox must show the active alias on every path so the
  # user catches drift in one glance.
  local out
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "(as bar)" "empty inbox shows alias" || return 1
  ( cd "$TMP/foo" && echo "ping" | "$WRAPPER" send bar ) >/dev/null
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "(as bar)" "footer shows alias when messages present" || return 1
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "(as bar)" "mtime short-circuit shows alias" || return 1
  # Negative: alias must change when cwd changes.
  out=$( cd "$TMP/foo" && "$WRAPPER" inbox )
  assert_contains "$out" "(as foo)" "alias reflects cwd basename"
}

test_wrapper_dotted_alias_watermark() {
  # ALIAS_RE permits dots. _aw must not use Path.with_suffix — for alias
  # "host.local" that gives ".seen-host.tmp" (drops .local), risking collision
  # with alias "host" mid-write and orphaned tmps that masquerade as another
  # alias's watermark on crash.
  mkdir -p "$TMP/dotbox"
  echo "host.local" > "$TMP/dotbox/.agent-message"
  ( cd "$TMP/foo" && echo "ping" | "$WRAPPER" send host.local ) >/dev/null
  ( cd "$TMP/dotbox" && "$WRAPPER" inbox ) >/dev/null
  assert_file_exists "$AGENT_MESSAGE_DIR/.seen-host.local" || return 1
  assert_file_exists "$AGENT_MESSAGE_DIR/.mtime-host.local" || return 1
  local out; out=$( cd "$TMP/dotbox" && "$WRAPPER" inbox )
  assert_contains "$out" "no new messages (as host.local)" "SC hit for dotted alias"
}

test_wrapper_mtime_sc_speedup_gate() {
  # Wallclock perf gate: SC hit must be ≥2x faster than cold parse on a 20k-record log.
  # Median cold over 3 runs; min warm (true SC cost — least runner contention).
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
cold = statistics.median(cold_run() for _ in range(3))
warm = min(run_inbox() for _ in range(3))
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

test_wrapper_logs_already_returns_list() {
  # _logs() returns list[Path] (sorted glob comprehension), called once per
  # iter_to. Guards against future "precompute log files" wraps that add a
  # copy allocation for zero speedup.
  python3 - "$WRAPPER" "$AGENT_MESSAGE_DIR" <<'PY' || return 1
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
mod = SourceFileLoader("amc", sys.argv[1]).load_module()
Path(sys.argv[2]).mkdir(parents=True, exist_ok=True)
r = mod._logs(Path(sys.argv[2]))
assert isinstance(r, list), f"_logs must return list, got {type(r).__name__}"
PY
}

test_wrapper_id_falsy_falls_through_to_cid() {
  # Cross-impl parity: shell/msg.sh uses `m.get("id") or cid(m)` in 5 places,
  # so wrapper must also recompute via cid() on falsy id (id:"") — not just
  # on None. Plant a malformed id:"" record alongside a conformant twin with
  # the recomputed cid; iter_to must dedup both to one.
  mkdir -p "$AGENT_MESSAGE_DIR"
  local ts="1700000000" body="parity"
  local recomputed
  recomputed=$(python3 -c "
import hashlib, json
core = {'ts': $ts, 'from': 'foo', 'to': 'bar', 'thread': 't', 'body': '$body'}
print(hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()[:16])
")
  printf '{"id":"","ts":%s,"from":"foo","to":"bar","thread":"t","body":"%s"}\n' "$ts" "$body" >  "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  printf '{"id":"%s","ts":%s,"from":"foo","to":"bar","thread":"t","body":"%s"}\n' "$recomputed" "$ts" "$body" >> "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  local n; n=$(echo "$out" | grep -c "from=foo" || true)
  assert_eq "1" "$n" "id:'' falls through to cid() and dedups against conformant twin"
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

test_msg_inbox_shows_active_alias() {
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "(as bar)" "empty inbox shows alias" || return 1
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "ping" ) >/dev/null
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "(as bar)" "footer shows alias when messages present" || return 1
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "(as bar)" "mtime short-circuit shows alias"
}

test_msg_dotted_alias_watermark() {
  mkdir -p "$TMP/dotbox"
  echo "host.local" > "$TMP/dotbox/.agent-message"
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send host.local "ping" ) >/dev/null
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/dotbox" && msg ) >/dev/null
  assert_file_exists "$AGENT_MESSAGE_DIR/.seen-host.local" || return 1
  assert_file_exists "$AGENT_MESSAGE_DIR/.mtime-host.local" || return 1
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/dotbox" && msg )
  assert_contains "$out" "no new messages (as host.local)" "SC hit for dotted alias"
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

test_cid_spec_golden() {
  # SPEC.md §3 frozen vector. Pins canonical formula across wrapper + samp-validate.
  # Body via Python \u0301 escape (NFD: e + combining acute) so editors can't silently
  # NFC-fold the source. NFD body catches NFC removal; extra field "x" catches tuple growth.
  local golden="5be5e1463ceca3cc"
  local d="$TMP/golden"; mkdir -p "$d"
  WRAPPER="$WRAPPER" python3 - "$golden" "$d" <<'PY' || return 1
import importlib.util, importlib.machinery, json, os, sys
from pathlib import Path
golden, gdir = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("w", os.environ["WRAPPER"])
spec = importlib.util.spec_from_loader("w", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
rec = {"ts": 1700000000, "from": "alice", "to": "bob", "thread": "t1", "body": "cafe\u0301", "x": "ignore"}
got = m.cid(rec)
if got != golden: sys.exit(f"  wrapper cid drifted from spec: {got} vs {golden}")
(Path(gdir) / "log-alice.jsonl").write_text(json.dumps({"id": golden, **rec}, ensure_ascii=False) + "\n")
PY
  AGENT_MESSAGE_DIR="$d" "$VALIDATOR" >/dev/null 2>&1 || { echo "  samp-validate rejected golden record"; return 1; }
}

test_cid_golden_nfd_thread() {
  # Pins canonical bytes for a record whose `thread` field is in NFD form
  # (e + combining acute). SPEC §3 names `body` as the only NFC-normalised
  # field; if a future change extends NFC normalisation to `thread` (or any
  # other field) the canonical bytes shift and this hash breaks. Cross-impl
  # consistency verified by running samp-validate against the record.
  local golden="7565a9dae7f349c6"
  local d="$TMP/golden-nfd-thread"; mkdir -p "$d"
  WRAPPER="$WRAPPER" python3 - "$golden" "$d" <<'PY' || return 1
import importlib.util, importlib.machinery, json, os, sys
from pathlib import Path
golden, gdir = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("w", os.environ["WRAPPER"])
spec = importlib.util.spec_from_loader("w", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
rec = {"ts": 1700000000, "from": "alice", "to": "bob",
       "thread": "thréad", "body": "hi", "x": "ignore"}
got = m.cid(rec)
if got != golden:
    sys.exit(f"  cid drifted: {got} vs {golden} — was NFC extended past body?")
(Path(gdir) / "log-alice.jsonl").write_text(
    json.dumps({"id": golden, **rec}, ensure_ascii=False) + "\n")
PY
  AGENT_MESSAGE_DIR="$d" "$VALIDATOR" >/dev/null 2>&1 || {
    echo "  samp-validate rejected NFD-thread golden — cross-impl drift"; return 1; }
}

# ---- security + correctness tests ----

test_msg_alias_traversal_blocked() {
  # Invalid override line falls back to cwd basename — same as the wrapper
  # (test_wrapper_alias_traversal_blocked expects log-foo.jsonl too).
  ( cd "$TMP/foo" || exit 1
    echo "../../../tmp/PWNED-msg-$$" > .agent-message
    # shellcheck source=shell/msg.sh
    source "$SHELL_HELPER"
    msg send bar "evil" ) >/dev/null 2>&1
  assert_file_missing "/tmp/PWNED-msg-$$" || return 1
  assert_file_missing "/tmp/PWNED-msg-$$.jsonl" || return 1
  assert_file_exists "$AGENT_MESSAGE_DIR/log-foo.jsonl"
}

test_alias_resolution_parity() {
  # .agent-message: invalid first line, valid second line, NO trailing newline.
  # Both impls must resolve "ali" — line-1-only reads and `read || me=""` EOF
  # handling each produced a different alias here before.
  mkdir -p "$TMP/proj"
  printf 'not valid!\nali' > "$TMP/proj/.agent-message"
  ( cd "$TMP/proj" && echo "w" | "$WRAPPER" send bar ) >/dev/null
  assert_file_exists "$AGENT_MESSAGE_DIR/log-ali.jsonl" || return 1
  rm -f "$AGENT_MESSAGE_DIR/log-ali.jsonl"
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/proj" && msg send bar "s" ) >/dev/null
  assert_file_exists "$AGENT_MESSAGE_DIR/log-ali.jsonl"
}

test_send_rejects_invalid_recipient() {
  local rc=0
  ( cd "$TMP/foo" && echo "hi" | "$WRAPPER" send 'bad alias!' ) >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] || { echo "  wrapper send accepted invalid recipient"; return 1; }
  rc=0
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send 'bad alias!' "hi" ) >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] || { echo "  msg send accepted invalid recipient"; return 1; }
  assert_file_missing "$AGENT_MESSAGE_DIR/log-foo.jsonl"
}

test_reader_tolerates_malformed_records() {
  # Missing thread, string ts, invalid UTF-8: readers must skip, not crash.
  mkdir -p "$AGENT_MESSAGE_DIR"
  {
    printf '{"ts":1700000000,"from":"peer","to":"bar","body":"no thread"}\n'
    printf '{"ts":"1700000001","from":"peer","to":"bar","thread":"t","body":"string ts"}\n'
    printf 'caf\xe9 not json\n'
  } > "$AGENT_MESSAGE_DIR/log-peer.jsonl"
  ( cd "$TMP/foo" && echo "valid msg" | "$WRAPPER" send bar ) >/dev/null
  local out rc=0
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "wrapper inbox survives malformed records" || return 1
  assert_contains "$out" "valid msg" "wrapper shows the valid message" || return 1
  rm -f "$AGENT_MESSAGE_DIR/.seen-bar" "$AGENT_MESSAGE_DIR/.mtime-bar"
  rc=0
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "shell inbox survives malformed records" || return 1
  assert_contains "$out" "valid msg" "shell shows the valid message"
}

test_wrapper_inbox_creates_missing_dir() {
  export AGENT_MESSAGE_DIR="$TMP/nonexistent/deep"
  local out rc=0
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox 2>&1 ) || rc=$?
  assert_eq "0" "$rc" "inbox on missing dir exits 0" || return 1
  assert_contains "$out" "no new messages" "inbox reports empty inbox"
}

test_thread_slug_parity_nfd() {
  # NFD body ('cafe' + combining acute): both impls must NFC-normalize BEFORE
  # deriving the slug, or the same message gets different thread → different id.
  ( cd "$TMP/foo" && printf 'cafe\xcc\x81 menu\nx' | "$WRAPPER" send bar ) >/dev/null
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "$(printf 'cafe\xcc\x81 menu\nx')" ) >/dev/null
  python3 - "$AGENT_MESSAGE_DIR/log-foo.jsonl" <<'PY'
import json, sys
recs = [json.loads(ln) for ln in open(sys.argv[1], encoding="utf-8")]
assert len(recs) == 2, f"expected 2 records, got {len(recs)}"
t1, t2 = recs[0]["thread"], recs[1]["thread"]
assert t1 == t2, f"thread divergence: wrapper={t1!r} shell={t2!r}"
assert recs[0]["body"] == recs[1]["body"], "body divergence"
PY
}

test_thread_empty_override_falls_back() {
  # "[thread: ]" strips to empty — must auto-derive, not collapse threads onto "".
  ( cd "$TMP/foo" && printf '[thread: ] hello world' | "$WRAPPER" send bar ) >/dev/null
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "[thread: ] hello world" ) >/dev/null
  python3 - "$AGENT_MESSAGE_DIR/log-foo.jsonl" <<'PY'
import json, sys
for ln in open(sys.argv[1], encoding="utf-8"):
    rec = json.loads(ln)
    assert rec["thread"].endswith("-foo-hello-world"), f"bad thread: {rec['thread']!r}"
    assert rec["body"] == "hello world", f"prefix not stripped: {rec['body']!r}"
PY
}

test_forged_id_suppression_blocked() {
  ( cd "$TMP/foo" && echo "APPROVE the merge" | "$WRAPPER" send bar ) >/dev/null
  # Forge a record in an earlier-sorting log carrying the real message's id.
  python3 - "$AGENT_MESSAGE_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
real = json.loads(open(os.path.join(d, "log-foo.jsonl"), encoding="utf-8").readline())
forged = {"id": real["id"], "ts": real["ts"], "from": "aaa", "to": "bar", "thread": "junk", "body": "junk"}
open(os.path.join(d, "log-aaa.jsonl"), "w", encoding="utf-8").write(json.dumps(forged) + "\n")
PY
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "APPROVE the merge" "wrapper: real message survives forged-id dedup" || return 1
  rm -f "$AGENT_MESSAGE_DIR/.seen-bar" "$AGENT_MESSAGE_DIR/.mtime-bar"
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "APPROVE the merge" "shell: real message survives forged-id dedup"
}

test_wrapper_mtime_cache_size_signal() {
  ( cd "$TMP/foo" && echo "one" | "$WRAPPER" send bar ) >/dev/null
  ( cd "$TMP/bar" && "$WRAPPER" inbox ) >/dev/null
  # Append while pinning mtime back — only the size signal can catch this.
  touch -r "$AGENT_MESSAGE_DIR/log-foo.jsonl" "$TMP/mtime-ref"
  ( cd "$TMP/foo" && echo "two" | "$WRAPPER" send bar ) >/dev/null
  touch -r "$TMP/mtime-ref" "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "two" "size change defeats pinned-mtime cache"
}

test_msg_mtime_cache_size_signal() {
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "one" ) >/dev/null
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/bar" && msg ) >/dev/null
  touch -r "$AGENT_MESSAGE_DIR/log-foo.jsonl" "$TMP/mtime-ref"
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg send bar "two" ) >/dev/null
  touch -r "$TMP/mtime-ref" "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "two" "shell: size change defeats pinned-mtime cache"
}

# Append a well-formed record with an arbitrary ts to $2/log-$1.jsonl.
_plant_record() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import hashlib, json, os, sys
frm, d, ts, body = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
core = {"ts": ts, "from": frm, "to": "bar", "thread": f"t-{frm}", "body": body}
i = hashlib.sha256(json.dumps(core, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, f"log-{frm}.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({"id": i, **core}) + "\n")
PY
}

test_wrapper_watermark_clock_skew_no_loss() {
  # A sender 300s in the future must not hide a later on-time message.
  _plant_record fast "$AGENT_MESSAGE_DIR" "$(($(date +%s) + 300))" "from the future"
  ( cd "$TMP/bar" && "$WRAPPER" inbox ) >/dev/null
  _plant_record slow "$AGENT_MESSAGE_DIR" "$(date +%s)" "on time"
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "on time" "honest-clock message not lost behind skewed watermark" || return 1
  out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_contains "$out" "no new messages" "watermark stable after skew"
}

test_msg_watermark_clock_skew_no_loss() {
  _plant_record fast "$AGENT_MESSAGE_DIR" "$(($(date +%s) + 300))" "from the future"
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/bar" && msg ) >/dev/null
  _plant_record slow "$AGENT_MESSAGE_DIR" "$(date +%s)" "on time"
  local out
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "on time" "shell: honest-clock message not lost behind skewed watermark" || return 1
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_contains "$out" "no new messages" "shell: watermark stable after skew"
}

test_msg_compact_own_log_only() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  printf '{"ts":1,"from":"foo","to":"bar","thread":"t","body":"a"}\n{"ts":1,"from":"foo","to":"bar","thread":"t","body":"a"}\n' > "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  printf '{"ts":1,"from":"other","to":"bar","thread":"t","body":"b"}\n{"ts":1,"from":"other","to":"bar","thread":"t","body":"b"}\n' > "$AGENT_MESSAGE_DIR/log-other.jsonl"
  local before_other; before_other=$(cat "$AGENT_MESSAGE_DIR/log-other.jsonl")
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg compact ) >/dev/null
  local n; n=$(wc -l < "$AGENT_MESSAGE_DIR/log-foo.jsonl" | tr -d ' ')
  assert_eq "1" "$n" "own log deduped" || return 1
  assert_eq "$before_other" "$(cat "$AGENT_MESSAGE_DIR/log-other.jsonl")" "foreign log untouched (§5: not ours to rewrite)"
}

test_msg_compact_preserves_unparseable() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  printf '{"ts":1,"from":"foo","to":"bar","thread":"t","body":"a"}\n{"ts":1,"from":"foo","to":"bar","thread":"t","body":"a"}\n{"truncated\n' > "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  # shellcheck source=shell/msg.sh
  ( source "$SHELL_HELPER"; cd "$TMP/foo" && msg compact ) >/dev/null
  grep -q '{"truncated' "$AGENT_MESSAGE_DIR/log-foo.jsonl" || { echo "  truncated line was destroyed"; return 1; }
  local n; n=$(wc -l < "$AGENT_MESSAGE_DIR/log-foo.jsonl" | tr -d ' ')
  assert_eq "2" "$n" "duplicate removed, truncated line kept"
}

test_validator_allows_legacy_missing_id() {
  mkdir -p "$AGENT_MESSAGE_DIR"
  printf '{"ts":1700000000,"from":"foo","to":"bar","thread":"t","body":"legacy"}\n' > "$AGENT_MESSAGE_DIR/log-foo.jsonl"
  local rc=0; "$VALIDATOR" "$AGENT_MESSAGE_DIR" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "record without id passes (SPEC §3: legacy MAY omit)"
}

test_inbox_strips_ansi_escapes() {
  ( cd "$TMP/foo" && printf 'evil \x1b[31mred\x1b[0m text' | "$WRAPPER" send bar ) >/dev/null
  local out; out=$( cd "$TMP/bar" && "$WRAPPER" inbox )
  assert_not_contains "$out" $'\x1b' "ESC stripped from wrapper inbox" || return 1
  rm -f "$AGENT_MESSAGE_DIR/.seen-bar" "$AGENT_MESSAGE_DIR/.mtime-bar"
  # shellcheck source=shell/msg.sh
  out=$( source "$SHELL_HELPER"; cd "$TMP/bar" && msg )
  assert_not_contains "$out" $'\x1b' "ESC stripped from shell inbox"
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
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=cursor )
  _install "$fake_home" "${args[@]}" || return 1
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  _install "$fake_home" "${args[@]}" || return 1
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  assert_file_missing "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  # partial uninstall: main install untouched
  assert_file_exists "$fake_home/.agent-message-cmd" || return 1
  assert_file_exists "$fake_home/.claude/commands/message-send.md"
}

test_install_uninstall_cursor_preserves_user_content() {
  local fake_home="$TMP/cursor-user-home"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=cursor )
  local dst="$fake_home/.cursor/rules/agent-message.mdc"

  _install "$fake_home" "${args[@]}" || return 1
  printf '\n# My extra Cursor rule\nKeep this line.\n' >> "$dst"
  _install "$fake_home" "${args[@]}" --uninstall || return 1

  local content; content=$(cat "$dst")
  assert_contains "$content" "My extra Cursor rule" "Cursor user edit preserved" || return 1
  assert_contains "$content" "Keep this line" "Cursor user content preserved" || return 1
  assert_not_contains "$content" "agent-message" "Cursor marker block removed"
}

test_install_uninstall_cursor_preserves_preexisting_file() {
  local fake_home="$TMP/cursor-preexisting-home"
  local dst="$fake_home/.cursor/rules/agent-message.mdc"
  local backup="$TMP/cursor-preexisting.backup"
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' '---' 'description: My own Cursor rule' '---' '' 'Keep my rule.' > "$dst"
  cp "$dst" "$backup"
  _iargs "$fake_home"

  _install "$fake_home" "${_IARGS[@]}" --integrate=cursor --uninstall || return 1
  cmp -s "$backup" "$dst" || {
    echo "  pre-existing Cursor file changed during uninstall"
    return 1
  }
}

test_install_integrate_copilot_preserves_user_content() {
  local fake_home="$TMP/copilot-home"
  local fake_repo="$TMP/copilot-repo"
  mkdir -p "$fake_home" "$fake_repo/.github" "$fake_repo/.git"
  printf '# Existing user content\nUse 4-space indent.\n' > "$fake_repo/.github/copilot-instructions.md"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=copilot )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  local content; content=$(cat "$fake_repo/.github/copilot-instructions.md")
  assert_contains "$content" "Existing user content" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Idempotent re-run
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_marker_once "$fake_repo/.github/copilot-instructions.md" || return 1
  # Partial uninstall
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
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
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=copilot )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
  assert_file_missing "$fake_repo/.github/copilot-instructions.md"
}

test_install_integrate_all_and_full_uninstall() {
  local fake_home="$TMP/all-home"
  local fake_repo="$TMP/all-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=all )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  # Full uninstall strips main + cursor (global), but NOT copilot (per-repo, explicit only).
  _iargs "$fake_home"

  local args_no_integ=( "${_IARGS[@]}" )
  ( cd "$fake_repo" && _install "$fake_home" "${args_no_integ[@]}" --uninstall ) || return 1
  assert_file_missing "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  assert_file_missing "$fake_home/.agent-message-cmd" || return 1
  # Explicit --uninstall --integrate=copilot from inside the repo strips it.
  ( cd "$fake_repo" && _install "$fake_home" --integrate=copilot --uninstall ) || return 1
  assert_file_missing "$fake_repo/.github/copilot-instructions.md"
}

test_install_integrate_copilot_skipped_outside_git_repo() {
  local fake_home="$TMP/non-git-home"
  local fake_dir="$TMP/non-git-dir"
  mkdir -p "$fake_home" "$fake_dir"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=copilot )
  ( cd "$fake_dir" && _install "$fake_home" "${args[@]}" ) || return 1
  # No .github/ created in non-git dir
  assert_file_missing "$fake_dir/.github/copilot-instructions.md"
}

test_install_integrate_antigravity_repo_preserves_user_content() {
  local fake_home="$TMP/antigrav-repo-home"
  local fake_repo="$TMP/antigrav-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf '# Project rules\nUse 2-space indent.\n' > "$fake_repo/AGENTS.md"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  local content; content=$(cat "$fake_repo/AGENTS.md")
  assert_contains "$content" "Project rules" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Idempotent re-run
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_marker_once "$fake_repo/AGENTS.md" || return 1
  # Partial uninstall preserves user content
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
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
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_exists "$fake_repo/AGENTS.md" || return 1
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
  assert_file_missing "$fake_repo/AGENTS.md"
}

test_install_integrate_antigravity_repo_works_in_non_git_dir() {
  # antigravity-repo writes ./AGENTS.md (cross-tool, not git-specific) — no git gate.
  local fake_home="$TMP/antigrav-non-git-home"
  local fake_dir="$TMP/antigrav-non-git-dir"
  mkdir -p "$fake_home" "$fake_dir"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  ( cd "$fake_dir" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_exists "$fake_dir/AGENTS.md" || return 1
  grep -qF "<!-- >>> agent-message >>> -->" "$fake_dir/AGENTS.md"
}

test_install_integrate_antigravity_repo_refuses_home_dir() {
  # cwd_is_project sanity gate refuses $HOME and / for non-git per-repo integrations.
  local fake_home="$TMP/antigrav-home-cwd"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  ( cd "$fake_home" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_missing "$fake_home/AGENTS.md"
}

test_install_integrate_antigravity_global_writes_to_home_gemini() {
  local fake_home="$TMP/antigrav-global-home"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity )
  _install "$fake_home" "${args[@]}" || return 1
  local dst="$fake_home/.gemini/AGENTS.md"
  assert_file_exists "$dst" || return 1
  grep -qF "<!-- >>> agent-message >>> -->" "$dst" || { echo "  marker not in $dst"; return 1; }
  # Idempotent re-run
  _install "$fake_home" "${args[@]}" || return 1
  assert_marker_once "$dst" || return 1
  # Partial uninstall removes empty file
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  assert_file_missing "$dst"
}

test_install_integrate_antigravity_global_preserves_existing_gemini_md() {
  local fake_home="$TMP/antigrav-global-pre-home"
  mkdir -p "$fake_home/.gemini"
  printf '# Existing Gemini rules\nbe terse.\n' > "$fake_home/.gemini/AGENTS.md"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity )
  _install "$fake_home" "${args[@]}" || return 1
  local dst="$fake_home/.gemini/AGENTS.md"
  local content; content=$(cat "$dst")
  assert_contains "$content" "Existing Gemini rules" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Partial uninstall preserves user content
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  content=$(cat "$dst")
  assert_contains "$content" "Existing Gemini rules" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
}

test_install_integrate_codex_writes_to_home_codex() {
  local fake_home="$TMP/codex-home"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=codex )
  _install "$fake_home" "${args[@]}" || return 1
  local dst="$fake_home/.codex/AGENTS.md"
  assert_file_exists "$dst" || return 1
  grep -qF "<!-- >>> agent-message >>> -->" "$dst" || { echo "  marker not in $dst"; return 1; }
  # Idempotent
  _install "$fake_home" "${args[@]}" || return 1
  assert_marker_once "$dst" || return 1
  # Uninstall
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  assert_file_missing "$dst"
}

# AGENTS.md teaches Codex the commands; config.toml is what lets the read marker
# actually save under the default workspace-write sandbox. Without it the inbox
# works but never marks anything read.
test_install_integrate_codex_writes_sandbox_writable_root() {
  local fake_home="$TMP/codex-sb-home"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=codex )
  _install "$fake_home" "${args[@]}" || return 1

  local cfg="$fake_home/.codex/config.toml"
  assert_file_exists "$cfg" || return 1
  local content; content=$(cat "$cfg")
  assert_contains "$content" "[sandbox_workspace_write]" "table written" || return 1
  assert_contains "$content" "$fake_home/.local/state/agent-message" "message dir listed" || return 1
  # Must be valid TOML — a malformed config.toml breaks Codex entirely.
  python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$cfg" 2>/dev/null \
    || { echo "  generated config.toml is not valid TOML"; return 1; }
  _install "$fake_home" "${args[@]}" || return 1
  assert_eq "1" "$(grep -c 'sandbox_workspace_write' "$cfg")" "idempotent" || return 1
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  content=$(cat "$cfg")
  assert_not_contains "$content" "sandbox_workspace_write" "stripped on uninstall"
}

test_install_integrate_codex_preserves_existing_config_toml() {
  local fake_home="$TMP/codex-cfg-home"
  mkdir -p "$fake_home/.codex"
  printf 'model = "gpt-5.6-sol"\n\n[projects."/x"]\ntrust_level = "trusted"\n' > "$fake_home/.codex/config.toml"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=codex )
  _install "$fake_home" "${args[@]}" || return 1

  local cfg="$fake_home/.codex/config.toml"
  python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$cfg" 2>/dev/null \
    || { echo "  config.toml no longer parses"; return 1; }
  local content; content=$(cat "$cfg")
  assert_contains "$content" 'model = "gpt-5.6-sol"' "user keys preserved" || return 1
  assert_contains "$content" 'trust_level = "trusted"' "user tables preserved" || return 1
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  content=$(cat "$cfg")
  assert_contains "$content" 'model = "gpt-5.6-sol"' "user keys survive uninstall" || return 1
  assert_not_contains "$content" "agent-message" "our block gone"
}

# Appending a second [sandbox_workspace_write] would be a TOML duplicate-table
# error and break Codex outright. Refuse and tell the user what to add.
test_install_integrate_codex_refuses_existing_sandbox_table() {
  local fake_home="$TMP/codex-conflict-home"
  mkdir -p "$fake_home/.codex"
  printf '[sandbox_workspace_write]\nwritable_roots = ["/tmp/mine"]\n' > "$fake_home/.codex/config.toml"
  _iargs "$fake_home"

  local out
  out=$(HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${_IARGS[@]}" --integrate=codex 2>&1)
  assert_contains "$out" "already sets [sandbox_workspace_write]" "explains the refusal" || return 1
  local content; content=$(cat "$fake_home/.codex/config.toml")
  assert_eq "1" "$(grep -c 'sandbox_workspace_write' "$fake_home/.codex/config.toml")" "no duplicate table" || return 1
  assert_contains "$content" '"/tmp/mine"' "user roots untouched"
}

test_install_integrate_codex_preserves_existing_agents_md() {
  local fake_home="$TMP/codex-pre-home"
  mkdir -p "$fake_home/.codex"
  printf '# My Codex rules\nbe terse.\n' > "$fake_home/.codex/AGENTS.md"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=codex )
  _install "$fake_home" "${args[@]}" || return 1
  local dst="$fake_home/.codex/AGENTS.md"
  local content; content=$(cat "$dst")
  assert_contains "$content" "My Codex rules" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  content=$(cat "$dst")
  assert_contains "$content" "My Codex rules" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
}

test_install_integrate_copilot_cli_writes_to_home_copilot() {
  local fake_home="$TMP/copilot-cli-home"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=copilot-cli )
  _install "$fake_home" "${args[@]}" || return 1
  local dst="$fake_home/.copilot/copilot-instructions.md"
  assert_file_exists "$dst" || return 1
  grep -qF "<!-- >>> agent-message >>> -->" "$dst" || { echo "  marker not in $dst"; return 1; }
  # Idempotent
  _install "$fake_home" "${args[@]}" || return 1
  assert_marker_once "$dst" || return 1
  # Uninstall
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  assert_file_missing "$dst"
}

test_install_integrate_copilot_cli_preserves_existing_instructions() {
  local fake_home="$TMP/copilot-cli-pre-home"
  mkdir -p "$fake_home/.copilot"
  printf '# My personal Copilot rules\nUse pytest.\n' > "$fake_home/.copilot/copilot-instructions.md"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=copilot-cli )
  _install "$fake_home" "${args[@]}" || return 1
  local dst="$fake_home/.copilot/copilot-instructions.md"
  local content; content=$(cat "$dst")
  assert_contains "$content" "My personal Copilot rules" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  content=$(cat "$dst")
  assert_contains "$content" "My personal Copilot rules" "user content preserved on uninstall" || return 1
  if [[ "$content" == *"agent-message"* ]]; then
    echo "  marker block not stripped"
    return 1
  fi
}

test_install_hint_lists_detected_unwired_global() {
  local fake_home="$TMP/hint-home"
  mkdir -p "$fake_home/.codex" "$fake_home/.cursor"
  _iargs "$fake_home"

  local out; out=$(HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${_IARGS[@]}" 2>&1)
  assert_contains "$out" "Not wired yet" "hint header" || return 1
  assert_contains "$out" "--integrate=codex" "codex offered" || return 1
  assert_contains "$out" "--integrate=cursor" "cursor offered" || return 1
  # With nothing wired the `agents:` branch is skipped. Regression guard: doing
  # that with a bare `[[ ]] &&` returned 1 and set -e killed the rest of the hint.
  assert_contains "$out" "--integrate=select" "hint not truncated" || return 1
  # copilot-cli has no signal in this fake HOME, and per-repo writers never appear.
  assert_not_contains "$out" "--integrate=copilot-cli" "undetected tool not offered" || return 1
  assert_not_contains "$out" "--integrate=zed" "per-repo writer not offered"
}

test_install_hint_omits_wired_tool() {
  local fake_home="$TMP/hint-wired-home"
  mkdir -p "$fake_home/.codex" "$fake_home/.cursor"
  _iargs "$fake_home"

  _install "$fake_home" "${_IARGS[@]}" --integrate=codex || return 1
  local out; out=$(HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${_IARGS[@]}" 2>&1)
  assert_not_contains "$out" "--integrate=codex" "wired tool dropped from hint" || return 1
  assert_contains "$out" "agents:   codex" "wired tool named in the aligned block" || return 1
  assert_contains "$out" "--integrate=cursor" "unwired tool still offered"
}

test_install_hint_confirms_when_all_wired() {
  local fake_home="$TMP/hint-allwired-home"
  mkdir -p "$fake_home/.codex"
  _iargs "$fake_home"

  _install "$fake_home" "${_IARGS[@]}" --integrate=codex || return 1
  local out; out=$(HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${_IARGS[@]}" 2>&1)
  assert_not_contains "$out" "Not wired yet" "nothing left to offer" || return 1
  assert_contains "$out" "agents:   codex" "all-wired confirmation"
}

test_install_hint_silent_when_nothing_detected() {
  local fake_home="$TMP/hint-quiet-home"
  _iargs "$fake_home"
  local out; out=$(HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${_IARGS[@]}" 2>&1)
  assert_not_contains "$out" "Not wired yet" "no hint without signals" || return 1
  assert_not_contains "$out" "agents:" "no agents row without signals"
}

test_install_select_without_tty_falls_back_to_auto() {
  local fake_home="$TMP/select-notty-home"
  mkdir -p "$fake_home/.codex"
  _iargs "$fake_home"

  local out
  out=$(HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${_IARGS[@]}" --integrate=select </dev/null 2>&1)
  assert_contains "$out" "falling back to auto" "non-TTY notice" || return 1
  assert_file_exists "$fake_home/.codex/AGENTS.md"
}

# A cancelled (or non-TTY) `--uninstall --integrate=select` must stay a partial
# uninstall. Regression guard: an empty selection previously read as "no
# --integrate given" and escalated to a full uninstall.
test_install_select_uninstall_keeps_core_install() {
  local fake_home="$TMP/select-uninstall-home"
  mkdir -p "$fake_home/.codex"
  _iargs "$fake_home"

  _install "$fake_home" "${_IARGS[@]}" --integrate=codex || return 1
  HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${_IARGS[@]}" --uninstall --integrate=select \
    </dev/null >/dev/null 2>&1 || return 1
  assert_file_missing "$fake_home/.codex/AGENTS.md" || return 1
  assert_file_exists "$fake_home/.agent-message-cmd" || return 1
  assert_file_exists "$fake_home/.claude/commands/message-send.md"
}

# Drives the real menu over a pty. Skipped where `expect` is unavailable; the
# non-TTY fallback tests above cover the rest of the path.
test_install_select_menu_picks_by_number() {
  command -v expect >/dev/null 2>&1 || { echo "  (skipped: expect not installed)"; return 0; }
  local fake_home="$TMP/select-tty-home" repo="$TMP/select-tty-repo"
  mkdir -p "$fake_home/.codex" "$fake_home/.cursor" "$repo"
  _iargs "$fake_home"

  # [4] = codex (global). Cursor is detected but unpicked, so it must stay untouched.
  ( cd "$repo" && HOME="$fake_home" expect -c "
    set timeout 30
    spawn $SCRIPT_DIR/install.sh ${_IARGS[*]} --integrate=select
    expect \">\"
    send \"4\r\"
    expect eof
  " ) >/dev/null 2>&1 || return 1
  assert_file_exists "$fake_home/.codex/AGENTS.md" || return 1
  assert_file_missing "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_missing "$repo/.rules"
}

test_install_integrate_zed_preserves_user_content() {
  local fake_home="$TMP/zed-home"
  local fake_repo="$TMP/zed-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf 'Use TypeScript strict mode.\n' > "$fake_repo/.rules"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=zed )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  local content; content=$(cat "$fake_repo/.rules")
  assert_contains "$content" "TypeScript strict mode" "user content preserved on inject" || return 1
  assert_contains "$content" "agent-message" "marker injected" || return 1
  # Idempotent
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_marker_once "$fake_repo/.rules" || return 1
  # Partial uninstall
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
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
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=zed )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_exists "$fake_repo/.rules" || return 1
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
  assert_file_missing "$fake_repo/.rules"
}

test_install_integrate_zed_works_in_non_git_dir() {
  # Zed works on any folder, git or not — no git gate.
  local fake_home="$TMP/zed-non-git-home"
  local fake_dir="$TMP/zed-non-git-dir"
  mkdir -p "$fake_home" "$fake_dir"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=zed )
  ( cd "$fake_dir" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_exists "$fake_dir/.rules" || return 1
  grep -qF "<!-- >>> agent-message >>> -->" "$fake_dir/.rules"
}

test_install_integrate_zed_refuses_home_dir() {
  local fake_home="$TMP/zed-home-cwd"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=zed )
  ( cd "$fake_home" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_missing "$fake_home/.rules"
}

test_install_integrate_copilot_refuses_symlinked_dotgit() {
  # Copilot Chat keeps the git gate (lives in .github/, presupposes git anyway).
  # Symlinked .git must not satisfy the gate.
  local fake_home="$TMP/sym-dotgit-home"
  local fake_repo="$TMP/sym-dotgit-repo"
  local foreign_dir="$TMP/foreign"
  mkdir -p "$fake_home" "$fake_repo" "$foreign_dir"
  ln -s "$foreign_dir" "$fake_repo/.git"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=copilot )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  assert_file_missing "$fake_repo/.github/copilot-instructions.md"
}

test_install_integrate_refuses_symlinked_target() {
  local fake_home="$TMP/sym-target-home"
  local fake_repo="$TMP/sym-target-repo"
  local foreign_file="$TMP/sensitive-file"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf 'sensitive content\n' > "$foreign_file"
  ln -s "$foreign_file" "$fake_repo/AGENTS.md"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  # Symlink target must NOT have been written through.
  local content; content=$(cat "$foreign_file")
  assert_eq "sensitive content" "$content" "symlink target unchanged"
}

test_install_integrate_zed_refuses_symlinked_target_non_git() {
  # Symlink defense (O_NOFOLLOW write) must hold for zed in non-git folders too.
  local fake_home="$TMP/zed-sym-non-git-home"
  local fake_dir="$TMP/zed-sym-non-git-dir"
  local foreign_file="$TMP/zed-sensitive"
  mkdir -p "$fake_home" "$fake_dir"
  printf 'sensitive\n' > "$foreign_file"
  ln -s "$foreign_file" "$fake_dir/.rules"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=zed )
  ( cd "$fake_dir" && _install "$fake_home" "${args[@]}" ) || return 1
  local content; content=$(cat "$foreign_file")
  assert_eq "sensitive" "$content" "symlinked target unchanged in non-git dir"
}

test_install_integrate_global_refuses_symlinked_parent_dir() {
  # Symlinked parent dir (e.g. ~/.gemini → /attacker/dir) bypasses O_NOFOLLOW
  # because the FINAL component is not a symlink. Helper must refuse pre-write.
  local fake_home="$TMP/sym-parent-home"
  local attacker_dir="$TMP/attacker"
  mkdir -p "$fake_home" "$attacker_dir"
  ln -s "$attacker_dir" "$fake_home/.gemini"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity )
  _install "$fake_home" "${args[@]}" || return 1
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
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity )
  _install "$fake_home" "${args[@]}" --uninstall || return 1
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
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity )
  _install "$fake_home" "${args[@]}" || return 1
  local content; content=$(cat "$foreign_file")
  assert_eq "sensitive" "$content" "global symlink target unchanged"
}

test_install_uninstall_refuses_symlinked_marker_target() {
  local fake_home="$TMP/uninstall-sym-home"
  local fake_repo="$TMP/uninstall-sym-repo"
  local foreign_file="$TMP/uninstall-sensitive"
  local backup="$TMP/uninstall-sensitive.backup"
  mkdir -p "$fake_home" "$fake_repo/.git"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )

  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  mv "$fake_repo/AGENTS.md" "$foreign_file"
  cp "$foreign_file" "$backup"
  ln -s "$foreign_file" "$fake_repo/AGENTS.md"
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1

  cmp -s "$backup" "$foreign_file" || {
    echo "  symlink target changed during marker uninstall"
    return 1
  }
}

test_install_uninstall_removes_duplicate_marker_blocks() {
  local fake_home="$TMP/duplicate-home"
  local fake_repo="$TMP/duplicate-repo"
  local duplicate="$TMP/duplicate-block"
  mkdir -p "$fake_home" "$fake_repo/.git"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )

  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  cp "$fake_repo/AGENTS.md" "$duplicate"
  printf '%s' "$(cat "$duplicate")" >> "$fake_repo/AGENTS.md"
  assert_eq "2" "$(grep -c '^<!-- >>> agent-message >>> -->$' "$fake_repo/AGENTS.md")" \
    "duplicate marker setup" || return 1
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
  assert_file_missing "$fake_repo/AGENTS.md"
}

test_install_uninstall_restores_marker_file_exactly() {
  local fake_home="$TMP/exact-home"
  local fake_repo="$TMP/exact-repo"
  local backup="$TMP/exact.backup"
  mkdir -p "$fake_home" "$fake_repo/.git"
  printf '\n\n# User rules\n\n\n' > "$fake_repo/AGENTS.md"
  cp "$fake_repo/AGENTS.md" "$backup"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )

  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
  cmp -s "$backup" "$fake_repo/AGENTS.md" || {
    echo "  marker uninstall did not restore user bytes exactly"
    return 1
  }
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
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  # User runs uninstall, expecting a no-op. Must NOT touch the file.
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" --uninstall ) || return 1
  local content; content=$(cat "$fake_repo/AGENTS.md")
  assert_contains "$content" "arbitrary user content the attacker wants to delete" \
    "non-canonical block survives uninstall" || return 1
  assert_contains "$content" "More legitimate content" "trailing content survives"
}

test_install_integrate_all_includes_global_and_per_repo() {
  local fake_home="$TMP/all-new-home"
  local fake_repo="$TMP/all-new-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=all )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  # Global integrations
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_home/.gemini/AGENTS.md" || return 1
  assert_file_exists "$fake_home/.copilot/copilot-instructions.md" || return 1
  assert_file_exists "$fake_home/.codex/AGENTS.md" || return 1
  # Per-repo (cwd) integrations — `all` does NOT include antigravity-repo
  assert_file_exists "$fake_repo/.github/copilot-instructions.md" || return 1
  assert_file_exists "$fake_repo/.rules" || return 1
  # antigravity-repo is opt-in only; --integrate=all should NOT have written ./AGENTS.md
  assert_file_missing "$fake_repo/AGENTS.md"
}

# Uninstall must NOT touch foreign files in $AGENT_MESSAGE_DIR — only files
# matching the whitelist (log-*.jsonl, .seen-*, .mtime-*) are removed. Locks
# the find-delete pattern at install.sh's uninstall block: any future widening
# (e.g. `-name '*'` for "thorough cleanup") would eat user-owned content next
# to the per-agent logs.
test_uninstall_preserves_foreign_files_in_msg_dir() {
  local fake_home="$TMP/sentinel-home" msgdir="$TMP/sentinel-msgdir"
  mkdir -p "$fake_home" "$msgdir"
  printf 'should survive\n' > "$msgdir/SENTINEL.txt"
  printf 'foreign config\n' > "$msgdir/.agent-message-config"
  printf '{}\n' > "$msgdir/log-foo.jsonl"
  printf '{"ts":0,"ids":[]}\n' > "$msgdir/.seen-foo"
  local args=(
    --dir "$msgdir"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
    --no-shell
  )
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  # Whitelisted files: removed.
  assert_file_missing "$msgdir/log-foo.jsonl" || return 1
  assert_file_missing "$msgdir/.seen-foo" || return 1
  # Foreign files: preserved.
  assert_file_exists "$msgdir/SENTINEL.txt" || return 1
  assert_file_exists "$msgdir/.agent-message-config"
}

# Re-running install over a file already containing the current marker block must
# succeed (exit 0) and report "already integrated". Regression guard: ensure_marker_block
# returns exit 2 to signal up-to-date, and `set -euo pipefail` is active — any caller
# that fails to escape the non-zero exit (e.g. via `|| rc=$?`) aborts the installer.
test_install_integrate_already_integrated_idempotent() {
  local fake_home="$TMP/idem-home"
  local fake_repo="$TMP/idem-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  # Second run hits the exit-2 path. Must not abort.
  local out
  out=$( cd "$fake_repo" && HOME="$fake_home" "$SCRIPT_DIR/install.sh" "${args[@]}" 2>&1 ) || return 1
  assert_contains "$out" "antigravity-repo: AGENTS.md (already integrated)" \
    "second run reports already integrated" || return 1
  # File must still contain exactly one marker block.
  assert_marker_once "$fake_repo/AGENTS.md"
}

# Re-running install with edited marker_block content must replace the stale block
# in place, not skip it. Pre-rename behaviour grepped for the open anchor and
# bailed out, so a v1.x → v1.y edit to marker_block (URL fix, wording change)
# never reached existing installs.
test_install_integrate_replaces_stale_marker_block() {
  local fake_home="$TMP/stale-home"
  local fake_repo="$TMP/stale-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  cat > "$fake_repo/AGENTS.md" <<'STALE'
# Project rules

<!-- >>> agent-message >>> -->
## Agent messaging (SAMP v1)
old wording from a previous installer version.
sender: ~/.agent-message-cmd
<!-- <<< agent-message <<< -->
STALE
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --integrate=antigravity-repo )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  local content; content=$(cat "$fake_repo/AGENTS.md")
  assert_contains "$content" "# Project rules" "user header preserved" || return 1
  # Stale wording must be gone; current marker_block content must be present.
  assert_not_contains "$content" "old wording from a previous" \
    "stale block stripped on re-install" || return 1
  assert_contains "$content" "Send: \`echo '<body>' | ~/.agent-message-cmd send" \
    "current marker block written"
}

# --integrate=auto runs ONLY global integrations. Per-repo writers (copilot,
# zed, antigravity-repo) require explicit --integrate=<tool> from inside the
# target repo, even if their detection signals are present. Pre-rename
# behaviour wrote .github/copilot-instructions.md and .rules into the cwd
# whenever the user happened to run install from a git-backed directory
# (including the agent-message clone itself).
test_install_integrate_auto_global_only() {
  local fake_home="$TMP/auto-home"
  local fake_repo="$TMP/auto-repo"
  mkdir -p "$fake_home" "$fake_repo/.git"
  # Plant detection signals for every auto-eligible tool, AND for the per-repo
  # tools we expect auto to skip.
  mkdir -p "$fake_home/.cursor" \
           "$fake_home/.copilot" \
           "$fake_home/.gemini" \
           "$fake_home/.codex" \
           "$fake_home/.config/zed"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" --integrate=auto )
  ( cd "$fake_repo" && _install "$fake_home" "${args[@]}" ) || return 1
  # Global integrations: present.
  assert_file_exists "$fake_home/.cursor/rules/agent-message.mdc" || return 1
  assert_file_exists "$fake_home/.copilot/copilot-instructions.md" || return 1
  assert_file_exists "$fake_home/.gemini/AGENTS.md" || return 1
  assert_file_exists "$fake_home/.codex/AGENTS.md" || return 1
  # Per-repo writers: must NOT fire under auto, even though signals are present
  # (cwd has .git, fake_home has .config/zed).
  assert_file_missing "$fake_repo/.github/copilot-instructions.md" || return 1
  assert_file_missing "$fake_repo/.rules" || return 1
  assert_file_missing "$fake_repo/AGENTS.md"
}

test_installer_idempotent_and_uninstall() {
  local fake_home="$TMP/fake-home"
  _iargs "$fake_home"

  local args=( "${_IARGS[@]}" )
  _install "$fake_home" "${args[@]}" || return 1
  assert_file_exists "$fake_home/.agent-message-cmd" || return 1
  assert_file_exists "$fake_home/.claude/commands/message-send.md" || return 1
  # Re-run -- must not fail
  _install "$fake_home" "${args[@]}" || return 1
  _install "$fake_home" "${args[@]}" --uninstall || return 1
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
  _install "$fake_home" "${args[@]}" || return 1
  local n
  n=$(grep -c "^# >>> agent-message >>>$" "$fake_home/.zshrc" || true)
  assert_eq "1" "$n" "rc-block injected once into .zshrc" || return 1
  n=$(grep -c "^# >>> agent-message >>>$" "$fake_home/.bashrc" || true)
  assert_eq "1" "$n" "rc-block injected once into .bashrc" || return 1
  # Re-run install -- must not duplicate
  _install "$fake_home" "${args[@]}" || return 1
  n=$(grep -c "^# >>> agent-message >>>$" "$fake_home/.zshrc" || true)
  assert_eq "1" "$n" "rc-block still once after re-install" || return 1
  # Uninstall -- rc-block must be stripped, user content preserved
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  n=$(grep -c "agent-message" "$fake_home/.zshrc" || true)
  assert_eq "0" "$n" "rc-block stripped from .zshrc" || return 1
  n=$(grep -c "agent-message" "$fake_home/.bashrc" || true)
  assert_eq "0" "$n" "rc-block stripped from .bashrc" || return 1
  local zshrc; zshrc=$(cat "$fake_home/.zshrc")
  assert_contains "$zshrc" "user content above" "user content preserved in .zshrc" || return 1
  assert_contains "$zshrc" "FOO=bar" "user export preserved in .zshrc"
}

test_installer_refreshes_stale_rc_shell_path() {
  local fake_home="$TMP/rc-stale-home"
  mkdir -p "$fake_home"
  printf '# user rc\n' > "$fake_home/.zshrc"
  local common=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --bin "$fake_home/.agent-message-cmd"
  )
  local old_shell="$fake_home/old-agent-message.sh"
  local new_shell="$fake_home/new-agent-message.sh"

  _install "$fake_home" "${common[@]}" --shell "$old_shell" || return 1
  _install "$fake_home" "${common[@]}" --shell "$new_shell" || return 1
  local content; content=$(cat "$fake_home/.zshrc")
  assert_not_contains "$content" "$old_shell" "stale rc source path removed" || return 1
  assert_contains "$content" "$new_shell" "new rc source path installed" || return 1
  assert_eq "1" "$(grep -c '^# >>> agent-message >>>$' "$fake_home/.zshrc")" \
    "rc marker remains singular after path refresh"
}

test_installer_rc_non_utf8_bytes_survive_round_trip() {
  local fake_home="$TMP/rc-bytes-home"
  local backup="$TMP/zshrc-bytes.backup"
  mkdir -p "$fake_home"
  printf '# user rc\nraw byte: \377\n\n' > "$fake_home/.zshrc"
  cp "$fake_home/.zshrc" "$backup"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
  )

  _install "$fake_home" "${args[@]}" || return 1
  _install "$fake_home" "${args[@]}" --uninstall || return 1
  cmp -s "$backup" "$fake_home/.zshrc" || {
    echo "  non-UTF-8 rc bytes changed across install/uninstall"
    return 1
  }
}

test_installer_replaces_destination_symlinks_without_following() {
  local fake_home="$TMP/copy-symlink-home"
  local command_target="$TMP/command-sensitive"
  local bin_target="$TMP/bin-sensitive"
  local shell_target="$TMP/shell-sensitive"
  local directory_target="$TMP/directory-sensitive"
  mkdir -p "$fake_home/.claude/commands" "$directory_target"
  printf 'command secret\n' > "$command_target"
  printf 'bin secret\n' > "$bin_target"
  printf 'shell secret\n' > "$shell_target"
  ln -s "$command_target" "$fake_home/.claude/commands/message-send.md"
  ln -s "$directory_target" "$fake_home/.claude/commands/message-inbox.md"
  ln -s "$bin_target" "$fake_home/.agent-message-cmd"
  ln -s "$shell_target" "$fake_home/.agent-message.sh"
  local args=(
    --dir "$fake_home/.local/state/agent-message"
    --commands "$fake_home/.claude/commands"
    --shell "$fake_home/.agent-message.sh"
    --bin "$fake_home/.agent-message-cmd"
  )

  _install "$fake_home" "${args[@]}" || return 1
  assert_eq "command secret" "$(cat "$command_target")" "command symlink target untouched" || return 1
  assert_eq "bin secret" "$(cat "$bin_target")" "bin symlink target untouched" || return 1
  assert_eq "shell secret" "$(cat "$shell_target")" "shell symlink target untouched" || return 1
  [[ ! -L "$fake_home/.claude/commands/message-send.md" ]] || return 1
  [[ ! -L "$fake_home/.claude/commands/message-inbox.md" ]] || return 1
  [[ ! -L "$fake_home/.agent-message-cmd" ]] || return 1
  [[ ! -L "$fake_home/.agent-message.sh" ]] || return 1
  assert_file_exists "$fake_home/.claude/commands/message-inbox.md" || return 1
  if find "$directory_target" -mindepth 1 -print -quit | grep -q .; then
    echo "  directory symlink target received an installer file"
    return 1
  fi
}

test_installer_preserves_private_message_dir_mode() {
  local fake_home="$TMP/private-mode-home"
  local msg_dir="$fake_home/private-messages"
  mkdir -p "$msg_dir"
  chmod 0700 "$msg_dir"
  _iargs "$fake_home"
  local args=( "${_IARGS[@]}" --dir "$msg_dir" )

  _install "$fake_home" "${args[@]}" || return 1
  local mode
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$msg_dir")
  assert_eq "700" "$mode" "private message directory mode preserved"
}

test_installer_preserves_private_command_file_mode() {
  local fake_home="$TMP/private-command-home"
  local command_file="$fake_home/.claude/commands/message-send.md"
  mkdir -p "$(dirname "$command_file")"
  printf '# private command\n' > "$command_file"
  chmod 0600 "$command_file"
  _iargs "$fake_home"

  _install "$fake_home" "${_IARGS[@]}" || return 1
  local mode
  mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$command_file")
  assert_eq "600" "$mode" "private command file mode preserved"
}

# The post-install banner is read once, at the moment a new mode is most likely to
# stick. It drifted behind `inbox <n>` for a release; pin it to the porcelain.
test_installer_banner_lists_count_mode() {
  local out home="$TMP/banner-home"
  mkdir -p "$home"
  out=$( HOME="$home" "$SCRIPT_DIR/install.sh" --dir "$TMP/banner-msg" \
           --bin "$home/.agent-message-cmd" --shell "$home/.agent-message.sh" ) || return 1
  # Match the comment too: a bare "msg 2" would still pass if it drifted to "msg 25".
  assert_contains "$out" "/message-inbox 2            # the 2 latest" "banner lists slash count" || return 1
  assert_contains "$out" "msg 2            # the 2 latest" "banner lists shell count"
}

test_installer_help_includes_trailing_options() {
  local out
  out=$(HOME="$TMP/help-home" "$SCRIPT_DIR/install.sh" --help) || return 1
  assert_contains "$out" "--uninstall" "help includes uninstall option" || return 1
  assert_contains "$out" "-h, --help" "help includes help option"
}

# ---- run ----

TESTS=(
  test_wrapper_round_trip
  test_wrapper_watermark
  test_wrapper_readonly_dir_still_reads
  test_shell_readonly_dir_still_reads
  test_wrapper_same_second_burst
  test_wrapper_dedup_synced_log
  test_wrapper_alias_traversal_blocked
  test_wrapper_thread_inheritance
  test_reply_rejects_two_sender_same_second_tie
  test_reply_same_sender_same_second_uses_log_order
  test_reply_picks_newest_ts_not_log_order
  test_inbox_full_body_parity_wrapper_and_shell
  test_inbox_body_cannot_spoof_header
  test_inbox_oversized_body_elided_not_silent
  test_inbox_budget_bounds_total_output
  test_inbox_all_mode_shows_full_body
  test_inbox_budget_favours_newest
  test_send_refuses_oversized_body
  test_reply_refuses_oversized_body
  test_body_limit_boundary_is_exact
  test_reader_accepts_oversized_record
  test_inbox_count_bounded_reread
  test_inbox_count_rejects_zero
  test_inbox_count_rejects_non_ascii_digits
  test_inbox_empty_body_marked
  test_wrapper_thread_override
  test_wrapper_id_is_content_addressed
  test_wrapper_logs_already_returns_list
  test_wrapper_id_falsy_falls_through_to_cid
  test_wrapper_mtime_short_circuit
  test_wrapper_seen_deletion_forces_reread
  test_wrapper_inbox_shows_active_alias
  test_wrapper_dotted_alias_watermark
  test_wrapper_mtime_sc_speedup_gate
  test_msg_round_trip
  test_msg_inbox_shows_active_alias
  test_msg_dotted_alias_watermark
  test_msg_mtime_short_circuit
  test_wrapper_version
  test_msg_version
  test_validator_clean
  test_validator_catches_id_tamper
  test_validator_catches_single_writer_violation
  test_cid_spec_golden
  test_cid_golden_nfd_thread
  test_msg_alias_traversal_blocked
  test_alias_resolution_parity
  test_send_rejects_invalid_recipient
  test_reader_tolerates_malformed_records
  test_wrapper_inbox_creates_missing_dir
  test_thread_slug_parity_nfd
  test_thread_empty_override_falls_back
  test_forged_id_suppression_blocked
  test_wrapper_mtime_cache_size_signal
  test_msg_mtime_cache_size_signal
  test_wrapper_watermark_clock_skew_no_loss
  test_msg_watermark_clock_skew_no_loss
  test_msg_compact_own_log_only
  test_msg_compact_preserves_unparseable
  test_validator_allows_legacy_missing_id
  test_inbox_strips_ansi_escapes
  test_wrapper_single_writer_runtime_enforced
  test_wrapper_nfc_body
  test_msg_thread_strip_whitespace
  test_wrapper_symlink_log_blocks_write
  test_msg_seen_deletion_forces_reread
  test_install_integrate_cursor
  test_install_uninstall_cursor_preserves_user_content
  test_install_uninstall_cursor_preserves_preexisting_file
  test_install_integrate_copilot_preserves_user_content
  test_install_integrate_copilot_empty_file_removed
  test_install_integrate_all_and_full_uninstall
  test_install_integrate_copilot_skipped_outside_git_repo
  test_install_integrate_antigravity_repo_preserves_user_content
  test_install_integrate_antigravity_repo_empty_file_removed
  test_install_integrate_antigravity_repo_works_in_non_git_dir
  test_install_integrate_antigravity_repo_refuses_home_dir
  test_install_integrate_antigravity_global_writes_to_home_gemini
  test_install_integrate_antigravity_global_preserves_existing_gemini_md
  test_install_integrate_copilot_cli_writes_to_home_copilot
  test_install_integrate_copilot_cli_preserves_existing_instructions
  test_install_integrate_codex_writes_to_home_codex
  test_install_integrate_codex_writes_sandbox_writable_root
  test_install_integrate_codex_preserves_existing_config_toml
  test_install_integrate_codex_refuses_existing_sandbox_table
  test_install_integrate_codex_preserves_existing_agents_md
  test_install_hint_lists_detected_unwired_global
  test_install_hint_omits_wired_tool
  test_install_hint_confirms_when_all_wired
  test_install_hint_silent_when_nothing_detected
  test_install_select_without_tty_falls_back_to_auto
  test_install_select_uninstall_keeps_core_install
  test_install_select_menu_picks_by_number
  test_install_integrate_zed_preserves_user_content
  test_install_integrate_zed_empty_file_removed
  test_install_integrate_zed_works_in_non_git_dir
  test_install_integrate_zed_refuses_home_dir
  test_install_integrate_copilot_refuses_symlinked_dotgit
  test_install_integrate_refuses_symlinked_target
  test_install_integrate_zed_refuses_symlinked_target_non_git
  test_install_integrate_global_refuses_symlinked_target
  test_install_integrate_global_refuses_symlinked_parent_dir
  test_install_uninstall_refuses_symlinked_marker_target
  test_install_uninstall_removes_duplicate_marker_blocks
  test_install_uninstall_restores_marker_file_exactly
  test_install_uninstall_preserves_attacker_planted_marker_pair
  test_install_uninstall_global_preserves_attacker_planted_marker
  test_install_integrate_all_includes_global_and_per_repo
  test_install_integrate_auto_global_only
  test_install_integrate_replaces_stale_marker_block
  test_install_integrate_already_integrated_idempotent
  test_uninstall_preserves_foreign_files_in_msg_dir
  test_installer_idempotent_and_uninstall
  test_installer_rc_block_idempotent_and_stripped
  test_installer_refreshes_stale_rc_shell_path
  test_installer_rc_non_utf8_bytes_survive_round_trip
  test_installer_replaces_destination_symlinks_without_following
  test_installer_preserves_private_message_dir_mode
  test_installer_preserves_private_command_file_mode
  test_installer_banner_lists_count_mode
  test_installer_help_includes_trailing_options
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
