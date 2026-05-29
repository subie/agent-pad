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

exit $fail
