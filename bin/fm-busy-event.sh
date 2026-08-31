#!/usr/bin/env bash
# fm-busy-event.sh - the ONLY writer of the semantic busy-state contract
# owned by bin/fm-busy-lib.sh (record format, gen binding, and classification
# live there; this script owns mutation mechanics only).
#
# Subcommands:
#
#   arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
#           [--publish-backend B --publish-target T]
#       Mint a fresh incarnation gen token, write the gen sidecar, and seed
#       the record at seq=1 (default: busy, source fm-spawn, event
#       launch-brief - the launch prompt IS a submitted turn). Prints the
#       minted gen on stdout so the caller can embed it into adapter wiring.
#       Arming again replaces the previous incarnation: late events carrying
#       the old gen are rejected as stale from then on.
#       --publish-backend and --publish-target name the runtime endpoint for
#       the publish side effect described below, and are accepted on arm ONLY.
#       fm-spawn arms BEFORE it writes the task's metadata, so at arm time
#       there is no recorded endpoint to read and the launch turn - the one
#       turn a fresh worker is guaranteed to be running - would otherwise
#       never be published. Every other caller runs once that metadata exists
#       and keeps reading it, so the metadata gate below is unchanged for
#       them.
#
#   apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen)
#         --source S --event E
#       Append one lifecycle event: validate the gen against the armed
#       sidecar, advance seq under the lock, atomically replace the record.
#       Adapter wiring passes the exact --gen embedded at arm time, so a
#       hook that outlives its incarnation fails closed here. The legacy
#       Claude fm-send --key Escape path (fm-interrupt) and firstmate recovery
#       paths (fm-recovery) may pass --current-gen to bind to the incarnation
#       armed right now.
#
#   retire <state-dir> <id> (--gen G | --current-gen)
#       Remove one incarnation's sidecar and record while holding the same
#       writer lock used by arm and apply. An exact gen prevents teardown for
#       an old task from retiring a newly armed incarnation. A missing sidecar
#       is already retired, so any orphan record is removed idempotently.
#
# Exit codes: 0 applied; 1 refused (stale gen, unarmed task, lock timeout,
# invalid input); 2 usage. Adapter hook command lines append `|| true` so a
# refusal never breaks the harness's own lifecycle.
#
# After a SUCCESSFUL arm or apply - never before one, never for a refused
# event, and never for a retirement - the state just written is published to
# the task's runtime backend when that backend renders agent state in its own
# UI (fm_backend_publish_busy_state in bin/fm-backend.sh). That is a bounded,
# best-effort side effect of the mutation: it can never fail the write above,
# and the value it sends is re-read from the record rather than taken from this
# invocation's arguments, so a writer the record has already moved past reports
# the superseding state instead of inverting the UI with its own stale one.
#
# The published value is not invisible to firstmate, and describing this as
# one-way traffic would be wrong. It lands in the very field an adapter's
# native fm_backend_busy_state reads back, and bin/fm-busy-lib.sh consults
# that read on exactly one path: a task with NO record at all. What it can
# echo there is only the last state this writer itself published - never a
# state firstmate did not assert - and any live record outranks it, so the
# record stays authoritative without this being a closed loop.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-busy-event.sh arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
                                        [--publish-backend B --publish-target T]
  fm-busy-event.sh apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen) --source S --event E
  fm-busy-event.sh retire <state-dir> <id> (--gen G | --current-gen)
See the header comment for the full contract.
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# fm_run_timed: the shared hard bound around the publish side effect below, so
# a wedged backend CLI can never hold a harness's turn hook open.
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CMD=${1:-}
case "$CMD" in
  arm|apply|retire) shift ;;
  *) usage ;;
esac

STATE=${1:-}
ID=${2:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
shift 2
case "$ID" in *[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

NEW_STATE=
GEN=
USE_CURRENT_GEN=0
SOURCE=
EVENT=
PUBLISH_BACKEND=
PUBLISH_TARGET=
if [ "$CMD" = apply ]; then
  NEW_STATE=${1:-}
  case "$NEW_STATE" in busy|idle|unknown) shift ;; *) usage ;; esac
elif [ "$CMD" = arm ]; then
  NEW_STATE=busy
  SOURCE=fm-spawn
  EVENT=launch-brief
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --state) NEW_STATE=${2:-}; shift 2 || usage ;;
    --gen) GEN=${2:-}; shift 2 || usage ;;
    --current-gen) USE_CURRENT_GEN=1; shift ;;
    --source) SOURCE=${2:-}; shift 2 || usage ;;
    --event) EVENT=${2:-}; shift 2 || usage ;;
    --publish-backend) PUBLISH_BACKEND=${2:-}; shift 2 || usage ;;
    --publish-target) PUBLISH_TARGET=${2:-}; shift 2 || usage ;;
    *) usage ;;
  esac
done
# The explicit publish endpoint exists only for the pre-metadata arm; letting
# apply or retire carry it would let any caller name an endpoint the task's own
# recorded metadata does not, which is exactly the gate that keeps every other
# backend a no-op.
if [ "$CMD" != arm ] && { [ -n "$PUBLISH_BACKEND" ] || [ -n "$PUBLISH_TARGET" ]; }; then
  echo "error: --publish-backend/--publish-target are accepted on arm only" >&2
  exit 2
fi
if [ -n "$PUBLISH_BACKEND" ] || [ -n "$PUBLISH_TARGET" ]; then
  fm_busy_token_valid "$PUBLISH_BACKEND" || { echo "error: invalid --publish-backend" >&2; exit 1; }
  # Target atoms are joined by ':' (bin/fm-backend.sh's target convention), so
  # this is fm_backend_endpoint_atom_valid's character class plus that joiner.
  case "$PUBLISH_TARGET" in
    ''|*[!A-Za-z0-9._@%:+-]*) echo "error: invalid --publish-target" >&2; exit 1 ;;
  esac
fi
if [ "$CMD" != retire ]; then
  case "$NEW_STATE" in busy|idle|unknown) : ;; *) usage ;; esac
  fm_busy_token_valid "$SOURCE" || { echo "error: invalid --source" >&2; exit 1; }
  fm_busy_token_valid "$EVENT" || { echo "error: invalid --event" >&2; exit 1; }
fi

REC=$(fm_busy_record_path "$STATE" "$ID")
GEN_FILE=$(fm_busy_gen_path "$STATE" "$ID")
LOCK="$REC.lock"
# A SECOND lock, deliberately not the writer lock above: it serializes the
# publish side effect without ever being held while a record is written, so a
# slow backend CLI can delay another publication but can never delay - let alone
# refuse - a busy-state write.
PUBLISH_LOCK="$REC.publish.lock"

# Portable mtime in epoch seconds. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU)
# stat uses `-c <fmt>`. Do NOT collapse this into `stat -f <fmt> ... || stat -c
# <fmt> ...`: on GNU `-f` is *filesystem* stat, so it reads the format string as
# a path, reports that on stderr, prints a partial filesystem dump ("  File:
# ...") on stdout, and still exits 0 - the fallback never runs and the caller
# gets a non-numeric token. Detect the platform once and pick the right form,
# exactly as bin/fm-watch.sh does.
if [ "$(uname)" = Darwin ]; then
  lock_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  lock_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Serialize writers. The lock protects seq advancement and the sidecar/record
# pair; a holder that died mid-write is broken after FM_BUSY_LOCK_STALE_SECS.
lock_acquire() {
  local tries=0 now mtime age
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      now=$(date +%s)
      mtime=$(lock_mtime "$LOCK" || true)
      # Anything unreadable or non-numeric reads as "just created", so an
      # unforeseen stat surprise degrades to a lock-timeout refusal instead of
      # aborting the writer - and its caller, fm-teardown.sh - under `set -u`.
      case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
      age=$((now - mtime))
      if [ "$age" -ge "${FM_BUSY_LOCK_STALE_SECS:-5}" ]; then
        rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
        mkdir "$LOCK" 2>/dev/null && break
      fi
      echo "error: busy-state lock timeout for $ID" >&2
      return 1
    fi
    sleep 0.05
  done
  return 0
}
lock_release() { rmdir "$LOCK" 2>/dev/null || true; }

# Serialize publications for this task. Its wait is deliberately much shorter
# than the writer lock's, because this runs on a harness's turn hook after the
# record is already safe: waiting longer would buy a cosmetic UI signal at the
# cost of hook latency, so a contended lock gives up and publishes nothing.
# Giving up is safe - the holder reads the same record this would have read.
publish_lock_acquire() {
  local tries=0 now mtime age
  while ! mkdir "$PUBLISH_LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      now=$(date +%s)
      mtime=$(lock_mtime "$PUBLISH_LOCK" || true)
      case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
      age=$((now - mtime))
      if [ "$age" -ge "${FM_BUSY_LOCK_STALE_SECS:-5}" ]; then
        rmdir "$PUBLISH_LOCK" 2>/dev/null || rm -rf "$PUBLISH_LOCK" 2>/dev/null || true
        mkdir "$PUBLISH_LOCK" 2>/dev/null && return 0
      fi
      return 1
    fi
    sleep 0.05
  done
  return 0
}
publish_lock_release() { rmdir "$PUBLISH_LOCK" 2>/dev/null || true; }

write_record() {  # <gen> <seq>
  local tmp
  tmp="$REC.tmp.$$"
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$1" "$2" "$NEW_STATE" "$SOURCE" "$EVENT" "$(date +%s)" > "$tmp" || return 1
  mv -f "$tmp" "$REC"
}

# publish_busy_state: hand the task's current busy state to its runtime backend,
# so a firstmate worker is not the one session in that backend's UI showing no
# state at all. Called only after the record has actually been replaced, which
# keeps the record the source of truth and this strictly a side effect of it.
#
# Four properties it must hold, because it runs on a harness's own hook path:
# it never fails the mutation (every failure mode returns 0), it never writes to
# this script's stdout (arm's caller reads the minted gen from there), it never
# runs unbounded, and it never reports a state the record has moved past.
#
# THE STATE COMES FROM THE RECORD, not from this invocation's own arguments,
# and that is what keeps concurrent writers from inverting the UI. The backend
# CLI call runs OUTSIDE the writer lock deliberately - holding that lock across
# a bounded-but-slow CLI call could make a concurrent hook's record write time
# out, and refusing a busy-state write to improve a UI signal is exactly the
# wrong trade. So two writers can reach this point in either order, and an
# invocation that published its OWN argument could re-assert a state the record
# had already left: a busy/idle pair racing on a turn boundary would leave the
# UI reading `working` against an idle record, which is the very mislabel this
# whole path exists to remove. Re-reading the record instead means a superseded
# invocation publishes the SUPERSEDING state rather than its own stale one, so
# whichever order the two calls land in, both agree with the record.
# fm_busy_record_read is the owner of that parse and of the gen binding, so a
# retired or superseded-incarnation record simply yields no state to publish.
#
# Publications are then serialized by their own lock so the last one to run is
# the one that read the record last. A contended lock publishes nothing rather
# than queueing behind a slow CLI on a turn hook; the residual is a UI that can
# lag the record by one event until the next turn boundary corrects it, never a
# UI that contradicts firstmate's own truth.
#
# The cheap gate is bin/fm-backend.sh's own compatibility contract: a task meta
# with no `backend=` line IS a tmux task, and tmux has no state surface to
# publish to, so the default path returns here without sourcing or forking
# anything. WHICH of the explicitly recorded backends can actually publish is
# the dispatcher's knowledge, not this script's - the no-op arm there is what
# keeps every other backend unchanged. An explicit --publish-backend/--target
# pair (arm only, before any metadata exists) replaces that read; it never
# relaxes it, because an absent pair still falls through to the metadata gate.
publish_busy_state() {
  local meta="$STATE/$ID.meta" backend=$PUBLISH_BACKEND target=$PUBLISH_TARGET
  local budget parsed p_state p_event
  if [ -z "$backend" ]; then
    [ -f "$meta" ] || return 0
    grep -q '^backend=' "$meta" 2>/dev/null || return 0
  elif [ "$backend" = tmux ]; then
    # The default backend has no state surface, and an absent `backend=` line
    # means exactly this - so name it here rather than forking to learn it.
    return 0
  fi
  # fm-timeout-lib.sh's contract: a non-positive bound is NOT a bound, because
  # `timeout 0` and the perl fallback's `alarm 0` both DISABLE the deadline. An
  # override of 0 would therefore turn this hard bound into no bound at all, on
  # a path a harness's turn hook waits for - so sanitize rather than trust the
  # value, and fall back to the default for anything not strictly positive. A
  # bad budget degrades to the default bound, never to an unbounded call.
  budget=${FM_BUSY_PUBLISH_BUDGET_SECS:-5}
  case "$budget" in
    ''|.|*[!0-9.]*|*.*.*) budget=5 ;;
    *[1-9]*) : ;;
    *) budget=5 ;;
  esac
  publish_lock_acquire || return 0
  parsed=$(fm_busy_record_read "$STATE" "$ID") || { publish_lock_release; return 0; }
  # fm_busy_record_read prints "<state> <source> <event> <seq>"; source and seq
  # are not published, so they are read into throwaways rather than reparsed.
  read -r p_state _ p_event _ <<< "$parsed"
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  fm_run_timed "$budget" bash -c '
    . "$1/fm-backend.sh" || exit 0
    backend=$3
    target=$4
    if [ -z "$backend" ]; then
      backend=$(fm_backend_of_meta "$2")
      target=$(fm_backend_target_of_meta "$2")
    fi
    fm_backend_publish_busy_state "$backend" "$target" "$5" "$6"
  ' fm-busy-publish "$SCRIPT_DIR" "$meta" "$backend" "$target" "$p_state" "$p_event" \
    >/dev/null 2>&1 || true
  publish_lock_release
  return 0
}

old_umask=$(umask)
umask 077

if [ "$CMD" = arm ]; then
  GEN="g$(date +%s).$$.$RANDOM"
  lock_acquire || exit 1
  {
    printf '%s\n' "$GEN" > "$GEN_FILE.tmp.$$" && mv -f "$GEN_FILE.tmp.$$" "$GEN_FILE" \
      && write_record "$GEN" 1
  } || { lock_release; umask "$old_umask"; echo "error: arm failed for $ID" >&2; exit 1; }
  lock_release
  umask "$old_umask"
  publish_busy_state
  printf '%s\n' "$GEN"
  exit 0
fi

# apply / retire
if [ "$USE_CURRENT_GEN" = 1 ] && [ "$CMD" != retire ]; then
  GEN=$(fm_busy_current_gen "$STATE" "$ID") || {
    umask "$old_umask"
    echo "error: no armed busy-state gen for $ID" >&2
    exit 1
  }
fi
if [ "$USE_CURRENT_GEN" != 1 ] || [ "$CMD" != retire ]; then
  fm_busy_token_valid "$GEN" || { umask "$old_umask"; echo "error: invalid --gen" >&2; exit 1; }
fi

lock_acquire || { umask "$old_umask"; exit 1; }
CURRENT=$(fm_busy_current_gen "$STATE" "$ID") || {
  if [ "$CMD" = retire ] && [ ! -e "$GEN_FILE" ] && [ ! -L "$GEN_FILE" ]; then
    rm -f "$REC" || {
      lock_release
      umask "$old_umask"
      echo "error: busy-state retirement failed for $ID" >&2
      exit 1
    }
    lock_release
    umask "$old_umask"
    exit 0
  fi
  lock_release
  umask "$old_umask"
  echo "error: no armed busy-state gen for $ID" >&2
  exit 1
}
if [ "$CMD" = retire ] && [ "$USE_CURRENT_GEN" = 1 ]; then
  GEN=$CURRENT
fi
if [ "$GEN" != "$CURRENT" ]; then
  lock_release
  umask "$old_umask"
  echo "error: stale busy-state gen for $ID (event rejected)" >&2
  exit 1
fi
if [ "$CMD" = retire ]; then
  rm -f "$GEN_FILE" "$REC" || {
    lock_release
    umask "$old_umask"
    echo "error: busy-state retirement failed for $ID" >&2
    exit 1
  }
  lock_release
  umask "$old_umask"
  exit 0
fi
OLD_SEQ=0
if [ -f "$REC" ]; then
  old_line=$(head -n 1 "$REC" 2>/dev/null || true)
  case "$old_line" in
    *" gen=$GEN "*)
      old_seq_field=${old_line##* seq=}
      old_seq_field=${old_seq_field%% *}
      case "$old_seq_field" in
        ''|*[!0-9]*) OLD_SEQ=0 ;;
        *) OLD_SEQ=$old_seq_field ;;
      esac
      ;;
  esac
fi
NEW_SEQ=$((OLD_SEQ + 1))
write_record "$GEN" "$NEW_SEQ" || {
  lock_release
  umask "$old_umask"
  echo "error: record write failed for $ID" >&2
  exit 1
}
lock_release
umask "$old_umask"
publish_busy_state
exit 0
