#!/usr/bin/env bash
# Smoke test for scripts/agent-enter.sh: the tmux -> container -> shell
# state machine, the AUDIT.md §4.3 flag set, network profiles, staleness
# detection, --rebuild, and self-refusal (README.md "must never be
# /work"). Run with `just smoke-enter` or directly: tests/smoke-enter.sh
#
# REVISED after the Phase 2 code review (.omc/reviews/phase2-code-review.md)
# and Codex pass (.omc/reviews/phase2-codex.md). Design rules this version
# follows throughout, each tied to a finding:
#   - M6: no bare command under `set -e` that can kill the script silently.
#     Every `agent-enter.sh` invocation goes through run_enter(), which
#     captures output AND exit status without masking either, so a crash
#     always produces a FAIL line and the run always reaches the summary.
#   - M3: no assertion trusts output without first checking the exit code
#     that produced it (the "negative assertion that passes on any
#     failure" trap AUDIT.md §5 warns about).
#   - M4: never touches the real `agent-example` container or the real
#     `agent-example:latest` tag destructively. A live `agent-example`
#     container aborts the whole run before anything is touched. The
#     staleness simulation builds a SCRATCH overlay/tag, never the real
#     one.
#   - M1: the self-refusal content-check uses a throwaway copy of the
#     marker files, never this repository's own tree -- entering the real
#     tree, even to prove it's refused, SELinux-relabels it, and an
#     earlier version of this suite did exactly that (verified and fixed:
#     see the note at the bottom of this file).
#   - M7: every temp file this suite writes lives under $WORKDIR (mktemp),
#     which the trap removes; nothing is hardcoded under bare /tmp.
#   - L2/L3: no `A && pass || fail`; the private tmux socket file is
#     removed in cleanup.
#
# Non-interactive throughout: container-layer checks use --no-tmux (no TTY
# needed), and tmux-layer checks use a private tmux socket
# (`tmux -L atelier-test`, via agent-enter.sh's ATELIER_TMUX override) so
# this never touches the operator's real tmux server.
set -euo pipefail

if [[ -f /run/.containerenv ]] && command -v distrobox-host-exec >/dev/null 2>&1; then
  PODMAN=(distrobox-host-exec podman)
else
  PODMAN=(podman)
fi
if [[ -n "${ATELIER_PODMAN:-}" ]]; then
  # shellcheck disable=SC2206
  PODMAN=(${ATELIER_PODMAN})
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENTER="${REPO_ROOT}/scripts/agent-enter.sh"

# TEST_PROJECT is fixed at "example" -- it MUST match containers/example/
# (README.md "Overlay convention") so container/session naming and image
# resolution (agent-example:latest) actually exercise the overlay this
# suite is meant to check (jq, the union allow-list). M4: this suite reads
# and creates/removes the agent-example CONTAINER, but never mutates the
# agent-example:latest IMAGE tag -- the staleness simulation below uses a
# separate scratch overlay and tag instead.
TEST_PROJECT="example"
CONTAINER="agent-${TEST_PROJECT}"
SESSION="agent-${TEST_PROJECT}"
TMUX_SOCKET="atelier-test"
TMUX_CMD=(tmux -L "$TMUX_SOCKET")
PROBE_IP="1.1.1.1"
# Same env-var overrides agent-enter.sh itself honours, so a caller who
# points one at a nonstandard name points both consistently.
EGRESS_CONTAINER="${ATELIER_EGRESS_HOST:-atelier-egress}"
EGRESS_NETWORK="${ATELIER_EGRESS_NET:-atelier-internal}"

# Scratch identities, unique per run ($$), for tests that must not collide
# with TEST_PROJECT or with each other.
MISMATCH_PROJECT="smoke-mismatch-$$"
NONE_PROJECT="smoke-none-$$"
DOTTED_PROJECT="smoke.dot-$$"
H6_PROJECT="smoke-h6-$$"
STALE_PROJECT="smoke-stale-$$"
PREFLIGHT_PROJECT="smoke-preflight-$$"

PASS_COUNT=0
FAIL_COUNT=0
pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORKDIR="$(mktemp -d)"
PROJECT_DIR="${WORKDIR}/project-$$"
mkdir -p "$PROJECT_DIR"

cleanup() {
  "${TMUX_CMD[@]}" kill-server >/dev/null 2>&1 || true
  rm -f "/tmp/tmux-$(id -u)/${TMUX_SOCKET}" 2>/dev/null || true
  local p
  for p in "$TEST_PROJECT" "$MISMATCH_PROJECT" "$NONE_PROJECT" \
           "$DOTTED_PROJECT" "$H6_PROJECT" "$STALE_PROJECT" \
           "$PREFLIGHT_PROJECT" "fake-checkout" "atelier-harness"; do
    "${PODMAN[@]}" rm -f "agent-${p}" >/dev/null 2>&1 || true
  done
  # just build tags :latest AND :<YYYYMMDD> on every build (Justfile
  # build recipe) -- both must go, not just :latest, or the date tag
  # accumulates as a stray image across runs (found in testing: two
  # leftover agent-<scratch>:<date> images from earlier runs).
  "${PODMAN[@]}" images --format '{{.Repository}}:{{.Tag}}' \
    | grep "^localhost/agent-${STALE_PROJECT}:" \
    | xargs -r "${PODMAN[@]}" rmi -f >/dev/null 2>&1 || true
  rm -rf "${REPO_ROOT}/containers/${STALE_PROJECT}"
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# M6/M3: the single entry point every check below uses to run
# agent-enter.sh. Never masks a failure: ENTER_EXIT is always the real
# exit code, ENTER_OUT is always the real combined output, and nothing
# here can trigger `set -e` regardless of what agent-enter.sh does.
run_enter() {
  ENTER_EXIT=0
  ENTER_OUT="$("$ENTER" "$@" 2>&1)" || ENTER_EXIT=$?
}

echo "== agent-enter.sh smoke test =="
echo "podman: ${PODMAN[*]}"
echo "project dir: ${PROJECT_DIR}"
echo

# --- 0. Preconditions: don't run destructively over live operator state ---
if ! "${PODMAN[@]}" image exists agent-example:latest 2>/dev/null; then
  fail "image agent-example:latest exists locally (build it first: 'just build example')"
  echo; echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed =="
  exit 1
fi
pass "image agent-example:latest exists locally"

# B (code reviewer): preflight the proxy itself, not just the image --
# most of this suite's coverage defaults to the proxied network profile,
# so a down or DNS-broken proxy would otherwise surface many turns later
# as a pile of unrelated-looking container-creation failures instead of
# one clear line up front.
if ! "${PODMAN[@]}" inspect "$EGRESS_CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
  fail "${EGRESS_CONTAINER} is running (it is not -- run 'just egress-up' first)"
  echo; echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed =="
  exit 1
fi
if ! "${PODMAN[@]}" exec "$EGRESS_CONTAINER" getent hosts api.github.com >/dev/null 2>&1; then
  fail "${EGRESS_CONTAINER} resolves a public hostname (it does not -- DNS is broken inside the proxy; run 'just egress-up' to reconverge)"
  echo; echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed =="
  exit 1
fi
pass "${EGRESS_CONTAINER} is running and resolves a public hostname"

# M4: refuse to run at all over a live operator session named agent-example
# -- this suite creates/removes that container, so it must not exist yet.
if "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null; then
  fail "no pre-existing ${CONTAINER} container (found one -- refusing to run: this suite creates and removes it, which would destroy a live session)"
  echo; echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed =="
  exit 1
fi
pass "no pre-existing ${CONTAINER} container"

# --- 1. Self-refusal: string-identity, filesystem-identity, and content --
run_enter --dir "$REPO_ROOT" --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 3 ]]; then
  pass "self-refusal: --dir \$REPO_ROOT is refused (exit 3)"
else
  fail "self-refusal: --dir \$REPO_ROOT is refused (exit 3) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi

# C1: the same repository is reachable through a second canonical path on
# this host (verified: identical device+inode). A string comparison of
# two realpath'd paths misses this; the fix compares by filesystem
# identity. Only run if the alias actually exists here.
ALT_REPO_PATH=""
if [[ "$REPO_ROOT" == /var/home/* ]]; then
  ALT_REPO_PATH="${REPO_ROOT#/var}"
elif [[ "$REPO_ROOT" == /home/* ]]; then
  ALT_REPO_PATH="/var${REPO_ROOT}"
fi
if [[ -n "$ALT_REPO_PATH" && -d "$ALT_REPO_PATH" ]]; then
  run_enter --dir "$ALT_REPO_PATH" --no-tmux -- true
  if [[ "$ENTER_EXIT" -eq 3 ]]; then
    pass "self-refusal: the repo's alternate canonical path (${ALT_REPO_PATH}) is refused by filesystem identity (exit 3)"
  else
    fail "self-refusal: the repo's alternate canonical path is refused (exit 3) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
  fi
else
  echo "NOTE: no alternate canonical path to \$REPO_ROOT found on this host; skipping that self-refusal variant"
fi

# A symlinked parent pointing at the repo -- realpath alone would resolve
# through it fine, but the point is to exercise the same is_within_repo
# device+inode walk from a different starting string.
SYMLINK_PARENT="${WORKDIR}/repo-symlink"
ln -s "$REPO_ROOT" "$SYMLINK_PARENT"
run_enter --dir "$SYMLINK_PARENT" --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 3 ]]; then
  pass "self-refusal: a symlinked parent pointing at the repo is refused (exit 3)"
else
  fail "self-refusal: a symlinked parent pointing at the repo is refused (exit 3) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi

# M1: content-based checkout detection, exercised against a THROWAWAY copy
# of just the two marker files -- never this repository's own tree. The
# original version of this check entered $REPO_ROOT itself for the
# --allow-self case, which SELinux-relabels it (:Z) even on a refused
# entry that never creates a container is fine, but --allow-self does
# create one; this replacement removes that risk entirely.
FAKE_CHECKOUT="${WORKDIR}/fake-checkout"
mkdir -p "${FAKE_CHECKOUT}/scripts" "${FAKE_CHECKOUT}/containers/agent-base"
: > "${FAKE_CHECKOUT}/scripts/source-sha.sh"
: > "${FAKE_CHECKOUT}/containers/agent-base/Containerfile"
run_enter --dir "$FAKE_CHECKOUT" --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 3 ]]; then
  pass "self-refusal: a throwaway copy of the marker files is refused by content (exit 3)"
else
  fail "self-refusal: a throwaway copy of the marker files is refused by content (exit 3) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi

run_enter --dir "$FAKE_CHECKOUT" --allow-self --network none --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 0 ]]; then
  pass "self-refusal: --allow-self permits the throwaway checkout copy"
else
  fail "self-refusal: --allow-self permits the throwaway checkout copy (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi
"${PODMAN[@]}" rm -f "agent-fake-checkout" >/dev/null 2>&1 || true

# M2/Codex HIGH: $HOME (and /, /etc, /usr, /var) must never be mountable
# as /work -- unconditional, no --allow-self override (that flag exists
# for "this is Atelier itself", not "mount my whole home directory").
run_enter --dir "$HOME" --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 3 ]]; then
  pass "dangerous-dir: --dir \$HOME is refused (exit 3), nothing created"
else
  fail "dangerous-dir: --dir \$HOME is refused (exit 3) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi
if "${PODMAN[@]}" container exists "agent-$(basename "$HOME")" 2>/dev/null; then
  fail "dangerous-dir: no container was created for \$HOME"
  "${PODMAN[@]}" rm -f "agent-$(basename "$HOME")" >/dev/null 2>&1 || true
else
  pass "dangerous-dir: no container was created for \$HOME"
fi

# --- 1b. An injection-shaped project name is refused, not executed ---------
# Codex review (.omc/reviews/phase1-codex.md): `just build 'z"; echo
# INJECTED >&2; #'` used to render as executable shell, because `just`
# interpolates its {{project}} parameter as raw text into the recipe body
# before bash ever parses it. Checks both layers that reject it: the
# Justfile recipe (quote()'d interpolation, validated via
# scripts/valid-project-name.sh) and agent-enter.sh's own
# sanitize_project_name (same script, no template-interpolation risk to
# begin with, but must still refuse the same shape of input).
#
# The rejection message legitimately echoes the invalid name back (for
# debuggability), which itself contains the substring "INJECTED" as
# quoted data -- a plain substring check would be a false positive either
# way. A REAL injection instead runs `echo INJECTED >&2` as a live
# command, printing INJECTED alone on its own line; grep -x for that
# exact standalone line distinguishes "rejected and echoed" from
# "executed".
INJECTION_PAYLOAD='z"; echo INJECTED >&2; #'
JUST_INJECT_OUT="$(cd "$REPO_ROOT" && just build "$INJECTION_PAYLOAD" 2>&1)" || JUST_INJECT_EXIT=$?
if [[ "${JUST_INJECT_EXIT:-0}" -ne 0 ]] && ! echo "$JUST_INJECT_OUT" | grep -qx 'INJECTED'; then
  pass "just build refuses an injection-shaped project name without executing it"
else
  fail "just build refuses an injection-shaped project name without executing it (exit=${JUST_INJECT_EXIT:-0}, got: ${JUST_INJECT_OUT})"
fi
unset JUST_INJECT_EXIT

run_enter --project "$INJECTION_PAYLOAD" --dir "$PROJECT_DIR" --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 2 ]] && ! echo "$ENTER_OUT" | grep -qx 'INJECTED'; then
  pass "agent-enter.sh refuses an injection-shaped project name (exit 2)"
else
  fail "agent-enter.sh refuses an injection-shaped project name (exit 2) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi

# --- 2. Container creation: flags, mounts, network, overlay tool -----------
run_enter --project "$TEST_PROJECT" --dir "$PROJECT_DIR" --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 0 ]] && "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null; then
  pass "container ${CONTAINER} was created"
else
  fail "container ${CONTAINER} was created (exit=${ENTER_EXIT}: ${ENTER_OUT})"
  echo; echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed =="
  exit 1
fi

CAPDROP="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.HostConfig.CapDrop}}')"
if [[ -n "$CAPDROP" && "$CAPDROP" != "[]" ]]; then
  CAPBND="$("${PODMAN[@]}" exec "$CONTAINER" grep CapBnd /proc/self/status | awk '{print $2}')"
  if [[ "$CAPBND" =~ ^0+$ ]]; then
    pass "CapDrop is set and effective CapBnd is all zeros (${CAPBND})"
  else
    fail "CapDrop is set and effective CapBnd is all zeros (got CapBnd=${CAPBND})"
  fi
else
  fail "CapDrop is set (got: '${CAPDROP}')"
fi

NNP="$("${PODMAN[@]}" exec "$CONTAINER" grep NoNewPrivs /proc/self/status | awk '{print $2}')"
if [[ "$NNP" == "1" ]]; then pass "NoNewPrivs is 1"; else fail "NoNewPrivs is 1 (got: ${NNP})"; fi

UIDMAP="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{json .HostConfig.IDMappings}}')"
CUID="$("${PODMAN[@]}" exec "$CONTAINER" id -u)"
if [[ "$UIDMAP" == *'"1000:0:1"'* && "$CUID" == "1000" ]]; then
  pass "userns keep-id: uid 1000 in container, IDMappings show the 1000:0:1 keep-id entry"
else
  fail "userns keep-id (got container uid=${CUID}, UidMap=${UIDMAP})"
fi

PIDSLIMIT="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.HostConfig.PidsLimit}}')"
if [[ "$PIDSLIMIT" == "2048" ]]; then pass "PidsLimit is 2048"; else fail "PidsLimit is 2048 (got: ${PIDSLIMIT})"; fi

INIT="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.HostConfig.Init}}')"
if [[ "$INIT" == "true" ]]; then pass "--init is set"; else fail "--init is set (got: ${INIT})"; fi

MOUNTS="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' | sort)"
EXPECTED_MOUNTS=$'/home/agent/.claude\n/home/agent/.codex\n/home/agent/.config/gh\n/work'
if [[ "$MOUNTS" == "$EXPECTED_MOUNTS" ]]; then
  pass "mounts are exactly /work plus the three auth volumes, nothing else"
else
  fail "mounts are exactly /work plus the three auth volumes, nothing else (got: $(echo "$MOUNTS" | tr '\n' ';'))"
fi

WORK_SOURCE="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}')"
if [[ "$WORK_SOURCE" == "$PROJECT_DIR" ]]; then
  pass "/work is bind-mounted from the requested --dir"
else
  fail "/work is bind-mounted from the requested --dir (got: ${WORK_SOURCE})"
fi

NET="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{json .NetworkSettings.Networks}}')"
if [[ "$NET" == *"\"${EGRESS_NETWORK}\""* ]]; then
  pass "network profile 'proxied' (default) joins ${EGRESS_NETWORK}"
else
  fail "network profile 'proxied' (default) joins ${EGRESS_NETWORK} (got: ${NET})"
fi

ENV_JSON="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{json .Config.Env}}')"
if [[ "$ENV_JSON" == *"HTTPS_PROXY=http://${EGRESS_CONTAINER}:3128"* && "$ENV_JSON" == *"https_proxy=http://${EGRESS_CONTAINER}:3128"* ]]; then
  pass "proxied profile sets HTTPS_PROXY/https_proxy to ${EGRESS_CONTAINER}:3128"
else
  fail "proxied profile sets HTTPS_PROXY/https_proxy to ${EGRESS_CONTAINER}:3128 (got: ${ENV_JSON})"
fi

# atelier-internal is created with --disable-dns (deterministic resolv.conf
# fix), so "atelier-egress" is no longer resolvable by DNS on that network
# -- agent-enter.sh maps it via --add-host instead. Assert the container
# can both resolve the name and actually reach the proxy through it.
if EGRESS_RESOLVE_OUT="$("${PODMAN[@]}" exec "$CONTAINER" getent hosts "$EGRESS_CONTAINER" 2>&1)"; then
  pass "the proxied container resolves ${EGRESS_CONTAINER} via --add-host (got: ${EGRESS_RESOLVE_OUT})"
else
  fail "the proxied container resolves ${EGRESS_CONTAINER} via --add-host (got: ${EGRESS_RESOLVE_OUT})"
fi
if PROXY_CODE="$("${PODMAN[@]}" exec "$CONTAINER" curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://api.github.com 2>&1)" \
   && [[ "$PROXY_CODE" =~ ^2[0-9][0-9]$ ]]; then
  pass "the proxied container reaches api.github.com through the proxy (HTTP ${PROXY_CODE})"
else
  fail "the proxied container reaches api.github.com through the proxy (got: ${PROXY_CODE:-<curl failed>})"
fi

if JQ_OUT="$("${PODMAN[@]}" exec "$CONTAINER" jq --version 2>&1)"; then
  if [[ "$JQ_OUT" == jq-* ]]; then
    pass "jq --version works (overlay tool present, got: ${JQ_OUT})"
  else
    fail "jq --version works (overlay tool present) (unexpected output: ${JQ_OUT})"
  fi
else
  fail "jq --version works (overlay tool present) (podman exec itself failed: ${JQ_OUT})"
fi

# --- 3. Second invocation reuses the container ------------------------------
ID1="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Id}}')"
run_enter --project "$TEST_PROJECT" --dir "$PROJECT_DIR" --no-tmux -- true
if [[ "$ENTER_EXIT" -ne 0 ]]; then
  fail "a second invocation reuses the same container (id unchanged) (the invocation itself failed: exit=${ENTER_EXIT}: ${ENTER_OUT})"
else
  ID2="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Id}}')"
  if [[ "$ID1" == "$ID2" ]]; then
    pass "a second invocation reuses the same container (id unchanged)"
  else
    fail "a second invocation reuses the same container (id changed: ${ID1} -> ${ID2})"
  fi
fi

# --- 4. Command after -- runs in the container, exit code propagates -------
# Both failure messages include ENTER_OUT (stderr+stdout combined): a
# mismatch here can come from agent-enter.sh itself (e.g. podman error
# 125 from resource contention) rather than the command's own exit code,
# and the earlier version of this assertion reported only the numbers,
# which made that indistinguishable from a real propagation bug.
run_enter --project "$TEST_PROJECT" --dir "$PROJECT_DIR" --no-tmux -- bash -c 'exit 0'
if [[ "$ENTER_EXIT" -eq 0 ]]; then
  pass "a command after -- that exits 0 propagates exit code 0"
else
  fail "a command after -- that exits 0 propagates exit code 0 (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi

run_enter --project "$TEST_PROJECT" --dir "$PROJECT_DIR" --no-tmux -- bash -c 'exit 42'
if [[ "$ENTER_EXIT" -eq 42 ]]; then
  pass "a command after -- that exits 42 propagates exit code 42"
else
  fail "a command after -- that exits 42 propagates exit code 42 (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi

# M8: a trailing command given without -- (parse_args falls through to the
# same COMMAND=("$@") capture as the -- branch).
run_enter --project "$TEST_PROJECT" --dir "$PROJECT_DIR" --no-tmux echo trailing-no-dashdash
if [[ "$ENTER_EXIT" -eq 0 && "$ENTER_OUT" == *trailing-no-dashdash* ]]; then
  pass "a trailing command without -- still runs in the container"
else
  fail "a trailing command without -- still runs in the container (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi

# --- 5. H1: --dir mismatch on an existing container is refused (exit 4) ----
MISMATCH_DIR1="${WORKDIR}/mismatch1"
MISMATCH_DIR2="${WORKDIR}/mismatch2"
mkdir -p "$MISMATCH_DIR1" "$MISMATCH_DIR2"
run_enter --project "$MISMATCH_PROJECT" --dir "$MISMATCH_DIR1" --network none --no-tmux -- true
if [[ "$ENTER_EXIT" -ne 0 ]]; then
  fail "H1: --dir mismatch on an existing container is refused (exit 4) (setup invocation failed: exit=${ENTER_EXIT}: ${ENTER_OUT})"
else
  run_enter --project "$MISMATCH_PROJECT" --dir "$MISMATCH_DIR2" --network none --no-tmux -- true
  if [[ "$ENTER_EXIT" -eq 4 ]]; then
    pass "H1: --dir mismatch on an existing container is refused (exit 4)"
  else
    fail "H1: --dir mismatch on an existing container is refused (exit 4) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
  fi
fi

# --- 6. H3: --network mismatch on an existing container is refused (exit 4) -
# Uses the real atelier-egress for the preflight check (read-only
# `podman inspect`, never restarts or rebuilds it) -- the container was
# just created with --network none above, so requesting --network proxied
# on reuse must be refused before anything about proxied networking is
# even attempted.
run_enter --project "$MISMATCH_PROJECT" --dir "$MISMATCH_DIR1" --network proxied --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 4 ]]; then
  pass "H3: --network mismatch on an existing container is refused (exit 4)"
else
  fail "H3: --network mismatch on an existing container is refused (exit 4) (got exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi
"${PODMAN[@]}" rm -f "agent-${MISMATCH_PROJECT}" >/dev/null 2>&1 || true

# --- 7. Staleness warning: present/absent, on a SCRATCH overlay/tag --------
# M4: never touches agent-example:latest. A throwaway overlay directory
# (a copy of containers/example/) and a matching agent-<scratch>:latest
# tag are created here and removed in the trap.
STALE_DIR="${REPO_ROOT}/containers/${STALE_PROJECT}"
mkdir -p "$STALE_DIR"
cp "${REPO_ROOT}/containers/example/Containerfile" "$STALE_DIR/"
[[ -f "${REPO_ROOT}/containers/example/allowlist.txt" ]] && cp "${REPO_ROOT}/containers/example/allowlist.txt" "$STALE_DIR/"
mkdir -p "${WORKDIR}/stale-project"

if ! "${PODMAN[@]}" build --build-arg SOURCE_SHA=0000000000000000000000000000000000000000000000000000000000000000 \
  -t "agent-${STALE_PROJECT}:latest" -f "${STALE_DIR}/Containerfile" "$STALE_DIR" >"${WORKDIR}/stale-build.out" 2>&1; then
  fail "staleness warning appears when the image label doesn't match its current inputs (could not build the scratch test image: $(tail -5 "${WORKDIR}/stale-build.out"))"
else
  run_enter --project "$STALE_PROJECT" --dir "${WORKDIR}/stale-project" --network none --no-tmux -- true
  if [[ "$ENTER_EXIT" -eq 0 ]] && echo "$ENTER_OUT" | grep -qi 'looks stale'; then
    pass "staleness warning appears when the image label doesn't match its current inputs"
  else
    fail "staleness warning appears when the image label doesn't match its current inputs (exit=${ENTER_EXIT}, got: ${ENTER_OUT})"
  fi
fi
"${PODMAN[@]}" rm -f "agent-${STALE_PROJECT}" >/dev/null 2>&1 || true

if (cd "$REPO_ROOT" && just build "$STALE_PROJECT" >"${WORKDIR}/stale-rebuild.out" 2>&1); then
  run_enter --project "$STALE_PROJECT" --dir "${WORKDIR}/stale-project" --network none --no-tmux -- true
  if [[ "$ENTER_EXIT" -eq 0 ]] && ! echo "$ENTER_OUT" | grep -qi 'looks stale'; then
    pass "staleness warning is absent once the image is rebuilt correctly"
  else
    fail "staleness warning is absent once the image is rebuilt correctly (exit=${ENTER_EXIT}, got: ${ENTER_OUT})"
  fi
else
  fail "staleness warning is absent once the image is rebuilt correctly (could not rebuild the scratch image: $(tail -5 "${WORKDIR}/stale-rebuild.out"))"
fi
"${PODMAN[@]}" rm -f "agent-${STALE_PROJECT}" >/dev/null 2>&1 || true

# --- 8. --rebuild produces a new container id -------------------------------
ID_BEFORE="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Id}}')"
run_enter --project "$TEST_PROJECT" --dir "$PROJECT_DIR" --rebuild --no-tmux -- true
if [[ "$ENTER_EXIT" -ne 0 ]]; then
  fail "--rebuild produces a new container id (invocation failed: exit=${ENTER_EXIT}: ${ENTER_OUT})"
else
  ID_AFTER="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Id}}')"
  if [[ "$ID_BEFORE" != "$ID_AFTER" ]]; then
    pass "--rebuild produces a new container id"
  else
    fail "--rebuild produces a new container id (id unchanged: ${ID_BEFORE})"
  fi
fi

# --- 9. start_if_stopped: stop, re-enter, assert Running and same id -------
ID_BEFORE_STOP="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Id}}')"
"${PODMAN[@]}" stop "$CONTAINER" >/dev/null
run_enter --project "$TEST_PROJECT" --dir "$PROJECT_DIR" --no-tmux -- true
if [[ "$ENTER_EXIT" -eq 0 ]]; then
  ID_AFTER_START="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Id}}')"
  RUNNING="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.State.Running}}')"
  if [[ "$RUNNING" == "true" && "$ID_AFTER_START" == "$ID_BEFORE_STOP" ]]; then
    pass "start_if_stopped: a stopped container is restarted, not recreated"
  else
    fail "start_if_stopped: a stopped container is restarted, not recreated (running=${RUNNING}, id ${ID_BEFORE_STOP} -> ${ID_AFTER_START})"
  fi
else
  fail "start_if_stopped: a stopped container is restarted, not recreated (invocation failed: exit=${ENTER_EXIT}: ${ENTER_OUT})"
fi
"${PODMAN[@]}" rm -f "$CONTAINER" >/dev/null 2>&1 || true

# --- 10. --network=none: no DNS, no route to a raw IP, no proxy env --------
NONE_DIR="${WORKDIR}/none-project"
mkdir -p "$NONE_DIR"
run_enter --project "$NONE_PROJECT" --dir "$NONE_DIR" --network none --no-tmux -- bash -c '
  getent hosts example.com >/dev/null 2>&1 && echo RESOLVED || echo DNS_FAILED
  curl -sS --max-time 5 -o /dev/null "http://'"${PROBE_IP}"'/" 2>/dev/null
  echo "RAWIP_EXIT=$?"
'
if [[ "$ENTER_EXIT" -eq 0 ]] && echo "$ENTER_OUT" | grep -q '^DNS_FAILED$' && echo "$ENTER_OUT" | grep -q '^RAWIP_EXIT=7$'; then
  pass "--network=none: DNS fails and a raw-IP curl to ${PROBE_IP} fails with exit 7 (no route)"
else
  fail "--network=none: DNS fails and a raw-IP curl to ${PROBE_IP} fails with exit 7 (exit=${ENTER_EXIT}, got: ${ENTER_OUT})"
fi
NONE_ENV="$("${PODMAN[@]}" inspect "agent-${NONE_PROJECT}" --format '{{json .Config.Env}}' 2>/dev/null)" || NONE_ENV=""
if [[ "$NONE_ENV" != *'HTTPS_PROXY=http://'* ]]; then
  pass "--network=none: no proxy env injected"
else
  fail "--network=none: no proxy env injected (got: ${NONE_ENV})"
fi
"${PODMAN[@]}" rm -f "agent-${NONE_PROJECT}" >/dev/null 2>&1 || true

# --- 11. Proxied preflight failure: fails fast, never touches the real
#         atelier-egress. ATELIER_EGRESS_HOST is pointed at a name that
#         does not exist, so this exercises the exact failure path without
#         stopping or restarting the real proxy. ------------------------
PREFLIGHT_DIR="${WORKDIR}/preflight-project"
mkdir -p "$PREFLIGHT_DIR"
NONEXISTENT_EGRESS="atelier-egress-does-not-exist-$$"
PREFLIGHT_OUT="$(ATELIER_EGRESS_HOST="$NONEXISTENT_EGRESS" "$ENTER" --project "$PREFLIGHT_PROJECT" --dir "$PREFLIGHT_DIR" --network proxied --no-tmux -- true 2>&1)" || PREFLIGHT_EXIT=$?
if [[ "${PREFLIGHT_EXIT:-0}" -eq 1 ]] && echo "$PREFLIGHT_OUT" | grep -q "requires ${NONEXISTENT_EGRESS} to be running"; then
  pass "proxied preflight failure: fails fast with the just egress-up pointer, without touching the real proxy"
else
  fail "proxied preflight failure: fails fast with the just egress-up pointer (exit=${PREFLIGHT_EXIT:-0}, got: ${PREFLIGHT_OUT})"
fi
unset PREFLIGHT_EXIT
if "${PODMAN[@]}" container exists "agent-${PREFLIGHT_PROJECT}" 2>/dev/null; then
  fail "proxied preflight failure: no container was created"
  "${PODMAN[@]}" rm -f "agent-${PREFLIGHT_PROJECT}" >/dev/null 2>&1 || true
else
  pass "proxied preflight failure: no container was created"
fi

# --- 12. H4: a dotted project name round-trips through the tmux layer ------
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

# --- 13. tmux layer on TEST_PROJECT: session creation, reuse with pane-
#         command verification (M3: a failed second invocation that still
#         leaves the session count at 1 must not be reported as a pass). -
"${TMUX_CMD[@]}" kill-server >/dev/null 2>&1 || true
ATELIER_TMUX="${TMUX_CMD[*]}" "$ENTER" --project "$TEST_PROJECT" --dir "$PROJECT_DIR" </dev/null >/dev/null 2>&1 &
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
SECOND_OUT="$(ATELIER_TMUX="${TMUX_CMD[*]}" timeout 5 "$ENTER" --project "$TEST_PROJECT" --dir "$PROJECT_DIR" </dev/null 2>&1)" || SECOND_EXIT=$?
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

# --- 14. H6: a container removed behind a live session is recreated before
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

# --- Summary ------------------------------------------------------------
echo
echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed =="
[[ "$FAIL_COUNT" -gt 0 ]] && exit 1
exit 0
