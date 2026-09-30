# shellcheck shell=bash
# SC2034: the globals set here (CLAUDE_SECRET, HARDENED_FLAGS, ...) ARE the
# interface; they are read by the scripts that source this file.
# shellcheck disable=SC2034
# scripts/lib/atelier-common.sh -- SOURCED, never executed.
#
# The pieces agent-enter.sh and auth-login.sh (and, for the podman routing
# only, auth-import.sh) used to carry as hand-kept duplicates -- factored
# out 2026-09-30, after the copies had already drifted once: agent-enter's
# egress check still used `| grep -q true` (a SIGPIPE hazard under
# pipefail) while auth-login's had been fixed to a string compare.
#
# Contract for callers: set `set -euo pipefail` yourself (this file sets no
# shell options), source it by an ABSOLUTE path derived from the script's
# own readlink -f'd location -- failing closed if BASH_SOURCE[0] is empty
# (script fed on stdin), never falling back to the CWD -- then call
# resolve_podman. Re-sourcing is harmless (plain assignments and function
# definitions only), so there is no include guard. User-facing messages and exit codes stay in the
# callers -- tests assert each script's own wording (tests/smoke.sh 4c,
# tests/smoke-enter.sh 11), so only predicates and flag builders live here.
#
# NOT an image input: scripts/source-sha.sh hashes containers/ only (the
# Justfile's build recipes pass nothing under scripts/), so editing this
# file never marks an image stale or changes a tag.
#
# STDIN RULE: every podman call in here gets `</dev/null` -- see the
# header of agent-enter.sh / auth-login.sh for why (pty-mode host-spawn
# swallows the caller's stdin).

# --- Constants (env-overridable; names are part of the docs/tests) --------
# The default secret name is part of the Meute contract (README.md) --
# Meute consumes it by this exact name. The override exists only so the
# smoke suites never touch the owner's real token.
ATELIER_DEFAULT_CLAUDE_SECRET="atelier-claude-token"
CLAUDE_SECRET="${ATELIER_CLAUDE_SECRET:-${ATELIER_DEFAULT_CLAUDE_SECRET}}"
EGRESS_CONTAINER="${ATELIER_EGRESS_HOST:-atelier-egress}"
EGRESS_NETWORK="${ATELIER_EGRESS_NET:-atelier-internal}"
EGRESS_PORT="${ATELIER_EGRESS_PORT:-3128}"

# --- podman routing (AUDIT.md §4.4) ---------------------------------------
# `podman` is only a shell alias to `distrobox-host-exec podman` inside the
# `dev` distrobox; aliases don't expand in scripts. ATELIER_PODMAN wins
# over both (word-split on purpose: it may be a wrapper plus arguments).
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

# --- Hardened base flags (AUDIT.md §4.3, plus --read-only) ----------------
# The set every Atelier-run container shares: agent-enter.sh adds its
# per-project mounts and extra tmpfs on top, auth-login.sh uses it as is.
# Sets HARDENED_FLAGS.
#
# TMPFS OWNERSHIP (2026-09-30): every tmpfs under /home/agent takes `:U`
# (chown to the container user). Without it Podman creates the tmpfs as
# root, and where the image already has the directory (tmpcopyup) it
# keeps that dir's mode -- /home/agent/.local/share came up root:root 755,
# NOT writable by agent (touch: Permission denied); the others happened to
# be root 1777. Probed on podman 5.8.7 under keep-id + --read-only:
# `--tmpfs P:mode=1777` also works but leaves root the owner; `--tmpfs P:U`
# and `--mount type=tmpfs,destination=P,U` both give agent ownership. `:U`
# chowns the tmpfs only: a volume mounted beneath it (.config/gh) kept its
# agent 0600 files. /tmp stays the stock root 1777, like any /tmp.
# .local/state: gh 2.97 writes ~/.local/state/gh/device-id on every run --
# silently dropped on a read-only root (see agent-enter.sh STATE TMPFS).
hardened_flags() {
  HARDENED_FLAGS=(
    --userns=keep-id:uid=1000,gid=1000
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --init
    --pids-limit=2048
    --read-only
    --tmpfs /tmp
    --tmpfs /home/agent/.cache:U
    --tmpfs /home/agent/.local/state:U
  )
}

# --- Egress proxy (AUDIT.md §4.2) -----------------------------------------
# String compare, not `| grep -q true`: grep -q exits at the first match,
# and under pipefail the writer's SIGPIPE can fail the pipeline.
egress_is_running() {
  [[ "$("${PODMAN[@]}" inspect "$EGRESS_CONTAINER" --format '{{.State.Running}}' 2>/dev/null </dev/null)" == "true" ]]
}

# atelier-internal is created with --disable-dns (Justfile egress-up):
# Podman used to order /etc/resolv.conf's nameservers non-deterministically
# when a container joined two networks, and the network's own aardvark-dns
# entry racing the injected --dns entries made agent-base's DNS unreliable.
# With DNS disabled nothing resolves "atelier-egress" on that network, so
# proxy_flags maps it with --add-host, reading the proxy's actual IP from
# the running container rather than a second copy of the Justfile's
# egress_ip constant that could drift. Prints the IP, or nothing.
egress_ip_on_network() {
  "${PODMAN[@]}" inspect "$EGRESS_CONTAINER" \
    --format "{{with index .NetworkSettings.Networks \"${EGRESS_NETWORK}\"}}{{.IPAddress}}{{end}}" 2>/dev/null </dev/null
}

# Sets PROXY_FLAGS for a proxied container, given the proxy's IP on
# EGRESS_NETWORK (the caller looks it up and owns the error message).
proxy_flags() {
  local egress_ip="$1" proxy_url="http://${EGRESS_CONTAINER}:${EGRESS_PORT}"
  PROXY_FLAGS=(
    --network="$EGRESS_NETWORK"
    --add-host "${EGRESS_CONTAINER}:${egress_ip}"
    -e "HTTPS_PROXY=${proxy_url}" -e "https_proxy=${proxy_url}"
    -e "HTTP_PROXY=${proxy_url}" -e "http_proxy=${proxy_url}"
    -e "NO_PROXY=localhost,127.0.0.1" -e "no_proxy=localhost,127.0.0.1"
  )
}
