#!/usr/bin/env bash
# scripts/auth-login.sh <claude|codex|gh> [volume]
#
# Per-tool login, replacing `just auth`'s copy of the host's credential
# files for Claude and Codex (AUDIT.md §4.1 "Trigger met"): a COPIED OAuth
# token is revoked the moment the host refreshes its own copy -- Meute got
# `401 OAuth access token has been revoked` on 2026-09-23 exactly that way.
# Each branch below instead gives the container side a credential that is
# never shared with the host:
#
#   claude  `claude setup-token` (run by the owner on the HOST) prints a
#           long-lived subscription token; this stores it as a Podman
#           secret, which agent-enter.sh injects as CLAUDE_CODE_OAUTH_TOKEN
#           on proxied runs. No refresh ever happens container-side, so the
#           revocation cannot recur rather than being made less likely.
#   codex   `codex login --device-auth` INSIDE a container with the codex
#           volume mounted, so that volume holds its own refresh pair.
#   gh      `gh auth login --with-token` with a PAT on stdin, into one of
#           the three gh volumes (Meute contract, README.md).
#
# Real logins cannot be exercised headless; tests/smoke.sh covers the
# argument refusals and the whole claude path with a dummy token and a
# throwaway secret name (ATELIER_CLAUDE_SECRET).
set -euo pipefail
# xtrace off before anything touches a secret: an inherited `set -x`
# (e.g. `bash -x` or SHELLOPTS from a debugging session) printed the
# token 7 times in review (2026-09-27) -- once per expansion of it.
{ set +x; } 2>/dev/null

# Podman routing, CLAUDE_SECRET (default + ATELIER_CLAUDE_SECRET override),
# the EGRESS_* defaults, hardened_flags and the proxy helpers are shared
# with agent-enter.sh (2026-09-30; they were hand-kept duplicates before).
# Locating the lib FAILS CLOSED (security review, 2026-09-30): fed on
# stdin (`bash < auth-login.sh`) BASH_SOURCE[0] is empty, and the old
# `dirname "$(readlink -f "")"` quietly became "." -- the CWD -- so a
# lib/atelier-common.sh in whatever directory the caller stood in would
# have been sourced. Separate assignments, so errexit sees each failure.
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  echo "auth-login: cannot locate this script (BASH_SOURCE is empty); run it as a file from the repo checkout, not on stdin" >&2
  exit 1
fi
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ATELIER_LIB="${SELF_PATH%/*}/lib/atelier-common.sh"
if [[ "$ATELIER_LIB" != /* || ! -f "$ATELIER_LIB" ]]; then
  echo "auth-login: missing ${ATELIER_LIB}; run from the repo checkout" >&2
  exit 1
fi
# shellcheck source=scripts/lib/atelier-common.sh
source "$ATELIER_LIB"
resolve_podman
# STDIN RULE for every podman call below (found 2026-09-27): inside the
# `dev` distrobox, distrobox-host-exec gives host-spawn a pty whenever
# stdout is a TTY, and in that mode it both echoes piped stdin to the
# terminal and SWALLOWS it -- even for a call that never reads stdin (a
# preflight `podman network exists` ate and echoed a piped PAT before it
# was read). So: a call fed a credential keeps stdout off the TTY (`| cat`
# or `>/dev/null`); every other call gets `</dev/null`. The one exception
# is the interactive codex login, which needs the terminal.

# Fixed, NOT $ATELIER_AUTH_IMAGE (which auth-import.sh honours): the
# codex and gh containers here are networked, and the gh one is handed a
# PAT on stdin with github.com reachable -- an override image would be
# code of the caller's choosing holding a live credential on a network.
# The claude path runs no container at all, so tests need no override.
IMAGE="agent-base:latest"
CODEX_VOLUME="${ATELIER_AUTH_VOLUME_CODEX:-atelier-auth-codex}"
GH_VOLUMES=(atelier-auth-gh atelier-auth-gh-publish atelier-auth-gh-review)

usage() {
  echo "usage: $0 claude | codex | gh <volume>   (gh volume: one of ${GH_VOLUMES[*]})" >&2
  exit 2
}

# The same egress check, IP lookup and flags as agent-enter.sh's proxied
# profile (lib/atelier-common.sh), plus a `network exists` check, with
# this script's own messages: the codex and gh logins both need
# auth.openai.com / api.github.com, which are on the allow-list. Claude's
# browser flow is NOT, which is why that one runs on the host instead --
# the allow-list is not widened for it. Sets PROXY_FLAGS.
proxy_preflight() {
  local egress_ip
  if ! egress_is_running; then
    echo "auth-login: this login needs ${EGRESS_CONTAINER} running (it goes through the egress proxy); run: just egress-up" >&2
    exit 1
  fi
  if ! "${PODMAN[@]}" network exists "$EGRESS_NETWORK" 2>/dev/null </dev/null; then
    echo "auth-login: network ${EGRESS_NETWORK} does not exist; run: just egress-up" >&2
    exit 1
  fi
  egress_ip="$(egress_ip_on_network)" || egress_ip=""
  if [[ -z "$egress_ip" ]]; then
    echo "auth-login: could not determine ${EGRESS_CONTAINER}'s address on ${EGRESS_NETWORK}; run: just egress-up" >&2
    exit 1
  fi
  proxy_flags "$egress_ip"
}

# Reads one secret into $SECRET_INPUT: hidden prompt on a TTY, otherwise
# all of stdin (what tests and `pass show ... |` pipelines use). The
# `$(cat; printf x)` / `%x` pair keeps trailing newlines intact so that
# exactly ONE trailing "\n" (then one "\r", for a CRLF paste) is stripped
# below -- a bare `$(cat)` strips all of them, silently. Validation is
# deliberately loose (non-empty, no whitespace): no token prefix is
# hard-coded, since a vendor format change must not lock the owner out.
# The value is never echoed, not even in the rejection message.
read_secret_input() {
  local what="$1"
  if [[ -t 0 ]]; then
    printf '%s (input hidden): ' "$what" >&2
    if ! IFS= read -rs SECRET_INPUT; then
      echo >&2
      echo "auth-login: no ${what} read (EOF)" >&2
      exit 1
    fi
    echo >&2
  else
    SECRET_INPUT="$(cat; printf x)"
    SECRET_INPUT="${SECRET_INPUT%x}"
  fi
  SECRET_INPUT="${SECRET_INPUT%$'\n'}"
  SECRET_INPUT="${SECRET_INPUT%$'\r'}"
  if [[ -z "$SECRET_INPUT" || "$SECRET_INPUT" == *[[:space:]]* ]]; then
    echo "auth-login: rejected ${what}: it is empty or contains whitespace (paste exactly the one token, nothing else)" >&2
    exit 1
  fi
}

# `printf` is a bash builtin, so the token only ever travels through a
# pipe -- never through the argv or environment of any process (argv is
# world-readable in /proc; a podman -e would also land in `podman
# inspect`). The `>/dev/null` also keeps this call's stdout off the TTY,
# which is REQUIRED for every stdin-fed podman call in this repo: inside
# the `dev` distrobox, distrobox-host-exec gives host-spawn a pty when
# stdout is a TTY, which echoes piped stdin to the terminal in cleartext
# and never delivers EOF (reproduced 2026-09-27; tests/smoke.sh 4d).
# `--replace` is the rotation path: a --secret env var is
# resolved at container START, not create (verified 2026-09-27: replace,
# then stop+start of an existing container shows the new value), so a
# rotated token needs only a restart of running containers, not --rebuild.
login_claude() {
  if [[ -t 0 ]]; then
    cat >&2 <<'EOF'
In ANOTHER terminal, on the HOST (not inside a container -- the browser
sign-in needs hosts the egress allow-list deliberately does not include),
run:

    claude setup-token

finish the browser sign-in, then paste the token it prints here.
EOF
  fi
  read_secret_input "Claude token"
  printf '%s' "$SECRET_INPUT" | "${PODMAN[@]}" secret create --replace "$CLAUDE_SECRET" - >/dev/null
  echo "auth-login: stored the Claude token in Podman secret ${CLAUDE_SECRET}"
  echo "auth-login: proxied containers get it as CLAUDE_CODE_OAUTH_TOKEN; ones already running pick up a rotated token on their next restart"
}

# NEVER `codex logout`, here or anywhere: it can revoke the refresh token
# server-side, and until the owner's first device-auth login this volume
# may still hold a copy of the host's auth.json from the old `just auth`
# -- a logout would then sign the HOST out as well. The volume is not
# recreated either (unlike gh): it also holds codex's config and session
# history, and a successful login simply overwrites auth.json.
#
# hardened_flags (lib/atelier-common.sh) is the same hardened set agent
# containers run with (AUDIT.md §4.3, including --init and --pids-limit),
# plus --read-only. `codex login --help` and `codex login --device-auth`
# were run under these flags on 2026-09-27: help exits 0, and device-auth
# reached the device-code prompt through the proxy, so the /tmp and
# .cache tmpfs mounts were all codex's login needs. Re-checked 2026-09-30
# after .cache/.local/state became `:U` tmpfs in the set: `codex login
# --help` still exits 0 (with the known harmless PATH-aliases warning).
login_codex() {
  hardened_flags
  proxy_preflight
  echo "auth-login: starting codex device-code login into volume ${CODEX_VOLUME}"
  echo "auth-login: if ChatGPT refuses the device code, enable device-code login in ChatGPT's security settings and re-run"
  # -t only with a terminal on stdin, like agent-enter.sh's
  # container_exec_flags; the device flow itself reads nothing from stdin.
  local tty_flags=(-i)
  if [[ -t 0 ]]; then
    tty_flags+=(-t)
  fi
  "${PODMAN[@]}" run --rm "${tty_flags[@]}" \
    "${HARDENED_FLAGS[@]}" "${PROXY_FLAGS[@]}" \
    -v "${CODEX_VOLUME}:/home/agent/.codex:z" \
    "$IMAGE" \
    codex login --device-auth
}

# gh's own `auth login --help` warns: "Take care when passing a
# fine-grained personal access token to --with-token ... Favour setting
# GH_TOKEN". Accepted here because the Meute contract MOUNTS the gh
# volumes (README.md); switching Meute to a GH_TOKEN secret would be a
# contract change, which is the owner's call (AUDIT.md §4.1).
#
# The new PAT is proven in a STAGING volume first (login + `gh auth
# status`) and only then swapped in, so a mistyped or under-scoped PAT
# never destroys the working credential. The target is recreated, not
# logged-in-on-top: recent gh APPENDS accounts to hosts.yml, and these
# volumes exist precisely to keep one identity per consumer (§4.1).
login_gh() {
  local vol="$1"
  hardened_flags
  proxy_preflight
  check_volume_unused "$vol"
  read_secret_input "GitHub PAT for ${vol}"
  STAGING_VOLUME="${vol}-staging-$$"
  trap remove_staging_volume EXIT
  "${PODMAN[@]}" volume create "$STAGING_VOLUME" >/dev/null </dev/null
  # --insecure-storage: there is no keyring in the container; the token
  # lands in the volume's hosts.yml, which is the whole point of it.
  # `| cat`: stdout of a stdin-fed podman call must never be a TTY (see
  # login_claude) -- without it the PAT is echoed to the terminal.
  printf '%s\n' "$SECRET_INPUT" | "${PODMAN[@]}" run --rm -i \
    "${HARDENED_FLAGS[@]}" "${PROXY_FLAGS[@]}" \
    -v "${STAGING_VOLUME}:/home/agent/.config/gh:z" \
    "$IMAGE" \
    gh auth login --with-token --hostname github.com --git-protocol https --insecure-storage \
    | cat
  "${PODMAN[@]}" run --rm \
    "${HARDENED_FLAGS[@]}" "${PROXY_FLAGS[@]}" \
    -v "${STAGING_VOLUME}:/home/agent/.config/gh:ro,z" \
    "$IMAGE" \
    gh auth status --hostname github.com </dev/null
  swap_in_staging "$vol"
  echo "auth-login: logged ${vol} in to github.com"
}

# `podman volume rm` refuses while any container -- even a stopped one --
# references the volume, and every agent-enter container mounts
# atelier-auth-gh. Checked before the PAT is read so nothing is pasted in
# vain (and a later race still fails safe: the rm refuses, target intact).
check_volume_unused() {
  local vol="$1" users
  users="$("${PODMAN[@]}" ps -a --filter "volume=${vol}" --format '{{.Names}}' </dev/null)"
  if [[ -n "$users" ]]; then
    echo "auth-login: volume ${vol} is in use by: $(echo "$users" | tr '\n' ' ')-- remove those containers first (agent-enter.sh --rebuild recreates one)" >&2
    exit 1
  fi
}

# Only reached once the staged login is proven. The copy runs in a
# --network=none, hardened keep-id container (the same uid mapping that
# wrote the files, so ownership carries over), both volumes :z.
swap_in_staging() {
  local vol="$1"
  if "${PODMAN[@]}" volume exists "$vol" 2>/dev/null </dev/null; then
    "${PODMAN[@]}" volume rm "$vol" >/dev/null </dev/null
  fi
  "${PODMAN[@]}" volume create "$vol" >/dev/null </dev/null
  "${PODMAN[@]}" run --rm --network=none \
    "${HARDENED_FLAGS[@]}" \
    -v "${STAGING_VOLUME}:/src:ro,z" \
    -v "${vol}:/dest:z" \
    "$IMAGE" \
    cp -a /src/. /dest/ </dev/null
}

# EXIT trap: the staging volume holds a PAT, so it goes on success AND on
# every failure path (bad PAT, gh auth status failing, a failed swap).
remove_staging_volume() {
  if [[ -n "${STAGING_VOLUME:-}" ]] && "${PODMAN[@]}" volume exists "$STAGING_VOLUME" 2>/dev/null </dev/null; then
    "${PODMAN[@]}" volume rm -f "$STAGING_VOLUME" >/dev/null </dev/null
  fi
}

is_gh_volume() {
  local v
  for v in "${GH_VOLUMES[@]}"; do
    [[ "$1" == "$v" ]] && return 0
  done
  return 1
}

main() {
  [[ $# -ge 1 ]] || usage
  case "$1" in
    claude) [[ $# -eq 1 ]] || usage; login_claude ;;
    codex) [[ $# -eq 1 ]] || usage; login_codex ;;
    gh)
      [[ $# -eq 2 ]] || usage
      if ! is_gh_volume "$2"; then
        echo "auth-login: gh volume must be one of: ${GH_VOLUMES[*]} (got: $2)" >&2
        exit 2
      fi
      login_gh "$2"
      ;;
    *) usage ;;
  esac
}

main "$@"
