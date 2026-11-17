#!/usr/bin/env bash
# Static check (no podman needed): the egress subnet has ONE source, the
# `egress_subnet` variable in the Justfile. tinyproxy.conf must carry only
# a placeholder, and build-egress must feed the Justfile value into the
# image build. Run directly: tests/egress-subnet.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${REPO_ROOT}/containers/egress-proxy/tinyproxy.conf"
CONTAINERFILE="${REPO_ROOT}/containers/egress-proxy/Containerfile"
JUSTFILE="${REPO_ROOT}/Justfile"
fail=0

check() { # description, command...
  local desc="$1"; shift
  if "$@"; then echo "PASS: ${desc}"; else echo "FAIL: ${desc}"; fail=1; fi
}

subnet="$(sed -n 's/^egress_subnet := "\(.*\)"$/\1/p' "$JUSTFILE")"
check "Justfile defines egress_subnet" test -n "$subnet"
check "tinyproxy.conf has no hardcoded subnet Allow" \
  bash -c '! grep -Eq "^Allow +[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+" "$1"' _ "$CONF"
check "tinyproxy.conf Allow uses the @EGRESS_SUBNET@ placeholder" \
  grep -q '^Allow @EGRESS_SUBNET@$' "$CONF"
check "Containerfile substitutes the placeholder from the EGRESS_SUBNET build arg" \
  grep -q 'EGRESS_SUBNET' "$CONTAINERFILE"
check "build-egress passes egress_subnet as the EGRESS_SUBNET build arg" \
  grep -q -- '--build-arg "EGRESS_SUBNET={{egress_subnet}}"' "$JUSTFILE"

exit "$fail"
