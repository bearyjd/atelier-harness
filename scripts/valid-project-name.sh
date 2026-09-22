#!/usr/bin/env bash
# scripts/valid-project-name.sh <name>
#
# Single source of truth for project-name validation (code review M5,
# .omc/reviews/phase2-code-review.md): the Justfile's `build` recipe and
# agent-enter.sh's sanitize_project_name previously carried two separate
# copies of this rule and had already drifted -- the Justfile rejected "."
# and ".." on top of the regex; the script's copy did not. Both now call
# this script instead.
#
# Exit 0 and print nothing if valid. Exit 2 with a message on stderr if not.
set -euo pipefail

PROJECT_NAME_RE='^[A-Za-z0-9._-]+$'

usage() {
  echo "usage: $0 <name>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
name="$1"

if [[ ! "$name" =~ $PROJECT_NAME_RE || "$name" == "." || "$name" == ".." ]]; then
  echo "valid-project-name: invalid project name '${name}' (must match ${PROJECT_NAME_RE}, and not be '.' or '..')" >&2
  exit 2
fi
