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
#
# Shares its podman routing, proxy preflight and proxy flags with
# agent-enter.sh by DUPLICATION, not a sourced library -- a known cost,
# kept deliberately small; a change to either copy needs the other.
set -euo pipefail
# xtrace off before anything touches a secret: an inherited `set -x`
# (e.g. `bash -x` or SHELLOPTS from a debugging session) printed the
# token 7 times in review (2026-09-27) -- once per expansion of it.
{ set +x; } 2>/dev/null

if [[ -f /run/.containerenv ]] && command -v distrobox-host-exec >/dev/null 2>&1; then
  PODMAN=(distrobox-host-exec podman)
else
  PODMAN=(podman)
fi
if [[ -n "${ATELIER_PODMAN:-}" ]]; then
  # shellcheck disable=SC2206
  PODMAN=(${ATELIER_PODMAN})
fi
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
# The default secret name is part of the Meute contract (README.md) --
# Meute consumes it by this exact name. Override only for tests.
CLAUDE_SECRET="${ATELIER_CLAUDE_SECRET:-atelier-claude-token}"
CODEX_VOLUME="${ATELIER_AUTH_VOLUME_CODEX:-atelier-auth-codex}"
EGRESS_CONTAINER="${ATELIER_EGRESS_HOST:-atelier-egress}"
EGRESS_NETWORK="${ATELIER_EGRESS_NET:-atelier-internal}"
EGRESS_PORT="${ATELIER_EGRESS_PORT:-3128}"
GH_VOLUMES=(atelier-auth-gh atelier-auth-gh-publish atelier-auth-gh-review)

usage() {
  echo "usage: $0 claude | codex | gh <volume>   (gh volume: one of ${GH_VOLUMES[*]})" >&2
  exit 2
}

# Same hardened set agent containers run with (AUDIT.md §4.3, including
# --init and --pids-limit), plus --read-only. `codex login --help` and
# `codex login --device-auth` were run under these flags on 2026-09-27:
# help exits 0, and device-auth reached the device-code prompt through
# the proxy, so these two tmpfs mounts are all codex's login needs. gh
# additionally gets GH_EXTRA_FLAGS (see login_gh).
hardened_flags() {
  HARDENED_FLAGS=(
    --userns=keep-id:uid=1000,gid=1000
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --init
    --pids-limit=2048
    --read-only
    --tmpfs /tmp
    --tmpfs /home/agent/.cache
  )
}

# The same preflight and flags as agent-enter.sh's proxied profile
# (check_network_preflight, egress_ip_on_network, add_proxy_flags): the
# codex and gh logins both need auth.openai.com / api.github.com, which
# are on the allow-list. Claude's browser flow is NOT, which is why that
# one runs on the host instead -- the allow-list is not widened for it.
proxy_flags() {
  local proxy_url="http://${EGRESS_CONTAINER}:${EGRESS_PORT}" egress_ip
  # String compare, not `| grep -q true`: grep -q exits at the first
  # match, and under pipefail the writer's SIGPIPE can fail the pipeline.
  if [[ "$("${PODMAN[@]}" inspect "$EGRESS_CONTAINER" --format '{{.State.Running}}' 2>/dev/null </dev/null)" != "true" ]]; then
    echo "auth-login: this login needs ${EGRESS_CONTAINER} running (it goes through the egress proxy); run: just egress-up" >&2
    exit 1
  fi
  if ! "${PODMAN[@]}" network exists "$EGRESS_NETWORK" 2>/dev/null </dev/null; then
    echo "auth-login: network ${EGRESS_NETWORK} does not exist; run: just egress-up" >&2
    exit 1
  fi
  egress_ip="$("${PODMAN[@]}" inspect "$EGRESS_CONTAINER" \
    --format "{{with index .NetworkSettings.Networks \"${EGRESS_NETWORK}\"}}{{.IPAddress}}{{end}}" 2>/dev/null </dev/null)" || egress_ip=""
  if [[ -z "$egress_ip" ]]; then
    echo "auth-login: could not determine ${EGRESS_CONTAINER}'s address on ${EGRESS_NETWORK}; run: just egress-up" >&2
    exit 1
  fi
  PROXY_FLAGS=(
    --network="$EGRESS_NETWORK"
    --add-host "${EGRESS_CONTAINER}:${egress_ip}"
    -e "HTTPS_PROXY=${proxy_url}" -e "https_proxy=${proxy_url}"
    -e "HTTP_PROXY=${proxy_url}" -e "http_proxy=${proxy_url}"
    -e "NO_PROXY=localhost,127.0.0.1" -e "no_proxy=localhost,127.0.0.1"
  )
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
login_codex() {
  hardened_flags
  proxy_flags
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
  proxy_flags
  # gh writes ~/.local/state/gh/device-id on every run, even a failed
  # login (found 2026-09-27 with `find -newer` in a writable container);
  # without this tmpfs that write hits the read-only rootfs.
  GH_EXTRA_FLAGS=(--tmpfs /home/agent/.local/state)
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
    "${HARDENED_FLAGS[@]}" "${GH_EXTRA_FLAGS[@]}" "${PROXY_FLAGS[@]}" \
    -v "${STAGING_VOLUME}:/home/agent/.config/gh:z" \
    "$IMAGE" \
    gh auth login --with-token --hostname github.com --git-protocol https --insecure-storage \
    | cat
  "${PODMAN[@]}" run --rm \
    "${HARDENED_FLAGS[@]}" "${GH_EXTRA_FLAGS[@]}" "${PROXY_FLAGS[@]}" \
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
