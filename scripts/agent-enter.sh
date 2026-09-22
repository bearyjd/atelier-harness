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
# Functions are kept under 50 lines each; no `|| true` hides a real
# failure anywhere in this file.
set -euo pipefail

# --- Constants (env-overridable) -------------------------------------------
# C1/H5 (code review): BASH_SOURCE[0] is the path as invoked, which breaks
# if this script is reached through a symlink (e.g. symlinked into a `bin`
# directory as `agent-enter`) -- readlink -f resolves the symlink chain
# before deriving the repo root, and `pwd -P` resolves any symlink
# components in the directory walk itself.
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
DEFAULT_NETWORK="proxied"
EGRESS_CONTAINER="${ATELIER_EGRESS_HOST:-atelier-egress}"
EGRESS_NETWORK="${ATELIER_EGRESS_NET:-atelier-internal}"
EGRESS_PORT="${ATELIER_EGRESS_PORT:-3128}"
AUTH_VOLUME_CLAUDE="${ATELIER_AUTH_VOLUME_CLAUDE:-atelier-auth-claude}"
AUTH_VOLUME_CODEX="${ATELIER_AUTH_VOLUME_CODEX:-atelier-auth-codex}"
AUTH_VOLUME_GH="${ATELIER_AUTH_VOLUME_GH:-atelier-auth-gh}"

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

# --- podman / tmux wrappers (AUDIT.md §4.4) ---------------------------------
# `podman` is only a shell alias to `distrobox-host-exec podman` inside the
# `dev` distrobox; aliases don't expand in scripts. tmux is NOT routed
# through distrobox-host-exec: the session is created where this script is
# invoked (AUDIT.md §4.4), only the podman calls cross to the host.
resolve_podman() {
  if [[ -f /run/.containerenv ]] && command -v distrobox-host-exec >/dev/null 2>&1; then
    PODMAN=(distrobox-host-exec podman)
  else
    PODMAN=(podman)
  fi
  if [[ -n "${ATELIER_PODMAN:-}" ]]; then
    # shellcheck disable=SC2206
    PODMAN=(${ATELIER_PODMAN})
  fi
}

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
  if "${PODMAN[@]}" image exists "$IMAGE" 2>/dev/null; then
    return 0
  fi
  require_just
  if [[ -f "${REPO_ROOT}/containers/${PROJECT}/Containerfile" ]]; then
    echo "agent-enter: image ${IMAGE} not found; building via 'just build ${PROJECT}'" >&2
    (cd "$REPO_ROOT" && just build "$PROJECT")
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
  actual="$("${PODMAN[@]}" image inspect "$IMAGE" --format '{{index .Labels "org.atelier.source-sha"}}' 2>/dev/null)" || actual=""
  if [[ -z "$actual" ]]; then
    echo "agent-enter: warning: ${IMAGE} has no org.atelier.source-sha label (<missing>); treating it as stale. Pass --rebuild to rebuild." >&2
  elif [[ "$actual" != "$expected" ]]; then
    echo "agent-enter: warning: ${IMAGE} looks stale (built source-sha ${actual:0:12}..., current inputs hash to ${expected:0:12}...); pass --rebuild to rebuild" >&2
  fi
  check_container_image_drift
}

check_container_image_drift() {
  "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null || return 0
  local container_image_id current_image_id
  container_image_id="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.Image}}')"
  current_image_id="$("${PODMAN[@]}" image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)" || current_image_id=""
  if [[ -n "$current_image_id" && "$container_image_id" != "$current_image_id" ]]; then
    echo "agent-enter: warning: container ${CONTAINER} was created from an older ${IMAGE} (the image has changed since); pass --rebuild to recreate" >&2
  fi
}

# --- Network preflight (AUDIT.md §4.2) --------------------------------------
# H3/Codex MEDIUM: called on every proxied start AND every proxied reuse
# (from ensure_container, both branches), not only before create -- a dead
# proxy must be reported whichever branch is taken, including after a host
# reboot restarting a stopped persistent container.
check_network_preflight() {
  [[ "$NETWORK" == "proxied" ]] || return 0
  if ! "${PODMAN[@]}" inspect "$EGRESS_CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
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
  "${PODMAN[@]}" volume exists "$vol" 2>/dev/null || "${PODMAN[@]}" volume create "$vol" >/dev/null
  mp="$("${PODMAN[@]}" volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null)" || mp=""
  if [[ -n "$mp" && -r "$mp" ]]; then
    contents="$(ls -A "$mp" 2>/dev/null)"
  else
    contents="$(probe_volume_contents "$vol")"
  fi
  if [[ -z "$contents" ]]; then
    echo "agent-enter: warning: auth volume ${vol} is empty -- 'just auth' has not populated it yet" >&2
  fi
}

probe_volume_contents() {
  local vol="$1"
  "${PODMAN[@]}" run --rm \
    --network=none --cap-drop=ALL --security-opt=no-new-privileges \
    --read-only --userns=keep-id:uid=1000,gid=1000 \
    -v "${vol}:/probe:ro" \
    agent-base:latest bash -c 'ls -A /probe 2>/dev/null'
}

ensure_auth_volumes() {
  ensure_auth_volume "$AUTH_VOLUME_CLAUDE"
  ensure_auth_volume "$AUTH_VOLUME_CODEX"
  ensure_auth_volume "$AUTH_VOLUME_GH"
}

# --- podman run flags (AUDIT.md §4.3, plus the read-only experiment above) -
build_run_flags() {
  RUN_FLAGS=(
    -d
    --userns=keep-id:uid=1000,gid=1000
    --volume "${DIR}:/work:Z"
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --init
    --pids-limit=2048
    --name "$CONTAINER"
    --hostname "$CONTAINER"
    --read-only
    --tmpfs /tmp
    --tmpfs /home/agent/.cache
    --tmpfs /home/agent/.npm
    --tmpfs /home/agent/.local/share
    --tmpfs /home/agent/.config
    -v "${AUTH_VOLUME_CLAUDE}:/home/agent/.claude"
    -v "${AUTH_VOLUME_CODEX}:/home/agent/.codex"
    -v "${AUTH_VOLUME_GH}:/home/agent/.config/gh"
  )
  if [[ "$NETWORK" == "proxied" ]]; then
    add_proxy_flags
  else
    RUN_FLAGS+=(--network=none)
  fi
  RUN_FLAGS+=("$IMAGE")
}


# atelier-internal is created with --disable-dns (Justfile egress-up):
# Podman used to order /etc/resolv.conf's nameservers non-deterministically
# when a container joined two networks, and the network's own aardvark-dns
# entry racing the injected --dns entries caused agent-base's own DNS to
# be unreliable too. Disabling DNS on the network removes that race
# entirely, but it also means aardvark no longer resolves the
# "atelier-egress" name for anything on that network -- nothing provides
# it anymore. --add-host maps the name statically instead, reading the
# proxy's actual IP from a running container rather than hardcoding a
# second copy of the Justfile's egress_ip constant, so the two cannot
# drift apart the way a duplicated constant eventually would.
egress_ip_on_network() {
  "${PODMAN[@]}" inspect "$EGRESS_CONTAINER" \
    --format "{{with index .NetworkSettings.Networks \"${EGRESS_NETWORK}\"}}{{.IPAddress}}{{end}}" 2>/dev/null
}

add_proxy_flags() {
  local proxy_url="http://${EGRESS_CONTAINER}:${EGRESS_PORT}" egress_ip
  egress_ip="$(egress_ip_on_network)"
  if [[ -z "$egress_ip" ]]; then
    echo "agent-enter: could not determine ${EGRESS_CONTAINER}'s address on ${EGRESS_NETWORK}; is it attached to that network? (run: just egress-up)" >&2
    exit 1
  fi
  RUN_FLAGS+=(
    --network="$EGRESS_NETWORK"
    --add-host "${EGRESS_CONTAINER}:${egress_ip}"
    -e "HTTPS_PROXY=${proxy_url}" -e "https_proxy=${proxy_url}"
    -e "HTTP_PROXY=${proxy_url}" -e "http_proxy=${proxy_url}"
    -e "NO_PROXY=localhost,127.0.0.1" -e "no_proxy=localhost,127.0.0.1"
  )
}

# --- --rebuild (AUDIT.md §3.1) ----------------------------------------------
do_rebuild() {
  echo "agent-enter: --rebuild requested: removing session/container and rebuilding ${IMAGE}" >&2
  if tmux_session_exists; then
    "${TMUX_CMD[@]}" kill-session -t "${SESSION}:"
  fi
  require_just
  if [[ -f "${REPO_ROOT}/containers/${PROJECT}/Containerfile" ]]; then
    (cd "$REPO_ROOT" && just build "$PROJECT")
  else
    (cd "$REPO_ROOT" && just build-base)
  fi
  if "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null; then
    "${PODMAN[@]}" rm -f "$CONTAINER" >/dev/null
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
  if "${PODMAN[@]}" container exists "$CONTAINER" 2>/dev/null; then
    check_network_preflight
    check_container_matches_request
    start_if_stopped
  else
    check_network_preflight
    ensure_auth_volumes
    build_run_flags
    "${PODMAN[@]}" run "${RUN_FLAGS[@]}" >/dev/null
  fi
}

check_container_matches_request() {
  local existing_work network_mode networks
  existing_work="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}')"
  if [[ "$existing_work" != "$DIR" ]]; then
    echo "agent-enter: container ${CONTAINER} has ${existing_work} at /work, not ${DIR}; pass --rebuild to recreate it, or use a different --project" >&2
    exit 4
  fi
  network_mode="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.HostConfig.NetworkMode}}')"
  networks="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{json .NetworkSettings.Networks}}')"
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
  running="$("${PODMAN[@]}" inspect "$CONTAINER" --format '{{.State.Running}}')"
  [[ "$running" == "true" ]] || "${PODMAN[@]}" start "$CONTAINER" >/dev/null
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

enter_no_tmux() {
  ensure_container
  container_exec_flags
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
