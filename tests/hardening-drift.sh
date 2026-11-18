#!/usr/bin/env bash
# tests/hardening-drift.sh -- unit test (fake podman, no containers needed)
# for hardening-flag drift detection on container reuse.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/scripts/lib/atelier-common.sh"
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

FP="$(hardening_fingerprint)"
LABEL_VALUE=""
PODMAN=(fake_podman)
fake_podman() { printf '%s' "$LABEL_VALUE"; }

LABEL_VALUE="$FP"
check_hardening_drift c 2>/dev/null && ok "matching fingerprint accepted" || bad "matching fingerprint rejected"
LABEL_VALUE=""
check_hardening_drift c 2>/dev/null && bad "missing label accepted" || ok "missing label is drift"
LABEL_VALUE="deadbeef"
check_hardening_drift c 2>/dev/null && bad "stale fingerprint accepted" || ok "stale fingerprint is drift"

orig="$(declare -f hardened_flags)"
hardened_flags() { HARDENED_FLAGS=(--cap-drop=ALL); }
[[ "$(hardening_fingerprint)" != "$FP" ]] && ok "fingerprint changes with the flags" || bad "fingerprint unchanged after flag change"
eval "$orig"
exit "$((fails > 0))"
