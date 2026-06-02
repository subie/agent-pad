#!/usr/bin/env bash
# eval-wrapper-test.sh — verify the agent-start eval mechanism preserves
# quoting, multi-line content, and command substitution without re-evaluating
# shell metacharacters from the prompt.  Mirrors the core wrapper line
# `eval "$(cat "$cmdfile")"` from bin/agent-start, independent of tmux.
set -euo pipefail

fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    echo "       expected: [$expected]"
    echo "       actual:   [$actual]"
    fail=1
  fi
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# 1. A copilot-style command using "$(cat <promptfile>)" substitution where
#    the prompt contains shell metacharacters that must stay inert.
promptfile="$tmpdir/prompt"
printf 'Line one\nLine two with $HOME & `whoami`' > "$promptfile"
cmdfile="$tmpdir/cmd"
printf 'printf "%%s" "$(cat %q)"' "$promptfile" > "$cmdfile"
out=$(eval "$(cat "$cmdfile")")
expected=$(cat "$promptfile")
check "prompt substitution keeps metacharacters literal" "$expected" "$out"

# 2. Quoting with embedded spaces is preserved (single argument).
cmdfile2="$tmpdir/cmd2"
printf 'printf "[%%s]" "a  b   c"' > "$cmdfile2"
out2=$(eval "$(cat "$cmdfile2")")
check "embedded multi-space quoting preserved" "[a  b   c]" "$out2"

# 3. Exit code propagates (wrapper relies on $? to signal done/blocked).
cmdfile3="$tmpdir/cmd3"
printf 'exit 7' > "$cmdfile3"
set +e
( eval "$(cat "$cmdfile3")" )
code=$?
set -e
check "exit code propagates through eval" "7" "$code"

# 4. Window-id discovery resolves the wrapper's OWN window via $TMUX_PANE,
#    not the active client's window.  This is the regression guard for the
#    "RET jumps to the last/active window" bug: a bare `tmux display` reports
#    the active client's window, so launching while another window is focused
#    records the wrong id.  Requires a tmux server; skipped otherwise.
if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
  sess="agentpad-widtest-$$"
  tmux new-session -d -s "$sess" -x 80 -y 24 'sleep 30'
  # Make a *second* window active so a bare display would return the wrong id.
  tmux new-window -t "$sess" 'sleep 30'
  outfile="$tmpdir/widout"
  # Discovery snippet mirrors bin/agent-start.
  read -r -d '' snippet <<'SNIP' || true
_AQ_WID=$(tmux display -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null || true)
[[ -n "$_AQ_WID" ]] || _AQ_WID=$(tmux display -p '#{window_id}' 2>/dev/null || true)
printf '%s' "$_AQ_WID" > OUTFILE_PLACEHOLDER
SNIP
  snippet=${snippet//OUTFILE_PLACEHOLDER/$outfile}
  snipfile="$tmpdir/snip.sh"
  printf '%s' "$snippet" > "$snipfile"
  # Launch the snippet in its own NEW window and capture that window's real id.
  realwid=$(tmux new-window -t "$sess" -P -F '#{window_id}' "bash '$snipfile'")
  sleep 0.5
  discovered=$(cat "$outfile" 2>/dev/null || true)
  check "window-id discovery resolves own window via TMUX_PANE" "$realwid" "$discovered"
  tmux kill-session -t "$sess" 2>/dev/null || true
else
  echo "skip - window-id discovery test (no tmux server)"
fi

# 5. agent_rename_window prefers an explicit window id over the stored one.
#    Regression guard for "windows rewritten with the wrong task name": when
#    the wrapper passes its authoritative pane-derived id, the rename must
#    target THAT window, never a stale/wrong id in the state file.  Uses a
#    fake `tmux` on PATH to capture the rename target; no tmux server needed.
lib="$(cd "$(dirname "$0")/.." && pwd)/bin/agent-lib.sh"
fakebin="$tmpdir/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/tmux" <<FAKE
#!/usr/bin/env bash
# Record only rename-window invocations: "<target>|<name>".
if [[ "\$1" == "rename-window" ]]; then
  # args: rename-window -t <target> <name>
  printf '%s|%s\n' "\$3" "\$4" >> "$tmpdir/rename.log"
fi
exit 0
FAKE
chmod +x "$fakebin/tmux"
: > "$tmpdir/rename.log"
(
  export AGENT_STATE_DIR="$tmpdir/state"
  mkdir -p "$AGENT_STATE_DIR"
  # Stored id is deliberately WRONG (@99) to prove it is not used.
  printf 'running|mytask|0||@99' > "$AGENT_STATE_DIR/mytask"
  PATH="$fakebin:$PATH"
  source "$lib"
  agent_rename_window "mytask" "done" "@42"
)
rename_line=$(cat "$tmpdir/rename.log")
check "agent_rename_window targets explicit id, not stored id" "@42|✓  mytask" "$rename_line"

# 6. agent_rename_window falls back to the stored id when none is supplied.
: > "$tmpdir/rename.log"
(
  export AGENT_STATE_DIR="$tmpdir/state"
  PATH="$fakebin:$PATH"
  source "$lib"
  agent_rename_window "mytask" "blocked"
)
rename_line2=$(cat "$tmpdir/rename.log")
check "agent_rename_window falls back to stored id" "@99|🔴 mytask" "$rename_line2"

exit $fail
