#!/usr/bin/env bash
# Smoke test for scripts/agent-enter.sh's tmux layer: session creation and
# reuse (with pane-command verification), H4 dotted project names, and H6
# recreation of a container removed behind a live session. Split out of
# tests/smoke-enter.sh on 2026-09-30 (that file had hit the 800-line cap);
# `just smoke-enter` runs it after the container-layer suite. The design
# rules in smoke-enter.sh's header (M3/M6/M7, L2/L3) apply here unchanged.
#
# Headless throughout: a private tmux socket (`tmux -L atelier-test-tmux`,
# via agent-enter.sh's ATELIER_TMUX override) never touches the
# operator's real tmux server, and every project name is a scratch one
# ($$-suffixed), so this suite never needs agent-example. Cleanup is armed
# only after the preconditions pass (tests/lib/smoke-common.sh).
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

TMUX_SOCKET="atelier-test-tmux"
TMUX_CMD=(tmux -L "$TMUX_SOCKET")
TMUX_PROJECT="smoke-tmux-$$"
CONTAINER="agent-${TMUX_PROJECT}"
SESSION="agent-${TMUX_PROJECT}"
DOTTED_PROJECT="smoke.dot-$$"
H6_PROJECT="smoke-h6-$$"
# Section 2 uses the default (proxied) profile: a throwaway secret name
# that never exists, so the real atelier-claude-token is never injected.
export ATELIER_CLAUDE_SECRET="atelier-claude-token-smoke-tmux-absent-$$"

cleanup() {
  "${TMUX_CMD[@]}" kill-server >/dev/null 2>&1 || true
  rm -f "/tmp/tmux-$(id -u)/${TMUX_SOCKET}" 2>/dev/null || true
  local p
  for p in "$TMUX_PROJECT" "$DOTTED_PROJECT" "$H6_PROJECT"; do
    "${PODMAN[@]}" rm -f "agent-${p}" >/dev/null 2>&1 || true
  done
  rm -rf "$WORKDIR"
}

echo "== agent-enter.sh tmux-layer smoke test =="
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
PROJECT_DIR="${WORKDIR}/project-$$"
mkdir -p "$PROJECT_DIR"
trap cleanup EXIT

# --- 1. H4: a dotted project name round-trips through the tmux layer ------
"${TMUX_CMD[@]}" kill-server >/dev/null 2>&1 || true
DOTTED_DIR="${WORKDIR}/dotted-project"
mkdir -p "$DOTTED_DIR"
DOTTED_SESSION="agent-${DOTTED_PROJECT}"
ATELIER_TMUX="${TMUX_CMD[*]}" "$ENTER" --project "$DOTTED_PROJECT" --dir "$DOTTED_DIR" --network none </dev/null >/dev/null 2>&1 &
DOTTED_PID=$!
for _ in $(seq 1 20); do
  "${TMUX_CMD[@]}" has-session -t "${DOTTED_SESSION}:" 2>/dev/null && break
  sleep 0.5
done
if "${TMUX_CMD[@]}" has-session -t "${DOTTED_SESSION}:" 2>/dev/null; then
  pass "H4: a dotted project name (${DOTTED_PROJECT}) creates a tmux session findable by has-session"
else
  fail "H4: a dotted project name creates a tmux session findable by has-session"
fi
kill "$DOTTED_PID" >/dev/null 2>&1 || true
wait "$DOTTED_PID" 2>/dev/null || true

SESSIONS_BEFORE="$("${TMUX_CMD[@]}" list-sessions -F '#{session_name}' 2>/dev/null | grep -c "^${DOTTED_SESSION}\$" || true)"
ATELIER_TMUX="${TMUX_CMD[*]}" timeout 5 "$ENTER" --project "$DOTTED_PROJECT" --dir "$DOTTED_DIR" --network none </dev/null >/dev/null 2>&1 || true
SESSIONS_AFTER="$("${TMUX_CMD[@]}" list-sessions -F '#{session_name}' 2>/dev/null | grep -c "^${DOTTED_SESSION}\$" || true)"
if [[ "$SESSIONS_BEFORE" -eq 1 && "$SESSIONS_AFTER" -eq 1 ]]; then
  pass "H4: a second invocation with a dotted project name reuses the session, not 'duplicate session'"
else
  fail "H4: a second invocation with a dotted project name reuses the session (before=${SESSIONS_BEFORE} after=${SESSIONS_AFTER})"
fi
"${PODMAN[@]}" rm -f "agent-${DOTTED_PROJECT}" >/dev/null 2>&1 || true

# --- 2. tmux layer on a scratch project: session creation, reuse with pane-
#         command verification (M3: a failed second invocation that still
#         leaves the session count at 1 must not be reported as a pass). -
"${TMUX_CMD[@]}" kill-server >/dev/null 2>&1 || true
ATELIER_TMUX="${TMUX_CMD[*]}" "$ENTER" --project "$TMUX_PROJECT" --dir "$PROJECT_DIR" </dev/null >/dev/null 2>&1 &
FIRST_PID=$!
for _ in $(seq 1 20); do
  "${TMUX_CMD[@]}" has-session -t "${SESSION}:" 2>/dev/null && break
  sleep 0.5
done
if "${TMUX_CMD[@]}" has-session -t "${SESSION}:" 2>/dev/null; then
  pass "tmux layer creates a session named ${SESSION}"
else
  fail "tmux layer creates a session named ${SESSION}"
fi
kill "$FIRST_PID" >/dev/null 2>&1 || true
wait "$FIRST_PID" 2>/dev/null || true

# The pane's own process must still name the podman exec into this
# container -- proves the session is genuinely attached to the right
# thing, not just present under the right name.
PANE_NAMES_EXEC=0
PANE_PID="$("${TMUX_CMD[@]}" list-panes -t "${SESSION}:" -F '#{pane_pid}' 2>/dev/null)" || PANE_PID=""
if [[ -n "$PANE_PID" ]]; then
  PANE_ARGS="$(ps -o args= -p "$PANE_PID" 2>/dev/null)" || PANE_ARGS=""
  [[ "$PANE_ARGS" == *exec* && "$PANE_ARGS" == *"$CONTAINER"* ]] && PANE_NAMES_EXEC=1
fi
if [[ "$PANE_NAMES_EXEC" -eq 1 ]]; then
  pass "tmux session's pane command names the podman exec into ${CONTAINER}"
else
  fail "tmux session's pane command names the podman exec into ${CONTAINER} (pane_pid=${PANE_PID:-<none>}, args=${PANE_ARGS:-<none>})"
fi

SESSIONS_BEFORE2="$("${TMUX_CMD[@]}" list-sessions -F '#{session_name}' 2>/dev/null | grep -c "^${SESSION}\$" || true)"
SECOND_OUT="$(ATELIER_TMUX="${TMUX_CMD[*]}" timeout 5 "$ENTER" --project "$TMUX_PROJECT" --dir "$PROJECT_DIR" </dev/null 2>&1)" || SECOND_EXIT=$?
SESSIONS_AFTER2="$("${TMUX_CMD[@]}" list-sessions -F '#{session_name}' 2>/dev/null | grep -c "^${SESSION}\$" || true)"
# Headless, no controlling terminal: the second invocation cannot actually
# attach. Its only acceptable outcomes are the two documented in the
# review ("no current client" via switch-client if TMUX is set in this
# shell, or "not a terminal" via attach if not) -- anything else (a
# duplicate-session error, a crash) is a real failure, not an artifact of
# the test environment.
if [[ "$SESSIONS_BEFORE2" -eq 1 && "$SESSIONS_AFTER2" -eq 1 \
      && "${SECOND_EXIT:-0}" -eq 1 \
      && ( "$SECOND_OUT" == *"no current client"* || "$SECOND_OUT" == *"not a terminal"* ) ]]; then
  pass "a second invocation attaches to the existing tmux session (headless outcome: no current client / not a terminal), not a duplicate session"
else
  fail "a second invocation attaches to the existing tmux session, not a duplicate session (before=${SESSIONS_BEFORE2} after=${SESSIONS_AFTER2} exit=${SECOND_EXIT:-0}: ${SECOND_OUT})"
fi
unset SECOND_EXIT

# --- 3. H6: a container removed behind a live session is recreated before
#         the next attach, not silently attached to a dead pane. ---------
"${TMUX_CMD[@]}" kill-server >/dev/null 2>&1 || true
"${PODMAN[@]}" rm -f "agent-${H6_PROJECT}" >/dev/null 2>&1 || true
H6_DIR="${WORKDIR}/h6-project"
mkdir -p "$H6_DIR"
ATELIER_TMUX="${TMUX_CMD[*]}" "$ENTER" --project "$H6_PROJECT" --dir "$H6_DIR" --network none </dev/null >/dev/null 2>&1 &
H6_PID=$!
for _ in $(seq 1 20); do
  "${PODMAN[@]}" container exists "agent-${H6_PROJECT}" 2>/dev/null && break
  sleep 0.5
done
kill "$H6_PID" >/dev/null 2>&1 || true
wait "$H6_PID" 2>/dev/null || true

if "${PODMAN[@]}" container exists "agent-${H6_PROJECT}" 2>/dev/null; then
  "${PODMAN[@]}" rm -f "agent-${H6_PROJECT}" >/dev/null
  H6_CONTAINER_GONE=1
else
  H6_CONTAINER_GONE=0
fi

if [[ "$H6_CONTAINER_GONE" -eq 1 ]]; then
  ATELIER_TMUX="${TMUX_CMD[*]}" timeout 5 "$ENTER" --project "$H6_PROJECT" --dir "$H6_DIR" --network none </dev/null >/dev/null 2>&1 || true
  if "${PODMAN[@]}" container exists "agent-${H6_PROJECT}" 2>/dev/null; then
    pass "H6: a container removed behind a live/dead session is recreated on the next tmux-path invocation"
  else
    fail "H6: a container removed behind a live/dead session is recreated on the next tmux-path invocation"
  fi
else
  fail "H6: setup could not remove the container to test recreation"
fi
"${PODMAN[@]}" rm -f "agent-${H6_PROJECT}" >/dev/null 2>&1 || true


finish
