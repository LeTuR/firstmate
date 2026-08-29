#!/usr/bin/env bash
# thurbox-e2e-demo.sh - end-to-end walkthrough of firstmate's thurbox backend.
#
# Drives the REAL adapter (bin/backends/thurbox.sh) through one complete task
# lifecycle exactly as bin/fm-spawn.sh / the watcher / bin/fm-teardown.sh would,
# and prints every thurbox-cli and `tmux -L <thurbox-socket>` command the
# adapter actually issued.
#
# The two CLIs are STUBS inside the fixture, enforced by
# tests/thurbox-test-safety.sh: a real thurbox-cli would create windows on the
# operator's live thurbox tmux server (its socket is shared even when the
# database is not) and leak an automation-heartbeat window that no delete
# reclaims. Stub definitions are lifted verbatim from
# tests/fm-backend-thurbox.test.sh so the transcript matches what the suite runs.
set -u
ROOT=$1
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/thurbox-demo.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

. "$ROOT/tests/thurbox-test-safety.sh"
# Reuse the suite's fixture builder verbatim (lines 43-234 of the test file).
eval "$(sed -n '43,234p' "$ROOT/tests/fm-backend-thurbox.test.sh")"
FM_TB_REAL_PS=$(command -v ps); export FM_TB_REAL_PS
FAKEBIN=$(make_thurbox_fakebin "$TMP_ROOT")

export FM_TB_ROWS="$TMP_ROOT/rows.tsv" FM_TB_LOG="$TMP_ROOT/log" \
       FM_TB_TMUXLOG="$TMP_ROOT/tmuxlog" FM_TB_SCREEN="$TMP_ROOT/screen" \
       FM_TB_CAPTURE="$TMP_ROOT/capture"
: > "$FM_TB_ROWS"; : > "$FM_TB_LOG"; : > "$FM_TB_TMUXLOG"
export FM_TB_PANES="%23" FM_TB_CREATE_PANE="%23" \
       FM_TB_CREATE_UUID="0b797791-3590-41c5-9918-21e38d1a54d4" \
       FM_TB_AGENTS_TOML="$TMP_ROOT/agents.toml"
export FM_THURBOX_BIN="$FAKEBIN/thurbox-cli"
PATH="$FAKEBIN:$PATH"; export PATH

thurbox_refuse_if_unsafe "$TMP_ROOT" || { echo "SAFETY GUARD REFUSED - aborting"; exit 1; }
echo "safety guard: SAFE - both thurbox-cli and tmux resolve to stubs inside the fixture"
echo

FM_ROOT_OVERRIDE="$TMP_ROOT/home"; mkdir -p "$FM_ROOT_OVERRIDE/config"
export FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE="$FM_ROOT_OVERRIDE/config"
FM_ROOT=$FM_ROOT_OVERRIDE FM_HOME=$FM_ROOT_OVERRIDE
. "$ROOT/bin/backends/thurbox.sh"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-supervisor-target-lib.sh"

hr() { printf '\n=== %s ===\n' "$*"; }
cmds() {  # pretty-print the stub call logs since the last marker
  printf -- '--- commands the adapter issued ---\n'
  cat "$FM_TB_LOG" "$FM_TB_TMUXLOG" 2>/dev/null | tr '\037' ' ' | sed 's/^/  $ /'
  : > "$FM_TB_LOG"; : > "$FM_TB_TMUXLOG"
}

hr "0. an operator with no thurbox agents.toml entry is refused, with paste-ready TOML"
printf '[[agents]]\nname = "codex"\ncommand = "codex"\n' > "$TMP_ROOT/agents.toml"
fm_backend_thurbox_container_ensure; echo "container_ensure rc=$?"
cmds

hr "1. setup: the one thurbox-side config entry docs/thurbox-backend.md asks for"
cat >> "$TMP_ROOT/agents.toml" <<'TOML'

[[agents]]
name = "shell"
command = "bash"
args = ["-i"]
TOML
sed 's/^/  /' "$TMP_ROOT/agents.toml"
FM_BACKEND_THURBOX_SOCKET_CACHE=''
fm_backend_thurbox_container_ensure && echo "container_ensure rc=0 (agent 'shell' accepted)"
cmds

hr "2. backend detection: a firstmate started inside a thurbox pane resolves 'thurbox'"
echo "  THURBOX_SESSION=0b797791-... TMUX=/tmp/tmux-1000/thurbox,900,0"
echo "  -> fm_backend_detect  = $(THURBOX_SESSION=0b797791-3590-41c5-9918-21e38d1a54d4 TMUX='/tmp/tmux-1000/thurbox,900,0' fm_backend_detect)"
echo "  a REAL nested tmux inside that pane (different socket) must NOT be hijacked:"
echo "  THURBOX_SESSION=0b797791-... TMUX=/tmp/tmux-1000/default,901,0"
echo "  -> fm_backend_detect  = $(THURBOX_SESSION=0b797791-3590-41c5-9918-21e38d1a54d4 TMUX='/tmp/tmux-1000/default,901,0' fm_backend_detect)"
echo "  and the away-mode supervisor resolver agrees, so its refusal is reachable:"
echo "  -> discover_supervisor_backend = $(THURBOX_SESSION=0b797791-3590-41c5-9918-21e38d1a54d4 TMUX='/tmp/tmux-1000/thurbox,900,0' TMUX_PANE='%23' discover_supervisor_backend)"
cmds

hr "3. spawn: fm-spawn.sh creates the task's thurbox session"
target_raw=$(fm_backend_thurbox_create_task fm-demo1 /w) || echo "create failed"
uuid=${target_raw%% *}; pane=${target_raw##* }
TARGET="$uuid:$pane"
echo "  create_task fm-demo1 /w  ->  uuid=$uuid pane=$pane"
echo "  task endpoint recorded in meta: $TARGET"
cmds

hr "4. identity model: the UUID is durable, the pane id is only a cache"
echo "  thurbox-cli session restart moved the window %23 -> %24 (verified live on 2.9.2)"
sed -i 's/\t%23\t/\t%24\t/' "$FM_TB_ROWS"; export FM_TB_PANES="%24"
fm_backend_thurbox_target_ready "$TARGET" fm-demo1 \
  && echo "  target_ready re-resolved the stale endpoint $TARGET -> pane $FM_BACKEND_THURBOX_PANE"
cmds

hr "5. steer: unsubmitted literal input, then a named key - never 'session send'"
fm_backend_thurbox_send_literal "$TARGET" 'ship it, captain' fm-demo1 && echo "  send_literal rc=0"
fm_backend_thurbox_send_key "$TARGET" enter fm-demo1 && echo "  send_key enter rc=0"
cmds

hr "6. read the pane back (what the watcher and 'fm brief' show the operator)"
cat > "$FM_TB_CAPTURE" <<'SCREEN'
captain@fm-demo1:/w$ claude
> ship it, captain
  Working... (esc to interrupt)
SCREEN
echo "  capture (plain, via thurbox-cli session capture):"
fm_backend_thurbox_capture "$TARGET" 5 fm-demo1 | sed 's/^/    | /'
cmds

hr "7. composer fidelity: thurbox is the first non-tmux backend at tmux's caps"
echo "  composer_caps ->"; fm_backend_thurbox_composer_caps | sed 's/^/    /'
# A real Claude Code composer as it renders in the pane: the arrow row is the
# row the terminal cursor sits on (cursor=1 is what makes this anchored read
# possible at all on a non-tmux backend).
tb_screen() { printf '\n  \xe2\x86\x92 %s\n\n  Claude Sonnet 4.5                       Run Everything\n  /w \xc2\xb7 main\n\n' "$1" > "$FM_TB_SCREEN"; export FM_TB_CURSOR_Y=1; }
tb_screen ''
echo "  rendered pane:"; sed 's/^/    | /' "$FM_TB_SCREEN"
echo "  -> composer_state = $(fm_backend_thurbox_composer_state "$TARGET" fm-demo1)   (safe to send)"
tb_screen 'ship it, captain'
echo "  rendered pane after an Enter that did not land:"; sed 's/^/    | /' "$FM_TB_SCREEN"
echo "  -> composer_state = $(fm_backend_thurbox_composer_state "$TARGET" fm-demo1) (text still unsubmitted)"
cmds

hr "7b. the Cursor Agent hazard: cursor parked past the footer, reclassified"
printf '\n  \xe2\x86\x92 \033[2mPlan, search, build anything\033[0m\n\n  Cursor Grok 4.5 High                    Run Everything\n  /w \xc2\xb7 main\n\n' > "$FM_TB_SCREEN"
export FM_TB_CURSOR_Y=6 FM_TB_PANE_TTY=/dev/pts/9
printf 'pts/9\t4242\t4242\t4242\tcursor-agent\t/opt/cursor/cursor-agent\n' > "$TMP_ROOT/ps.tsv"
export FM_TB_PS="$TMP_ROOT/ps.tsv"
echo "  foreground process is cursor-agent, cursor row 6 (past the footer)"
echo "  -> composer_state = $(fm_backend_thurbox_composer_state "$TARGET" fm-demo1)   (ghost placeholder, not typed text)"
printf 'pts/9\t4242\t4242\t4242\tbash\t/bin/bash\n' > "$TMP_ROOT/ps.tsv"
echo "  same screen, foreground process is a plain shell (Cursor exited)"
echo "  -> composer_state = $(fm_backend_thurbox_composer_state "$TARGET" fm-demo1) (never 'empty': typing here would run a shell command)"
unset FM_TB_PS FM_TB_PANE_TTY
cmds

hr "8. busy classification from thurbox's own hook_state (herdr's exact vocabulary)"
for st in - working blocked done idle; do
  sed -i "s/\t[^\t]*$/\t$st/" "$FM_TB_ROWS"
  printf '  hook_state=%-8s -> busy_state %s\n' "$( [ "$st" = - ] && echo null || echo "$st" )" "$(fm_backend_thurbox_busy_state "$TARGET" fm-demo1)"
done
cmds

hr "9. the fleet view: list_live is scoped to this firstmate home"
sed -i "s/\t[^\t]*$/\t-/" "$FM_TB_ROWS"
printf '%s\t%s\t%s\t%s\t%s\n' 22222222-2222-2222-2222-222222222222 someone-elses-session %25 local-tmux - >> "$FM_TB_ROWS"
export FM_TB_PANES="%24 %25"
echo "  sessions in thurbox's database:"; sed 's/^/    /' "$FM_TB_ROWS"
echo "  fm_backend_thurbox_list_live ->"; fm_backend_thurbox_list_live | sed 's/^/    /'
cmds

hr "10. teardown: fm-teardown.sh reclaims the window headlessly (--force)"
fm_backend_thurbox_kill "$TARGET" '' fm-demo1 && echo "  kill rc=0"
echo "  sessions remaining:"; sed 's/^/    /' "$FM_TB_ROWS"
cmds
