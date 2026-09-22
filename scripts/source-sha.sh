#!/usr/bin/env bash
# scripts/source-sha.sh <dir> [extra-file...]
#
# Computes the SOURCE_SHA manifest hash used for the org.atelier.source-sha
# image label (AUDIT.md §3.1): one `sha256sum` line per input file (path +
# content hash), sorted for determinism, then sha256sum of that manifest --
# not a hash of concatenated bytes. That distinction matters: moving
# content between files, renaming a file, or adding/removing one changes
# the hash even if the total bytes are identical.
#
# Inputs are every regular file under <dir> (recursive), plus any extra
# files given as additional arguments -- the latter is how an overlay
# image's manifest includes agent-base's own Containerfile and installer
# (AUDIT.md §5: "SOURCE_SHA manifest = base Containerfile + base installer
# + overlay files") without hashing the whole containers/agent-base tree
# twice or hardcoding a second file list.
#
# This is the single source of truth for the computation: the Justfile's
# build-base, build-egress, and build recipes all call this script instead
# of each inlining their own `sha256sum ... | sha256sum`, and
# agent-enter.sh recomputes the same manifest for its staleness check
# (AUDIT.md §3.1) -- so the two call sites cannot drift apart.
set -euo pipefail

usage() {
  echo "usage: $0 <dir> [extra-file...]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
dir="$1"
shift

if [[ ! -d "$dir" ]]; then
  echo "source-sha: not a directory: ${dir}" >&2
  exit 1
fi

files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find "$dir" -type f -print0)

for extra in "$@"; do
  if [[ ! -f "$extra" ]]; then
    echo "source-sha: extra file not found: ${extra}" >&2
    exit 1
  fi
  files+=("$extra")
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "source-sha: no input files found under ${dir}" >&2
  exit 1
fi

# Sort the combined list (dir contents + extras) so the manifest -- and
# therefore the resulting hash -- does not depend on find's traversal
# order or on the order extra files were passed on the command line.
mapfile -t sorted_files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)

LC_ALL=C sha256sum "${sorted_files[@]}" | sha256sum | cut -d' ' -f1
