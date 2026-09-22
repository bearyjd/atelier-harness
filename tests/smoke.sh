#!/usr/bin/env bash
# Smoke test for the agent-base image and the atelier-egress proxy:
# asserts the hardened security posture from AUDIT.md §4.3, the toolchain
# pins from §6, and the egress allow-list from §4.2. Run with `just smoke`
# or directly: tests/smoke.sh
#
# Every check prints PASS/FAIL/SKIP with what it checked. Exits non-zero if
# any check FAILs.
#
# By default, if atelier-egress is not running, the suite FAILs rather
# than silently skipping the egress-allow-list checks (a down proxy used
# to produce a clean "0 failed" exit with zero egress coverage, which
# hid exactly the failure mode that matters most). Set SMOKE_BASE_ONLY=1
# to intentionally run only the base-image checks, e.g. before the proxy
# has ever been brought up.
set -euo pipefail

# --- podman wrapper -----------------------------------------------------
# We may be invoked from inside the `dev` distrobox, where `podman` is only
# a shell alias (not expanded in scripts) to distrobox-host-exec podman on
# the host. Detect and route accordingly. AUDIT.md §4.4.
if [[ -f /run/.containerenv ]] && command -v distrobox-host-exec >/dev/null 2>&1; then
  PODMAN=(distrobox-host-exec podman)
else
  PODMAN=(podman)
fi
# Allow an explicit override for anyone wrapping podman differently.
if [[ -n "${ATELIER_PODMAN:-}" ]]; then
  # shellcheck disable=SC2206
  PODMAN=(${ATELIER_PODMAN})
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${SMOKE_IMAGE:-agent-base:latest}"
EGRESS_HOST="${ATELIER_EGRESS_HOST:-atelier-egress}"
EGRESS_NET="${ATELIER_EGRESS_NET:-atelier-internal}"
EGRESS_PORT="${ATELIER_EGRESS_PORT:-3128}"
# A stable public IP used to prove "no route out" / "DNS blocked is not
# the only thing standing between us and the internet" -- a hostname
# lookup failing is not proof of an absent route (critic L3).
PROBE_IP="1.1.1.1"

CLAUDE_VERSION="2.1.278"
CODEX_VERSION="0.155.1"
PI_VERSION="0.73.1"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { printf 'PASS: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
skip() { printf 'SKIP: %s -- %s\n' "$1" "$2"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

BASE_FLAGS=(
  --rm
  --userns=keep-id:uid=1000,gid=1000
  --volume "${WORKDIR}:/work:Z"
  --cap-drop=ALL
  --security-opt=no-new-privileges
  --init
  --pids-limit=2048
)

echo "== agent-base / atelier-egress smoke test =="
echo "image: ${IMAGE}"
echo "podman: ${PODMAN[*]}"
echo

if ! "${PODMAN[@]}" image exists "${IMAGE}" 2>/dev/null; then
  fail "image ${IMAGE} exists locally (build it first: 'just build-base')"
  echo
  echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped =="
  exit 1
fi
pass "image ${IMAGE} exists locally"

# --- 1. Identity, capabilities, no-new-privs, no host files, no sudo ----
IDENTITY_OUT="$("${PODMAN[@]}" run "${BASE_FLAGS[@]}" "${IMAGE}" bash -c '
  echo "UID=$(id -u)"
  echo "USER=$(id -un)"
  echo "CAPBND=$(grep -i CapBnd /proc/self/status | awk "{print \$2}")"
  echo "CAPEFF=$(grep -i CapEff /proc/self/status | awk "{print \$2}")"
  echo "CAPPRM=$(grep -i CapPrm /proc/self/status | awk "{print \$2}")"
  echo "CAPINH=$(grep -i CapInh /proc/self/status | awk "{print \$2}")"
  echo "CAPAMB=$(grep -i CapAmb /proc/self/status | awk "{print \$2}")"
  echo "NNP=$(grep -i NoNewPrivs /proc/self/status | awk "{print \$2}")"
  echo "HOME_VAL=$HOME"
  echo "HOME_MOUNT=$(awk -v h="$HOME" "\$5==h{print \$5}" /proc/self/mountinfo | head -1)"
  for f in .ssh .bash_history .gitconfig .netrc .aws .kube; do
    if [[ -e "$HOME/$f" ]]; then echo "HOSTFILE_FOUND=$f"; fi
  done
  if command -v sudo >/dev/null 2>&1; then echo "SUDO_PRESENT=1"; else echo "SUDO_PRESENT=0"; fi
  SETUID_FILES=$(find / -xdev -perm -4000 -type f 2>/dev/null)
  echo "SETUID_COUNT=$(echo -n "$SETUID_FILES" | grep -c . || true)"
  echo "SETUID_LIST=$(echo "$SETUID_FILES" | tr "\n" "," )"
  echo "HTTP_PROXY_SET=$([[ -v HTTP_PROXY ]] && echo yes || echo no)"
  echo "HTTP_PROXY_VAL=${HTTP_PROXY-__unset__}"
  echo "HTTPS_PROXY_SET=$([[ -v HTTPS_PROXY ]] && echo yes || echo no)"
  echo "HTTPS_PROXY_VAL=${HTTPS_PROXY-__unset__}"
' 2>&1)" || true

get_field() { echo "$IDENTITY_OUT" | grep "^${1}=" | head -1 | cut -d= -f2-; }

UID_VAL="$(get_field UID)"
USER_VAL="$(get_field USER)"
CAPBND_VAL="$(get_field CAPBND)"
CAPEFF_VAL="$(get_field CAPEFF)"
CAPPRM_VAL="$(get_field CAPPRM)"
CAPINH_VAL="$(get_field CAPINH)"
CAPAMB_VAL="$(get_field CAPAMB)"
NNP_VAL="$(get_field NNP)"
HOME_MOUNT_VAL="$(get_field HOME_MOUNT)"
SUDO_PRESENT_VAL="$(get_field SUDO_PRESENT)"
SETUID_COUNT_VAL="$(get_field SETUID_COUNT)"
SETUID_LIST_VAL="$(get_field SETUID_LIST)"
HTTP_PROXY_SET_VAL="$(get_field HTTP_PROXY_SET)"
HTTP_PROXY_VAL_VAL="$(get_field HTTP_PROXY_VAL)"
HTTPS_PROXY_SET_VAL="$(get_field HTTPS_PROXY_SET)"
HTTPS_PROXY_VAL_VAL="$(get_field HTTPS_PROXY_VAL)"
HOSTFILES_FOUND="$(echo "$IDENTITY_OUT" | grep '^HOSTFILE_FOUND=' | cut -d= -f2- || true)"

if [[ "$UID_VAL" == "1000" && "$USER_VAL" != "root" ]]; then
  pass "container runs as uid 1000 (user: ${USER_VAL}), not root"
else
  fail "container runs as uid 1000, not root (got uid=${UID_VAL} user=${USER_VAL})"
fi

# Zero CapBnd alone doesn't prove the effective/permitted/inheritable/
# ambient sets are also empty (Codex LOW, 2026-09-22) -- --cap-drop=ALL
# should empty all five, and this asserts all five, not just the bounding
# set.
CAPS_OK=1
for cap_pair in "CapBnd:$CAPBND_VAL" "CapEff:$CAPEFF_VAL" "CapPrm:$CAPPRM_VAL" "CapInh:$CAPINH_VAL" "CapAmb:$CAPAMB_VAL"; do
  cap_name="${cap_pair%%:*}"
  cap_val="${cap_pair#*:}"
  if [[ ! "$cap_val" =~ ^0+$ ]]; then
    CAPS_OK=0
    fail "${cap_name} is all zeros (got: ${cap_val})"
  fi
done
if [[ "$CAPS_OK" -eq 1 ]]; then
  pass "CapBnd, CapEff, CapPrm, CapInh, and CapAmb are all zero (${CAPBND_VAL})"
fi

if [[ "$NNP_VAL" == "1" ]]; then
  pass "NoNewPrivs is 1"
else
  fail "NoNewPrivs is 1 (got: ${NNP_VAL})"
fi

if [[ -z "$HOSTFILES_FOUND" ]]; then
  pass "/home/agent has no host dotfiles (.ssh, .bash_history, .gitconfig, .netrc, .aws, .kube)"
else
  fail "/home/agent has no host dotfiles (found: ${HOSTFILES_FOUND})"
fi

# Uses /proc/self/mountinfo field 5 (the mount point). Field 2 is the
# parent mount ID, an integer that can never equal a path -- an earlier
# version of this check compared against field 2 and could never fail,
# even with a real volume mounted directly over $HOME (security HIGH /
# critic H1, both caught this independently).
if [[ -z "$HOME_MOUNT_VAL" ]]; then
  pass '$HOME is not a separate mount point'
else
  fail '$HOME is not a separate mount point (mountinfo shows an entry)'
fi

if [[ "$SUDO_PRESENT_VAL" == "0" ]]; then
  pass "no sudo binary present"
else
  fail "no sudo binary present (sudo was found on PATH)"
fi

if [[ "$SETUID_COUNT_VAL" == "0" ]]; then
  pass "no setuid-root binaries present (find / -perm -4000 -type f is empty)"
else
  fail "no setuid-root binaries present (found ${SETUID_COUNT_VAL}: ${SETUID_LIST_VAL})"
fi

if [[ "$HTTP_PROXY_SET_VAL" == "yes" && -z "$HTTP_PROXY_VAL_VAL" ]]; then
  pass "HTTP_PROXY env var exists and is empty by default"
else
  fail "HTTP_PROXY env var exists and is empty by default (set=${HTTP_PROXY_SET_VAL} val='${HTTP_PROXY_VAL_VAL}')"
fi

if [[ "$HTTPS_PROXY_SET_VAL" == "yes" && -z "$HTTPS_PROXY_VAL_VAL" ]]; then
  pass "HTTPS_PROXY env var exists and is empty by default"
else
  fail "HTTPS_PROXY env var exists and is empty by default (set=${HTTPS_PROXY_SET_VAL} val='${HTTPS_PROXY_VAL_VAL}')"
fi

# --- 2. CLI presence / version pins --------------------------------------
# claude, codex, pi are genuinely pinned (ARGs in the Containerfile), so
# their exact versions are asserted. gh and git are NOT pinned -- they
# ride whatever the Fedora 44 base digest ships -- so asserting an exact
# version trains people to edit the expected string on every base bump
# instead of it meaning anything (security MEDIUM / critic M1, both
# flagged the earlier version doing this). Only presence-and-parses is
# checked for those two.
# pi-flow's version is checked via `npm ls @kky42/pi-flow --json` against
# its LOCAL project directory (/home/agent/.local/lib/atelier-npm), not
# `npm ls -g` -- codex/pi/pi-flow no longer install in npm's global mode
# (see Containerfile: `npm ci` has no `-g`, it manages one project
# directory's own node_modules from a lockfile). node itself parses the
# JSON (via require(), reading a file rather than piping a JSON blob
# through grep) so a shape change in npm's own output doesn't silently
# produce an empty-string false pass.
VERSIONS_OUT="$("${PODMAN[@]}" run "${BASE_FLAGS[@]}" "${IMAGE}" bash -c '
  export PATH="$HOME/.local/bin:$PATH"
  claude --version >/tmp/claude.out 2>&1; echo "CLAUDE_EXIT=$?"
  echo "CLAUDE_OUT=$(cat /tmp/claude.out)"
  codex --version >/tmp/codex.out 2>&1; echo "CODEX_EXIT=$?"
  echo "CODEX_OUT=$(cat /tmp/codex.out)"
  pi --version >/tmp/pi.out 2>&1; echo "PI_EXIT=$?"
  echo "PI_OUT=$(cat /tmp/pi.out)"
  gh --version >/tmp/gh.out 2>&1; echo "GH_EXIT=$?"
  echo "GH_OUT=$(head -1 /tmp/gh.out)"
  git --version >/tmp/git.out 2>&1; echo "GIT_EXIT=$?"
  echo "GIT_OUT=$(cat /tmp/git.out)"
  echo "PI_SYMLINK=$(readlink -f "$HOME/.local/bin/pi")"
  ( cd "$HOME/.local/lib/atelier-npm" && npm ls @kky42/pi-flow --json > /tmp/piflow.json 2>&1 )
  echo "PIFLOW_VERSION=$(node -e "
    try {
      const d = require(\"/tmp/piflow.json\");
      const v = d.dependencies && d.dependencies[\"@kky42/pi-flow\"] && d.dependencies[\"@kky42/pi-flow\"].version;
      console.log(v || \"\");
    } catch (e) { console.log(\"\"); }
  ")"
' 2>&1)" || true

version_check() {
  local name="$1" expected="$2"
  local exit_val out_val
  exit_val="$(echo "$VERSIONS_OUT" | grep "^${name}_EXIT=" | cut -d= -f2-)"
  out_val="$(echo "$VERSIONS_OUT" | grep "^${name}_OUT=" | cut -d= -f2-)"
  if [[ "$exit_val" == "0" && "$out_val" == *"$expected"* ]]; then
    pass "${name,,} --version exits 0 and reports pinned version ${expected} (got: ${out_val})"
  else
    fail "${name,,} --version exits 0 and reports pinned version ${expected} (exit=${exit_val}, got: ${out_val})"
  fi
}

# gh/git are unpinned (ride the base digest, see above), so only presence
# AND a well-formed version-output grammar are checked -- not just
# "nonempty". A missing binary's "bash: gh: command not found" is
# nonempty too and would have passed the old string-only check (Codex
# LOW, 2026-09-22).
grammar_check() {
  local name="$1" cmd="$2" regex="$3"
  local exit_val out_val
  exit_val="$(echo "$VERSIONS_OUT" | grep "^${name}_EXIT=" | cut -d= -f2-)"
  out_val="$(echo "$VERSIONS_OUT" | grep "^${name}_OUT=" | cut -d= -f2-)"
  if [[ "$exit_val" == "0" && "$out_val" =~ $regex ]]; then
    pass "${cmd} --version exits 0 and matches expected version grammar (got: ${out_val})"
  else
    fail "${cmd} --version exits 0 and matches expected version grammar (exit=${exit_val}, got: ${out_val})"
  fi
}

version_check CLAUDE "$CLAUDE_VERSION"
version_check CODEX "$CODEX_VERSION"
version_check PI "$PI_VERSION"
grammar_check GH gh '^gh version [0-9]+\.[0-9]+\.[0-9]+'
grammar_check GIT git '^git version [0-9]+\.[0-9]+\.[0-9]+'

# The `pi` symlink must resolve into @mariozechner/pi-coding-agent
# specifically. node_modules/.bin/pi (not used here, see Containerfile)
# resolved to @earendil-works/pi-coding-agent instead -- a DIFFERENT
# package that also ships a `pi` bin and won npm's hoisting. `pi
# --version` returning "0.73.1" cannot by itself distinguish the pinned
# package from that other one if they ever report the same version
# string; this checks the actual symlink target, which is the assertion
# that would have caught the mismatch (advisor review, 2026-09-22).
PI_SYMLINK_VAL="$(echo "$VERSIONS_OUT" | grep '^PI_SYMLINK=' | cut -d= -f2-)"
if [[ "$PI_SYMLINK_VAL" == *"@mariozechner/pi-coding-agent"* ]]; then
  pass "~/.local/bin/pi resolves into @mariozechner/pi-coding-agent, not a same-named bin from another package (${PI_SYMLINK_VAL})"
else
  fail "~/.local/bin/pi resolves into @mariozechner/pi-coding-agent (got: ${PI_SYMLINK_VAL})"
fi

PIFLOW_VERSION_VAL="$(echo "$VERSIONS_OUT" | grep '^PIFLOW_VERSION=' | cut -d= -f2-)"
if [[ "$PIFLOW_VERSION_VAL" == "3.1.3" ]]; then
  pass "@kky42/pi-flow is exactly version 3.1.3 (it ships no executable -- it's a library pi consumes, not a CLI)"
else
  fail "@kky42/pi-flow is exactly version 3.1.3 (got: '${PIFLOW_VERSION_VAL}')"
fi

# --- 3. Network isolation (--network=none) -------------------------------
# Checks both DNS (a name never resolves) and a raw IP (no route exists
# at all) -- DNS failing alone does not prove the absence of a route
# (critic L3); a raw-IP curl failing with exit 7 ("couldn't connect")
# proves there is genuinely nowhere for the packets to go.
NETNONE_OUT="$("${PODMAN[@]}" run "${BASE_FLAGS[@]}" --network=none "${IMAGE}" bash -c '
  if getent hosts example.com >/dev/null 2>&1; then
    echo "RESOLVED=1"
  else
    echo "RESOLVED=0"
  fi
  curl -sS --max-time 5 -o /dev/null "'"http://${PROBE_IP}"'/" 2>/dev/null
  echo "RAWIP_EXIT=$?"
' 2>&1)" || true

if echo "$NETNONE_OUT" | grep -q '^RESOLVED=0$'; then
  pass "with --network=none, DNS resolution of example.com fails"
else
  fail "with --network=none, DNS resolution of example.com fails (output: ${NETNONE_OUT})"
fi

RAWIP_EXIT_NONE="$(echo "$NETNONE_OUT" | grep '^RAWIP_EXIT=' | cut -d= -f2-)"
if [[ "$RAWIP_EXIT_NONE" == "7" ]]; then
  pass "with --network=none, a raw-IP curl to ${PROBE_IP} fails with exit 7 (no route)"
else
  fail "with --network=none, a raw-IP curl to ${PROBE_IP} fails with exit 7 (got exit=${RAWIP_EXIT_NONE})"
fi

# --- 4. Auth volume import path (throwaway files + volume, never real
#        credentials) ------------------------------------------------------
# Exercises scripts/auth-import.sh end to end, TWICE against the same
# volume with two distinct probe files: a dummy credential-shaped file
# (mode 0600, matching AUDIT.md §2's note that the real files are all
# 0600) goes into a throwaway volume, then is read back as uid 1000 under
# the same --userns=keep-id flags agent containers actually run with.
# `podman volume import` (the more obvious tool) was the C1/blocking
# finding in the first review round: it extracts in a different user
# namespace than keep-id, so the file landed unreadable by uid 1000.
#
# The SECOND import (Codex LOW, 2026-09-22) is what actually proves the
# "each run replaces rather than accumulates" claim made elsewhere in
# this repo: importing once and reading it back only shows the import
# path works, not that a re-import (the real-world case -- a rotated
# token) removes the stale file rather than leaving it alongside the new
# one.
AUTH_PROBE_VOLUME="atelier-smoke-auth-probe-$$"
AUTH_PROBE_FILE_A="${WORKDIR}/auth-probe-a.json"
AUTH_PROBE_FILE_B="${WORKDIR}/auth-probe-b.json"
printf '{"probe":"a"}' > "${AUTH_PROBE_FILE_A}"
chmod 600 "${AUTH_PROBE_FILE_A}"
printf '{"probe":"b"}' > "${AUTH_PROBE_FILE_B}"
chmod 600 "${AUTH_PROBE_FILE_B}"

AUTH_IMPORT_OK=0
if ATELIER_PODMAN="${PODMAN[*]}" "${REPO_ROOT}/scripts/auth-import.sh" "${AUTH_PROBE_VOLUME}" "${AUTH_PROBE_FILE_A}" >/dev/null 2>&1 \
   && ATELIER_PODMAN="${PODMAN[*]}" "${REPO_ROOT}/scripts/auth-import.sh" "${AUTH_PROBE_VOLUME}" "${AUTH_PROBE_FILE_B}" >/dev/null 2>&1; then
  AUTH_READ_OUT="$("${PODMAN[@]}" run --rm \
    --userns=keep-id:uid=1000,gid=1000 --cap-drop=ALL --security-opt=no-new-privileges \
    -v "${AUTH_PROBE_VOLUME}:/home/agent/.claude" \
    "${IMAGE}" bash -c '
      ls -la /home/agent/.claude 2>&1
      stat -c "%a %U" /home/agent/.claude/auth-probe-b.json 2>&1
      cat /home/agent/.claude/auth-probe-b.json 2>&1
    ' 2>&1)" || true
  if [[ "$AUTH_READ_OUT" == *"600 agent"* \
     && "$AUTH_READ_OUT" == *'"probe":"b"'* \
     && "$AUTH_READ_OUT" != *"auth-probe-a.json"* ]]; then
    AUTH_IMPORT_OK=1
  fi
fi
"${PODMAN[@]}" volume rm "${AUTH_PROBE_VOLUME}" >/dev/null 2>&1 || true

if [[ "$AUTH_IMPORT_OK" -eq 1 ]]; then
  pass "scripts/auth-import.sh: two sequential imports into the same volume leave only the second probe (rotation replaces, does not accumulate)"
else
  fail "scripts/auth-import.sh: two sequential imports into the same volume leave only the second probe (got: ${AUTH_READ_OUT:-<import failed>})"
fi

# --- 5. Only the three expected paths are mounted under $HOME -----------
# A container with the three auth volumes actually mounted must show
# exactly those three mount points under $HOME, and $HOME itself must
# still not be a separate mount point. This is the meaningful version of
# check 1's $HOME-mount assertion: it proves the legitimate exception
# (named auth volumes at known sub-paths) doesn't silently widen into
# "anything can be mounted under $HOME" (critic H1's fix suggestion).
declare -a AUTH_MOUNT_VOLUMES=("atelier-smoke-mnt-claude-$$" "atelier-smoke-mnt-codex-$$" "atelier-smoke-mnt-gh-$$")
for v in "${AUTH_MOUNT_VOLUMES[@]}"; do
  "${PODMAN[@]}" volume create "$v" >/dev/null
done

MOUNT_OUT="$("${PODMAN[@]}" run --rm \
  --userns=keep-id:uid=1000,gid=1000 --cap-drop=ALL --security-opt=no-new-privileges \
  -v "${AUTH_MOUNT_VOLUMES[0]}:/home/agent/.claude" \
  -v "${AUTH_MOUNT_VOLUMES[1]}:/home/agent/.codex" \
  -v "${AUTH_MOUNT_VOLUMES[2]}:/home/agent/.config/gh" \
  "${IMAGE}" bash -c 'awk -v h="$HOME" '"'"'index($5, h) == 1 {print $5}'"'"' /proc/self/mountinfo | sort -u' 2>&1)" || true

for v in "${AUTH_MOUNT_VOLUMES[@]}"; do
  "${PODMAN[@]}" volume rm "$v" >/dev/null 2>&1 || true
done

EXPECTED_MOUNTS=$'/home/agent/.claude\n/home/agent/.codex\n/home/agent/.config/gh'
if [[ "$MOUNT_OUT" == "$EXPECTED_MOUNTS" ]]; then
  pass "exactly the three auth volume paths (.claude, .codex, .config/gh) are mounted under \$HOME, nothing else"
else
  fail "exactly the three auth volume paths are mounted under \$HOME, nothing else (got: $(echo "$MOUNT_OUT" | tr '\n' ';'))"
fi

# --- 6. atelier-egress image: entrypoint.sh rejects an IP-literal
#        allow-list entry -------------------------------------------------
# Only needs the image, not a running proxy -- runs unconditionally
# whenever atelier-egress:latest exists. Mounts a crafted allowlist.d
# containing "10.88.0.1" (the default podman bridge gateway) in place of
# the image's own baked-in allowlist and asserts the container refuses to
# start AND that it fails for the validator's own stated reason, not for
# some unrelated error (e.g. a permission problem reading the bind mount)
# that would also exit non-zero but prove nothing about the validator
# (Codex MEDIUM, entrypoint.sh:69, 2026-09-22).
if "${PODMAN[@]}" image exists atelier-egress:latest 2>/dev/null; then
  BAD_ALLOWLIST_DIR="${WORKDIR}/bad-allowlist"
  mkdir -p "${BAD_ALLOWLIST_DIR}"
  chmod 755 "${BAD_ALLOWLIST_DIR}"
  echo "10.88.0.1" > "${BAD_ALLOWLIST_DIR}/00-bad.txt"
  chmod 644 "${BAD_ALLOWLIST_DIR}/00-bad.txt"
  BAD_OUT="$("${PODMAN[@]}" run --rm \
    -v "${BAD_ALLOWLIST_DIR}:/etc/tinyproxy/allowlist.d:Z,ro" \
    atelier-egress:latest 2>&1)" && BAD_EXIT=0 || BAD_EXIT=$?
  if [[ "$BAD_EXIT" -ne 0 ]] && echo "$BAD_OUT" | grep -q 'invalid allow-list entry'; then
    pass "atelier-egress entrypoint.sh rejects an IPv4-literal allow-list entry (10.88.0.1, the podman bridge gateway) and exits non-zero"
  else
    fail "atelier-egress entrypoint.sh rejects an IPv4-literal allow-list entry (exit=${BAD_EXIT}, output: ${BAD_OUT})"
  fi
else
  skip "atelier-egress entrypoint.sh rejects an IPv4-literal allow-list entry" "atelier-egress:latest image not built (run 'just build-egress' first)"
fi

# --- 7. Egress proxy checks --------------------------------------------
PROXY_UP=0
if "${PODMAN[@]}" network exists "${EGRESS_NET}" >/dev/null 2>&1; then
  if "${PODMAN[@]}" inspect "${EGRESS_HOST}" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    PROXY_UP=1
  fi
fi

if [[ "$PROXY_UP" -eq 1 ]]; then
  # atelier-internal is created with --disable-dns (the deterministic fix
  # for the resolv.conf nameserver-ordering race documented below): agent
  # containers on it can no longer resolve "atelier-egress" by name via
  # aardvark. Test containers below need the same --add-host workaround
  # production agent containers get, so they can still reach the proxy by
  # the "atelier-egress" name their HTTPS_PROXY/HTTP_PROXY values use.
  # Read once, here, and reused by every podman run below that needs it.
  EGRESS_IP="$("${PODMAN[@]}" inspect "${EGRESS_HOST}" --format '{{(index .NetworkSettings.Networks "'"${EGRESS_NET}"'").IPAddress}}' 2>/dev/null)"
  if [[ -z "$EGRESS_IP" ]]; then
    fail "atelier-egress has an IP address on ${EGRESS_NET} (needed for --add-host now that the network is --disable-dns; got empty)"
    echo
    echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped =="
    exit 1
  fi

  # --- 7a. atelier-egress itself can resolve a public hostname ------------
  # Checked directly and first, separately from the proxy's own CONNECT/
  # HTTP behaviour below: a DNS failure inside atelier-egress otherwise
  # only shows up as "curl got 000 / CONNECT tunnel failed, response 500"
  # on the allow-listed-host check, which looks identical to a filter bug.
  # Asserting resolution directly names the actual failure mode.
  #
  # This is genuinely non-deterministic across container starts (found by
  # the Phase 2 executor, confirmed here over repeated
  # `podman rm -f atelier-egress && just egress-up` cycles): Podman's
  # generated /etc/resolv.conf sometimes places the atelier-internal
  # network's aardvark-dns entry (10.89.x.1) ahead of the --dns entries.
  # aardvark answers a fast, AUTHORITATIVE NXDOMAIN for public hostnames
  # it doesn't know, and glibc's resolver does not fall through past an
  # authoritative answer to try the next nameserver -- so whether this
  # fails depends on network-attachment timing, not on anything in this
  # repo's own files. /etc/resolv.conf cannot be rewritten from inside the
  # running container to force a fix: verified empirically that it is a
  # genuinely read-only mount under --read-only (fails with "Read-only
  # file system" even as uid 0), so the fix belongs wherever
  # `atelier-egress` is actually started -- see README/report for the
  # options and why they weren't applied directly here.
  DNS_OUT="$("${PODMAN[@]}" exec "${EGRESS_HOST}" getent hosts api.github.com 2>&1)"
  DNS_EXIT=$?
  if [[ "$DNS_EXIT" -eq 0 ]]; then
    pass "atelier-egress resolves a public hostname (api.github.com -> ${DNS_OUT})"
  else
    fail "atelier-egress resolves a public hostname (getent exit=${DNS_EXIT}, output: ${DNS_OUT}; see entrypoint.sh/README for the known nameserver-ordering race)"
  fi

  # --- 7b. atelier-internal has no route out, independent of the proxy ---
  NOROUTE_OUT="$("${PODMAN[@]}" run "${BASE_FLAGS[@]}" --network="${EGRESS_NET}" "${IMAGE}" bash -c '
    curl -sS --max-time 5 -o /dev/null "'"http://${PROBE_IP}"'/" 2>/dev/null
    echo "RAWIP_EXIT=$?"
  ' 2>&1)" || true
  RAWIP_EXIT_INTERNAL="$(echo "$NOROUTE_OUT" | grep '^RAWIP_EXIT=' | cut -d= -f2-)"
  if [[ "$RAWIP_EXIT_INTERNAL" == "7" ]]; then
    pass "atelier-internal has no route out: a no-proxy raw-IP curl to ${PROBE_IP} fails with exit 7"
  else
    fail "atelier-internal has no route out: a no-proxy raw-IP curl to ${PROBE_IP} fails with exit 7 (got exit=${RAWIP_EXIT_INTERNAL})"
  fi

  # Snapshot the proxy's log line count before firing test requests, so
  # the refusal-message greps below only look at lines THIS run produced
  # -- a stale refusal line from an earlier smoke run for the same
  # hostname would otherwise make a broken filter look like it still
  # works.
  LOG_LINES_BEFORE="$("${PODMAN[@]}" logs "${EGRESS_HOST}" 2>&1 | wc -l)"

  PROXY_OUT="$("${PODMAN[@]}" run "${BASE_FLAGS[@]}" --network="${EGRESS_NET}" \
    --add-host "${EGRESS_HOST}:${EGRESS_IP}" \
    -e "HTTPS_PROXY=http://${EGRESS_HOST}:${EGRESS_PORT}" \
    -e "HTTP_PROXY=http://${EGRESS_HOST}:${EGRESS_PORT}" \
    "${IMAGE}" bash -c '
      code=$(curl -sS --max-time 10 --proxy "$HTTPS_PROXY" -o /dev/null -w "%{http_code}" https://api.github.com 2>/dev/null || echo 000)
      echo "ALLOWED_CODE=$code"

      # Negative assertions use the plain-HTTP forward-proxy form with
      # -w "%{http_code}", not curl exit status. Exit status conflates
      # "the proxy refused this (403)" with "DNS failed", "the proxy was
      # unreachable" and "the connection timed out" -- all four report
      # curl exit 56 or empty on the CONNECT path, so a completely broken
      # or empty filter would have passed the old check identically
      # (security HIGH / critic finding, both independently demonstrated
      # this). The plain-HTTP form returns a clean body-level status code
      # tinyproxy sets itself.
      code=$(curl -sS --max-time 10 --proxy "$HTTPS_PROXY" -o /dev/null -w "%{http_code}" http://example.com/ 2>/dev/null || echo 000)
      echo "EXAMPLE_CODE=$code"

      # Anchoring check, using gist.github.com: a real, publicly
      # resolvable hostname that CONTAINS the allow-listed "github.com"
      # as a trailing substring but is not that host. The earlier version
      # used an IANA-reserved .invalid name, which never resolves, so it
      # could not distinguish "refused by the anchored filter" from
      # "could not resolve" -- an unanchored filter would have passed
      # that check identically (critic H2, confirmed with a table showing
      # every negative case producing the same curl exit code).
      code=$(curl -sS --max-time 10 --proxy "$HTTPS_PROXY" -o /dev/null -w "%{http_code}" http://gist.github.com/ 2>/dev/null || echo 000)
      echo "SUBSTRING_CODE=$code"
    ' 2>&1)" || true

  ALLOWED_CODE="$(echo "$PROXY_OUT" | grep '^ALLOWED_CODE=' | cut -d= -f2-)"
  if [[ "$ALLOWED_CODE" =~ ^2[0-9][0-9]$ ]]; then
    pass "proxied curl to allow-listed host api.github.com succeeds (HTTP ${ALLOWED_CODE})"
  else
    fail "proxied curl to allow-listed host api.github.com succeeds (got: ${ALLOWED_CODE})"
  fi

  EXAMPLE_CODE="$(echo "$PROXY_OUT" | grep '^EXAMPLE_CODE=' | cut -d= -f2-)"
  SUBSTRING_CODE="$(echo "$PROXY_OUT" | grep '^SUBSTRING_CODE=' | cut -d= -f2-)"

  NEW_LOG="$("${PODMAN[@]}" logs "${EGRESS_HOST}" 2>&1 | tail -n "+$((LOG_LINES_BEFORE + 1))")"

  if [[ "$EXAMPLE_CODE" == "403" ]] && echo "$NEW_LOG" | grep -q 'Proxying refused on filtered domain "example.com"'; then
    pass "proxied plain-HTTP to non-allow-listed host example.com gets 403, and the proxy's own log records the refusal"
  else
    fail "proxied plain-HTTP to non-allow-listed host example.com gets 403, and the proxy's own log records the refusal (code=${EXAMPLE_CODE})"
  fi

  if [[ "$SUBSTRING_CODE" == "403" ]] && echo "$NEW_LOG" | grep -q 'Proxying refused on filtered domain "gist.github.com"'; then
    pass "proxied plain-HTTP to gist.github.com (substring-matches allow-listed github.com, is not it) gets 403 and is logged as refused (anchoring check)"
  else
    fail "proxied plain-HTTP to gist.github.com gets 403 and is logged as refused (anchoring check) (code=${SUBSTRING_CODE})"
  fi
else
  # A down proxy FAILs the suite by default (Codex MEDIUM, shared with
  # Justfile egress-up; this is the smoke.sh half). The suite used to
  # SKIP all four proxy checks and still exit 0 -- meaning `just smoke`
  # reported a clean pass with zero egress-allow-list coverage whenever
  # the proxy happened to be down (including if `egress-up` itself had
  # silently failed to leave a running container). Set SMOKE_BASE_ONLY=1
  # to intentionally run only the base-image checks, e.g. before the
  # proxy has ever been brought up.
  if [[ "${SMOKE_BASE_ONLY:-0}" == "1" ]]; then
    skip "atelier-internal has no route out" "SMOKE_BASE_ONLY=1: proxy checks intentionally skipped"
    skip "proxied curl to allow-listed host api.github.com succeeds" "SMOKE_BASE_ONLY=1: proxy checks intentionally skipped"
    skip "proxied plain-HTTP to example.com gets 403 and is logged as refused" "SMOKE_BASE_ONLY=1: proxy checks intentionally skipped"
    skip "proxied plain-HTTP anchoring check (gist.github.com)" "SMOKE_BASE_ONLY=1: proxy checks intentionally skipped"
  else
    fail "atelier-egress is not running, so the egress allow-list could not be checked. Run 'just egress-up' first, or set SMOKE_BASE_ONLY=1 to intentionally run only the base-image checks."
  fi
fi

# --- Summary --------------------------------------------------------------
echo
echo "== summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped =="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
