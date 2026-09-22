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

if [[ -f /run/.containerenv ]] && command -v distrobox-host-exec >/dev/null 2>&1; then
  PODMAN=(distrobox-host-exec podman)
else
  PODMAN=(podman)
fi
if [[ -n "${ATELIER_PODMAN:-}" ]]; then
  # shellcheck disable=SC2206
  PODMAN=(${ATELIER_PODMAN})
fi

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
if "${PODMAN[@]}" volume exists "$volume" 2>/dev/null; then
  "${PODMAN[@]}" volume rm "$volume" >/dev/null
fi
"${PODMAN[@]}" volume create "$volume" >/dev/null

# --network=none unconditionally: this container only ever needs to
# extract a tar stream into a volume, and $ATELIER_AUTH_IMAGE is
# operator-overridable (for tests/smoke.sh's throwaway-image case). A
# malicious or mistaken override image could otherwise read the
# credential tar as it arrives on stdin and exfiltrate it over the
# network while `tar -xf` is running; no network is ever a legitimate
# requirement for this step (Codex LOW, 2026-09-22).
tar -cf - -C "$(dirname "$src")" "$(basename "$src")" \
  | "${PODMAN[@]}" run --rm -i \
      --network=none \
      --userns=keep-id:uid=1000,gid=1000 \
      --cap-drop=ALL \
      --security-opt=no-new-privileges \
      -v "${volume}:/dest" \
      "$IMAGE" \
      tar -xf - -C /dest

echo "auth-import: imported $(basename "$src") into volume ${volume}"
