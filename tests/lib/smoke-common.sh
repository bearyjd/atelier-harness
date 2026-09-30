# shellcheck shell=bash
# SC2034: ENTER_EXIT/ENTER_OUT etc. are read by the suites that source this.
# shellcheck disable=SC2034
# tests/lib/smoke-common.sh -- SOURCED by tests/smoke-enter.sh,
# tests/smoke-enter-tmux.sh and tests/smoke-enter-pty.sh, never executed.
#
# Split out 2026-09-30, when smoke-enter.sh hit the 800-line cap and its
# tmux and pty checks moved to their own files: the result helpers and
# run_enter are shared, so all three suites count and report identically. Sets no shell
# options; callers keep their own `set -euo pipefail`.
#
# CLEANUP CONTRACT (review finding, 2026-09-30): a suite arms its EXIT
# trap only AFTER its preconditions pass. `abort` before that point exits
# without running any cleanup -- an earlier version armed the trap first,
# so the "refusing to run over a live agent-example" precondition fired
# and the trap then `rm -f`'d that very live container (reproduced with a
# dummy agent-example).

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

print_summary() {
  echo
  echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped =="
}

# A failed precondition: report it and stop with exit 2 -- distinct from
# an ordinary test failure (1), so `just smoke-enter` can tell "this suite
# REFUSED to run" (e.g. over a live agent-example session) apart and not
# start the next suite on the same proxy. Runs no cleanup of its own; see
# the CLEANUP CONTRACT above.
abort() {
  fail "$1"
  print_summary
  exit 2
}

finish() {
  print_summary
  [[ "$FAIL_COUNT" -gt 0 ]] && exit 1
  exit 0
}

# M6/M3: the single entry point every check uses to run agent-enter.sh
# ($ENTER, set by the caller). Never masks a failure: ENTER_EXIT is always
# the real exit code, ENTER_OUT is always the real combined output, and
# nothing here can trigger `set -e` regardless of what agent-enter.sh does.
run_enter() {
  ENTER_EXIT=0
  ENTER_OUT="$("$ENTER" "$@" 2>&1)" || ENTER_EXIT=$?
}
