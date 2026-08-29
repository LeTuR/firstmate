#!/usr/bin/env bash
# Measures the review-round fix at bin/backends/thurbox.sh:211 (fm_backend_thurbox_tmux):
# the socket memo used to be read through a command substitution, so its cache
# assignment died in a subshell and every pane primitive re-ran
# `thurbox-cli version --json` + jq. Counts that CLI call for ONE cold
# composer_state read, with the current wrapper and with the pre-fix one.
set -u
ROOT=$1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tb-memo.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
. "$ROOT/tests/thurbox-test-safety.sh"
eval "$(sed -n '43,234p' "$ROOT/tests/fm-backend-thurbox.test.sh")"
FM_TB_REAL_PS=$(command -v ps); export FM_TB_REAL_PS
FAKEBIN=$(make_thurbox_fakebin "$TMP")
export FM_THURBOX_BIN="$FAKEBIN/thurbox-cli"; PATH="$FAKEBIN:$PATH"; export PATH
thurbox_refuse_if_unsafe "$TMP" || exit 1

# The pre-fix wrapper, restored verbatim into a copy of the adapter.
mkdir -p "$TMP/prefix/bin/backends"
cp -r "$ROOT/bin/." "$TMP/prefix/bin/"
python3 - "$TMP/prefix/bin/backends/thurbox.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
new='  fm_backend_thurbox_socket >/dev/null || return 1\n  tmux -L "$FM_BACKEND_THURBOX_SOCKET_CACHE" "$@"\n'
old='  local sock\n  sock=$(fm_backend_thurbox_socket) || return 1\n  tmux -L "$sock" "$@"\n'
assert new in s, "current wrapper shape not found"
open(p,'w').write(s.replace(new,old))
PY

run() {  # <adapter-root> <label>
  local root=$1
  : > "$TMP/log"; : > "$TMP/tmuxlog"
  printf '0b797791-3590-41c5-9918-21e38d1a54d4\t%s\t%%24\tlocal-tmux\t-\n' "$TITLE" > "$TMP/rows.tsv"
  printf '\n  \xe2\x86\x92 ship it\n\n  Claude Sonnet 4.5   Run Everything\n  /w \xc2\xb7 main\n\n' > "$TMP/screen"
  local verdict
  verdict=$(env FM_TB_ROWS="$TMP/rows.tsv" FM_TB_LOG="$TMP/log" FM_TB_TMUXLOG="$TMP/tmuxlog" \
      FM_TB_SCREEN="$TMP/screen" FM_TB_PANES='%24' FM_TB_CURSOR_Y=1 \
      FM_ROOT_OVERRIDE="$TMP/home" FM_HOME="$TMP/home" FM_CONFIG_OVERRIDE="$TMP/home/config" \
    bash -c '. "$1/backends/thurbox.sh"; fm_backend_thurbox_composer_state 0b797791-3590-41c5-9918-21e38d1a54d4:%24 fm-x' _ "$root")
  printf '  %-18s verdict=%-8s thurbox-cli processes spawned: %-3s (of which `version --json`: %s)   tmux pane primitives: %s\n' \
    "$2" "$verdict" "$(wc -l < "$TMP/log")" "$(grep -c $'\x1fversion' "$TMP/log")" "$(wc -l < "$TMP/tmuxlog")"
}
mkdir -p "$TMP/home/config"
TITLE=$(env FM_ROOT_OVERRIDE="$TMP/home" FM_HOME="$TMP/home" FM_CONFIG_OVERRIDE="$TMP/home/config" bash -c '. "$1/backends/thurbox.sh"; fm_backend_thurbox_scoped_title fm-x' _ "$ROOT/bin")
echo "one cold fm_backend_thurbox_composer_state read (the watcher's per-poll, per-Enter hot path):"
run "$TMP/prefix/bin" "pre-fix wrapper"
run "$ROOT/bin"       "current wrapper"
