#!/usr/bin/env bash
# Static test (no podman needed): the Justfile's egress variables must agree
# with the ATELIER_EGRESS_* overrides that scripts/lib/atelier-common.sh and
# the smoke suites honor, and must not carry dead variables.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fails=0
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; fails=$((fails+1)); fi
}
check "default egress_container" "atelier-egress" "$(just --evaluate egress_container)"
check "default egress_network" "atelier-internal" "$(just --evaluate egress_network)"
check "ATELIER_EGRESS_HOST overrides egress_container" "my-proxy" "$(ATELIER_EGRESS_HOST=my-proxy just --evaluate egress_container)"
check "ATELIER_EGRESS_NET overrides egress_network" "my-net" "$(ATELIER_EGRESS_NET=my-net just --evaluate egress_network)"
# tinyproxy.conf hard-codes the listen port, so a Justfile egress_port would be dead.
if just --evaluate 2>/dev/null | grep -q '^egress_port'; then
  echo "FAIL: dead Justfile variable egress_port still defined"; fails=$((fails+1))
else echo "PASS: no dead egress_port variable"; fi
[[ "$fails" -eq 0 ]]
