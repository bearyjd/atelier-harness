#!/usr/bin/env bash
# Builds tinyproxy's anchored filter file from every *.txt file under
# /etc/tinyproxy/allowlist.d/ (base list + any per-project overlay lists a
# derived image adds), then execs tinyproxy in the foreground so its
# stdout becomes this container's PID 1 stdout (`podman logs` visibility).
#
# Anchoring matters: tinyproxy's Filter treats each line as a regex
# (FilterType ere), so a bare "github.com" would also match
# "github.com.attacker.example" as a substring. Every hostname here is
# wrapped as ^host$ to force an exact match.
#
# If arguments are given (e.g. `podman run atelier-egress bash -c ...` for
# debugging), exec them directly instead of silently starting the proxy --
# this cost a reviewer a debugging cycle when it always started tinyproxy
# regardless of the command line (2026-09-22).
set -euo pipefail

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

ALLOWLIST_DIR="${ALLOWLIST_DIR:-/etc/tinyproxy/allowlist.d}"
# Fixed path, matching tinyproxy.conf's Filter directive literally -- no
# indirection variable. A prior FILTER_FILE override could point tinyproxy
# at a path the generated filter was never written to, which fails closed
# (tinyproxy refuses to start without its filter file) but has no valid
# use, so the knob was removed rather than documented as intentional.
# This path is a tmpfs mounted read-write by `just egress-up`
# (--tmpfs /run/tinyproxy:rw,mode=1777 -- Podman's --tmpfs does not
# support uid=/gid= mount options, verified 2026-09-22, so 1777 is used
# instead of owning it to the tinyproxy uid specifically; safe because
# this container runs exactly one process, as that uid); the rest of the
# container's rootfs is --read-only.
FILTER_FILE="/run/tinyproxy/filter"

if [[ ! -d "$ALLOWLIST_DIR" ]]; then
  echo "entrypoint.sh: allow-list directory ${ALLOWLIST_DIR} does not exist" >&2
  exit 1
fi

shopt -s nullglob
allowlist_files=("$ALLOWLIST_DIR"/*.txt)
if [[ ${#allowlist_files[@]} -eq 0 ]]; then
  echo "entrypoint.sh: no *.txt allow-list files found in ${ALLOWLIST_DIR}" >&2
  exit 1
fi

# Pure-bash trim (no subshell/fork per line, unlike piping through xargs
# or sed). xargs was dropped here because it interprets quotes and
# backslashes in its input: an allow-list entry containing an unmatched
# quote would abort the whole script under `set -e` rather than being
# rejected as an invalid hostname by the validation below.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Allow-list entries are a system boundary (repo coding-style rule:
# validate at system boundaries). Every entry must be a well-formed DNS
# hostname -- not just "these characters are allowed" (the prior
# ^[A-Za-z0-9.-]+$ check, which technically also matched an IPv4 literal
# like "10.88.0.1" character-for-character). CORRECTION (2026-09-22,
# Codex adversarial review, MEDIUM): a hostname allow-list entry that is
# actually an IP literal authorizes direct access to whatever that IP is
# -- including RFC1918/loopback ranges such as the Podman gateway
# (10.88.0.1) -- for every agent container, since the filter has no
# separate "is this actually a hostname" concept beyond "does this string
# match the allow-list". A future overlay's allowlist.txt could add one
# by mistake (or by attack) and nothing would have caught it before.
#
# Grammar enforced, per label (dot-separated) and overall:
#   - each label: starts and ends with an alphanumeric character; only
#     alphanumerics and hyphens in between (no leading/trailing hyphen,
#     no empty label -- so no leading/trailing dot and no "..").
#   - at least one character anywhere in the whole name must be
#     alphabetic. A name with zero letters is either a bare IPv4 literal
#     ("10.88.0.1") or something equally IP-shaped; a real hostname
#     always has at least one letter somewhere (even single-letter TLDs
#     like ".io" have one). This is what actually rejects IPv4 literals
#     -- the label grammar alone accepts them, since "10", "88", "0", "1"
#     are all individually valid labels.
#   - no colon anywhere. Colons never appear in a bare hostname; this is
#     either an IPv6 literal or a host:port typo, and are rejected
#     explicitly rather than relying only on the label grammar to exclude
#     them (IPv6 literals contain no dots in the label sense, so this is
#     the check that actually catches them, not an accident of the regex
#     already excluding ":" from its character class).
#   - overall length <= 253 characters (the DNS limit).
# This also still blocks wildcards like "*.github.com" (rejected: "*" is
# not in the label character class), which would otherwise become the
# anchored regex ^*\.github\.com$ -- a repetition operator with nothing
# to repeat.
dns_label_re='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
hostname_re="^${dns_label_re}(\\.${dns_label_re})*\$"

validate_hostname() {
  local h="$1"
  if [[ ${#h} -gt 253 ]]; then
    return 1
  fi
  if [[ "$h" == *:* ]]; then
    return 1
  fi
  if [[ ! "$h" =~ $hostname_re ]]; then
    return 1
  fi
  if [[ "$h" != *[A-Za-z]* ]]; then
    return 1
  fi
  return 0
}

# All entries are validated and accumulated in memory BEFORE anything is
# written to $FILTER_FILE -- previously the file was truncated first and
# filled line by line, so a validation failure partway through left a
# half-written filter file behind (and required $FILTER_FILE's directory
# to already be writable just to test the validator at all, even when
# every entry is invalid). Now nothing touches disk until every entry in
# every file has passed.
filter_lines=""
for f in "${allowlist_files[@]}"; do
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%%#*}"   # strip trailing comments
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    if ! validate_hostname "$line"; then
      echo "entrypoint.sh: invalid allow-list entry in ${f}: '${line}' (must be a DNS hostname -- IP literals, host:port, and malformed labels are rejected)" >&2
      exit 1
    fi
    escaped="$(printf '%s' "$line" | sed -E 's/[.]/\\./g')"
    filter_lines+="^${escaped}\$"$'\n'
  done < "$f"
done

printf '%s' "$filter_lines" > "$FILTER_FILE"

echo "entrypoint.sh: generated allow-list filter from: ${allowlist_files[*]}" >&2
echo "entrypoint.sh: ${FILTER_FILE} contents:" >&2
cat "$FILTER_FILE" >&2

exec tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf
