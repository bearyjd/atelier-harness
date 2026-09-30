#!/usr/bin/env bash
# scripts/auth-import.sh <volume-name> <source-file>
#
# Imports a single credential file into a named Podman volume so it lands
# owned by container uid 1000 -- readable and writable under the real
# `--userns=keep-id:uid=1000,gid=1000` flag set agent containers actually
# run with (AUDIT.md §4.3).
#
# WHY NOT `podman volume import`: it extracts the tar in Podman's default
# rootless user-namespace mapping, not keep-id's. A file tarred with
# `--owner=1000` lands as container uid 999 when later viewed inside a
# `--userns=keep-id:uid=1000,gid=1000` container -- a namespace-offset
# mismatch between `podman volume import`'s own extraction path and the
# mapping agent containers actually use. Verified empirically 2026-09-21:
# the agent user got "Permission denied" reading its own imported
# credentials. Streaming the tar into a `podman run` that uses the SAME
# `--userns=keep-id` flags as agent containers do sidesteps the mismatch
# entirely, because it's the identical mapping doing the extraction.
#
# Used by: `just auth` (real credentials) and tests/smoke.sh (a throwaway
# dummy file into a throwaway volume -- this script never sees or needs
# real credentials to be exercised by the smoke suite).
set -euo pipefail

# Only resolve_podman is used from the shared lib: this script's container
# is deliberately NOT the hardened agent set (no --read-only, no proxy).
# Locating the lib FAILS CLOSED (security review, 2026-09-30): fed on
# stdin (`bash < auth-import.sh`) BASH_SOURCE[0] is empty, and the old
# `dirname "$(readlink -f "")"` quietly became "." -- the CWD -- so a
# lib/atelier-common.sh in whatever directory the caller stood in would
# have been sourced. Separate assignments, so errexit sees each failure.
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  echo "auth-import: cannot locate this script (BASH_SOURCE is empty); run it as a file from the repo checkout, not on stdin" >&2
  exit 1
fi
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ATELIER_LIB="${SELF_PATH%/*}/lib/atelier-common.sh"
if [[ "$ATELIER_LIB" != /* || ! -f "$ATELIER_LIB" ]]; then
  echo "auth-import: missing ${ATELIER_LIB}; run from the repo checkout" >&2
  exit 1
fi
# shellcheck source=scripts/lib/atelier-common.sh
source "$ATELIER_LIB"
resolve_podman

IMAGE="${ATELIER_AUTH_IMAGE:-agent-base:latest}"

usage() {
  echo "usage: $0 <volume-name> <source-file>" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
volume="$1"
src="$2"

if [[ ! -f "$src" ]]; then
  echo "auth-import: source file not found, skipping: ${src}" >&2
  exit 1
fi

# Remove and recreate rather than import-on-top: `podman volume import` is
# additive, not replacing. Verified 2026-09-21 by importing a second file
# into a volume that already held a first one -- both survived. A rotated
# credential must not leave the stale file behind, so re-runs of this
# script replace the volume's entire contents.
# `</dev/null` on these three: STDIN RULE (see the `| cat` comment below)
# -- none of them reads stdin, and in pty mode any of them would eat it.
if "${PODMAN[@]}" volume exists "$volume" 2>/dev/null </dev/null; then
  "${PODMAN[@]}" volume rm "$volume" >/dev/null </dev/null
fi
"${PODMAN[@]}" volume create "$volume" >/dev/null </dev/null

# --network=none unconditionally: this container only ever needs to
# extract a tar stream into a volume, and $ATELIER_AUTH_IMAGE is
# operator-overridable (for tests/smoke.sh's throwaway-image case). A
# malicious or mistaken override image could otherwise read the
# credential tar as it arrives on stdin and exfiltrate it over the
# network while `tar -xf` is running; no network is ever a legitimate
# requirement for this step (Codex LOW, 2026-09-22).
#
# :z (shared label), not unflagged: an unflagged mount only works while
# nothing has ever :Z-mounted this volume. These volumes are read by both
# agent-enter.sh (interactive) and Meute's unattended containers by
# design, so whichever mounts first with :Z (a private MCS category)
# poisons it for the other -- reproduced 2026-09-23. :z resets the volume
# to the shared container_file_t:s0 label on every import, so an import
# never leaves private categories behind for whoever reads it next.
#
# The trailing `| cat` is load-bearing, not cosmetic: stdout of a
# stdin-fed podman call must NEVER be a TTY. Inside the `dev` distrobox,
# distrobox-host-exec runs host-spawn WITH a pty whenever its stdout is a
# TTY (--no-pty only for `[ ! -t 1 ]`); the credential tar piped on stdin
# is then echoed to the terminal in cleartext and EOF never reaches the
# container, so the import hangs. Reproduced 2026-09-27 (review canary);
# tests/smoke.sh section 4d runs this script under a real pty to guard it.
tar -cf - -C "$(dirname "$src")" "$(basename "$src")" \
  | "${PODMAN[@]}" run --rm -i \
      --network=none \
      --userns=keep-id:uid=1000,gid=1000 \
      --cap-drop=ALL \
      --security-opt=no-new-privileges \
      -v "${volume}:/dest:z" \
      "$IMAGE" \
      tar -xf - -C /dest \
  | cat

echo "auth-import: imported $(basename "$src") into volume ${volume}"
