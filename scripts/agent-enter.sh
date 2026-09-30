#!/usr/bin/env bash
# scripts/agent-enter.sh -- Atelier's entry mechanism (AUDIT.md §7, PRP §5).
#
# Three-layer state machine: tmux session -> container -> shell, creating
# whichever layer is missing.
#   - tmux session "agent-<project>" exists -> attach (or switch-client if
#     already inside tmux).
#   - Else container running -> exec a shell into it inside a new tmux
#     session, attach.
#   - Container exists but stopped -> `podman start`, then the same.
#   - Neither exists -> `podman run -d` with the hardened flags below, then
#     the same.
#   - `--no-tmux` skips the tmux layer entirely and execs directly into the
#     container -- what a non-interactive caller (and this repo's own
#     smoke-enter.sh) wants.
#
# REVISED after the Phase 2 code review (.omc/reviews/phase2-code-review.md,
# BLOCK on C1) and the Codex pass (.omc/reviews/phase2-codex.md). Every
# fix below is cross-referenced to its finding ID so the rationale doesn't
# have to be re-derived from the diff.
#
# READ-ONLY EXPERIMENT (AUDIT.md §4.3 carry-over from Phase 1) -- result:
# KEPT. Tested 2026-09-21 against agent-base:latest with
# `--read-only --tmpfs /tmp --tmpfs /home/agent/.cache --tmpfs
# /home/agent/.npm --tmpfs /home/agent/.local/share --tmpfs
# /home/agent/.config`, plus the three auth volumes mounted at their real
# paths (including /home/agent/.config/gh, a subpath of the tmpfs'd
# /home/agent/.config):
#   - `claude --version`, `codex --version`, `pi --version`, `gh --version`
#     all printed their pinned versions; `git status` worked in a bind-
#     mounted /work with a git repo in it.
#   - `claude -p "hi"` exited 1 with a clean "Not logged in - Please run
#     /login" message on stdout -- an auth error, not a crash.
#   - `codex --version` printed a non-fatal stderr WARNING ("proceeding,
#     even though we could not create PATH aliases: Read-only file system")
#     but still exited 0 with the correct version. The same command run
#     WITHOUT --read-only prints no such warning, confirming it is a
#     harmless side effect of the read-only root, not a functional break.
#   - The auth-volume mount at /home/agent/.config/gh (a volume mounted at
#     a subpath of the tmpfs'd /home/agent/.config) survived and stayed
#     writable -- verified with `podman inspect` (mountinfo lists both
#     /home/agent/.config and /home/agent/.config/gh) and a write+read-back
#     through the container. Podman layers the more specific mount over
#     the tmpfs correctly; there is no shadowing.
#   - `podman inspect .Mounts` never lists --tmpfs entries (they live under
#     .HostConfig.Tmpfs instead), so adding these tmpfs mounts does not
#     change what "exactly /work plus the three auth volumes" looks like
#     to anything inspecting .Mounts (tests/smoke-enter.sh included).
#
# CLAUDE TOKEN SECRET (AUDIT.md §4.1, added 2026-09-27): besides the
# mounts above, a proxied container also gets one Podman secret as an env
# var -- `--secret atelier-claude-token,type=env,target=CLAUDE_CODE_OAUTH_TOKEN`
# -- when that secret exists (populated by `just auth-login claude`). It is
# not a mount, so .Mounts is still exactly /work plus the three auth
# volumes, and the value never appears in `podman inspect` (verified).
# See add_claude_secret_flag / check_container_secret below.
#
# STATE TMPFS (added 2026-09-30): gh 2.97 writes
# ~/.local/state/gh/device-id on every run (auth-login.sh found it and
# gave its gh containers this tmpfs). Probed here with this file's exact
# flag set: `gh --version`, `gh config list`, `gh api` (GH_TOKEN set,
# --network=none) all printed NO error -- the write fails silently -- but
# device-id only appears once /home/agent/.local/state is a tmpfs, and
# `mkdir` there fails with "Read-only file system" without it. Added for
# every other XDG_STATE_HOME user too (bash/less history). It now lives in
# hardened_flags (lib/atelier-common.sh), so auth-login's containers get
# it from the same place.
#
# TMPFS OWNERSHIP (2026-09-30): the .local/share tmpfs came up root:root
# 755 -- agent could not write to it. Every tmpfs under /home/agent now
# takes `:U` (chown to the container user); the probe and the options
# that were tried are in lib/atelier-common.sh (hardened_flags).
#
# Existing containers keep their old tmpfs flags until --rebuild; nothing
# refuses them, since check_container_matches_request compares only /work
# and network.
#
# STDIN RULE for every podman call in this file (found 2026-09-27 in
# auth-login.sh, reproduced here 2026-09-30): inside the `dev` distrobox,
# distrobox-host-exec gives host-spawn a pty whenever stdout is a TTY, and
# in that mode it echoes piped stdin to the terminal and SWALLOWS it --
# even for a call that never reads stdin. `printf canary | agent-enter.sh
# --no-tmux -- cat` under a pty printed the canary once (echoed by a
# preflight inspect) and hung 60s, the command never seeing it. So every
# podman call (and every `just build`, which runs podman) gets
# `</dev/null`, except the final exec that is meant to receive stdin (see
# enter_no_tmux). tmux calls don't: the pane's podman exec reads the
# pane's own tty, never this script's stdin, and attach needs the terminal.
#
# Functions are kept under 50 lines each; no `|| true` hides a real
# failure anywhere in this file.
set -euo pipefail

# --- Constants (env-overridable) -------------------------------------------
# C1/H5 (code review): BASH_SOURCE[0] is the path as invoked, which breaks
# if this script is reached through a symlink (e.g. symlinked into a `bin`
# directory as `agent-enter`) -- readlink -f resolves the symlink chain
# before deriving the repo root, and `pwd -P` resolves any symlink
# components in the directory walk itself.
# Locating the lib FAILS CLOSED (security review, 2026-09-30): fed on
# stdin (`bash < agent-enter.sh`) BASH_SOURCE[0] is empty, and the old
# `dirname "$(readlink -f "")"` quietly became "." -- the CWD -- so a
# lib/atelier-common.sh in whatever directory the caller stood in would
# have been sourced. Separate assignments, so errexit sees each failure.
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  echo "agent-enter: cannot locate this script (BASH_SOURCE is empty); run it as a file from the repo checkout, not on stdin" >&2
  exit 1
fi
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "${SELF_PATH%/*}/.." && pwd -P)"
# PODMAN routing, CLAUDE_SECRET, the EGRESS_* defaults (and their
# ATELIER_* overrides), hardened_flags and the proxy helpers.
ATELIER_LIB="${REPO_ROOT}/scripts/lib/atelier-common.sh"
if [[ "$ATELIER_LIB" != /* || ! -f "$ATELIER_LIB" ]]; then
  echo "agent-enter: missing ${ATELIER_LIB}; run from the repo checkout" >&2
  exit 1
fi
# shellcheck source=scripts/lib/atelier-common.sh
source "$ATELIER_LIB"
DEFAULT_NETWORK="proxied"
AUTH_VOLUME_CLAUDE="${ATELIER_AUTH_VOLUME_CLAUDE:-atelier-auth-claude}"
AUTH_VOLUME_CODEX="${ATELIER_AUTH_VOLUME_CODEX:-atelier-auth-codex}"
AUTH_VOLUME_GH="${ATELIER_AUTH_VOLUME_GH:-atelier-auth-gh}"
CLAUDE_TOKEN_ENV="CLAUDE_CODE_OAUTH_TOKEN"

# H5: fail loudly, naming the resolved root, rather than crash later with a
# bare "No such file or directory" from a relative path that silently
# pointed somewhere else (reproduced via a symlinked entry point in the
# review).
assert_repo_root() {
  if [[ ! -f "${REPO_ROOT}/scripts/source-sha.sh" || ! -f "${REPO_ROOT}/Justfile" ]]; then
    echo "agent-enter: resolved REPO_ROOT=${REPO_ROOT} does not look like the Atelier repo (missing scripts/source-sha.sh or Justfile) -- check how this script was invoked (symlinks are resolved with readlink -f)" >&2
    exit 1
  fi
}

# --- tmux wrapper (AUDIT.md §4.4) -------------------------------------------
# resolve_podman lives in lib/atelier-common.sh. tmux is NOT routed
# through distrobox-host-exec: the session is created where this script is
# invoked (AUDIT.md §4.4), only the podman calls cross to the host.
resolve_tmux() {
  TMUX_CMD=(tmux)
  if [[ -n "${ATELIER_TMUX:-}" ]]; then
    # shellcheck disable=SC2206
    TMUX_CMD=(${ATELIER_TMUX})
  fi
}

# L4: a missing `just` used to surface as a bare "command not found" deep
# inside ensure_image_built/do_rebuild.
require_just() {
  command -v just >/dev/null 2>&1 || {
    echo "agent-enter: 'just' is required (to build images) but was not found on PATH" >&2
    exit 1
  }
}

usage_error() {
  echo "agent-enter: $1" >&2
  print_usage >&2
  exit 2
}

print_usage() {
  cat <<'EOF'
usage: agent-enter.sh [--project NAME] [--dir PATH] [--network proxied|none]
                       [--rebuild] [--allow-self] [--no-tmux] [--] [command...]
EOF
}

# --- Argument parsing --------------------------------------------------------
PROJECT=""
DIR="$PWD"
NETWORK="$DEFAULT_NETWORK"
REBUILD=0
ALLOW_SELF=0
NO_TMUX=0
COMMAND=()

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) [[ $# -ge 2 ]] || usage_error "--project needs a value"; PROJECT="$2"; shift 2 ;;
      --dir) [[ $# -ge 2 ]] || usage_error "--dir needs a value"; DIR="$2"; shift 2 ;;
      --network)
        [[ $# -ge 2 ]] || usage_error "--network needs a value"
        case "$2" in
          proxied|none) NETWORK="$2" ;;
          *) usage_error "--network must be 'proxied' or 'none' (got: $2)" ;;
        esac
        shift 2 ;;
      --rebuild) REBUILD=1; shift ;;
      --allow-self) ALLOW_SELF=1; shift ;;
      --no-tmux) NO_TMUX=1; shift ;;
      --) shift; COMMAND=("$@"); break ;;
      -h|--help) print_usage; exit 0 ;;
      -*) usage_error "unknown flag: $1" ;;
      *) COMMAND=("$@"); break ;;
    esac
  done
}

# --- Project / dir resolution -----------------------------------------------
# M5: validation lives in scripts/valid-project-name.sh, the sole source of
# truth also called by the Justfile's `build` recipe (they had drifted:
# the Justfile rejected "." and ".." on top of the regex, this script did
# not). A failure here exits 2 with a message printed by that script.
#
# The `if ! cmd; then exit 2; fi` shape is required, not stylistic: this
# function is always called as `X="$(sanitize_project_name ...)"`, and
# bash does not propagate a failing command's errexit out of a command
# substitution's subshell unless `shopt -s inherit_errexit` is set (it
# isn't, for portability to older bash). A bare failing command here would
# print the rejection message and then fall through to `printf` anyway,
# returning the invalid name as if it had been accepted -- verified this
# was a real bug in an earlier draft of this function. `exit` is
# unconditional regardless of errexit settings, so it is used explicitly.
sanitize_project_name() {
  local name="$1"
  if ! "${REPO_ROOT}/scripts/valid-project-name.sh" "$name"; then
    exit 2
  fi
  printf '%s' "$name"
}

resolve_project() {
  if ! DIR="$(realpath -e "$DIR" 2>/dev/null)"; then
    echo "agent-enter: --dir does not exist: ${DIR}" >&2
    exit 1
  fi
  [[ -n "$PROJECT" ]] || PROJECT="$(basename "$DIR")"
  PROJECT="$(sanitize_project_name "$PROJECT")"
  CONTAINER="agent-${PROJECT}"
  SESSION="agent-${PROJECT}"
}

# --- Filesystem-identity helpers (C1) ---------------------------------------
# device+inode, not string comparison: realpath resolves symlinks but not
# bind mounts, and this host has /home/user and /var/home/user as two
# stable canonical paths to the same directory (verified: identical
# `stat -c '%d:%i'`). A string comparison of two realpath'd paths misses
# that entirely -- that was C1, self-refusal failing open.
stat_id() {
  stat -c '%d:%i' "$1" 2>/dev/null
}

is_within_repo() {
  local probe="$1" root_id
  root_id="$(stat_id "$REPO_ROOT")" || return 2
  while :; do
    [[ "$(stat_id "$probe")" == "$root_id" ]] && return 0
    [[ "$probe" == "/" ]] && return 1
    probe="$(dirname "$probe")"
  done
}

# C1 "related, same root cause": a git worktree or second clone of Atelier
# at another path is not caught by is_within_repo (it genuinely is a
# different directory). Belt-and-braces content check: either it looks like
# an Atelier checkout by its marker files, or its git common dir resolves
# inside this repo (a worktree of it).
looks_like_atelier_checkout() {
  local dir="$1" git_common_dir
  if [[ -f "${dir}/scripts/source-sha.sh" && -f "${dir}/containers/agent-base/Containerfile" ]]; then
    return 0
  fi
  git_common_dir="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$git_common_dir" == /* ]] || git_common_dir="${dir}/${git_common_dir}"
  is_within_repo "$git_common_dir"
}

# --- Self-refusal (AUDIT.md §5 / README "must never be /work") -------------
check_self_refusal() {
  [[ "$ALLOW_SELF" -eq 1 ]] && return 0
  if is_within_repo "$DIR"; then
    echo "agent-enter: refusing to bind ${DIR} as /work: it is this repository (Atelier itself) or a path inside it, matched by filesystem identity (device+inode), not by string -- this host has more than one canonical path to the same directory. An agent with Atelier at /work could edit allowlist.txt, the Justfile, or a Containerfile, and the change would take effect the next time the owner runs a build -- exactly the trusted moment this design protects (README.md). Pass --allow-self to override, or mount it read-only from another tool if you just need to edit it." >&2
    exit 3
  fi
  if looks_like_atelier_checkout "$DIR"; then
    echo "agent-enter: refusing to bind ${DIR} as /work: it looks like a separate Atelier checkout (both scripts/source-sha.sh and containers/agent-base/Containerfile are present, or its git directory resolves inside this repository -- e.g. a worktree). Pass --allow-self to override." >&2
    exit 3
  fi
}

# --- Dangerous-directory refusal (code review M2 / Codex HIGH) -------------
# Unconditional, no --allow-self override: --allow-self exists for "this is
# the Atelier repo itself", not for "mount my whole $HOME". Device+inode
# again, so a second path to $HOME (or /) doesn't slip through.
check_dangerous_dir() {
  local dir_id d d_id
  dir_id="$(stat_id "$DIR")"
  for d in "$HOME" / /etc /usr /var; do
    [[ -e "$d" ]] || continue
    d_id="$(stat_id "$d")"
    if [[ -n "$dir_id" && "$dir_id" == "$d_id" ]]; then
      echo "agent-enter: refusing to bind ${DIR} as /work: it is ${d}, not a project directory (AUDIT.md §4.1 forbids \$HOME/system mounts). Pass a real project directory with --dir." >&2
      exit 3
    fi
  done
}

# --- Image resolution (build overlay if missing; agent-base must pre-exist) -
resolve_image_name() {
  if [[ -f "${REPO_ROOT}/containers/${PROJECT}/Containerfile" ]]; then
    IMAGE="agent-${PROJECT}:latest"
  else
    IMAGE="agent-base:latest"
    echo "agent-enter: no containers/${PROJECT}/Containerfile found; using ${IMAGE}" >&2
  fi
}

ensure_image_built() {
  if "${PODMAN[@]}" image exists "$IMAGE" 2>/dev/null </dev/null; then
    return 0
  fi
  require_just
  if [[ -f "${REPO_ROOT}/containers/${PROJECT}/Containerfile" ]]; then
    echo "agent-enter: image ${IMAGE} not found; building via 'just build ${PROJECT}'" >&2
    (cd "$REPO_ROOT" && just build "$PROJECT") </dev/null
  else
    echo "agent-enter: image ${IMAGE} not found; run 'just build-base' first" >&2
    exit 1
  fi
}

# --- Staleness check (AUDIT.md §3.1) ----------------------------------------
# source-sha.sh's manifest lines include the path text passed to it, so this
# MUST invoke it with paths relative to REPO_ROOT, exactly as the Justfile's
# build/build-base recipes do (both `cd` there first) -- absolute paths here
# would hash to a different, permanently-mismatching manifest even when the
# file contents are byte-identical to what was just built. For an overlay,
# agent-base's files are enumerated at call time (not a hardcoded
# Containerfile+installer pair) so this stays correct whatever agent-base's
# own file set happens to be -- mirrors the Justfile's `build` recipe
# exactly, which is the only way the two cannot drift apart (AUDIT.md §5).
expected_source_sha() {
  (
    cd "$REPO_ROOT"
    if [[ -f "containers/${PROJECT}/Containerfile" ]]; then
      local base_files=()
      while IFS= read -r -d '' f; do
        base_files+=("$f")
      done < <(find containers/agent-base -type f -print0)
      ./scripts/source-sha.sh "containers/${PROJECT}" "${base_files[@]}"
    else
      ./scripts/source-sha.sh containers/agent-base
    fi
  )
}

# L5: a missing label and a mismatched label are distinguished in the
# message (Podman renders a missing key as the empty string via Go
# template's `index`, not an error) -- both are still treated as stale.
check_staleness() {
  local expected actual
  expected="$(expected_source_sha)"
  actual="$("${PODMAN[@]}" image inspect "$IMAGE" --format '{{index .Labels "org.atelier.source-sha"}}' 2>/dev/null </dev/null)" || actual=""
  if [[ -z "$actual" ]]; then
    echo "agent-enter: warning: ${IMAGE} has no org.atelier.source-sha label (<missing>); treating it as stale. Pass --rebuild to rebuild." >&2
  elif [[ "$actual" != "$expected" ]]; then
    echo "agent-enter: warning: ${IMAGE} looks stale (built source-sha ${actual:0:12}..., current inputs hash to ${expected:0:12}...); pass --rebuild to rebuild" >&2
  fi
  check_container_image_drift
}

check_container_image_drift() {
  "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null </dev/null || return 0
  local container_image_id current_image_id
  container_image_id="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Image}}' </dev/null)"
  current_image_id="$("${PODMAN[@]}" image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null </dev/null)" || current_image_id=""
  if [[ -n "$current_image_id" && "$container_image_id" != "$current_image_id" ]]; then
    echo "agent-enter: warning: container ${CONTAINER} was created from an older ${IMAGE} (the image has changed since); pass --rebuild to recreate" >&2
  fi
}

# --- Network preflight (AUDIT.md §4.2) --------------------------------------
# H3/Codex MEDIUM: called on every proxied start AND every proxied reuse
# (from ensure_container, both branches), not only before create -- a dead
# proxy must be reported whichever branch is taken, including after a host
# reboot restarting a stopped persistent container. egress_is_running is
# shared with auth-login.sh (lib/atelier-common.sh); the message is ours
# (tests/smoke-enter.sh 11 asserts it).
check_network_preflight() {
  [[ "$NETWORK" == "proxied" ]] || return 0
  if ! egress_is_running; then
    echo "agent-enter: --network=proxied requires ${EGRESS_CONTAINER} to be running; run: just egress-up" >&2
    exit 1
  fi
}

# --- Auth volumes (AUDIT.md §4.1) -------------------------------------------
# H2: the previous version ran the OVERLAY image on Podman's default
# network (no --network=none, no --cap-drop, no --userns=keep-id) just to
# `ls -A` a mounted credential volume -- reproduced as a live route with
# working DNS and a completed HTTPS connection while a credential volume
# was attached, on every first-run of a project, even under --network
# none. Fixed to never start a container for this on the normal path:
# `podman volume inspect` gives the host mountpoint directly, and on this
# host (rootless, keep-id-imported) it is readable without one. A
# hardened probe container (agent-base:latest only, never the overlay) is
# the fallback for a portability edge case, not the default path.
ensure_auth_volume() {
  local vol="$1" mp contents
  "${PODMAN[@]}" volume exists "$vol" 2>/dev/null </dev/null || "${PODMAN[@]}" volume create "$vol" >/dev/null </dev/null
  mp="$("${PODMAN[@]}" volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null </dev/null)" || mp=""
  if [[ -n "$mp" && -r "$mp" ]]; then
    contents="$(ls -A "$mp" 2>/dev/null)"
  else
    contents="$(probe_volume_contents "$vol")"
  fi
  if [[ -z "$contents" ]]; then
    if [[ "$vol" == "$AUTH_VOLUME_CLAUDE" ]]; then
      # Not a problem on its own: claude authenticates from the token
      # secret (CLAUDE_CODE_OAUTH_TOKEN), not from this volume.
      echo "agent-enter: note: auth volume ${vol} is empty -- that is normal, claude authenticates via its token secret (just auth-login claude)" >&2
    else
      echo "agent-enter: warning: auth volume ${vol} is empty -- nothing has populated it yet (see README.md 'Populating auth volumes': just auth-login codex|gh, or just auth for gh)" >&2
    fi
  fi
}

probe_volume_contents() {
  local vol="$1"
  # :z for the same reason as the real mounts in build_run_flags (see
  # its comment): this containerized read must not fail just because
  # some other consumer previously :Z-poisoned the volume.
  "${PODMAN[@]}" run --rm \
    --network=none --cap-drop=ALL --security-opt=no-new-privileges \
    --read-only --userns=keep-id:uid=1000,gid=1000 \
    -v "${vol}:/probe:ro,z" \
    agent-base:latest bash -c 'ls -A /probe 2>/dev/null' </dev/null
}

ensure_auth_volumes() {
  ensure_auth_volume "$AUTH_VOLUME_CLAUDE"
  ensure_auth_volume "$AUTH_VOLUME_CODEX"
  ensure_auth_volume "$AUTH_VOLUME_GH"
}

# --- podman run flags (AUDIT.md §4.3, plus the read-only experiment above) -
# `/work` is `:Z` (private label): only this one container ever needs to
# read it. The three auth volumes are `:z` (shared label), not `:Z` and
# not unflagged -- found in testing (Meute report, reproduced here):
# `:Z`-mounting a named volume rewrites its content to a PRIVATE MCS
# category tied to that one container; a later container mounting the
# same volume with no flag at all then gets Permission denied, because
# SELinux enforces the mismatched category against a mount that never
# asked for a relabel. These volumes are read by both `agent-enter.sh`
# (interactive) and Meute's unattended containers by design -- that's the
# whole point of a named credential volume instead of a bind mount -- so
# whichever one mounts first with `:Z` poisons it for the other. `:z`
# resets the volume to the shared `container_file_t:s0` label (no
# categories) on every mount, which every later mount of the same volume
# can read regardless of what mounted it last. The isolation `:Z` would
# otherwise buy here is illusory anyway: reading a named volume already
# requires knowing its name and mounting it explicitly, which is exactly
# the access a shared label grants and nothing more.
#
# The base set (keep-id, cap-drop, no-new-privileges, --init, pids-limit,
# --read-only, /tmp, .cache and .local/state tmpfs) is hardened_flags,
# shared with auth-login.sh; the rest is per-project. `:U` on every tmpfs
# under /home/agent: see TMPFS OWNERSHIP in the header.
build_run_flags() {
  hardened_flags
  RUN_FLAGS=(
    -d
    "${HARDENED_FLAGS[@]}"
    --volume "${DIR}:/work:Z"
    --name "$CONTAINER"
    --hostname "$CONTAINER"
    --tmpfs /home/agent/.npm:U
    --tmpfs /home/agent/.local/share:U
    --tmpfs /home/agent/.config:U
    -v "${AUTH_VOLUME_CLAUDE}:/home/agent/.claude:z"
    -v "${AUTH_VOLUME_CODEX}:/home/agent/.codex:z"
    -v "${AUTH_VOLUME_GH}:/home/agent/.config/gh:z"
  )
  if [[ "$NETWORK" == "proxied" ]]; then
    add_proxy_flags
    add_claude_secret_flag
  else
    RUN_FLAGS+=(--network=none)
  fi
  RUN_FLAGS+=("$IMAGE")
}

# egress_ip_on_network and proxy_flags live in lib/atelier-common.sh (see
# its comment for why the proxy's IP is read live and mapped --add-host).
add_proxy_flags() {
  local egress_ip
  egress_ip="$(egress_ip_on_network)" || egress_ip=""
  if [[ -z "$egress_ip" ]]; then
    echo "agent-enter: could not determine ${EGRESS_CONTAINER}'s address on ${EGRESS_NETWORK}; is it attached to that network? (run: just egress-up)" >&2
    exit 1
  fi
  proxy_flags "$egress_ip"
  RUN_FLAGS+=("${PROXY_FLAGS[@]}")
}

# --- Claude token secret (AUDIT.md §4.1) ------------------------------------
# Proxied only: the `none` profile never calls a model, so it never gets
# the token. A missing secret is a warning, not a refusal -- codex and pi
# may still be usable in the container without it. The value travels
# only as a secret reference; it is never in argv, `-e`, or `inspect`.
warn_no_claude_secret() {
  echo "agent-enter: warning: Podman secret ${CLAUDE_SECRET} does not exist -- claude in ${CONTAINER} will not be authenticated (codex/pi may still work); run: just auth-login claude" >&2
}

add_claude_secret_flag() {
  if "${PODMAN[@]}" secret exists "$CLAUDE_SECRET" 2>/dev/null </dev/null; then
    RUN_FLAGS+=(--secret "${CLAUDE_SECRET},type=env,target=${CLAUDE_TOKEN_ENV}")
  else
    warn_no_claude_secret
  fi
}

# Which secret (if any) the container was created with, by name. Found
# empirically on podman 5.8.7 (2026-09-27): a `type=env` secret does NOT
# appear in `.Config.Secrets` (null -- only mount-type secrets are listed
# there) nor anywhere under `.HostConfig`; the only inspect field that
# records it is `.Config.CreateCommand`, the argv the container was
# created with. Sets REFERENCED_SECRET (empty if there is no reference).
#
# Sets a global rather than printing for `$(...)`, and captures inspect
# into a variable before parsing (here-string, not `< <(...)`): a failure
# inside a process substitution -- or inside a command substitution's
# subshell, which does not inherit errexit here (see
# sanitize_project_name) -- would be silently ignored and read as "no
# secret". Here a failed inspect stops the script under `set -e`.
container_claude_secret() {
  local create_cmd arg
  REFERENCED_SECRET=""
  create_cmd="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{range .Config.CreateCommand}}{{println .}}{{end}}' </dev/null)"
  while IFS= read -r arg; do
    if [[ "$arg" == *",type=env,target=${CLAUDE_TOKEN_ENV}" ]]; then
      REFERENCED_SECRET="${arg%%,*}"
      return 0
    fi
  done <<< "$create_cmd"
}

# Reuse path. Rotation needs only a restart, never --rebuild: a --secret
# env var is resolved at container START, not create (verified
# 2026-09-27: `secret create --replace`, then stop+start, shows the new
# value; so does `secret rm` + `secret create` under the same name). Two
# states cannot be fixed by a restart, and both refuse with exit 4 in the
# same spirit as check_container_matches_request:
#   - created without the secret, which exists now: an env secret can only
#     be attached at creation, so this container would silently stay
#     unauthenticated forever.
#   - created with a DIFFERENT secret name than the one now configured
#     (e.g. a leftover smoke-test container carrying a dummy token):
#     silently running on the wrong token is worse than refusing.
#   - created with a secret that has since been deleted: `podman start`
#     fails with a bare `no secret with name or id ...: no such secret`.
#     Only checked when the container actually needs starting -- a running
#     one already has the env var and keeps working.
check_container_secret() {
  [[ "$NETWORK" == "proxied" ]] || return 0
  local referenced running
  container_claude_secret
  referenced="$REFERENCED_SECRET"
  if [[ -z "$referenced" ]]; then
    if "${PODMAN[@]}" secret exists "$CLAUDE_SECRET" 2>/dev/null </dev/null; then
      echo "agent-enter: container ${CONTAINER} was created without the Claude token secret ${CLAUDE_SECRET}, which exists now; a secret can only be attached at creation, so pass --rebuild to recreate it" >&2
      exit 4
    fi
    warn_no_claude_secret
    return 0
  fi
  if [[ "$referenced" != "$CLAUDE_SECRET" ]]; then
    echo "agent-enter: container ${CONTAINER} was created with the Podman secret ${referenced}, but the configured Claude token secret is ${CLAUDE_SECRET}; pass --rebuild to recreate it with the configured one" >&2
    exit 4
  fi
  running="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.State.Running}}' </dev/null)"
  if [[ "$running" != "true" ]] && ! "${PODMAN[@]}" secret exists "$referenced" 2>/dev/null </dev/null; then
    echo "agent-enter: container ${CONTAINER} was created with the Podman secret ${referenced}, which no longer exists, so it cannot be started; recreate the secret (just auth-login claude) or pass --rebuild to recreate the container" >&2
    exit 4
  fi
}

# --- --rebuild (AUDIT.md §3.1) ----------------------------------------------
do_rebuild() {
  echo "agent-enter: --rebuild requested: removing session/container and rebuilding ${IMAGE}" >&2
  if tmux_session_exists; then
    "${TMUX_CMD[@]}" kill-session -t "${SESSION}:"
  fi
  require_just
  if [[ -f "${REPO_ROOT}/containers/${PROJECT}/Containerfile" ]]; then
    (cd "$REPO_ROOT" && just build "$PROJECT") </dev/null
  else
    (cd "$REPO_ROOT" && just build-base) </dev/null
  fi
  if "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null </dev/null; then
    "${PODMAN[@]}" rm -f "$CONTAINER" >/dev/null </dev/null
  fi
}

# --- Container layer: idempotently reach "created and running" -------------
# H1/H3: the exists-branch used to only start the container -- neither
# --dir nor --network were ever compared against what it actually has,
# so a second --dir for the same --project silently kept the FIRST
# directory at /work, and --network was a create-time-only switch that
# silently no-op'd on reuse. Both now refuse (exit 4) rather than warn: a
# warning scrolls past an attach, and AUDIT §3.1 says never auto-recreate,
# so the only safe response to "this isn't what was asked for" is to stop
# and point at --rebuild.
ensure_container() {
  check_staleness
  if "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null </dev/null; then
    check_network_preflight
    check_container_matches_request
    check_container_secret
    start_if_stopped
  else
    check_network_preflight
    ensure_auth_volumes
    build_run_flags
    "${PODMAN[@]}" run "${RUN_FLAGS[@]}" >/dev/null </dev/null
  fi
}

check_container_matches_request() {
  local existing_work network_mode networks
  existing_work="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}' </dev/null)"
  if [[ "$existing_work" != "$DIR" ]]; then
    echo "agent-enter: container ${CONTAINER} has ${existing_work} at /work, not ${DIR}; pass --rebuild to recreate it, or use a different --project" >&2
    exit 4
  fi
  network_mode="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.HostConfig.NetworkMode}}' </dev/null)"
  networks="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{json .NetworkSettings.Networks}}' </dev/null)"
  if [[ "$NETWORK" == "none" && "$network_mode" != "none" ]]; then
    echo "agent-enter: container ${CONTAINER} was created with network profile 'proxied', not 'none'; pass --rebuild to recreate it" >&2
    exit 4
  fi
  if [[ "$NETWORK" == "proxied" && "$networks" != *"\"${EGRESS_NETWORK}\""* ]]; then
    echo "agent-enter: container ${CONTAINER} was created with network profile 'none', not 'proxied'; pass --rebuild to recreate it" >&2
    exit 4
  fi
}

start_if_stopped() {
  local running
  running="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.State.Running}}' </dev/null)"
  [[ "$running" == "true" ]] || "${PODMAN[@]}" start "$CONTAINER" >/dev/null </dev/null
}

# --- Shell layer -------------------------------------------------------------
container_exec_flags() {
  EXEC_FLAGS=(exec -i)
  if [[ -t 0 && -t 1 ]]; then
    EXEC_FLAGS+=(-t)
  fi
  EXEC_FLAGS+=("$CONTAINER")
  if [[ ${#COMMAND[@]} -gt 0 ]]; then
    EXEC_FLAGS+=("${COMMAND[@]}")
  else
    EXEC_FLAGS+=(bash -l)
  fi
}

# --- tmux layer --------------------------------------------------------------
# H4: tmux parses a bare "." in a -t target as the window/pane separator,
# so an unadorned project name containing one (my.app, example.com, v2.0)
# permanently breaks has-session/attach/switch-client/kill-session -- the
# first call leaves a session it can never find again. A trailing colon
# terminates the target and was verified (in the review) to fix all four
# subcommands this script uses.
tmux_session_exists() {
  "${TMUX_CMD[@]}" has-session -t "${SESSION}:" 2>/dev/null
}

attach_or_switch() {
  if [[ -n "${TMUX:-}" ]]; then
    "${TMUX_CMD[@]}" switch-client -t "${SESSION}:"
  else
    "${TMUX_CMD[@]}" attach -t "${SESSION}:"
  fi
}

# L1: quotes a single argument for /bin/sh (POSIX single-quote escaping),
# not bash's `printf %q`, which used to emit bash-specific $'...' quoting
# even though tmux runs the resulting string under /bin/sh.
sh_quote_one() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

sh_quote_words() {
  local out="" w
  for w in "$@"; do
    out+="$(sh_quote_one "$w") "
  done
  printf '%s' "$out"
}

# The one podman call that is MEANT to get the caller's stdin, so no
# `</dev/null`. It is `exec`, so this script's PID becomes podman's and
# signals reach it directly -- EXCEPT in exactly the trigger case of the
# STDIN RULE above: stdin piped (not a terminal) AND stdout a terminal.
# There stdout goes through `| cat`, because a stdin-fed podman call must
# never have a TTY stdout -- verified 2026-09-30, `printf x |
# distrobox-host-exec podman exec -i C tr a-z A-Z` under a pty echoed x
# and hung (no EOF); with `| cat` it printed X and exited 0.
#
# On that `| cat` path, under pipefail the result is the rightmost
# non-zero status: podman's (the command's own, e.g. 42) unless cat
# itself fails -- e.g. SIGPIPE/EIO when the terminal goes away -- in
# which case cat's status wins. Signals are NOT forwarded: bash defers
# traps until a foreground pipeline finishes, so a trap here could not
# relay them. Ctrl-C/hangup from the terminal already reach the whole
# pipeline (it is the terminal's foreground job); a program stopping this
# must signal the process group (`kill -TERM -- -<pgid>`), not the PID.
enter_no_tmux() {
  ensure_container
  container_exec_flags
  if [[ ! -t 0 && -t 1 ]]; then
    "${PODMAN[@]}" "${EXEC_FLAGS[@]}" | cat
    return
  fi
  exec "${PODMAN[@]}" "${EXEC_FLAGS[@]}"
}

# H6: ensure_container used to run only on the create-session branch, so
# the common case -- attaching to an already-live session, day after day
# -- never re-checked staleness, image drift, network preflight or auth
# volumes. AUDIT §3.1 requires the label comparison "before attaching";
# the old code compared it only before *creating*. Reproduced: a container
# removed out from under a live session (`remain-on-exit on`) attached to
# a dead pane with no error and no self-repair short of --rebuild. Moving
# this call before the session-exists check makes it unconditional -- one
# `podman container exists` plus the staleness hash on every attach, and
# a container removed behind a live session is recreated before the
# attach is attempted.
enter_tmux() {
  ensure_container
  if tmux_session_exists; then
    attach_or_switch
    return 0
  fi
  container_exec_flags
  local podman_cmd
  podman_cmd="$(sh_quote_words "${PODMAN[@]}" "${EXEC_FLAGS[@]}")"
  "${TMUX_CMD[@]}" new-session -d -s "$SESSION" "$podman_cmd"
  attach_or_switch
}

# --- Main --------------------------------------------------------------------
main() {
  assert_repo_root
  resolve_podman
  resolve_tmux
  parse_args "$@"
  resolve_project
  check_dangerous_dir
  check_self_refusal
  resolve_image_name
  if [[ "$REBUILD" -eq 1 ]]; then
    do_rebuild
  else
    ensure_image_built
  fi
  if [[ "$NO_TMUX" -eq 1 ]]; then
    enter_no_tmux
  else
    enter_tmux
  fi
}

main "$@"
