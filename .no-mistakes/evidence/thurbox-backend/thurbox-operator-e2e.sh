#!/usr/bin/env bash
# thurbox-operator-e2e.sh - end-to-end operator-level demonstration of the
# thurbox runtime backend on the 2.10 surface.
#
# Drives firstmate's REAL operator commands (fm-peek.sh, fm-send.sh,
# fm-crew-state.sh, fm-teardown.sh) against a task recorded as backend=thurbox,
# with a stubbed `thurbox-cli` standing in for real thurbox 2.10.1 (JSON shapes
# taken from the live verification log in docs/thurbox-backend.md) and a `tmux`
# TRIPWIRE on PATH that fails loudly on any invocation.
#
# The stub is required, not a convenience: a real thurbox test cannot be
# isolated from the operator's live sessions (shared tmux socket + leaked
# automation-heartbeat window), which is why the repo ships
# tests/thurbox-test-safety.sh instead of a real-binary smoke test.
set -u

ROOT=${1:?usage: thurbox-operator-e2e.sh <firstmate-root>}
ROOT=$(cd "$ROOT" && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/thurbox-e2e.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

FB="$WORK/fakebin"; mkdir -p "$FB"

# --- a fake thurbox-cli speaking the 2.10.1 surface -------------------------
cat > "$FB/thurbox-cli" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_TB_LOG:?}"
ROWS="${FM_TB_ROWS:?}"
{ printf 'thurbox-cli'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$LOG"

emit_row() {  # <uuid> <name> <pane> <btype> <hook>
  local pane=$3 hook=$5
  [ "$pane" = - ] && pane='' || :
  if [ "$hook" = - ]; then hook=null; else hook="\"$hook\""; fi
  printf '{"id":"%s","name":"%s","backend_id":"%s","backend_type":"%s","hook_state":%s,"cwd":"/w","agent":"shell","worktrees":[]}' \
    "$1" "$2" "$pane" "$4" "$hook"
}

case "${1:-}" in
  version)
    printf '{"version":"%s","schema_version":40,"tmux_socket":"thurbox","data_dir":"/d"}\n' \
      "${FM_TB_FAKE_VERSION:-2.10.1}"
    exit 0 ;;
  config)
    printf '{"valid":true,"agents_toml":{"exists":true,"valid":true,"path":"%s","problems":[]}}\n' \
      "${FM_TB_AGENTS_TOML:-/nonexistent}"
    exit 0 ;;
  session) : ;;
  *) exit 0 ;;
esac

case "${2:-}" in
  list)
    printf '['
    first=1
    while IFS=$'\t' read -r uuid name pane btype hook; do
      [ -n "${uuid:-}" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      emit_row "$uuid" "$name" "$pane" "$btype" "$hook"
    done < "$ROWS"
    printf ']\n' ;;
  get)
    want=${3:-}
    while IFS=$'\t' read -r uuid name pane btype hook; do
      if [ "${uuid:-}" = "$want" ]; then emit_row "$uuid" "$name" "$pane" "$btype" "$hook"; printf '\n'; exit 0; fi
    done < "$ROWS"
    echo "session not found" >&2; exit 1 ;;
  delete)
    want=${3:-}
    tmpf=$(mktemp)
    while IFS=$'\t' read -r uuid name pane btype hook; do
      [ "${uuid:-}" = "$want" ] && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$uuid" "$name" "$pane" "$btype" "$hook" >> "$tmpf"
    done < "$ROWS"
    mv "$tmpf" "$ROWS"
    printf '{"deleted":true,"forced":true,"killed_window":true,"id":"%s"}\n' "$want" ;;
  capture)
    want=${3:-}
    row=$(grep "^$want	" "$ROWS" | head -1)
    [ -n "$row" ] || { echo "session not found" >&2; exit 1; }
    rowpane=$(printf '%s' "$row" | cut -f3)
    case " ${FM_TB_PANES:-} " in
      *" $rowpane "*) : ;;
      *) echo "pane is gone" >&2; exit 1 ;;
    esac
    ansi=false
    for a in "$@"; do [ "$a" = --ansi ] && ansi=true; done
    body="${FM_TB_CAPTURE:?}"
    [ "$ansi" = true ] && body="${FM_TB_SCREEN:?}"
    jq -Rs --argjson ansi "$ansi" \
      --arg cy "${FM_TB_CURSOR_ROW:-0}" \
      --arg fp "${FM_TB_FG_PROCESS:-}" \
      --arg fc "${FM_TB_FG_COMMAND:-}" '{
        output: ., ansi: $ansi,
        cursor_row: ($cy | if . == "" then null else tonumber end), cursor_col: 0,
        foreground_process: (if $fp == "" then null else $fp end),
        foreground_command: (if $fc == "" then null else $fc end),
        foreground_cwd: "/w"
      }' < "$body" ;;
  send)
    # `session send --no-enter` types unsubmitted input. The fixture mirrors the
    # real pane by appending the typed text into the composer line of the
    # screen files, so a later capture shows what a real pane would show.
    text=''
    while [ $# -gt 0 ]; do
      case "$1" in --) shift; text=${1:-}; break ;; *) shift ;; esac
    done
    printf '%s' "$text" >> "${FM_TB_COMPOSER:?}"
    "${FM_TB_RENDER:?}"
    exit 0 ;;
  key)
    # `session key <session> <key>`: with the leading `session` word the key
    # name is the fourth argv slot.
    key=${4:-}
    case "$key" in
      enter) : > "${FM_TB_COMPOSER:?}"; "${FM_TB_RENDER:?}" ;;   # submit clears the composer
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FB/thurbox-cli"

# --- tmux TRIPWIRE: the 2.10 adapter must never shell out to tmux ----------
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'tmux'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FM_TB_TMUXLOG:?}"
echo "TRIPWIRE: the thurbox adapter invoked tmux" >&2
exit 97
SH
chmod +x "$FB/tmux"

# --- treehouse stub: the WORKTREE provider, deliberately not thurbox's job ---
# thurbox is a session provider only (docs/thurbox-backend.md "Why not the
# worktree provider"), so teardown still returns the worktree through
# treehouse. It is stubbed here because this walkthrough is about the session
# backend, not the worktree plane.
cat > "$FB/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'treehouse'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FM_TB_TREEHOUSELOG:?}"
exit 0
SH
chmod +x "$FB/treehouse"

# --- the fake pane: a Claude-style composer rendered from the typed text ----
cat > "$WORK/render" <<'SH'
#!/usr/bin/env bash
set -u
typed=$(cat "${FM_TB_COMPOSER:?}")
{
  printf '  Welcome to Claude Code\n'
  printf '\n'
  printf '> tell me about this repo\n'
  printf '\n'
  printf '  I looked at the tree and it is a bash fleet manager.\n'
  printf '\n'
  printf '╭──────────────────────────────────────────────────────────────╮\n'
  printf '│ > %s%*s│\n' "$typed" $((59 - ${#typed})) ''
  printf '╰──────────────────────────────────────────────────────────────╯\n'
} > "${FM_TB_CAPTURE:?}"
# The styled screen is the same body with SGR sequences, which is what
# `session capture --ansi` returns and what the composer classifier reads.
sed 's/│/\x1b[2m│\x1b[0m/g' "${FM_TB_CAPTURE:?}" > "${FM_TB_SCREEN:?}"
SH
chmod +x "$WORK/render"

# --- world state ------------------------------------------------------------
UUID=7f3a91c4-2b8e-4d6f-9a10-5c7e2f4b8d31
PANE=%23
STATE="$WORK/state"; mkdir -p "$STATE"
NEUTRAL="$WORK/neutral"; mkdir -p "$NEUTRAL/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NEUTRAL/bin/fm-guard.sh"; chmod +x "$NEUTRAL/bin/fm-guard.sh"

export FM_TB_ROWS="$WORK/rows.tsv"
export FM_TB_LOG="$WORK/cli.log"
export FM_TB_TMUXLOG="$WORK/tmux.log"
export FM_TB_TREEHOUSELOG="$WORK/treehouse.log"
export FM_TB_CAPTURE="$WORK/capture.txt"
export FM_TB_SCREEN="$WORK/screen.txt"
export FM_TB_COMPOSER="$WORK/composer.txt"
export FM_TB_RENDER="$WORK/render"
export FM_TB_PANES="$PANE"
export FM_THURBOX_BIN="$FB/thurbox-cli"
: > "$FM_TB_ROWS"; : > "$FM_TB_LOG"; : > "$FM_TB_TMUXLOG"; : > "$FM_TB_COMPOSER"
: > "$FM_TB_TREEHOUSELOG"
"$WORK/render"

# Neutralize the ambient session so this run does not depend on whether the
# operator's own shell happens to be inside thurbox or tmux.
unset THURBOX_SESSION TMUX TMUX_PANE

TASK=steerdemo
# The scoped session name is home-tagged; compute it exactly as the adapter
# would for the home the operator commands will run under.
TITLE=$( FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL" bash -c \
  '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/thurbox.sh"; fm_backend_thurbox_scoped_title fm-'"$TASK" _ "$ROOT" )
printf '%s\t%s\t%s\tlocal-tmux\t-\n' "$UUID" "$TITLE" "$PANE" >> "$FM_TB_ROWS"

WT="$WORK/worktree"
git init -q "$WT"
printf '# demo\n' > "$WT/README.md"
git -C "$WT" add README.md
git -C "$WT" -c user.name=demo -c user.email=demo@example.invalid commit -qm initial

{
  printf 'window=%s:%s\n' "$UUID" "$PANE"
  printf 'endpoint_task_id=%s\n' "$TASK"
  printf 'backend=thurbox\n'
  printf 'thurbox_session_id=%s\n' "$UUID"
  printf 'thurbox_pane_id=%s\n' "$PANE"
  printf 'worktree=%s\n' "$WT"
  printf 'project=%s\n' "$WT"
  printf 'harness=claude\n'
  printf 'kind=scout\n'
} > "$STATE/$TASK.meta"
touch "$STATE/.last-watcher-beat"

say() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; }

# FM_GATE_REFUSE_BYPASS=1 is the seam firstmate's own harness uses
# (tests/lib.sh:35): this walkthrough runs inside a no-mistakes gate worktree,
# whose fleet-lifecycle refusal would otherwise stop fm-send/fm-teardown before
# they reach the backend. Everything they touch here is the stub fixture.
FM_ENV=( PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL"
         FM_STATE_OVERRIDE="$STATE" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.01
         FM_GATE_REFUSE_BYPASS=1 )

printf 'thurbox operator end-to-end walkthrough\n'
printf 'firstmate root : %s\n' "$ROOT"
printf 'task           : %s (backend=thurbox)\n' "$TASK"
printf 'thurbox session: %s  name=%s  pane=%s\n' "$UUID" "$TITLE" "$PANE"
printf 'thurbox-cli    : stub speaking 2.10.1; tmux on PATH is a tripwire that fails on any call\n'

say "1. state/$TASK.meta - what a thurbox spawn records"
cat "$STATE/$TASK.meta"

say "2. bin/fm-peek.sh - read the agent's pane through thurbox-cli"
run "bin/fm-peek.sh fm-$TASK 12"
env "${FM_ENV[@]}" "$ROOT/bin/fm-peek.sh" "fm-$TASK" 12
echo "(exit $?)"

say "3. bin/fm-send.sh - steer the task (durable inbox record + terminal doorbell)"
run "bin/fm-send.sh $TASK 'switch to the retry-budget branch and rerun the suite'"
env "${FM_ENV[@]}" "$ROOT/bin/fm-send.sh" "$TASK" 'switch to the retry-budget branch and rerun the suite'
echo "(exit $?)"

say "4. the durable steering record the send created"
for f in "$STATE/$TASK.inbox"/*.msg; do
  printf -- '--- %s ---\n' "${f#$STATE/}"
  cat "$f"
done

say "5. the pane after the steer - doorbell typed and submitted, composer empty again"
env "${FM_ENV[@]}" "$ROOT/bin/fm-peek.sh" "fm-$TASK" 12

say "6. bin/fm-crew-state.sh - task state read through the thurbox backend"
run "bin/fm-crew-state.sh $TASK"
env "${FM_ENV[@]}" "$ROOT/bin/fm-crew-state.sh" "$TASK" 2>&1 | sed -n '1,12p'

say "7. thurbox's native hook_state drives busy - agent signals working"
printf '%s\t%s\t%s\tlocal-tmux\tworking\n' "$UUID" "$TITLE" "$PANE" > "$FM_TB_ROWS"
run "fm_backend_dispatch busy-state (backend=thurbox, hook_state=working)"
env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL" bash -c \
  '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/thurbox.sh"; printf "hook_state=working -> busy_state=%s\n" "$(fm_backend_thurbox_busy_state "$2" fm-'"$TASK"')"' _ "$ROOT" "$UUID:$PANE"
printf '%s\t%s\t%s\tlocal-tmux\t-\n' "$UUID" "$TITLE" "$PANE" > "$FM_TB_ROWS"
env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL" bash -c \
  '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/thurbox.sh"; printf "hook_state=null    -> busy_state=%s (never idle before the first signal)\n" "$(fm_backend_thurbox_busy_state "$2" fm-'"$TASK"')"' _ "$ROOT" "$UUID:$PANE"

say "7b. a Cursor Agent pane - cursor parked outside the composer"
# Cursor parks its terminal cursor BELOW its footer, so the cursor-anchored
# read can only answer `unknown` and every steer would report an unverified
# submit. The 2.10 adapter reclassifies such a pane from `session capture`'s
# own foreground_command argv - a bundled Cursor CLI reports a bare `node`, so
# the argv is the only thing that can identify it.
: > "$FM_TB_COMPOSER"
# Cursor's real composer shape: a borderless arrow-prompt line above its
# model/footer rows, with the terminal cursor parked on a row below them.
printf '\n  \xe2\x86\x92 rerun the failing case\n\n  Cursor Grok 4.5 High                    Run Everything\n  /w \xc2\xb7 main\n\n' \
  > "$FM_TB_CAPTURE"
cp "$FM_TB_CAPTURE" "$FM_TB_SCREEN"
export FM_TB_CURSOR_ROW=6   # below the footer: not a composer locator
printf 'the pane an operator would see:\n'; sed 's/^/  | /' "$FM_TB_CAPTURE"

verdict() {  # <label> <fg-process> <fg-command>
  env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL" \
    FM_TB_FG_PROCESS="$2" FM_TB_FG_COMMAND="$3" bash -c \
    '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/thurbox.sh"
     printf "%-58s -> composer verdict: %s\\n" "$3" "$(fm_backend_thurbox_composer_state "$2" fm-'"$TASK"')"' \
    _ "$ROOT" "$UUID:$PANE" "$1"
}
verdict "no foreground process reported" '' ''
verdict "foreground_process=node (name only, as a bundled CLI reports)" node ''
verdict "foreground_command carries Cursor's argv" node \
  '/home/u/.local/share/cursor-agent/versions/2026.08.11/cursor-agent --resume'
echo
echo "Reading: with only the cursor row to go on the verdict is unknown (an unverifiable"
echo "steer); the pane is reclassified cursorlessly - and the pending text in the composer"
echo "found - only once the argv identifies Cursor. A bare command NAME is not enough,"
echo "which is what the head commit fixed."
unset FM_TB_CURSOR_ROW

say "8. bin/fm-teardown.sh --force - retire the task, reclaiming the thurbox session"
run "bin/fm-teardown.sh $TASK --force"
env "${FM_ENV[@]}" FM_DATA_OVERRIDE="$WORK/data" FM_CONFIG_OVERRIDE="$WORK/config" \
  "$ROOT/bin/fm-teardown.sh" "$TASK" --force 2>&1 | sed -n '1,25p'
printf '\nsession rows remaining after teardown: %s\n' "$(wc -l < "$FM_TB_ROWS" | tr -d ' ')"

say "9. every thurbox-cli call this walkthrough made"
cat -v "$FM_TB_LOG"

say "10. tmux invocations (the 2.10 rework must make ZERO)"
if [ -s "$FM_TB_TMUXLOG" ]; then
  echo "TRIPWIRE FIRED:"; cat "$FM_TB_TMUXLOG"; exit 1
fi
echo "(empty - the adapter drove thurbox-cli only)"

say "11. operator preflight gates, as bin/fm-spawn.sh's thurbox arm runs them"
run "container_ensure with thurbox 2.9.2 installed (below the 2.10 floor)"
env PATH="$FB:$PATH" FM_THURBOX_BIN="$FB/thurbox-cli" FM_TB_FAKE_VERSION=2.9.2 \
  FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL" bash -c \
  '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/thurbox.sh"; fm_backend_thurbox_container_ensure; echo "(exit $?)"' _ "$ROOT" 2>&1

run "container_ensure on 2.10.1 with no interactive-shell agent in agents.toml"
printf '[[agents]]\nname = "claude"\ncommand = "claude"\n' > "$WORK/agents.toml"
env PATH="$FB:$PATH" FM_THURBOX_BIN="$FB/thurbox-cli" FM_TB_AGENTS_TOML="$WORK/agents.toml" \
  FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL" bash -c \
  '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/thurbox.sh"; fm_backend_thurbox_container_ensure; echo "(exit $?)"' _ "$ROOT" 2>&1

run "container_ensure once the documented [[agents]] entry exists"
printf '[[agents]]\nname = "shell"\ncommand = "bash"\nargs = ["-i"]\n' >> "$WORK/agents.toml"
env PATH="$FB:$PATH" FM_THURBOX_BIN="$FB/thurbox-cli" FM_TB_AGENTS_TOML="$WORK/agents.toml" \
  FM_ROOT_OVERRIDE="$NEUTRAL" FM_HOME="$NEUTRAL" bash -c \
  '. "$1/bin/fm-backend.sh"; . "$1/bin/backends/thurbox.sh"; fm_backend_thurbox_container_ensure && echo "gate passed (exit 0)"' _ "$ROOT" 2>&1

run "the toolchain firstmate demands for backend=thurbox"
env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$NEUTRAL" bash -c \
  '. "$1/bin/fm-backend.sh"; printf "required tools: %s\n" "$(fm_backend_required_tools thurbox)"' _ "$ROOT"

printf '\nWALKTHROUGH COMPLETE\n'
