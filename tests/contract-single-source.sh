#!/usr/bin/env bash
# tests/contract-single-source.sh -- podman-free static check that the
# credential-volume contract (volume names, in-container mount paths, the
# :z label) is defined once, in scripts/lib/atelier-common.sh, and that
# agent-enter.sh / auth-login.sh consume it instead of re-spelling it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"
# shellcheck source=tests/lib/smoke-common.sh
source "${REPO_ROOT}/tests/lib/smoke-common.sh"
LIB="${REPO_ROOT}/scripts/lib/atelier-common.sh"
SCRIPTS=("${REPO_ROOT}/scripts/agent-enter.sh" "${REPO_ROOT}/scripts/auth-login.sh")

# 1. The lib exposes the contract.
# shellcheck source=scripts/lib/atelier-common.sh
source "$LIB"
if [[ "${AUTH_VOLUME_CLAUDE:-}" == "atelier-auth-claude" && "${AUTH_VOLUME_CODEX:-}" == "atelier-auth-codex" \
  && "${AUTH_VOLUME_GH:-}" == "atelier-auth-gh" && "${#GH_VOLUMES[@]}" -eq 3 \
  && "${AUTH_MOUNT_CLAUDE:-}" == "/home/agent/.claude" && "${AUTH_MOUNT_CODEX:-}" == "/home/agent/.codex" \
  && "${AUTH_MOUNT_GH:-}" == "/home/agent/.config/gh" && "${AUTH_VOLUME_OPTS:-}" == "z" ]]; then
  pass "lib defines volume names, mount paths and mount options"
else
  fail "lib is missing the credential-volume contract constants"
fi

# 2. The consumers do not re-spell it.
for s in "${SCRIPTS[@]}"; do
  name="${s##*/}"
  if grep -vE '^\s*#' "$s" | grep -qE 'atelier-auth-(claude|codex|gh)|/home/agent/\.(claude|codex)|/home/agent/\.config/gh'; then
    fail "${name} hardcodes credential volume names or mount paths"
  else
    pass "${name} consumes the contract from the lib"
  fi
done

print_summary
[[ "$FAIL_COUNT" -eq 0 ]]
