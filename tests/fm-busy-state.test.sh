#!/usr/bin/env bash
# Behavior tests for the semantic busy-state contract (bin/fm-busy-lib.sh and
# its only writer bin/fm-busy-event.sh).
#
# Covers the captain-approved redesign invariants: busy/idle/unknown/dead with
# explicit source attribution; missing, malformed, stale (gen-mismatch), and
# untrusted (source-mismatch) semantic data classify unknown - never idle;
# adapter isolation (one adapter's writer or Grok's regex can never classify
# another adapter); endpoint death is the only process-level override and
# yields dead, never busy; converted adapters never classify from rendered
# footer text. All hermetic over temp dirs; no real agent session is invoked.
#
# It also covers the writer's one side effect: publishing the state it just
# wrote to a runtime backend that renders agent state in its own UI. Those
# cases drive the real bin/fm-busy-event.sh against a STUBBED thurbox CLI
# (tests/thurbox-test-safety.sh refuses anything else), because the property
# under test is when firstmate publishes, not what thurbox does with it -
# tests/fm-backend-thurbox.test.sh owns the vocabulary and the round-trip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-state)
EV="$ROOT/bin/fm-busy-event.sh"

new_state_dir() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- publish fixture ---------------------------------------------------------
#
# A stub thurbox CLI that records every `session signal` as
# "<session-uuid> <state>". FM_PUBLISH_EXIT forces a failing CLI, and
# FM_PUBLISH_NOISE makes it chatty on both streams, so the two properties the
# hook path depends on - a refusal never fails the mutation, and nothing ever
# reaches this script's own stdout - are exercised rather than assumed.
PUBLISH_BIN="$TMP_ROOT/fakebin/thurbox-cli"
PUBLISH_LOG="$TMP_ROOT/publish.log"
mkdir -p "$TMP_ROOT/fakebin"
cat > "$PUBLISH_BIN" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_PUBLISH_NOISE:-}" ] || { echo "stub chatter on stdout"; echo "stub chatter on stderr" >&2; }
# FM_PUBLISH_BLOCK makes this call hang until the named file is removed, so a
# test can hold one publication open and drive a second one against it. The cap
# keeps a broken test from wedging the suite rather than failing it.
if [ -n "${FM_PUBLISH_BLOCK:-}" ]; then
  [ -z "${FM_PUBLISH_STARTED:-}" ] || : > "$FM_PUBLISH_STARTED"
  waited=0
  while [ -e "$FM_PUBLISH_BLOCK" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
sess=''; state=''
while [ $# -gt 0 ]; do
  case "$1" in
    --session) sess=$2; shift 2 ;;
    --state) state=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$sess" "$state" >> "${FM_PUBLISH_LOG:?}"
exit "${FM_PUBLISH_EXIT:-0}"
SH
chmod +x "$PUBLISH_BIN"
export FM_PUBLISH_LOG="$PUBLISH_LOG"
export FM_THURBOX_BIN="$PUBLISH_BIN"

# shellcheck source=tests/thurbox-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/thurbox-test-safety.sh"
thurbox_refuse_if_unsafe "$TMP_ROOT" \
  || fail "thurbox safety guard refused this suite's own publish stub"

PUBLISH_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee

reset_publish_log() {
  : > "$PUBLISH_LOG"
  unset FM_PUBLISH_EXIT FM_PUBLISH_NOISE FM_PUBLISH_BLOCK FM_PUBLISH_STARTED 2>/dev/null || true
}

# publish_meta <state-dir> <id> [backend]: the task metadata the writer reads to
# decide where, if anywhere, to publish. No backend argument writes NO backend=
# line at all, which IS a tmux task under bin/fm-backend.sh's compatibility
# contract.
publish_meta() {  # <state-dir> <id> [backend]
  local state=$1 id=$2 backend=${3:-}
  {
    echo "window=$PUBLISH_UUID:%20"
    echo "endpoint_task_id=$id"
    echo "worktree=$state"
    echo "project=$state"
    echo "harness=claude"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$state/$id.meta"
}

published() {
  cat "$PUBLISH_LOG"
}

# --- writer: arm and apply ---------------------------------------------------

test_arm_seeds_busy_spawn() {
  local state gen out
  state=$(new_state_dir arm-seed)
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ -f "$state/t1.busy-gen" ] || fail "arm did not write the gen sidecar"
  [ "$(cat "$state/t1.busy-gen")" = "$gen" ] || fail "sidecar gen does not match printed gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed should classify 'busy fm-spawn', got '$out'"
  pass "arm mints a gen sidecar and seeds busy fm-spawn at seq=1"
}

test_apply_advances_seq_and_source() {
  local state gen out seq
  state=$(new_state_dir apply-seq)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply idle failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "expected 'idle claude-hook', got '$out'"
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "apply busy failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy claude-hook" ] || fail "expected 'busy claude-hook', got '$out'"
  seq=$(fm_busy_record_read "$state" t1 | awk '{print $4}')
  [ "$seq" = 3 ] || fail "expected seq 3 after seed + two applies, got '$seq'"
  pass "apply advances seq under the armed gen and attributes the writing source"
}

test_apply_current_gen_reset() {
  local state out
  state=$(new_state_dir apply-current)
  "$EV" arm "$state" t1 >/dev/null
  "$EV" apply "$state" t1 idle --current-gen --source fm-interrupt --event interrupt \
    || fail "apply --current-gen failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle fm-interrupt" ] || fail "expected 'idle fm-interrupt', got '$out'"
  "$EV" apply "$state" t1 unknown --current-gen --source fm-recovery --event relaunch \
    || fail "apply unknown failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown fm-recovery" ] || fail "expected 'unknown fm-recovery', got '$out'"
  pass "firstmate-owned interrupt and recovery events bind to the current gen"
}

test_apply_unarmed_refused() {
  local state
  state=$(new_state_dir apply-unarmed)
  if "$EV" apply "$state" t1 busy --gen g1.2.3 --source claude-hook --event x 2>/dev/null; then
    fail "apply against an unarmed task must be refused"
  fi
  [ ! -f "$state/t1.busy-state" ] || fail "refused apply must not write a record"
  pass "apply is refused for a task whose busy contract was never armed"
}

test_retire_serializes_and_rejects_stale_gen() {
  local state old_gen new_gen out retire_pid i=0
  state=$(new_state_dir retire)
  old_gen=$("$EV" arm "$state" t1)
  mkdir "$state/t1.busy-state.lock"
  "$EV" retire "$state" t1 --gen "$old_gen" >/dev/null 2>&1 &
  retire_pid=$!
  while [ "$i" -lt 20 ] && ! kill -0 "$retire_pid" 2>/dev/null; do
    i=$((i + 1))
  done
  [ -e "$state/t1.busy-state" ] || fail "retire bypassed the writer lock"
  rmdir "$state/t1.busy-state.lock"
  wait "$retire_pid" || fail "retire failed after acquiring the writer lock"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"

  new_gen=$("$EV" arm "$state" t1)
  if "$EV" retire "$state" t1 --gen "$old_gen" 2>/dev/null; then
    fail "retire accepted a superseded incarnation"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale retirement changed the new incarnation, got '$out'"
  [ "$(cat "$state/t1.busy-gen")" = "$new_gen" ] || fail "stale retirement changed the new gen"
  pass "retire waits for the writer lock and cannot remove a new incarnation"
}

# Regression for issue #2625: the writer lock's stale-lock branch resolved the
# lock's mtime with `stat -f %m ... || stat -c %Y ...`. On GNU coreutils `-f` is
# *filesystem* stat, so it consumes the format string as a path, complains on
# stderr, prints "  File: ..." on stdout, and still exits 0 - the GNU form in the
# fallback never ran. The following `$((now - mtime))` then evaluated the word
# `File`, which under `set -u` aborted the writer with "File: unbound variable".
# fm-teardown.sh died there after returning the worktree, leaving state/<id>.meta
# and friends behind to generate stale wakes forever, and every re-run died
# identically because the abandoned lock directory was never broken.
#
# The stat and uname stubs make this deterministic on any host: the writer must
# take the Linux path and still break a provably stale lock.
test_stale_lock_broken_under_gnu_stat() {
  local state gen fakebin real_uname out status
  state=$(new_state_dir gnu-stat-lock)
  gen=$("$EV" arm "$state" t1)
  fakebin=$(fm_fakebin "$TMP_ROOT/gnu-stat-lock")
  real_uname=$(command -v uname)

  # GNU coreutils semantics, self-contained so no real stat is consulted.
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %Y ]; then
  printf '%s\n' 1000000000   # long-abandoned lock
  exit 0
fi
if [ "${1:-}" = -f ]; then
  echo "stat: cannot read file system information for '$2': No such file or directory" >&2
  shift 2
  printf '  File: "%s"\n' "${1:-}"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/stat"
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
if [ \$# -eq 0 ]; then printf 'Linux\n'; exit 0; fi
exec "$real_uname" "\$@"
SH
  chmod +x "$fakebin/uname"

  mkdir "$state/t1.busy-state.lock"
  out=$(PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --gen "$gen" 2>&1) && status=0 || status=$?
  case "$out" in
    *'unbound variable'*) fail "the writer still dies on GNU stat output: $out" ;;
  esac
  [ "$status" = 0 ] || fail "retire did not break a provably stale writer lock: $out"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"
  [ ! -e "$state/t1.busy-state.lock" ] || fail "retire left the stale lock behind"

  # Teardown must be able to run again over the same task without failing.
  PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --current-gen \
    || fail "a repeated retire over already-cleaned state was not idempotent"
  pass "the writer breaks a stale lock instead of dying on GNU stat output"
}

test_retire_missing_sidecar_is_idempotent() {
  local state gen
  state=$(new_state_dir retire-missing)
  gen=$("$EV" arm "$state" t1)
  rm -f "$state/t1.busy-gen"

  "$EV" retire "$state" t1 --gen "$gen" || fail "exact-gen retire rejected a missing sidecar"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left an orphan record behind"
  "$EV" retire "$state" t1 --gen "$gen" || fail "repeated exact-gen retire was not idempotent"
  "$EV" retire "$state" t1 --current-gen || fail "current-gen retire was not idempotent"

  printf 'malformed gen\n' > "$state/t1.busy-gen"
  printf 'orphan\n' > "$state/t1.busy-state"
  if "$EV" retire "$state" t1 --gen "$gen" 2>/dev/null; then
    fail "retire accepted a malformed existing sidecar"
  fi
  [ -e "$state/t1.busy-state" ] || fail "retire removed the record for a malformed existing sidecar"
  pass "retire treats only an absent sidecar as already retired"
}

# --- stale event rejection ----------------------------------------------------

test_stale_gen_event_rejected() {
  local state old_gen new_gen out
  state=$(new_state_dir stale-event)
  old_gen=$("$EV" arm "$state" t1)
  new_gen=$("$EV" arm "$state" t1)
  [ "$old_gen" != "$new_gen" ] || fail "re-arm must mint a fresh gen"
  if "$EV" apply "$state" t1 idle --gen "$old_gen" --source claude-hook --event stop 2>/dev/null; then
    fail "an event carrying a stale gen must be rejected"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale event must not change the record, got '$out'"
  pass "a late event from a previous incarnation is rejected, record unchanged"
}

test_stale_gen_record_unknown() {
  local state gen out
  state=$(new_state_dir stale-record)
  gen=$("$EV" arm "$state" t1)
  # Simulate a record left behind by a superseded incarnation.
  printf 'g-superseded.1.1\n' > "$state/t1.busy-gen.new"
  mv "$state/t1.busy-gen.new" "$state/t1.busy-gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown gen-mismatch" ] || fail "stale record must classify 'unknown gen-mismatch', got '$out'"
  pass "a record from a stale incarnation classifies unknown, never idle"
}

# --- missing and malformed semantic data --------------------------------------

test_missing_record_unknown_not_idle() {
  local state out h
  state=$(new_state_dir missing)
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state")
    [ "$out" = "unknown missing" ] || fail "$h with no record must be 'unknown missing', got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex with no verified source must be 'unknown codex-unverified', got '$out'"
  pass "a converted adapter with no record classifies unknown, never idle"
}

test_malformed_record_unknown() {
  local state gen out
  state=$(new_state_dir malformed)
  gen=$("$EV" arm "$state" t1)
  for bad in \
    'garbage' \
    "v0 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=NaN state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=frobbing source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=bad source event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1 rogue=1"; do
    printf '%s\n' "$bad" > "$state/t1.busy-state"
    out=$(fm_busy_classify tmux w1 claude t1 "$state")
    [ "$out" = "unknown malformed" ] || fail "malformed record '$bad' must be 'unknown malformed', got '$out'"
  done
  printf 'v1 gen=%s seq=1 state=busy source=claude-hook event=x ts=1\nsecond line\n' "$gen" > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "multi-line record must be 'unknown malformed', got '$out'"
  pass "malformed records classify unknown malformed, never busy or idle"
}

test_record_without_sidecar_unknown() {
  local state out
  state=$(new_state_dir orphan-record)
  printf 'v1 gen=g1.1.1 seq=1 state=busy source=claude-hook event=x ts=1\n' > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "record without an armed gen must be unknown, got '$out'"
  pass "a record with no armed gen sidecar classifies unknown"
}

# --- adapter isolation ---------------------------------------------------------

test_source_mismatch_cross_adapter() {
  local state gen out
  state=$(new_state_dir cross-adapter)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "pi-ext record on a claude task must be untrusted, got '$out'"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "pi-ext record on a pi task must classify, got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "grok trusts no semantic source, got '$out'"
  pass "a record is trusted only by the adapter whose source wrote it"
}

test_converted_adapters_ignore_footer_text() {
  local state out h
  state=$(new_state_dir no-footer)
  local tail='• Working (6s • esc to interrupt)
   ■■■■⬝⬝⬝⬝  esc interrupt
Working...
Ctrl+c:cancel'
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" "$tail")
    [ "$out" = "unknown missing" ] || fail "$h must never classify from footer text, got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state" "$tail")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must never classify from footer text, got '$out'"
  pass "converted adapters never classify busy from rendered footer text"
}

test_grok_regex_isolated() {
  local state out
  state=$(new_state_dir grok-arm)
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'thinking hard
Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok busy tail must classify 'busy grok-regex', got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'done.
> ')
  [ "$out" = "idle grok-regex" ] || fail "grok idle tail must classify 'idle grok-regex', got '$out'"
  # Another adapter's footer never makes grok busy either.
  out=$(fm_busy_classify tmux w1 grok t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "idle grok-regex" ] || fail "a claude footer must not classify grok busy, got '$out'"
  pass "the grok fallback is regex-scoped to grok and classifies only grok tasks"
}

# --- kimi verification gate -----------------------------------------------------

test_codex_unverified_gate() {
  local state gen out
  state=$(new_state_dir codex-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source codex-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "unverified codex must classify unknown, got '$out'"
  [ -z "$(fm_busy_sources_for_harness codex)" ] \
    || fail "codex must trust no semantic source until one is verified"
  pass "codex classifies unknown until a semantic source passes its verification gate"
}

test_kimi_unverified_gate() {
  local state gen out
  state=$(new_state_dir kimi-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source kimi-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 kimi t1 "$state")
  [ "$out" = "unknown kimi-unverified" ] || fail "unverified kimi must classify unknown, got '$out'"
  out=$(fm_busy_classify tmux w1 kimi t1 "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must not classify from footer text, got '$out'"
  pass "standalone kimi classifies unknown until the live verification gate opens"
}

test_cursor_ignores_rendered_and_native_signals() {
  local state out
  state=$(new_state_dir cursor-gate)
  # Cursor's verdict comes from its own transcript, never from rendered text.
  # With no binding to fold, the honest answer is unknown - and a rendered
  # busy-looking footer must not change that.
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'Working')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from its rendered footer, got '$out'"
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'ctrl+c to stop')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from the ctrl+c busy token either, got '$out'"
  # Herdr's narrower native streaming state is not cursor's turn lifecycle.
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' busy; }
  out=$(fm_busy_classify herdr s:p cursor t1 "$state")
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not borrow herdr's native busy verdict, got '$out'"
  unset -f fm_backend_busy_state
  # The fold is a PULL source: nothing is armed, so no stored record is trusted.
  [ -z "$(fm_busy_sources_for_harness cursor)" ] \
    || fail "cursor must trust no stored record source; its fold has no writer"
  pass "cursor classifies only from its transcript fold, never rendered text or native state"
}

# --- endpoint death and native fallbacks ----------------------------------------

test_dead_endpoint_overrides() {
  local state gen out
  state=$(new_state_dir dead)
  gen=$("$EV" arm "$state" t1)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 1; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "dead endpoint-gone" ] || fail "gone endpoint must classify dead, got '$out'"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 0; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "live endpoint must fall through to the record, got '$out'"
  out=$(fm_busy_classify_live tmux '' claude t1 "$state")
  [ "$out" = "unknown no-target" ] || fail "empty target must classify unknown, got '$out'"
  unset -f fm_backend_target_exists
  pass "endpoint death is the only process-level override and yields dead, never busy"
}

test_herdr_native_busy_only() {
  local state out
  state=$(new_state_dir herdr-native)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' "$FAKE_NATIVE"; }
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "busy herdr-native" ] || fail "native busy with no record must classify busy, got '$out'"
  FAKE_NATIVE=idle
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "unknown missing" ] || fail "native idle must NOT classify idle, got '$out'"
  # A valid record outranks the native verdict.
  local gen
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "the adapter record must outrank herdr's native verdict, got '$out'"
  unset -f fm_backend_busy_state
  pass "herdr's native verdict is trusted for busy only, and records outrank it"
}

# The record parser runs inside sourcing callers (the watcher, the daemon, the
# crew-state reader), so it must not disturb their shell: no clobbered
# positional parameters and no changed glob setting.
test_record_read_leaves_caller_shell_intact() {
  local state out
  state=$(new_state_dir parser-isolation)
  "$EV" arm "$state" t1 >/dev/null
  out=$(bash -c '
    set -f
    . "$1/bin/fm-busy-lib.sh"
    set -- keepme second
    fm_busy_record_read "$2" t1 >/dev/null
    printf "%s|%s|%s" "$1" "$#" "$-"
  ' _ "$ROOT" "$state")
  case "$out" in
    keepme\|2\|*f*) : ;;
    *) fail "record parsing disturbed the caller's shell: $out" ;;
  esac
  # A glob-shaped field must survive parsing literally rather than expanding.
  printf 'v1 gen=%s seq=1 state=busy source=* event=x ts=1\n' "$(cat "$state/t1.busy-gen")" \
    > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "a glob-shaped source must be rejected, not expanded, got '$out'"
  pass "record parsing never clobbers the caller's positional parameters, glob setting, or fields"
}

test_boolean_view_never_promotes_unknown() {
  local state gen
  state=$(new_state_dir boolean)
  gen=$("$EV" arm "$state" t1)
  fm_busy_is_busy tmux w1 claude t1 "$state" || fail "busy record must read busy"
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "idle record must not read busy"
  fi
  printf 'garbage\n' > "$state/t1.busy-state"
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "malformed record must not read busy"
  fi
  pass "the boolean view reports busy only on an exact busy verdict"
}

# --- writer side effect: publishing to the task's runtime backend -----------

test_publish_reports_every_written_state_to_a_thurbox_task() {
  local state gen
  state=$(new_state_dir publish-thurbox)
  publish_meta "$state" t1 thurbox
  reset_publish_log
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ "$(published)" = "$PUBLISH_UUID working" ] \
    || fail "arm did not publish the seeded turn, got '$(published)'"
  reset_publish_log
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply stop failed"
  [ "$(published)" = "$PUBLISH_UUID done" ] \
    || fail "a finished turn did not publish done, got '$(published)'"
  reset_publish_log
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event session-end
  [ "$(published)" = "$PUBLISH_UUID working
$PUBLISH_UUID idle" ] || fail "expected working then idle, got '$(published)'"
  pass "each written state is published to the task's thurbox session"
}

test_publish_is_skipped_for_a_default_backend_task() {
  local state gen before after
  state=$(new_state_dir publish-default)
  publish_meta "$state" t1
  reset_publish_log
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  before=$(fm_busy_record_read "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply failed"
  after=$(fm_busy_record_read "$state" t1)
  [ -z "$(published)" ] || fail "a default-backend task published '$(published)'"
  [ "$before" != "$after" ] || fail "the record did not advance"
  [ "$(fm_busy_classify tmux w1 claude t1 "$state")" = "idle claude-hook" ] \
    || fail "the default path's own classification changed"
  pass "a task with no recorded backend publishes nothing and is otherwise unchanged"
}

test_publish_is_a_no_op_for_a_backend_without_a_state_surface() {
  local state gen
  state=$(new_state_dir publish-herdr)
  publish_meta "$state" t1 herdr
  reset_publish_log
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply failed"
  [ -z "$(published)" ] || fail "a herdr task published '$(published)'"
  [ "$(fm_busy_classify herdr "$PUBLISH_UUID:%20" claude t1 "$state")" = "idle claude-hook" ] \
    || fail "the herdr path's own classification changed"
  pass "a backend with no state surface is a silent no-op, record unchanged"
}

test_publish_never_reports_a_state_firstmate_cannot_place() {
  local state gen
  state=$(new_state_dir publish-unknown)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1)
  reset_publish_log
  "$EV" apply "$state" t1 unknown --gen "$gen" --source claude-hook --event session-end \
    || fail "apply unknown failed"
  [ -z "$(published)" ] || fail "unknown was published as '$(published)'"
  pass "an unknown state is written to the record but published to nothing"
}

test_publish_never_follows_a_refused_event() {
  local state gen
  state=$(new_state_dir publish-refused)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1)
  reset_publish_log
  # A hook that outlived its incarnation is refused at the record, so there is
  # no state to publish either.
  if "$EV" apply "$state" t1 busy --gen "gstale.1.2" --source claude-hook --event user-prompt-submit 2>/dev/null; then
    fail "a stale-gen event was not refused"
  fi
  [ -z "$(published)" ] || fail "a refused event published '$(published)'"
  # A retirement naming an incarnation that is not the current one is refused
  # the same way, and must not report the task at rest on its way out.
  if "$EV" retire "$state" t1 --gen "gstale.1.2" 2>/dev/null; then
    fail "a stale-gen retirement was not refused"
  fi
  [ -z "$(published)" ] || fail "a refused retirement published '$(published)'"
  pass "publishing follows a successful mutation only, never a refused one"
}

test_retirement_reports_the_task_at_rest() {
  local state gen
  state=$(new_state_dir publish-retire)
  publish_meta "$state" t1 thurbox
  reset_publish_log
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ "$(published)" = "$PUBLISH_UUID working" ] || fail "arm did not publish its turn"
  reset_publish_log
  # `fm-control exit` retires the record while deliberately KEEPING the
  # endpoint alive. Before this reported anything, the last state on the
  # session stayed `working`, and fm_busy_classify's no-record path went on
  # trusting that native verdict - so a stopped worker classified as
  # confidently busy where it used to answer unknown.
  "$EV" retire "$state" t1 --gen "$gen" || fail "retire failed"
  [ "$(published)" = "$PUBLISH_UUID idle" ] \
    || fail "a retirement did not report the task at rest, got '$(published)'"
  # The value has to be named literally, because the record a re-read would
  # consult is exactly what retirement just removed.
  [ ! -e "$state/t1.busy-state" ] || fail "the record survived retirement"
  [ ! -e "$state/t1.busy-gen" ] || fail "the gen sidecar survived retirement"
  pass "a successful retirement reports the task at rest with a literal state"
}

test_retirement_publish_never_fails_or_delays_the_retirement() {
  local state gen block start elapsed
  state=$(new_state_dir publish-retire-besteffort)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  reset_publish_log
  # Teardown kills the session before it retires, so this call routinely fails;
  # it must never take the retirement down with it.
  export FM_PUBLISH_EXIT=4
  "$EV" retire "$state" t1 --gen "$gen" \
    || fail "a failing publish failed the retirement"
  [ ! -e "$state/t1.busy-gen" ] || fail "the retirement did not happen"
  unset FM_PUBLISH_EXIT
  # And a wedged CLI is bounded on the way out just like every other event.
  publish_meta "$state" t2 thurbox
  gen=$("$EV" arm "$state" t2) || fail "arm t2 failed"
  reset_publish_log
  block="$state/block"
  : > "$block"
  start=$(date +%s)
  FM_PUBLISH_BLOCK="$block" "$EV" retire "$state" t2 --gen "$gen" \
    || fail "a hanging publish failed the retirement"
  elapsed=$(( $(date +%s) - start ))
  rm -f "$block"
  [ "$elapsed" -lt 8 ] || fail "a hanging publish held the retirement for ${elapsed}s"
  [ ! -e "$state/t2.busy-gen" ] || fail "the bounded retirement did not happen"
  pass "a failing or wedged report never fails or unbounds a retirement"
}

test_publish_carries_every_harness_turn_end_through_the_writer() {
  local state gen event
  state=$(new_state_dir publish-turn-end)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  # Each published harness ends a turn with its own token: claude's Stop hook,
  # opencode's two idle boundaries for the latched worker session, and pi's
  # settled check. All three mean "a turn just finished", so all four tokens
  # must survive the writer as thurbox's `done`.
  for event in stop session-status-idle session-idle agent-settled; do
    "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
      || fail "apply busy failed"
    reset_publish_log
    "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event "$event" \
      || fail "apply $event failed"
    [ "$(published)" = "$PUBLISH_UUID done" ] \
      || fail "turn end '$event' published '$(published)', expected done"
  done
  # An interrupt is not a completed turn, and neither is a shutdown or an error
  # stop: those stay at-rest.
  for event in interrupt session-end stop-failure; do
    "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
    reset_publish_log
    "$EV" apply "$state" t1 idle --gen "$gen" --source fm-interrupt --event "$event" \
      || fail "apply $event failed"
    [ "$(published)" = "$PUBLISH_UUID idle" ] \
      || fail "'$event' published '$(published)', expected the at-rest idle"
  done
  pass "every harness's turn end reports a finished turn, and nothing else does"
}

test_publish_failure_never_fails_the_mutation() {
  local state gen out
  state=$(new_state_dir publish-failure)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1)
  reset_publish_log
  export FM_PUBLISH_EXIT=3
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "a failing publish failed the busy-state write"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "expected 'idle claude-hook', got '$out'"
  reset_publish_log
  # An absent CLI is the same class of problem and must behave the same way.
  FM_THURBOX_BIN="$TMP_ROOT/does-not-exist" \
    "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "a missing publish CLI failed the busy-state write"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy claude-hook" ] || fail "expected 'busy claude-hook', got '$out'"
  pass "a refused, failing, or absent publish never fails the busy-state write"
}

test_publish_never_pollutes_the_writer_stdout() {
  local state gen
  state=$(new_state_dir publish-stdout)
  publish_meta "$state" t1 thurbox
  reset_publish_log
  export FM_PUBLISH_NOISE=1
  # fm-spawn reads the minted gen from arm's stdout, so a chatty backend CLI
  # must not reach it.
  gen=$("$EV" arm "$state" t1 2>/dev/null) || fail "arm failed"
  [ "$gen" = "$(cat "$state/t1.busy-gen")" ] \
    || fail "arm's stdout carried more than the minted gen: '$gen'"
  unset FM_PUBLISH_NOISE
  pass "publishing never writes to the writer's own stdout"
}

test_publish_reports_the_launch_turn_before_any_metadata_exists() {
  local state gen
  state=$(new_state_dir publish-launch)
  reset_publish_log
  # fm-spawn arms BEFORE it writes the task metadata, so this is the real
  # fresh-spawn shape: no metadata on disk at all.
  [ ! -e "$state/t1.meta" ] || fail "fixture wrote metadata it should not have"
  gen=$("$EV" arm "$state" t1 --publish-backend thurbox --publish-target "$PUBLISH_UUID:%20") \
    || fail "arm with an explicit endpoint failed"
  [ "$(published)" = "$PUBLISH_UUID working" ] \
    || fail "the launch turn was not published, got '$(published)'"
  # And the metadata gate is what every later event still uses: the same arm
  # with no named endpoint has nothing to resolve and publishes nothing.
  reset_publish_log
  "$EV" arm "$state" t2 >/dev/null || fail "plain arm failed"
  [ -z "$(published)" ] || fail "a pre-metadata arm published '$(published)' with no endpoint named"
  pass "a fresh spawn publishes its launch turn only when it names the endpoint"
}

test_publish_endpoint_is_accepted_on_arm_only() {
  local state gen
  state=$(new_state_dir publish-argument-gate)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  reset_publish_log
  # Every other caller runs once the metadata exists, so letting it name an
  # endpoint would let it publish somewhere the task's own record does not.
  if "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
      --publish-backend thurbox --publish-target "$PUBLISH_UUID:%20" 2>/dev/null; then
    fail "apply accepted an explicit publish endpoint"
  fi
  if "$EV" retire "$state" t1 --gen "$gen" \
      --publish-backend thurbox --publish-target "$PUBLISH_UUID:%20" 2>/dev/null; then
    fail "retire accepted an explicit publish endpoint"
  fi
  [ -z "$(published)" ] || fail "a refused invocation published '$(published)'"
  # A malformed pair is refused rather than silently ignored.
  if "$EV" arm "$state" t2 --publish-backend 'thurbox;rm -rf /' --publish-target x 2>/dev/null; then
    fail "arm accepted a malformed publish backend"
  fi
  if "$EV" arm "$state" t3 --publish-backend thurbox --publish-target '' 2>/dev/null; then
    fail "arm accepted an empty publish target"
  fi
  pass "an explicit publish endpoint is accepted on arm only, and validated"
}

test_publish_budget_cannot_be_disabled_by_a_zero_override() {
  local state gen started block start elapsed
  state=$(new_state_dir publish-budget)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  reset_publish_log
  block="$state/block"
  started="$state/started"
  : > "$block"
  # `timeout 0` and the perl fallback's `alarm 0` both DISABLE the deadline
  # (bin/fm-timeout-lib.sh's own contract), so an unsanitized 0 would leave this
  # hanging on the stub for its full 10s cap instead of being bounded.
  start=$(date +%s)
  FM_PUBLISH_BLOCK="$block" FM_PUBLISH_STARTED="$started" \
    FM_BUSY_PUBLISH_BUDGET_SECS=0 \
    "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "a bounded publish failed the busy-state write"
  elapsed=$(( $(date +%s) - start ))
  rm -f "$block"
  [ -e "$started" ] || fail "the stub never ran, so nothing was bounded"
  [ "$elapsed" -lt 8 ] \
    || fail "a zero budget disabled the bound: the write took ${elapsed}s"
  [ "$(fm_busy_classify tmux w1 claude t1 "$state")" = "idle claude-hook" ] \
    || fail "the record did not survive a bounded publish"
  # A non-numeric override degrades to the default bound the same way.
  reset_publish_log
  : > "$block"
  start=$(date +%s)
  FM_PUBLISH_BLOCK="$block" FM_BUSY_PUBLISH_BUDGET_SECS=not-a-number \
    "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "a garbage budget failed the busy-state write"
  elapsed=$(( $(date +%s) - start ))
  rm -f "$block"
  [ "$elapsed" -lt 8 ] || fail "a garbage budget disabled the bound: ${elapsed}s"
  # A FRACTIONAL override is the subtle one: it is strictly positive, so a
  # "positive" test admits it and passes it straight through. Whether that
  # disables the deadline depends on the host's timeout mechanism - the perl
  # fallback's `alarm` takes whole seconds and truncates 0.5 to alarm(0),
  # which is the same defect as a zero budget on any host with neither
  # `timeout` nor `gtimeout`. So the property asserted here is the portable
  # one the sanitizer actually promises: a fractional value is REJECTED and
  # the default bound applies instead, rather than becoming the bound itself.
  reset_publish_log
  : > "$block"
  start=$(date +%s)
  FM_PUBLISH_BLOCK="$block" FM_BUSY_PUBLISH_BUDGET_SECS=0.5 \
    "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "a fractional budget failed the busy-state write"
  elapsed=$(( $(date +%s) - start ))
  rm -f "$block"
  [ "$elapsed" -ge 3 ] \
    || fail "a fractional budget became the bound (${elapsed}s) instead of being rejected"
  [ "$elapsed" -lt 8 ] || fail "a fractional budget disabled the bound: ${elapsed}s"
  [ "$(fm_busy_classify tmux w1 claude t1 "$state")" = "idle claude-hook" ] \
    || fail "the record did not survive a bounded publish"
  pass "a zero, fractional, or malformed publish budget falls back to a real bound"
}

test_publish_lock_is_released_only_by_the_invocation_that_owns_it() {
  local state gen block started lock waited slow_pid
  state=$(new_state_dir publish-lock-ownership)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  reset_publish_log
  lock="$(fm_busy_record_path "$state" t1).publish.lock"
  block="$state/block"
  started="$state/started"
  : > "$block"
  # Hold one publication open, then take its lock away and hand the lock to a
  # different owner - which is what an operator, or a stale-break that fired
  # too early, would do. When the held publication finishes it must release
  # NOTHING: a holder that removed the successor's lock would let a third
  # publisher run alongside it, which is the inversion this lock prevents.
  FM_PUBLISH_BLOCK="$block" FM_PUBLISH_STARTED="$started" \
    "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop &
  slow_pid=$!
  waited=0
  while [ ! -e "$started" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$started" ] || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "the held publication never started"; }
  [ -d "$lock" ] || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "no publish lock was taken"; }
  rm -rf "$lock"
  mkdir "$lock" || fail "could not re-create the lock for a second owner"
  printf 'someone-else\n' > "$lock/owner"
  rm -f "$block"
  wait "$slow_pid" 2>/dev/null || fail "the held publication failed its write"
  [ -d "$lock" ] || fail "the held publication removed a lock it no longer owned"
  [ "$(cat "$lock/owner")" = someone-else ] \
    || fail "the held publication clobbered the successor's ownership marker"
  rm -rf "$lock"
  # A genuinely abandoned lock is still recoverable, so the guard cannot wedge
  # publishing for good.
  mkdir "$lock"
  printf 'abandoned\n' > "$lock/owner"
  touch -d '@1' "$lock" 2>/dev/null || touch -t 197001020000 "$lock"
  reset_publish_log
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "a publish behind an abandoned lock failed the busy-state write"
  [ "$(published)" = "$PUBLISH_UUID working" ] \
    || fail "an abandoned lock was not reclaimed, got '$(published)'"
  [ ! -e "$lock" ] || fail "the reclaiming publication did not release its own lock"
  pass "a publish lock is released only by its owner, and an abandoned one is still reclaimed"
}

test_a_live_publication_is_never_declared_abandoned() {
  local state gen block started lock waited slow_pid
  state=$(new_state_dir publish-lock-stale-bound)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  reset_publish_log
  lock="$(fm_busy_record_path "$state" t1).publish.lock"
  block="$state/block"
  started="$state/started"
  : > "$block"
  FM_PUBLISH_BLOCK="$block" FM_PUBLISH_STARTED="$started" \
    "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop &
  slow_pid=$!
  waited=0
  while [ ! -e "$started" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$started" ] || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "the held publication never started"; }
  # The stale bound has to outlive the bounded call it serializes, so it is
  # derived from the publish budget rather than from FM_BUSY_LOCK_STALE_SECS -
  # which defaults EQUAL to that budget, and is pinned below the holder's own
  # bound here to prove the derivation. A threshold that is not strictly
  # greater lets this second writer declare a still-running holder abandoned,
  # break into its lock, and publish alongside it.
  FM_BUSY_LOCK_STALE_SECS=1 \
    "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "a contended publish failed the busy-state write"; }
  [ -z "$(published)" ] \
    || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "a live holder was declared abandoned: '$(published)'"; }
  [ -d "$lock" ] \
    || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "the live holder's lock was broken"; }
  rm -f "$block"
  wait "$slow_pid" 2>/dev/null || fail "the held publication failed its write"
  [ "$(published)" = "$PUBLISH_UUID done" ] \
    || fail "expected only the held publication, got '$(published)'"
  [ ! -e "$lock" ] || fail "the holder did not release its own lock"
  pass "a publication still inside its own budget is never declared abandoned"
}

test_publish_is_dropped_rather_than_landing_out_of_order() {
  local state gen block started waited
  state=$(new_state_dir publish-ordering)
  publish_meta "$state" t1 thurbox
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  reset_publish_log
  block="$state/block"
  started="$state/started"
  : > "$block"
  # Hold one publication open inside the backend CLI, then drive a second event
  # against it. The second must still write its record - the mutation can never
  # depend on this side effect - and must not queue behind the slow call on a
  # turn hook, so it publishes nothing at all.
  FM_PUBLISH_BLOCK="$block" FM_PUBLISH_STARTED="$started" \
    "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop &
  local slow_pid=$!
  waited=0
  while [ ! -e "$started" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$started" ] || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "the held publication never started"; }
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "a contended publish failed the busy-state write"; }
  [ -z "$(published)" ] \
    || { rm -f "$block"; wait "$slow_pid" 2>/dev/null; fail "a contended publication landed anyway: '$(published)'"; }
  rm -f "$block"
  wait "$slow_pid" 2>/dev/null || fail "the held publication failed its write"
  # Exactly one publication went out, and the record - not the UI - is what the
  # second event advanced.
  [ "$(published)" = "$PUBLISH_UUID done" ] \
    || fail "expected the single held publication, got '$(published)'"
  [ "$(fm_busy_classify tmux w1 claude t1 "$state")" = "busy claude-hook" ] \
    || fail "the contended event did not advance the record"
  pass "a publication contending with one in flight is dropped, never reordered"
}

test_arm_seeds_busy_spawn
test_apply_advances_seq_and_source
test_apply_current_gen_reset
test_apply_unarmed_refused
test_retire_serializes_and_rejects_stale_gen
test_retire_missing_sidecar_is_idempotent
test_stale_lock_broken_under_gnu_stat
test_stale_gen_event_rejected
test_stale_gen_record_unknown
test_missing_record_unknown_not_idle
test_malformed_record_unknown
test_record_without_sidecar_unknown
test_source_mismatch_cross_adapter
test_converted_adapters_ignore_footer_text
test_grok_regex_isolated
test_codex_unverified_gate
test_kimi_unverified_gate
test_cursor_ignores_rendered_and_native_signals
test_dead_endpoint_overrides
test_herdr_native_busy_only
test_record_read_leaves_caller_shell_intact
test_boolean_view_never_promotes_unknown
test_publish_reports_every_written_state_to_a_thurbox_task
test_publish_is_skipped_for_a_default_backend_task
test_publish_is_a_no_op_for_a_backend_without_a_state_surface
test_publish_never_reports_a_state_firstmate_cannot_place
test_publish_never_follows_a_refused_event
test_retirement_reports_the_task_at_rest
test_retirement_publish_never_fails_or_delays_the_retirement
test_publish_carries_every_harness_turn_end_through_the_writer
test_publish_failure_never_fails_the_mutation
test_publish_never_pollutes_the_writer_stdout
test_publish_reports_the_launch_turn_before_any_metadata_exists
test_publish_endpoint_is_accepted_on_arm_only
test_publish_budget_cannot_be_disabled_by_a_zero_override
test_publish_lock_is_released_only_by_the_invocation_that_owns_it
test_a_live_publication_is_never_declared_abandoned
test_publish_is_dropped_rather_than_landing_out_of_order

echo "all fm-busy-state tests passed"
