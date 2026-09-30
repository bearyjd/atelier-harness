#!/usr/bin/env bash
# Smoke test for how scripts/agent-enter.sh --no-tmux hands over the
# caller's stdin/stdout (its STDIN RULE and enter_no_tmux). Split out of
# tests/smoke-enter.sh on 2026-09-30 (that file had hit the 800-line cap);
# `just smoke-enter` runs it after the other two agent-enter suites.
#
# Background (same root cause as tests/smoke.sh 4d): inside the `dev`
# distrobox, distrobox-host-exec gives host-spawn a pty whenever stdout is
# a TTY, and in that mode it echoes piped stdin and SWALLOWS it, even in a
# podman call that never reads stdin; the final `podman exec -i` then
# never sees EOF. Until 2026-09-30, `printf canary | agent-enter.sh
# --no-tmux -- cat` under a pty printed the canary once (echoed by a
# preflight inspect) and hung until timeout (124).
#
# Isolation: scratch project names ($$), THROWAWAY auth volumes (the
# ATELIER_AUTH_VOLUME_* overrides -- never the real atelier-auth-*), and a
# claude secret name that never exists. Cleanup is armed only after the
# preconditions pass (tests/lib/smoke-common.sh CLEANUP CONTRACT).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENTER="${REPO_ROOT}/scripts/agent-enter.sh"
# shellcheck source=tests/lib/smoke-common.sh
source "${SCRIPT_DIR}/lib/smoke-common.sh"
# Only for resolve_podman (the same routing agent-enter.sh uses).
# shellcheck source=scripts/lib/atelier-common.sh
source "${REPO_ROOT}/scripts/lib/atelier-common.sh"
resolve_podman
EGRESS_CONTAINER="${ATELIER_EGRESS_HOST:-atelier-egress}"

EXEC_PROJECT="smoke-exec-$$"
PTY_NONE_PROJECT="smoke-pty-none-$$"
PTY_PROXIED_PROJECT="smoke-pty-proxied-$$"
export ATELIER_CLAUDE_SECRET="atelier-claude-token-smoke-pty-absent-$$"
export ATELIER_AUTH_VOLUME_CLAUDE="atelier-smoke-pty-claude-$$"
export ATELIER_AUTH_VOLUME_CODEX="atelier-smoke-pty-codex-$$"
export ATELIER_AUTH_VOLUME_GH="atelier-smoke-pty-gh-$$"

cleanup() {
  local p v
  for p in "$EXEC_PROJECT" "$PTY_NONE_PROJECT" "$PTY_PROXIED_PROJECT"; do
    "${PODMAN[@]}" rm -f "agent-${p}" >/dev/null 2>&1 || true
  done
  for v in "$ATELIER_AUTH_VOLUME_CLAUDE" "$ATELIER_AUTH_VOLUME_CODEX" "$ATELIER_AUTH_VOLUME_GH"; do
    "${PODMAN[@]}" volume rm -f "$v" >/dev/null 2>&1 || true
  done
  rm -rf "$WORKDIR"
}

echo "== agent-enter.sh stdin/pty smoke test =="
echo "podman: ${PODMAN[*]}"
echo

# --- 0. Preconditions ------------------------------------------------------
if ! "${PODMAN[@]}" image exists agent-base:latest 2>/dev/null; then
  abort "image agent-base:latest exists locally (build it first: 'just build-base')"
fi
if [[ "$("${PODMAN[@]}" inspect "$EGRESS_CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" != "true" ]]; then
  abort "${EGRESS_CONTAINER} is running (it is not -- run 'just egress-up' first)"
fi
pass "agent-base:latest exists and ${EGRESS_CONTAINER} is running"

WORKDIR="$(mktemp -d)"
mkdir -p "${WORKDIR}/exec" "${WORKDIR}/pty-none" "${WORKDIR}/pty-proxied"
trap cleanup EXIT

# --- 1. Outside the trigger case the script execs: its PID becomes podman --
# enter_no_tmux pipes through `| cat` ONLY for stdin-piped + stdout-a-TTY
# (security review, 2026-09-30): anywhere else it must `exec`, so a
# caller's signal to the PID it started reaches podman, not a bash that
# would die and orphan the pipeline. stdin and stdout are both non-TTY
# here. setsid makes the job its own process group, so the whole group can
# be killed afterwards whichever way it went. Needs no distrobox.
setsid "$ENTER" --project "$EXEC_PROJECT" --dir "${WORKDIR}/exec" --network none --no-tmux \
  -- sleep 60 </dev/null >"${WORKDIR}/exec.out" 2>&1 &
EXEC_PID=$!
EXEC_CMDLINE=""
for _ in $(seq 1 120); do
  EXEC_CMDLINE="$(tr '\0' ' ' <"/proc/${EXEC_PID}/cmdline" 2>/dev/null)" || break
  [[ -n "$EXEC_CMDLINE" && "$EXEC_CMDLINE" != *agent-enter.sh* ]] && break
  sleep 0.5
done
if [[ -n "$EXEC_CMDLINE" && "$EXEC_CMDLINE" != *agent-enter.sh* && "$EXEC_CMDLINE" == *exec* ]]; then
  pass "--no-tmux with stdin and stdout not a TTY execs: the PID becomes the podman exec (${EXEC_CMDLINE:0:60}...)"
else
  fail "--no-tmux with stdin and stdout not a TTY execs: the PID becomes the podman exec (last cmdline: ${EXEC_CMDLINE:-<gone>}; output: $(tail -3 "${WORKDIR}/exec.out"))"
fi
kill -TERM -- "-${EXEC_PID}" >/dev/null 2>&1 || true
wait "$EXEC_PID" 2>/dev/null || true

# --- 2-4. Piped stdin under a real pty: delivered exactly once, exit code --
# `tr` tells the command's own output (uppercase) from a pty echo (which
# stays lowercase): the canary must appear uppercase exactly once and
# never lowercase. The command exits 42 through the `| cat` path, which
# must come back as agent-enter.sh's exit code. printf %q builds the
# `script -c` line; SHELL=/bin/bash makes script run it under bash.
PTY_EXIT=0
PTY_OUT=""
run_pty_canary() {
  local project="$1" dir="$2" network="$3" cmd
  cmd="printf 'stdincanary\\n' | $(printf '%q ' "$ENTER" --project "$project" --dir "$dir" \
    --network "$network" --no-tmux -- sh -c 'tr a-z A-Z; exit 42')"
  PTY_EXIT=0
  PTY_OUT="$(SHELL=/bin/bash timeout 90 script -qefc "$cmd" /dev/null </dev/null 2>&1)" || PTY_EXIT=$?
}

check_pty_canary() {
  local label="piped stdin under a pty, $1: reaches the command exactly once (not swallowed, not echoed), exit 42 propagates"
  if [[ "$PTY_EXIT" -eq 42 && "$(grep -c STDINCANARY <<<"$PTY_OUT")" -eq 1 && "$PTY_OUT" != *stdincanary* ]]; then
    pass "$label"
  else
    fail "${label} (exit=${PTY_EXIT}$([[ "$PTY_EXIT" -eq 124 ]] && echo ' = TIMED OUT'): ${PTY_OUT})"
  fi
}

# Outside a distrobox there is no host-spawn hop, so these would pass
# trivially -- reported as SKIP, never as a PASS that proves nothing.
if [[ "${PODMAN[0]}" != "distrobox-host-exec" ]]; then
  skip "piped stdin under a pty (x3): podman is '${PODMAN[*]}', not distrobox-host-exec -- the pty hop under test does not exist here"
else
  run_pty_canary "$PTY_NONE_PROJECT" "${WORKDIR}/pty-none" none
  check_pty_canary "create path, --network none"
  run_pty_canary "$PTY_NONE_PROJECT" "${WORKDIR}/pty-none" none
  check_pty_canary "reuse path, --network none"
  run_pty_canary "$PTY_PROXIED_PROJECT" "${WORKDIR}/pty-proxied" proxied
  check_pty_canary "create path, --network proxied"
fi

finish
