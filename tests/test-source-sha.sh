#!/usr/bin/env bash
# Hermetic test (no podman) that the overlay image's SOURCE_SHA input set is
# defined once, in scripts/source-sha.sh (`--overlay <project>`), and that
# neither the Justfile `build` recipe nor agent-enter.sh re-enumerates
# agent-base's files themselves. Run directly: tests/test-source-sha.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
fail=0
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi
}

base_files=()
while IFS= read -r -d '' f; do base_files+=("$f"); done < <(find containers/agent-base -type f -print0)
expected="$(./scripts/source-sha.sh containers/example "${base_files[@]}")"
actual="$(./scripts/source-sha.sh --overlay example 2>/dev/null)"

check "--overlay <project> hashes overlay dir plus all agent-base files" \
  test -n "$actual" -a "$actual" = "$expected"
check "Justfile does not enumerate agent-base files itself" \
  bash -c '! grep -q "find containers/agent-base" Justfile'
check "agent-enter.sh does not enumerate agent-base files itself" \
  bash -c '! grep -q "find containers/agent-base" scripts/agent-enter.sh'

exit "$fail"
