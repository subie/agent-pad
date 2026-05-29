#!/usr/bin/env bash
# run-tests.sh — run the agent-pad test suite (ERT + shell wrapper tests).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"

echo "== ERT (elisp) tests =="
emacs -Q --batch -l "$DIR/agent-pad-test.el" -f ert-run-tests-batch-and-exit

echo ""
echo "== shell (eval wrapper) tests =="
bash "$DIR/eval-wrapper-test.sh"

echo ""
echo "All test suites passed."
